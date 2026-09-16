#!/usr/bin/env python3
"""Replace only VIF's stopped storage tasks with private TCP links."""
import json
import re
import shutil
from pathlib import Path
import subprocess

p=Path('/var/lib/makepad/db-migration-20260916/vif')
source=Path('/home/makepad/vif-app/current')
original=json.loads((p/'original-services.json').read_text())
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
