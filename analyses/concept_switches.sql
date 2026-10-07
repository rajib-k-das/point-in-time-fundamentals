-- Decision 012 check: are "restatements" real, or caused by our tag mapping?
-- If the new version was reported under a DIFFERENT XBRL tag than the version it replaced,
-- the change may come from the mapping (e.g. equity with vs. without non-controlling
-- interest) rather than from the company revising its number.
with restatements as (

    select
        metric,
        concept,
        lag(concept) over (partition by fact_key order by version_number) as previous_concept,
        is_restatement,
        is_scale_error,
        change_vs_previous_pct
    from {{ ref('int_fact_versions') }}

)

select
    metric,
    count(*)                                                       as restatements,
    count(*) filter (where concept <> previous_concept)            as tag_switches,
    round(100.0 * count(*) filter (where concept <> previous_concept) / count(*), 1)
                                                                   as pct_tag_switches,
    round(median(abs(change_vs_previous_pct)) filter (where concept <> previous_concept) * 100, 2)
                                                                   as median_pct_change_tag_switch,
    round(median(abs(change_vs_previous_pct)) filter (where concept = previous_concept) * 100, 2)
                                                                   as median_pct_change_same_tag
from restatements
where is_restatement
group by metric
order by tag_switches desc
