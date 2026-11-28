"""StudioPortal Blender session on bigki: a persistent background Blender that agents drive through the worker.

Runs inside Blender:  blender -b --factory-startup [file.blend] --python blender_session.py -- <socket> <state.blend>
Listens on a unix socket (one JSON request per connection, executed on Blender's main thread). The session never
uses the MI50s: previews render with Workbench/EEVEE (EGL) or Cycles on the CPU; GPU renders run as separate
processes through the StudioPortal card broker. After IDLE seconds without a request it saves its state and exits;
the worker starts it again from that state on the next request.
"""
import ast
import difflib
import contextlib
import io
import json
import math
import os
import queue
import re
import signal
import socket
import sys
import threading
import time
import traceback

import bpy
import mathutils

args = sys.argv[sys.argv.index('--') + 1:] if '--' in sys.argv else []
SOCKET, STATE = args[0], args[1]
FOLDER = os.path.dirname(STATE)
TOOLS = os.path.join(FOLDER, 'werkzeuge.py')          # the agent's own helpers, loaded at every start
SNAPSHOTS = os.path.join(FOLDER, 'zwischenstaende')
CRASH = os.path.join(FOLDER, 'absturz.json')         # written by the memory guard right before it stops the session
RUNNING = os.path.join(FOLDER, 'laeuft.json')        # the command in progress; left behind if the session dies
# memory guard: bigki has 61 GB; above this the session stops itself with a clear message instead of freezing the PC
MAX_GB = float(os.environ.get('STUDIOPORTAL_BLENDER_MAX_GB', '40'))
MIN_FREE_GB = 2.5
HERE = os.path.dirname(os.path.abspath(__file__))
BASE = os.path.dirname(HERE)
IDLE = int(os.environ.get('STUDIOPORTAL_BLENDER_IDLE', '1800'))
requests = queue.Queue()
last_request = time.time()
running = True
restarted = os.path.exists(STATE)                     # started again from a saved state (idle exit or crash)
startup_notes = []
current = {}                                          # command in progress (for crash reports)
unsaved = False                                       # changes since the last automatic save
autosave = {'last': None, 'seconds': None, 'next': 0.0, 'error': None}
last_look = {}                                        # hash of the previous blender_look image per view
history = []                                          # last commands, for the Blender tab in the app
STATUS = os.path.join(FOLDER, 'status.json')          # read by the worker without waiting for the session
DEFS = os.path.join(FOLDER, 'sitzung_defs.json')      # functions/classes/imports from blender_python, replayed after a restart
VARS = os.path.join(FOLDER, 'sitzung_variablen.json')  # simple variables (numbers, text, lists, Blender objects by name, vectors)
base_names = set()                                    # names that exist before any agent code (bpy, figur, werkzeuge …)
END = os.path.join(FOLDER, 'ende.json')               # why the previous process ended normally (quit / idle), for the restart note
end_reason = {}


def previous_end():
    """Why the previous process ended normally (written at exit), e.g. 'beendet mit quit 14:02' or '30 min ohne Aufruf'."""
    if not os.path.exists(END):
        return None
    try:
        info = json.load(open(END, encoding='utf-8'))
    except Exception:  # noqa: BLE001
        info = {}
    os.replace(END, END + '.alt')
    return info


def previous_crash():
    """Explains why the previous session process ended, if it did not end normally."""
    notes = []
    for path, kind in ((CRASH, 'crash'), (RUNNING, 'running')):
        if not os.path.exists(path):
            continue
        try:
            info = json.load(open(path, encoding='utf-8'))
        except Exception:  # noqa: BLE001
            info = {}
        os.replace(path, path + '.alt')
        what = info.get('command', '?')
        code = (info.get('code') or '').strip().replace('\n', ' ⏎ ')[:300]
        when = info.get('time', '')
        if kind == 'crash':
            notes.append(f'Letzter Absturz {when}: {info.get("reason", "unbekannt")} – bei {what}' + (f' (Code: {code})' if code else '')
                         + '. ' + info.get('hint', ''))
            break
        notes.append(f'Die vorige Sitzung ist {when} während {what} abgestürzt (ohne Meldung, z. B. Speicher oder Blender-Fehler)'
                     + (f' – Code: {code}' if code else '') + '.')
    if notes and os.path.exists(STATE):
        notes.append('Geladen ist der automatisch gespeicherte Stand von '
                     + time.strftime('%H:%M:%S', time.localtime(os.path.getmtime(STATE))) + ' (nach dem letzten erfolgreichen Aufruf).')
    return notes


startup_notes += previous_crash()
previous_ending = previous_end()
# extra packages (scipy, libigl, robust_laplacian) live in our own folder, after Blender's own (numpy stays Blender's)
PYLIB = os.path.join(BASE, 'pylib', f'py{sys.version_info.major}{sys.version_info.minor}')
if os.path.isdir(PYLIB) and PYLIB not in sys.path:
    sys.path.append(PYLIB)
if HERE not in sys.path:
    sys.path.append(HERE)


def fresh_namespace():
    space = {'bpy': bpy, 'mathutils': mathutils, 'math': math, 'C': bpy.context, 'D': bpy.data}
    try:
        import numpy
        space['np'] = numpy
    except ImportError:
        pass
    if os.path.isfile(os.path.join(HERE, 'studio_helfer.py')):
        try:
            import studio_helfer  # camera, vertex positions, smoothing, remesh, decimate
            space['helfer'] = studio_helfer
        except Exception as error:  # noqa: BLE001
            startup_notes.append(f'helfer nicht geladen: {type(error).__name__}: {error}')
    if os.path.isfile(os.path.join(HERE, 'studio_figur.py')):
        try:
            import studio_figur  # figure building blocks (MPFB, weights, grip, porcelain …)
            space['figur'] = studio_figur
        except Exception as error:  # noqa: BLE001
            startup_notes.append(f'figur-Bausteine nicht geladen: {type(error).__name__}: {error}')
    return space


namespace = fresh_namespace()


def tool_files():
    """werkzeuge.py plus the script files loaded with blender_tools script=… (werkzeuge/<name>.py), in that order."""
    files = [TOOLS] if os.path.isfile(TOOLS) else []
    folder = os.path.join(FOLDER, 'werkzeuge')
    if os.path.isdir(folder):
        files += [os.path.join(folder, f) for f in sorted(os.listdir(folder)) if f.endswith('.py')]
    return files


def load_tools():
    """Exec werkzeuge.py and werkzeuge/*.py into the namespace; returns the names they defined (or raises with the traceback)."""
    before = set(namespace)
    for path in tool_files():
        code = open(path, encoding='utf-8').read()
        exec(compile(code, path, 'exec'), namespace)
    return sorted(n for n in set(namespace) - before if not n.startswith('_'))


def json_safe(value, found):
    """Plain JSON: NaN/inf → None (counted in found[0]), numpy values/arrays → Python, tuples/sets → lists."""
    if isinstance(value, float):
        if math.isfinite(value):
            return value
        found[0] += 1
        return None
    if isinstance(value, (str, int, bool)) or value is None:
        return value
    if isinstance(value, dict):
        return {str(k): json_safe(v, found) for k, v in value.items()}
    if isinstance(value, (list, tuple, set, frozenset)):
        return [json_safe(v, found) for v in value]
    if hasattr(value, 'tolist') and callable(value.tolist):       # numpy scalars and arrays
        return json_safe(value.tolist(), found)
    if isinstance(value, mathutils.Vector) or isinstance(value, (mathutils.Euler, mathutils.Quaternion, mathutils.Color)):
        return json_safe(list(value), found)
    if isinstance(value, mathutils.Matrix):
        return json_safe([list(row) for row in value], found)
    return str(value)


def reply(conn, value):
    try:
        found = [0]
        value = json_safe(value, found)
        conn.sendall((json.dumps(value, ensure_ascii=False, allow_nan=False) + '\n').encode())
    except OSError:
        pass
    finally:
        conn.close()


def accept_loop(server):
    while running:
        try:
            conn, _ = server.accept()
        except OSError:
            return
        try:
            conn.settimeout(30)
            data = b''
            while not data.endswith(b'\n'):
                chunk = conn.recv(1 << 20)
                if not chunk:
                    break
                data += chunk
                if len(data) > 64 * 1024 * 1024:
                    raise ValueError('Anfrage zu groß')
            conn.settimeout(None)
            requests.put((json.loads(data), conn))
        except Exception as error:  # noqa: BLE001
            reply(conn, {'ok': False, 'error': f'Ungültige Anfrage: {error}'})


def memory_now():
    with open('/proc/self/statm') as handle:
        rss = int(handle.read().split()[1]) * os.sysconf('SC_PAGE_SIZE') / 1e9
    free = None
    with open('/proc/meminfo') as handle:
        for line in handle:
            if line.startswith('MemAvailable:'):
                free = int(line.split()[1]) / 1e6
                break
    return rss, free


def memory_guard():
    """Runs beside Blender's main thread. A runaway Remesh/Subdivide can't be interrupted from Python, so the session
    writes the reason and stops itself before bigki starts swapping; the next call loads the last autosave."""
    peak = 0.0
    while running:
        try:
            rss, free = memory_now()
        except Exception:  # noqa: BLE001
            time.sleep(3)
            continue
        peak = max(peak, rss)
        if rss > MAX_GB or (free is not None and free < MIN_FREE_GB and rss > 6):
            reason = (f'Speicher voll ({rss:.1f} GB belegt, {free:.1f} GB frei, Grenze {MAX_GB:.0f} GB)' if rss > MAX_GB else
                      f'bigki hat kaum noch freien Speicher ({free:.1f} GB frei, Sitzung {rss:.1f} GB)')
            hint = ('Häufige Ursache: Remesh/Subdivision/Boolean auf einem Objekt mit Ausreißern (z. B. Solidify mit „Even Offset“ '
                    'schießt Punkte weit hinaus) oder zu feinem Voxel – vorher Objektgröße prüfen (blender_scene, blender_check).')
            info = dict(current, reason=reason, hint=hint, rss_gb=round(rss, 1), time=time.strftime('%H:%M:%S'))
            try:
                with open(CRASH, 'w', encoding='utf-8') as handle:
                    json.dump(info, handle, ensure_ascii=False)
            finally:
                os.kill(os.getpid(), signal.SIGKILL)
        time.sleep(0.3 if rss > MAX_GB * 0.6 else 1.0)


def save_now():
    """Automatic save after changes (when the session is idle for a moment), so a crash loses at most one call."""
    global unsaved
    started = time.time()
    try:
        save_state()
        autosave.update(last=time.strftime('%H:%M:%S'), seconds=round(time.time() - started, 1), error=None)
    except Exception as error:  # noqa: BLE001
        autosave['error'] = f'{type(error).__name__}: {error}'
    unsaved = False
    # big scenes take a while to save: then not more often than every few times the save duration
    autosave['next'] = time.time() + min(120.0, 4 * (time.time() - started))


def build_type_text():
    raw = getattr(bpy.app, 'build_type', '')
    return raw.decode('utf-8', 'replace') if isinstance(raw, bytes) else str(raw)


