#!/usr/bin/env python3
"""Expire only Visitaki snapshots; never infer scope from a tag alone."""
import datetime
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import time

spec = importlib.util.spec_from_file_location('backup', Path(__file__).with_name('visitaki-encrypted-backup.py'))
backup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(backup)
RETENTION_DAYS = 30


def expired_snapshots(rows, now):
    if not rows:
        raise ValueError('No scoped backup exists')
    parsed = []
    for row in rows:
        if (row.get('hostname') != 'db-server-1'
                or row.get('paths') != [str(backup.ROOT / 'current')]
                or row.get('tags') != ['visitaki-preview']
                or not re.fullmatch('[0-9a-f]{64}', str(row.get('id', '')))):
            raise ValueError('Unexpected snapshot scope')
        stamp = datetime.datetime.fromisoformat(row['time'].replace('Z', '+00:00'))
        if stamp.tzinfo is None or stamp.timestamp() > now:
            raise ValueError('Invalid snapshot time')
        parsed.append((row['id'], stamp.timestamp()))
    if len({ident for ident, _ in parsed}) != len(parsed):
        raise ValueError('Duplicate snapshot')
    if now - max(stamp for _, stamp in parsed) > 86400:
        raise ValueError('Fresh backup required before expiry')
    return [ident for ident, stamp in parsed if now - stamp > RETENTION_DAYS * 86400]


def expire():
    rows = json.loads(backup.restic('snapshots', '--json', '--tag', 'visitaki-preview',
        '--host', 'db-server-1', '--path', str(backup.ROOT / 'current')))
    expired = expired_snapshots(rows, time.time())
    # Explicit validated full IDs; never a repository-wide forget policy.
    for ident in expired:
        backup.restic('forget', ident)
    # Shared encrypted repository: only unreferenced blobs are removed. All
    # retained snapshots, including other applications, remain referenced.
    # Zero unused tolerance avoids indefinite retention in partially used packs.
    result = subprocess.run(['/bin/bash', '-ec',
        'set -a; source "$1"; exec /usr/bin/restic --no-cache prune --max-unused 0',
        'visitaki-retention', str(backup.ENV)], capture_output=True, timeout=3600)
    if result.returncode:
        raise RuntimeError('Encrypted repository prune failed')
    remaining = json.loads(backup.restic('snapshots', '--json', '--tag', 'visitaki-preview',
        '--host', 'db-server-1', '--path', str(backup.ROOT / 'current')))
    if expired_snapshots(remaining, time.time()):
        raise RuntimeError('Expired snapshots remain')
    receipt = {'retention_days': RETENTION_DAYS, 'expired_count': len(expired),
        'remaining_count': len(remaining), 'prune_verified': True,
        'verified_unix': int(time.time())}
    (backup.ROOT / 'retention-receipt.json').write_text(json.dumps(receipt, indent=2))
    print(json.dumps(receipt))


def main():
    if os.geteuid() != 0 or socket.gethostname() != 'db-server-1':
        raise RuntimeError('Authorized database host required')
    if (not backup.ENV.is_file() or backup.ENV.is_symlink()
            or backup.ENV.stat().st_uid != 0 or backup.ENV.stat().st_mode & 0o077):
        raise RuntimeError('Private backup credentials required')
    os.umask(0o077)
    if not backup.ROOT.is_dir() or backup.ROOT.is_symlink():
        raise RuntimeError('Existing private backup root required')
    with (backup.ROOT / 'operation.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        expire()


if __name__ == '__main__':
    main()
