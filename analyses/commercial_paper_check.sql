-- Decision 018 check: is commercial paper reported inside short-term borrowings, or separately?
-- For each company's fiscal-year-end balance sheets (current versions), classify the pattern.
with balances as (

    select
        ticker,
        period_end,
        max(value) filter (where metric = 'short_term_borrowings') as short_term_borrowings,
        max(value) filter (where metric = 'commercial_paper')      as commercial_paper
    from {{ ref('fct_fundamentals') }}
    where is_current
      and period_grain = 'instant'
      and metric in ('short_term_borrowings', 'commercial_paper')
    group by ticker, period_end

)

select
    ticker,
    case
        when commercial_paper is null      then 'borrowings only'
        when short_term_borrowings is null then 'commercial paper only'
        when commercial_paper > short_term_borrowings then 'both: paper exceeds borrowings (added)'
        else 'both: paper within borrowings (not added)'
    end                     as pattern,
    count(*)                as balance_sheets,
    min(period_end)         as first_period,
    max(period_end)         as last_period
from balances
group by all
order by ticker, pattern