def write_status():
    """Small summary for the app's Blender tab (read by the worker directly, also while a long command runs)."""
    try:
        rss, free = memory_now()
        scene = bpy.context.scene
        objects = []
        for obj in list(scene.objects)[:250]:
            item = {'name': obj.name, 'type': obj.type}
            if obj.type == 'MESH' and obj.data:
                item['vertices'] = len(obj.data.vertices)
            if obj.hide_render:
                item['render'] = False
            if obj.hide_get():
                item['viewport'] = False
            objects.append(item)
        data = {'pid': os.getpid(), 'time': time.strftime('%H:%M:%S'), 'blender': bpy.app.version_string,
                'build_type': build_type_text(),
                'file': bpy.data.filepath or None, 'objects': objects, 'object_count': len(scene.objects),
                'camera': scene.camera.name if scene.camera else None, 'engine': scene.render.engine,
                'memory_gb': round(rss, 1), 'memory_limit_gb': MAX_GB, 'bigki_free_gb': round(free or 0, 1),
                'autosave': {k: v for k, v in autosave.items() if k != 'next'}, 'unsaved': unsaved,
                'idle_exit_seconds': IDLE, 'history': history[-30:]}
        temp = STATUS + '.tmp'
        with open(temp, 'w', encoding='utf-8') as handle:
            json.dump(data, handle, ensure_ascii=False)
        os.replace(temp, STATUS)
    except Exception:  # noqa: BLE001
        traceback.print_exc()


# ------------------------------------------------------------------ keep agent state across restarts
def remember_definitions(code):
    """Top-level def/class/import statements of a successful blender_python call, latest version per name."""
    try:
        tree = ast.parse(code)
    except SyntaxError:
        return
    found = {}
    for node in tree.body:
        segment = ast.get_source_segment(code, node)
        if not segment:
            continue
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            found[node.name] = segment
        elif isinstance(node, (ast.Import, ast.ImportFrom)):
            found['import:' + segment] = segment
    if not found:
        return
    try:
        known = json.load(open(DEFS, encoding='utf-8'))
    except Exception:  # noqa: BLE001
        known = {}
    for key in found:
        known.pop(key, None)       # re-insert so the order follows the latest definition
    known.update(found)
    temp = DEFS + '.tmp'
    with open(temp, 'w', encoding='utf-8') as handle:
        json.dump(known, handle, ensure_ascii=False)
    os.replace(temp, DEFS)


def encode_value(value, depth=0):
    """JSON form of a variable, or raises TypeError when it can't be restored."""
    if value is None or isinstance(value, (bool, int, float, str)):
        if isinstance(value, float) and not math.isfinite(value):
            raise TypeError('nan')
        return value
    if depth > 4:
        raise TypeError('zu tief')
    if isinstance(value, bpy.types.ID):
        for attr in ('objects', 'meshes', 'materials', 'collections', 'cameras', 'lights', 'armatures', 'images', 'actions',
                     'node_groups', 'curves', 'textures', 'worlds', 'scenes'):
            if getattr(bpy.data, attr).get(value.name) == value:
                return {'__id__': attr, 'name': value.name}
        raise TypeError('unbekannter Blender-Typ')
    if isinstance(value, bpy.types.PoseBone):
        return {'__posebone__': value.id_data.name, 'name': value.name}
    for kind in ('Vector', 'Euler', 'Quaternion', 'Color'):
        if isinstance(value, getattr(mathutils, kind)):
            return {'__math__': kind, 'v': [float(x) for x in value]}
    if isinstance(value, mathutils.Matrix):
        return {'__math__': 'Matrix', 'v': [[float(x) for x in row] for row in value]}
    if isinstance(value, (list, tuple)):
        if len(value) > 20000:
            raise TypeError('zu groß')
        items = [encode_value(v, depth + 1) for v in value]
        return items if isinstance(value, list) else {'__tuple__': items}
    if isinstance(value, dict):
        if len(value) > 5000 or not all(isinstance(k, str) for k in value):
            raise TypeError('zu groß oder keine Text-Schlüssel')
        return {'__dict__': {k: encode_value(v, depth + 1) for k, v in value.items()}}
    raise TypeError(type(value).__name__)


def decode_value(value):
    if isinstance(value, list):
        return [decode_value(v) for v in value]
    if not isinstance(value, dict):
        return value
    if '__id__' in value:
        found = getattr(bpy.data, value['__id__']).get(value['name'])
        if found is None:
            raise KeyError(value['name'])
        return found
    if '__posebone__' in value:
        return bpy.data.objects[value['__posebone__']].pose.bones[value['name']]
    if '__math__' in value:
        return getattr(mathutils, value['__math__'])(value['v'])
    if '__tuple__' in value:
        return tuple(decode_value(v) for v in value['__tuple__'])
    return {k: decode_value(v) for k, v in value['__dict__'].items()}


def save_variables():
    keep, skipped = {}, []
    for name, value in list(namespace.items()):
        if name.startswith('_') or name in base_names or name == 'result' or callable(value) or type(value).__name__ == 'module':
            continue
        try:
            keep[name] = encode_value(value)
        except Exception as error:  # noqa: BLE001
            skipped.append(f'{name} ({error})')
    data = json.dumps({'vars': keep, 'skipped': skipped[:40]}, ensure_ascii=False)
    if len(data) > 20 * 1024 * 1024:
        data = json.dumps({'vars': {}, 'skipped': ['alle (zusammen größer als 20 MB)']})
    temp = VARS + '.tmp'
    with open(temp, 'w', encoding='utf-8') as handle:
        handle.write(data)
    os.replace(temp, VARS)


def restore_agent_state():
    """After a restart: replay remembered definitions, then restore variables. Returns a note for the first answer."""
    restored_defs, failed, restored_vars, lost = [], [], [], []
    try:
        defs = json.load(open(DEFS, encoding='utf-8'))
    except Exception:  # noqa: BLE001
        defs = {}
    for key, code in defs.items():
        try:
            exec(compile(code, f'<wiederhergestellt {key}>', 'exec'), namespace)
            if not key.startswith('import:'):
                restored_defs.append(key)
        except Exception as error:  # noqa: BLE001
            failed.append(f'{key} ({type(error).__name__})')
    try:
        saved = json.load(open(VARS, encoding='utf-8'))
    except Exception:  # noqa: BLE001
        saved = {}
    for name, value in (saved.get('vars') or {}).items():
        try:
            namespace[name] = decode_value(value)
            restored_vars.append(name)
        except Exception as error:  # noqa: BLE001
            lost.append(f'{name} ({str(error)[:40]})')
    lost += saved.get('skipped') or []
    parts = []
    if restored_defs:
        parts.append('Funktionen/Klassen wiederhergestellt: ' + ', '.join(restored_defs[:40]))
    if restored_vars:
        more = f' (+{len(restored_vars) - 25} weitere)' if len(restored_vars) > 25 else ''
        parts.append('Variablen wiederhergestellt: ' + ', '.join(restored_vars[:25]) + more)
    if failed:
        parts.append('nicht wieder ausführbar: ' + ', '.join(failed[:20]))
    if lost:
        parts.append('nicht wiederherstellbar (nur Zahlen, Text, Listen/Dicts, Vektoren/Matrizen und Blender-Objekte gehen): '
                     + ', '.join(lost[:20]))
    return parts


def changes_scene(command, req):
    return command in ('python', 'open', 'new', 'restore', 'tools') or (command == 'check' and req.get('remove_small'))


# ------------------------------------------------------------------ commands
def run_python(req):
    code = req.get('code')
    if not isinstance(code, str) or not code.strip():
        raise ValueError('Kein Python-Code übergeben.')
    raw_path = req.get('script_path')
    script_path = raw_path.strip() if isinstance(raw_path, str) and raw_path.strip() else None
    filename = script_path or '<agent>'
    namespace['C'] = bpy.context
    namespace['D'] = bpy.data
    namespace.pop('result', None)
    had_file = '__file__' in namespace
    prev_file = namespace.get('__file__')
    if script_path:
        namespace['__file__'] = script_path
        script_dir = os.path.dirname(os.path.abspath(script_path))
        if os.path.isdir(script_dir) and script_dir not in sys.path:
            sys.path.insert(0, script_dir)
    out = io.StringIO()
    error = None
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
        try:
            exec(compile(code, filename, 'exec'), namespace)
        except Exception:  # noqa: BLE001
            error = traceback.format_exc(limit=8)
        finally:
            if had_file:
                namespace['__file__'] = prev_file
            else:
                namespace.pop('__file__', None)
    text = out.getvalue()
    result = namespace.get('result')
    answer = {'ok': error is None, 'output': text[-20000:]}
    logs = [line for line in text.splitlines() if line.startswith('LOG')]
    if logs:
        answer['log'] = logs[-400:]
    if error is None:
        try:
            remember_definitions(code)
        except Exception:  # noqa: BLE001
            traceback.print_exc()
    if error is None and req.get('persist'):
        with open(TOOLS, 'a', encoding='utf-8') as handle:
            handle.write(f'\n# --- {time.strftime("%Y-%m-%d %H:%M")}\n{code.rstrip()}\n')
        answer['persisted'] = TOOLS
    if result is not None:
        found = [0]
        answer['result'] = json_safe(result, found)
        if found[0]:
            answer['nan_warnung'] = (f'{found[0]} Wert(e) in result waren NaN oder unendlich und stehen dort als null '
                                     '(z. B. Division durch 0, leere Auswahl, normalisierter Nullvektor).')
    if error:
        answer['error'] = error[-8000:]
    return answer


def vec(v, digits=3):
    return [round(float(x), digits) for x in v]


def object_info(obj, detail=False):
    info = {'name': obj.name, 'type': obj.type, 'location': vec(obj.location), 'rotation': vec(obj.rotation_euler),
            'scale': vec(obj.scale), 'dimensions': vec(obj.dimensions)}
    if obj.parent:
        info['parent'] = obj.parent.name
    if obj.users_collection:
        info['collections'] = [c.name for c in obj.users_collection]
    if obj.hide_render or obj.hide_get():
        info['hidden'] = {'viewport': obj.hide_get(), 'render': obj.hide_render}
    if obj.type == 'MESH' and obj.data:
        info['mesh'] = {'vertices': len(obj.data.vertices), 'faces': len(obj.data.polygons)}
    materials = [slot.material.name for slot in getattr(obj, 'material_slots', []) if slot.material]
    if materials:
        info['materials'] = materials
    if obj.modifiers:
        info['modifiers'] = [f'{m.name} ({m.type})' for m in obj.modifiers]
    if obj.type == 'LIGHT':
        info['light'] = {'type': obj.data.type, 'energy': obj.data.energy, 'color': vec(obj.data.color)}
    if obj.type == 'CAMERA':
        info['camera'] = {'lens': obj.data.lens, 'type': obj.data.type}
    if obj.animation_data and obj.animation_data.action:
        info['action'] = obj.animation_data.action.name
    if detail:
        info['matrix_world'] = [vec(row) for row in obj.matrix_world]
        info['custom_properties'] = {k: str(obj[k])[:200] for k in obj.keys() if not k.startswith('_')}
        if obj.type == 'MESH' and obj.data:
            info['mesh'].update({'edges': len(obj.data.edges), 'uv_layers': [u.name for u in obj.data.uv_layers],
                                 'color_attributes': [a.name for a in obj.data.color_attributes]})
        if obj.modifiers:
            info['modifier_settings'] = {m.name: {p.identifier: str(getattr(m, p.identifier))[:120]
                                                  for p in m.bl_rna.properties if p.identifier not in ('rna_type', 'name')}
                                         for m in obj.modifiers}
    return info


