-- SCD Type 2 history of every reported fact.
--
-- A "fact" is one metric for one company and one period (e.g. AAPL revenue, FY2022).
-- The same fact is reported many times over the years. This model keeps one row per
-- MEANINGFULLY DIFFERENT value, with the window of time during which that value was the
-- latest public number:
--
--     valid_from <= as_of_date < valid_to     (valid_to is null for the current version)
--
-- Design decisions are numbered to match docs/decisions.md.

{% set tolerance = var('restatement_tolerance') %}
{% set log_tolerance = var('scale_error_log_tolerance') %}

with reports as (

    select
        md5(concat_ws('|', cik, metric, coalesce(cast(period_start as varchar), ''),
                      cast(period_end as varchar)))                as fact_key,
        ticker,
        cik,
        metric,
        period_grain,
        period_start,
        period_end,
        value,
        concept,
        form,
        accession_number,
        filed_date
    from {{ ref('int_facts__mapped') }}

),

-- Decision 010: when several filings report the same fact on the same day,
-- the latest accession number is that day's value.
daily_reports as (

    select *
    from reports
    qualify row_number() over (
        partition by fact_key, filed_date
        order by accession_number desc
    ) = 1

),

-- Decisions 006 and 007: a report starts a new version only if its value differs from
-- the previous report by more than the tolerance. Unchanged re-reports and rounding
-- noise (e.g. 114,070M -> 114,071M) confirm the existing version instead.
change_flags as (

    select
        *,
        lag(value) over (partition by fact_key order by filed_date) as previous_report_value
    from daily_reports

),

numbered_reports as (

    select
        *,
        cast(sum(
            case
                when previous_report_value is null then 1
                when greatest(abs(value), abs(previous_report_value)) = 0 then 0
                when abs(value - previous_report_value)
                     > {{ tolerance }} * greatest(abs(value), abs(previous_report_value)) then 1
                else 0
            end
        ) over (
            partition by fact_key
            order by filed_date
            rows between unbounded preceding and current row
        ) as integer) as version_number
    from change_flags

),

-- Collapse each run of equivalent reports into one version. The version's value is the
-- one first published; later equivalent reports only extend how long it was confirmed.
versions as (

    select
        fact_key,
        version_number,
        ticker,
        cik,
        metric,
        period_grain,
        period_start,
        period_end,
        arg_min(value, filed_date)            as value,
        arg_min(concept, filed_date)          as concept,
        arg_min(form, filed_date)             as form,
        arg_min(accession_number, filed_date) as accession_number,
        min(filed_date)                       as first_filed_date,
        max(filed_date)                       as last_confirmed_date,
        count(*)                              as times_reported
    from numbered_reports
    group by all

),

-- Decisions 009 and 011: a version becomes known the day AFTER it was filed
-- (filings often land after the market close), and validity windows are half-open.
windows as (

    select
        *,
        first_filed_date + 1                                                  as valid_from,
        lead(first_filed_date + 1) over fact_history                          as valid_to,
        lag(value) over fact_history                                          as previous_version_value,
        lag(concept) over fact_history                                        as previous_version_concept,
        last_value(value) over (
            fact_history rows between unbounded preceding and unbounded following
        )                                                                     as current_value
    from versions
    window fact_history as (partition by fact_key order by version_number)

),

-- Decision 008: a superseded value that differs from the current value by a factor of
-- about 1,000, 1,000,000 or 1,000,000,000 is almost certainly an XBRL scale-tagging error,
-- not an economic restatement. It is kept (it WAS published) but flagged.
scale_checks as (

    select
        *,
        case
            when value <> 0 and current_value <> 0
                then log10(abs(current_value) / abs(value))
        end as log10_ratio_to_current
    from windows

)

select
    md5(concat_ws('|', fact_key, version_number))                 as version_id,
    fact_key,
    version_number,
    ticker,
    cik,
    metric,
    period_grain,
    period_start,
    period_end,
    value,
    previous_version_value,
    case
        when previous_version_value is not null and previous_version_value <> 0
            then (value - previous_version_value) / abs(previous_version_value)
    end                                                           as change_vs_previous_pct,
    concept,
    previous_version_concept,
    form,
    accession_number,
    first_filed_date,
    last_confirmed_date,
    times_reported,
    valid_from,
    valid_to,
    valid_to is null                                              as is_current,
    version_number > 1                                            as is_restatement,
    -- Decision 013: the new value was reported under a different (equivalent) XBRL tag,
    -- e.g. revenue moving to the ASC 606 tag in 2018. Kept, but made visible.
    coalesce(concept <> previous_version_concept, false)          as is_tag_switch,
    coalesce(
        valid_to is not null
        and round(log10_ratio_to_current / 3) <> 0
        and abs(log10_ratio_to_current - 3 * round(log10_ratio_to_current / 3)) < {{ log_tolerance }},
        false
    )                                                             as is_scale_error
from scale_checks
