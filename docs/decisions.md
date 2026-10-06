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

## Open questions (next)

- **Restatement definition:** Is a new version created whenever a later filing reports a *different* value,
  or on every re-report? (Leaning: only on a changed value, with `is_restated` flagged.)
- **Q4 values:** 10-Ks report annual totals only. Derive Q4 as annual minus nine-month YTD, and decide
  which versions of each to use when either one has been restated.
