"""Exercise real pg_dump/CMS/pg_restore over verified TLS in disposable PostgreSQL."""
import os
from pathlib import Path
import subprocess
import tempfile
import time
import uuid

SCRIPTS=Path(__file__).resolve().parent
IMAGE='postgres@sha256:721873c34ceb9f8d8fc265984940dc982404c105f19ad51be9fdc5970a6080ea'
container='jotwink-encrypted-test-'+uuid.uuid4().hex[:10]

def run(*args, **kw):
    result=subprocess.run(args,capture_output=True,text=True,**kw)
    if result.returncode:
        raise RuntimeError('Disposable fixture operation failed: '+result.stderr)
    return result.stdout.strip()

with tempfile.TemporaryDirectory(prefix='jotwink-encrypted-') as tmp:
    root=Path(tmp);root.chmod(0o755)
    cert=root/'server.crt';key=root/'server.key'
    run('openssl','req','-x509','-newkey','rsa:2048','-nodes','-days','1','-subj','/CN=localhost','-addext','subjectAltName=DNS:localhost,IP:127.0.0.1','-keyout',str(key),'-out',str(cert))
    # Separate recipient key from server transport credentials.
    recipient=root/'recipient.pem';private=root/'recipient.key'
    run('openssl','req','-x509','-newkey','rsa:2048','-nodes','-days','1','-subj','/CN=backup-test','-keyout',str(private),'-out',str(recipient))
    password=root/'password';password.write_text('disposable-fixture-password\n');password.chmod(0o600)
    bin=root/'bin';bin.mkdir();work=root/'tmp';work.mkdir()
    for tool in ['pg_dump','pg_restore','psql']:
        (bin/tool).write_text('#!/bin/sh\nexec docker exec -i -e PGPASSFILE -e PGSERVICEFILE -e PGSSLMODE -e PGSSLROOTCERT "$TEST_CONTAINER" '+tool+' "$@"\n')
        (bin/tool).chmod(0o700)
    env=dict(os.environ,PATH=str(bin)+os.pathsep+os.environ['PATH'],TEST_CONTAINER=container,TMPDIR=str(work),PGUSER='postgres',PGHOST='127.0.0.1',PGSSLMODE='verify-full',PGSSLROOTCERT=str(cert),POSTGRES_SUPERUSER_PASSWORD_FILE=str(password),JOTWINK_BACKUP_ENCRYPTION_CERT=str(recipient),JOTWINK_BACKUP_ROOT=str(root/'backups'))
    def sql(database,query):
        return run('docker','exec','-i',container,'psql','-U','postgres','-d',database,'-XAt','-v','ON_ERROR_STOP=1',input=query)
    try:
        run('docker','run','-d','--network','none','--name',container,'--tmpfs','/var/lib/postgresql/data','--volume',tmp+':'+tmp,'-e','POSTGRES_PASSWORD=disposable-fixture-password',IMAGE)
        for _ in range(30):
            if subprocess.run(['docker','exec',container,'pg_isready','-U','postgres'],capture_output=True).returncode==0:break
            time.sleep(1)
        run('docker','cp',str(cert),container+':/tmp/server.crt');run('docker','cp',str(key),container+':/tmp/server.key')
        run('docker','exec',container,'chown','postgres:postgres','/tmp/server.crt','/tmp/server.key')
        run('docker','exec',container,'chmod','600','/tmp/server.key')
        sql('postgres',"ALTER SYSTEM SET ssl='on';\nALTER SYSTEM SET ssl_cert_file='/tmp/server.crt';\nALTER SYSTEM SET ssl_key_file='/tmp/server.key';\nSELECT pg_reload_conf();")
        sql('postgres','CREATE DATABASE jotwink; CREATE DATABASE keycloak_jotwink; CREATE DATABASE jotwink_restore_test; CREATE DATABASE keycloak_jotwink_restore_test;')
        sql('jotwink',"CREATE TABLE schema_migrations(version text); INSERT INTO schema_migrations VALUES ('real-backup-test');")
        sql('keycloak_jotwink',"CREATE TABLE realm(id text); INSERT INTO realm VALUES ('isolated-identity-test');")
        run('sh',str(SCRIPTS/'run-jotwink-backup.sh'),env=env)
        backup=(root/'backups/latest').resolve()
        services=root/'services.conf'
        services.write_text(''.join(f'[{name}]\nhost=127.0.0.1\nuser=postgres\npassword=disposable-fixture-password\ndbname={db}\nsslrootcert={cert}\n' for name,db in [('app','jotwink_restore_test'),('identity','keycloak_jotwink_restore_test')]))
        services.chmod(0o600)
        env.update(PGSERVICEFILE=str(services),JOTWINK_RESTORE_SERVICE='app',KEYCLOAK_JOTWINK_RESTORE_SERVICE='identity',JOTWINK_RESTORE_CONFIRM='replace-nonproduction-restore-targets',JOTWINK_BACKUP_DECRYPTION_CERT=str(recipient),JOTWINK_BACKUP_DECRYPTION_KEY=str(private))
        run('bash',str(SCRIPTS/'verify-jotwink-restore.sh'),str(backup),env=env)
        assert sql('jotwink_restore_test','SELECT version FROM schema_migrations')=='real-backup-test'
        assert sql('keycloak_jotwink_restore_test','SELECT id FROM realm')=='isolated-identity-test'
        # Re-running against populated destinations must fail before replacing rows.
        failed=subprocess.run(['bash',str(SCRIPTS/'verify-jotwink-restore.sh'),str(backup)],env=env,capture_output=True)
        assert failed.returncode != 0
        assert sql('jotwink_restore_test','SELECT version FROM schema_migrations')=='real-backup-test'
        # Disabling TLS cannot create an allegedly verified backup.
        assert subprocess.run(['sh',str(SCRIPTS/'run-jotwink-backup.sh')],env=dict(env,PGSSLMODE='disable'),capture_output=True).returncode != 0
        print('PASS: real PostgreSQL dumps, verified TLS, CMS encryption, both restored datasets, nonempty-target preservation and TLS-downgrade rejection')
    finally:
        subprocess.run(['docker','rm','-f',container],capture_output=True)
