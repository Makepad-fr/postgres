#!/usr/bin/env python3
"""Report shape and counts for a failed Keycloak configuration fingerprint.

This is diagnostic only. The calling restore remains failed whenever a category
fingerprint differs; this program never grants an upgrade exception or prints
configuration values.
"""

from collections import Counter
import json
from pathlib import Path
import re
import sys


SAFE_NAME = re.compile(r"^[a-z][a-z0-9_]*$")
SLUGS = frozenset(("catwlk", "makepad", "runtrace", "vestiaire", "vif"))


def read_rows(root, slug, phase, table):
    path = root / f"{slug}-{phase}-{table}.jsonl"
    rows = [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines()]
    if not all(isinstance(row, dict) for row in rows):
        raise ValueError("fingerprint row is not an object")
    return rows


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


def compare(before, after):
    columns = sorted({key for row in before + after for key in row})
    keys = ["id"] if "id" in columns else [key for key in columns if key.endswith("_id") or key == "name"]
    if keys:
        def index(rows):
            return {tuple(canonical(row.get(key)) for key in keys): row for row in rows}

        left, right = index(before), index(after)
        if len(left) == len(before) and len(right) == len(after):
            return {
                "added_rows": len(right.keys() - left.keys()),
                "removed_rows": len(left.keys() - right.keys()),
                "changed_columns": sorted({
                    column for key in left.keys() & right.keys() for column in columns
                    if left[key].get(column) != right[key].get(column)
                }),
                "identity": "key",
            }
    left = Counter(canonical(row) for row in before)
    right = Counter(canonical(row) for row in after)
    return {
        "added_rows": sum((right - left).values()),
        "removed_rows": sum((left - right).values()),
        "changed_columns": [],
        "identity": "row",
    }


def diagnose(root, slug, category, tables):
    for table in tables:
        try:
            before = read_rows(root, slug, "before", table)
            after = read_rows(root, slug, "after", table)
            if before == after:
                continue
            result = compare(before, after)
            result.update({"database": slug, "category": category, "table": table,
                           "before_rows": len(before), "after_rows": len(after)})
        except (OSError, UnicodeError, ValueError, TypeError):
            result = {"database": slug, "category": category, "table": table,
                      "diagnostic": "row-shape-or-read-error"}
        print(json.dumps(result, sort_keys=True, separators=(",", ":")), file=sys.stderr)


def main():
    if len(sys.argv) != 5:
        raise SystemExit("usage: diagnose-keycloak-cohort-drift.py <runtime-dir> <slug> <category> <space-separated tables>")
    root = Path(sys.argv[1])
    slug, category, table_text = sys.argv[2:]
    tables = table_text.split()
    if not root.is_dir() or root.is_symlink() or slug not in SLUGS or not SAFE_NAME.fullmatch(category) \
            or not tables or any(not SAFE_NAME.fullmatch(table) for table in tables):
        raise SystemExit("invalid sanitized diagnostic inputs")
    diagnose(root, slug, category, tables)


if __name__ == "__main__":
    main()
