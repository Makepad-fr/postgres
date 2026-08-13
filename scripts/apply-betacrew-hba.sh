#!/usr/bin/env bash
set -euo pipefail

hba_path=${1:?Usage: apply-betacrew-hba.sh <pg_hba.conf>}
[[ -f "${hba_path}" && ! -L "${hba_path}" ]] || { echo "HBA path must be a regular non-symlink file." >&2; exit 1; }

marker='hostnossl betacrew'
if grep -Fq "${marker}" "${hba_path}"; then
  for required in \
    'hostssl betacrew            betacrew_app         10.80.0.1/32' \
    'hostssl keycloak_betacrew   keycloak_betacrew_app 88.99.209.165/32' \
    'hostssl keycloak_betacrew   all                  all                 reject'; do
    grep -Fq "${required}" "${hba_path}" || { echo "Partial BetaCrew HBA policy found; refusing to modify it." >&2; exit 1; }
  done
  exit 0
fi

fallback='host    all                 all                 all                 scram-sha-256'
[[ $(grep -Fxc "${fallback}" "${hba_path}") == 1 ]] || { echo "Expected exactly one shared HBA fallback rule." >&2; exit 1; }

temporary=$(mktemp "${hba_path}.betacrew.XXXXXX")
cleanup() { [[ ! -e "${temporary}" ]] || rm -f "${temporary}"; }
trap cleanup EXIT HUP INT TERM

awk -v fallback="${fallback}" '
  $0 == fallback {
    print "# BetaCrew app and identity traffic require TLS and exact source roles."
    print "hostnossl betacrew          all                  all                 reject"
    print "hostnossl keycloak_betacrew all                  all                 reject"
    print "hostssl betacrew            betacrew_app         10.80.0.1/32        scram-sha-256"
    print "hostssl keycloak_betacrew   keycloak_betacrew_app 88.99.209.165/32   scram-sha-256"
    print "hostssl betacrew            postgres             127.0.0.1/32        scram-sha-256"
    print "hostssl keycloak_betacrew   postgres             127.0.0.1/32        scram-sha-256"
    print "hostssl betacrew            all                  all                 reject"
    print "hostssl keycloak_betacrew   all                  all                 reject"
  }
  { print }
' "${hba_path}" > "${temporary}"
if original_mode=$(stat -c '%a' "${hba_path}" 2>/dev/null); then :; else original_mode=$(stat -f '%Lp' "${hba_path}"); fi
chmod "${original_mode}" "${temporary}"
mv "${temporary}" "${hba_path}"
