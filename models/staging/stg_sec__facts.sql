-- Staging: type-cast raw SEC facts, add descriptive flags, and remove exact duplicates.
-- SEC repeats a fact inside the same filing when it belongs to a calendar "frame";
-- those copies carry no new information, so we keep one row per filing + concept + period.

with source as (

    select * from {{ source('sec', 'sec_facts') }}

),

typed as (

    select
        ticker,
        cik,
        entity_name,
        concept,
        unit,
        cast(period_start as date)       as period_start,
        cast(period_end as date)         as period_end,
        cast(value as double)            as value,
        accession_number,
        cast(fiscal_year as integer)     as fiscal_year,
        fiscal_period,
        form,
        cast(filed_date as date)         as filed_date,
        frame,
        loaded_at
    from source

),

deduplicated as (

    select *
    from typed
    qualify row_number() over (
        partition by cik, concept, unit, period_start, period_end, accession_number
        order by frame nulls last
    ) = 1

)

select
    md5(concat_ws('|', cik, concept, unit, coalesce(cast(period_start as varchar), ''),
                  cast(period_end as varchar), accession_number))          as fact_id,
    *,
    case when period_start is null then 'instant' else 'duration' end     as period_type,
    date_diff('day', period_start, period_end) + 1                         as duration_days,
    form like '%/A'                                                        as is_amendment
from deduplicated
