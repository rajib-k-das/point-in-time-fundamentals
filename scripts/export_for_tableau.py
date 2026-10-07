"""
Export the dashboard data from the warehouse to CSV files for Tableau Public.

Run after `dbt build`. Writes three files to exports/:

  screen_latest.csv           Today's screen: one row per company at the latest month-end.
  screen_history.csv          Every company at every month-end, with WHY the F-score changed:
                              a new annual report, or revised data for the same fiscal year
                              (a restatement, a correction, or a value filed late).
  restatements_by_metric.csv  Restatements per metric, split into genuine revisions,
                              equivalent-tag switches and corrections of XBRL scale errors.

Usage:
    python scripts/export_for_tableau.py
"""

from pathlib import Path

import duckdb

ROOT = Path(__file__).resolve().parents[1]
DB_PATH = ROOT / "data" / "warehouse.duckdb"
EXPORT_DIR = ROOT / "exports"

SCREEN_COLUMNS = """
    ticker                                           as "Ticker",
    company_name                                     as "Company",
    coalesce(sector, 'Unassigned')                   as "Sector",
    as_of_date                                       as "As Of Date",
    fiscal_year_end                                  as "Fiscal Year End",
    f_score                                          as "F-Score",
    f_score_signals_available                        as "Signals Available",
    f_score_signals_available = 9                    as "Complete Score",
    round(gross_margin, 4)                           as "Gross Margin",
    round(operating_margin, 4)                       as "Operating Margin",
    round(net_margin, 4)                             as "Net Margin",
    round(free_cash_flow_margin, 4)                  as "FCF Margin",
    round(accruals_ratio, 4)                         as "Accruals Ratio",
    round(total_debt / 1e9, 2)                       as "Total Debt ($B)",
    total_debt_source                                as "Debt Source",
    round(debt_to_equity, 2)                         as "Debt to Equity",
    round(revenue / 1e9, 2)                          as "Revenue ($B)",
    net_income_basis                                 as "Net Income Basis"
"""

QUERIES = {
    "screen_latest": f"""
        select {SCREEN_COLUMNS}
        from marts.fct_screening_monthly
        where as_of_date = (select max(as_of_date) from marts.fct_screening_monthly)
        order by f_score desc, ticker
    """,
    "screen_history": f"""
        with history as (
            select
                *,
                lag(f_score)         over (partition by ticker order by as_of_date) as previous_f_score,
                lag(fiscal_year_end) over (partition by ticker order by as_of_date) as previous_fiscal_year_end
            from marts.fct_screening_monthly
        )
        select
            {SCREEN_COLUMNS},
            f_score - previous_f_score                       as "F-Score Change",
            case
                when previous_f_score is null or f_score = previous_f_score then 'No change'
                when fiscal_year_end <> previous_fiscal_year_end           then 'New annual report'
                else 'Revised data for same fiscal year'
            end                                              as "Change Reason"
        from history
        order by ticker, as_of_date
    """,
    "restatements_by_metric": """
        with versions as (
            select
                *,
                coalesce(lag(is_scale_error) over (partition by fact_key order by version_number), false)
                    as replaces_scale_error
            from intermediate.int_fact_versions
        )
        select
            metric                                                              as "Metric",
            count(distinct fact_key)                                            as "Facts",
            count(distinct fact_key) filter (where is_restatement)              as "Facts Restated",
            round(count(distinct fact_key) filter (where is_restatement)
                  / count(distinct fact_key), 4)                                as "Share Restated",
            count(*) filter (where is_restatement
                             and not is_tag_switch and not replaces_scale_error) as "Genuine Revisions",
            count(*) filter (where is_restatement and is_tag_switch)            as "Tag Switches",
            count(*) filter (where is_restatement and replaces_scale_error)     as "Scale Error Corrections"
        from versions
        group by metric
        order by "Facts Restated" desc
    """,
}


def main() -> None:
    EXPORT_DIR.mkdir(exist_ok=True)
    with duckdb.connect(str(DB_PATH), read_only=True) as con:
        for name, sql in QUERIES.items():
            target = EXPORT_DIR / f"{name}.csv"
            con.sql(sql).write_csv(str(target))
            rows = con.sql(f"select count(*) from read_csv_auto('{target}')").fetchone()[0]
            print(f"  wrote {target.relative_to(ROOT)}  ({rows:,} rows)")


if __name__ == "__main__":
    main()
