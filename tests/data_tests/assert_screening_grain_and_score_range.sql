-- One row per company and month-end, and the score can't exceed the signals that were available.
select ticker, as_of_date, 'duplicate row' as problem
from {{ ref('fct_screening_monthly') }}
group by ticker, as_of_date
having count(*) > 1

union all

select ticker, as_of_date, 'score out of range' as problem
from {{ ref('fct_screening_monthly') }}
where f_score < 0
   or f_score > f_score_signals_available
   or f_score_signals_available > 9
