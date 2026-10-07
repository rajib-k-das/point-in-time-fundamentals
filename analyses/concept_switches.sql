-- Decisions 012 and 013: how many restatements came with a change of XBRL tag?
-- After decision 012, the remaining tag switches are between equivalent tags (e.g. revenue
-- moving to the ASC 606 tag), so they reflect real re-presentations, not mapping errors.
select
    metric,
    count(*)                                                         as restatements,
    count(*) filter (where is_tag_switch)                            as tag_switches,
    round(100.0 * count(*) filter (where is_tag_switch) / count(*), 1) as pct_tag_switches,
    round(median(abs(change_vs_previous_pct)) filter (where is_tag_switch) * 100, 2)
                                                                     as median_pct_change_tag_switch,
    round(median(abs(change_vs_previous_pct)) filter (where not is_tag_switch) * 100, 2)
                                                                     as median_pct_change_same_tag
from {{ ref('int_fact_versions') }}
where is_restatement
group by metric
order by tag_switches desc, restatements desc
