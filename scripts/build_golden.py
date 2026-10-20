#!/usr/bin/env python3
"""Convert eval/golden.csv to eval/golden.jsonl and validate it against eval/corpus/.

Errors report only the query id and the reason; query text is never printed,
because the golden set describes private screenshots.
"""

from __future__ import annotations

import argparse
import csv
import json
import sys
import unicodedata
from collections import Counter
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
REQUIRED_COLUMNS = ("id", "query", "relevant", "type", "lang")
VALID_TYPES = ("exact_text", "paraphrase", "visual", "multi")
VALID_LANGS = ("en", "es")


def nfc(text: str) -> str:
    # macOS can hand back filenames in NFD, so "ñ" from the CSV and from the
    # directory listing would differ byte-wise without normalizing both.
    return unicodedata.normalize("NFC", text)


def parse_relevant(raw: str) -> list[str]:
    return [nfc(part.strip()) for part in raw.split("|") if part.strip()]


def load_rows(csv_path: Path) -> list[dict[str, str]]:
    # utf-8-sig strips the BOM that spreadsheet exports often add.
    with csv_path.open(newline="", encoding="utf-8-sig") as f:
        reader = csv.DictReader(f)
        fieldnames = [name.strip() for name in reader.fieldnames or []]
        missing = [c for c in REQUIRED_COLUMNS if c not in fieldnames]
        if missing:
            sys.exit(f"error: {csv_path} is missing columns: {', '.join(missing)}")
        reader.fieldnames = fieldnames
        return [
            {key: (row.get(key) or "").strip() for key in REQUIRED_COLUMNS}
            for row in reader
        ]


def build_records(rows: list[dict[str, str]]) -> list[dict[str, object]]:
    return [
        {
            "id": row["id"],
            "query": row["query"],
            "relevant": parse_relevant(row["relevant"]),
            "type": row["type"],
            "lang": row["lang"],
        }
        for row in rows
    ]


def write_jsonl(records: list[dict[str, object]], out_path: Path) -> None:
    with out_path.open("w", encoding="utf-8") as f:
        for record in records:
            f.write(json.dumps(record, ensure_ascii=False) + "\n")


def validate(records: list[dict[str, object]], corpus_dir: Path) -> list[tuple[str, str]]:
    # Compare against the listing, not Path.exists(): the default macOS
    # filesystem is case-insensitive and would accept "IMG.png" for "img.png".
    corpus_files = {nfc(p.name) for p in corpus_dir.iterdir() if p.is_file()}
    corpus_by_lower = {name.casefold(): name for name in corpus_files}

    errors: list[tuple[str, str]] = []
    id_counts = Counter(str(r["id"]) for r in records)

    for index, record in enumerate(records, start=2):  # row 1 is the header
        qid = str(record["id"]) or f"<row {index}>"
        relevant = record["relevant"]
        assert isinstance(relevant, list)
        qtype = record["type"]

        if not record["id"]:
            errors.append((qid, "empty id"))
        elif id_counts[qid] > 1:
            errors.append((qid, f"duplicate id ({id_counts[qid]} rows)"))

        if qtype not in VALID_TYPES:
            errors.append((qid, f"invalid type {qtype!r}"))
        if record["lang"] not in VALID_LANGS:
            errors.append((qid, f"invalid lang {record['lang']!r}"))

        min_files = 2 if qtype == "multi" else 1
        if len(relevant) < min_files:
            errors.append((qid, f"type {qtype!r} needs at least {min_files} relevant file(s), has {len(relevant)}"))

        for name, count in Counter(relevant).items():
            if count > 1:
                errors.append((qid, f"relevant lists {name!r} {count} times"))

        for name in dict.fromkeys(relevant):
            if name in corpus_files:
                continue
            match = corpus_by_lower.get(name.casefold())
            if match:
                errors.append((qid, f"capitalization mismatch: {name!r} vs corpus {match!r}"))
            else:
                errors.append((qid, f"file not in corpus: {name!r}"))

    return errors


def print_counts(records: list[dict[str, object]]) -> None:
    by_type = Counter(str(r["type"]) for r in records)
    by_lang = Counter(str(r["lang"]) for r in records)
    by_both = Counter((str(r["type"]), str(r["lang"])) for r in records)

    print(f"queries: {len(records)}")
    print("\nby type:")
    for key, count in sorted(by_type.items()):
        print(f"  {key:<12} {count}")
    print("\nby lang:")
    for key, count in sorted(by_lang.items()):
        print(f"  {key:<12} {count}")
    print("\nby type x lang:")
    for (qtype, lang), count in sorted(by_both.items()):
        print(f"  {qtype:<12} {lang:<4} {count}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--csv", type=Path, default=REPO_ROOT / "eval" / "golden.csv")
    parser.add_argument("--corpus", type=Path, default=REPO_ROOT / "eval" / "corpus")
    parser.add_argument("--out", type=Path, default=REPO_ROOT / "eval" / "golden.jsonl")
    args = parser.parse_args()

    if not args.csv.is_file():
        sys.exit(f"error: {args.csv} not found")
    if not args.corpus.is_dir():
        sys.exit(f"error: {args.corpus} is not a directory")

    records = build_records(load_rows(args.csv))
    write_jsonl(records, args.out)
    print(f"wrote {len(records)} records to {args.out}\n")

    print_counts(records)

    errors = validate(records, args.corpus)
    if errors:
        print(f"\nFAILED: {len(errors)} problem(s)", file=sys.stderr)
        for qid, reason in errors:
            print(f"  {qid}: {reason}", file=sys.stderr)
        return 1

    print("\nall checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
