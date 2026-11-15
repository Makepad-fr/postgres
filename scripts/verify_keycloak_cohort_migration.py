#!/usr/bin/env python3
"""Draft fail-closed verifier for the reviewed Keycloak 26.8.2 cohort migration.

Input is the isolated restore job's private whole-row JSONL snapshots. This
module reports only a small status object; it never prints row contents.
"""

from __future__ import annotations

import argparse
import collections
import hashlib
import json
from pathlib import Path


TABLES = frozenset(
    """realm realm_attribute realm_default_groups realm_enabled_event_types
    realm_events_listeners realm_localizations realm_required_credential
    realm_smtp_config realm_supported_locales authentication_flow
    authentication_execution authenticator_config authenticator_config_entry
    keycloak_role role_attribute composite_role scope_mapping client
    client_attributes client_auth_flow_bindings redirect_uris web_origins
    client_scope client_scope_attributes client_scope_client
    client_scope_role_mapping default_client_scope protocol_mapper
    protocol_mapper_config identity_provider identity_provider_config
    identity_provider_mapper idp_mapper_config component component_config
    required_action_provider""".split()
)
COHORT_VARIANTS = {
    "catwlk": "legacy-26.5.7",
    "makepad": "legacy-26.5.7",
    "runtrace": "legacy-26.5.7",
    "vestiaire": "legacy-26.5.7",
    "vif": "vif-26.7.3",
}
COHORT_REALMS = {
    "catwlk": {"master", "catwlk"},
    "makepad": {"master", "makepad", "makepad-scan", "mendloo-pilot"},
    "runtrace": {"master", "runtrace"},
    "vestiaire": {"master", "vestiaire"},
    "vif": {"master", "vif"},
}


def priority_changes(*realms: str) -> dict[tuple[str, str], tuple[int, int]]:
    return {(realm, alias): pair for realm in realms for alias, pair in (
        ("CONFIGURE_TOTP", (10, 54)), ("UPDATE_PASSWORD", (30, 57)))}


PRIORITY_CHANGES = {
    "catwlk": priority_changes("master", "catwlk"),
    "makepad": priority_changes("master", "makepad", "makepad-scan", "mendloo-pilot"),
    "runtrace": {**priority_changes("master"),
                 ("runtrace", "CONFIGURE_TOTP"): (10, 51)},
    "vestiaire": priority_changes("master", "vestiaire"),
    "vif": {},
}

# Exact schema deltas from independent disposable upgrades of retained
# 26.5.7 Makepad and 26.7.3 Vif snapshots. Hashes describe ordered column
# names, PostgreSQL types, and nullability of newly introduced tables.
NEW_TABLES = {
    "legacy-26.5.7": {
        "auth_session": "4e7ae3891bb81853e708721fea0fd8454987d1d9ecfeb66aa5685d68c8e2e73f",
        "cluster_event": "e9f8b28597cd308b71fa962e4f89c503a8fb030f2f18cc1d6cf702c4413f4097",
        "fed_issued_ver_credential": "a01da6f0270a9ec625dc1d46cd3e349ee20ee4fac5b89438207ab6687d836594",
        "fed_user_ver_credential": "a9bfe6e0be3c932be1c562c4e69acb9f0f78994e0cc68976c003fce794e584d5",
        "issued_ver_credential": "86f2c28a8268ded9445b1135fe3a2d7f56e281e83ffa6d65849343b81394b17e",
        "login_failure": "33fe2aa287dec40fe1e7a15f653a6c01d1b08329bb1c66320d45b00840213b0f",
        "org_identity_provider": "f4e75eec50b9a09c8e9eb761e7931509d33ae58bb532915332deb62168ab95e0",
        "outbox_entry": "0a5714c3e0def4f50be71c7329d71650e1c02f27ef628d07071b251da4800a18",
        "root_auth_session": "37b4620f0cce17f1adbeb0a3d80c17b9e139090e0c06c75237d0edc40705a58e",
        "single_use_object": "32635442613050a1947c733c61af8cd3b4b9fbeeaac15c15bf29981f028b6697",
        "user_ver_credential": "5b738f3bfca51deae4463958b57d72b8abd48f43a038bd1cbc777578fdb511e1",
    },
    "vif-26.7.3": {
        "org_identity_provider": "f4e75eec50b9a09c8e9eb761e7931509d33ae58bb532915332deb62168ab95e0",
    },
}


