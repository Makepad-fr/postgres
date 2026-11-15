#!/usr/bin/env python3
"""Synthetic adversarial tests for the reviewed Keycloak migration predicate.

The fixtures deliberately contain no production row identifiers or values.
"""

from __future__ import annotations

import copy
import hashlib
import json
import sys
from pathlib import Path
from unittest.mock import patch
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from verify_keycloak_cohort_migration import (
    COHORT_REALMS, COHORT_VARIANTS, COMMON_SCHEMA_COLUMNS,
    CURRENT_CATWLK_VARIANT, CURRENT_VARIANTS, LEGACY_SCHEMA_COLUMNS,
    MigrationError, NEW_TABLES, REMOVED_SCHEMA_COLUMNS, TABLES,
    detect_catwlk_source_variant, detect_source_variant, expected_priority_move,
    verify, verify_rows, verify_schema,
)


ADMIN_SCOPE_DESCRIPTION = (
    "Grants access to the Keycloak Admin REST API by adding its required "
    "audience to the token"
)
SAML_SCOPE_DESCRIPTION = "AuthnContextClassRef Level of Authentiation"
POLICY_TYPE = "org.keycloak.services.clientregistration.policy.ClientRegistrationPolicy"


def cohort_for_variant(variant: str) -> str:
    return "catwlk" if variant == "legacy-26.5.7" else "vif"


