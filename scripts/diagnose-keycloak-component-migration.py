#!/usr/bin/env python3
"""Print bounded component identifiers and column names from a failed isolated restore."""

import json
import pathlib
import re
import sys


SLUGS = frozenset(("catwlk", "makepad", "runtrace", "vestiaire", "vif"))
NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:/@ +()\-]{0,127}$")
SENSITIVE_LABEL = re.compile(r"secret|password|token|credential|private|api[-_]?key", re.IGNORECASE)
MAX_DIAGNOSTIC_ROWS = 20


def identifier(value):
    if isinstance(value, str) and NAME.fullmatch(value) and not SENSITIVE_LABEL.search(value):
        return value
    return "<redacted>"


def rows(root, slug, phase, table):
    path = root / f"{slug}-{phase}-{table}.jsonl"
    result = [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines()]
    if not all(isinstance(row, dict) for row in result):
        raise ValueError("invalid fingerprint rows")
    return result


def indexed(rows):
    result = {row["id"]: row for row in rows}
    if len(result) != len(rows):
        raise ValueError("duplicate fingerprint identity")
    return result


def delta(before, after, render):
    left, right = indexed(before), indexed(after)
    added = [render(row) for key, row in right.items() if key not in left]
    changed = []
    for key in left.keys() & right.keys():
        columns = sorted(column for column in left[key].keys() | right[key].keys()
                         if left[key].get(column) != right[key].get(column))
        if columns:
            changed.append({**render(right[key]), "changed_columns": columns})
    return added, changed


def bound(result, name, values):
    values.sort(key=lambda value: json.dumps(value, sort_keys=True))
    result[name + "_count"] = len(values)
    result[name] = values[:MAX_DIAGNOSTIC_ROWS]


def diagnose(root, slug):
    realms = {row["id"]: identifier(row.get("name")) for row in rows(root, slug, "after", "realm")}
    before_components = rows(root, slug, "before", "component")
    after_components = rows(root, slug, "after", "component")
    components = indexed(after_components)

    def component(row):
        return {"realm": realms.get(row.get("realm_id"), "<redacted>"),
                "name": identifier(row.get("name")),
                "provider_id": identifier(row.get("provider_id")),
                "provider_type": identifier(row.get("provider_type"))}

    def config(row):
        owner = components.get(row.get("component_id"), {})
        return {"realm": realms.get(owner.get("realm_id"), "<redacted>"),
                "component": identifier(owner.get("name")),
                "name": identifier(row.get("name"))}

    added_components, changed_components = delta(before_components, after_components, component)
    added_configs, changed_configs = delta(
        rows(root, slug, "before", "component_config"),
        rows(root, slug, "after", "component_config"), config
    )
    result = {"database": slug}
    bound(result, "added_components", added_components)
    bound(result, "changed_components", changed_components)
    bound(result, "added_component_config_keys", added_configs)
    bound(result, "changed_component_config_keys", changed_configs)
    return result


def main():
    if len(sys.argv) != 3 or sys.argv[2] not in SLUGS:
        raise SystemExit("usage: diagnose-keycloak-component-migration.py <runtime-dir> <database-slug>")
    root = pathlib.Path(sys.argv[1])
    if not root.is_dir() or root.is_symlink():
        raise SystemExit("invalid runtime directory")
    try:
        result = diagnose(root, sys.argv[2])
    except (KeyError, TypeError, ValueError, OSError, json.JSONDecodeError):
        raise SystemExit("Could not produce safe Keycloak component migration diagnostics") from None
    print(json.dumps(result, sort_keys=True, separators=(",", ":")), file=sys.stderr)


if __name__ == "__main__":
    main()
