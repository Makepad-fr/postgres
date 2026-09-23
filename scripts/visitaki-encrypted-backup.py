#!/usr/bin/env python3
"""Scoped host-side backup and isolated restore using the existing encrypted repository."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import tempfile
import time
import uuid

DATABASES = ('visitaki', 'keycloak_visitaki')
ROOT = Path('/var/lib/makepad/visitaki-postgres-backup')
ENV = Path('/etc/makepad/backups/restic-postgres.env')
SOURCE = 'postgres-postgres-1'


def run(args, **kwargs):
    result = subprocess.run(args, stderr=subprocess.PIPE, timeout=600, **kwargs)
    if result.returncode:
        raise RuntimeError('Visitaki backup operation failed: ' + args[0])
    return result


def restic(*args):
    return run(['/bin/bash', '-ec', 'set -a; source "$1"; shift; exec /usr/bin/restic --no-cache "$@"',
        'visitaki-backup', str(ENV), *args], stdout=subprocess.PIPE).stdout


def validate_manifest(metadata, directory):
    assert set(metadata['sha256']) == set(DATABASES)
    for database in DATABASES:
        path = directory / (database + '.dump')
        assert path.is_file() and not path.is_symlink()
        assert path.read_bytes()[:5] == b'PGDMP'
        assert hashlib.file_digest(path.open('rb'), 'sha256').hexdigest() == metadata['sha256'][database]


def backup():
    current = ROOT / 'current'
    assert not current.exists(), 'Unfinished backup directory requires inspection'
    current.mkdir(mode=0o700)
    try:
        digests = {}
        for database in DATABASES:
            path = current / (database + '.dump')
            with path.open('wb') as output:
                run(['docker', 'exec', SOURCE, 'sh', '-ec',
                    'export PGPASSWORD="$POSTGRES_PASSWORD"; exec pg_dump --format=custom --no-owner --no-acl -U "$POSTGRES_USER" "$1"',
                    'visitaki-backup', database], stdout=output)
            with path.open('rb') as dump:
                run(['docker', 'exec', '-i', SOURCE, 'pg_restore', '--list'], stdin=dump, stdout=subprocess.DEVNULL)
            with path.open('rb') as dump:
                digests[database] = hashlib.file_digest(dump, 'sha256').hexdigest()
        metadata = {'databases': list(DATABASES), 'sha256': digests, 'created_unix': int(time.time())}
        (current / 'metadata.json').write_text(json.dumps(metadata))
        output = restic('backup', '--json', '--tag', 'visitaki-preview', '--host', 'db-server-1', str(current))
        summaries = [json.loads(line) for line in output.splitlines() if line.strip()]
        completed = [row for row in summaries if row.get('message_type') == 'summary']
        assert len(completed) == 1 and completed[0].get('snapshot_id')
        receipt = {'snapshot_id': completed[0]['snapshot_id'], **metadata, 'encrypted_repository': True}
        (ROOT / 'latest.json').write_text(json.dumps(receipt, indent=2))
        print(json.dumps(receipt))
    finally:
        # Delete only the three plaintext files created by this invocation.
        for name in [*(database + '.dump' for database in DATABASES), 'metadata.json']:
            (current / name).unlink(missing_ok=True)
        current.rmdir()


def restore(snapshot):
    assert re.fullmatch('[0-9a-f]{8,64}', snapshot)
    records = json.loads(restic('snapshots', '--json', snapshot))
    assert len(records) == 1 and 'visitaki-preview' in records[0].get('tags', [])
    assert records[0]['paths'] == [str(ROOT / 'current')]
    image = run(['docker', 'inspect', '-f', '{{.Image}}', SOURCE], stdout=subprocess.PIPE).stdout.decode().strip()
    assert re.fullmatch('sha256:[0-9a-f]{64}', image)
    container = 'visitaki-isolated-restore-' + uuid.uuid4().hex[:12]
    created = False
    with tempfile.TemporaryDirectory(prefix='restore-', dir=ROOT) as temporary:
        directory = Path(temporary)
        prefix = str(ROOT / 'current') + '/'
        metadata = json.loads(restic('dump', snapshot, prefix + 'metadata.json'))
        for database in DATABASES:
            (directory / (database + '.dump')).write_bytes(restic('dump', snapshot, prefix + database + '.dump'))
        validate_manifest(metadata, directory)
        try:
            run(['docker', 'run', '-d', '--name', container, '--network', 'none', '--cpus', '.5', '--memory', '512m',
                 '--label', 'makepad.validation=visitaki-backup', '-e', 'POSTGRES_HOST_AUTH_METHOD=trust', image], stdout=subprocess.DEVNULL)
            created = True
            for _ in range(60):
                result = subprocess.run(['docker', 'exec', container, 'pg_isready', '-U', 'postgres'], capture_output=True, timeout=10)
                if result.returncode == 0:
                    break
                time.sleep(1)
            else:
                raise RuntimeError('Isolated restore database did not start')
            tables = {}
            for database in DATABASES:
                run(['docker', 'exec', container, 'createdb', '-U', 'postgres', database], stdout=subprocess.DEVNULL)
                with (directory / (database + '.dump')).open('rb') as dump:
                    run(['docker', 'exec', '-i', container, 'pg_restore', '-U', 'postgres', '-d', database,
                         '--exit-on-error', '--no-owner', '--no-privileges'], stdin=dump, stdout=subprocess.DEVNULL)
                count = run(['docker', 'exec', container, 'psql', '-XAt', '-U', 'postgres', '-d', database, '-c',
                    "SELECT count(*) FROM information_schema.tables WHERE table_schema='public'"], stdout=subprocess.PIPE)
                tables[database] = int(count.stdout)
            assert tables['visitaki'] > 0
            receipt = {'snapshot_id': records[0]['id'], 'restored_databases': tables, 'image': image,
                       'network': 'none', 'checksums_verified': True, 'passed': True}
            (ROOT / 'restore-receipt.json').write_text(json.dumps(receipt, indent=2))
            print(json.dumps(receipt))
        finally:
            if created:
                run(['docker', 'rm', '-fv', container], stdout=subprocess.DEVNULL)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('operation', choices=['backup', 'restore'])
    parser.add_argument('--snapshot')
    args = parser.parse_args()
    assert os.geteuid() == 0 and socket.gethostname() == 'db-server-1'
    assert ENV.is_file() and not ENV.is_symlink() and ENV.stat().st_uid == 0
    assert ENV.stat().st_mode & 0o077 == 0
    os.umask(0o077)
    ROOT.mkdir(mode=0o700, exist_ok=True)
    assert ROOT.is_dir() and not ROOT.is_symlink()
    with (ROOT / 'operation.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if args.operation == 'backup':
            backup()
        else:
            restore(args.snapshot or json.loads((ROOT / 'latest.json').read_text())['snapshot_id'])


if __name__ == '__main__':
    main()
