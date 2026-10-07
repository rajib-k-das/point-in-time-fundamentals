-- Point-in-time fundamentals: every version of every annual, quarterly and balance-sheet value,
-- with the window during which it was the latest public number (decision 016).
-- Includes derived Q4 values (decision 014). Nine-month and six-month year-to-date values are
-- inputs to the derivation only and are left out here.
--
-- As-of lookup:  valid_from <= as_of_date and (valid_to is null or as_of_date < valid_to)

with reported as (

    select
        version_id,
        fact_key,
        version_number,
        ticker,
        cik,
        metric,
        period_grain,
        period_start,
        period_end,
        value,
        valid_from,
        valid_to,
        is_current,
        is_restatement,
        is_tag_switch,
        is_scale_error,
        false as is_derived
    from {{ ref('int_fact_versions') }}
    where period_grain in ('annual', 'quarter', 'instant')

),

derived_q4 as (

    select
        version_id,
        fact_key,
        version_number,
        ticker,
        cik,
        metric,
        period_grain,
        period_start,
        period_end,
        value,
        valid_from,
        valid_to,
        is_current,
        is_restatement,
        false as is_tag_switch,
        false as is_scale_error,
        true  as is_derived
    from {{ ref('int_q4_derived_versions') }}

)

select * from reported
union all
select * from derived_q4