def scene_summary(req):
    scene = bpy.context.scene
    render = scene.render
    name = req.get('object')
    if name:
        obj = bpy.data.objects.get(name)
        if obj is None:
            raise ValueError(f'Objekt „{name}“ gibt es nicht.')
        return {'ok': True, 'object': object_info(obj, detail=True)}
    objects = list(scene.objects)
    summary = {
        'ok': True,
        'file': bpy.data.filepath or None, 'unsaved_changes': bpy.data.is_dirty,
        'blender': bpy.app.version_string, 'scene': scene.name,
        'frames': [scene.frame_start, scene.frame_end], 'frame_current': scene.frame_current,
        'fps': round(render.fps / render.fps_base, 3),
        'render': {'engine': render.engine, 'resolution': [render.resolution_x, render.resolution_y],
                   'percentage': render.resolution_percentage, 'output': render.filepath,
                   'format': render.image_settings.file_format},
        'camera': scene.camera.name if scene.camera else None,
        'world': scene.world.name if scene.world else None,
        'collections': {c.name: [o.name for o in c.objects][:50] for c in bpy.data.collections},
        'materials': [m.name for m in bpy.data.materials][:200],
        'object_count': len(objects),
        'objects': [object_info(o) for o in objects[:300]],
    }
    if render.engine == 'CYCLES':
        summary['render']['samples'] = scene.cycles.samples
        summary['render']['adaptive'] = scene.cycles.use_adaptive_sampling
    huge = [o.name for o in objects if o.type in GEOMETRY and max(o.dimensions) > 10]
    if huge:
        summary['warnung_groesse'] = (f'Größer als 10 m: {", ".join(huge[:12])} – oft Ausreißer-Punkte (z. B. Solidify „Even Offset“); '
                                      'vor Remesh/Subdivision helfer.groesse_pruefen(name).')
    try:
        rss, free = memory_now()
        summary['memory_gb'] = {'session': round(rss, 1), 'bigki_free': round(free or 0, 1), 'limit': MAX_GB}
    except OSError:
        pass
    missing = [img.filepath for img in bpy.data.images
               if img.source == 'FILE' and img.filepath and not img.packed_file and not os.path.exists(bpy.path.abspath(img.filepath))]
    if missing:
        summary['missing_files'] = missing[:50]
    return summary


GEOMETRY = ('MESH', 'CURVE', 'SURFACE', 'META', 'FONT', 'VOLUME', 'CURVES', 'POINTCLOUD')
# named views: (azimuth, elevation) in degrees; azimuth 0 = from the front (-Y), 90 = from the right (+X)
VIEWS = {'vorne': (0, 4), 'rechts': (90, 4), 'hinten': (180, 4), 'links': (270, 4), 'oben': (0, 89),
         'unten': (0, -89), 'schräg': (35, 22), 'schraeg': (35, 22), 'schräg-hinten': (215, 22)}
VIEW_SETS = {'rund': ['vorne', 'schräg', 'rechts', 'hinten', 'links', 'oben'], 'vier': ['vorne', 'rechts', 'hinten', 'schräg'],
             'alle': ['vorne', 'schräg', 'rechts', 'hinten', 'links', 'oben']}
PALETTE = [(0.90, 0.30, 0.25), (0.25, 0.60, 0.90), (0.35, 0.80, 0.35), (0.95, 0.75, 0.20), (0.70, 0.40, 0.85),
           (0.20, 0.80, 0.80), (0.95, 0.55, 0.75), (0.55, 0.45, 0.30), (0.60, 0.60, 0.60), (0.95, 0.95, 0.95)]


def cameras_text():
    names = [o.name for o in bpy.data.objects if o.type == 'CAMERA']
    return ', '.join(names) if names else 'keine'


def object_or_error(name):
    obj = bpy.data.objects.get(name)
    if obj is None:
        close = difflib.get_close_matches(name, [o.name for o in bpy.data.objects], n=6, cutoff=0.4)
        raise ValueError(f'Objekt „{name}“ gibt es nicht.' + (f' Ähnlich: {", ".join(close)}' if close else ''))
    return obj


def world_points(spec):
    """Points to frame/measure: "Objekt", "Objekt:Vertexgruppe", "Armature:Knochen", [x, y, z] or a list of those."""
    if isinstance(spec, (list, tuple)) and len(spec) == 3 and all(isinstance(v, (int, float)) for v in spec):
        return [mathutils.Vector(spec)]
    if isinstance(spec, (list, tuple)):
        points = []
        for item in spec:
            points += world_points(item)
        return points
    name, _, part = str(spec).partition(':')
    obj = object_or_error(name)
    depsgraph = bpy.context.evaluated_depsgraph_get()
    if part and obj.type == 'ARMATURE':
        bone = obj.pose.bones.get(part)
        if bone is None:
            raise ValueError(f'Knochen „{part}“ gibt es in {name} nicht. Ähnlich: '
                             + ', '.join(difflib.get_close_matches(part, [b.name for b in obj.pose.bones], n=8, cutoff=0.3)))
        head, tail = obj.matrix_world @ bone.head, obj.matrix_world @ bone.tail
        pad = max((tail - head).length * 0.6, 0.02)
        return [p + mathutils.Vector(d) * pad for p in (head, tail) for d in ((1, 0, 0), (-1, 0, 0), (0, 1, 0), (0, -1, 0), (0, 0, 1), (0, 0, -1))]
    if part and obj.type == 'MESH':
        group = obj.vertex_groups.get(part)
        if group is None:
            raise ValueError(f'Vertexgruppe „{part}“ gibt es in {name} nicht. Vorhanden: ' + ', '.join(g.name for g in obj.vertex_groups)[:600])
        import numpy as np
        index = group.index
        ids = [v.index for v in obj.data.vertices if any(g.group == index and g.weight > 0.3 for g in v.groups)]
        if not ids:
            raise ValueError(f'Vertexgruppe „{part}“ ist leer.')
        evaluated = obj.evaluated_get(depsgraph)
        mesh = evaluated.to_mesh()
        try:
            source = mesh if len(mesh.vertices) == len(obj.data.vertices) else obj.data
            co = np.zeros(len(source.vertices) * 3, np.float32)
            source.vertices.foreach_get('co', co)
            co = co.reshape(-1, 3)[ids]
        finally:
            evaluated.to_mesh_clear()
        low, high = co.min(0), co.max(0)
        corners = [mathutils.Vector((x, y, z)) for x in (low[0], high[0]) for y in (low[1], high[1]) for z in (low[2], high[2])]
        return [obj.matrix_world @ c for c in corners]
    evaluated = obj.evaluated_get(depsgraph)
    if obj.type in GEOMETRY:
        return [obj.matrix_world @ mathutils.Vector(c) for c in evaluated.bound_box]
    if obj.type == 'ARMATURE':
        return [obj.matrix_world @ p for b in obj.pose.bones for p in (b.head, b.tail)]
    return [obj.matrix_world.translation.copy()]


def scene_points(scene, only=None):
    points = []
    for obj in scene.objects:
        if obj.type in GEOMETRY and not obj.hide_render and (only is None or obj.name in only):
            points += [obj.matrix_world @ mathutils.Vector(c) for c in obj.evaluated_get(bpy.context.evaluated_depsgraph_get()).bound_box]
    return points or [mathutils.Vector((-1, -1, -1)), mathutils.Vector((1, 1, 1))]


def view_direction(azimuth, elevation):
    a, e = math.radians(azimuth), math.radians(max(-89.5, min(89.5, elevation)))
    return mathutils.Vector((math.sin(a) * math.cos(e), -math.cos(a) * math.cos(e), math.sin(e))).normalized()


def place_camera(scene, points, direction, lens=50, distance=None, margin=1.08, target=None):
    """Temporary camera looking along -direction at the points' bounding box (or at target), framing them."""
    low = mathutils.Vector([min(p[i] for p in points) for i in range(3)])
    high = mathutils.Vector([max(p[i] for p in points) for i in range(3)])
    center = target if target is not None else (low + high) / 2
    data = bpy.data.cameras.new('StudioPortal-Vorschau')
    data.lens = lens
    camera = bpy.data.objects.new('StudioPortal-Vorschau', data)
    scene.collection.objects.link(camera)
    forward = -direction
    right = forward.cross(mathutils.Vector((0, 0, 1)))
    right = right.normalized() if right.length > 1e-6 else mathutils.Vector((1, 0, 0))
    up = right.cross(forward).normalized()
    tangent = math.tan(data.angle / 2)
    if distance is None:
        distance = 1e-3
        for x in (low.x, high.x):
            for y in (low.y, high.y):
                for z in (low.z, high.z):
                    offset = mathutils.Vector((x, y, z)) - center
                    depth = offset.dot(direction)
                    distance = max(distance, depth + abs(offset.dot(right)) / tangent, depth + abs(offset.dot(up)) / tangent)
        distance *= margin
    camera.location = center + direction * distance
    camera.rotation_euler = forward.to_track_quat('-Z', 'Y').to_euler()
    data.clip_start, data.clip_end = max(distance / 2000, 1e-4), distance * 30
    return camera


def frame_all(scene, size):
    """Temporary camera that frames all visible geometry (used when the scene has no camera)."""
    return place_camera(scene, scene_points(scene), view_direction(*VIEWS['schräg']))


def remove_camera(camera):
    data = camera.data
    bpy.data.objects.remove(camera)
    bpy.data.cameras.remove(data)


