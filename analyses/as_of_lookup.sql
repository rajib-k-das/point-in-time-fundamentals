-- Point-in-time lookup: what did the market know on a given date?
-- Run with a different date or company:
--   python scripts/run_analysis.py as_of_lookup --vars '{"as_of_date": "2019-06-30", "ticker": "KO"}'
{% set as_of_date = var('as_of_date', '2023-03-01') %}
{% set ticker = var('ticker', 'AAPL') %}

select
    ticker,
    metric,
    period_end,
    value,
    version_number,
    valid_from,
    valid_to,
    is_scale_error
from {{ ref('int_fact_versions') }}
where ticker = '{{ ticker }}'
  and period_grain = 'annual'
  and valid_from <= date '{{ as_of_date }}'
  and (valid_to is null or date '{{ as_of_date }}' < valid_to)
order by metric, period_end desc
