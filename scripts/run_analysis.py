"""
Run a SQL file from analyses/ against the warehouse and print the full result.

dbt compiles the file first (so {{ ref() }} works), then DuckDB prints every column
in full, which `dbt show` truncates.

Usage:
    python scripts/run_analysis.py largest_restatements
    python scripts/run_analysis.py largest_restatements --rows 30
"""

import argparse
import subprocess
import sys
from pathlib import Path

import duckdb

ROOT = Path(__file__).resolve().parents[1]
COMPILED_DIR = ROOT / "target" / "compiled" / "point_in_time_fundamentals" / "analyses"
DB_PATH = ROOT / "data" / "warehouse.duckdb"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("name", help="analysis file name without .sql")
    parser.add_argument("--rows", type=int, default=20, help="maximum rows to print")
    parser.add_argument("--vars", default=None, help='dbt vars as JSON, e.g. \'{"ticker": "KO"}\'')
    args = parser.parse_args()

    if not (ROOT / "analyses" / f"{args.name}.sql").exists():
        sys.exit(f"No file analyses/{args.name}.sql")

    command = ["dbt", "compile", "--select", args.name]
    if args.vars:
        command += ["--vars", args.vars]
    result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
    if result.returncode != 0:
        print(result.stdout, result.stderr)
        sys.exit(result.returncode)

    sql = (COMPILED_DIR / f"{args.name}.sql").read_text()
    with duckdb.connect(str(DB_PATH), read_only=True) as con:
        con.sql(sql).show(max_rows=args.rows, max_width=250)


if __name__ == "__main__":
    main()
