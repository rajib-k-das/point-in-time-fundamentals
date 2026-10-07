-- No two versions of the same value may be valid on the same date, including derived Q4 values,
-- or a point-in-time lookup could return two answers.
with ordered as (

    select
        *,
        lead(valid_from) over (partition by fact_key order by valid_from) as next_valid_from
    from {{ ref('fct_fundamentals') }}

)

select *
from ordered
where (valid_to is not null and valid_to <= valid_from)
   or (next_valid_from is not null and (valid_to is null or valid_to > next_valid_from))
