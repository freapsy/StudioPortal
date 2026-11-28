#!/usr/bin/env python3
"""Install the restricted bigki worker (worker, card broker, view preparation) using the existing Mac mini connection.

Each Mac gets its own key, limited to its Tailscale address and to the worker (forced command):
    setup_bigki.py                                   # MacBook (default key, MAC-1-IP)
    setup_bigki.py --key mini.pub --source 100.x.y.z --name mac-mini
Every existing StudioPortal key on bigki is moved to the new worker version at the same time.
"""
import socket
import argparse
import base64
import hashlib
import json
from pathlib import Path
import shlex
import subprocess

project = Path(__file__).resolve().parent
parser = argparse.ArgumentParser()
parser.add_argument('--key', type=Path, default=Path.home() / '.ssh' / '3d-modelle-bigki.pub')
parser.add_argument('--source', default='MAC-1-IP', help='Tailscale address of the Mac that uses this key')
parser.add_argument('--name', default='macbook')
parser.add_argument('--files-only', action='store_true', help='only install the new version, keep keys')
parser.add_argument('--via-session', action='store_true',
                    help='files-only install through the app key -> worker -> Blender session (when the Mac mini is offline)')
options = parser.parse_args()

files = {name: (project / 'src' / name).read_bytes() for name in ('bigki_worker.py', 'gpu_broker.py', 'prepare_views.py', 'blender_session.py', 'studio_figur.py', 'studio_helfer.py', 'omni_figur.py')}
files['ARCHITEKTUR.md'] = (project / 'ARCHITEKTUR.md').read_bytes()
version = hashlib.sha256(b'\0'.join(files[name] for name in sorted(files))).hexdigest()[:16]
payload = json.dumps({'public_key': options.key.read_text().strip(), 'version': version, 'source': options.source,
                      'name': options.name, 'files_only': options.files_only,
                      'files': {name: base64.b64encode(data).decode('ascii') for name, data in files.items()}}).encode()

installer = r'''
import base64, fcntl, hashlib, ipaddress, json, os, pwd, re, stat, sys, tempfile
from pathlib import Path
p=json.load(sys.stdin)
assert pwd.getpwuid(os.getuid()).pw_name == 'bigki'
files={name: base64.b64decode(data, validate=True) for name, data in p['files'].items()}
assert set(files) == {'bigki_worker.py', 'gpu_broker.py', 'prepare_views.py', 'blender_session.py', 'studio_figur.py', 'studio_helfer.py', 'omni_figur.py', 'ARCHITEKTUR.md'}
version=hashlib.sha256(b'\0'.join(files[name] for name in sorted(files))).hexdigest()[:16]
assert version == p['version'] and re.fullmatch('[0-9a-f]{16}', version)
source=str(ipaddress.ip_address(p['source']))
name=p['name']; assert re.fullmatch('[a-z0-9-]{1,30}', name)
key=p['public_key'].split()
assert len(key)>=2 and key[0]=='ssh-ed25519' and re.fullmatch('[A-Za-z0-9+/=]+', key[1])
base=Path.home()/'.local/share/3d-modelle-app'
directory=base/version
directory.mkdir(mode=0o700, parents=True, exist_ok=True)
for filename, data in files.items():
    path=directory/('worker.py' if filename=='bigki_worker.py' else filename)
    try:
        with path.open('xb') as output: output.write(data)
        path.chmod(0o600)
    except FileExistsError:
        if path.read_bytes()!=data: raise RuntimeError('Bestehende Worker-Datei unterscheidet sich')
info=base/'ARCHITEKTUR.md'  # stable path for agents on bigki (always the newest version)
temp_info=base/'.ARCHITEKTUR.md.tmp'
temp_info.write_bytes(files['ARCHITEKTUR.md']); os.replace(temp_info, info)
worker=str(directory/'worker.py')
pattern=re.compile(re.escape(str(base))+'/([0-9a-f]{16})/worker.py')
comment='studioportal-'+name
entry='from="'+source+'",restrict,command="/usr/bin/python3 '+worker+'" '+key[0]+' '+key[1]+' '+comment
auth=Path.home()/'.ssh/authorized_keys'
auth.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
fd=os.open(auth,os.O_RDWR|os.O_CREAT|getattr(os,'O_NOFOLLOW',0),0o600)
with os.fdopen(fd,'r+',encoding='utf-8') as output:
    fcntl.flock(output,fcntl.LOCK_EX)
    existing=output.read()
    lines=existing.splitlines()
    updated=[]
    found=False
    for line in lines:
        if key[1] in line and not p['files_only']:
            if not pattern.search(line) or 'restrict' not in line:
                raise RuntimeError('Der App-Schlüssel ist bereits mit einer anderen Berechtigung installiert')
            if not found: updated.append(entry)
            found=True
            continue
        if pattern.search(line) and line.split('command=')[0].find('restrict')>=0:
            line=pattern.sub(worker.replace('\\','\\\\'), line)  # every StudioPortal key follows the new version
        updated.append(line)
    if not found and not p['files_only']:
        updated.append(entry)
    text='\n'.join(updated)+'\n'
    if text!=existing:
        temp_fd,temp_path=tempfile.mkstemp(prefix='.3d-modelle-auth-',dir=auth.parent)
        try:
            os.fchmod(temp_fd,stat.S_IMODE(os.fstat(output.fileno()).st_mode))
            with os.fdopen(temp_fd,'w',encoding='utf-8') as temp:
                temp.write(text); temp.flush(); os.fsync(temp.fileno())
            os.replace(temp_path,auth)
        finally:
            if os.path.exists(temp_path): os.unlink(temp_path)
print('bigki worker installed:',version)
'''

