#!/usr/bin/env python3
"""Forced SSH command: provision only labelled, disposable Brio PostgreSQL."""
import base64
import json
import re
import subprocess
import sys

IMAGE='postgres:16-alpine@sha256:57c72fd2a128e416c7fcc499958864df5301e940bca0a56f58fddf30ffc07777'
LABEL='makepad.ci-database'
def invoke(args, data=None):
    p=subprocess.run(['/usr/bin/docker']+args,input=data,capture_output=True)
    return {'code':p.returncode,'stdout':base64.b64encode(p.stdout).decode(),'stderr':base64.b64encode(p.stderr).decode()}
def main():
    request=json.loads(sys.stdin.buffer.read(20*1024*1024))
    name=request.get('name','')
    if not re.fullmatch(r'brio-(browser-postgres|postgres-integration)-[0-9]+-[0-9]+',name):
        raise ValueError('Database name is outside the allowed CI scope')
    action=request.get('action')
    if action=='create':
        password=request['password'];database=request.get('database','postgres')
        if not re.fullmatch(r'[A-Za-z0-9_-]{1,63}',database) or not isinstance(password,str) or len(password)>256:
            raise ValueError('Invalid test database settings')
        count=subprocess.check_output(['/usr/bin/docker','ps','-q','--filter','label='+LABEL+'=true'],text=True).split()
        if len(count)>=12: raise ValueError('CI database concurrency limit reached')
        response=invoke(['run','--detach','--rm','--name',name,'--label',LABEL+'=true',
            '--network','makepad-ci-databases','--publish','10.80.0.2::5432',
            '--memory','1g','--cpus','2','--pids-limit','256','--security-opt','no-new-privileges',
            '--tmpfs','/var/lib/postgresql/data:rw,size=512m',
            '--env','POSTGRES_PASSWORD='+password,'--env','POSTGRES_DB='+database,IMAGE])
        if response['code']==0:
            raw=subprocess.check_output(['/usr/bin/docker','port',name,'5432/tcp'],text=True).strip()
            response['port']=int(raw.rsplit(':',1)[1])
        return response
    result=subprocess.run(['/usr/bin/docker','inspect','--format','{{index .Config.Labels "'+LABEL+'"}}',name],capture_output=True,text=True)
    if result.returncode or result.stdout.strip()!='true': raise ValueError('Not a managed CI database')
    if action=='exec':
        args=request.get('args',[])
        if not args or args[0] not in ['psql','pg_isready']: raise ValueError('Only PostgreSQL test tools are permitted')
        data=base64.b64decode(request.get('input',''),validate=True)
        return invoke(['exec','-i',name]+args,data)
    if action=='logs': return invoke(['logs','--tail','200',name])
    if action=='remove': return invoke(['rm','--force',name])
    raise ValueError('Unsupported operation')
try:
    print(json.dumps(main()))
except Exception as exc:
    print(json.dumps({'code':1,'stdout':'','stderr':base64.b64encode(str(exc).encode()).decode()}))
