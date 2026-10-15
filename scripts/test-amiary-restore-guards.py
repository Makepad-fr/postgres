import os
from pathlib import Path
import subprocess
import tempfile
import unittest
ROOT=Path(__file__).resolve().parent
class RestoreGuards(unittest.TestCase):
    def test_refuses_unsafe_targets_before_mutation(self):
        for response, service in [('f','amiary_restore_test'),('error','amiary_restore_test'),('t','amiary_restore_test dbname=amiary')]:
            with self.subTest(response=response,service=service),tempfile.TemporaryDirectory() as tmp:
                root=Path(tmp); bindir=root/'bin';bindir.mkdir();backup=root/'backup';backup.mkdir()
                for name in ('runtrace','keycloak_runtrace','amiary','amiary_canary','keycloak_amiary'):(backup/(name+'.dump')).write_text('fixture')
                for name in ('SHA256SUMS','metadata.json'):(backup/name).write_text('fixture')
                (root/'services').write_text('fixture')
                (bindir/'sha256sum').write_text('#!/bin/sh\nexit 0\n')
                (bindir/'psql').write_text('#!/bin/sh\ncat >/dev/null\nif [ "$TEST_RESPONSE" = error ]; then exit 1; fi\necho "$TEST_RESPONSE"\n')
                (bindir/'pg_restore').write_text('#!/bin/sh\ntouch "$TEST_ROOT/mutation"\nexit 1\n')
                for path in bindir.iterdir():path.chmod(0o700)
                env=dict(os.environ,PATH=str(bindir)+os.pathsep+os.environ['PATH'],TEST_ROOT=tmp,TEST_RESPONSE=response,PGSERVICEFILE=str(root/'services'),RUNTRACE_RESTORE_CONFIRM='replace-nonproduction-restore-targets')
                for name in ('RUNTRACE','KEYCLOAK_RUNTRACE','AMIARY','AMIARY_CANARY','KEYCLOAK_AMIARY'):env[name+'_RESTORE_SERVICE']=name.lower()+'_restore_test'
                env['AMIARY_RESTORE_SERVICE']=service
                result=subprocess.run(['bash',str(ROOT/'verify-amiary-shared-restore.sh'),str(backup)],env=env,capture_output=True)
                self.assertNotEqual(result.returncode,0)
                self.assertFalse((root/'mutation').exists(),'Unsafe target reached pg_restore')
if __name__=='__main__':unittest.main()
