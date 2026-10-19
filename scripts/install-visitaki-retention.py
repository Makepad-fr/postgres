#!/usr/bin/env python3
"""Install the reviewed Visitaki retention helper on its existing database host."""
import hashlib
import os
from pathlib import Path
import socket
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
TARGET = Path('/srv/makepad/visitaki-backups')


def main():
    if os.geteuid() != 0 or socket.gethostname() != 'db-server-1':
        raise RuntimeError('Authorized database host required')
    # Existing helper must match reviewed source; never upgrade backup code here.
    expected = (ROOT / 'scripts/visitaki-encrypted-backup.py').read_bytes()
    installed = TARGET / 'visitaki-encrypted-backup.py'
    if installed.is_symlink() or installed.read_bytes() != expected:
        raise RuntimeError('Installed backup helper differs from reviewed source')
    helper = (ROOT / 'scripts/visitaki-backup-retention.py').read_bytes()
    compile(helper, 'visitaki-backup-retention.py', 'exec')
    units = ['visitaki-postgres-retention.service','visitaki-postgres-retention.timer']
    subprocess.run(['systemd-analyze','verify',*[str(ROOT / 'systemd' / n) for n in units]],check=True)
    for target, contents, mode in [(TARGET/'visitaki-backup-retention.py',helper,0o600),
            *[(Path('/etc/systemd/system')/n,(ROOT/'systemd'/n).read_bytes(),0o644) for n in units]]:
        if target.is_symlink():
            raise RuntimeError('Refusing symlink target')
        with tempfile.NamedTemporaryFile(dir=target.parent,delete=False) as temporary:
            temporary.write(contents);temporary.flush();os.fsync(temporary.fileno())
            os.fchmod(temporary.fileno(),mode)
            name=temporary.name
        try:os.replace(name,target)
        finally:Path(name).unlink(missing_ok=True)
        if target.read_bytes()!=contents:
            raise RuntimeError('Installation verification failed')
    subprocess.run(['systemctl','daemon-reload'],check=True)
    subprocess.run(['systemctl','enable','--now','visitaki-postgres-retention.timer'],check=True)
    print('Installed retention helper SHA256 '+hashlib.sha256(helper).hexdigest())
    # Timer installation is not proof that an expiry operation has succeeded.


if __name__=='__main__':main()
