"""Everyday helpers for the StudioPortal Blender session, loaded at every session start as `helfer`
(next to `figur`). They survive the 30-minute idle restart because they are part of StudioPortal, not of the scene.

    helfer.kamera('Kam_vorne', ziel='Figur', azimut=0, hoehe=10)      camera that frames an object / point
    helfer.punkte('Figur')                                               vertex positions as numpy array (world)
    helfer.glaetten('Figur', faktor=0.5, schritte=5)                   Laplacian smoothing (whole mesh or a group)
    helfer.groesse_pruefen('Kleid', voxel=0.004)                         size, outliers, expected points before Remesh
    helfer.remesh('Scan', voxel=0.004)                                   voxel remesh, applied (checks size first)
    helfer.dezimieren('Scan', anteil=0.3)                                fewer triangles, applied
    helfer.hilfe()                                                       this overview
"""
import math

import bpy
import mathutils


def _obj(name):
    obj = bpy.data.objects.get(name) if isinstance(name, str) else name
    if obj is None:
        raise ValueError(f'Objekt „{name}“ gibt es nicht.')
    return obj


def _mesh(name):
    obj = _obj(name)
    if obj.type != 'MESH':
        raise ValueError(f'{obj.name} ist kein Mesh ({obj.type}).')
    if bpy.context.object is not None and bpy.context.object.mode != 'OBJECT':
        bpy.ops.object.mode_set(mode='OBJECT')
    return obj


def punkte(objekt, welt=True, evaluiert=True, gruppe=None, min_gewicht=0.3):
    """Vertex positions (N×3 numpy). evaluiert=True includes modifiers/shape keys/pose; gruppe = only that vertex group
    (needs the same vertex count, i.e. no topology-changing modifiers)."""
    import numpy as np
    obj = _mesh(objekt)
    mesh, owner = obj.data, None
    if evaluiert:
        owner = obj.evaluated_get(bpy.context.evaluated_depsgraph_get())
        mesh = owner.to_mesh()
    try:
        co = np.zeros(len(mesh.vertices) * 3, np.float64)
        mesh.vertices.foreach_get('co', co)
        co = co.reshape(-1, 3)
    finally:
        if owner is not None:
            owner.to_mesh_clear()
    if gruppe is not None:
        group = obj.vertex_groups.get(gruppe)
        if group is None:
            raise ValueError(f'Vertexgruppe „{gruppe}“ gibt es in {obj.name} nicht.')
        if len(co) != len(obj.data.vertices):
            raise ValueError('Die Modifier ändern die Punktzahl – gruppe geht nur mit evaluiert=False.')
        ids = [v.index for v in obj.data.vertices if any(g.group == group.index and g.weight >= min_gewicht for g in v.groups)]
        co = co[ids]
    if welt:
        m = np.array(obj.matrix_world, np.float64)
        co = co @ m[:3, :3].T + m[:3, 3]
    return co


def _bounds(ziel):
    """Corner points of an object (evaluated bounds), "Objekt:Gruppe", a point [x,y,z] or None = all visible meshes."""
    if ziel is None:
        objects = [o for o in bpy.context.scene.objects if o.type == 'MESH' and not o.hide_render]
        points = [o.matrix_world @ mathutils.Vector(c) for o in objects
                  for c in o.evaluated_get(bpy.context.evaluated_depsgraph_get()).bound_box]
        return points or [mathutils.Vector((-1, -1, 0)), mathutils.Vector((1, 1, 2))]
    if isinstance(ziel, (list, tuple)) and len(ziel) == 3 and all(isinstance(v, (int, float)) for v in ziel):
        return [mathutils.Vector(ziel)]
    name, _, group = str(ziel).partition(':')
    if group:
        co = punkte(name, gruppe=group, evaluiert=False)
        low, high = co.min(0), co.max(0)
        return [mathutils.Vector((x, y, z)) for x in (low[0], high[0]) for y in (low[1], high[1]) for z in (low[2], high[2])]
    obj = _obj(name)
    evaluated = obj.evaluated_get(bpy.context.evaluated_depsgraph_get())
    return [obj.matrix_world @ mathutils.Vector(c) for c in evaluated.bound_box]


