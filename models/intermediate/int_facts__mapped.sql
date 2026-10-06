-- Map raw XBRL concepts to standard metrics (seeds/concept_map.csv) and classify the period grain.
-- Companies tag the same idea differently (e.g. revenue has 4+ common tags). When a filing reports
-- several tags for the same metric and period, keep the highest-priority tag (lowest number).

with facts as (

    select * from {{ ref('stg_sec__facts') }}

),

concept_map as (

    select * from {{ ref('concept_map') }}

),

mapped as (

    select
        facts.*,
        concept_map.metric,
        concept_map.priority as concept_priority,
        case
            when facts.period_type = 'instant'           then 'instant'
            when facts.duration_days between 80 and 100  then 'quarter'
            when facts.duration_days between 350 and 380 then 'annual'
            else 'year_to_date'  -- e.g. 6- and 9-month cumulative values in 10-Qs
        end as period_grain
    from facts
    inner join concept_map
        on  facts.concept = concept_map.source_concept
        and facts.unit    = concept_map.unit

)

select
    md5(concat_ws('|', cik, metric, coalesce(cast(period_start as varchar), ''),
                  cast(period_end as varchar), accession_number)) as metric_fact_id,
    *
from mapped
qualify row_number() over (
    partition by cik, metric, period_start, period_end, accession_number
    order by concept_priority
) = 1
