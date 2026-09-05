#!/usr/bin/env python3
"""Validate one public PostgreSQL CI trust anchor read from standard input."""

from __future__ import annotations

import base64
import binascii
import re
import sys
from typing import NoReturn


INTEGER_ANCHORS = {
    "POSTGRES_CI_LAUNCHER_APP_SENDER_ID",
    "POSTGRES_PR_CHECK_APP_ID",
}
EXPECTED_ANCHORS = INTEGER_ANCHORS | {
    "POSTGRES_CI_APPROVED_BASE_IMAGE_SHA256",
    "POSTGRES_CI_ATTESTATION_PUBLIC_KEY",
}
ED25519_SPKI_PREFIX = bytes.fromhex("302a300506032b6570032100")
MAX_PROVIDER_INTEGER = 2**63 - 1


def fail(message: str) -> NoReturn:
    raise SystemExit(f"repository trust anchor is invalid: {message}")


def validate(name: str, value: bytes) -> None:
    if name not in EXPECTED_ANCHORS:
        fail("unsupported destination")
    if not value or len(value) > 4096 or b"\x00" in value:
        fail("value is empty, oversized, or contains NUL")

    try:
        text = value.decode("ascii")
    except UnicodeDecodeError:
        fail("value is not ASCII")

    if name in INTEGER_ANCHORS:
        if not re.fullmatch(r"[1-9][0-9]{0,18}", text):
            fail("provider identifier is not canonical decimal")
        if int(text) > MAX_PROVIDER_INTEGER:
            fail("provider identifier exceeds the accepted range")
        return

    if name == "POSTGRES_CI_APPROVED_BASE_IMAGE_SHA256":
        if not re.fullmatch(r"[0-9a-f]{64}", text):
            fail("base-image digest is not canonical lowercase SHA-256")
        return

    lines = text.splitlines()
    if (
        len(lines) != 3
        or lines[0] != "-----BEGIN PUBLIC KEY-----"
        or lines[2] != "-----END PUBLIC KEY-----"
        or not re.fullmatch(r"[A-Za-z0-9+/]{59}=", lines[1])
    ):
        fail("attestation key is not canonical single-line PEM")
    try:
        der = base64.b64decode(lines[1], validate=True)
    except (binascii.Error, ValueError):
        fail("attestation key PEM is not valid base64")
    if len(der) != 44 or not der.startswith(ED25519_SPKI_PREFIX):
        fail("attestation key is not an Ed25519 SubjectPublicKeyInfo")
    if der[len(ED25519_SPKI_PREFIX) :] == bytes(32):
        fail("attestation key contains an invalid all-zero public point")


def main() -> int:
    if len(sys.argv) != 2:
        fail("expected exactly one destination argument")
    validate(sys.argv[1], sys.stdin.buffer.read())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
