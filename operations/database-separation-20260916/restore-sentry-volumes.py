#!/usr/bin/env python3
"""Verify archives and restore into NEW destination volumes on the DB host."""
import hashlib
import json
import re
from pathlib import Path
import subprocess

root = Path('/var/lib/makepad/db-migration-20260916')
snapshot = root / 'cutover'
manifest = json.loads((snapshot/'manifest.json').read_text())
mapping = json.loads((root/'volume-map.json').read_text())
# Validate the complete plan before creating any destination volume. A partial
# manifest must never allow an unchecked archive to reach tar.
valid_name = re.compile(r'[a-zA-Z0-9][a-zA-Z0-9_.-]*\Z')
if not isinstance(mapping, dict) or not mapping or any(
    not isinstance(name, str) or not valid_name.fullmatch(name)
    for pair in mapping.items() for name in pair
):
    raise SystemExit('Invalid or empty volume mapping')
if len(set(mapping.values())) != len(mapping):
    raise SystemExit('Destination volumes must be unique')
if set(mapping).intersection(mapping.values()):
    raise SystemExit('Destination volumes must differ from all source volumes')
if not isinstance(manifest, dict) or set(manifest) != {source + '.tar.gz' for source in mapping}:
    raise SystemExit('Manifest must cover exactly the mapped source archives')
for filename, info in manifest.items():
    archive = snapshot / filename
    if not isinstance(info, dict) or not isinstance(info.get('sha256'), str) or not re.fullmatch(r'[0-9a-f]{64}', info['sha256']):
        raise SystemExit('Invalid archive checksum: ' + filename)
    if not archive.is_file() or archive.is_symlink() or type(info.get('bytes')) is not int or archive.stat().st_size != info['bytes']:
        raise SystemExit('Archive missing or size mismatch: ' + filename)
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
