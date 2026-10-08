#!/usr/bin/env python3
"""Contract tests for the Brio PostgreSQL semantic-control receipt."""

import importlib.util
import ipaddress
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "brio_postgres_control_receipt",
    ROOT / "scripts/brio-postgres-control-receipt.py",
)
assert SPEC is not None and SPEC.loader is not None
receipt_module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(receipt_module)


def raw_rule(rule):
    rule_type, databases, users, address, method = rule
    if address == "all":
        raw_address = "all"
        netmask = None
    else:
        network = ipaddress.ip_network(address)
        raw_address = str(network.network_address)
        netmask = str(network.netmask)
    return {
        "type": rule_type,
        "databases": list(databases),
        "users": list(users),
        "address": raw_address,
        "netmask": netmask,
        "authMethod": method,
        "options": None,
        "error": None,
    }


def settings_fixture():
    return {
        "ssl": "on",
        "passwordEncryption": "scram-sha-256",
        "hbaFile": receipt_module.EXPECTED_HBA_FILE,
        "sslCertFile": receipt_module.EXPECTED_SSL_CERT_FILE,
        "listenAddresses": "*",
        "port": 5432,
        "hbaErrors": 0,
        "rules": [raw_rule(rule) for rule in receipt_module.EXPECTED_HBA_RULES],
        "password": "must-never-enter-the-receipt",
    }


def certificate_fixture():
    return {
        "applicationAlias": receipt_module.EXPECTED_APPLICATION_ALIAS,
        "applicationAliasVerified": True,
        "fingerprintSHA256": f"sha256:{'a' * 64}",
        "identityEndpoint": receipt_module.EXPECTED_IDENTITY_ENDPOINT,
        "identityEndpointVerified": True,
        "protocols": {"applicationAlias": "TLSv1.3", "identityEndpoint": "TLSv1.3"},
        "verification": "verify-full",
    }


receipt = receipt_module.normalize_control_receipt(settings_fixture(), certificate_fixture())
assert set(receipt) == {"controls", "hostRole", "provider", "schema", "subject"}
assert receipt["schema"] == "makepad.brio.runtime-controls.v1"
assert receipt["hostRole"] == "database"
assert receipt["provider"] == "postgresql"
assert receipt["subject"] == "brio-databases"
assert receipt["controls"]["server"] == {"passwordEncryption": "scram-sha-256", "ssl": True}
assert receipt["controls"]["networkBoundary"]["containerNetworkMode"] == "host"
assert receipt["controls"]["certificate"]["applicationAliasVerified"] is True
assert receipt["controls"]["certificate"]["identityEndpointVerified"] is True
assert receipt["controls"]["networkBoundary"]["plaintextRejectedFor"] == [
    "brio_staging/brio_staging_app",
    "keycloak_brio_staging/keycloak_brio_staging_app",
]
assert len(receipt["controls"]["hbaRules"]) == 11
assert receipt["controls"]["normalizedRulesSHA256"].startswith("sha256:")
assert "must-never-enter-the-receipt" not in json.dumps(receipt, sort_keys=True)
assert "BEGIN TRANSACTION READ ONLY" in receipt_module.SETTINGS_SQL
assert "pg_hba_file_rules" in receipt_module.SETTINGS_SQL

ip_only_certificate = {
    "fingerprintSHA256": f"sha256:{'a' * 64}",
    "protocol": "TLSv1.3",
    "subjectAlternativeNames": [f"IP:{receipt_module.EXPECTED_IDENTITY_ENDPOINT}"],
    "verifiedHost": receipt_module.EXPECTED_IDENTITY_ENDPOINT,
    "verification": "verify-full",
}
try:
    receipt_module.normalize_control_receipt(settings_fixture(), ip_only_certificate)
except receipt_module.ReceiptError as error:
    assert "identity" in str(error)
else:
    raise AssertionError("an IP-only certificate receipt without the Brio application alias was accepted")

drifted_settings = settings_fixture()
drifted_settings["ssl"] = "off"
try:
    receipt_module.normalize_control_receipt(drifted_settings, certificate_fixture())
except receipt_module.ReceiptError as error:
    assert "TLS" in str(error)
else:
    raise AssertionError("disabled PostgreSQL TLS was accepted")

drifted_hba = settings_fixture()
drifted_hba["rules"][0]["authMethod"] = "trust"
try:
    receipt_module.normalize_control_receipt(drifted_hba, certificate_fixture())
except receipt_module.ReceiptError as error:
    assert "HBA" in str(error)
else:
    raise AssertionError("HBA authentication drift was accepted")

parse_error = settings_fixture()
parse_error["rules"][2]["error"] = "fixture parse error"
try:
    receipt_module.normalize_control_receipt(parse_error, certificate_fixture())
except receipt_module.ReceiptError as error:
    assert "HBA" in str(error)
else:
    raise AssertionError("HBA parse error was accepted")

print("Brio PostgreSQL control receipt contract passed.")
