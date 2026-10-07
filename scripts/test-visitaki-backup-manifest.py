import hashlib
import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('backup', Path(__file__).with_name('visitaki-encrypted-backup.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class IntegrityChecks(unittest.TestCase):
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
