import subprocess
from pathlib import Path
import time
import unittest
import uuid
ROOT=Path(__file__).resolve().parents[1]
class Bootstrap(unittest.TestCase):
    def test_existing_credentials_and_isolation(self):
        name='fashion-db-test-'+uuid.uuid4().hex[:10]
        def cmd(*args,input=None):
            return subprocess.run(args,input=input,text=True,capture_output=True,check=True).stdout.strip()
        def sql(text):
            return cmd('docker','exec','-i',name,'psql','-U','postgres','-XAt','-v','ON_ERROR_STOP=1',input=text)
        try:
            image=next(l.split('=',1)[1] for l in (ROOT/'envs/production/.env.db').read_text().splitlines() if l.startswith('POSTGRES_IMAGE='))
            cmd('docker','run','-d','--network','none','--name',name,'--tmpfs','/var/lib/postgresql/data','-e','POSTGRES_PASSWORD=fixture-password',image)
            # The initialization server accepts socket connections before restarting.
            # TCP readiness identifies the final server used by the bootstrap tests.
            for _ in range(30):
                if subprocess.run(['docker','exec',name,'pg_isready','-h','127.0.0.1','-U','postgres'],capture_output=True).returncode==0: break
                time.sleep(1)
            else:
                logs = subprocess.run(['docker','logs',name],capture_output=True,text=True)
                self.fail('PostgreSQL fixture never became TCP-ready: '+logs.stderr[-2000:])
            for file,role,db,var in [('scraping-app.sql','scraping_crawler','scraping','scraping_crawler_password'),('iceberg-catalog.sql','iceberg_catalog','iceberg_catalog','iceberg_catalog_password'),('vestiaire-developer-platform.sql','vestiaire_developer_app','vestiaire_developer','vestiaire_developer_app_password')]:
                if not (ROOT/'bootstrap'/file).exists():
                    continue
                with self.subTest(file=file):
                    def provision(password):
                        return cmd('docker','exec','-i',name,'psql','-U','postgres','-XAt','-v','ON_ERROR_STOP=1','-v',var+'='+password,'-v','fashion_catalog_reader_password=fixture-reader-password-32-characters',input=(ROOT/'bootstrap'/file).read_text())
                    provision('fixture-app-password-with-32-characters')
                    before=sql("SELECT rolpassword FROM pg_authid WHERE rolname='"+role+"'")
                    provision('different-fixture-password-with-32-characters')
                    self.assertTrue(before==sql("SELECT rolpassword FROM pg_authid WHERE rolname='"+role+"'"),'Bootstrap rotated existing credential')
                    self.assertEqual(sql("SELECT count(*) FROM pg_database d, LATERAL aclexplode(COALESCE(d.datacl,acldefault('d',d.datdba))) a WHERE d.datname='"+db+"' AND a.grantee=0"),'0')
                    sql('ALTER ROLE '+role+' SUPERUSER;')
                    with self.assertRaises(subprocess.CalledProcessError):provision('fixture-password-32-characters-long')
                    sql('ALTER ROLE '+role+' NOSUPERUSER;')
            def reader(password):
                return cmd('docker','exec','-i',name,'psql','-U','postgres','-XAt','-v','ON_ERROR_STOP=1','-v','fashion_catalog_reader_password='+password,input=(ROOT/'bootstrap/fashion-catalog-reader.sql').read_text())
            reader('fixture-reader-password-with-32-characters')
            old=sql("SELECT rolpassword FROM pg_authid WHERE rolname='fashion_catalog_reader'")
            reader('different-reader-password-with-32-characters')
            self.assertTrue(old==sql("SELECT rolpassword FROM pg_authid WHERE rolname='fashion_catalog_reader'"))
            cmd('docker','exec',name,'psql','-U','postgres','-d','scraping','-v','ON_ERROR_STOP=1','-c','SET ROLE scraping_crawler; CREATE TABLE fixture(id int); INSERT INTO fixture VALUES(1);')
            self.assertEqual(cmd('docker','exec',name,'psql','-U','postgres','-d','scraping','-XAt','-v','ON_ERROR_STOP=1','-c','SET ROLE fashion_catalog_reader; SELECT count(*) FROM fixture;').splitlines()[-1],'1')
            with self.assertRaises(subprocess.CalledProcessError):
                cmd('docker','exec',name,'psql','-U','postgres','-d','scraping','-v','ON_ERROR_STOP=1','-c','SET ROLE fashion_catalog_reader; INSERT INTO fixture VALUES(2);')
        finally: subprocess.run(['docker','rm','-f',name],capture_output=True)
if __name__=='__main__':unittest.main()
