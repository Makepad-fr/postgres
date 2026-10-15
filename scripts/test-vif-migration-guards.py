#!/usr/bin/env python3
"""Archived VIF cutover preconditions; no Docker or production mutations."""
import copy
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

TOOL = Path(__file__).resolve().parents[1] / 'operations/database-separation-20260916/cutover-vif-links.py'

class CutoverGuards(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name); self.archive = self.root / 'archive'; self.archive.mkdir()
        self.source = self.root / 'source'; self.source.mkdir(); (self.source / 'infra').mkdir()
        self.compose = self.source / 'compose.yml'
        self.compose.write_text('services:\n  etcd:\n    image: fixture-etcd\n  vault:\n    image: fixture-vault\n')
        self.original = [{'Spec': {'Name': 'vif_'+name, 'TaskTemplate': {'ContainerSpec': {'Image': 'fixture-'+name}}, 'Mode': {'Replicated': {'Replicas': 1}}}} for name in ['etcd','vault']]
        (self.archive / 'original-services.json').write_text(json.dumps(self.original))
        for name in ['etcd','vault']:(self.archive / (name+'-db-link.cfg')).write_text('synthetic proxy')
        self.current = copy.deepcopy(self.original)
        for row in self.current:row['Spec']['Mode']['Replicated']['Replicas'] = 0
        self.task_state = 'shutdown'

    def execute(self):
        code = TOOL.read_text().replace('/var/lib/makepad/db-migration-20260916/vif',str(self.archive)).replace('/home/makepad/vif-app/current',str(self.source))
        def output(args, **kwargs):
            if args[:3] == ['docker','service','inspect']:return json.dumps(self.current)
            if args[:3] == ['docker','service','ps']:return 'fixture-task\n'
            if args[:2] == ['docker','inspect']:return json.dumps([{'Status': {'State': self.task_state}}])
            raise AssertionError(args)
        old_umask = os.umask(0o022)
        try:
            with patch.object(subprocess,'check_output',side_effect=output), patch.object(subprocess,'run') as mutate:
                self.mutate = mutate
                exec(compile(code,str(TOOL),'exec'),{'__name__':'__main__'})
        finally:os.umask(old_umask)

    def reject(self):
        with self.assertRaises(SystemExit):self.execute()
        self.mutate.assert_not_called()
        self.assertFalse((self.archive/'original-compose.yml').exists())
        self.assertFalse((self.source/'infra/database-links').exists())

    def test_running_replica_rejected(self):
        self.current[0]['Spec']['Mode']['Replicated']['Replicas'] = 1; self.reject()
    def test_stopping_task_rejected(self):
        self.task_state = 'running'; self.reject()
    def test_changed_container_rejected(self):
        self.current[1]['Spec']['TaskTemplate']['ContainerSpec']['Image'] = 'new-runtime'; self.reject()
    def test_missing_service_rejected(self):
        self.current.pop(); self.reject()
    def test_verified_stopped_services_and_private_rollback(self):
        self.execute(); self.assertEqual(self.mutate.call_count,3)
        self.assertEqual((self.archive/'original-compose.yml').stat().st_mode & 0o777,0o600)

if __name__ == '__main__':unittest.main()
