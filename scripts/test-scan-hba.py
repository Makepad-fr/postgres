#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import unittest
spec = importlib.util.spec_from_file_location('hba', Path(__file__).with_name('prepare-scan-hba.py'))
hba = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hba)
class HBA(unittest.TestCase):
    def test_preserves_shared_policy(self):
        old = 'local all all trust\nhostssl other other 10.80.0.1/32 scram-sha-256\nhost all all all scram-sha-256\n'
        rules = 'hostnossl makepad_scan all all reject\n'
        new = hba.candidate(old, rules)
        self.assertEqual(new.replace(rules, ''), old)
        self.assertLess(new.index('makepad_scan'), new.index('host all all'))
        self.assertEqual(hba.candidate(new, rules), new)
    def test_refuses_ambiguous_policy(self):
        for old in ['', 'host makepad_scan all all reject\nhost all all all scram-sha-256\n']:
            with self.assertRaises(ValueError): hba.candidate(old, 'hostnossl makepad_scan all all reject')
unittest.main()