@contextlib.contextmanager
def coloured_parts(scene, mode, by):
    """Workbench colouring: material, object, random or an attribute / vertex groups as flat colours."""
    shading = scene.display.shading
    saved = (shading.color_type, shading.light, shading.show_cavity)
    temp = []  # (mesh, attribute name, previous active colour name)
    legend = None
    try:
        if by and mode == 'solid':
            by = str(by)
            shading.light = 'STUDIO'
            if by in ('material', 'object', 'random'):
                shading.color_type = {'material': 'MATERIAL', 'object': 'OBJECT', 'random': 'RANDOM'}[by]
            else:
                import numpy as np
                legend = {}
                for obj in scene.objects:
                    if obj.type != 'MESH' or obj.hide_render:
                        continue
                    me = obj.data
                    n = len(me.vertices)
                    values = None
                    if by in ('teile', 'teil', 'inseln', 'parts', 'islands'):
                        edges = np.empty(len(me.edges) * 2, np.int64)
                        me.edges.foreach_get('vertices', edges)
                        labels = islands(n, edges.reshape(-1, 2))
                        _, values, counts = np.unique(labels, return_inverse=True, return_counts=True)
                        order = np.argsort(-counts)                      # biggest part first = red
                        rank = np.empty_like(order)
                        rank[order] = np.arange(len(order))
                        values = np.minimum(rank[values], 9)             # parts 10+ share one colour (fast for many bits)
                        names = {int(r): f'{obj.name} Teil {int(r) + 1} ({int(counts[order[r]])} Punkte)' for r in range(min(len(order), 9))}
                        if len(order) > 9:
                            rest = int(counts[order[9:]].sum())
                            names[9] = f'{obj.name} Teil 10 und alle kleineren ({len(order) - 9} Teile, {rest} Punkte)'
                    elif by == 'vertex_groups' and obj.vertex_groups:
                        weights = np.zeros((n, len(obj.vertex_groups)), np.float32)
                        for v in me.vertices:
                            for g in v.groups:
                                if g.group < weights.shape[1]:
                                    weights[v.index, g.group] = g.weight
                        values = np.where(weights.max(1) > 0, weights.argmax(1), -1)
                        names = {i: g.name for i, g in enumerate(obj.vertex_groups)}
                    elif by in me.attributes and me.attributes[by].domain == 'POINT':
                        attribute = me.attributes[by]
                        if attribute.data_type in ('INT', 'INT8', 'BOOLEAN'):
                            values = np.zeros(n, np.int32 if attribute.data_type != 'BOOLEAN' else bool)
                            attribute.data.foreach_get('value', values)
                            values = values.astype(np.int32)
                            names = {int(v): str(int(v)) for v in np.unique(values)}
                        elif attribute.data_type == 'FLOAT':
                            raw = np.zeros(n, np.float32)
                            attribute.data.foreach_get('value', raw)
                            span = max(float(raw.max() - raw.min()), 1e-9)
                            values = np.clip(((raw - raw.min()) / span * 9.999).astype(np.int32), 0, 9)
                            names = {i: f'{raw.min() + span * i / 10:.3g}…' for i in range(10)}
                    if values is None:
                        continue
                    colours = np.ones((n, 4), np.float32)
                    for value in np.unique(values):
                        rgb = (0.12, 0.12, 0.12) if value < 0 else PALETTE[int(value) % len(PALETTE)]
                        colours[values == value, :3] = rgb
                        legend[names.get(int(value), 'ohne') if value >= 0 else 'ohne'] = ['rot', 'blau', 'grün', 'gelb', 'lila', 'türkis', 'rosa', 'braun', 'grau', 'weiß'][int(value) % 10] if value >= 0 else 'schwarz'
                    previous = me.color_attributes.active_color.name if me.color_attributes.active_color else None
                    attribute = me.color_attributes.new('_SP_Teile', 'FLOAT_COLOR', 'POINT')
                    attribute.data.foreach_set('color', colours.ravel())
                    me.color_attributes.active_color = attribute
                    temp.append((me, attribute.name, previous))
                if not temp:
                    raise ValueError(f'color_by „{by}“: weder material/object/random/teile/vertex_groups noch ein Punkt-Attribut dieses Namens an einem sichtbaren Mesh.')
                shading.color_type = 'VERTEX'
        yield legend
    finally:
        shading.color_type, shading.light, shading.show_cavity = saved
        for me, name, previous in temp:
            attribute = me.color_attributes.get(name)
            if attribute:
                me.color_attributes.remove(attribute)
            if previous and me.color_attributes.get(previous):
                me.color_attributes.active_color = me.color_attributes[previous]


