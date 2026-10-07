-- Derived fourth-quarter values, with point-in-time history.
--
-- Companies never file a Q4 report: the fourth quarter only exists inside the annual 10-K.
-- Q4 = annual value - nine-month year-to-date value (same fiscal year start).
--
-- Decision 014: both inputs are versioned, and either can be restated. Every pairing of an
-- annual version with a nine-month version is a candidate Q4 version, valid only while BOTH
-- inputs were the latest public numbers: the overlap of their two validity windows.
-- Decision 015: only income-statement and cash-flow amounts (duration metrics in USD).
-- Balance-sheet items are snapshots, and a weighted-average share count can't be subtracted.

with eligible_metrics as (

    select distinct metric
    from {{ ref('concept_map') }}
    where balance_type = 'duration'
      and unit = 'USD'

),

versions as (

    select versions.*
    from {{ ref('int_fact_versions') }} as versions
    inner join eligible_metrics using (metric)
    where not versions.is_scale_error

),

annual as (

    select * from versions where period_grain = 'annual'

),

nine_month as (

    select *
    from versions
    where period_grain = 'year_to_date'
      and date_diff('day', period_start, period_end) + 1 between 260 and 285

),

paired as (

    select
        annual.ticker,
        annual.cik,
        annual.metric,
        nine_month.period_end + 1                          as period_start,
        annual.period_end,
        annual.value - nine_month.value                    as value,
        annual.version_id                                  as annual_version_id,
        nine_month.version_id                              as nine_month_version_id,
        greatest(annual.valid_from, nine_month.valid_from) as valid_from,
        case
            when annual.valid_to is null     then nine_month.valid_to
            when nine_month.valid_to is null then annual.valid_to
            else least(annual.valid_to, nine_month.valid_to)
        end                                                as valid_to
    from annual
    inner join nine_month
        on  annual.cik          = nine_month.cik
        and annual.metric       = nine_month.metric
        and annual.period_start = nine_month.period_start
        and date_diff('day', nine_month.period_end, annual.period_end) between 80 and 100

),

overlapping as (

    -- Keep only pairs whose windows actually overlap.
    select *
    from paired
    where valid_to is null or valid_from < valid_to

),

-- If the company reported the fourth quarter directly, the reported value wins.
reported_quarters as (

    select distinct cik, metric, period_start, period_end
    from {{ ref('int_fact_versions') }}
    where period_grain = 'quarter'

),

derived as (

    select overlapping.*
    from overlapping
    anti join reported_quarters
        on  overlapping.cik          = reported_quarters.cik
        and overlapping.metric       = reported_quarters.metric
        and overlapping.period_start = reported_quarters.period_start
        and overlapping.period_end   = reported_quarters.period_end

),

numbered as (

    select
        *,
        md5(concat_ws('|', cik, metric, cast(period_start as varchar),
                      cast(period_end as varchar), 'q4'))            as fact_key,
        cast(row_number() over (
            partition by cik, metric, period_end
            order by valid_from
        ) as integer)                                                as version_number
    from derived

)

select
    md5(concat_ws('|', annual_version_id, nine_month_version_id))    as version_id,
    fact_key,
    version_number,
    ticker,
    cik,
    metric,
    'quarter'                                                        as period_grain,
    period_start,
    period_end,
    value,
    annual_version_id,
    nine_month_version_id,
    valid_from,
    valid_to,
    valid_to is null                                                 as is_current,
    version_number > 1                                               as is_restatement
from numbered
