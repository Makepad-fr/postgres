#!/usr/bin/env python3
"""Exercise archived migration tooling without contacting a Docker daemon."""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

TOOLS = Path(__file__).resolve().parents[1] / 'operations/database-separation-20260916'

class MigrationGuards(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        (self.root / 'cutover').mkdir()
        self.mapping = {'source': 'sentry-migrated-source'}
        self.archive = self.root / 'cutover/source.tar.gz'
        self.archive.write_bytes(b'fixture archive')
        self.manifest = {'source.tar.gz': {'sha256': hashlib.sha256(self.archive.read_bytes()).hexdigest(), 'bytes': self.archive.stat().st_size}}

    def execute(self, name, existing='', consumers=''):
        (self.root / 'volume-map.json').write_text(json.dumps(self.mapping))
        (self.root / 'cutover/manifest.json').write_text(json.dumps(self.manifest))
        code = (TOOLS / name).read_text().replace('/var/lib/makepad/db-migration-20260916', str(self.root))
        def output(args, **kwargs):
            if args[:3] == ['docker', 'volume', 'ls']: return existing
            if args[:2] == ['docker', 'ps']:
                return consumers if any('volume=' in a for a in args) else ''
            if args[:3] == ['docker', 'volume', 'inspect']: return str(self.root)
            raise AssertionError(args)
        with patch.object(subprocess, 'check_output', side_effect=output), patch.object(subprocess, 'run') as mutate, patch('sys.argv', [name, 'rehearsal']):
            self.mutate = mutate
            exec(compile(code, name, 'exec'), {'__name__': '__main__'})

    def rejects_restore(self):
        with self.assertRaises(SystemExit): self.execute('restore-sentry-volumes.py')
        self.mutate.assert_not_called()

    def test_missing_manifest_entry_refuses_before_create(self):
        self.manifest = {}
        self.rejects_restore()

    def test_extra_manifest_entry_refuses_before_create(self):
        self.manifest['unused.tar.gz'] = dict(self.manifest['source.tar.gz'])
        (self.root / 'cutover/unused.tar.gz').write_bytes(self.archive.read_bytes())
        self.rejects_restore()

    def test_duplicate_destination_refuses_before_create(self):
        self.mapping['second'] = self.mapping['source']
        (self.root / 'cutover/second.tar.gz').write_bytes(self.archive.read_bytes())
        self.manifest['second.tar.gz'] = dict(self.manifest['source.tar.gz'])
        self.rejects_restore()

    def test_size_mismatch_refuses_before_create(self):
        self.manifest['source.tar.gz']['bytes'] += 1
        self.rejects_restore()

    def test_digest_mismatch_refuses_before_create(self):
        self.manifest['source.tar.gz']['sha256'] = '0' * 64
        self.rejects_restore()

    def test_existing_destination_refuses_before_create(self):
        with self.assertRaises(SystemExit): self.execute('restore-sentry-volumes.py', existing='sentry-migrated-source\n')
        self.mutate.assert_not_called()

    def test_complete_manifest_creates_and_restores(self):
        self.execute('restore-sentry-volumes.py')
        calls = self.mutate.call_args_list
        self.assertEqual(calls[0].args[0], ['docker', 'volume', 'create', 'sentry-migrated-source'])
        self.assertEqual(calls[1].args[0][0], 'tar')
        self.assertEqual(len(calls), 2)

    def test_snapshot_rejects_volume_writer_in_another_project(self):
        with self.assertRaises(SystemExit): self.execute('snapshot-sentry-volumes.py', consumers='running-container')
        self.mutate.assert_not_called()

if __name__ == '__main__': unittest.main()
