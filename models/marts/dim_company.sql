-- One row per company with SEC data. Sector comes from the curated universe seed.
with filers as (

    select
        ticker,
        any_value(cik)                       as cik,
        arg_max(entity_name, filed_date)     as company_name
    from {{ ref('stg_sec__facts') }}
    group by ticker

)

select
    filers.ticker,
    filers.cik,
    filers.company_name,
    universe.sector
from filers
left join {{ ref('company_universe') }} as universe
    on filers.ticker = universe.ticker
