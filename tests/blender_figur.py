"""Regression tests for the figure tools, run inside headless Blender on bigki (tests/run_blender_tests.sh).
Reference clip tests/data/cmu_02_01_gehen.bvh: CMU Graphics Lab Motion Capture Database (mocap.cs.cmu.edu), subject 2, walk.
Catches e.g. a retargeted figure floating 1 m above the floor or walking backwards."""
import json
import sys
import time

import bpy
from mathutils import Vector

args = sys.argv[sys.argv.index('--') + 1:]
sys.path.insert(0, args[0])
import studio_figur as figur  # noqa: E402

bvh, slow = args[1], '--lang' in args
results, failed = [], 0


def check(name, ok, value):
    global failed
    failed += not ok
    results.append({'test': name, 'ok': bool(ok), 'wert': value})


def lowest_joint(rig):
    world = rig.matrix_world
    return min((world @ b.head).z for b in rig.pose.bones if 'foot' in b.name.lower() or 'toe' in b.name.lower())


body = figur.mensch(name='Test')
rig = bpy.data.objects[body['rig']]
check('mensch: Rig mit Knochen', body['knochen'] > 50, body['knochen'])
check('mensch: Größe plausibel', 1.4 < body['hoehe_m'] < 2.1, body['hoehe_m'])

r = figur.bvh_laden(bvh, rig.name)
p = r['pruefung']
check('bvh_laden: Knochen zugeordnet', r['knochen'] >= 15, r['knochen'])
check('bvh_laden: Füße am Boden (Prüfwert)', abs(p['boden_abstand_cm']) <= 3, p['boden_abstand_cm'])
check('bvh_laden: Kopf über Hüfte', p['kopf_ueber_huefte_cm'] > 30, p['kopf_ueber_huefte_cm'])
check('bvh_laden: Clip läuft vorwärts', p['weg_m'] > 1.0, p['weg_m'])
check('bvh_laden: keine Warnung', 'warnung' not in p, p.get('warnung'))
first, last = r['bilder']
for frame in (first, (first + last) // 2, last):
    bpy.context.scene.frame_set(frame)
    low = lowest_joint(rig)
    check(f'Bild {frame}: tiefstes Fußgelenk < 15 cm über Boden', -0.03 < low < 0.15, round(low, 3))
bpy.context.scene.frame_set(first)
hip = (rig.matrix_world @ rig.pose.bones['pelvis' if 'pelvis' in rig.pose.bones else 'root'].head).z
check('Hüfte auf Beinhöhe (nicht schwebend)', 0.6 < hip < 1.3, round(hip, 3))

if slow:
    start = time.time()
    mesh = bpy.data.objects[body['koerper']].copy(); mesh.data = mesh.data.copy(); bpy.context.collection.objects.link(mesh)
    mesh.parent = None; mesh.modifiers.clear(); mesh.vertex_groups.clear()
    a = figur.auto_rig(mesh.name, max_minuten=20)
    check('auto_rig: Skelett erzeugt', a['knochen'] >= 15, a['knochen'])
    weighted = bpy.data.objects[a['mesh']]
    check('auto_rig: Gewichte vorhanden', len(weighted.vertex_groups) >= 10, len(weighted.vertex_groups))
    check('auto_rig: Laufzeit < 20 min', time.time() - start < 1200, round(time.time() - start))

print('ERGEBNIS ' + json.dumps({'fehler': failed, 'tests': results}, ensure_ascii=False))
sys.exit(1 if failed else 0)
