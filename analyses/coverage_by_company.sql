-- Decision 021: which companies are missing which metrics in their latest annual report?
-- A "missing" cell means no mapped tag was reported for that fiscal year; use
-- scripts/discover_tags.py to find the tag the company actually uses.
{% set metrics = ['revenue', 'net_income', 'operating_cash_flow', 'gross_profit', 'cost_of_revenue',
                  'total_assets', 'current_assets', 'current_liabilities', 'long_term_debt',
                  'long_term_debt_incl_current', 'diluted_shares'] %}

with latest_year as (

    select cik, max(period_end) as fiscal_year_end
    from {{ ref('fct_fundamentals') }}
    where period_grain = 'annual' and is_current
    group by cik

),

values_in_latest_year as (

    select fundamentals.ticker, fundamentals.metric
    from {{ ref('fct_fundamentals') }} as fundamentals
    inner join latest_year
        on  fundamentals.cik = latest_year.cik
        and fundamentals.period_end = latest_year.fiscal_year_end
    where fundamentals.is_current
      and fundamentals.period_grain in ('annual', 'instant')

)

select
    company.ticker,
    latest_year.fiscal_year_end,
    {%- for metric in metrics %}
    case when count(*) filter (where values_in_latest_year.metric = '{{ metric }}') > 0
         then 'ok' else 'MISSING' end as {{ metric }}{{ "," if not loop.last }}
    {%- endfor %}
from {{ ref('dim_company') }} as company
left join latest_year on company.cik = latest_year.cik
left join values_in_latest_year on company.ticker = values_in_latest_year.ticker
group by company.ticker, latest_year.fiscal_year_end
order by company.ticker
