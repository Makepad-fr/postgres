#!/usr/bin/env python3
"""Resolve only reviewed immutable runtime pins from an exact Keycloak checkout."""
import argparse
import importlib.util
from pathlib import Path

spec = importlib.util.spec_from_file_location("cohort_evidence", Path(__file__).with_name("verify-keycloak-cohort-evidence.py"))
contract = importlib.util.module_from_spec(spec)
spec.loader.exec_module(contract)


def read_runtime(path):
    fields = {}
    for line in Path(path).read_text().splitlines():
        key, sep, value = line.partition("=")
        if key in ("KEYCLOAK_IMAGE", "KEYCLOAK_UPSTREAM_VERSION"):
            if key in fields or not sep:
                raise ValueError("Runtime pin is duplicated or malformed")
            fields[key] = value
    image = fields.get("KEYCLOAK_IMAGE")
    version = fields.get("KEYCLOAK_UPSTREAM_VERSION")
    if image not in contract.REVIEWED_RUNTIMES or contract.REVIEWED_RUNTIMES[image] != version:
        raise ValueError("Runtime image/version pair has not been reviewed")
    return image, version


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("config", type=Path)
    parser.add_argument("--field", choices=("image", "version", "github-env"), required=True)
    args = parser.parse_args()
    try:
        image, version = read_runtime(args.config)
    except (OSError, ValueError) as error:
        parser.exit(1, str(error) + "\n")
    if args.field == "github-env":
        print("COHORT_KEYCLOAK_IMAGE=" + image)
        print("COHORT_KEYCLOAK_VERSION=" + version)
    else:
        print(image if args.field == "image" else version)
