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
        -- Decision 019: a 12-month period is a fiscal year only if a 10-K reported it.
        -- Twelve-month figures that appear only in 10-Qs are trailing-twelve-month (TTM) values.
        bool_or(facts.form like '10-K%') over (
            partition by facts.cik, concept_map.metric, facts.period_start, facts.period_end
        ) as reported_in_annual_filing,
        facts.duration_days
    from facts
    inner join concept_map
        on  facts.concept = concept_map.source_concept
        and facts.unit    = concept_map.unit

)

select
    md5(concat_ws('|', cik, metric, coalesce(cast(period_start as varchar), ''),
                  cast(period_end as varchar), accession_number)) as metric_fact_id,
    * exclude (reported_in_annual_filing),
    case
        when period_type = 'instant'                                         then 'instant'
        when duration_days between 80 and 100                                then 'quarter'
        when duration_days between 350 and 380 and reported_in_annual_filing then 'annual'
        when duration_days between 350 and 380                              then 'trailing_twelve_months'
        else 'year_to_date'  -- e.g. 6- and 9-month cumulative values in 10-Qs
    end as period_grain
from mapped
qualify row_number() over (
    partition by cik, metric, period_start, period_end, accession_number
    order by concept_priority
) = 1
