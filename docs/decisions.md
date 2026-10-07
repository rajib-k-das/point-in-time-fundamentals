# Design decision log

Each entry records a modeling choice, the alternatives considered, and why this one won.

## 001 — Local-first stack: DuckDB + dbt Core

**Decision:** Build on DuckDB (an embedded analytical database) with dbt Core instead of a cloud warehouse.
**Why:** Anyone can clone and run the full project in minutes at zero cost, and CI can build it on every push.
The SQL and dbt patterns transfer directly to Snowflake or BigQuery by changing the profile.
**Trade-off:** No concurrency or scale features, which this dataset doesn't need.

## 002 — Keep every filing, including comparatives and amendments

**Decision:** Load every 10-K, 10-Q, 10-K/A, and 10-Q/A value, not only the latest one per period.
**Why:** A point-in-time warehouse needs to know what value was public on each date. Deduplicating to the
latest value at ingestion would destroy exactly the history the project exists to model.
**Trade-off:** More rows, and downstream models must handle multiple versions per period explicitly.

## 003 — Seed-driven concept mapping with priority order

**Decision:** Map XBRL tags to standard metrics in `seeds/concept_map.csv`, with a priority column
used when a filing reports more than one tag for the same metric and period.
**Why:** Companies report the same idea under different tags (revenue has at least four common ones), and
tags change over time. A version-controlled table keeps the mapping explicit, reviewable in pull requests,
and covered by a relationships test.
**Trade-off:** New tags must be added manually. Unmapped tags are dropped at ingestion, not silently guessed.

## 004 — Exclude financial-sector companies

**Decision:** The universe covers 28 non-financial US large caps across 7 sectors.
**Why:** Banks and insurers don't report gross profit, current assets, or current liabilities, so the
Piotroski F-score and accruals ratio are not meaningful for them.
**Trade-off:** No financials coverage; a separate bank-specific metric set could be added later.

## 005 — Classify period grain by duration, not by the fiscal period label

**Decision:** Derive `period_grain` (quarter, annual, year_to_date, instant) from the number of days
between period start and end.
**Why:** The SEC `fp` field describes the *filing*, not the *value*. A Q2 10-Q contains both a 3-month
and a 6-month value, both labelled Q2. Duration is the reliable signal.
**Trade-off:** 52/53-week fiscal years need tolerance bands (80–100 days, 350–380 days).

## Evidence behind decisions 006–011

Before modeling restatements, the raw history was measured (`analyses/restatement_*.sql`,
28 companies, real SEC data):

| Measure | Count |
|---|---|
| Reported values | 61,289 |
| First reports of a period | 27,499 |
| Re-reports with an unchanged value | 31,270 (92.5% of re-reports) |
| Re-reports with a changed value | 2,520 (7.5% of re-reports) |

The 2,520 changes were not all restatements. The largest were **XBRL scale errors**
(KO diluted shares 4,295 → 4,295,000,000; NVDA off by 1,000×), and many of the smallest were
**rounding noise** (WMT revenue 114,070M → 114,071M → 114,070M). Decisions 006–011 handle each case.

## 006 — A new version starts only when the value meaningfully changes

**Decision:** Re-reports that repeat the existing value confirm the current version instead of creating a new one.
**Why:** 92.5% of re-reports change nothing. Versioning them would roughly double the table with zero information,
and make "how often was this restated?" impossible to answer from version counts.
**Trade-off:** The model records when a value was first published, not every filing that repeated it.
`times_reported` and `last_confirmed_date` keep that information in summary form.

## 007 — Changes of 0.01% or less are rounding noise

**Decision:** A re-report starts a new version only if it differs from the previous report by more than 0.01%
of the larger value (`restatement_tolerance` in `dbt_project.yml`).
**Why:** Filings round to the nearest million, so the same number flip-flops by ±$1M between filings.
At 0.01%, a $1M wobble on $10B of revenue is ignored, while any revision an analyst would notice is kept.
**Trade-off:** A genuine revision under 0.01% is treated as noise. It is immaterial by any standard.

## 008 — Scale errors are kept, flagged, and excluded downstream

**Decision:** A superseded value that differs from the current value by a power of 1,000 (log10 of the ratio
within 0.02 of 3, 6 or 9) is flagged `is_scale_error = true`. It stays in the history.
**Why:** Two principles conflict. A point-in-time record must keep what was actually published, even if it was
wrong. But no analyst would screen on 4,295 diluted shares for Coca-Cola. Keeping the row with a flag satisfies
both: the history is honest, and the screening marts filter flagged rows out.
**Trade-off:** The check uses the current value as the reference. If the *latest* filing is the wrong one, it can't be
detected until a later filing corrects it.

