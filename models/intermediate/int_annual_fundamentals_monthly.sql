-- What was known about each fiscal year, at each month-end (decisions 016 and 017).
-- Grain: one row per company, month-end and fiscal year, with one column per metric.
-- Only values public on that month-end are used, and scale-error versions are excluded.

{% set metrics = [
    'revenue', 'cost_of_revenue', 'gross_profit', 'operating_income', 'net_income', 'net_income_incl_nci',
    'operating_cash_flow', 'capex', 'diluted_shares',
    'total_assets', 'current_assets', 'current_liabilities',
    'long_term_debt', 'long_term_debt_current', 'long_term_debt_incl_current',
    'long_term_debt_incl_leases', 'total_debt_reported', 'short_term_borrowings', 'commercial_paper',
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

),

pivoted as (

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

),

with_short_term_debt as (

    select
        *,
        -- Decision 020: borrowings if reported, otherwise commercial paper, never both.
        coalesce(short_term_borrowings, commercial_paper, 0) as short_term_debt
    from pivoted

)

select
    *,

    -- Decision 022: net income attributable to the parent; if a company only reports net income
    -- including non-controlling interests (ProfitLoss), use that and record the basis.
    coalesce(net_income, net_income_incl_nci)                       as net_income_used,
    case
        when net_income is not null          then 'net_income'
        when net_income_incl_nci is not null then 'net_income_incl_nci'
    end                                                             as net_income_basis,

    -- Decisions 018 and 023: total debt from the first available source, in this order.
    case
        when long_term_debt_incl_current is not null
            then long_term_debt_incl_current + short_term_debt
        when long_term_debt is not null
            then long_term_debt + coalesce(long_term_debt_current, 0) + short_term_debt
        when total_debt_reported is not null
            then total_debt_reported
        when long_term_debt_incl_leases is not null
            then long_term_debt_incl_leases + short_term_debt
    end                                                             as total_debt,
    case
        when long_term_debt_incl_current is not null then 'long_term_debt_incl_current'
        when long_term_debt is not null              then 'noncurrent_plus_current'
        when total_debt_reported is not null         then 'company_reported_total'
        when long_term_debt_incl_leases is not null  then 'incl_finance_leases'
    end                                                             as total_debt_source
from with_short_term_debt