def kamera(name='Kamera', ziel=None, azimut=30.0, hoehe=12.0, abstand=None, brennweite=50.0, rand=1.08,
           aktiv=True, aufloesung=None):
    """Create or move camera `name` so that `ziel` fills the picture. azimut 0 = from the front (-Y), 90 = from the
    right (+X); hoehe = elevation in degrees; abstand in m (None = fit). aufloesung = (x, y) for the scene.
    Returns {kamera, ort, abstand}."""
    scene = bpy.context.scene
    if aufloesung:
        scene.render.resolution_x, scene.render.resolution_y = int(aufloesung[0]), int(aufloesung[1])
    camera = bpy.data.objects.get(name)
    if camera is None:
        camera = bpy.data.objects.new(name, bpy.data.cameras.new(name))
        scene.collection.objects.link(camera)
    elif camera.type != 'CAMERA':
        raise ValueError(f'„{name}“ ist keine Kamera.')
    data = camera.data
    data.lens = float(brennweite)
    points = _bounds(ziel)
    low = mathutils.Vector([min(p[i] for p in points) for i in range(3)])
    high = mathutils.Vector([max(p[i] for p in points) for i in range(3)])
    center = (low + high) / 2
    a, e = math.radians(azimut), math.radians(max(-89.5, min(89.5, hoehe)))
    direction = mathutils.Vector((math.sin(a) * math.cos(e), -math.cos(a) * math.cos(e), math.sin(e))).normalized()
    forward = -direction
    right = forward.cross(mathutils.Vector((0, 0, 1)))
    right = right.normalized() if right.length > 1e-6 else mathutils.Vector((1, 0, 0))
    up = right.cross(forward).normalized()
    aspect = scene.render.resolution_x / max(1, scene.render.resolution_y)
    # sensor fit AUTO: the wider side gets the full angle
    wide = math.tan(data.angle / 2)
    tan_x, tan_y = (wide, wide / aspect) if aspect >= 1 else (wide * aspect, wide)
    if abstand is None:
        abstand = 1e-3
        for x in (low.x, high.x):
            for y in (low.y, high.y):
                for z in (low.z, high.z):
                    offset = mathutils.Vector((x, y, z)) - center
                    depth = offset.dot(direction)
                    abstand = max(abstand, depth + abs(offset.dot(right)) / tan_x, depth + abs(offset.dot(up)) / tan_y)
        abstand *= rand
    camera.location = center + direction * float(abstand)
    camera.rotation_euler = forward.to_track_quat('-Z', 'Y').to_euler()
    data.clip_start, data.clip_end = max(abstand / 2000, 1e-4), max(abstand * 30, 100)
    if aktiv:
        scene.camera = camera
    return {'kamera': camera.name, 'ort': [round(v, 4) for v in camera.location], 'abstand': round(float(abstand), 4)}


def glaetten(objekt, faktor=0.5, schritte=5, gruppe=None, raender_halten=True):
    """Laplacian smoothing of the mesh itself (all vertices or one vertex group). Open borders stay put by default."""
    import bmesh
    obj = _mesh(objekt)
    mesh = obj.data
    selected = None
    if gruppe is not None:
        group = obj.vertex_groups.get(gruppe)
        if group is None:
            raise ValueError(f'Vertexgruppe „{gruppe}“ gibt es in {obj.name} nicht.')
        selected = {v.index for v in mesh.vertices if any(g.group == group.index and g.weight > 0.3 for g in v.groups)}
    bm = bmesh.new()
    bm.from_mesh(mesh)
    verts = [v for v in bm.verts if (selected is None or v.index in selected) and not (raender_halten and v.is_boundary)]
    for _ in range(int(schritte)):
        bmesh.ops.smooth_vert(bm, verts=verts, factor=float(faktor), use_axis_x=True, use_axis_y=True, use_axis_z=True)
    bm.to_mesh(mesh)
    bm.free()
    mesh.update()
    return {'objekt': obj.name, 'punkte': len(verts), 'schritte': int(schritte)}


def _apply(obj, modifier):
    with bpy.context.temp_override(object=obj, active_object=obj, selected_objects=[obj]):
        bpy.ops.object.modifier_apply(modifier=modifier.name)


