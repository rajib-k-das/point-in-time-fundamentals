-- Every fact must have exactly one current version.
select
    fact_key,
    count(*) filter (where is_current) as current_versions
from {{ ref('int_fact_versions') }}
group by fact_key
having count(*) filter (where is_current) <> 1
