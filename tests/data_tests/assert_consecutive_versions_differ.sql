-- A new version may only exist if its value moved by more than the restatement tolerance.
select *
from {{ ref('int_fact_versions') }}
where previous_version_value is not null
  and abs(value - previous_version_value)
      <= {{ var('restatement_tolerance') }} * greatest(abs(value), abs(previous_version_value))
