-- Versions of a fact must form an unbroken timeline: numbered 1, 2, 3...,
-- each window non-empty, and each version ending exactly where the next begins.
-- Any row returned is a gap or an overlap, which would break point-in-time lookups.
with ordered as (

    select
        *,
        row_number() over (partition by fact_key order by valid_from) as expected_version,
        lead(valid_from) over (partition by fact_key order by valid_from) as next_valid_from
    from {{ ref('int_fact_versions') }}

)

select *
from ordered
where version_number <> expected_version
   or (valid_to is not null and valid_to <= valid_from)
   or (next_valid_from is not null and valid_to is distinct from next_valid_from)