def fixture(legacy: bool, legacy_slug: str = "catwlk") -> tuple[dict, dict, str]:
    before = {table: [] for table in TABLES}
    after = {table: [] for table in TABLES}
    variant = "legacy-26.5.7" if legacy else "vif-26.7.3"
    before["realm"] = [{"id": "realm-1", "name": "master"}]
    after["realm"] = [{"id": "realm-1", "name": "master", "display_name": "Synthetic"}]
    if legacy:
        before["realm_attribute"] = [
            {"realm_id": "realm-1", "name": "displayName", "value": "Synthetic"}
        ]
    else:
        before["realm"][0]["display_name"] = "Synthetic"

    built_in_clients = [("admin", "admin-cli"), ("console", "security-admin-console")]
    if legacy:
        built_in_clients.append(("realm-client", "master-realm"))
    for cid, name in built_in_clients:
        old = {"id": cid, "realm_id": "realm-1", "client_id": name,
               "enabled": True}
        new = dict(old)
        if legacy:
            new.update(created_timestamp=None, last_modified_timestamp=None)
        else:
            old.update(created_timestamp=None, last_modified_timestamp=None)
            new = dict(old)
        before["client"].append(old)
        after["client"].append(new)

    admin_scope = {"id": "scope-admin", "name": "kc-admin-api", "realm_id": "realm-1",
                   "description": ADMIN_SCOPE_DESCRIPTION, "protocol": "openid-connect"}
    after["client_scope"].append(admin_scope)
    after["client_scope_attributes"] += [
        {"scope_id": "scope-admin", "name": "display.on.consent.screen", "value": "false"},
        {"scope_id": "scope-admin", "name": "include.in.token.scope", "value": "true"},
    ]
    after["client_scope_client"] += [
        {"client_id": cid, "scope_id": "scope-admin", "default_scope": True}
        for cid in ("admin", "console")
    ]
    after["protocol_mapper"].append(
        {"id": "mapper-admin", "name": "admin-api-audience", "protocol": "openid-connect",
         "protocol_mapper_name": "oidc-admin-api-audience-mapper", "client_id": None,
         "client_scope_id": "scope-admin"}
    )
    after["protocol_mapper_config"] += [
        {"protocol_mapper_id": "mapper-admin", "name": name, "value": "true"}
        for name in ("access.token.claim", "introspection.token.claim", "lightweight.claim")
    ]
    after["component"] += [
        {"id": f"policy-{n}", "name": name, "parent_id": "realm-1",
         "provider_id": provider, "provider_type": POLICY_TYPE, "realm_id": "realm-1",
         "sub_type": sub_type}
        for n, (name, provider, sub_type) in enumerate((
            ("Default Roles Disabled", "default-roles", "anonymous"),
            ("Default Roles Disabled", "default-roles", "authenticated"),
            ("Full Scope Disabled", "scope", "authenticated"),
        ))
    ]

    if legacy:
        after["client_scope"].append(
            {"id": "scope-saml", "name": "AuthnContextClassRef", "realm_id": "realm-1",
             "description": SAML_SCOPE_DESCRIPTION, "protocol": "saml"}
        )
        after["default_client_scope"].append(
            {"realm_id": "realm-1", "scope_id": "scope-saml", "default_scope": True}
        )
        after["protocol_mapper"].append(
            {"id": "mapper-saml", "name": "AuthnContextClassRef", "protocol": "saml",
             "protocol_mapper_name": "saml-authn-context-class-ref-mapper", "client_id": None,
             "client_scope_id": "scope-saml"}
        )
        admin_role = {"id": "role-admin", "realm_id": "realm-1", "name": "admin",
                      "client": None}
        before["keycloak_role"].append(admin_role)
        after["keycloak_role"].append(dict(admin_role))
        for name in ("query-organizations", "view-organizations", "manage-organizations"):
            after["keycloak_role"].append(
                {"id": "role-" + name, "client_realm_constraint": "realm-client",
                 "client_role": True, "description": "${role_" + name + "}",
                 "name": name, "realm_id": "realm-1", "client": "realm-client",
                 "realm": None}
            )
            after["composite_role"].append(
                {"composite": "role-admin", "child_role": "role-" + name}
            )
        after["composite_role"].append(
            {"composite": "role-view-organizations", "child_role": "role-query-organizations"}
        )

    second_realm = legacy_slug if legacy else "vif"
    before["realm"].append({"id": "realm-2", "name": second_realm,
                            **({} if legacy else {"display_name": "Synthetic 2"})})
    after["realm"].append({"id": "realm-2", "name": second_realm,
                           "display_name": "Synthetic 2"})
    if legacy:
        before["realm_attribute"].append(
            {"realm_id": "realm-2", "name": "displayName", "value": "Synthetic 2"}
        )
    for cid, name in (("admin-2", "admin-cli"),
                      ("console-2", "security-admin-console")):
        old = {"id": cid, "realm_id": "realm-2", "client_id": name,
               "enabled": True}
        new = dict(old)
        if legacy:
            new.update(created_timestamp=None, last_modified_timestamp=None)
        else:
            old.update(created_timestamp=None, last_modified_timestamp=None)
            new = dict(old)
        before["client"].append(old)
        after["client"].append(new)
    after["client_scope"].append(
        {"id": "scope-admin-2", "name": "kc-admin-api", "realm_id": "realm-2",
         "description": ADMIN_SCOPE_DESCRIPTION, "protocol": "openid-connect"}
    )
    after["client_scope_attributes"] += [
        {"scope_id": "scope-admin-2", "name": "display.on.consent.screen", "value": "false"},
        {"scope_id": "scope-admin-2", "name": "include.in.token.scope", "value": "true"},
    ]
    after["client_scope_client"] += [
        {"client_id": cid, "scope_id": "scope-admin-2", "default_scope": True}
        for cid in ("admin-2", "console-2")
    ]
    after["protocol_mapper"].append(
        {"id": "mapper-admin-2", "name": "admin-api-audience", "protocol": "openid-connect",
         "protocol_mapper_name": "oidc-admin-api-audience-mapper", "client_id": None,
         "client_scope_id": "scope-admin-2"}
    )
    after["protocol_mapper_config"] += [
        {"protocol_mapper_id": "mapper-admin-2", "name": name, "value": "true"}
        for name in ("access.token.claim", "introspection.token.claim", "lightweight.claim")
    ]
    after["component"] += [
        {"id": f"policy-2-{n}", "name": name, "parent_id": "realm-2",
         "provider_id": provider, "provider_type": POLICY_TYPE, "realm_id": "realm-2",
         "sub_type": sub_type}
        for n, (name, provider, sub_type) in enumerate((
            ("Default Roles Disabled", "default-roles", "anonymous"),
            ("Default Roles Disabled", "default-roles", "authenticated"),
            ("Full Scope Disabled", "scope", "authenticated"),
        ))
    ]
    if legacy:
        after["client_scope"].append(
            {"id": "scope-saml-2", "name": "AuthnContextClassRef",
             "realm_id": "realm-2", "description": SAML_SCOPE_DESCRIPTION,
             "protocol": "saml"}
        )
        after["default_client_scope"].append(
            {"realm_id": "realm-2", "scope_id": "scope-saml-2", "default_scope": True}
        )
        after["protocol_mapper"].append(
            {"id": "mapper-saml-2", "name": "AuthnContextClassRef", "protocol": "saml",
             "protocol_mapper_name": "saml-authn-context-class-ref-mapper", "client_id": None,
             "client_scope_id": "scope-saml-2"}
        )
        for cid, client_name, realm_id in (
            ("cross-client", f"{legacy_slug}-realm", "realm-1"),
            ("management", "realm-management", "realm-2"),
        ):
            old = {"id": cid, "realm_id": realm_id, "client_id": client_name,
                   "enabled": True}
            before["client"].append(old)
            after["client"].append({**old, "created_timestamp": None,
                                    "last_modified_timestamp": None})
        realm_admin = {"id": "role-realm-admin", "realm_id": "realm-2",
                       "name": "realm-admin", "client": "management"}
        before["keycloak_role"].append(realm_admin)
        after["keycloak_role"].append(dict(realm_admin))
        for client_id, parent in (("cross-client", "role-admin"),
                                  ("management", "role-realm-admin")):
            for name in ("query-organizations", "view-organizations", "manage-organizations"):
                role_id = f"{client_id}-{name}"
                after["keycloak_role"].append(
                    {"id": role_id, "client_realm_constraint": client_id,
                     "client_role": True, "description": "${role_" + name + "}",
                     "name": name, "realm_id": "realm-1" if client_id == "cross-client" else "realm-2",
                     "client": client_id, "realm": None}
                )
                after["composite_role"].append({"composite": parent, "child_role": role_id})
            after["composite_role"].append(
                {"composite": f"{client_id}-view-organizations",
                 "child_role": f"{client_id}-query-organizations"}
            )
        for realm_id in ("realm-1", "realm-2"):
            for alias, old_priority, new_priority in (
                ("CONFIGURE_TOTP", 10, 54), ("UPDATE_PASSWORD", 30, 57)
            ):
                if legacy_slug == "runtrace" and realm_id == "realm-2":
                    new_priority = 51 if alias == "CONFIGURE_TOTP" else old_priority
                old = {"realm_id": realm_id, "alias": alias, "priority": old_priority}
                before["required_action_provider"].append(old)
                after["required_action_provider"].append(
                    {**old, "priority": new_priority})

    return before, after, variant


