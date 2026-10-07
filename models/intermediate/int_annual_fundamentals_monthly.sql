-- What was known about each fiscal year, at each month-end (decisions 016 and 017).
-- Grain: one row per company, month-end and fiscal year, with one column per metric.
-- Only values public on that month-end are used, and scale-error versions are excluded.

{% set metrics = [
    'revenue', 'cost_of_revenue', 'gross_profit', 'operating_income', 'net_income',
    'operating_cash_flow', 'capex', 'diluted_shares',
    'total_assets', 'current_assets', 'current_liabilities',
    'long_term_debt', 'long_term_debt_current', 'long_term_debt_incl_current',
    'short_term_borrowings', 'commercial_paper',
    'shareholders_equity', 'total_equity'
] %}

with month_ends as (

    select date_day as as_of_date
    from {{ ref('dim_date') }}
    where is_month_end
      and date_day >= date '2010-01-31'

),

fundamentals as (

    select * from {{ ref('fct_fundamentals') }}
    where not is_scale_error

),

-- A company's fiscal year ends are the end dates of its annual (10-K) periods.
fiscal_year_ends as (

    select distinct cik, period_end as fiscal_year_end
    from fundamentals
    where period_grain = 'annual'

),

-- Annual amounts, plus balance-sheet snapshots taken at a fiscal year end.
annual_values as (

    select cik, ticker, metric, period_end as fiscal_year_end, value, valid_from, valid_to
    from fundamentals
    where period_grain = 'annual'

    union all

    select fundamentals.cik, ticker, metric, period_end, value, valid_from, valid_to
    from fundamentals
    inner join fiscal_year_ends
        on  fundamentals.cik        = fiscal_year_ends.cik
        and fundamentals.period_end = fiscal_year_ends.fiscal_year_end
    where period_grain = 'instant'

),

known_at_month_end as (

    select
        month_ends.as_of_date,
        annual_values.*
    from month_ends
    inner join annual_values
        on  annual_values.valid_from <= month_ends.as_of_date
        and (annual_values.valid_to is null or month_ends.as_of_date < annual_values.valid_to)

)

select
    cik,
    any_value(ticker) as ticker,
    as_of_date,
    fiscal_year_end,
    {%- for metric in metrics %}
    max(value) filter (where metric = '{{ metric }}') as {{ metric }}{{ "," if not loop.last }}
    {%- endfor %}
from known_at_month_end
group by cik, as_of_date, fiscal_year_end