def compose_grid(paths, labels, output, columns=None, reference=None):
    """Tile PNGs into one image (top-left first) with a dark gap; optional reference image as the first tile."""
    import numpy as np
    tiles = []
    for path in ([reference] if reference else []) + list(paths):
        image = bpy.data.images.load(path)
        w, h = image.size
        pixels = np.zeros(w * h * 4, np.float32)
        image.pixels.foreach_get(pixels)
        tiles.append(pixels.reshape(h, w, 4))
        bpy.data.images.remove(image)
    th = max(t.shape[0] for t in tiles)
    tw = max(t.shape[1] for t in tiles)
    count = len(tiles)
    columns = columns or (count if count <= 3 else (2 if count == 4 else 3))
    rows = math.ceil(count / columns)
    gap = 6
    H, W = rows * th + (rows - 1) * gap, columns * tw + (columns - 1) * gap
    canvas = np.zeros((H, W, 4), np.float32)
    canvas[..., :3] = 0.06
    canvas[..., 3] = 1
    for i, tile in enumerate(tiles):
        r, c = divmod(i, columns)
        h, w = tile.shape[:2]
        if h != th or w != tw:  # reference image: nearest-neighbour fit into the tile
            scale = min(th / h, tw / w)
            ys = (np.arange(int(h * scale)) / scale).astype(int).clip(0, h - 1)
            xs = (np.arange(int(w * scale)) / scale).astype(int).clip(0, w - 1)
            tile = tile[ys][:, xs]
            h, w = tile.shape[:2]
        top = H - r * (th + gap)                 # Blender images start bottom-left
        left = c * (tw + gap) + (tw - w) // 2
        canvas[top - th + (th - h) // 2: top - th + (th - h) // 2 + h, left:left + w] = tile
    out = bpy.data.images.new('_sp_raster', W, H, alpha=False)
    out.pixels.foreach_set(canvas.ravel())
    out.filepath_raw = output
    out.file_format = 'PNG'
    out.save()
    bpy.data.images.remove(out)
    return {'tiles': (['vorlage'] if reference else []) + labels, 'columns': columns, 'resolution': [W, H]}


def look_region(req):
    """region [x0, y0, x1, y1] (0–1, from the top left of the same view without region) or zoom (2 = half the width)
    around center [x, y] (default the middle). None = whole image."""
    region, zoom = req.get('region'), req.get('zoom')
    if zoom is not None:
        zoom = float(zoom)
        if not 1 <= zoom <= 32:
            raise ValueError('zoom: 1–32 (2 = doppelt so groß, Ausschnitt halb so breit).')
        if zoom == 1 and region is None:
            return None
        center = req.get('center') or [0.5, 0.5]
        if not (isinstance(center, (list, tuple)) and len(center) == 2):
            raise ValueError('center: [x, y] im Bild, 0–1 von oben links.')
        half = 0.5 / zoom
        cx = min(max(float(center[0]), half), 1 - half)
        cy = min(max(float(center[1]), half), 1 - half)
        region = [cx - half, cy - half, cx + half, cy + half]
    if region is None:
        return None
    if not (isinstance(region, (list, tuple)) and len(region) == 4):
        raise ValueError('region: [x0, y0, x1, y1] als Anteile 0–1 von oben links, z. B. [0.4, 0.1, 0.7, 0.4].')
    x0, y0, x1, y1 = (min(max(float(v), 0.0), 1.0) for v in region)
    if x1 - x0 < 0.005 or y1 - y0 < 0.005:
        raise ValueError('region ist leer oder kleiner als 0,5 % des Bildes (x0 < x1 und y0 < y1).')
    return [x0, y0, x1, y1]


def render_visible(scene):
    """Geometry objects that a render really shows: hide_render off, collection not excluded or render-hidden.
    (Viewport hiding – the eye icon / hide_set – does not hide anything in a render.)"""
    excluded = set()

    def walk(layer, hidden):
        hidden = hidden or layer.exclude or layer.collection.hide_render
        if hidden:
            excluded.add(layer.collection.name)
        for child in layer.children:
            walk(child, hidden)
    walk(bpy.context.view_layer.layer_collection, False)
    shown = []
    for obj in scene.objects:
        if obj.type not in GEOMETRY or obj.hide_render:
            continue
        if all(c.name in excluded for c in obj.users_collection if c != scene.collection) and scene.collection not in obj.users_collection:
            continue
        shown.append(obj)
    return shown


def visibility_report(scene):
    shown = render_visible(scene)
    names = [o.name for o in shown]
    report = {'im_bild': names[:60] + ([f'… {len(names) - 60} weitere'] if len(names) > 60 else [])}
    hidden_render = [o.name for o in scene.objects if o.type in GEOMETRY and o.hide_render]
    if hidden_render:
        report['nicht_im_bild'] = hidden_render[:60]
    trap = [o.name for o in shown if o.hide_get() or o.hide_viewport]
    if trap:
        report['warnung_sichtbarkeit'] = (f'Im Viewport ausgeblendet, aber im Bild: {", ".join(trap[:12])}. blender_look und '
                                          'blender_render richten sich nach hide_render – zum Ausblenden obj.hide_render = True '
                                          '(und obj.hide_set(True)) setzen.')
    return report


def look(req):
    """Preview without the MI50s: solid (Workbench), eevee (Intel iGPU, few samples) or cycles (CPU, few samples).
    views: list of named views / {azimuth, elevation, distance} or a set name (rund, vier) → one raster image."""
    scene = bpy.context.scene
    render = scene.render
    mode = req.get('mode', 'solid')
    if mode not in ('solid', 'eevee', 'cycles'):
        raise ValueError('mode muss solid, eevee oder cycles sein.')
    views = req.get('views')
    if isinstance(views, str):
        views = VIEW_SETS.get(views, [v.strip() for v in views.split(',') if v.strip()])
    single_view = any(req.get(k) is not None for k in ('azimuth', 'elevation', 'target', 'distance'))
    if views is None and single_view:
        views = [{'azimuth': req.get('azimuth', 0), 'elevation': req.get('elevation', 10)}]
    many = bool(views) and len(views) > 1
    region = look_region(req)
    if region and many:
        raise ValueError('region/zoom gilt für eine einzelne Ansicht – nicht zusammen mit mehreren views.')
    default_size = 512 if many else 768
    size = max(128, min(int(req.get('size', default_size)), 2048))
    output = req['output']
    only = req.get('only')
    if isinstance(only, str):
        only = [only]
    focus = req.get('focus') or req.get('target')
    target_point = None
    if isinstance(req.get('target'), (list, tuple)) and len(req['target']) == 3:
        target_point = mathutils.Vector(req['target'])
    saved = {'engine': render.engine, 'x': render.resolution_x, 'y': render.resolution_y, 'pct': render.resolution_percentage,
             'path': render.filepath, 'fmt': render.image_settings.file_format, 'camera': scene.camera,
             'frame': scene.frame_current, 'stamp': render.use_stamp, 'border': render.use_border, 'crop': render.use_crop_to_border,
             'border_box': (render.border_min_x, render.border_max_x, render.border_min_y, render.border_max_y)}
    cycles = {}
    cameras = []
    hidden = []
    tiles = []
    try:
        if req.get('frame') is not None:
            scene.frame_set(int(req['frame']))
        if only:
            for name in only:
                object_or_error(name)
            for obj in scene.objects:
                if obj.type in GEOMETRY and obj.name not in only and not obj.hide_render:
                    obj.hide_render = True
                    hidden.append(obj)
        camera_name = req.get('camera')
        if camera_name and not views:
            camera = bpy.data.objects.get(camera_name)
            if camera is None or camera.type != 'CAMERA':
                raise ValueError(f'Kamera „{camera_name}“ gibt es nicht. Vorhandene Kameras: {cameras_text()}')
            scene.camera = camera
        points = world_points(focus) if focus else scene_points(scene, only)
        lens = float(req.get('lens', 50))
        if views:
            for view in views:
                if isinstance(view, dict):
                    direction = view_direction(float(view.get('azimuth', 0)), float(view.get('elevation', 10)))
                    label = view.get('name') or f'{view.get("azimuth", 0)}°/{view.get("elevation", 10)}°'
                    distance = view.get('distance', req.get('distance'))
                elif view in VIEWS:
                    direction, label, distance = view_direction(*VIEWS[view]), view, req.get('distance')
                else:
                    raise ValueError(f'Unbekannte Ansicht „{view}“. Möglich: {", ".join(VIEWS)} oder {{"azimuth": …, "elevation": …}}.')
                cameras.append((place_camera(scene, points, direction, lens, float(distance) if distance else None,
                                             target=target_point), label))
        elif scene.camera is None or req.get('overview') or focus:
            cameras.append((place_camera(scene, points, view_direction(*VIEWS['schräg']), lens, target=target_point),
                            'Übersicht (temporär)' if not focus else f'Fokus {focus}'))
        render.resolution_percentage = 100
        render.image_settings.file_format = 'PNG'
        render.use_stamp = False
        if mode == 'solid':
            render.engine = 'BLENDER_WORKBENCH'
        elif mode == 'eevee':
            render.engine = 'BLENDER_EEVEE' if 'BLENDER_EEVEE' in {e.identifier for e in render.bl_rna.properties['engine'].enum_items} else 'BLENDER_EEVEE_NEXT'
            cycles = {'eevee_samples': scene.eevee.taa_render_samples}
            scene.eevee.taa_render_samples = max(1, min(int(req.get('samples', 16)), 256))
        else:
            render.engine = 'CYCLES'
            cycles = {'device': scene.cycles.device, 'samples': scene.cycles.samples, 'denoise': scene.cycles.use_denoising}
            scene.cycles.device = 'CPU'
            scene.cycles.samples = max(1, min(int(req.get('samples', 24)), 512))
            scene.cycles.use_denoising = True
        started = time.time()
        with coloured_parts(scene, mode, req.get('color_by')) as legend:
            for index, (camera, label) in enumerate(cameras or [(scene.camera, scene.camera.name)]):
                scene.camera = camera
                if cameras:
                    render.resolution_x = render.resolution_y = size
                else:
                    aspect = saved['x'] / max(1, saved['y'])
                    render.resolution_x, render.resolution_y = (size, max(64, round(size / aspect))) if aspect >= 1 else (max(64, round(size * aspect)), size)
                if region:
                    # zoom = render only that part of the same frame, at a higher full resolution (real detail, not upscaled)
                    x0, y0, x1, y1 = region
                    factor = 1.0 / max(x1 - x0, y1 - y0)
                    render.resolution_x = min(16384, round(render.resolution_x * factor))
                    render.resolution_y = min(16384, round(render.resolution_y * factor))
                    render.use_border = True
                    render.use_crop_to_border = True
                    render.border_min_x, render.border_max_x = x0, x1
                    render.border_min_y, render.border_max_y = 1 - y1, 1 - y0   # Blender counts from the bottom
                if many:
                    render.use_stamp = True
                    for flag in ('use_stamp_date', 'use_stamp_time', 'use_stamp_render_time', 'use_stamp_frame', 'use_stamp_camera',
                                 'use_stamp_lens', 'use_stamp_scene', 'use_stamp_filename', 'use_stamp_memory', 'use_stamp_hostname',
                                 'use_stamp_marker', 'use_stamp_sequencer_strip', 'use_stamp_frame_range', 'use_stamp_time_code'):
                        if hasattr(render, flag):
                            setattr(render, flag, False)
                    render.use_stamp_note = True
                    render.stamp_note_text = label
                    render.stamp_font_size = max(12, size // 26)
                path = output if not many else f'{output[:-4]}-{index}.png'
                render.filepath = path
                bpy.ops.render.render(write_still=True)
                tiles.append((path, label))
        answer = {'ok': True, 'path': output, 'seconds': None, 'mode': mode}
        if many or req.get('reference'):
            answer.update(compose_grid([p for p, _ in tiles], [l for _, l in tiles], output, req.get('columns'), req.get('reference')))
        else:
            answer['camera'] = tiles[0][1]
            answer['resolution'] = [render.resolution_x, render.resolution_y]
            if region:
                answer['region'] = [round(v, 4) for v in region]
                answer['resolution'] = [round(render.resolution_x * (region[2] - region[0])), round(render.resolution_y * (region[3] - region[1]))]
        answer['seconds'] = round(time.time() - started, 2)
        answer.update(visibility_report(scene))
        try:
            import hashlib
            digest = hashlib.sha1(open(output, 'rb').read()).hexdigest()
            key = json.dumps({k: req.get(k) for k in ('views', 'camera', 'focus', 'azimuth', 'elevation', 'mode', 'region', 'zoom')},
                             sort_keys=True, default=str)
            if last_look.get(key) == digest:
                answer['gleiches_bild'] = ('Das Bild ist identisch mit dem vorigen blender_look derselben Ansicht – die Änderung '
                                           'ist nicht sichtbar (anderes Objekt, ausgeblendet, verdeckt oder nicht übernommen?).')
            last_look[key] = digest
        except OSError:
            pass
        if legend:
            answer['farben'] = legend
        if hidden:
            answer['ausgeblendet'] = len(hidden)
        return answer
    finally:
        render.engine, render.resolution_x, render.resolution_y = saved['engine'], saved['x'], saved['y']
        render.resolution_percentage, render.filepath = saved['pct'], saved['path']
        render.image_settings.file_format = saved['fmt']
        render.use_stamp = saved['stamp']
        render.use_border, render.use_crop_to_border = saved['border'], saved['crop']
        render.border_min_x, render.border_max_x, render.border_min_y, render.border_max_y = saved['border_box']
        scene.camera = saved['camera']
        if 'eevee_samples' in cycles:
            scene.eevee.taa_render_samples = cycles['eevee_samples']
        elif cycles:
            scene.cycles.device, scene.cycles.samples, scene.cycles.use_denoising = cycles['device'], cycles['samples'], cycles['denoise']
        for camera, _ in cameras:
            remove_camera(camera)
        for obj in hidden:
            obj.hide_render = False
        if many:
            for path, _ in tiles:
                try:
                    os.unlink(path)
                except OSError:
                    pass
        if scene.frame_current != saved['frame']:
            scene.frame_set(saved['frame'])


# ------------------------------------------------------------------ checks with numbers
def evaluated_arrays(obj):
    """World-space vertices, triangles (vertex ids), edges and the per-edge face count of the evaluated mesh."""
    import numpy as np
    depsgraph = bpy.context.evaluated_depsgraph_get()
    evaluated = obj.evaluated_get(depsgraph)
    mesh = evaluated.to_mesh()
    try:
        mesh.calc_loop_triangles()
        n = len(mesh.vertices)
        co = np.zeros(n * 3, np.float64)
        mesh.vertices.foreach_get('co', co)
        co = co.reshape(-1, 3)
        m = np.array(obj.matrix_world, np.float64)
        co = co @ m[:3, :3].T + m[:3, 3]
        tris = np.zeros(len(mesh.loop_triangles) * 3, np.int32)
        mesh.loop_triangles.foreach_get('vertices', tris)
        tris = tris.reshape(-1, 3)
        edges = np.zeros(len(mesh.edges) * 2, np.int32)
        mesh.edges.foreach_get('vertices', edges)
        edges = edges.reshape(-1, 2)
        loop_edges = np.zeros(len(mesh.loops), np.int32)
        mesh.loops.foreach_get('edge_index', loop_edges)
        faces_per_edge = np.bincount(loop_edges, minlength=len(edges))
        return co, tris, edges, faces_per_edge
    finally:
        evaluated.to_mesh_clear()


def islands(n, edges):
    """Connected components by min-label propagation with pointer jumping (fast for millions of vertices)."""
    import numpy as np
    labels = np.arange(n, dtype=np.int64)
    if len(edges) == 0:
        return labels
    a, b = edges[:, 0], edges[:, 1]
    for _ in range(400):
        low = np.minimum(labels[a], labels[b])
        changed = (labels[a] != low).any() or (labels[b] != low).any()
        np.minimum.at(labels, a, low)
        np.minimum.at(labels, b, low)
        for _ in range(30):
            jumped = labels[labels]
            if (jumped == labels).all():
                break
            labels = jumped
        if not changed:
            break
    return labels


def bvh_for(co, tris):
    from mathutils.bvhtree import BVHTree
    return BVHTree.FromPolygons([tuple(map(float, v)) for v in co], tris.tolist(), all_triangles=True, epsilon=0.0)


def where(points, digits=3):
    return [vec(p, digits) for p in points]


def check_mesh(obj, req, warnings):
    import numpy as np
    co, tris, edges, fpe = evaluated_arrays(obj)
    n = len(co)
    result = {'vertices': n, 'triangles': int(len(tris))}
    if n == 0 or len(tris) == 0:
        warnings.append(f'{obj.name}: leeres Netz.')
        return result
    low, high = co.min(0), co.max(0)
    diag = float(np.linalg.norm(high - low)) or 1.0
    result['bounds'] = {'min': vec(low), 'max': vec(high), 'size': vec(high - low)}
    # outliers: points far outside the body (Solidify "Even Offset" spikes) – they make Remesh explode
    center = np.median(co, 0)
    dist = np.linalg.norm(co - center, axis=1)
    typical = float(np.percentile(dist, 99)) or 1e-6
    far = dist > max(typical * 4, 0.05)
    if far.any():
        result['outliers'] = {'count': int(far.sum()), 'farthest_m': round(float(dist.max()), 3), 'at': vec(co[int(dist.argmax())])}
        warnings.append(f'{obj.name}: {int(far.sum())} Ausreißer-Punkte bis {dist.max():.2f} m weit draußen (z. B. Solidify „Even '
                        'Offset“) – vor Remesh/Subdivision entfernen.')
    if float((high - low).max()) > 10:
        warnings.append(f'{obj.name}: {float((high - low).max()):.1f} m groß – vor Remesh prüfen (helfer.groesse_pruefen).')
    # islands / loose parts
    labels = islands(n, edges)
    _, inverse, counts = np.unique(labels, return_inverse=True, return_counts=True)
    order = np.argsort(-counts)
    small_limit = max(int(n * float(req.get('small_part', 0.005))), 8)
    small = [i for i in order if counts[i] < small_limit]
    result['parts'] = {'count': int(len(counts)), 'largest_share': round(float(counts[order[0]] / n), 4),
                       'sizes': [int(counts[i]) for i in order[:8]]}
    if small:
        centers = [co[inverse == i].mean(0) for i in small[:6]]
        result['parts']['small'] = {'count': len(small), 'vertices': int(sum(counts[i] for i in small)), 'centers': where(centers)}
        warnings.append(f'{obj.name}: {len(small)} kleine lose Teile ({int(sum(counts[i] for i in small))} Vertices), z. B. bei {vec(centers[0])}.')
    if len(counts) > 1 and len(counts) - len(small) > 1:
        result['parts']['big_separate'] = int(len(counts) - len(small))
    # open borders and non-manifold edges
    boundary = int((fpe == 1).sum())
    nonmanifold = int((fpe > 2).sum())
    result['edges'] = {'open_border': boundary, 'non_manifold': nonmanifold, 'loose': int((fpe == 0).sum())}
    if boundary:
        border = edges[fpe == 1]
        mid = co[border].mean(1)
        result['edges']['open_border_sample'] = where(mid[:: max(1, len(mid) // 5)][:5])
        # rings of open edges = holes (or the intended open rim of a shell)
        ring = islands(n, border)[border[:, 0]]
        ids, ring_index = np.unique(ring, return_inverse=True)
        length = np.linalg.norm(co[border[:, 0]] - co[border[:, 1]], axis=1)
        rings = []
        for k in range(len(ids)):
            mask = ring_index == k
            pts = co[border[mask]].reshape(-1, 3)
            rings.append({'edges': int(mask.sum()), 'perimeter_mm': round(float(length[mask].sum()) * 1000, 1),
                          'center': vec(pts.mean(0)), 'size_mm': [round(float(v) * 1000, 1) for v in pts.max(0) - pts.min(0)]})
        rings.sort(key=lambda r: -r['perimeter_mm'])
        result['holes_open'] = {'count': len(rings), 'largest': rings[:8]}
        warnings.append(f'{obj.name}: {len(rings)} offene Ränder/Löcher, größtes Umfang {rings[0]["perimeter_mm"]} mm bei {rings[0]["center"]}.')
    if nonmanifold:
        warnings.append(f'{obj.name}: {nonmanifold} Kanten mit mehr als zwei Flächen (nicht-mannigfaltig).')
    # slivers and stretched triangles
    p0, p1, p2 = co[tris[:, 0]], co[tris[:, 1]], co[tris[:, 2]]
    l2 = np.stack([((p1 - p0) ** 2).sum(1), ((p2 - p1) ** 2).sum(1), ((p0 - p2) ** 2).sum(1)], 1)
    area = 0.5 * np.linalg.norm(np.cross(p1 - p0, p2 - p0), axis=1)
    quality = 4 * math.sqrt(3) * area / np.maximum(l2.sum(1), 1e-30)   # 1 = equilateral, 0 = sliver
    longest = np.sqrt(l2.max(1))
    median_edge = float(np.median(np.sqrt(l2))) or 1e-9
    sliver = quality < float(req.get('sliver', 0.05))
    stretched = longest > median_edge * float(req.get('stretch', 12))
    degenerate = area < (median_edge ** 2) * 1e-6
    centers = (p0 + p1 + p2) / 3
    result['triangles_quality'] = {'slivers': int(sliver.sum()), 'stretched': int(stretched.sum()), 'degenerate': int(degenerate.sum()),
                                   'median_edge_mm': round(median_edge * 1000, 3)}
    if stretched.any():
        worst = np.argsort(-longest)[:5]
        result['triangles_quality']['stretched_at'] = where(centers[worst])
        warnings.append(f'{obj.name}: {int(stretched.sum())} gedehnte Dreiecke (> {req.get("stretch", 12)}× Median-Kante), z. B. bei {vec(centers[worst[0]])}.')
    if sliver.sum() > len(tris) * 0.01:
        warnings.append(f'{obj.name}: {int(sliver.sum())} Splitter-Dreiecke ({100 * sliver.mean():.1f} %).')
    tree = None
    if req.get('holes', True) or req.get('layers', True):
        tree = bvh_for(co, tris)
    normals = np.cross(p1 - p0, p2 - p0)
    normals /= np.maximum(np.linalg.norm(normals, axis=1, keepdims=True), 1e-30)
    # holes: rays from outside that first hit a back face (open shell, hole or flipped normals)
    if req.get('holes', True):
        center = (low + high) / 2
        radius = diag * 0.75
        rays = int(req.get('rays', 1500))
        rng = np.random.default_rng(1)
        dirs = rng.normal(size=(rays, 3))
        dirs /= np.linalg.norm(dirs, axis=1, keepdims=True)
        aim = center + (rng.random((rays, 3)) - 0.5) * (high - low) * 0.9
        back, hits, back_at = 0, 0, []
        for d, target in zip(dirs, aim):
            origin = target - d * radius
            location, normal, index, _ = tree.ray_cast(mathutils.Vector(origin), mathutils.Vector(d))
            if location is None:
                continue
            hits += 1
            if float(np.dot(normals[index], d)) > 0.2:
                back += 1
                if len(back_at) < 6:
                    back_at.append(vec(location))
        result['holes'] = {'rays_hit': hits, 'backface_hits': back, 'share': round(back / max(hits, 1), 4), 'at': back_at}
        if back > max(3, hits * 0.01):
            warnings.append(f'{obj.name}: {back} von {hits} Strahlen treffen von außen eine Rückseite (Loch oder gedrehte Normalen), z. B. bei {back_at[0]}.')
    # overlapping layers: another surface very close in front of / behind a face, facing the SAME way
    # (duplicate shell, skin under a shell). Close surfaces facing each other are narrow gaps
    # (between fingers, thighs) or thin walls – counted separately, no warning.
    if req.get('layers', True):
        gap = float(req.get('layer_gap', diag * 0.004))
        sample = np.random.default_rng(2).choice(len(tris), size=min(len(tris), int(req.get('layer_samples', 8000))), replace=False)
        double, double_at, narrow = 0, [], 0
        for i in sample:
            c, nrm = centers[i], normals[i]
            found = None
            for sign in (1.0, -1.0):
                direction = mathutils.Vector(nrm * sign)
                origin = mathutils.Vector(c + nrm * sign * gap * 0.02)
                location, normal, index, distance = tree.ray_cast(origin, direction, gap)
                if location is None or index == i or distance <= gap * 0.01 or set(tris[index]).intersection(tris[i]):
                    continue
                facing = float(np.dot(normals[index], nrm))
                if facing > 0.85:
                    found = 'double'
                    break
                if facing < -0.85:
                    found = 'narrow'
            if found == 'double':
                double += 1
                if len(double_at) < 6:
                    double_at.append(vec(c))
            elif found == 'narrow':
                narrow += 1
        share = double / max(len(sample), 1)
        result['layers'] = {'gap_mm': round(gap * 1000, 2), 'sampled': int(len(sample)), 'double': double, 'share': round(share, 4), 'at': double_at,
                            'narrow_gaps_share': round(narrow / max(len(sample), 1), 4)}
        if share > 0.02:
            warnings.append(f'{obj.name}: {100 * share:.1f} % der Flächen haben eine zweite Schicht in < {gap * 1000:.1f} mm (übereinanderliegende Flächen), z. B. bei {double_at[0]}.')
    # wall thickness: from sampled faces straight inwards to the opposite wall
    if req.get('thickness'):
        if tree is None:
            tree = bvh_for(co, tris)
        count = min(len(tris), int(req.get('thickness_samples', 4000)))
        sample = np.random.default_rng(3).choice(len(tris), size=count, replace=False)
        found, at = [], []
        for i in sample:
            inward = mathutils.Vector(-normals[i])
            origin = mathutils.Vector(centers[i]) + inward * (median_edge * 1e-3)
            location, normal, index, distance = tree.ray_cast(origin, inward, diag)
            if location is None or index == i or float(np.dot(normals[index], -normals[i])) < 0.2:
                continue   # nothing behind it or not an opposite wall (open shell, inner detail)
            found.append(distance)
            at.append(centers[i])
        if found:
            found = np.array(found)
            order = np.argsort(found)
            result['thickness'] = {'sampled': int(count), 'measured': int(len(found)),
                                   'min_mm': round(float(found.min()) * 1000, 2), 'p5_mm': round(float(np.percentile(found, 5)) * 1000, 2),
                                   'median_mm': round(float(np.median(found)) * 1000, 2),
                                   'thinnest_at': [{'at': vec(at[k]), 'mm': round(float(found[k]) * 1000, 2)} for k in order[:6]]}
            limit = req.get('min_thickness')
            if limit is not None:
                thin = int((found < float(limit)).sum())
                result['thickness']['below_min'] = thin
                if thin:
                    warnings.append(f'{obj.name}: {thin} von {len(found)} Messpunkten dünner als {float(limit) * 1000:.1f} mm, '
                                    f'dünnste {found.min() * 1000:.2f} mm bei {vec(at[order[0]])}.')
        else:
            result['thickness'] = {'sampled': int(count), 'measured': 0, 'hinweis': 'Keine gegenüberliegende Wand gefunden (offene Fläche oder gedrehte Normalen).'}
    # floor
    if req.get('floor', True):
        floor = float(req.get('floor_z', 0.0))
        lowest = float(low[2])
        result['lowest_z'] = round(lowest, 4)
        if obj.parent is None and abs(lowest - floor) > float(req.get('floor_tolerance', 0.01)) and req.get('floor') is True:
            warnings.append(f'{obj.name}: tiefster Punkt {lowest:+.3f} m – {"schwebt" if lowest > floor else "steckt im Boden"} ({abs(lowest - floor) * 100:.1f} cm).')
    # armature: unweighted vertices
    arm = next((m for m in obj.modifiers if m.type == 'ARMATURE' and m.object), None)
    if arm:
        bones = {b.name for b in arm.object.data.bones if b.use_deform}
        group_names = {g.index: g.name for g in obj.vertex_groups if g.name in bones}
        unweighted = sum(1 for v in obj.data.vertices if not any(g.group in group_names and g.weight > 0 for g in v.groups))
        result['armature'] = {'object': arm.object.name, 'deform_bones': len(bones), 'unweighted_vertices': unweighted}
        if unweighted:
            warnings.append(f'{obj.name}: {unweighted} Vertices ohne Gewicht für {arm.object.name} (bleiben bei Posen stehen).')
    return result


def surface_points(spec):
    """Vertices (world, evaluated) of "Objekt" or "Objekt:Vertexgruppe" for distance checks."""
    import numpy as np
    name, _, part = str(spec).partition(':')
    obj = object_or_error(name)
    co, tris, _, _ = evaluated_arrays(obj)
    ids = None
    if part:
        group = obj.vertex_groups.get(part)
        if group is None:
            raise ValueError(f'Vertexgruppe „{part}“ gibt es in {name} nicht.')
        ids = np.array([v.index for v in obj.data.vertices if any(g.group == group.index and g.weight > 0.3 for g in v.groups)], np.int64)
        ids = ids[ids < len(co)]
    return obj, co, tris, ids


def check_pair(a_spec, b_spec, tolerance):
    import numpy as np
    _, a_co, _, a_ids = surface_points(a_spec)
    _, b_co, b_tris, b_ids = surface_points(b_spec)
    points = a_co if a_ids is None else a_co[a_ids]
    if len(points) > 60000:
        points = points[np.random.default_rng(3).choice(len(points), 60000, replace=False)]
    if b_ids is not None:
        keep = np.isin(b_tris, b_ids).all(1)
        b_tris = b_tris[keep]
    tree = bvh_for(b_co, b_tris)
    best, best_at, inside, depth = float('inf'), None, 0, 0.0
    for p in points:
        location, normal, index, distance = tree.find_nearest(mathutils.Vector(p))
        if location is None:
            continue
        if (mathutils.Vector(p) - location).dot(normal) < 0:
            inside += 1
            depth = max(depth, distance)
            distance = -distance
        if distance < best:
            best, best_at = distance, (vec(p), vec(location))
    result = {'a': a_spec, 'b': b_spec, 'min_distance_mm': round(best * 1000, 2), 'touching': bool(abs(best) <= tolerance),
              'a_points_inside_b': inside, 'max_penetration_mm': round(depth * 1000, 2), 'closest': best_at,
              'checked_points': int(len(points))}
    if inside:
        result['hint'] = f'{inside} Punkte von {a_spec} stecken in {b_spec} (bis {depth * 1000:.1f} mm).'
    elif best > tolerance:
        result['hint'] = f'Lücke von {best * 1000:.1f} mm zwischen {a_spec} und {b_spec}.'
    else:
        result['hint'] = 'Berührt ohne einzudringen.'
    return result


def remove_small_parts(obj, req):
    """Delete loose parts of the mesh itself (not the modifier result) below a size: remove_small = vertex count,
    or true = small_part share of all vertices (default 0.5 %). The largest part always stays."""
    import numpy as np
    import bmesh
    mesh = obj.data
    n = len(mesh.vertices)
    if n == 0:
        return {'parts': 0, 'vertices': 0}
    edges = np.zeros(len(mesh.edges) * 2, np.int32)
    mesh.edges.foreach_get('vertices', edges)
    labels = islands(n, edges.reshape(-1, 2))
    ids, inverse, counts = np.unique(labels, return_inverse=True, return_counts=True)
    limit = req['remove_small']
    limit = int(limit) if isinstance(limit, (int, float)) and not isinstance(limit, bool) else max(int(n * float(req.get('small_part', 0.005))), 8)
    small = counts < limit
    small[np.argmax(counts)] = False
    doomed = np.nonzero(small[inverse])[0]
    if len(doomed) == 0:
        return {'parts': 0, 'vertices': 0, 'limit_vertices': limit}
    if obj.mode != 'OBJECT':
        bpy.ops.object.mode_set(mode='OBJECT')
    bm = bmesh.new()
    bm.from_mesh(mesh)
    bm.verts.ensure_lookup_table()
    bmesh.ops.delete(bm, geom=[bm.verts[int(i)] for i in doomed], context='VERTS')
    bm.to_mesh(mesh)
    bm.free()
    mesh.update()
    return {'parts': int(small.sum()), 'vertices': int(len(doomed)), 'limit_vertices': limit}


def check(req):
    """Numbers instead of eyeballing: loose parts, open borders, slivers/stretched triangles, holes, double layers,
    floor, unweighted vertices; pairs: distance / contact / penetration between objects or vertex groups."""
    started = time.time()
    names = req.get('objects')
    if isinstance(names, str):
        names = [names]
    objects = [object_or_error(n) for n in names] if names else [o for o in bpy.context.scene.objects if o.type == 'MESH' and not o.hide_render]
    warnings = []
    report = {}
    removed = {}
    for obj in objects[:int(req.get('max_objects', 12))]:
        if obj.type != 'MESH':
            raise ValueError(f'{obj.name} ist kein Mesh ({obj.type}).')
        if req.get('remove_small'):
            removed[obj.name] = remove_small_parts(obj, req)
        report[obj.name] = check_mesh(obj, req, warnings)
        if obj.name in removed:
            report[obj.name]['removed_small_parts'] = removed[obj.name]
    pairs = req.get('pairs') or ([req['contact']] if req.get('contact') else [])
    contacts = [check_pair(a, b, float(req.get('tolerance', 0.002))) for a, b in pairs]
    for item in contacts:
        warnings.append(f'{item["a"]} ↔ {item["b"]}: {item["hint"]}')
    answer = {'ok': True, 'objects': report, 'warnings': warnings or ['Keine Auffälligkeiten.'], 'seconds': round(time.time() - started, 2)}
    if contacts:
        answer['pairs'] = contacts
    return answer


# ------------------------------------------------------------------ snapshots and own tools
def snapshot(req):
    name = re.sub(r'[^A-Za-z0-9._-]', '_', str(req.get('name') or time.strftime('stand-%H%M%S')))[:60]
    os.makedirs(SNAPSHOTS, exist_ok=True)
    path = os.path.join(SNAPSHOTS, name + '.blend')
    started = time.time()
    bpy.ops.wm.save_as_mainfile(filepath=path, copy=True, compress=False)
    meta = {'name': name, 'note': str(req.get('note', ''))[:300], 'date': time.strftime('%Y-%m-%d %H:%M:%S'),
            'objects': len(bpy.context.scene.objects), 'mb': round(os.path.getsize(path) / 1e6, 1)}
    with open(path[:-6] + '.json', 'w', encoding='utf-8') as handle:
        json.dump(meta, handle, ensure_ascii=False)
    removed = prune_snapshots(keep=int(req.get('keep', 12)))
    return {'ok': True, 'snapshot': meta, 'seconds': round(time.time() - started, 2), 'removed_old': removed}


def list_snapshots():
    items = []
    if os.path.isdir(SNAPSHOTS):
        for entry in os.listdir(SNAPSHOTS):
            if entry.endswith('.blend'):
                meta_path = os.path.join(SNAPSHOTS, entry[:-6] + '.json')
                try:
                    meta = json.load(open(meta_path, encoding='utf-8'))
                except (OSError, ValueError):
                    meta = {'name': entry[:-6]}
                meta['mtime'] = os.path.getmtime(os.path.join(SNAPSHOTS, entry))
                items.append(meta)
    return sorted(items, key=lambda m: m['mtime'])


def prune_snapshots(keep=12, max_gb=6.0):
    items = list_snapshots()
    removed = []
    total = sum(m.get('mb', 0) for m in items) / 1000
    while items and (len(items) > keep or total > max_gb):
        old = items.pop(0)
        total -= old.get('mb', 0) / 1000
        for ext in ('.blend', '.json'):
            try:
                os.unlink(os.path.join(SNAPSHOTS, old['name'] + ext))
            except OSError:
                pass
        removed.append(old['name'])
    return removed


def snapshots(req):
    items = list_snapshots()
    for m in items:
        m.pop('mtime', None)
    return {'ok': True, 'snapshots': items}


def restore(req):
    name = str(req.get('name') or '')
    items = list_snapshots()
    if not name and items:
        name = items[-1]['name']
    path = os.path.join(SNAPSHOTS, re.sub(r'[^A-Za-z0-9._-]', '_', name) + '.blend')
    if not os.path.isfile(path):
        raise ValueError(f'Zwischenstand „{name}“ gibt es nicht. Vorhanden: {", ".join(m["name"] for m in items) or "keine"}')
    bpy.ops.wm.open_mainfile(filepath=path, load_ui=False)
    bpy.ops.wm.save_as_mainfile(filepath=STATE, compress=True)   # keep working on the session file, not the snapshot
    namespace['C'] = bpy.context
    namespace['D'] = bpy.data
    return {'ok': True, 'restored': name, 'objects': [o.name for o in bpy.context.scene.objects][:100],
            'hint': 'Python-Variablen bleiben erhalten, zeigen aber evtl. auf Objekte des alten Stands – neu holen (D.objects[...]).'}


def tools(req):
    """Own helper functions, loaded at every session start: werkzeuge.py (show, set, add, clear, reload) and whole
    script files (mode file + name: stored as werkzeuge/<name>.py, replaced when loaded again; remove + name)."""
    mode = req.get('mode', 'show')
    code = req.get('code') or ''
    folder = os.path.join(FOLDER, 'werkzeuge')
    name = re.sub(r'[^A-Za-z0-9_-]', '_', str(req.get('name') or ''))[:60].strip('_')
    if mode in ('set', 'add', 'file'):
        if not code.strip():
            raise ValueError('code fehlt.')
        compile(code, name or TOOLS, 'exec')
    if mode in ('set', 'add'):
        with open(TOOLS, 'w' if mode == 'set' else 'a', encoding='utf-8') as handle:
            handle.write(code.rstrip() + '\n')
    elif mode == 'file':
        if not name:
            raise ValueError('name fehlt (Dateiname des Skripts).')
        os.makedirs(folder, exist_ok=True)
        with open(os.path.join(folder, name + '.py'), 'w', encoding='utf-8') as handle:
            handle.write(code.rstrip() + '\n')
    elif mode == 'remove':
        path = os.path.join(folder, name + '.py')
        if not name or not os.path.isfile(path):
            raise ValueError(f'Skript „{name}“ ist nicht geladen. Geladen: {", ".join(os.path.basename(f) for f in tool_files()) or "nichts"}')
        os.replace(path, path + '.alt')
    elif mode == 'clear':
        if os.path.exists(TOOLS):
            os.replace(TOOLS, TOOLS + '.alt')
    elif mode not in ('show', 'reload'):
        raise ValueError('mode: show, set, add, file, remove, clear oder reload.')
    answer = {'ok': True, 'file': TOOLS, 'scripts': [os.path.basename(f) for f in tool_files() if f != TOOLS]}
    if mode in ('set', 'add', 'file', 'reload'):
        if mode == 'file':
            before = set(namespace)
            exec(compile(code, os.path.join(folder, name + '.py'), 'exec'), namespace)
            answer['loaded'] = sorted(n for n in set(namespace) - before if not n.startswith('_'))
        else:
            answer['loaded'] = load_tools()
    if mode != 'file':
        text = open(TOOLS, encoding='utf-8').read() if os.path.exists(TOOLS) else ''
        answer['code'] = text[-30000:]
        answer['lines'] = text.count('\n')
    return answer


IMPORTERS = {
    '.glb': lambda p: bpy.ops.import_scene.gltf(filepath=p), '.gltf': lambda p: bpy.ops.import_scene.gltf(filepath=p),
    '.obj': lambda p: bpy.ops.wm.obj_import(filepath=p), '.fbx': lambda p: bpy.ops.import_scene.fbx(filepath=p),
    '.stl': lambda p: bpy.ops.wm.stl_import(filepath=p), '.ply': lambda p: bpy.ops.wm.ply_import(filepath=p),
    '.usd': lambda p: bpy.ops.wm.usd_import(filepath=p), '.usdz': lambda p: bpy.ops.wm.usd_import(filepath=p),
    '.usdc': lambda p: bpy.ops.wm.usd_import(filepath=p), '.abc': lambda p: bpy.ops.wm.alembic_import(filepath=p),
}


def open_file(req):
    path = req['path']
    if req.get('mode') == 'append' or path.lower().endswith(tuple(IMPORTERS)):
        ext = os.path.splitext(path)[1].lower()
        if ext == '.blend':
            with bpy.data.libraries.load(path) as (source, target):
                target.objects = list(source.objects)
            for obj in target.objects:
                if obj is not None:
                    bpy.context.scene.collection.objects.link(obj)
            names = [o.name for o in target.objects if o is not None]
        else:
            before = set(bpy.data.objects)
            IMPORTERS[ext](path)
            names = [o.name for o in bpy.data.objects if o not in before]
        return {'ok': True, 'imported': names[:200], 'count': len(names)}
    bpy.ops.wm.open_mainfile(filepath=path, load_ui=False)
    return {'ok': True, 'opened': os.path.basename(path), 'objects': len(bpy.context.scene.objects)}


def new_file(req):
    bpy.ops.wm.read_factory_settings(use_empty=bool(req.get('empty')))
    namespace.clear()
    namespace.update(fresh_namespace())
    answer = {'ok': True, 'objects': [o.name for o in bpy.context.scene.objects]}
    try:
        answer['werkzeuge'] = load_tools()
    except Exception:  # noqa: BLE001
        answer['werkzeuge_fehler'] = traceback.format_exc(limit=4)[-3000:]
    return answer


def save_copy(req):
    path = req['path']
    scene = bpy.context.scene
    if req.get('pack', True):
        try:
            bpy.ops.file.pack_all()
        except RuntimeError:
            pass
    previous = scene.camera
    if req.get('camera'):
        camera = bpy.data.objects.get(req['camera'])
        if camera is None or camera.type != 'CAMERA':
            raise ValueError(f'Kamera „{req["camera"]}“ gibt es nicht. Vorhandene Kameras: {cameras_text()}')
        scene.camera = camera
    try:
        bpy.ops.wm.save_as_mainfile(filepath=path, copy=True, compress=bool(req.get('compress', True)))
    finally:
        scene.camera = previous
    r = scene.render
    cyc = getattr(scene, 'cycles', None)
    use_denoising = bool(getattr(cyc, 'use_denoising', False))
    denoiser = getattr(cyc, 'denoiser', None) if use_denoising else 'off'
    return {'ok': True, 'path': path, 'frames': [scene.frame_start, scene.frame_end], 'engine': r.engine,
            'current': scene.frame_current, 'fps': round(r.fps / r.fps_base, 3),
            # for the labels of render comparisons (camera, resolution, samples, source file)
            'camera': (bpy.data.objects[req['camera']].name if req.get('camera') else (scene.camera.name if scene.camera else None)),
            'resolution': [r.resolution_x * r.resolution_percentage // 100, r.resolution_y * r.resolution_percentage // 100],
            'base_resolution': [r.resolution_x, r.resolution_y],
            'samples': getattr(cyc, 'samples', None),
            'denoising': use_denoising,
            'denoiser': denoiser,
            'adaptive_sampling': bool(getattr(cyc, 'use_adaptive_sampling', False)),
            'adaptive_threshold': getattr(cyc, 'adaptive_threshold', None),
            'source': os.path.basename(bpy.data.filepath) or None}


def api_docs(req):
    """Version-exact Python API reference from Blender's own RNA (bpy.types.X, bpy.ops.a.b, or X.prop)."""
    name = (req.get('identifier') or '').strip()
    if not name:
        raise ValueError('identifier fehlt, z. B. "bpy.types.Object", "bpy.ops.mesh.primitive_cube_add" oder "CyclesRenderSettings".')

    def props(rna):
        result = []
        for p in rna.properties:
            if p.identifier == 'rna_type':
                continue
            entry = {'name': p.identifier, 'type': p.type, 'description': p.description[:200]}
            if p.type == 'ENUM':
                entry['items'] = [i.identifier for i in p.enum_items][:60]
            elif p.type in ('INT', 'FLOAT') and getattr(p, 'array_length', 0) == 0:
                entry['default'] = p.default
            if p.type == 'POINTER':
                entry['fixed_type'] = p.fixed_type.identifier
            if p.is_readonly:
                entry['readonly'] = True
            result.append(entry)
        return result

    if name.startswith('bpy.ops.'):
        module, _, op = name[8:].partition('.')
        operators = dir(getattr(bpy.ops, module)) if module in dir(bpy.ops) else []
        if op not in operators:
            pool = [f'bpy.ops.{module}.{o}' for o in operators] or [f'bpy.ops.{m}' for m in dir(bpy.ops) if not m.startswith('_')]
            similar = difflib.get_close_matches(name, pool, n=12, cutoff=0.5) or [p for p in pool if op and op.lower() in p.lower()][:12]
            return {'ok': False, 'error': f'{name} gibt es nicht.', 'similar': similar}
        rna = getattr(getattr(bpy.ops, module), op).get_rna_type()
        return {'ok': True, 'operator': name, 'description': rna.description, 'parameters': props(rna)}
    if name.startswith('bpy.types.'):
        name = name[10:]
    attribute = None
    if '.' in name:
        name, attribute = name.split('.', 1)
    cls = getattr(bpy.types, name, None)
    if cls is None:
        matches = ([n for n in dir(bpy.types) if name.lower() in n.lower()][:30]
                   or difflib.get_close_matches(name, dir(bpy.types), n=10, cutoff=0.5))
        return {'ok': False, 'error': f'bpy.types.{name} gibt es nicht.', 'similar': matches}
    rna = cls.bl_rna
    if attribute:
        prop = rna.properties.get(attribute)
        if prop is None:
            function = rna.functions.get(attribute)
            if function is None:
                pool = [p.identifier for p in rna.properties] + [f.identifier for f in rna.functions]
                return {'ok': False, 'error': f'{name}.{attribute} gibt es nicht.',
                        'similar': [f'{name}.{n}' for n in difflib.get_close_matches(attribute, pool, n=10, cutoff=0.5)]}
            return {'ok': True, 'function': f'{name}.{attribute}', 'description': function.description,
                    'parameters': props(function)}
        return {'ok': True, 'property': f'{name}.{attribute}', **[p for p in props(rna) if p['name'] == attribute][0]}
    return {'ok': True, 'type': name, 'description': rna.description, 'base': rna.base.identifier if rna.base else None,
            'properties': props(rna),
            'functions': [{'name': f.identifier, 'description': f.description[:200]} for f in rna.functions]}


def info(req):
    rss, free = memory_now()
    return {'ok': True, 'blender': bpy.app.version_string, 'build_type': build_type_text(), 'file': bpy.data.filepath or None,
            'unsaved_changes': bpy.data.is_dirty, 'objects': len(bpy.context.scene.objects), 'pid': os.getpid(),
            'idle_exit_seconds': IDLE, 'memory_gb': round(rss, 1), 'bigki_free_gb': round(free or 0, 1),
            'memory_limit_gb': MAX_GB, 'autosave': {k: v for k, v in autosave.items() if k != 'next'}}


def save_state():
    os.makedirs(os.path.dirname(STATE), exist_ok=True)
    try:
        save_variables()
    except Exception:  # noqa: BLE001
        traceback.print_exc()
    temp = STATE + '.tmp.blend'
    bpy.ops.wm.save_as_mainfile(filepath=temp, copy=True, compress=True)
    os.replace(temp, STATE)


COMMANDS = {'python': run_python, 'scene': scene_summary, 'look': look, 'open': open_file, 'new': new_file,
            'save': save_copy, 'api': api_docs, 'info': info, 'check': check, 'snapshot': snapshot, 'snapshots': snapshots,
            'restore': restore, 'tools': tools}


def main():
    global last_request, running, unsaved
    try:
        os.unlink(SOCKET)
    except FileNotFoundError:
        pass
    old = os.umask(0o077)
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(SOCKET)
    os.umask(old)
    server.listen(8)
    threading.Thread(target=accept_loop, args=(server,), daemon=True).start()
    threading.Thread(target=memory_guard, daemon=True).start()
    signal.signal(signal.SIGTERM, lambda *_: requests.put((None, None)))
    loaded, tools_error = [], None
    try:
        loaded = load_tools()
    except Exception:  # noqa: BLE001
        tools_error = traceback.format_exc(limit=4)[-3000:]
    base_names.update(namespace)
    restored = restore_agent_state() if restarted else []
    first = True
    write_status()
    print('STUDIOPORTAL_BLENDER_READY', flush=True)
    while running:
        try:
            req, conn = requests.get(timeout=1.5 if unsaved else 5)
        except queue.Empty:
            if unsaved and time.time() >= autosave['next']:
                save_now()
                write_status()
            if time.time() - last_request > IDLE:
                end_reason.update(reason='idle', text=f'nach {IDLE // 60} min ohne Aufruf automatisch geschlossen')
                break
            continue
        if req is None:
            break
        last_request = time.time()
        command = req.get('command')
        if command == 'quit':
            end_reason.update(reason='quit', text='mit „quit“ beendet' + (f' ({req.get("origin")})' if req.get('origin') else ''))
            reply(conn, {'ok': True, 'message': 'Sitzung wird gespeichert und beendet.'})
            break
        current.clear()
        current.update(command=command, code=(req.get('code') or '')[:1500] if command in ('python', 'tools') else '',
                       time=time.strftime('%H:%M:%S'))
        try:
            with open(RUNNING, 'w', encoding='utf-8') as handle:
                json.dump(current, handle, ensure_ascii=False)
        except OSError:
            pass
        if command == 'look' and unsaved:
            # a hanging preview gets killed by the worker – save first so nothing from the previous call is lost
            save_now()
        try:
            handler = COMMANDS.get(command)
            if handler is None:
                raise ValueError(f'Unbekannter Befehl: {command}')
            answer = handler(req)
        except Exception as error:  # noqa: BLE001
            answer = {'ok': False, 'error': f'{type(error).__name__}: {error}', 'traceback': traceback.format_exc(limit=6)[-4000:]}
        if changes_scene(command, req):
            unsaved = True
        entry = {'time': current.get('time'), 'command': command, 'ok': bool(isinstance(answer, dict) and answer.get('ok', True)),
                 'seconds': round(time.time() - last_request, 1)}
        if current.get('code'):
            entry['code'] = current['code'][:160]
        if isinstance(answer, dict) and answer.get('error'):
            entry['error'] = str(answer['error']).strip().splitlines()[-1][:200]
        history.append(entry)
        del history[:-30]
        try:
            os.unlink(RUNNING)
        except OSError:
            pass
        if first:
            first = False
            notes = list(startup_notes)
            if restarted:
                if previous_ending and previous_ending.get('text'):
                    why = f'die vorige Sitzung wurde {previous_ending.get("time", "")} {previous_ending["text"]}'
                elif startup_notes and any(n.startswith(('Letzter Absturz', 'Die vorige Sitzung ist')) for n in startup_notes):
                    why = 'nach einem Absturz, Details unten'
                else:
                    why = 'die vorige Sitzung endete ohne Abschlussmeldung (von außen beendet, z. B. Neustart von bigki oder kill)'
                notes.insert(0, f'Sitzung wurde neu gestartet ({why}): Szene ist wieder geladen.'
                                + (f' Werkzeuge neu geladen: {", ".join(loaded)}.' if loaded else '')
                                + (' ' + '; '.join(restored) + '.' if restored else
                                   ' Keine eigenen Variablen/Funktionen zum Wiederherstellen.'))
            if tools_error:
                notes.append('werkzeuge.py hat einen Fehler: ' + tools_error)
            if notes and isinstance(answer, dict):
                answer['hinweis'] = ' '.join(notes)
        reply(conn, answer)
        write_status()
    running = False
    try:
        save_state()
    except Exception:  # noqa: BLE001
        traceback.print_exc()
    try:
        end_reason.setdefault('reason', 'stop')
        end_reason.setdefault('text', 'beendet (Stoppsignal)')
        end_reason['time'] = time.strftime('%d.%m. %H:%M:%S')
        with open(END, 'w', encoding='utf-8') as handle:
            json.dump(end_reason, handle, ensure_ascii=False)
    except OSError:
        pass
    server.close()
    try:
        os.unlink(SOCKET)
    except FileNotFoundError:
        pass


main()
