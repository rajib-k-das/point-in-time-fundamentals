"""
Find XBRL tags a company actually uses, to close coverage gaps in seeds/concept_map.csv (decision 021).

Scans the downloaded SEC files (data/raw/<TICKER>.json) for us-gaap tags whose name matches a pattern,
and shows each tag's latest 10-K value and whether it is already mapped.

Usage:
    python scripts/discover_tags.py KO VZ --pattern "Debt|Borrowing"
    python scripts/discover_tags.py XOM --pattern "Revenue|NetIncome|ProfitLoss"
"""

import argparse
import csv
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def mapped_concepts() -> dict[str, str]:
    with open(ROOT / "seeds" / "concept_map.csv", newline="") as f:
        return {row["source_concept"]: row["metric"] for row in csv.DictReader(f)}


def latest_annual_value(facts: list[dict]) -> dict | None:
    annual = [f for f in facts if f.get("form", "").startswith("10-K")]
    return max(annual, key=lambda f: (f.get("end", ""), f.get("filed", ""))) if annual else None


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("tickers", nargs="+")
    parser.add_argument("--pattern", required=True, help="regular expression matched against tag names")
    parser.add_argument("--raw-dir", type=Path, default=ROOT / "data" / "raw")
    parser.add_argument("--since", default="2020-01-01", help="only show tags with a 10-K value ending on/after this date")
    args = parser.parse_args()

    mapped = mapped_concepts()
    pattern = re.compile(args.pattern, re.IGNORECASE)

    for ticker in args.tickers:
        paths = sorted(args.raw_dir.glob(f"{ticker.upper()}.json")) + sorted(args.raw_dir.glob(f"{ticker.upper()}__*.json"))
        if not paths:
            print(f"\n{ticker}: no files in {args.raw_dir}")
            continue
        facts: dict = {}
        for path in paths:  # current filer plus any predecessor CIKs (decision 025)
            for concept, body in json.loads(path.read_text()).get("facts", {}).get("us-gaap", {}).items():
                merged = facts.setdefault(concept, {"units": {}})
                for unit, values in body.get("units", {}).items():
                    merged["units"].setdefault(unit, []).extend(values)
        rows = []
        for concept, body in facts.items():
            if not pattern.search(concept):
                continue
            for unit, values in body.get("units", {}).items():
                latest = latest_annual_value(values)
                if latest and latest.get("end", "") >= args.since:
                    rows.append((concept, unit, latest))

        print(f"\n{ticker.upper()}: {len(rows)} matching tags with 10-K values since {args.since}")
        print(f"  {'tag':<75} {'mapped to':<28} {'latest 10-K period':<20} {'value':>16}")
        for concept, unit, latest in sorted(rows, key=lambda r: r[0]):
            period = f"{latest.get('start', '')[:7] + '..' if latest.get('start') else ''}{latest['end']}"
            value = latest["val"] / 1e9 if unit == "USD" else latest["val"] / 1e6
            suffix = "B" if unit == "USD" else "M sh" if unit == "shares" else unit
            print(f"  {concept:<75} {mapped.get(concept, '-'):<28} {period:<20} {value:>12,.2f} {suffix}")


if __name__ == "__main__":
    main()
