import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import time
import uuid

ROOT=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('hba',ROOT/'betacrew-hba.py')
hba=importlib.util.module_from_spec(spec);spec.loader.exec_module(hba)

class HBA(unittest.TestCase):
    def test_rerun_preserves_neighbor_rules_and_permissions(self):
        with tempfile.TemporaryDirectory() as t:
            p=Path(t)/'hba';original='local all all trust\nhostssl other other 10.1.0.1/32 scram-sha-256\nhost all all all scram-sha-256\n';p.write_text(original);p.chmod(0o640)
            hba.apply(p);first=p.read_bytes();hba.apply(p)
            self.assertEqual(first,p.read_bytes());self.assertEqual(p.stat().st_mode&0o777,0o640)
            self.assertIn('hostssl other other 10.1.0.1/32 scram-sha-256',p.read_text())
    def test_each_missing_rule_rejected_without_write(self):
        for i in range(len(hba.RULES)):
            with self.subTest(rule=i),tempfile.TemporaryDirectory() as t:
                p=Path(t)/'hba';p.write_text('\n'.join(hba.RULES[:i]+hba.RULES[i+1:])+ '\nhost all all all scram-sha-256\n');before=p.read_bytes()
                with self.assertRaises(ValueError):hba.apply(p)
                self.assertEqual(before,p.read_bytes())
    def test_shadowed_block_and_earlier_broad_allow_rejected(self):
        for content in ['host all all all scram-sha-256\n'+'\n'.join(hba.RULES), 'hostssl all all 0.0.0.0/0 trust\n'+'\n'.join(hba.RULES)+'\nhost all all all scram-sha-256\n']:
            with tempfile.TemporaryDirectory() as t:
                p=Path(t)/'hba';p.write_text(content)
                with self.assertRaises(ValueError):hba.apply(p)

class Restore(unittest.TestCase):
    def test_rejects_destinations_before_any_restore(self):
        for reply,service in [('f','app'),('error','app'),('t','app dbname=betacrew'),('second-f','app')]:
            with self.subTest(reply=reply),tempfile.TemporaryDirectory() as t:
                p=Path(t);bin=p/'bin';bin.mkdir();backup=p/'backup';backup.mkdir()
                for name in ['betacrew.dump.cms','keycloak_betacrew.dump.cms','SHA256SUMS','metadata.json']:(backup/name).write_text('fixture')
                for name in ['service','cert','key']:(p/name).write_text('fixture')
                (bin/'sha256sum').write_text('#!/bin/sh\nexit 0\n')
                (bin/'psql').write_text('''#!/bin/sh
cat > "$TEST_ROOT/query"
printf '%s\\n' "$*" >> "$TEST_ROOT/args"
case "$TEST_REPLY" in
error) exit 1;;
second-f) case "$*" in *service=identity*) echo f;; *) echo t;; esac;;
*) echo "$TEST_REPLY";;
esac
''')
                for name in ['pg_restore','openssl']:(bin/name).write_text('#!/bin/sh\ntouch "$TEST_ROOT/mutation"\nexit 1\n')
                for f in bin.iterdir():f.chmod(0o700)
                env=dict(os.environ,PATH=str(bin)+os.pathsep+os.environ['PATH'],TEST_ROOT=t,TEST_REPLY=reply,PGSERVICEFILE=str(p/'service'),BETACREW_BACKUP_DECRYPTION_CERT=str(p/'cert'),BETACREW_BACKUP_DECRYPTION_KEY=str(p/'key'),BETACREW_RESTORE_SERVICE=service,KEYCLOAK_BETACREW_RESTORE_SERVICE='identity',BETACREW_RESTORE_CONFIRM='replace-nonproduction-restore-targets')
                result=subprocess.run(['bash',str(ROOT/'verify-betacrew-restore.sh'),str(backup)],env=env,capture_output=True)
                self.assertNotEqual(result.returncode,0);self.assertFalse((p/'mutation').exists())
                if (p/'args').exists():self.assertIn('sslmode=verify-full',(p/'args').read_text())

