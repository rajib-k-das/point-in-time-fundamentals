-- Staging: type-cast raw SEC facts, add descriptive flags, and remove exact duplicates.
-- SEC repeats a fact inside the same filing when it belongs to a calendar "frame";
-- those copies carry no new information, so we keep one row per filing + concept + period.

with source as (

    select * from {{ source('sec', 'sec_facts') }}

),

-- Decision 025: a company that reorganized under a new registrant files under a new CIK, but its
-- history stays under the predecessor's. Everything is keyed to the current CIK; the CIK that
-- actually filed each value is kept as filer_cik.
predecessors as (

    select ticker, lpad(cast(cik as varchar), 10, '0') as cik
    from {{ ref('predecessor_ciks') }}

),

current_ciks as (

    select source.ticker, any_value(source.cik) as cik
    from {{ source('sec', 'sec_facts') }} as source
    anti join predecessors
        on source.ticker = predecessors.ticker
       and source.cik = predecessors.cik
    group by source.ticker

),

typed as (

    select
        source.ticker,
        coalesce(current_ciks.cik, source.cik) as cik,
        source.cik                             as filer_cik,
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
    left join current_ciks on source.ticker = current_ciks.ticker

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
