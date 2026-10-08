"""Add or validate the complete BetaCrew HBA block without altering other rules."""
import os
from pathlib import Path
import sys
import tempfile

RULES = [
 'hostnossl betacrew all all reject',
 'hostnossl keycloak_betacrew all all reject',
 'hostssl betacrew betacrew_app 10.80.0.1/32 scram-sha-256',
 'hostssl keycloak_betacrew keycloak_betacrew_app 88.99.209.165/32 scram-sha-256',
 'hostssl betacrew postgres 127.0.0.1/32 scram-sha-256',
 'hostssl keycloak_betacrew postgres 127.0.0.1/32 scram-sha-256',
 'hostssl betacrew all all reject',
 'hostssl keycloak_betacrew all all reject',
]

def apply(path):
    if path.is_symlink() or not path.is_file():
        raise ValueError('HBA path must be a regular non-symlink file')
    stat = path.stat()
    lines = path.read_text().splitlines(keepends=True)
    parsed = [(i, line.split('#', 1)[0].split()) for i, line in enumerate(lines)]
    scoped = [(i, ' '.join(parts)) for i, parts in parsed if len(parts)>1 and set(parts[1].split(',')) & {'betacrew','keycloak_betacrew'}]
    broad = [i for i, parts in parsed if len(parts)>1 and parts[0].startswith('host') and 'all' in parts[1].split(',')]
    fallback = [i for i, parts in parsed if parts == 'host all all all scram-sha-256'.split()]
    if len(fallback)!=1 or broad != fallback:
        raise ValueError('Ambiguous shared fallback rules; manual inspection required')
    if scoped:
        if [rule for _, rule in scoped] != RULES or max(i for i,_ in scoped)>=fallback[0]:
            raise ValueError('Partial, reordered or shadowed BetaCrew policy; refusing mutation')
        return
    lines.insert(fallback[0], '# BetaCrew TLS and exact source restrictions\n'+'\n'.join(RULES)+'\n')
    fd, temporary = tempfile.mkstemp(prefix=path.name+'.betacrew.', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as out:
            os.fchmod(out.fileno(), stat.st_mode & 0o7777)
            if (os.fstat(out.fileno()).st_uid, os.fstat(out.fileno()).st_gid)!=(stat.st_uid,stat.st_gid):
                os.fchown(out.fileno(),stat.st_uid,stat.st_gid)
            out.write(''.join(lines));out.flush();os.fsync(out.fileno())
        os.replace(temporary,path)
    finally:
        if os.path.exists(temporary):os.unlink(temporary)

if __name__=='__main__':
    try: apply(Path(sys.argv[1]))
    except (ValueError,OSError) as error:
        print(str(error),file=sys.stderr);sys.exit(1)
