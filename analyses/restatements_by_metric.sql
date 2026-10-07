-- Which metrics and companies get revised most often?
with reports as (

    select
        ticker,
        metric,
        value,
        lag(value) over (
            partition by cik, metric, period_start, period_end
            order by filed_date, accession_number
        ) as previous_value
    from {{ ref('int_facts__mapped') }}

)

select
    metric,
    count(*) filter (where previous_value <> value)               as changed_values,
    count(distinct ticker) filter (where previous_value <> value) as companies_affected
from reports
group by metric
order by changed_values desc
