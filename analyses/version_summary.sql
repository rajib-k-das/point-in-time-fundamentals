-- Headline numbers for the README: how much history does the SCD2 model hold, and why?
select
    metric,
    count(distinct fact_key)                                             as facts,
    count(distinct fact_key) filter (where is_restatement)               as facts_ever_restated,
    round(100.0 * count(distinct fact_key) filter (where is_restatement)
          / count(distinct fact_key), 2)                                 as pct_facts_restated,
    count(*) filter (where is_restatement)                               as restatements,
    count(*) filter (where is_scale_error)                               as scale_errors
from {{ ref('int_fact_versions') }}
group by rollup (metric)
order by metric nulls first
