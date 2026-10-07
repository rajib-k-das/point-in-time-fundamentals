-- Monthly stock screen, built only from information public on each month-end (decision 017).
-- Grain: one row per company and month-end. Compares the latest annual report known on that
-- date (year t) with the prior fiscal year (t-1); year t-2 supplies beginning-of-year assets.

with years as (

    select
        *,
        row_number() over (partition by cik, as_of_date order by fiscal_year_end desc) as years_back
    from {{ ref('int_annual_fundamentals_monthly') }}
    where revenue is not null or net_income is not null

),

current_year as (select * from years where years_back = 1),
prior_year   as (select * from years where years_back = 2),
two_back     as (select * from years where years_back = 3),

-- Prior years only count if they are consecutive fiscal years (350-380 days apart).
aligned as (

    select
        c.*,
        p.fiscal_year_end           as prior_fiscal_year_end,
        p.revenue                   as prior_revenue,
        p.cost_of_revenue           as prior_cost_of_revenue,
        p.gross_profit              as prior_gross_profit,
        p.net_income                as prior_net_income,
        p.diluted_shares            as prior_diluted_shares,
        p.total_assets              as prior_total_assets,
        p.current_assets            as prior_current_assets,
        p.current_liabilities       as prior_current_liabilities,
        p.long_term_debt            as prior_long_term_debt,
        t.total_assets              as two_back_total_assets
    from current_year as c
    left join prior_year as p
        on  p.cik = c.cik
        and p.as_of_date = c.as_of_date
        and date_diff('day', p.fiscal_year_end, c.fiscal_year_end) between 350 and 380
    left join two_back as t
        on  t.cik = c.cik
        and t.as_of_date = c.as_of_date
        and date_diff('day', t.fiscal_year_end, p.fiscal_year_end) between 350 and 380

),

ratios as (

    select
        *,
        -- Decision 018: total debt = long-term debt including its current portion + short-term debt.
        coalesce(long_term_debt_incl_current, long_term_debt + coalesce(long_term_debt_current, 0))
            -- Decision 020: short-term borrowings when reported, otherwise commercial paper; never both,
            -- because companies may reclassify paper into long-term debt (double counting).
            + coalesce(short_term_borrowings, commercial_paper, 0)               as total_debt,

        net_income / nullif(prior_total_assets, 0)                             as roa,
        prior_net_income / nullif(two_back_total_assets, 0)                    as prior_roa,
        operating_cash_flow / nullif(prior_total_assets, 0)                    as cfo_to_assets,
        long_term_debt / nullif((total_assets + prior_total_assets) / 2, 0)    as leverage,
        prior_long_term_debt
            / nullif((prior_total_assets + two_back_total_assets) / 2, 0)      as prior_leverage,
        current_assets / nullif(current_liabilities, 0)                        as current_ratio,
        prior_current_assets / nullif(prior_current_liabilities, 0)            as prior_current_ratio,
        coalesce(gross_profit, revenue - cost_of_revenue) / nullif(revenue, 0) as gross_margin,
        coalesce(prior_gross_profit, prior_revenue - prior_cost_of_revenue)
            / nullif(prior_revenue, 0)                                         as prior_gross_margin,
        revenue / nullif(prior_total_assets, 0)                                as asset_turnover,
        prior_revenue / nullif(two_back_total_assets, 0)                       as prior_asset_turnover

    from aligned

),

signals as (

    select
        *,
        {{ compare_signal('roa', '>', '0') }}                                as f_roa_positive,
        {{ compare_signal('operating_cash_flow', '>', '0') }}                as f_cfo_positive,
        {{ compare_signal('roa', '>', 'prior_roa') }}                        as f_roa_improving,
        {{ compare_signal('cfo_to_assets', '>', 'roa') }}                    as f_cash_exceeds_earnings,
        {{ compare_signal('leverage', '<', 'prior_leverage') }}              as f_leverage_falling,
        {{ compare_signal('current_ratio', '>', 'prior_current_ratio') }}    as f_liquidity_improving,
        {{ compare_signal('diluted_shares', '<=', 'prior_diluted_shares') }} as f_no_dilution,
        {{ compare_signal('gross_margin', '>', 'prior_gross_margin') }}      as f_margin_improving,
        {{ compare_signal('asset_turnover', '>', 'prior_asset_turnover') }}  as f_turnover_improving
    from ratios

)

select
    signals.as_of_date,
    signals.ticker,
    signals.cik,
    company.company_name,
    company.sector,
    signals.fiscal_year_end,
    date_diff('day', signals.fiscal_year_end, signals.as_of_date)          as days_since_fiscal_year_end,

    signals.revenue,
    signals.net_income,
    signals.operating_cash_flow,
    signals.total_assets,
    signals.total_debt,
    signals.shareholders_equity,

    signals.gross_margin,
    signals.operating_income / nullif(signals.revenue, 0)                    as operating_margin,
    signals.net_income / nullif(signals.revenue, 0)                          as net_margin,
    (signals.operating_cash_flow - signals.capex) / nullif(signals.revenue, 0) as free_cash_flow_margin,
    signals.total_debt / nullif(signals.shareholders_equity, 0)              as debt_to_equity,
    -- Sloan accruals ratio: earnings not backed by cash, scaled by average assets.
    (signals.net_income - signals.operating_cash_flow)
        / nullif((signals.total_assets + signals.prior_total_assets) / 2, 0) as accruals_ratio,

    signals.f_roa_positive,
    signals.f_cfo_positive,
    signals.f_roa_improving,
    signals.f_cash_exceeds_earnings,
    signals.f_leverage_falling,
    signals.f_liquidity_improving,
    signals.f_no_dilution,
    signals.f_margin_improving,
    signals.f_turnover_improving,

    coalesce(f_roa_positive, 0) + coalesce(f_cfo_positive, 0) + coalesce(f_roa_improving, 0)
      + coalesce(f_cash_exceeds_earnings, 0) + coalesce(f_leverage_falling, 0)
      + coalesce(f_liquidity_improving, 0) + coalesce(f_no_dilution, 0)
      + coalesce(f_margin_improving, 0) + coalesce(f_turnover_improving, 0)  as f_score,

    (f_roa_positive is not null)::int + (f_cfo_positive is not null)::int
      + (f_roa_improving is not null)::int + (f_cash_exceeds_earnings is not null)::int
      + (f_leverage_falling is not null)::int + (f_liquidity_improving is not null)::int
      + (f_no_dilution is not null)::int + (f_margin_improving is not null)::int
      + (f_turnover_improving is not null)::int                             as f_score_signals_available

from signals
left join {{ ref('dim_company') }} as company
    on signals.ticker = company.ticker
