#!/usr/bin/env python3
"""Capture live VIF storage specifications and prepare standalone DB services."""
import json
import os
from pathlib import Path
import subprocess

os.umask(0o077)
p=Path('/var/lib/makepad/db-migration-20260916/vif')
p.mkdir(exist_ok=False)
services=json.loads(subprocess.check_output(['docker','service','inspect']+subprocess.check_output(['docker','service','ls','-q','--filter','label=com.docker.stack.namespace=vif'],text=True).split()))
(p/'original-services.json').write_text(json.dumps(services,indent=2))
db={'name':'vif-storage','services':{},'volumes':{},'networks':{'default':{'ipam':{'config':[{'subnet':'172.30.61.0/24'}]}}}}
images=[]
for name,inside,outside in [('etcd',2379,12379),('vault',8200,18200)]:
    spec=next(s['Spec']['TaskTemplate']['ContainerSpec'] for s in services if s['Spec']['Name']=='vif_'+name)
    cid=subprocess.check_output(['docker','ps','-q','--filter','name=vif_'+name+'.1'],text=True).strip()
    image=subprocess.check_output(['docker','inspect','--format','{{.Image}}',cid],text=True).strip()
    images.append(image)
    mounts=[]
    for m in spec.get('Mounts',[]):
        if m['Type']=='volume':
            logical=m['Source'];db['volumes'][logical]={'name':'vif-migrated-'+logical,'external':True}
            mounts.append({'type':'volume','source':logical,'target':m['Target']})
        else:
            mounts.append({'type':'bind','source':str(p/'vault.hcl'),'target':m['Target'],'read_only':True})
            (p/'vault.hcl').write_bytes(Path(m['Source']).read_bytes())
            (p/'vault.hcl').chmod(Path(m['Source']).stat().st_mode & 0o777)
    health=spec.get('Healthcheck',{})
    db['services'][name]={'image':image,'command':spec.get('Args',[]),'restart':'unless-stopped',
        'environment':spec.get('Env',[]),'volumes':mounts,
        'ports':[{'host_ip':'10.80.0.2','published':str(outside),'target':inside}],
        'healthcheck':{'test':health['Test'],'interval':'5s','timeout':'3s','retries':20}}
    if spec.get('CapabilityAdd'): db['services'][name]['cap_add']=spec['CapabilityAdd']
    conf=p/(name+'-db-link.cfg')
    conf.write_text(f'global\n  maxconn 1024\ndefaults\n  mode tcp\n  timeout connect 5s\n  timeout client 1h\n  timeout server 1h\nlisten storage\n  bind :{inside}\n  server database 10.80.0.2:{outside} check inter 2s\n')
    conf.chmod(0o644)
def escape(x):
    if isinstance(x,str): return x.replace('$','$$')
    if isinstance(x,list): return [escape(v) for v in x]
    if isinstance(x,dict): return {k:escape(v) for k,v in x.items()}
    return x
(p/'db-compose.json').write_text(json.dumps(escape(db),indent=2))
(p/'image-ids.json').write_text(json.dumps(images))
key=Path('/var/lib/docker/volumes/current_vault_init_data/_data/keys.txt')
(p/'vault-recovery.txt').write_bytes(key.read_bytes())
print('Prepared VIF storage configuration; recovery material retained in root-only directory')
