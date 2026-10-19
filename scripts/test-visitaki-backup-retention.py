#!/usr/bin/env python3
import copy
import datetime
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('retention', Path(__file__).with_name('visitaki-backup-retention.py'))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
NOW = 1800000000

def row(age, ident='a'):
    return {'id': ident * 64, 'hostname': 'db-server-1', 'tags': ['visitaki-preview'],
        'paths': [str(m.backup.ROOT / 'current')],
        'time': datetime.datetime.fromtimestamp(NOW-age, datetime.timezone.utc).isoformat()}

class RetentionTests(unittest.TestCase):
    def test_absolute_cutoff_and_fresh_snapshot_preserved(self):
        self.assertEqual(m.expired_snapshots([row(0),row(30*86400,'b'),row(30*86400+1,'c')],NOW),['c'*64])
    def test_missing_or_stale_backup_fails_closed(self):
        for rows in [[],[row(86401)]]:
            with self.assertRaises(ValueError):m.expired_snapshots(rows,NOW)
    def test_foreign_or_mixed_scope_rejected(self):
        for key,value in [('hostname','elsewhere'),('tags',['visitaki-preview','other']),('paths',['/other']),('id','short')]:
            bad=row(40*86400,'b');bad[key]=value
            with self.assertRaises(ValueError):m.expired_snapshots([row(0),bad],NOW)
    def test_future_naive_and_duplicate_times_rejected(self):
        for rows in [[row(-1)],[dict(row(0),time='2026-01-01T00:00:00')],[row(0),row(1)]]:
            with self.assertRaises(ValueError):m.expired_snapshots(rows,NOW)
    def test_invalid_scope_causes_no_forget_or_prune(self):
        import json
        with patch.object(m.backup,'restic',return_value=json.dumps([dict(row(0),hostname='foreign')])) as restic, patch.object(m.subprocess,'run') as run:
            with self.assertRaises(ValueError):m.expire()
            self.assertEqual(restic.call_count,1);run.assert_not_called()

if __name__=='__main__':unittest.main()