## 009 — A version becomes known the day after it was filed

**Decision:** `valid_from = filed_date + 1 day`.
**Why:** Many filings are submitted after the market close. Treating them as known on the filing date would let a
backtest trade on information that wasn't available during that day's session: a small but real lookahead bias.
**Trade-off:** Filings made before the open are treated as one day late, which is the conservative direction.

## 010 — Same-day filings: the latest accession number wins

**Decision:** If several filings report the same fact on the same date, only the one with the highest accession
number is used.
**Why:** Without this, two versions would share the same `valid_from`, creating zero-length windows that break
point-in-time lookups. Accession numbers increase within a filer, so the highest one is the latest submission.
**Trade-off:** An intra-day value replaced within hours is not recorded as a separate version.

## 011 — Half-open validity windows

**Decision:** Each version is valid from `valid_from` (inclusive) to `valid_to` (exclusive), and `valid_to` equals the
next version's `valid_from`. The current version has `valid_to = null`.
**Why:** Exactly one version matches any date, with no gaps and no double-counting. Two data tests enforce this:
one current version per fact, and contiguous, non-overlapping windows.
**Lookup:** `valid_from <= as_of_date and (valid_to is null or as_of_date < valid_to)`.

## 012 — Tags that measure different things get different metrics

**Decision:** Split two metrics that mixed non-equivalent tags:
`shareholders_equity` (`StockholdersEquity`, parent only) vs. `total_equity` (including non-controlling interest), and
`long_term_debt` (`LongTermDebtNoncurrent`) vs. `long_term_debt_incl_current` (`LongTermDebt`, which adds the current portion).
**Evidence:** `analyses/concept_switches.sql` showed **549 of 601 (91%)** equity "restatements" happened when the reported tag
switched between the two equity definitions. Shareholders' equity looked restated for 29% of facts, three times any other metric.
The two long-term debt tag switches moved values by a median 15%: the gap between the two definitions, not a revision.
**Result:** equity's restatement rate fell from 29.2% to 1.9% of facts, in line with other balance-sheet metrics (1.9–4.3%).
**Why:** If two tags can legitimately report different numbers for the same period, a change between them is not a restatement.
The mapping was manufacturing restatements.
**Guard:** `assert_concept_map_is_consistent` fails if a metric mixes units or period types, or two tags share a priority;
each tag can feed only one metric (`unique` test on `source_concept`).
**Trade-off:** A company that reports only one equity tag has no value for the other metric. The marts choose explicitly
which definition each ratio uses, instead of the mapping choosing silently.

**Total debt is derived, not tagged.** `LongTermDebt` covers long-term debt including its current portion, but not
short-term borrowings, so no single tag equals total debt. The marts will compute
`total_debt = long_term_debt_incl_current + short_term_borrowings` (`ShortTermBorrowings`), each component taken as of
the same date. Open check: some companies report commercial paper under its own tag instead of inside short-term
borrowings; verify per company before adding it, to avoid double counting.

## 013 — Equivalent-tag switches are kept, and flagged

**Decision:** Revenue and cost of revenue keep several tags under one metric, and `int_fact_versions.is_tag_switch` marks
restatements whose tag differs from the version they replaced.
**Evidence:** 26% of revenue restatements (92 of 350) came with a tag change, mostly around the 2018 adoption of ASC 606, and the
values moved (median 4.4%). These are real re-presentations under a new standard, not mapping errors.
**Why:** Dropping them would hide genuine history; leaving them unmarked would blur "the company revised its number" with
"the company re-presented it under a new standard". The flag lets screens and analyses separate the two.

## 014 — Derived Q4 values are versioned by the overlap of their inputs

**Decision:** Q4 = annual value − nine-month year-to-date value (same fiscal year start). Every pairing of an annual
version with a nine-month version is a candidate Q4 version, valid only while *both* inputs were the latest public
numbers: from the later of the two `valid_from` dates to the earlier of the two `valid_to` dates.
**Why:** Companies never file a Q4 report. If the annual figure is amended, Q4 changes; if the nine-month figure is
restated, Q4 changes too. Using a restated input before it was published would reintroduce lookahead bias through
the derivation. Intersecting the two timelines keeps derived values exactly as point-in-time as reported ones.
**Rules:** a directly reported Q4 always wins over a derived one; scale-error inputs are never used.
**Test:** `assert_fixture_known_answers` checks a hand-calculated case: Q4 revenue of 120 − 87 = 33, becoming
114 − 87 = 27 on the day the 10-K/A became public.

## 015 — Q4 is derived only for income-statement and cash-flow amounts

**Decision:** Only metrics with `balance_type = duration` and `unit = USD` in `concept_map`.
**Why:** Balance-sheet items are snapshots at a date; there's nothing to subtract. Diluted shares are a weighted
average, and annual average minus nine-month average is not the Q4 average.

