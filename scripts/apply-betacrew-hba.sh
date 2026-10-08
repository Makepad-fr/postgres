#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")" && pwd)
exec python3 "$root/betacrew-hba.py" "${1:?Usage: apply-betacrew-hba.sh <pg_hba.conf>}"
