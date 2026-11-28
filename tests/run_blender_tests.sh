#!/bin/sh
# Figure regression tests in headless Blender on bigki (CPU only, own temp folder, nothing else touched).
#   tests/run_blender_tests.sh          ~2 min: mensch + bvh_laden with the CMU reference clip
#   tests/run_blender_tests.sh --lang   + auto_rig (UniRig, ~10 min CPU)
set -e
cd "$(dirname "$0")/.."
SSH="ssh -i $HOME/.ssh/bigki-admin-key -o HostKeyAlias=GPU-SERVER-LAN-IP bigki@GPU-SERVER-LAN-IP"
DIR=.local/share/3d-modelle-app/tests
$SSH "mkdir -p $DIR"
scp -q -i "$HOME/.ssh/bigki-admin-key" -o HostKeyAlias=GPU-SERVER-LAN-IP \
    src/studio_figur.py src/studio_helfer.py tests/blender_figur.py tests/data/cmu_02_01_gehen.bvh "bigki@GPU-SERVER-LAN-IP:$DIR/"
$SSH "B=\$(grep -o 'B=\"\${BLENDER:-[^}]*' ~/Schreibtisch/blender-mi50/run.sh | sed 's/.*:-//'); cd ~/$DIR && nice -n 10 \"\$B\" -b --python-exit-code 1 --python blender_figur.py -- ~/$DIR ~/$DIR/cmu_02_01_gehen.bvh $* 2>&1" \
    | grep '^ERGEBNIS' | sed 's/^ERGEBNIS //' | python3 -I -c '
import json, sys
r = json.load(sys.stdin)
for t in r["tests"]: print(("ok   " if t["ok"] else "FEHLT") + "  " + t["test"] + "  (" + str(t["wert"]) + ")")
n = len(r["tests"]); print(str(n - r["fehler"]) + "/" + str(n) + " bestanden"); sys.exit(1 if r["fehler"] else 0)'
