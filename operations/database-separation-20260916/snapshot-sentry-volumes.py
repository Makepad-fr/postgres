#!/usr/bin/env python3
"""Create a consistent archive only after every source Sentry container stops."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

os.umask(0o077)
root = Path('/var/lib/makepad/db-migration-20260916')
stage = sys.argv[1]
if stage not in ('rehearsal', 'cutover'):
    raise SystemExit('stage must be rehearsal or cutover')
running = subprocess.check_output(['docker','ps','-q','--filter','label=com.docker.compose.project=makepad-sentry'],text=True).strip()
if running:
    raise SystemExit('Refusing snapshot: Sentry containers still running')
mapping = json.loads((root / 'volume-map.json').read_text())
# The effective Compose project can differ from the historic project label.
# Refuse any active consumer of each source volume, regardless of its project.
for name in mapping:
    consumers = subprocess.check_output(['docker', 'ps', '-q', '--filter', 'volume=' + name], text=True).strip()
    if consumers:
        raise SystemExit('Refusing snapshot: source volume still mounted by a running container')
dest = root / stage
dest.mkdir(exist_ok=False)
manifest = {}
for name in mapping:
    mount = subprocess.check_output(['docker','volume','inspect','--format','{{.Mountpoint}}',name],text=True).strip()
    f = dest / (name + '.tar.gz')
    subprocess.run(['tar','--sparse','--numeric-owner','--acls','--xattrs','-C',mount,'-czf',str(f),'.'],check=True)
    h = hashlib.sha256()
    with f.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024*1024), b''): h.update(chunk)
    manifest[f.name] = {'sha256': h.hexdigest(), 'bytes': f.stat().st_size}
(dest/'manifest.json').write_text(json.dumps(manifest,indent=2))
print(json.dumps(manifest))
