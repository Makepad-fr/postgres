#!/usr/bin/env python3
"""Emit a deterministic, credential-free receipt for live Brio PostgreSQL controls."""

from __future__ import annotations

import hashlib
import ipaddress
import json
import os
import re
import socket
import ssl
import stat
import struct
import subprocess
import sys
from pathlib import Path
from typing import Any


DOCKER = "/usr/bin/docker"
CA_CERTIFICATE = Path("/etc/makepad/tls/postgres/ca.crt")
EXPECTED_APPLICATION_ALIAS = "makepad-postgres-brio-staging"
EXPECTED_IDENTITY_ENDPOINT = "65.21.134.125"
EXPECTED_HBA_FILE = "/etc/postgresql/runtrace-pg_hba.conf"
EXPECTED_SSL_CERT_FILE = "/etc/postgresql/tls/server.crt"
EXPECTED_PLAINTEXT_DENIALS = (
    "brio_staging/brio_staging_app",
    "keycloak_brio_staging/keycloak_brio_staging_app",
)
MAX_PROCESS_OUTPUT = 2 * 1024 * 1024

EXPECTED_HBA_RULES = (
    ("hostnossl", ("brio_staging",), ("all",), "all", "reject"),
    ("hostnossl", ("keycloak_brio_staging",), ("all",), "all", "reject"),
    ("hostssl", ("brio_staging",), ("brio_staging_app",), "all", "scram-sha-256"),
    ("hostssl", ("brio_staging",), ("brio_staging_backup",), "all", "scram-sha-256"),
    ("hostssl", ("keycloak_brio_staging",), ("keycloak_brio_staging_app",), "127.0.0.1/32", "scram-sha-256"),
    ("hostssl", ("keycloak_brio_staging",), ("keycloak_brio_staging_app",), "88.99.209.165/32", "scram-sha-256"),
    ("hostssl", ("keycloak_brio_staging",), ("keycloak_brio_staging_backup",), "127.0.0.1/32", "scram-sha-256"),
    ("host", ("all",), ("brio_staging_app",), "all", "reject"),
    ("host", ("all",), ("brio_staging_backup",), "all", "reject"),
    ("host", ("all",), ("keycloak_brio_staging_app",), "all", "reject"),
    ("host", ("all",), ("keycloak_brio_staging_backup",), "all", "reject"),
)

SETTINGS_SQL = r"""
BEGIN TRANSACTION READ ONLY;
SELECT json_build_object(
  'ssl', current_setting('ssl'),
  'passwordEncryption', current_setting('password_encryption'),
  'hbaFile', current_setting('hba_file'),
  'sslCertFile', current_setting('ssl_cert_file'),
  'listenAddresses', current_setting('listen_addresses'),
  'port', current_setting('port')::integer,
  'hbaErrors', (SELECT count(*) FROM pg_hba_file_rules WHERE error IS NOT NULL),
  'rules', (
    SELECT coalesce(json_agg(json_build_object(
      'type', type,
      'databases', database,
      'users', user_name,
      'address', address,
      'netmask', netmask,
      'authMethod', auth_method,
      'options', options,
      'error', error
    ) ORDER BY line_number), '[]'::json)
    FROM pg_hba_file_rules
    WHERE database && ARRAY['brio_staging', 'keycloak_brio_staging']
       OR user_name && ARRAY[
         'brio_staging_app', 'brio_staging_backup',
         'keycloak_brio_staging_app', 'keycloak_brio_staging_backup'
       ]
  )
)::text;
COMMIT;
"""


