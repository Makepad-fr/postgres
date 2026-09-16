#!/usr/bin/env python3
"""Run on the app host as root. Prepare, but do not deploy, the Sentry split.

Resolved secrets stay on the host in root-only files. The application keeps
its existing dependency names through TCP-only links over WireGuard.
"""
import copy
import json
import os
from pathlib import Path
import subprocess

os.umask(0o077)
SOURCE = Path('/srv/makepad/sentry-consent-lens')
OUT = Path('/var/lib/makepad/db-migration-20260916')
OUT.mkdir(parents=True, exist_ok=True)
PORTS = {
    'postgres': {5432: 15432}, 'pgbouncer': {5432: 16432},
    'clickhouse': {8123: 18123, 9000: 19000, 9009: 19009},
    'redis': {6379: 16379}, 'kafka': {9092: 19092, 9093: 19093},
    'memcached': {11211: 11211}, 'seaweedfs': {8333: 18333},
    'taskbroker': {50051: 15051},
}
PROXY = 'haproxy@sha256:6343ce34a132a5dceaa24767d739df2bd519f8f7c1079ae39e4821334e8eb42e'
def run(*args):
    return subprocess.check_output(args, text=True)

original_path = OUT / 'original-compose.json'
if original_path.exists():
    raise SystemExit('Snapshot already exists; refusing to overwrite rollback data.')
c = json.loads(run('docker', 'compose', '--project-directory', str(SOURCE),
    '-f', str(SOURCE / 'docker-compose.yml'), '-f', str(SOURCE / 'docker-compose.override.yml'),
    'config', '--format', 'json'))
original_path.write_text(json.dumps(c, indent=2))
app = copy.deepcopy(c)
db = {'name': 'sentry-storage', 'services': {}, 'volumes': {}, 'networks': {'default': {'ipam': {'config': [{'subnet': '172.19.0.0/16'}]}}}}
volume_map = {}
images = []
for name, ports in PORTS.items():
    s = copy.deepcopy(c['services'][name])
    images.append(s['image'])
    s.pop('build', None)
    s.pop('profiles', None)
    s.pop('container_name', None)
    s['networks'] = {'default': None}
    s['ports'] = [{'target': p, 'published': str(host), 'host_ip': '10.80.0.2', 'protocol': 'tcp'} for p, host in ports.items()]
    for v in s.get('volumes', []):
        if v['type'] == 'volume':
            logical = v['source']
            actual = c['volumes'][logical]['name']
            dest = 'sentry-migrated-' + logical
            volume_map[actual] = dest
            db['volumes'][logical] = {'name': dest, 'external': True}
    db['services'][name] = s
    del app['services'][name]
    link = name + '-db-link'
    config = ['global', '  maxconn 4096', 'defaults', '  mode tcp',
              '  timeout connect 5s', '  timeout client 1h', '  timeout server 1h']
    for port, remote in ports.items():
        config += [f'listen port_{port}', f'  bind :{port}',
                   f'  server database 10.80.0.2:{remote} check inter 2s fall 3 rise 2']
    f = OUT / (link + '.cfg')
    f.write_text('\n'.join(config) + '\n')
    f.chmod(0o644)
    app['services'][link] = {
        'image': PROXY, 'restart': 'unless-stopped',
        'volumes': [{'type': 'bind', 'source': str(f), 'target': '/usr/local/etc/haproxy/haproxy.cfg', 'read_only': True}],
        'networks': {'default': {'aliases': [name]}},
        'labels': {'makepad.role': 'database-tcp-link', 'makepad.database-host': '10.80.0.2'},
    }
for s in app['services'].values():
    s.pop('profiles', None)
    if 'depends_on' in s:
        s['depends_on'] = {(k + '-db-link' if k in PORTS else k):
            ({'condition': 'service_started', 'required': True} if k in PORTS else v)
            for k, v in s['depends_on'].items()}
used = {v['source'] for s in app['services'].values() for v in s.get('volumes', []) if v['type'] == 'volume'}
app['volumes'] = {k: v for k, v in app.get('volumes', {}).items() if k in used}
def dollar_escape(x):
    # docker compose interpolates even resolved JSON strings again.
    if isinstance(x, str): return x.replace('$', '$$')
    if isinstance(x, list): return [dollar_escape(v) for v in x]
    if isinstance(x, dict): return {k: dollar_escape(v) for k, v in x.items()}
    return x
for filename, obj in [('app-compose.json', app), ('db-compose.json', db), ('rollback-compose.json', c)]:
    (OUT / filename).write_text(json.dumps(dollar_escape(obj), indent=2))
(OUT / 'volume-map.json').write_text(json.dumps(volume_map, indent=2))
(OUT / 'storage-images.json').write_text(json.dumps(images))
print(json.dumps({'app_services': len(app['services']), 'storage_services': len(db['services']), 'volumes': volume_map}))