def col(name: str, type_name: str, not_null: bool) -> dict:
    return {"name": name, "type": type_name, "not_null": not_null}


LEGACY_SCHEMA_COLUMNS = {
    "client": {"created_timestamp": col("created_timestamp", "bigint", False),
               "last_modified_timestamp": col("last_modified_timestamp", "bigint", False)},
    "fed_user_consent_cl_scope": {"parameter": col("parameter", "character varying(255)", True)},
    "jgroups_ping": {"coordinated_by": col("coordinated_by", "character varying(200)", False),
                     "last_update": col("last_update", "bigint", False)},
    "keycloak_group": {"created_timestamp": col("created_timestamp", "bigint", False),
                        "last_modified_timestamp": col("last_modified_timestamp", "bigint", False),
                        "org_id": col("org_id", "character varying(255)", False)},
    "offline_client_session": {"realm_id": col("realm_id", "character varying(36)", False)},
    "realm": {"display_name": col("display_name", "character varying(255)", False)},
    "user_consent_client_scope": {"parameter": col("parameter", "character varying(255)", True)},
    "user_entity": {"last_modified_timestamp": col("last_modified_timestamp", "bigint", False)},
}
COMMON_SCHEMA_COLUMNS = {
    "offline_user_session": {
        "last_session_refresh_coarse": col("last_session_refresh_coarse", "bigint", True),
        "session_bucket": col("session_bucket", "smallint", True),
    },
    "org_domain": {
        "auto_redirect": col("auto_redirect", "boolean", True),
        "idp_id": col("idp_id", "character varying(36)", False),
        "realm_id": col("realm_id", "character varying(255)", True),
    },
    "root_auth_session": {
        "created_on": col("created_on", "bigint", True),
        "session_bucket": col("session_bucket", "smallint", True),
        "timestamp_coarse": col("timestamp_coarse", "bigint", True),
    },
}
REMOVED_SCHEMA_COLUMNS = {
    "identity_provider": {"organization_id": col("organization_id", "character varying(255)", False)}
}


class MigrationError(ValueError):
    pass


def require(ok: bool, message: str) -> None:
    if not ok:
        raise MigrationError(message)


