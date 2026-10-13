#!/usr/bin/env python3
"""Read the Visitaki identity DB password on stdin; print a sanitized receipt."""
import argparse
import json
import subprocess
import sys
import uuid

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--context', required=True)
args = parser.parse_args()
password = sys.stdin.readline().rstrip('\r\n')
if len(password) != 64 or any(c not in '0123456789abcdef' for c in password):
    raise SystemExit('Expected the scoped Visitaki identity credential on stdin')
image = 'postgres:16-alpine@sha256:57c72fd2a128e416c7fcc499958864df5301e940bca0a56f58fddf30ffc07777'
base = ['docker', '--context', args.context]

def probe(database, mode='verify-full'):
    name = 'visitaki-identity-db-probe-' + uuid.uuid4().hex
    connection = 'host=makepad-postgres dbname=' + database + ' user=keycloak_visitaki_app sslmode=' + mode + ' sslrootcert=/run/postgres-ca.crt connect_timeout=5'
    script = 'read -r PGPASSWORD; export PGPASSWORD; exec psql "$1" -At -v ON_ERROR_STOP=1 -c "SELECT current_database(),current_user,(SELECT ssl FROM pg_stat_ssl WHERE pid=pg_backend_pid())"'
    try:
        return subprocess.run(base + ['run', '--rm', '--name', name, '-i', '--cpus', '.25', '--memory', '96m', '--add-host', 'makepad-postgres:10.80.0.2', '--mount', 'type=bind,src=/etc/makepad/tls/visitaki/postgres-ca.crt,dst=/run/postgres-ca.crt,readonly', '--entrypoint', 'sh', image, '-c', script, 'probe', connection], input=password + '\n', text=True, capture_output=True, timeout=45)
    finally:
        subprocess.run(base + ['rm', '-f', name], capture_output=True)

success = probe('keycloak_visitaki')
if success.returncode or success.stdout.strip() != 'keycloak_visitaki|keycloak_visitaki_app|t':
    raise SystemExit('Visitaki identity TLS authentication failed')
for database, mode in [('visitaki', 'verify-full'), ('postgres', 'verify-full'), ('keycloak_visitaki', 'disable')]:
    denied = probe(database, mode)
    if not denied.returncode or 'pg_hba.conf rejects connection' not in denied.stderr:
        raise SystemExit('Visitaki identity isolation/transport denial failed')
print(json.dumps({'source_context': args.context, 'database': 'keycloak_visitaki', 'role': 'keycloak_visitaki_app', 'private_endpoint': '10.80.0.2', 'tls': 'verify-full', 'cross_database_denial': ['visitaki', 'postgres'], 'plaintext_denied': True, 'passed': True}))