def groesse_pruefen(objekt, voxel=None, max_m=10.0, max_punkte=6_000_000):
    """Before Remesh/Subdivision: object size (evaluated, with modifiers), outlier points and – with voxel – the
    expected vertex count. Raises a clear error instead of filling bigki's memory."""
    import numpy as np
    obj = _mesh(objekt)
    owner = obj.evaluated_get(bpy.context.evaluated_depsgraph_get())
    mesh = owner.to_mesh()
    try:
        co = np.zeros(len(mesh.vertices) * 3, np.float64)
        mesh.vertices.foreach_get('co', co)
        area = np.zeros(len(mesh.polygons), np.float64)
        mesh.polygons.foreach_get('area', area)
    finally:
        owner.to_mesh_clear()
    co = co.reshape(-1, 3)
    m = np.array(obj.matrix_world, np.float64)
    co = co @ m[:3, :3].T + m[:3, 3]
    scale = float(np.abs(np.linalg.det(m[:3, :3]))) ** (2 / 3) or 1.0
    size = (co.max(0) - co.min(0)) if len(co) else np.zeros(3)
    info = {'objekt': obj.name, 'groesse_m': [round(float(v), 3) for v in size], 'flaeche_m2': round(float(area.sum()) * scale, 3)}
    problems = []
    if len(co):
        center = np.median(co, 0)
        dist = np.linalg.norm(co - center, axis=1)
        typical = float(np.percentile(dist, 99)) or 1e-6
        far = dist > max(typical * 4, 0.05)
        if far.any():
            info['ausreisser'] = {'anzahl': int(far.sum()), 'weitester_m': round(float(dist.max()), 3),
                                  'beispiel': [round(float(v), 3) for v in co[int(dist.argmax())]]}
            problems.append(f'{int(far.sum())} Ausreißer-Punkte bis {dist.max():.2f} m vom Körper entfernt (z. B. von Solidify '
                            '„Even Offset“ an spitzen Stellen) – erst entfernen oder den Modifier ändern')
    if size.max() > max_m:
        problems.append(f'Objekt ist {size.max():.1f} m groß (Grenze {max_m} m)')
    if voxel:
        expected = float(area.sum()) * scale / float(voxel) ** 2
        info['erwartete_punkte'] = int(expected)
        if expected > max_punkte:
            suggestion = (float(area.sum()) * scale / max_punkte) ** 0.5
            problems.append(f'Remesh mit voxel={voxel} ergäbe etwa {expected / 1e6:.1f} Mio. Punkte (Grenze {max_punkte / 1e6:.0f} Mio.) – '
                            f'voxel ≥ {suggestion:.4f} wählen')
    info['ok'] = not problems
    if problems:
        info['probleme'] = problems
    return info


def remesh(objekt, voxel=0.005, glatt=True, anwenden=True, volumen_halten=True, erzwingen=False):
    """Voxel remesh (closed, even triangles; closes small holes). voxel in m. Checks size, outliers and the expected
    vertex count first (erzwingen=True skips that). Returns the new vertex count."""
    obj = _mesh(objekt)
    check = groesse_pruefen(obj, voxel)
    if not check['ok'] and not erzwingen:
        raise ValueError('Remesh abgebrochen, damit der Speicher nicht vollläuft: ' + '; '.join(check['probleme'])
                         + '. Details: helfer.groesse_pruefen(...); trotzdem: erzwingen=True.')
    if obj.data.shape_keys is not None and anwenden:
        raise ValueError(f'{obj.name} hat Shape Keys – vorher anwenden/entfernen (Remesh kann sie nicht behalten).')
    before = len(obj.data.vertices)
    modifier = obj.modifiers.new('StudioRemesh', 'REMESH')
    modifier.mode = 'VOXEL'
    modifier.voxel_size = float(voxel)
    modifier.use_smooth_shade = bool(glatt)
    if hasattr(modifier, 'use_preserve_volume'):
        modifier.use_preserve_volume = bool(volumen_halten)
    if anwenden:
        _apply(obj, modifier)
    return {'objekt': obj.name, 'vorher': before, 'nachher': len(obj.data.vertices) if anwenden else None,
            'angewendet': bool(anwenden)}


def dezimieren(objekt, anteil=0.5, anwenden=True):
    """Reduce triangles to `anteil` (0–1) with the collapse decimator."""
    obj = _mesh(objekt)
    before = len(obj.data.polygons)
    modifier = obj.modifiers.new('StudioDecimate', 'DECIMATE')
    modifier.ratio = max(0.001, min(float(anteil), 1.0))
    if anwenden:
        _apply(obj, modifier)
    return {'objekt': obj.name, 'flaechen_vorher': before, 'flaechen_nachher': len(obj.data.polygons) if anwenden else None}


def hilfe():
    return {name: (func.__doc__ or '').strip().split('\n')[0] for name, func in
            [('kamera', kamera), ('punkte', punkte), ('glaetten', glaetten), ('groesse_pruefen', groesse_pruefen),
             ('remesh', remesh), ('dezimieren', dezimieren)]} | {
        'auch': 'blender_check (lose Teile zählen/löschen mit remove_small, Dicke mit thickness, Löcher, Ausreißer), blender_snapshot, '
                'figur.hilfe(); Python-Pakete: numpy, scipy, igl (libigl), robust_laplacian'}
