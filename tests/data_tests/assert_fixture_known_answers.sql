-- Known-answer test on the synthetic fixture company (FIXT), calculated by hand.
-- Skipped automatically on real data, where FIXT doesn't exist.
--   Q4 2022 revenue = annual - nine months: 120 - 87 = 33, then 114 - 87 = 27 after the 10-K/A.
--   F-score on 2023-03-31 = 8 of 8: the share count is a scale error, so that signal is unknown.
--   F-score on 2024-03-31 = 9 of 9: the corrected share count arrived on 2024-02-13.
--   TTM figures from a 10-Q (12 months to 2022-09-30) must never become a fiscal year:
--   on 2022-11-30 the latest fiscal year is still FY2021 (decision 019).
--   History filed by a predecessor registrant (CIK 0000000001) belongs to the same company,
--   keyed to its current CIK (decision 025).
--   Total debt on 2023-03-31 = 90 (non-current long-term debt; no short-term debt) (decision 023).
with q4_expected as (

    select * from (values
        (date '2023-03-01', 33000000.0),
        (date '2023-08-01', 27000000.0)
    ) as t(as_of_date, expected_value)

),

q4_actual as (

    select q4_expected.*, fundamentals.value as actual_value
    from q4_expected
    left join {{ ref('fct_fundamentals') }} as fundamentals
        on  fundamentals.ticker = 'FIXT'
        and fundamentals.metric = 'revenue'
        and fundamentals.is_derived
        and fundamentals.period_end = date '2022-12-31'
        and fundamentals.valid_from <= q4_expected.as_of_date
        and (fundamentals.valid_to is null or q4_expected.as_of_date < fundamentals.valid_to)

),

score_expected as (

    select * from (values
        (date '2022-11-30', null, null),
        (date '2023-03-31', 8, 8),
        (date '2024-03-31', 9, 9)
    ) as t(as_of_date, expected_score, expected_available)

),

score_actual as (

    select score_expected.*, screen.f_score, screen.f_score_signals_available
    from score_expected
    left join {{ ref('fct_screening_monthly') }} as screen
        on  screen.ticker = 'FIXT'
        and screen.as_of_date = score_expected.as_of_date

),

failures as (

    select 'Q4 revenue on ' || as_of_date as check_name
    from q4_actual
    where actual_value is distinct from expected_value

    union all

    select 'F-score on ' || as_of_date
    from score_actual
    where expected_score is not null
      and (f_score is distinct from expected_score
           or f_score_signals_available is distinct from expected_available)

    union all

    select 'TTM treated as fiscal year on 2022-11-30'
    from {{ ref('fct_screening_monthly') }}
    where ticker = 'FIXT'
      and as_of_date = date '2022-11-30'
      and fiscal_year_end is distinct from date '2021-12-31'

    union all

    select 'predecessor history not attached to the current company'
    where not exists (
        select 1 from {{ ref('fct_fundamentals') }}
        where ticker = 'FIXT'
          and cik = '0009999999'
          and metric = 'net_income'
          and period_end = date '2019-12-31'
          and value = 5000000
    )

    union all

    select 'total debt or its source on 2023-03-31'
    from {{ ref('fct_screening_monthly') }}
    where ticker = 'FIXT'
      and as_of_date = date '2023-03-31'
      and (total_debt is distinct from 90000000
           or total_debt_source is distinct from 'noncurrent_plus_current')

    union all

    select 'TTM value in fct_fundamentals'
    from {{ ref('fct_fundamentals') }}
    where ticker = 'FIXT'
      and period_end = date '2022-09-30'
      and period_grain = 'annual'

)

select *
from failures
where exists (select 1 from {{ ref('dim_company') }} where ticker = 'FIXT')
