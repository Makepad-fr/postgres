#!/usr/bin/env python3
"""Verify archives and restore into NEW destination volumes on the DB host."""
import hashlib
import json
from pathlib import Path
import subprocess

root = Path('/var/lib/makepad/db-migration-20260916')
snapshot = root / 'cutover'
manifest = json.loads((snapshot/'manifest.json').read_text())
mapping = json.loads((root/'volume-map.json').read_text())
for filename, info in manifest.items():
    h = hashlib.sha256()
    with (snapshot/filename).open('rb') as f:
        for chunk in iter(lambda: f.read(1024*1024), b''): h.update(chunk)
    if h.hexdigest() != info['sha256']: raise SystemExit('Archive checksum mismatch: '+filename)
existing = set(subprocess.check_output(['docker','volume','ls','-q'],text=True).split())
if existing.intersection(mapping.values()):
    raise SystemExit('Destination volume already exists; refusing overwrite')
for source, target in mapping.items():
    subprocess.run(['docker','volume','create',target],check=True,stdout=subprocess.DEVNULL)
    mount = subprocess.check_output(['docker','volume','inspect','--format','{{.Mountpoint}}',target],text=True).strip()
    subprocess.run(['tar','--numeric-owner','--acls','--xattrs','-C',mount,'-xzf',str(snapshot/(source+'.tar.gz'))],check=True)
print('Verified and restored', len(mapping), 'new volumes')
