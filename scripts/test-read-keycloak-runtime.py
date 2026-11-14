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
    IMAGE_2682 = 'dhi.io/keycloak:26.8.2-debian13@sha256:07a4c143921a2ec8c38f02fd608d72180fa5e6bf2ee539c371ba8a5e1402b3fd'
    def read(self, contents):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'runtime.env'
            path.write_text(contents)
            return runtime.read_runtime(path)

    def test_reviewed_pairs(self):
        for image, version in runtime.contract.REVIEWED_RUNTIMES.items():
            with self.subTest(version=version):
                self.assertEqual((image, version), self.read(f'IGNORED=value\nKEYCLOAK_IMAGE={image}\nKEYCLOAK_UPSTREAM_VERSION={version}\n'))

    def test_exact_2682_pair(self):
        self.assertEqual((self.IMAGE_2682, '26.8.2'),
                         self.read(f'KEYCLOAK_IMAGE={self.IMAGE_2682}\nKEYCLOAK_UPSTREAM_VERSION=26.8.2\n'))

    def test_2682_mismatched_or_unreviewed_digest_is_rejected(self):
        bad_pairs = (
            (self.IMAGE_2682, '26.8.1'),
            (self.IMAGE_2682.replace('26.8.2-debian13', '26.8.1-debian13'), '26.8.2'),
            (self.IMAGE_2682[:-64] + 'f' * 64, '26.8.2'),
            ('dhi.io/keycloak:26.8.2-debian13', '26.8.2'),
        )
        for image, version in bad_pairs:
            with self.subTest(image=image, version=version), self.assertRaises(ValueError):
                self.read(f'KEYCLOAK_IMAGE={image}\nKEYCLOAK_UPSTREAM_VERSION={version}\n')

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