## 016 — Validity windows plus a month-end snapshot, not a daily table

**Decision:** `fct_fundamentals` keeps one row per version with its validity window. Screening runs on month-ends
(`fct_screening_monthly`).
**Why:** A daily table would hold roughly 29,000 facts × 5,000 days, about 145 million rows that are almost all
identical to the day before. Windows store the same information compactly, and any date can still be queried.
**Trade-off:** Screens rebalance monthly. A daily view can be generated from the windows if ever needed.

## 017 — Screens use the latest annual report known on each month-end

**Decision:** Each month-end compares fiscal year *t* (the latest annual report public on that date) with year *t−1*;
year *t−2* supplies beginning-of-year assets. Prior years count only if consecutive (350–380 days apart).
**Piotroski F-score:** the nine standard signals, each 1, 0, or **null when an input is unknown**. Unknown inputs are
never scored as 0, so the score is reported with `f_score_signals_available`; a complete score has 9.
Details: ROA and asset turnover use beginning-of-year assets; leverage is long-term debt over average assets;
gross margin falls back to revenue − cost of revenue when gross profit isn't tagged.
**Why point-in-time matters here:** in the fixture, the same company scores **8 of 8** in March 2023 (its share
count was a scale error, so the dilution signal is unknown) and **9 of 9** in March 2024, after the correction was
filed. A naive warehouse would show 9 for both dates, using information nobody had in 2023.
**Stock splits:** splits don't fake a "dilution" signal, because the latest 10-K re-presents the prior year's share
count split-adjusted, and the SCD2 model uses that newer version for both years.

## 018 — Total debt is built from components

**Decision:** `total_debt = long-term debt including current portion + short-term debt`.
Long-term part: `LongTermDebt`, or `LongTermDebtNoncurrent + LongTermDebtCurrent` when only the split is reported.
Short-term part: see decision 020. No short-term tag counts as zero.
**Why:** No single XBRL tag equals total debt, and commercial paper is sometimes inside short-term borrowings and
sometimes separate. Adding both blindly double-counts; ignoring paper undercounts.
**Check:** `analyses/commercial_paper_check.sql` classifies every company's pattern on real data.

## 019 — A fiscal year is a 12-month period reported in a 10-K

**Decision:** A ~12-month period is classified `annual` only if a 10-K or 10-K/A reported it. Twelve-month periods
that appear only in 10-Qs are `trailing_twelve_months` and are excluded from fiscal-year logic.
**Evidence:** The first real-data screen showed Amazon with a fiscal year ending **2026-06-30** and an F-score of
1 of 1. Amazon's year ends in December; its 10-Qs report trailing-twelve-month cash-flow figures, which the
duration-only rule mistook for a fiscal year.
**Why at the fact level:** the check looks at every filing of the same period, so one period can never be split
between two grains.
**Test:** the fixture includes a 10-Q with twelve-month figures; `assert_fixture_known_answers` fails if they become
a fiscal year. Reverting the rule makes the test fail (verified).

## 020 — Short-term debt: borrowings if reported, otherwise commercial paper, never both

**Decision:** `short-term debt = coalesce(ShortTermBorrowings, CommercialPaper, 0)`. This replaces the earlier
rule that added both when commercial paper exceeded borrowings.
**Evidence:** `commercial_paper_check` found the "add both" rule firing on 23 balance sheets (Chevron, Microsoft).
Companies such as Chevron reclassify commercial paper into long-term debt when they intend and are able to
refinance it, so the paper can be larger than short-term borrowings and *already counted* in long-term debt.
**Trade-off:** If a company reports paper separately from borrowings and doesn't reclassify it, total debt is
understated by the paper. A small, visible undercount is preferable to silent double counting.

## 021 — Coverage gaps are closed tag by tag, under the decision 012 rule

**Decision:** When a company reports a metric under a tag we don't map, add that tag to `concept_map` only if it
measures the same thing as the existing tags. Otherwise leave the value unknown.
**Evidence:** the first screen had no debt for KO, ORCL, VZ and CVX, missing cash-flow inputs for CAT, and no row
at all for XOM.
**Tools:** `analyses/coverage_by_company.sql` shows which metrics are missing from each company's latest annual
report; `scripts/discover_tags.py` lists the tags a company actually uses, with their latest 10-K values.

## Open questions (next)

- **Coverage gaps (decision 021):** review discovery results for KO, ORCL, VZ, CVX, CAT and XOM.
- **Diluted shares and stock splits:** same-tag diluted-share restatements have a median change of exactly 100%.
  Hypothesis: prior share counts re-presented after splits. Verify against known split dates.