def synthetic_schema(legacy: bool) -> tuple[dict, dict, dict]:
    before = {table: [{"name": "synthetic_id", "type": "text", "not_null": True}]
              for table in TABLES}
    after = copy.deepcopy(before)
    for table, columns in COMMON_SCHEMA_COLUMNS.items():
        if legacy and table == "root_auth_session":
            continue
        before.setdefault(table, [{"name": "synthetic_id", "type": "text", "not_null": True}])
        after.setdefault(table, copy.deepcopy(before[table]))
        after[table].extend(columns.values())
    if legacy:
        for table, columns in LEGACY_SCHEMA_COLUMNS.items():
            before.setdefault(table, [{"name": "synthetic_id", "type": "text", "not_null": True}])
            after.setdefault(table, copy.deepcopy(before[table]))
            after[table].extend(columns.values())
    for table, columns in REMOVED_SCHEMA_COLUMNS.items():
        before[table].extend(columns.values())
    variant = "legacy-26.5.7" if legacy else "vif-26.7.3"
    digests = {}
    for table in NEW_TABLES[variant]:
        after[table] = [{"name": "synthetic_id", "type": "text", "not_null": True}]
        signature = json.dumps(after[table], sort_keys=True, separators=(",", ":"))
        digests[table] = hashlib.sha256(signature.encode()).hexdigest()
    return before, after, digests


