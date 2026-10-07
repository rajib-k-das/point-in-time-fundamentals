-- Decision 012: every tag under one metric must be interchangeable. Each metric needs a single
-- unit and period type (a balance-sheet "instant" can't share a metric with a "duration"),
-- and no two tags may share a priority, or tie-breaking would be arbitrary.
select metric, 'mixed unit or balance type' as problem
from {{ ref('concept_map') }}
group by metric
having count(distinct unit) > 1 or count(distinct balance_type) > 1

union all

select metric, 'duplicate priority ' || priority as problem
from {{ ref('concept_map') }}
group by metric, priority
having count(*) > 1
