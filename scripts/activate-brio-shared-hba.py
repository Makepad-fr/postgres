#!/usr/bin/env python3
"""Activate Brio-only access rules on the existing standalone PostgreSQL service.

Preserves the running non-Brio policy and the original on-disk policy. The
HBA mount is replaced through Compose because file bind mounts retain old
inodes after atomic host-file replacement. No image upgrade is performed.
"""
import argparse, json, os, pathlib, re, subprocess, time

ROOT = pathlib.Path('/srv/makepad/postgres')
ENV = ROOT / 'envs/production/.env.db'
TARGET = ROOT / 'config/brio-shared-pg_hba.conf'
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--recovery-id', required=True)
parser.add_argument('--backup-directory', type=pathlib.Path, required=True)
args = parser.parse_args()
if not re.fullmatch(r'[a-z0-9][a-z0-9-]{0,63}', args.recovery_id):
    raise SystemExit('Invalid recovery identifier')
RECOVERY = pathlib.Path('/var/lib/makepad/postgres-recovery') / args.recovery_id
CONTAINER = 'postgres-postgres-1'
DEST = '/etc/postgresql/runtrace-pg_hba.conf'
SETTING = 'MAKEPAD_POSTGRES_RUNTRACE_HBA_HOST_PATH'
RULES = '''# Brio uses shared PostgreSQL, with dedicated roles and exact source addresses.
hostnossl brio_staging all all reject
hostnossl keycloak_brio_staging all all reject
hostssl brio_staging brio_staging_app 10.80.0.1/32 scram-sha-256
hostssl brio_staging brio_staging_backup 127.0.0.1/32 scram-sha-256
hostssl keycloak_brio_staging keycloak_brio_staging_app 127.0.0.1/32 scram-sha-256
hostssl keycloak_brio_staging keycloak_brio_staging_app 88.99.209.165/32 scram-sha-256
hostssl keycloak_brio_staging keycloak_brio_staging_backup 127.0.0.1/32 scram-sha-256
host all brio_staging_app all reject
host all brio_staging_backup all reject
host all keycloak_brio_staging_app all reject
host all keycloak_brio_staging_backup all reject
'''

def run(*args, **kwargs):
    return subprocess.check_output(list(args), **kwargs).decode()

def compose(*args, **kwargs):
    return run('docker', 'compose', '--project-name', 'postgres', '--env-file', str(ENV), '-f', str(ROOT/'compose.host.yml'), *args, **kwargs)

def healthy():
    for _ in range(45):
        state=json.loads(run('docker','inspect',CONTAINER))[0]['State']
        if state.get('Health',{}).get('Status')=='healthy': return
        time.sleep(1)
    raise RuntimeError('Shared PostgreSQL did not recover healthy')

if os.geteuid()!=0: raise SystemExit('Run as root on the DB VM')
old=json.loads(run('docker','inspect',CONTAINER))[0]
assert old['HostConfig']['NetworkMode']=='host'
assert old['Config']['Labels']['com.docker.compose.project']=='postgres'
assert old['Config']['Labels']['com.docker.compose.service']=='postgres'
assert old['State']['Health']['Status']=='healthy'
assert (args.backup_directory/'brio_staging.dump.cms').is_file()
assert (args.backup_directory/'keycloak_brio_staging.dump.cms').is_file()
active=run('docker','exec',CONTAINER,'cat',DEST)
if str(TARGET) in [m['Source'] for m in old['Mounts']] and RULES in active:
    print('Brio shared access rules already active'); raise SystemExit(0)
# This first activation expects the previously observed shared policy. Refuse
# unexpected Brio edits instead of guessing how to combine access rules.
assert 'brio_staging' not in active
lines=active.splitlines(keepends=True)
fallback=[i for i,line in enumerate(lines) if line.split()==['host','all','all','all','scram-sha-256']]
assert len(fallback)==1
lines.insert(fallback[0],RULES)
assert not RECOVERY.exists(), 'Recovery directory already exists; inspect before retrying'
RECOVERY.mkdir(mode=0o700,parents=True)
old_env=ENV.read_bytes()
(RECOVERY/'environment.before').write_bytes(old_env)
(RECOVERY/'active-hba.before').write_text(active)
(RECOVERY/'container.before.json').write_text(json.dumps(old))
for p in RECOVERY.iterdir(): p.chmod(0o600)
assert not TARGET.is_symlink()
if TARGET.exists():
    assert TARGET.read_text()==''.join(lines), 'Refusing to overwrite a different staged HBA'
else:
    TARGET.write_text(''.join(lines))
TARGET.chmod(0o644)
new_lines=[line for line in old_env.decode().splitlines() if not line.startswith(SETTING+'=')]
new_lines.append(SETTING+'='+str(TARGET))
armed=False
try:
    ENV.write_text('\n'.join(new_lines)+'\n')
    candidate=json.loads(compose('config','--format','json'))['services']['postgres']
    image_id=run('docker','image','inspect',candidate['image'],'--format','{{.Id}}').strip()
    assert image_id==old['Image'], 'Refusing an unrelated image change'
    assert candidate['network_mode']=='host'
    assert candidate['command']==old['Config']['Cmd'], 'Refusing an unrelated command change'
    actual_env=dict(v.split('=',1) for v in old['Config']['Env'])
    assert all(str(actual_env.get(k))==str(v) for k,v in candidate['environment'].items())
    previous={v['Destination']:(v['Source'],not v['RW']) for v in old['Mounts']}
    rendered={v['target']:(v['source'],v.get('read_only',False)) for v in candidate['volumes']}
    assert set(previous)==set(rendered)
    assert all(rendered[k]==v for k,v in previous.items() if k!=DEST), 'Refusing unrelated mount changes'
    assert rendered[DEST]==(str(TARGET),True)
    armed=True
    compose('up','-d','--no-deps','--pull','never','postgres',stderr=subprocess.STDOUT)
    healthy()
    errors=run('docker','exec',CONTAINER,'psql','-X','-U','postgres','-Atc','SELECT count(*) FROM pg_hba_file_rules WHERE error IS NOT NULL').strip()
    assert errors=='0'
    assert run('docker','exec',CONTAINER,'cat',DEST)==TARGET.read_text()
    (RECOVERY/'activation-passed').write_text('Brio shared HBA active; identical PostgreSQL image, command, environment and other mounts.\n')
    print('Brio access rules activated on shared PostgreSQL; healthy; no HBA parsing errors.')
except BaseException:
    ENV.write_bytes(old_env)
    if armed:
        rollback_lines=[line for line in old_env.decode().splitlines() if not line.startswith(SETTING+'=')]
        rollback_lines.append(SETTING+'='+str(RECOVERY/'active-hba.before'))
        ENV.write_text('\n'.join(rollback_lines)+'\n')
        compose('up','-d','--no-deps','--pull','never','postgres',stderr=subprocess.STDOUT)
        healthy()
    raise