class ReviewedMigrationTests(unittest.TestCase):
    def test_each_current_source_is_idempotent_and_bound_to_its_realm(self) -> None:
        for slug, predecessor in COHORT_VARIANTS.items():
            with self.subTest(slug=slug):
                legacy = predecessor == "legacy-26.5.7"
                old_schema, current_schema, digests = synthetic_schema(legacy)
                rows = {table: [] for table in TABLES}
                rows["realm"] = [
                    {"id": f"realm-{index}", "name": name}
                    for index, name in enumerate(sorted(COHORT_REALMS[slug]))
                ]
                with patch.dict(NEW_TABLES[predecessor], digests):
                    self.assertEqual(detect_source_variant(old_schema, slug), predecessor)
                    self.assertEqual(detect_source_variant(current_schema, slug),
                                     CURRENT_VARIANTS[slug])
                    result = verify(rows, copy.deepcopy(rows), CURRENT_VARIANTS[slug],
                                    slug, current_schema, copy.deepcopy(current_schema),
                                    [], [], [])
                    self.assertEqual(result["result"],
                                     "reviewed-keycloak-26.8.2-idempotence-only")
                    self.assertEqual(result["added_tables"], 0)
                    self.assertEqual(result["realms"], len(COHORT_REALMS[slug]))
                    changed = copy.deepcopy(rows)
                    changed["realm"][0]["name"] = "unreviewed"
                    with self.assertRaises(MigrationError):
                        verify(rows, changed, CURRENT_VARIANTS[slug], slug,
                               current_schema, current_schema, [], [], [])
                    wrong_shape = copy.deepcopy(current_schema)
                    table = next(iter(NEW_TABLES[predecessor]))
                    wrong_shape[table][0]["type"] = "integer"
                    with self.assertRaises(MigrationError):
                        detect_source_variant(wrong_shape, slug)

    def test_current_variants_reject_partial_or_cross_cohort_sources(self) -> None:
        _, current_schema, digests = synthetic_schema(True)
        with patch.dict(NEW_TABLES["legacy-26.5.7"], digests):
            partial = copy.deepcopy(current_schema)
            partial.pop("auth_session")
            for slug in ("catwlk", "makepad", "runtrace", "vestiaire"):
                with self.subTest(slug=slug):
                    with self.assertRaises(MigrationError):
                        detect_source_variant(partial, slug)
            rows = {table: [] for table in TABLES}
            rows["realm"] = [{"id": "master", "name": "master"},
                             {"id": "runtrace", "name": "runtrace"}]
            with self.assertRaises(MigrationError):
                verify(rows, rows, CURRENT_VARIANTS["runtrace"], "makepad",
                       current_schema, current_schema, [], [], [])

    def test_current_catwlk_source_is_idempotent_only(self) -> None:
        _, migrated_rows, _ = fixture(True)
        _, migrated_schema, digests = synthetic_schema(True)
        with patch.dict(NEW_TABLES["legacy-26.5.7"], digests):
            self.assertEqual(detect_catwlk_source_variant(migrated_schema),
                             CURRENT_CATWLK_VARIANT)
            result = verify(migrated_rows, copy.deepcopy(migrated_rows),
                            CURRENT_CATWLK_VARIANT, "catwlk", migrated_schema,
                            copy.deepcopy(migrated_schema), [], [], [])
            self.assertEqual(result["result"],
                             "reviewed-keycloak-26.8.2-idempotence-only")
            self.assertEqual(result["added_tables"], 0)
            with self.assertRaises(MigrationError):
                verify(migrated_rows, migrated_rows, CURRENT_CATWLK_VARIANT,
                       "makepad", migrated_schema, migrated_schema, [], [], [])

    def test_current_catwlk_rejects_partial_or_drifted_schema(self) -> None:
        _, migrated_rows, _ = fixture(True)
        legacy_schema, migrated_schema, digests = synthetic_schema(True)
        self.assertEqual(detect_catwlk_source_variant(legacy_schema),
                         "legacy-26.5.7")
        partial = copy.deepcopy(migrated_schema)
        partial.pop("auth_session")
        with self.assertRaises(MigrationError):
            detect_catwlk_source_variant(partial)
        with patch.dict(NEW_TABLES["legacy-26.5.7"], digests):
            for mutate in (
                lambda schema: schema["auth_session"][0].update(type="integer"),
                lambda schema: schema["client"].pop(),
                lambda schema: schema["identity_provider"].append(
                    REMOVED_SCHEMA_COLUMNS["identity_provider"]["organization_id"]),
            ):
                with self.subTest(mutation=mutate.__code__.co_firstlineno):
                    bad = copy.deepcopy(migrated_schema)
                    mutate(bad)
                    with self.assertRaises(MigrationError):
                        verify(migrated_rows, migrated_rows, CURRENT_CATWLK_VARIANT,
                               "catwlk", bad, bad, [], [], [])
            after_schema = copy.deepcopy(migrated_schema)
            after_schema["client"].append(
                {"name": "unexpected", "type": "text", "not_null": False})
            with self.assertRaises(MigrationError):
                verify(migrated_rows, migrated_rows, CURRENT_CATWLK_VARIANT,
                       "catwlk", migrated_schema, after_schema, [], [], [])

    def test_current_catwlk_rejects_configuration_or_routing_drift(self) -> None:
        _, migrated_rows, _ = fixture(True)
        _, migrated_schema, digests = synthetic_schema(True)
        with patch.dict(NEW_TABLES["legacy-26.5.7"], digests):
            changed_rows = copy.deepcopy(migrated_rows)
            changed_rows["client"][0]["enabled"] = False
            with self.assertRaises(MigrationError):
                verify(migrated_rows, changed_rows, CURRENT_CATWLK_VARIANT,
                       "catwlk", migrated_schema, migrated_schema, [], [], [])
            extra_realm = copy.deepcopy(migrated_rows)
            extra_realm["realm"].append({"id": "unexpected", "name": "other"})
            with self.assertRaises(MigrationError):
                verify(extra_realm, extra_realm, CURRENT_CATWLK_VARIANT,
                       "catwlk", migrated_schema, migrated_schema, [], [], [])
            with self.assertRaises(MigrationError):
                verify(migrated_rows, migrated_rows, CURRENT_CATWLK_VARIANT,
                       "catwlk", migrated_schema, migrated_schema,
                       [{"id": "unexpected-domain"}], [], [])

    def test_synthetic_variants_are_accepted(self) -> None:
        for legacy in (False, True):
            before, after, variant = fixture(legacy)
            self.assertEqual(verify_rows(before, after, variant, cohort_for_variant(variant))["result"],
                             "reviewed-keycloak-26.8.2-migration-only")

    def test_runtrace_priority_exception_requires_slug_and_realm(self) -> None:
        self.assertEqual(expected_priority_move("runtrace", "runtrace", "CONFIGURE_TOTP"),
                         (10, 51))
        self.assertIsNone(expected_priority_move("makepad", "runtrace", "CONFIGURE_TOTP"))
        self.assertEqual(expected_priority_move("runtrace", "master", "CONFIGURE_TOTP"),
                         (10, 54))
        self.assertIsNone(expected_priority_move("runtrace", "runtrace", "UPDATE_PASSWORD"))
        before, after, variant = fixture(True)
        with self.assertRaises(MigrationError):
            verify_rows(before, after, variant, "vif")
        before, after, variant = fixture(True, "runtrace")
        verify_rows(before, after, variant, "runtrace")
        with self.assertRaises(MigrationError):
            verify_rows(before, after, variant, "catwlk")
        action = next(row for row in after["required_action_provider"]
                      if row["realm_id"] == "realm-2"
                      and row["alias"] == "CONFIGURE_TOTP")
        action["priority"] = 54
        with self.assertRaises(MigrationError):
            verify_rows(before, after, variant, "runtrace")

    def test_existing_client_change_is_rejected(self) -> None:
        before, after, variant = fixture(False)
        after["client"][0]["enabled"] = False
        with self.assertRaises(MigrationError):
            verify_rows(before, after, variant, cohort_for_variant(variant))

    def test_existing_scope_binding_change_is_rejected(self) -> None:
        before, after, variant = fixture(False)
        old_binding = {"client_id": "admin", "scope_id": "old-scope", "default_scope": True}
        before["client_scope_client"].append(old_binding)
        after["client_scope_client"].append({**old_binding, "default_scope": False})
        with self.assertRaises(MigrationError):
            verify_rows(before, after, variant, cohort_for_variant(variant))

    def test_identity_provider_null_column_move_is_exact(self) -> None:
        before, after, variant = fixture(False)
        old = {"internal_id": "idp-1", "realm_id": "realm-1",
               "organization_id": None, "enabled": True}
        before["identity_provider"].append(old)
        after["identity_provider"].append({k: v for k, v in old.items()
                                            if k != "organization_id"})
        verify_rows(before, after, variant, cohort_for_variant(variant))
        before["identity_provider"][0]["organization_id"] = "org-1"
        with self.assertRaises(MigrationError):
            verify_rows(before, after, variant, cohort_for_variant(variant))
        before["identity_provider"][0]["organization_id"] = None
        after["identity_provider"][0]["enabled"] = False
        with self.assertRaises(MigrationError):
            verify_rows(before, after, variant, cohort_for_variant(variant))

    def test_duplicate_per_realm_client_identifier_is_rejected(self) -> None:
        before, after, variant = fixture(False)
        duplicate = copy.deepcopy(before["client"][0])
        duplicate["id"] = "another-admin-id"
        before["client"].append(duplicate)
        after["client"].append(copy.deepcopy(duplicate))
        with self.assertRaises(MigrationError):
            verify_rows(before, after, variant, cohort_for_variant(variant))

    def test_added_row_fields_are_exact(self) -> None:
        examples = (
            (False, "client_scope", "description", "More access"),
            (False, "client_scope_attributes", "value", "true"),
            (False, "client_scope_client", "default_scope", False),
            (False, "protocol_mapper", "client_id", "app-client"),
            (False, "protocol_mapper_config", "value", "false"),
            (False, "component", "provider_type", "OtherPolicy"),
            (True, "default_client_scope", "default_scope", False),
            (True, "keycloak_role", "client_role", False),
            (True, "composite_role", "child_role", "app-role"),
        )
        for legacy, table, field, value in examples:
            with self.subTest(table=table, field=field, legacy=legacy):
                before, after, variant = fixture(legacy)
                target = after[table][-1] if table == "keycloak_role" else after[table][0]
                target[field] = value
                with self.assertRaises(MigrationError):
                    verify_rows(before, after, variant, cohort_for_variant(variant))

    def test_extra_fields_on_each_added_row_type_are_rejected(self) -> None:
        for legacy, table in (
            (False, "client_scope"), (False, "client_scope_attributes"),
            (False, "client_scope_client"), (False, "protocol_mapper"),
            (False, "protocol_mapper_config"), (False, "component"),
            (True, "default_client_scope"), (True, "keycloak_role"),
            (True, "composite_role"),
        ):
            with self.subTest(table=table):
                before, after, variant = fixture(legacy)
                after[table][-1]["unreviewed_security_setting"] = "on"
                with self.assertRaises(MigrationError):
                    verify_rows(before, after, variant, cohort_for_variant(variant))

    def test_unknown_application_role_is_rejected(self) -> None:
        before, after, variant = fixture(True)
        after["keycloak_role"].append(
            {"id": "app-role", "client_realm_constraint": "admin", "client_role": True,
             "description": "extra", "name": "admin", "realm_id": "realm-1",
             "client": "admin", "realm": None}
        )
        with self.assertRaises(MigrationError):
            verify_rows(before, after, variant, cohort_for_variant(variant))

    def test_display_name_value_must_be_preserved(self) -> None:
        before, after, variant = fixture(True)
        after["realm"][0]["display_name"] = "Changed"
        with self.assertRaises(MigrationError):
            verify_rows(before, after, variant, cohort_for_variant(variant))

    def test_schema_inventory_rejects_unreviewed_changes(self) -> None:
        for legacy in (False, True):
            variant = "legacy-26.5.7" if legacy else "vif-26.7.3"
            before, after, synthetic_digests = synthetic_schema(legacy)
            with patch.dict(NEW_TABLES[variant], synthetic_digests):
                self.assertEqual(verify_schema(before, after, variant)["added_tables"],
                                 11 if legacy else 1)
                mutations = (
                    lambda x: x.update(extra_table=[{"name": "id", "type": "text", "not_null": True}]),
                    lambda x: x["org_identity_provider"][0].update(type="integer"),
                    lambda x: x["offline_user_session"][0].update(type="integer"),
                    lambda x: x["client"].append(
                        {"name": "unreviewed", "type": "boolean", "not_null": False}),
                    lambda x: x.pop("realm"),
                )
                for mutate in mutations:
                    with self.subTest(mutation=mutate.__code__.co_firstlineno, legacy=legacy):
                        changed = copy.deepcopy(after)
                        mutate(changed)
                        with self.assertRaises(MigrationError):
                            verify_schema(before, changed, variant)

    def test_org_routing_rows_block_attestation(self) -> None:
        before, after, variant = fixture(False)
        old_schema, new_schema, digests = synthetic_schema(False)
        with patch.dict(NEW_TABLES[variant], digests):
            verify(before, after, variant, "vif", old_schema, new_schema, [], [], [])
            mutations = (
                ([{"id": "old-domain"}], [], []),
                ([], [{"id": "new-domain"}], []),
                ([], [], [{"id": "new-link"}]),
            )
            for org_before, org_after, links_after in mutations:
                with self.assertRaises(MigrationError):
                    verify(before, after, variant, "vif", old_schema, new_schema,
                           org_before, org_after, links_after)


if __name__ == "__main__":
    unittest.main()
