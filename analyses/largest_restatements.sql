-- The biggest revisions: what changed, in which filing, and by how much?
with reports as (

    select
        ticker,
        metric,
        period_end,
        form,
        filed_date,
        value,
        lag(value) over (
            partition by cik, metric, period_start, period_end
            order by filed_date, accession_number
        ) as previous_value
    from {{ ref('int_facts__mapped') }}

)

select
    ticker,
    metric,
    period_end,
    filed_date,
    form,
    printf('%.1fM -> %.1fM (%+.1f%%)',
           previous_value / 1e6,
           value / 1e6,
           100.0 * (value - previous_value) / nullif(abs(previous_value), 0)) as revision
from reports
where previous_value <> value
order by abs(value - previous_value) / nullif(abs(previous_value), 0) desc
