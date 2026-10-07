-- Calendar from 2009 (the start of XBRL filings) to today, with month-end flags for screening.
with days as (

    select cast(day as date) as date_day
    from generate_series(timestamp '2009-01-01', cast(current_date as timestamp), interval 1 day) as t(day)

)

select
    date_day,
    year(date_day)                          as calendar_year,
    quarter(date_day)                       as calendar_quarter,
    month(date_day)                         as calendar_month,
    date_day = last_day(date_day)           as is_month_end
from days
