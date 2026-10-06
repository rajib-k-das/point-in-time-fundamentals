"""
Download SEC EDGAR "company facts" (XBRL financial data) for the company universe
and load every reported value -- including amended and re-reported ones -- into DuckDB.

Why keep every filing? The same number (e.g. FY2022 revenue) is reported in several
filings over time: the original 10-K, next year's 10-K as a comparative, and any
amendment (10-K/A). Keeping all of them, each with its `filed` date, is what makes a
point-in-time ("what did we know on date X?") warehouse possible downstream.

Usage:
    python ingest/fetch_sec_facts.py                 # download (cached) + load
    python ingest/fetch_sec_facts.py --refresh       # force re-download
    python ingest/fetch_sec_facts.py --offline --raw-dir tests/fixtures   # load local JSON only (used in CI)
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

import duckdb
import pandas as pd
import requests

ROOT = Path(__file__).resolve().parents[1]
SEEDS_DIR = ROOT / "seeds"
DB_PATH = ROOT / "data" / "warehouse.duckdb"
DEFAULT_RAW_DIR = ROOT / "data" / "raw"

TICKER_URL = "https://www.sec.gov/files/company_tickers.json"
FACTS_URL = "https://data.sec.gov/api/xbrl/companyfacts/CIK{cik}.json"
KEEP_FORMS = {"10-K", "10-K/A", "10-Q", "10-Q/A"}
SEC_REQUEST_PAUSE_SECONDS = 0.15  # SEC fair-access limit is 10 requests/second


def load_dotenv(path: Path) -> None:
    """Minimal .env reader so we don't need an extra dependency."""
    if not path.exists():
        return
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        os.environ.setdefault(key.strip(), value.strip().strip('"').strip("'"))


def read_seed(name: str) -> list[dict]:
    with open(SEEDS_DIR / name, newline="") as f:
        return list(csv.DictReader(f))


def sec_session() -> requests.Session:
    user_agent = os.environ.get("SEC_USER_AGENT", "")
    if not user_agent or "example.com" in user_agent:
        sys.exit("Set SEC_USER_AGENT in .env (your name + email). SEC blocks anonymous requests.")
    session = requests.Session()
    session.headers.update({"User-Agent": user_agent, "Accept-Encoding": "gzip, deflate"})
    return session


def ticker_to_cik(session: requests.Session) -> dict[str, str]:
    response = session.get(TICKER_URL, timeout=30)
    response.raise_for_status()
    return {row["ticker"]: str(row["cik_str"]).zfill(10) for row in response.json().values()}


def download_company_facts(raw_dir: Path, refresh: bool) -> None:
    session = sec_session()
    cik_map = ticker_to_cik(session)
    raw_dir.mkdir(parents=True, exist_ok=True)

    for company in read_seed("company_universe.csv"):
        ticker = company["ticker"]
        target = raw_dir / f"{ticker}.json"
        if target.exists() and not refresh:
            print(f"  cached   {ticker}")
            continue
        cik = cik_map.get(ticker)
        if cik is None:
            print(f"  MISSING  {ticker}: not found in SEC ticker list, skipping")
            continue
        response = session.get(FACTS_URL.format(cik=cik), timeout=60)
        response.raise_for_status()
        target.write_text(response.text)
        print(f"  saved    {ticker} (CIK {cik})")
        time.sleep(SEC_REQUEST_PAUSE_SECONDS)


def flatten_company_facts(payload: dict, ticker: str, wanted: dict[str, set[str]]) -> list[dict]:
    """Turn the nested SEC JSON into one row per reported value, for mapped concepts only."""
    rows = []
    us_gaap = payload.get("facts", {}).get("us-gaap", {})
    for concept, units_wanted in wanted.items():
        for unit, facts in us_gaap.get(concept, {}).get("units", {}).items():
            if unit not in units_wanted:
                continue
            for fact in facts:
                if fact.get("form") not in KEEP_FORMS:
                    continue
                rows.append(
                    {
                        "ticker": ticker,
                        "cik": str(payload.get("cik", "")).zfill(10),
                        "entity_name": payload.get("entityName"),
                        "taxonomy": "us-gaap",
                        "concept": concept,
                        "unit": unit,
                        "period_start": fact.get("start"),
                        "period_end": fact.get("end"),
                        "value": fact.get("val"),
                        "accession_number": fact.get("accn"),
                        "fiscal_year": fact.get("fy"),
                        "fiscal_period": fact.get("fp"),
                        "form": fact.get("form"),
                        "filed_date": fact.get("filed"),
                        "frame": fact.get("frame"),
                    }
                )
    return rows


def load_to_duckdb(raw_dir: Path) -> None:
    wanted: dict[str, set[str]] = {}
    for row in read_seed("concept_map.csv"):
        wanted.setdefault(row["source_concept"], set()).add(row["unit"])

    rows = []
    files = sorted(raw_dir.glob("*.json"))
    if not files:
        sys.exit(f"No JSON files found in {raw_dir}")
    for path in files:
        rows.extend(flatten_company_facts(json.loads(path.read_text()), path.stem, wanted))

    df = pd.DataFrame(rows)
    df["loaded_at"] = datetime.now(timezone.utc).replace(tzinfo=None)

    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    with duckdb.connect(str(DB_PATH)) as con:
        con.execute("create schema if not exists raw")
        con.register("facts_df", df)
        con.execute("create or replace table raw.sec_facts as select * from facts_df")
        count = con.execute("select count(*) from raw.sec_facts").fetchone()[0]
    print(f"Loaded {count:,} rows from {len(files)} companies into raw.sec_facts")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--raw-dir", type=Path, default=DEFAULT_RAW_DIR, help="where company JSON files live")
    parser.add_argument("--refresh", action="store_true", help="re-download files that are already cached")
    parser.add_argument("--offline", action="store_true", help="skip downloading; load existing JSON only")
    args = parser.parse_args()

    load_dotenv(ROOT / ".env")
    if not args.offline:
        print("Downloading company facts from SEC EDGAR...")
        download_company_facts(args.raw_dir, args.refresh)
    print("Loading into DuckDB...")
    load_to_duckdb(args.raw_dir)


if __name__ == "__main__":
    main()
