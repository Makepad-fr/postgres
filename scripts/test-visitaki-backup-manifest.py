import hashlib
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import json
from types import SimpleNamespace

spec = importlib.util.spec_from_file_location('backup', Path(__file__).with_name('visitaki-encrypted-backup.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class IntegrityChecks(unittest.TestCase):
    def test_restore_never_publishes_success_before_cleanup(self):
        for cleanup_fails in [False, True]:
            with self.subTest(cleanup_fails=cleanup_fails), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                dumps = {d: b'PGDMP' + d.encode() for d in module.DATABASES}
                metadata = {'created_unix': 99999, 'sha256': {d: hashlib.sha256(v).hexdigest() for d, v in dumps.items()}}
                def restic(*args, output=None):
                    if args[0] == 'snapshots':
                        return json.dumps([{'id': 'a'*64, 'tags': ['visitaki-preview'], 'paths': [str(root/'current')]}]).encode()
                    if args[-1].endswith('metadata.json'):
                        return json.dumps(metadata).encode()
                    output.write(dumps[Path(args[-1]).stem])
                def run(args, **kwargs):
                    if args[:2] == ['docker', 'inspect']:
                        return SimpleNamespace(stdout=('sha256:'+'b'*64).encode())
                    if args[:2] == ['docker', 'rm']:
                        self.assertFalse((root/'restore-receipt.json').exists())
                        if cleanup_fails: raise RuntimeError('cleanup failed')
                    return SimpleNamespace(stdout=b't' if 'photo_memories' in args[-1] else b'10')
                with patch.object(module, 'ROOT', root), patch.object(module, 'restic', side_effect=restic), \
                     patch.object(module, 'run', side_effect=run), patch.object(module.time, 'time', return_value=100000), \
                     patch.object(module.subprocess, 'run', return_value=SimpleNamespace(returncode=0)):
                    if cleanup_fails:
                        with self.assertRaises(RuntimeError): module.restore('a'*64, 'c'*64)
                        self.assertFalse((root/'restore-receipt.json').exists())
                    else:
                        module.restore('a'*64, 'c'*64)
                        result = json.loads((root/'restore-receipt.json').read_text())
                        self.assertTrue(result['cleanup_verified'])
                        self.assertTrue(result['photo_integrity_verified'])

    def test_photo_restore_requires_current_backup_and_exact_digest(self):
        with patch.object(module.time, 'time', return_value=100000):
            module.validate_photo_backup({'created_unix': 99999}, 'a' * 64)
            for created in [None, '99999', True, 100001, 1]:
                with self.assertRaises(ValueError):
                    module.validate_photo_backup({'created_unix': created}, 'a' * 64)
            with self.assertRaises(ValueError):
                module.validate_photo_backup({'created_unix': 99999}, 'bad')

    def test_photo_query_is_scoped_and_rejects_sql_input(self):
        query = module.photo_integrity_query('a' * 64)
        for expected in ['026_quest_photo_memories.sql', 'community_completions',
                         'quest_photo_memory_operations', '2097152', 'erase_disabled_account_memories']:
            self.assertIn(expected, query)
        with self.assertRaises(ValueError): module.photo_integrity_query("'; DROP TABLE accounts; --")

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.metadata = {'sha256': {}}
        for database in module.DATABASES:
            content = b'PGDMP' + database.encode()
            (self.directory / (database + '.dump')).write_bytes(content)
            self.metadata['sha256'][database] = hashlib.sha256(content).hexdigest()

    def test_matching_dump_checksums(self):
        module.validate_manifest(self.metadata, self.directory)

    def test_corrupted_dump_rejected(self):
        (self.directory / 'visitaki.dump').write_bytes(b'PGDMPtampered')
        with self.assertRaises(AssertionError):
            module.validate_manifest(self.metadata, self.directory)

    def test_wrong_database_set_rejected(self):
        self.metadata['sha256']['another_app'] = '0' * 64
        with self.assertRaises(AssertionError):
            module.validate_manifest(self.metadata, self.directory)

    def test_symlink_rejected(self):
        path = self.directory / 'visitaki.dump'
        path.unlink()
        path.symlink_to(self.directory / 'keycloak_visitaki.dump')
        with self.assertRaises(AssertionError):
            module.validate_manifest(self.metadata, self.directory)


if __name__ == '__main__':
    unittest.main()