inner = 'exec /usr/bin/python3 -c ' + shlex.quote(installer)
outer = 'exec ssh -F ~/.ssh/bigki-admin-config -o BatchMode=yes -o ConnectTimeout=15 bigki-ts ' + shlex.quote(inner)
command = ['/usr/bin/ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=12',
           '-o', 'StrictHostKeyChecking=yes', 'du@DEIN-MAC', outer]
if 'mini' in socket.gethostname().lower() or Path.home().joinpath('.ssh/bigki-admin-config').is_file():
    command = ['/bin/sh', '-c', outer]  # already on the Mac mini (the admin hop): no extra SSH to itself
if options.via_session:
    if not options.files_only:
        raise SystemExit('--via-session geht nur mit --files-only (Schlüssel werden nicht angefasst).')
    code = ("import subprocess\n"
            f"r = subprocess.run(['/usr/bin/python3', '-c', {installer!r}], input={payload!r}, capture_output=True, timeout=120)\n"
            "result = {'rc': r.returncode, 'out': r.stdout.decode()[-500:], 'err': r.stderr.decode()[-1500:]}\n")
    request = {'operation': 'blender', 'action': 'python', 'session': 'werkzeug', 'code': code, 'timeout': 200}
    home = Path.home()
    reply = subprocess.run(['/usr/bin/ssh', '-T', '-o', 'BatchMode=yes', '-o', 'IdentitiesOnly=yes', '-i', str(home / '.ssh/3d-modelle-bigki'),
                            '-o', 'UserKnownHostsFile=' + str(home / '.ssh/3d-modelle-bigki-known_hosts'), 'bigki@GPU-SERVER-IP'],
                           input=(json.dumps(request) + '\n').encode(), capture_output=True, timeout=300, check=True)
    results = [json.loads(line) for line in reply.stdout.decode().splitlines() if '"result"' in line or '"error"' in line]
    print(json.dumps(results[-1] if results else {'error': 'keine Antwort'}, ensure_ascii=False))
    subprocess.run([str(home / 'Applications/StudioPortal.app/Contents/MacOS/StudioPortal'), 'blender', 'quit', '--session', 'werkzeug'],
                   capture_output=True)
else:
    subprocess.run(command, input=payload, check=True)
