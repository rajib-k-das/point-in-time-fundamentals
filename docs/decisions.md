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

## Open questions (next)

- **Diluted shares and stock splits:** same-tag diluted-share restatements have a median change of exactly 100%. Hypothesis:
  prior share counts re-presented after stock splits. Verify against known split dates; it matters for per-share metrics.
- **Q4 values:** 10-Ks report annual totals only. Derive Q4 as annual minus nine-month YTD, and decide which
  versions of each to use when either one has been restated.
