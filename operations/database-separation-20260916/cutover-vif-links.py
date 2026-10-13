#!/usr/bin/env python3
"""Replace only VIF's stopped storage tasks with private TCP links."""
import json
import os
import re
import shutil
from pathlib import Path
import subprocess

p=Path('/var/lib/makepad/db-migration-20260916/vif')
source=Path('/home/makepad/vif-app/current')
original=json.loads((p/'original-services.json').read_text())
# Archived one-off operation: fail before rollback/config writes unless both
# original storage services are still present, unchanged, and fully stopped.
os.umask(0o077)
names = {'vif_etcd', 'vif_vault'}
try:
    expected = {row['Spec']['Name']: row['Spec']['TaskTemplate']['ContainerSpec']
                for row in original if row['Spec']['Name'] in names}
    current = json.loads(subprocess.check_output(['docker', 'service', 'inspect', *sorted(names)], text=True))
    if len(current) != 2 or set(expected) != names or {row['Spec']['Name'] for row in current} != names:
        raise SystemExit('Expected the two original VIF storage services')
    for row in current:
        spec = row['Spec']
        if spec['Mode'].get('Replicated', {}).get('Replicas') != 0:
            raise SystemExit('Refusing cutover: storage replicas must be zero')
        if spec['TaskTemplate']['ContainerSpec'] != expected[spec['Name']]:
            raise SystemExit('Refusing cutover: storage configuration changed since capture')
        tasks = subprocess.check_output(['docker', 'service', 'ps', '--no-trunc', '-q', spec['Name']], text=True).split()
        if tasks:
            states = json.loads(subprocess.check_output(['docker', 'inspect', *tasks], text=True))
            if any(task['Status']['State'] not in {'shutdown', 'complete', 'failed', 'rejected', 'remove'} for task in states):
                raise SystemExit('Refusing cutover: storage tasks have not fully stopped')
except (KeyError, TypeError, ValueError) as error:
    raise SystemExit('Invalid VIF storage capture or current service metadata') from error
image='haproxy@sha256:6343ce34a132a5dceaa24767d739df2bd519f8f7c1079ae39e4821334e8eb42e'
compose=source/'compose.yml'
backup=p/'original-compose.yml'
if backup.exists(): raise SystemExit('Refusing to overwrite rollback configuration')
backup.write_bytes(compose.read_bytes())
text=compose.read_text()
configs=source/'infra/database-links'
configs.mkdir(exist_ok=True)
for name in ['etcd','vault']:
    cfg=configs/(name+'.cfg')
    shutil.copyfile(p/(name+'-db-link.cfg'),cfg)
    cfg.chmod(0o644)
    definition=f'''  {name}:
    image: {image}
    entrypoint: ["haproxy"]
    command: ["-f", "/usr/local/etc/haproxy/haproxy.cfg"]
    volumes:
      - ./infra/database-links/{name}.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro
    healthcheck:
      test: ["CMD", "haproxy", "-c", "-f", "/usr/local/etc/haproxy/haproxy.cfg"]
      interval: 5s
      timeout: 3s
      retries: 20
    deploy:
      labels:
        makepad.role: database-tcp-link

'''
    text,n=re.subn(r'^  '+name+r':\n.*?(?=^  [A-Za-z0-9_-]+:|^[A-Za-z]|\Z)',lambda _:definition,text,flags=re.M|re.S)
    assert n==1,(name,n)
    spec=next(x['Spec']['TaskTemplate']['ContainerSpec'] for x in original if x['Spec']['Name']=='vif_'+name)
    cmd=['docker','service','update','--detach','--image',image,'--entrypoint','haproxy','--args','-f /usr/local/etc/haproxy/haproxy.cfg','--health-cmd','haproxy -c -f /usr/local/etc/haproxy/haproxy.cfg','--label-add','makepad.role=database-tcp-link']
    for m in spec.get('Mounts',[]): cmd+=['--mount-rm',m['Target']]
    for env in spec.get('Env',[]): cmd+=['--env-rm',env.split('=',1)[0]]
    cmd+=['--mount-add','type=bind,src='+str(cfg)+',dst=/usr/local/etc/haproxy/haproxy.cfg,readonly','vif_'+name]
    subprocess.run(cmd,check=True)
compose.write_text(text)
subprocess.run(['docker','service','scale','--detach','vif_etcd=1','vif_vault=1'],check=True)
print('VIF storage services now contain TCP links; original volumes retained')
