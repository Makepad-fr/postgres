#!/usr/bin/env python3
"""Keep builds local; route disposable Brio PostgreSQL to the database host.

The local container is a TCP link, preserving existing loopback URLs. SQL and
readiness commands go only to the corresponding managed remote test database.
"""
import base64
import json
import os
from pathlib import Path
import re
import shutil
import socket
import struct
import subprocess
import sys
import tempfile

DOCKER='/usr/bin/docker'
SSH=['/usr/bin/ssh','-T','-o','BatchMode=yes','-o','IdentitiesOnly=yes',
     '-o','StrictHostKeyChecking=yes','-o','UserKnownHostsFile=/etc/makepad-ci-databases/known_hosts',
     '-i','/etc/makepad-ci-databases/id_ed25519','root@10.80.0.2']
PROXY='haproxy@sha256:6343ce34a132a5dceaa24767d739df2bd519f8f7c1079ae39e4821334e8eb42e'
LABEL='makepad.remote-ci-database'
PATTERN=re.compile(r'brio-(?:browser-postgres|postgres-integration)-[0-9]+-[0-9]+')
original=sys.argv[1:]
def passthrough(): os.execv(DOCKER,[DOCKER]+original)
def rpc(data):
    result=subprocess.run(SSH,input=json.dumps(data).encode(),capture_output=True)
    if result.returncode: raise RuntimeError('Remote CI database connection failed: '+result.stderr.decode())
    return json.loads(result.stdout)
def emit(result):
    sys.stdout.buffer.write(base64.b64decode(result['stdout']))
    sys.stderr.buffer.write(base64.b64decode(result['stderr']))
    return result['code']
def managed(name):
    p=subprocess.run([DOCKER,'inspect','--format','{{index .Config.Labels "'+LABEL+'"}}',name],capture_output=True,text=True)
    return p.returncode==0 and p.stdout.strip()=='true'
def postgres_route_ready(port):
    # Connecting to HAProxy alone is insufficient: an unavailable backend
    # accepts then closes the client socket. Require a PostgreSQL response.
    try:
        with socket.create_connection(('127.0.0.1', port), timeout=1) as connection:
            connection.settimeout(1)
            connection.sendall(struct.pack('!II', 8, 80877103))
            return connection.recv(1) in (b'N', b'S')
    except OSError:
        return False

def main():
    if not original: passthrough()
    # Intercept only the standard local CLI invocation used by test harnesses.
    action=original[0]
    if action=='run':
        options=original[1:];name=None;password=None;database='postgres';image=None;i=0
        candidate=options[options.index('--name')+1] if '--name' in options and options.index('--name')+1<len(options) else ''
        if not PATTERN.fullmatch(candidate): passthrough()
        while i<len(options):
            arg=options[i]
            if arg in ['-d','--detach','--rm']: i+=1;continue
            if arg in ['--name','-e','--env','-p','--publish'] and i+1<len(options):
                val=options[i+1]
                if arg=='--name':name=val
                if arg in ['-e','--env']:
                    if val.startswith('POSTGRES_PASSWORD='):password=val.split('=',1)[1]
                    elif val.startswith('POSTGRES_DB='):database=val.split('=',1)[1]
                    else: raise RuntimeError('Unsupported CI database environment option')
                i+=2;continue
            if arg.startswith('-'): raise RuntimeError('Unsupported CI database run option: '+arg)
            image=arg
            if i!=len(options)-1: raise RuntimeError('Custom CI database commands are not allowed')
            break
        if image not in ['postgres:16-alpine','postgres:16-alpine@sha256:57c72fd2a128e416c7fcc499958864df5301e940bca0a56f58fddf30ffc07777']:
            raise RuntimeError('CI database image is not approved for the database host')
        if not password: raise RuntimeError('Test PostgreSQL password is required')
        result=rpc({'action':'create','name':name,'password':password,'database':database})
        if result['code']: return emit(result)
        directory=Path(tempfile.mkdtemp(prefix='makepad-ci-db-link-'))
        config=directory/'haproxy.cfg'
        config.write_text('global\n  maxconn 256\ndefaults\n  mode tcp\n  timeout connect 5s\n  timeout client 10m\n  timeout server 10m\nlisten database\n  bind :5432\n  server postgres 10.80.0.2:'+str(result['port'])+' check inter 1s\n')
        config.chmod(0o644)
        cmd=[DOCKER,'run','--detach','--name',name,'--label',LABEL+'=true',
             '--label','makepad.proxy-config='+str(directory),'--publish','127.0.0.1::5432',
             '--memory','64m','--volume',str(config)+':/usr/local/etc/haproxy/haproxy.cfg:ro',PROXY]
        proxy=subprocess.run(cmd,capture_output=True)
        if proxy.returncode:
            rpc({'action':'remove','name':name});shutil.rmtree(directory)
            sys.stderr.buffer.write(proxy.stderr);return proxy.returncode
        sys.stdout.buffer.write(proxy.stdout);return 0
    if action in ['exec','rm','logs']:
        args=original[1:];name=next((a for a in args if PATTERN.fullmatch(a)),None)
        if not name or not managed(name): passthrough()
        if action=='exec':
            index=args.index(name)
            data=sys.stdin.buffer.read() if any(a in ['-i','--interactive'] for a in args[:index]) else b''
            command=args[index+1:]
            result=rpc({'action':'exec','name':name,'args':command,'input':base64.b64encode(data).decode()})
            if command and command[0]=='pg_isready' and result['code']==0:
                published=subprocess.check_output([DOCKER,'port',name,'5432/tcp'],text=True).splitlines()[0]
                if not postgres_route_ready(int(published.rsplit(':',1)[1])):
                    return 1
            return emit(result)
        if action=='logs': return emit(rpc({'action':'logs','name':name}))
        result=rpc({'action':'remove','name':name})
        if result['code']: return emit(result)
        path=subprocess.check_output([DOCKER,'inspect','--format','{{index .Config.Labels "makepad.proxy-config"}}',name],text=True).strip()
        subprocess.run([DOCKER,'rm','--force',name],check=True)
        p=Path(path)
        if p.parent==Path('/tmp') and p.name.startswith('makepad-ci-db-link-') and p.stat().st_uid==os.getuid(): shutil.rmtree(p)
        return 0
    passthrough()
if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception as exc:
        print(str(exc),file=sys.stderr)
        sys.exit(1)
