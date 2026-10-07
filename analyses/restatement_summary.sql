-- How often does a later filing report a DIFFERENT value for a period already reported?
with reports as (

    select
        value,
        lag(value) over (
            partition by cik, metric, period_start, period_end
            order by filed_date, accession_number
        ) as previous_value
    from {{ ref('int_facts__mapped') }}

)

select
    count(*)                                                      as total_reports,
    count(*) filter (where previous_value is null)                as first_reports,
    count(*) filter (where previous_value = value)                as unchanged_rereports,
    count(*) filter (where previous_value <> value)               as changed_values
from reports
