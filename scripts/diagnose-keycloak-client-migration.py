#!/usr/bin/env python3
"""Print bounded, non-secret identifiers for an isolated Keycloak client migration.

The fingerprint comparison remains authoritative. This diagnostic never grants
an exception: a changed fingerprint still fails the restore compatibility job.
"""

import json
import pathlib
import re
import sys


SLUGS = frozenset(("catwlk", "makepad", "runtrace", "vestiaire", "vif"))
NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:/@ +()\-]{0,127}$")
SENSITIVE_LABEL = re.compile(r"secret|password|token|credential|private|api[-_]?key", re.IGNORECASE)
TABLES = ("realm", "client", "client_scope", "default_client_scope", "protocol_mapper")
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


def additions(before, after, key):
    old = {key(row) for row in before}
    new = {key(row) for row in after}
    if len(old) != len(before) or len(new) != len(after):
        raise ValueError("duplicate fingerprint identity")
    return [row for row in after if key(row) not in old]


def diagnose(root, slug):
    snapshots = {table: (rows(root, slug, "before", table), rows(root, slug, "after", table)) for table in TABLES}
    realms = {row["id"]: identifier(row.get("name")) for row in snapshots["realm"][1]}
    scopes = {row["id"]: row for row in snapshots["client_scope"][1]}
    clients = {row["id"]: row for row in snapshots["client"][1]}
    result = {"database": slug}

    added_scopes = additions(*snapshots["client_scope"], lambda row: row["id"])
    result["added_client_scopes"] = sorted(
        ({"realm": realms.get(row.get("realm_id"), "<redacted>"),
          "name": identifier(row.get("name")),
          "protocol": identifier(row.get("protocol"))} for row in added_scopes),
        key=lambda row: (row["realm"], row["name"], row["protocol"]),
    )

    added_defaults = additions(*snapshots["default_client_scope"],
                         lambda row: (row["realm_id"], row["scope_id"]))
    result["added_default_client_scopes"] = sorted(
        ({"realm": realms.get(row.get("realm_id"), "<redacted>"),
          "scope": identifier(scopes.get(row.get("scope_id"), {}).get("name")),
          "default": row.get("default_scope") is True} for row in added_defaults),
        key=lambda row: (row["realm"], row["scope"], row["default"]),
    )

    added_mappers = additions(*snapshots["protocol_mapper"], lambda row: row["id"])
    mappers = []
    for row in added_mappers:
        scope = scopes.get(row.get("client_scope_id"), {})
        client = clients.get(row.get("client_id"), {})
        owner = scope or client
        mappers.append({
            "realm": realms.get(owner.get("realm_id"), "<redacted>"),
            "scope": identifier(scope.get("name")) if scope else None,
            "client": identifier(client.get("client_id")) if client else None,
            "name": identifier(row.get("name")),
            "protocol": identifier(row.get("protocol")),
            "mapper_type": identifier(row.get("protocol_mapper_name")),
        })
    result["added_protocol_mappers"] = sorted(
        mappers, key=lambda row: (row["realm"], row["scope"] or "", row["client"] or "", row["name"])
    )
    for table in ("added_client_scopes", "added_default_client_scopes", "added_protocol_mappers"):
        result[table + "_count"] = len(result[table])
        result[table] = result[table][:MAX_DIAGNOSTIC_ROWS]
    return result


def main():
    if len(sys.argv) != 3 or sys.argv[2] not in SLUGS:
        raise SystemExit("usage: diagnose-keycloak-client-migration.py <runtime-dir> <database-slug>")
    root = pathlib.Path(sys.argv[1])
    if not root.is_dir() or root.is_symlink():
        raise SystemExit("invalid runtime directory")
    try:
        result = diagnose(root, sys.argv[2])
    except (KeyError, TypeError, ValueError, OSError, json.JSONDecodeError):
        raise SystemExit("Could not produce safe Keycloak client migration diagnostics") from None
    print(json.dumps(result, sort_keys=True, separators=(",", ":")), file=sys.stderr)


if __name__ == "__main__":
    main()