class DatabaseGuard(unittest.TestCase):
    def test_actual_database_name_and_nonempty_objects(self):
        container='betacrew-restore-guard-'+uuid.uuid4().hex[:10]
        image='postgres@sha256:721873c34ceb9f8d8fc265984940dc982404c105f19ad51be9fdc5970a6080ea'
        def command(*args,input=None):
            return subprocess.run(args,input=input,text=True,capture_output=True,check=True).stdout.strip()
        query=(ROOT/'verify-betacrew-restore.sh').read_text().split("<<'SQL'\n",1)[1].split('\nSQL',1)[0]
        def sql(database,text,expected='betacrew_restore_test'):
            return command('docker','exec','-i',container,'psql','-U','postgres','-d',database,'-XAt','-v','ON_ERROR_STOP=1','-v','expected_database='+expected,input=text)
        try:
            command('docker','run','-d','--network','none','--name',container,'--tmpfs','/var/lib/postgresql/data','-e','POSTGRES_PASSWORD=disposable-fixture-password',image)
            for _ in range(30):
                if subprocess.run(['docker','exec',container,'pg_isready','-U','postgres'],capture_output=True).returncode==0:break
                time.sleep(1)
            sql('postgres','CREATE DATABASE betacrew; CREATE DATABASE betacrew_restore_test; CREATE DATABASE keycloak_betacrew_restore_test;')
            self.assertEqual(sql('betacrew',query),'f')
            self.assertEqual(sql('betacrew_restore_test',query),'t')
            self.assertEqual(sql('keycloak_betacrew_restore_test',query),'f')
            self.assertEqual(sql('keycloak_betacrew_restore_test',query,'keycloak_betacrew_restore_test'),'t')
            for ddl,cleanup in [('CREATE TABLE sentinel(id int)','DROP TABLE sentinel'),('CREATE SEQUENCE sentinel','DROP SEQUENCE sentinel'),('CREATE VIEW sentinel AS SELECT 1','DROP VIEW sentinel')]:
                sql('betacrew_restore_test',ddl)
                self.assertEqual(sql('betacrew_restore_test',query),'f')
                sql('betacrew_restore_test',cleanup)
            sql('postgres','DROP DATABASE betacrew;')
            bootstrap=(ROOT.parent/'bootstrap/betacrew-databases.sql').read_text()
            def provision(password='disposable-app-password-at-least-32-characters'):
                return command('docker','exec','-i',container,'psql','-U','postgres','-d','postgres','-XAt','-v','ON_ERROR_STOP=1','-v','betacrew_app_password='+password,'-v','keycloak_betacrew_app_password=disposable-identity-password-at-least-32-characters',input=bootstrap)
            with self.assertRaises(subprocess.CalledProcessError):provision('weak')
            self.assertEqual(sql('postgres',"SELECT count(*) FROM pg_roles WHERE rolname='betacrew_app'"),'0')
            provision()
            original=sql('postgres',"SELECT rolpassword FROM pg_authid WHERE rolname='betacrew_app'")
            provision('different-password-must-not-replace-live-credential')
            self.assertEqual(original,sql('postgres',"SELECT rolpassword FROM pg_authid WHERE rolname='betacrew_app'"))
            self.assertEqual(sql('postgres',"SELECT has_database_privilege('betacrew_app','keycloak_betacrew','CONNECT')"),'f')
            self.assertEqual(sql('postgres',"SELECT has_database_privilege('keycloak_betacrew_app','betacrew','CONNECT')"),'f')
            sql('postgres','ALTER ROLE keycloak_betacrew_app SUPERUSER;')
            with self.assertRaises(subprocess.CalledProcessError):provision()
            self.assertEqual(original,sql('postgres',"SELECT rolpassword FROM pg_authid WHERE rolname='betacrew_app'"))
            sql('postgres','ALTER ROLE keycloak_betacrew_app NOSUPERUSER; GRANT CONNECT ON DATABASE betacrew TO PUBLIC;')
            with self.assertRaises(subprocess.CalledProcessError):provision()

        finally:
            subprocess.run(['docker','rm','-f',container],capture_output=True)

if __name__=='__main__':unittest.main()
