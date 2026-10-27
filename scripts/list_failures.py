#!/usr/bin/env python3
"""Write failures.csv for an eval run: one row per query that missed hit@5, for labelling by hand.

Prints only the number of failures. Errors name a query id or line number, never query text,
because the golden set describes private screenshots.
"""

from __future__ import annotations

import argparse
import csv
import json
import sys
from pathlib import Path

COLUMNS = ("id", "type", "lang", "query", "relevant", "top5", "category", "notes")


def read_jsonl(path: Path) -> list[dict[str, object]]:
    records: list[dict[str, object]] = []
    with path.open(encoding="utf-8") as f:
        for number, line in enumerate(f, start=1):
            if not line.strip():
                continue
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                sys.exit(f"error: {path} line {number} isn't valid JSON")
            if not isinstance(record, dict):
                sys.exit(f"error: {path} line {number} isn't a JSON object")
            records.append(record)
    return records


def load_golden(path: Path) -> dict[str, dict[str, object]]:
    golden: dict[str, dict[str, object]] = {}
    for record in read_jsonl(path):
        golden[str(record.get("id", ""))] = record
    return golden


def join_list(value: object) -> str:
    # "|" matches how golden.csv lists relevant files, so the CSV reads the same way.
    return "|".join(str(item) for item in value) if isinstance(value, list) else ""


def find_failures(per_query: list[dict[str, object]], golden: dict[str, dict[str, object]]) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []
    for result in per_query:
        qid = str(result.get("id", ""))
        hit = result.get("hit")
        if not isinstance(hit, bool):
            sys.exit(f"error: per_query.jsonl row for {qid!r} has no true/false hit")
        if hit:
            continue
        query = golden.get(qid)
        if query is None:
            sys.exit(f"error: query {qid!r} is in per_query.jsonl but not in the golden set")
        failures.append({
            "id": qid,
            "type": str(query.get("type", "")),
            "lang": str(query.get("lang", "")),
            "query": str(query.get("query", "")),
            "relevant": join_list(query.get("relevant")),
            "top5": join_list(result.get("top_5")),
            "category": "",
            "notes": "",
        })
    return failures


def write_csv(rows: list[dict[str, str]], out_path: Path) -> None:
    # "x" refuses an existing file, so notes typed into an earlier failures.csv are never lost.
    # utf-8-sig so spreadsheet apps show accents correctly.
    with out_path.open("x", newline="", encoding="utf-8-sig") as f:
        writer = csv.DictWriter(f, fieldnames=COLUMNS)
        writer.writeheader()
        writer.writerows(rows)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("results", type=Path, help="eval run folder holding per_query.jsonl")
    parser.add_argument("golden", type=Path, help="golden.jsonl")
    args = parser.parse_args()

    per_query_path = args.results / "per_query.jsonl"
    out_path = args.results / "failures.csv"
    if not per_query_path.is_file():
        sys.exit(f"error: {per_query_path} not found")
    if not args.golden.is_file():
        sys.exit(f"error: {args.golden} not found")
    if out_path.exists():
        sys.exit(f"error: {out_path} already exists; move it away first so its notes aren't overwritten")

    failures = find_failures(read_jsonl(per_query_path), load_golden(args.golden))
    write_csv(failures, out_path)
    print(len(failures))
    return 0


if __name__ == "__main__":
    sys.exit(main())
