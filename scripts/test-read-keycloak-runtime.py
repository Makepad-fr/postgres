#!/usr/bin/env python3
"""Runtime selection must reject arbitrary images before restore work starts."""
import importlib.util
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location('runtime', Path(__file__).with_name('read-keycloak-runtime.py'))
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)


class RuntimeTests(unittest.TestCase):
    def read(self, contents):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'runtime.env'
            path.write_text(contents)
            return runtime.read_runtime(path)

    def test_reviewed_pairs(self):
        for image, version in runtime.contract.REVIEWED_RUNTIMES.items():
            with self.subTest(version=version):
                self.assertEqual((image, version), self.read(f'IGNORED=value\nKEYCLOAK_IMAGE={image}\nKEYCLOAK_UPSTREAM_VERSION={version}\n'))

    def test_reject_unreviewed_or_ambiguous_config(self):
        image, version = next(iter(runtime.contract.REVIEWED_RUNTIMES.items()))
        valid = f'KEYCLOAK_IMAGE={image}\nKEYCLOAK_UPSTREAM_VERSION={version}\n'
        for contents in ('', f'KEYCLOAK_IMAGE={image}\n', valid.replace(version, '99.0.0'),
                         valid.replace(image, 'dhi.io/keycloak:latest'),
                         valid + f'KEYCLOAK_IMAGE={image}\n',
                         valid + f'KEYCLOAK_UPSTREAM_VERSION={version}\n',
                         valid.replace(image, image + ' ')):
            with self.subTest(contents=contents), self.assertRaises(ValueError):
                self.read(contents)


if __name__ == '__main__':
    unittest.main()