def encoded(row: dict) -> str:
    return json.dumps(row, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def bag(rows: list[dict]) -> collections.Counter[str]:
    return collections.Counter(encoded(row) for row in rows)


def same(label: str, left: list[dict], right: list[dict]) -> None:
    require(bag(left) == bag(right), f"{label}: existing configuration changed")


def additions(label: str, left: list[dict], right: list[dict]) -> list[dict]:
    old, new = bag(left), bag(right)
    require(not old - new, f"{label}: existing configuration removed or changed")
    return [json.loads(value) for value, count in (new - old).items() for _ in range(count)]


def index(rows: list[dict], key: str, label: str) -> dict[str, dict]:
    result = {}
    for row in rows:
        value = row.get(key)
        require(isinstance(value, str) and value and value not in result,
                f"{label}: missing or duplicate {key}")
        result[value] = row
    return result


def load(root: Path, slug: str, phase: str) -> dict[str, list[dict]]:
    rows = {}
    for table in TABLES:
        path = root / f"{slug}-{phase}-{table}.jsonl"
        require(path.is_file() and not path.is_symlink(), f"{phase}: missing {table}")
        parsed = [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines()]
        require(all(isinstance(row, dict) for row in parsed), f"{phase}: non-object {table} row")
        rows[table] = parsed
    return rows


def load_schema(root: Path, slug: str, phase: str) -> dict[str, list[dict]]:
    path = root / f"{slug}-{phase}-schema.json"
    require(path.is_file() and not path.is_symlink(), f"{phase}: missing schema inventory")
    return json.loads(path.read_text(encoding="utf-8"))


def load_extra(root: Path, slug: str, phase: str, table: str) -> list[dict]:
    path = root / f"{slug}-{phase}-{table}.jsonl"
    require(path.is_file() and not path.is_symlink(), f"{phase}: missing {table} data")
    rows = [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines()]
    require(all(isinstance(row, dict) for row in rows), f"{phase}: non-object {table} row")
    return rows


def validate_schema(value: dict[str, list[dict]], label: str) -> dict[str, list[dict]]:
    require(isinstance(value, dict) and value, f"{label}: invalid table inventory")
    for table, columns in value.items():
        require(isinstance(table, str) and table and isinstance(columns, list) and columns,
                f"{label}: invalid table or empty column list")
        names = set()
        for column in columns:
            require(isinstance(column, dict)
                    and set(column) == {"name", "type", "not_null"}
                    and isinstance(column["name"], str) and column["name"]
                    and isinstance(column["type"], str) and column["type"]
                    and type(column["not_null"]) is bool
                    and column["name"] not in names,
                    f"{label}: invalid or duplicate column inventory")
            names.add(column["name"])
    return value


def verify_schema(before: dict[str, list[dict]], after: dict[str, list[dict]],
                  variant: str) -> dict:
    require(variant in NEW_TABLES, "unsupported source schema variant")
    old = validate_schema(before, "before schema")
    new = validate_schema(after, "after schema")
    require(TABLES <= old.keys(), "before schema omits fingerprinted table")
    require(TABLES <= new.keys(), "after schema omits fingerprinted table")
    require(not old.keys() - new.keys(), "preexisting table removed")
    require(new.keys() - old.keys() == NEW_TABLES[variant].keys(),
            "new table set differs from reviewed migration")
    for table, digest in NEW_TABLES[variant].items():
        actual = hashlib.sha256(encoded(new[table]).encode()).hexdigest()
        require(actual == digest, f"{table}: new table columns differ from reviewed migration")

    added = {**{table: columns for table, columns in COMMON_SCHEMA_COLUMNS.items()
                if table != "root_auth_session"}}
    if variant == "legacy-26.5.7":
        added.update(LEGACY_SCHEMA_COLUMNS)
    else:
        added["root_auth_session"] = COMMON_SCHEMA_COLUMNS["root_auth_session"]
    for table in old.keys() & new.keys():
        old_columns = {column["name"]: column for column in old[table]}
        new_columns = {column["name"]: column for column in new[table]}
        expected_added = added.get(table, {})
        expected_removed = REMOVED_SCHEMA_COLUMNS.get(table, {})
        require(new_columns.keys() - old_columns.keys() == expected_added.keys()
                and old_columns.keys() - new_columns.keys() == expected_removed.keys(),
                f"{table}: column additions or removals differ from reviewed migration")
        require(all(new_columns[name] == expected for name, expected in expected_added.items())
                and all(old_columns[name] == expected for name, expected in expected_removed.items()),
                f"{table}: migrated column type or nullability differs")
        require(all(old_columns[name] == new_columns[name]
                    for name in old_columns.keys() & new_columns.keys()),
                f"{table}: preexisting column type or nullability changed")
    return {"added_tables": len(NEW_TABLES[variant]),
            "changed_existing_tables": len(added.keys() | REMOVED_SCHEMA_COLUMNS.keys())}


def expected_priority_move(slug: str, realm_name: str, alias: str) -> tuple[int, int] | None:
    return PRIORITY_CHANGES.get(slug, {}).get((realm_name, alias))


def verify_rows(before: dict[str, list[dict]], after: dict[str, list[dict]],
                variant: str, slug: str) -> dict:
    require(set(before) == TABLES and set(after) == TABLES, "required table set changed")
    require(variant in {"legacy-26.5.7", "vif-26.7.3"}, "unsupported source variant")
    require(COHORT_VARIANTS.get(slug) == variant, "cohort/source variant mismatch")
    legacy = variant == "legacy-26.5.7"

    old_realms = index(before["realm"], "id", "realm before")
    realms = index(after["realm"], "id", "realm after")
    require(set(old_realms) == set(realms), "realm set changed")
    realm_names = {rid: row.get("name") for rid, row in realms.items()}
    require(len(set(realm_names.values())) == len(realms)
            and set(realm_names.values()) == COHORT_REALMS[slug],
            "realm inventory differs from reviewed cohort")
    display_attrs = {}
    for row in before["realm_attribute"]:
        if row.get("name") == "displayName":
            key = row.get("realm_id")
            require(key in realms and key not in display_attrs, "duplicate displayName attribute")
            display_attrs[key] = row.get("value")
    for rid, old in old_realms.items():
        new = dict(realms[rid])
        if "display_name" not in old:
            require(legacy, "unexpected realm display_name schema migration")
            value = display_attrs.get(rid)
            require(value is None or (isinstance(value, str) and len(value) <= 255),
                    "displayName is too long or invalid")
            require(new.pop("display_name", object()) == value,
                    "realm displayName was not moved exactly")
        require(old == new, "preexisting realm value changed")
    expected_attrs = [row for row in before["realm_attribute"]
                      if not (legacy and row.get("name") == "displayName")]
    same("realm_attribute", expected_attrs, after["realm_attribute"])

    old_clients = index(before["client"], "id", "client before")
    clients = index(after["client"], "id", "client after")
    require(set(old_clients) == set(clients), "preexisting client set changed")
    for cid, old in old_clients.items():
        new = dict(clients[cid])
        for col in ("created_timestamp", "last_modified_timestamp"):
            if col not in old:
                require(legacy and new.pop(col, object()) is None,
                        f"client {col} migration changed an existing value")
        require(old == new, "preexisting client value changed")

    old_actions = {(r.get("realm_id"), r.get("alias")): r
                   for r in before["required_action_provider"]}
    new_actions = {(r.get("realm_id"), r.get("alias")): r
                   for r in after["required_action_provider"]}
    require(len(old_actions) == len(before["required_action_provider"])
            and len(new_actions) == len(after["required_action_provider"])
            and set(old_actions) == set(new_actions), "required action set changed")
    observed_priority_changes = {}
    for key, old in old_actions.items():
        new = dict(new_actions[key])
        if old.get("priority") != new.get("priority"):
            changed_key = (realm_names.get(key[0]), key[1])
            expected = expected_priority_move(slug, *changed_key)
            observed_priority_changes[changed_key] = (old.get("priority"), new.get("priority"))
            require(legacy and observed_priority_changes[changed_key] == expected,
                    "unexpected required-action priority change")
            new["priority"] = old["priority"]
        require(old == new, "required action changed beyond reviewed priority move")
    require(observed_priority_changes == PRIORITY_CHANGES[slug],
            "required-action priority migration is incomplete or unreviewed")

    scope_rows = additions("client_scope", before["client_scope"], after["client_scope"])
    expected_names = {"kc-admin-api"}
    if legacy:
        expected_names.add("AuthnContextClassRef")
    expected_scopes = {(rid, name) for rid in realms for name in expected_names}
    added_scopes = {}
    scope_templates = {
        "kc-admin-api": {
            "name": "kc-admin-api",
            "protocol": "openid-connect",
            "description": "Grants access to the Keycloak Admin REST API by adding its required audience to the token",
        },
        "AuthnContextClassRef": {
            "name": "AuthnContextClassRef",
            "protocol": "saml",
            "description": "AuthnContextClassRef Level of Authentiation",
        },
    }
    for row in scope_rows:
        key = (row.get("realm_id"), row.get("name"))
        require(key in expected_scopes and key not in added_scopes,
                "unknown or duplicate built-in client scope")
        require(set(row) == {"id", "name", "realm_id", "description", "protocol"}
                and {name: value for name, value in row.items() if name not in {"id", "realm_id"}}
                == scope_templates[key[1]], "built-in client scope fields drifted")
        added_scopes[key] = row
    require(set(added_scopes) == expected_scopes, "missing expected built-in client scope")
    scopes_by_id = index(after["client_scope"], "id", "client_scope after")

    scope_attrs = additions("client_scope_attributes", before["client_scope_attributes"],
                            after["client_scope_attributes"])
    expected_attrs = {(rid, name, val) for rid in realms for name, val in
                      (("display.on.consent.screen", "false"),
                       ("include.in.token.scope", "true"))}
    actual_attrs = []
    for row in scope_attrs:
        scope = scopes_by_id.get(row.get("scope_id"), {})
        require(set(row) == {"scope_id", "name", "value"}
                and scope.get("name") == "kc-admin-api",
                "scope attribute added outside kc-admin-api or with extra fields")
        actual_attrs.append((scope.get("realm_id"), row.get("name"), row.get("value")))
    require(len(actual_attrs) == len(expected_attrs) and set(actual_attrs) == expected_attrs,
            "kc-admin-api scope attributes differ from reviewed migration")

    client_by_realm_name = {}
    for client in clients.values():
        key = (client.get("realm_id"), client.get("client_id"))
        require(key not in client_by_realm_name,
                "duplicate per-realm client identifier")
        client_by_realm_name[key] = client["id"]
    bindings = additions("client_scope_client", before["client_scope_client"],
                         after["client_scope_client"])
    expected_bindings = {(rid, built_in) for rid in realms
                         for built_in in ("admin-cli", "security-admin-console")}
    actual_bindings = []
    for row in bindings:
        scope = scopes_by_id.get(row.get("scope_id"), {})
        client = clients.get(row.get("client_id"), {})
        require(set(row) == {"client_id", "scope_id", "default_scope"}
                and scope.get("name") == "kc-admin-api" and row.get("default_scope") is True,
                "unexpected client scope binding")
        require(client.get("realm_id") == scope.get("realm_id"),
                "admin scope attached across realms")
        actual_bindings.append((scope.get("realm_id"), client.get("client_id")))
    require(len(actual_bindings) == len(expected_bindings)
            and set(actual_bindings) == expected_bindings,
            "admin scope not bound to exact built-in clients")

    default_scopes = additions("default_client_scope", before["default_client_scope"],
                               after["default_client_scope"])
    expected_default = set(realms) if legacy else set()
    actual_default = []
    for row in default_scopes:
        scope = scopes_by_id.get(row.get("scope_id"), {})
        require(set(row) == {"realm_id", "scope_id", "default_scope"}
                and scope.get("name") == "AuthnContextClassRef" and row.get("default_scope") is True,
                "unexpected realm default scope")
        require(scope.get("realm_id") == row.get("realm_id"), "cross-realm default scope")
        actual_default.append(row.get("realm_id"))
    require(len(actual_default) == len(expected_default)
            and set(actual_default) == expected_default,
            "realm default scope migration differs")

    mapper_rows = additions("protocol_mapper", before["protocol_mapper"],
                            after["protocol_mapper"])
    expected_mappers = {("kc-admin-api", "admin-api-audience", "openid-connect",
                         "oidc-admin-api-audience-mapper")}
    if legacy:
        expected_mappers.add(("AuthnContextClassRef", "AuthnContextClassRef", "saml",
                              "saml-authn-context-class-ref-mapper"))
    actual_mappers = []
    mapper_by_id = index(after["protocol_mapper"], "id", "protocol_mapper after")
    for row in mapper_rows:
        scope = scopes_by_id.get(row.get("client_scope_id"), {})
        signature = (scope.get("name"), row.get("name"), row.get("protocol"),
                     row.get("protocol_mapper_name"))
        require(set(row) == {"id", "name", "protocol", "protocol_mapper_name",
                             "client_id", "client_scope_id"}
                and signature in expected_mappers and row.get("client_id") is None,
                "unexpected built-in protocol mapper")
        actual_mappers.append((scope.get("realm_id"), signature))
    require(len(actual_mappers) == len(realms) * len(expected_mappers)
            and set(actual_mappers) == {(rid, sig) for rid in realms for sig in expected_mappers},
            "protocol mapper additions differ")
    mapper_config = additions("protocol_mapper_config", before["protocol_mapper_config"],
                              after["protocol_mapper_config"])
    expected_config = {"access.token.claim", "introspection.token.claim", "lightweight.claim"}
    actual_config = []
    for row in mapper_config:
        mapper = mapper_by_id.get(row.get("protocol_mapper_id"), {})
        scope = scopes_by_id.get(mapper.get("client_scope_id"), {})
        require(set(row) == {"protocol_mapper_id", "name", "value"}
                and mapper.get("name") == "admin-api-audience"
                and scope.get("name") == "kc-admin-api" and row.get("value") == "true",
                "unexpected admin audience mapper config")
        actual_config.append((scope.get("realm_id"), row.get("name")))
    require(len(actual_config) == len(realms) * len(expected_config)
            and set(actual_config) == {(rid, key) for rid in realms for key in expected_config},
            "admin audience mapper config keys differ")

    component_rows = additions("component", before["component"], after["component"])
    policy_type = "org.keycloak.services.clientregistration.policy.ClientRegistrationPolicy"
    expected_components = {
        (rid, "Default Roles Disabled", "default-roles", "anonymous"): 1 for rid in realms
    }
    expected_components.update({
        (rid, "Default Roles Disabled", "default-roles", "authenticated"): 1 for rid in realms
    })
    expected_components.update({
        (rid, "Full Scope Disabled", "scope", "authenticated"): 1 for rid in realms
    })
    actual_components = collections.Counter()
    for row in component_rows:
        require(set(row) == {"id", "name", "parent_id", "provider_id", "provider_type",
                             "realm_id", "sub_type"}
                and row.get("provider_type") == policy_type
                and row.get("parent_id") == row.get("realm_id")
                and row.get("realm_id") in realms,
                "unexpected client registration policy component")
        actual_components[(row.get("realm_id"), row.get("name"), row.get("provider_id"),
                           row.get("sub_type"))] += 1
    require(dict(actual_components) == expected_components,
            "client registration policy additions differ")

    added_roles = additions("keycloak_role", before["keycloak_role"], after["keycloak_role"])
    role_by_id = index(after["keycloak_role"], "id", "keycloak_role after")
    if legacy:
        master_id = next(rid for rid, name in realm_names.items() if name == "master")
        role_clients = set()
        for rid, realm_name in realm_names.items():
            built_in = client_by_realm_name.get((master_id, f"{realm_name}-realm"))
            require(built_in is not None, "missing built-in cross-realm admin client")
            role_clients.add(built_in)
            if rid != master_id:
                management = client_by_realm_name.get((rid, "realm-management"))
                require(management is not None, "missing built-in realm-management client")
                role_clients.add(management)
        expected_roles = {(cid, name) for cid in role_clients
                          for name in ("query-organizations", "view-organizations", "manage-organizations")}
        actual_roles = []
        for row in added_roles:
            cid = row.get("client")
            require(set(row) == {"id", "client_realm_constraint", "client_role",
                                 "description", "name", "realm_id", "client", "realm"}
                    and cid in role_clients and row.get("client_role") is True
                    and row.get("realm_id") == clients[cid].get("realm_id")
                    and row.get("client_realm_constraint") == cid
                    and row.get("realm") is None
                    and row.get("description") == "${role_" + str(row.get("name")) + "}",
                    "organization role added to unexpected client or realm")
            actual_roles.append((cid, row.get("name")))
        require(len(actual_roles) == len(expected_roles) and set(actual_roles) == expected_roles,
                "organization role additions differ")
    else:
        require(not added_roles, "unexpected organization role addition for Vif variant")

    added_links = additions("composite_role", before["composite_role"],
                            after["composite_role"])
    if legacy:
        expected_links = set()
        master_id = next(rid for rid, name in realm_names.items() if name == "master")
        for cid in role_clients:
            org = {r.get("name"): r["id"] for r in role_by_id.values() if r.get("client") == cid
                   and r.get("name") in {"query-organizations", "view-organizations", "manage-organizations"}}
            require(set(org) == {"query-organizations", "view-organizations", "manage-organizations"},
                    "organization role graph is incomplete")
            client = clients[cid]
            if client.get("client_id") == "realm-management":
                parents = [r for r in role_by_id.values() if r.get("client") == cid
                           and r.get("name") == "realm-admin"]
            else:
                parents = [r for r in role_by_id.values() if r.get("client") is None
                           and r.get("realm_id") == master_id and r.get("name") == "admin"]
            require(len(parents) == 1, "built-in organization admin parent is missing")
            expected_links.update({(parents[0]["id"], org[name]) for name in org})
            expected_links.add((org["view-organizations"], org["query-organizations"]))
        require(all(set(r) == {"composite", "child_role"} for r in added_links),
                "organization composite link contains unexpected fields")
        actual_links = [(r.get("composite"), r.get("child_role")) for r in added_links]
        require(len(actual_links) == len(expected_links) and set(actual_links) == expected_links,
                "organization role composite links differ")
    else:
        require(not added_links, "unexpected organization composite link for Vif variant")

    old_idps = index(before["identity_provider"], "internal_id", "identity provider before")
    new_idps = index(after["identity_provider"], "internal_id", "identity provider after")
    require(set(old_idps) == set(new_idps), "identity provider set changed")
    for identifier, old in old_idps.items():
        normalized = dict(old)
        require("organization_id" in normalized
                and normalized.pop("organization_id") is None,
                "preexisting identity provider has an unreviewed organization link")
        require(normalized == new_idps[identifier],
                "preexisting identity provider changed beyond removal of NULL organization_id")

    handled = {"realm", "realm_attribute", "client", "required_action_provider",
               "client_scope", "client_scope_attributes", "client_scope_client",
               "default_client_scope", "protocol_mapper", "protocol_mapper_config",
               "component", "keycloak_role", "composite_role", "identity_provider"}
    for table in TABLES - handled:
        same(table, before[table], after[table])
    return {"result": "reviewed-keycloak-26.8.2-migration-only",
            "variant": variant, "realms": len(realms),
            "added_client_scopes": len(scope_rows),
            "added_policy_components": len(component_rows),
            "added_organization_roles": len(added_roles)}


def verify(before: dict[str, list[dict]], after: dict[str, list[dict]], variant: str,
           slug: str,
           before_schema: dict[str, list[dict]], after_schema: dict[str, list[dict]],
           org_domain_before: list[dict], org_domain_after: list[dict],
           org_identity_provider_after: list[dict]) -> dict:
    schema_result = verify_schema(before_schema, after_schema, variant)
    require(not org_domain_before and not org_domain_after,
            "organization domain routing rows require separate review")
    require(not org_identity_provider_after,
            "organization identity provider links require separate review")
    row_result = verify_rows(before, after, variant, slug)
    return {**row_result, **schema_result}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("private_runtime_dir", type=Path)
    parser.add_argument("slug")
    parser.add_argument("--variant", required=True, choices=("legacy-26.5.7", "vif-26.7.3"))
    args = parser.parse_args()
    require(COHORT_VARIANTS.get(args.slug) == args.variant,
            "cohort/source variant mismatch")
    result = verify(load(args.private_runtime_dir, args.slug, "before"),
                    load(args.private_runtime_dir, args.slug, "after"), args.variant, args.slug,
                    load_schema(args.private_runtime_dir, args.slug, "before"),
                    load_schema(args.private_runtime_dir, args.slug, "after"),
                    load_extra(args.private_runtime_dir, args.slug, "before", "org_domain"),
                    load_extra(args.private_runtime_dir, args.slug, "after", "org_domain"),
                    load_extra(args.private_runtime_dir, args.slug, "after", "org_identity_provider"))
    print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except MigrationError as exc:
        raise SystemExit(str(exc))