class ReceiptError(RuntimeError):
    """A fail-closed database observation error without provider output."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ReceiptError(message)


def run_bounded(arguments: list[str], *, stdin: bytes = b"", expect_success: bool = True) -> subprocess.CompletedProcess:
    try:
        result = subprocess.run(
            arguments,
            input=stdin,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=20,
            env={"PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"},
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise ReceiptError("A fixed local PostgreSQL probe could not complete") from error
    require(
        len(result.stdout) <= MAX_PROCESS_OUTPUT and len(result.stderr) <= MAX_PROCESS_OUTPUT,
        "A fixed local PostgreSQL probe exceeded its output bound",
    )
    if expect_success:
        require(result.returncode == 0, "A fixed local PostgreSQL probe failed")
    return result


def observe_settings(container_id: str) -> dict[str, Any]:
    result = run_bounded(
        [
            DOCKER,
            "exec",
            "-i",
            container_id,
            "psql",
            "-X",
            "-qAt",
            "--no-password",
            "--set=ON_ERROR_STOP=1",
            "--username=postgres",
            "--dbname=postgres",
        ],
        stdin=SETTINGS_SQL.encode("utf-8"),
    )
    lines = result.stdout.decode("utf-8", errors="strict").splitlines()
    require(len(lines) == 1, "PostgreSQL settings probe returned an invalid envelope")
    try:
        payload = json.loads(lines[0])
    except json.JSONDecodeError as error:
        raise ReceiptError("PostgreSQL settings probe returned invalid JSON") from error
    require(isinstance(payload, dict), "PostgreSQL settings probe returned invalid JSON")
    return payload


def require_plaintext_denied(container_id: str, database: str, role: str) -> None:
    connection = f"hostaddr=127.0.0.1 port=5432 dbname={database} user={role} sslmode=disable connect_timeout=5"
    result = run_bounded(
        [DOCKER, "exec", container_id, "psql", "-X", "-qAt", "--no-password", f"--dbname={connection}", "--command=select 1"],
        expect_success=False,
    )
    error = result.stderr.decode("utf-8", errors="replace")
    require(result.returncode != 0, f"Plaintext PostgreSQL access was accepted for {database}/{role}")
    require(
        "pg_hba.conf rejects connection" in error
        and f'user "{role}"' in error
        and f'database "{database}"' in error
        and "no encryption" in error,
        f"Plaintext PostgreSQL rejection was not enforced by the expected HBA rule for {database}/{role}",
    )


def validate_ca_file(path: Path) -> None:
    try:
        metadata = path.lstat()
    except OSError as error:
        raise ReceiptError("PostgreSQL observer CA certificate is unavailable") from error
    require(stat.S_ISREG(metadata.st_mode), "PostgreSQL observer CA certificate must be a regular file")
    require(metadata.st_uid == 0 and stat.S_IMODE(metadata.st_mode) & 0o022 == 0, "PostgreSQL observer CA permissions are unsafe")


def read_exact(sock: socket.socket, length: int) -> bytes:
    chunks: list[bytes] = []
    remaining = length
    while remaining:
        chunk = sock.recv(remaining)
        require(bool(chunk), "PostgreSQL closed the local TLS probe early")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def observe_certificate_identity(server_name: str) -> tuple[bytes, str]:
    context = ssl.create_default_context(cafile=str(CA_CERTIFICATE))
    context.check_hostname = True
    context.verify_mode = ssl.CERT_REQUIRED
    try:
        with socket.create_connection(("127.0.0.1", 5432), timeout=10) as connection:
            connection.sendall(struct.pack("!II", 8, 80877103))
            require(read_exact(connection, 1) == b"S", "PostgreSQL refused the local TLS negotiation")
            with context.wrap_socket(connection, server_hostname=server_name) as secured:
                der = secured.getpeercert(binary_form=True)
                protocol = secured.version()
    except (OSError, ssl.SSLError) as error:
        raise ReceiptError("PostgreSQL local verify-full certificate probe failed") from error
    require(isinstance(der, bytes) and der, "PostgreSQL TLS peer certificate was unavailable")
    require(protocol in {"TLSv1.2", "TLSv1.3"}, "PostgreSQL negotiated an unsupported TLS protocol")
    return der, protocol


def observe_certificate() -> dict[str, Any]:
    validate_ca_file(CA_CERTIFICATE)
    application_der, application_protocol = observe_certificate_identity(EXPECTED_APPLICATION_ALIAS)
    identity_der, identity_protocol = observe_certificate_identity(EXPECTED_IDENTITY_ENDPOINT)
    require(application_der == identity_der, "PostgreSQL TLS identities returned different certificates")
    return {
        "applicationAlias": EXPECTED_APPLICATION_ALIAS,
        "applicationAliasVerified": True,
        "fingerprintSHA256": f"sha256:{hashlib.sha256(application_der).hexdigest()}",
        "identityEndpoint": EXPECTED_IDENTITY_ENDPOINT,
        "identityEndpointVerified": True,
        "protocols": {
            "applicationAlias": application_protocol,
            "identityEndpoint": identity_protocol,
        },
        "verification": "verify-full",
    }


def normalized_address(address: Any, netmask: Any) -> str:
    require(isinstance(address, str) and address, "Observed HBA address is invalid")
    if address == "all":
        require(netmask is None, "Observed all-address HBA rule has an unexpected netmask")
        return "all"
    require(isinstance(netmask, str) and netmask, "Observed HBA netmask is invalid")
    try:
        return str(ipaddress.ip_network(f"{address}/{netmask}", strict=False))
    except ValueError as error:
        raise ReceiptError("Observed HBA address is invalid") from error


def normalize_hba_rules(raw_rules: Any) -> list[dict[str, Any]]:
    require(isinstance(raw_rules, list), "Observed HBA rules are invalid")
    normalized: list[dict[str, Any]] = []
    tuples: list[tuple[Any, ...]] = []
    for raw in raw_rules:
        require(isinstance(raw, dict), "Observed HBA rule is invalid")
        databases = raw.get("databases")
        users = raw.get("users")
        require(
            isinstance(databases, list)
            and databases
            and all(isinstance(value, str) for value in databases)
            and isinstance(users, list)
            and users
            and all(isinstance(value, str) for value in users),
            "Observed HBA database or role scope is invalid",
        )
        require(raw.get("error") is None, "PostgreSQL reported an active HBA parse error")
        require(raw.get("options") in (None, []), "Brio HBA rules contain unsupported options")
        rule = (
            raw.get("type"),
            tuple(databases),
            tuple(users),
            normalized_address(raw.get("address"), raw.get("netmask")),
            raw.get("authMethod"),
        )
        tuples.append(rule)
        normalized.append(
            {
                "address": rule[3],
                "authMethod": rule[4],
                "databases": list(rule[1]),
                "type": rule[0],
                "users": list(rule[2]),
            }
        )
    require(tuple(tuples) == EXPECTED_HBA_RULES, "Live Brio PostgreSQL HBA rules drifted")
    return normalized


def normalize_control_receipt(settings: dict[str, Any], certificate: dict[str, Any]) -> dict[str, Any]:
    require(settings.get("ssl") == "on", "Live PostgreSQL TLS setting drifted")
    require(settings.get("passwordEncryption") == "scram-sha-256", "Live PostgreSQL password encryption drifted")
    require(settings.get("hbaFile") == EXPECTED_HBA_FILE, "Live PostgreSQL HBA source drifted")
    require(settings.get("sslCertFile") == EXPECTED_SSL_CERT_FILE, "Live PostgreSQL certificate source drifted")
    require(settings.get("listenAddresses") == "*" and settings.get("port") == 5432, "Live PostgreSQL listener identity drifted")
    require(settings.get("hbaErrors") == 0, "PostgreSQL reported an HBA parse error")
    require(
        set(certificate)
        == {
            "applicationAlias",
            "applicationAliasVerified",
            "fingerprintSHA256",
            "identityEndpoint",
            "identityEndpointVerified",
            "protocols",
            "verification",
        },
        "PostgreSQL certificate receipt omitted a reviewed verify-full identity",
    )
    protocols = certificate.get("protocols")
    require(
        certificate.get("applicationAlias") == EXPECTED_APPLICATION_ALIAS
        and certificate.get("applicationAliasVerified") is True
        and certificate.get("identityEndpoint") == EXPECTED_IDENTITY_ENDPOINT
        and certificate.get("identityEndpointVerified") is True
        and certificate.get("verification") == "verify-full"
        and isinstance(certificate.get("fingerprintSHA256"), str)
        and re.fullmatch(r"sha256:[a-f0-9]{64}", certificate["fingerprintSHA256"]) is not None
        and isinstance(protocols, dict)
        and set(protocols) == {"applicationAlias", "identityEndpoint"}
        and protocols.get("applicationAlias") in {"TLSv1.2", "TLSv1.3"}
        and protocols.get("identityEndpoint") in {"TLSv1.2", "TLSv1.3"},
        "PostgreSQL certificate receipt did not prove both reviewed verify-full identities",
    )
    rules = normalize_hba_rules(settings.get("rules"))
    serialized_rules = json.dumps(rules, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return {
        "controls": {
            "certificate": certificate,
            "hbaRules": rules,
            "networkBoundary": {
                "containerNetworkMode": "host",
                "hbaFile": EXPECTED_HBA_FILE,
                "listenAddresses": ["*"],
                "localProbeAddress": "127.0.0.1",
                "plaintextRejectedFor": list(EXPECTED_PLAINTEXT_DENIALS),
                "port": 5432,
            },
            "normalizedRulesSHA256": f"sha256:{hashlib.sha256(serialized_rules).hexdigest()}",
            "server": {"passwordEncryption": "scram-sha-256", "ssl": True},
        },
        "hostRole": "database",
        "provider": "postgresql",
        "schema": "makepad.brio.runtime-controls.v1",
        "subject": "brio-databases",
    }


def main(arguments: list[str]) -> int:
    require(len(arguments) == 1 and re.fullmatch(r"[a-f0-9]{64}", arguments[0]) is not None, "Expected one validated PostgreSQL container ID")
    container_id = arguments[0]
    settings = observe_settings(container_id)
    for identity in EXPECTED_PLAINTEXT_DENIALS:
        database, role = identity.split("/", 1)
        require_plaintext_denied(container_id, database, role)
    certificate = observe_certificate()
    receipt = normalize_control_receipt(settings, certificate)
    print(json.dumps(receipt, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except ReceiptError as error:
        print(f"Brio PostgreSQL control observation failed: {error}", file=os.sys.stderr)
        raise SystemExit(1)
