"""Figure building blocks for the StudioPortal Blender session (available there as `figur`).

Recipe for realistic people (porcelain look):
  1. body in A-pose: figur.mensch(...) (MPFB, already rigged) or a scan/AI mesh in A-pose (open hands, no props)
  2. scan only: figur.scan_aufraeumen(scan); figur.abgleichen(rig, scan); figur.gewichte_uebertragen(body, scan, rig)
  3. pose: figur.arm_ik / figur.bein_ik (move the empties), then figur.hand_greifen(rig, obj, 'L') – for a phone held
     upright figur.handy_griff(rig, 'R'); heavy figures: figur.schnell_posieren(True) while posing; motion from
     Mixamo/BVH: figur.bvh_laden(datei, rig)
  4. props: figur.anhaengen(phone, rig, 'wrist.L')
  5. look: figur.porzellan([...]); figur.studio_licht(scan)
Check with blender_check (pairs=hand/object) and blender_look after every step; blender_snapshot before risky steps.
All lengths are metres; the MPFB figure looks along -Y with +Z up.
"""
import math
from pathlib import Path
import time

import bpy
import mathutils
import numpy as np
from mathutils.bvhtree import BVHTree

MPFB_MODULE = 'bl_ext.user_default.mpfb'
HELPER_GROUPS = ('HelperGeometry', 'JointCubes')


# ------------------------------------------------------------------ small helpers
def _obj(value):
    if isinstance(value, bpy.types.Object):
        return value
    found = bpy.data.objects.get(value)
    if found is None:
        raise ValueError(f'Objekt {value!r} nicht gefunden. Vorhanden: {", ".join(o.name for o in bpy.data.objects)[:600]}')
    return found


def _objs(values):
    if values is None:
        return [o for o in bpy.data.objects if o.type == 'MESH']
    if isinstance(values, (str, bpy.types.Object)):
        values = [values]
    return [_obj(v) for v in values]


def _link(obj, like=None):
    collection = like.users_collection[0] if like is not None and like.users_collection else bpy.context.scene.collection
    collection.objects.link(obj)
    return obj


def _mesh_arrays(obj, evaluated=False):
    """World-space vertices, triangles (vertex indices) and vertex normals of a mesh object."""
    owner = obj.evaluated_get(bpy.context.evaluated_depsgraph_get()) if evaluated else obj
    mesh = owner.to_mesh() if evaluated else obj.data
    try:
        n = len(mesh.vertices)
        co = np.empty(n * 3, np.float32)
        mesh.vertices.foreach_get('co', co)
        nor = np.empty(n * 3, np.float32)
        mesh.vertex_normals.foreach_get('vector', nor)
        mesh.calc_loop_triangles()
        tris = np.empty(len(mesh.loop_triangles) * 3, np.int32)
        mesh.loop_triangles.foreach_get('vertices', tris)
    finally:
        if evaluated:
            owner.to_mesh_clear()
    mw = np.array(obj.matrix_world, np.float64)
    co = co.reshape(-1, 3) @ mw[:3, :3].T + mw[:3, 3]
    normal_matrix = np.linalg.inv(mw[:3, :3]).T
    nor = nor.reshape(-1, 3) @ normal_matrix.T
    nor /= np.maximum(np.linalg.norm(nor, axis=1, keepdims=True), 1e-12)
    tris = tris.reshape(-1, 3)
    if np.linalg.det(mw[:3, :3]) < 0:          # mirrored object: keep triangles facing outwards
        tris = tris[:, ::-1].copy()
    return co, tris, nor


def _bvh(obj):
    co, tris, _ = _mesh_arrays(obj, evaluated=True)
    return BVHTree.FromPolygons(co.tolist(), tris.tolist(), all_triangles=True)


def _height(obj):
    corners = [obj.matrix_world @ mathutils.Vector(c) for c in obj.bound_box]
    return min(c.z for c in corners), max(c.z for c in corners), corners


def _set_input(node, names, value):
    for name in names if isinstance(names, (list, tuple)) else [names]:
        if name in node.inputs:
            node.inputs[name].default_value = value
            return True
    return False


# ------------------------------------------------------------------ MPFB people
def mpfb():
    """Enable the MPFB extension (the session starts with --factory-startup) and return its HumanService."""
    if MPFB_MODULE not in bpy.context.preferences.addons:
        bpy.ops.preferences.addon_enable(module=MPFB_MODULE)
    from bl_ext.user_default.mpfb.services.humanservice import HumanService  # noqa: PLC0415
    return HumanService


def mensch(name='Mensch', geschlecht=0.0, alter=0.5, muskeln=0.5, gewicht=0.5, groesse=0.5, proportionen=0.5,
           brust=0.5, hoehe_m=None, rig='default', glatt=1, ort=(0.0, 0.0, 0.0)):
    """A rigged MakeHuman body in A-pose (open hands). geschlecht 0 = woman, 1 = man; alter 0.5 ≈ 25 years.
    hoehe_m scales the whole figure to that height. Returns {'koerper', 'rig', 'hoehe_m', 'knochen'}."""
    service = mpfb()
    body = service.create_human(macro_detail_dict={
        'gender': geschlecht, 'age': alter, 'muscle': muskeln, 'weight': gewicht, 'height': groesse,
        'proportions': proportionen, 'cupsize': brust, 'firmness': 0.5,
        'race': {'african': 0.33, 'asian': 0.33, 'caucasian': 0.34}})
    armature = service.add_builtin_rig(body, rig) if rig else None
    body.name = name
    if armature is not None:
        armature.name = f'{name}.rig'
    top = armature or body
    if hoehe_m:
        bpy.context.view_layer.update()
        low, high, _ = _height(body)
        factor = hoehe_m / max(high - low, 1e-6)
        top.scale = [s * factor for s in top.scale]
    top.location = ort
    if glatt:
        sub = body.modifiers.new('Glatt', 'SUBSURF')
        sub.levels = sub.render_levels = int(glatt)
    bpy.context.view_layer.update()
    low, high, _ = _height(body)
    return {'koerper': body.name, 'rig': armature.name if armature else None, 'hoehe_m': round(high - low, 3),
            'knochen': len(armature.data.bones) if armature else 0}


# ------------------------------------------------------------------ looks
def porzellan(objekte=None, farbe=(0.93, 0.92, 0.89), rauheit=0.3, lack=1.0, lack_rauheit=0.04, durchscheinen=0.12,
              name='Porzellan'):
    """Glazed white porcelain (Principled BSDF with clear coat and a little subsurface) on the given objects
    (all meshes when None). Replaces their materials. Returns the material name."""
    material = bpy.data.materials.get(name) or bpy.data.materials.new(name)
    material.use_nodes = True
    bsdf = next((n for n in material.node_tree.nodes if n.type == 'BSDF_PRINCIPLED'), None)
    if bsdf is None:
        bsdf = material.node_tree.nodes.new('ShaderNodeBsdfPrincipled')
    _set_input(bsdf, 'Base Color', (*farbe, 1.0))
    _set_input(bsdf, 'Roughness', rauheit)
    _set_input(bsdf, ('Coat Weight', 'Clearcoat'), lack)
    _set_input(bsdf, ('Coat Roughness', 'Clearcoat Roughness'), lack_rauheit)
    _set_input(bsdf, 'Coat IOR', 1.52)
    _set_input(bsdf, ('Subsurface Weight', 'Subsurface'), durchscheinen)
    _set_input(bsdf, 'Subsurface Radius', (1.0, 0.85, 0.7))
    _set_input(bsdf, 'Subsurface Scale', 0.004)
    _set_input(bsdf, 'Specular IOR Level', 0.5)
    material.diffuse_color = (*farbe, 1.0)
    for obj in _objs(objekte):
        if obj.type != 'MESH':
            continue
        obj.data.materials.clear()
        obj.data.materials.append(material)
    return material.name


def _cyclorama(width, depth, height, radius, name):
    """An L-shaped backdrop with a rounded bend: floor along -Y, wall at +Y."""
    profile = [(y, 0.0) for y in np.linspace(-depth, depth - radius, 6)]
    for a in np.linspace(0, math.pi / 2, 10)[1:]:
        profile.append((depth - radius + radius * math.sin(a), radius - radius * math.cos(a)))
    profile += [(depth, z) for z in np.linspace(radius, height, 5)[1:]]
    xs = (-width / 2, width / 2)
    verts = [(x, y, z) for y, z in profile for x in xs]
    faces = [(2 * i, 2 * i + 1, 2 * i + 3, 2 * i + 2) for i in range(len(profile) - 1)]
    mesh = bpy.data.meshes.new(name)
    mesh.from_pydata(verts, [], faces)
    mesh.update()
    for poly in mesh.polygons:
        poly.use_smooth = True
    return mesh


def studio_licht(ziel=None, hintergrund=(0.32, 0.32, 0.34), staerke=1.0, boden=True, kamera=True, brennweite=70):
    """Soft three-point studio light (key, fill, rim) around `ziel` (object name/list, default: all meshes),
    a seamless backdrop and a 3/4 front camera. Running it again replaces the earlier setup."""
    targets = [o for o in _objs(ziel) if not o.name.startswith('Studio-')]
    if not targets:
        raise ValueError('Kein Ziel-Objekt für das Studiolicht.')
    bpy.context.view_layer.update()
    corners = [c for o in targets for c in _height(o)[2]]
    low = mathutils.Vector((min(c.x for c in corners), min(c.y for c in corners), min(c.z for c in corners)))
    high = mathutils.Vector((max(c.x for c in corners), max(c.y for c in corners), max(c.z for c in corners)))
    center = (low + high) / 2
    size = max((high - low).length, 0.1)
    collection = bpy.data.collections.get('Studio')
    if collection is None:
        collection = bpy.data.collections.new('Studio')
        bpy.context.scene.collection.children.link(collection)
    for obj in list(collection.objects):
        bpy.data.objects.remove(obj, do_unlink=True)

    def add_light(name, offset, energy, light_size, color=(1, 1, 1)):
        light = bpy.data.lights.new(name, 'AREA')
        light.shape = 'DISK'
        light.size = light_size * size
        light.energy = energy * staerke * size * size * 60
        light.color = color
        obj = bpy.data.objects.new(name, light)
        collection.objects.link(obj)
        obj.location = center + mathutils.Vector(offset) * size
        direction = center - obj.location
        obj.rotation_euler = direction.to_track_quat('-Z', 'Y').to_euler()
        return obj

    # energies scale with the squared distance, so the exposure is the same for a figurine or a statue
    add_light('Studio-Hauptlicht', (-0.9, -1.1, 0.9), 3.0, 0.8, (1.0, 0.97, 0.93))
    add_light('Studio-Fuelllicht', (1.2, -0.9, 0.2), 0.8, 1.2, (0.93, 0.96, 1.0))
    add_light('Studio-Kante', (0.4, 1.3, 1.1), 2.5, 0.5)
    if boden:
        mesh = _cyclorama(size * 12, size * 3, size * 3, size * 0.8, 'Studio-Hintergrund')
        backdrop = bpy.data.objects.new('Studio-Hintergrund', mesh)
        collection.objects.link(backdrop)
        backdrop.location = (center.x, center.y, low.z)
        mat = bpy.data.materials.get('Studio-Hintergrund') or bpy.data.materials.new('Studio-Hintergrund')
        mat.use_nodes = True
        bsdf = next(n for n in mat.node_tree.nodes if n.type == 'BSDF_PRINCIPLED')
        _set_input(bsdf, 'Base Color', (*hintergrund, 1.0))
        _set_input(bsdf, 'Roughness', 0.9)
        mat.diffuse_color = (*hintergrund, 1.0)
        mesh.materials.append(mat)
    world = bpy.context.scene.world or bpy.data.worlds.new('Welt')
    bpy.context.scene.world = world
    world.use_nodes = True
    background = next((n for n in world.node_tree.nodes if n.type == 'BACKGROUND'), None)
    if background is not None:
        background.inputs['Color'].default_value = (*[c * 0.15 for c in hintergrund], 1.0)
        background.inputs['Strength'].default_value = 1.0
    camera_name = None
    if kamera:
        cam = bpy.data.cameras.new('Studio-Kamera')
        cam.lens = brennweite
        cam_obj = bpy.data.objects.new('Studio-Kamera', cam)
        collection.objects.link(cam_obj)
        height = high.z - low.z
        render = bpy.context.scene.render
        aspect = (render.resolution_x * render.pixel_aspect_x) / max(render.resolution_y * render.pixel_aspect_y, 1)
        sensor_w = 36.0 if aspect >= 1 else 36.0 * aspect
        sensor_h = sensor_w / aspect
        width = max(high.x - low.x, high.y - low.y)
        distance = max(height / sensor_h, width / sensor_w) * brennweite * 1.15
        cam.sensor_fit = 'AUTO'
        look_at = center.copy()
        cam_obj.location = look_at + mathutils.Vector((0.45, -1.0, 0.12)).normalized() * distance
        cam_obj.rotation_euler = (look_at - cam_obj.location).to_track_quat('-Z', 'Y').to_euler()
        bpy.context.scene.camera = cam_obj
        camera_name = cam_obj.name
    return {'lichter': ['Studio-Hauptlicht', 'Studio-Fuelllicht', 'Studio-Kante'],
            'hintergrund': 'Studio-Hintergrund' if boden else None, 'kamera': camera_name}


# ------------------------------------------------------------------ scans / AI meshes
def scan_aufraeumen(objekt, verschmelzen=1e-5, min_anteil=0.002, glaetten=0, glatt_faktor=0.5, normalen=True,
                    loecher_fuellen=0):
    """Clean an AI/scan mesh in place: merge duplicate vertices, drop loose bits smaller than min_anteil of all
    vertices, recalculate normals, optional smoothing passes and filling of holes with at most loecher_fuellen
    edges. Returns counts before/after."""
    import bmesh  # noqa: PLC0415
    from scipy.sparse import coo_matrix  # noqa: PLC0415
    from scipy.sparse.csgraph import connected_components  # noqa: PLC0415
    obj = _obj(objekt)
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    before = len(bm.verts)
    if verschmelzen:
        bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=verschmelzen)
    bm.verts.index_update()
    bm.verts.ensure_lookup_table()
    edges = np.array([(e.verts[0].index, e.verts[1].index) for e in bm.edges], np.int64).reshape(-1, 2)
    n = len(bm.verts)
    removed_parts = 0
    if n and len(edges):
        graph = coo_matrix((np.ones(len(edges)), (edges[:, 0], edges[:, 1])), shape=(n, n))
        count, labels = connected_components(graph, directed=False)
        sizes = np.bincount(labels, minlength=count)
        small = sizes < max(1, int(min_anteil * n))
        if small.any() and not small.all():
            doomed = [bm.verts[i] for i in np.nonzero(small[labels])[0]]
            bmesh.ops.delete(bm, geom=doomed, context='VERTS')
            removed_parts = int(small.sum())
    if loecher_fuellen:
        bmesh.ops.holes_fill(bm, edges=bm.edges, sides=int(loecher_fuellen))
    if normalen:
        bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    for _ in range(int(glaetten)):
        bmesh.ops.smooth_vert(bm, verts=bm.verts, factor=glatt_faktor, use_axis_x=True, use_axis_y=True, use_axis_z=True)
    after = len(bm.verts)
    bm.to_mesh(obj.data)
    bm.free()
    obj.data.update()
    return {'punkte_vorher': before, 'punkte_nachher': after, 'teile_entfernt': removed_parts}


def abgleichen(rig, ziel, koerper=None):
    """Roughly fit an MPFB figure (scale and position of its rig) to a scan in the same A-pose:
    same height, feet on the same floor, same centre in X/Y. Returns the scale factor."""
    armature, target = _obj(rig), _obj(ziel)
    body = _obj(koerper) if koerper else next((c for c in armature.children if c.type == 'MESH'), None)
    if body is None:
        raise ValueError('Kein Körper-Mesh unter dem Rig gefunden; koerper= angeben.')
    bpy.context.view_layer.update()
    t_low, t_high, t_corners = _height(target)
    b_low, b_high, _ = _height(body)
    factor = (t_high - t_low) / max(b_high - b_low, 1e-6)
    armature.scale = [s * factor for s in armature.scale]
    bpy.context.view_layer.update()
    b_co, _, _ = _mesh_arrays(body, evaluated=True)
    t_co, _, _ = _mesh_arrays(target)
    # bounding-box centres, not medians: vertex density differs (MPFB packs the face with points)
    t_mid, b_mid = (t_co.min(0) + t_co.max(0)) / 2, (b_co.min(0) + b_co.max(0)) / 2
    shift = np.array([t_mid[0] - b_mid[0], t_mid[1] - b_mid[1], t_co[:, 2].min() - b_co[:, 2].min()])
    armature.location = armature.location + mathutils.Vector(shift.tolist())
    bpy.context.view_layer.update()
    return round(factor, 4)


# ------------------------------------------------------------------ weights
def _barycentric(points, a, b, c):
    v0, v1, v2 = b - a, c - a, points - a
    d00 = (v0 * v0).sum(1); d01 = (v0 * v1).sum(1); d11 = (v1 * v1).sum(1)
    d20 = (v2 * v0).sum(1); d21 = (v2 * v1).sum(1)
    denom = np.where(np.abs(d00 * d11 - d01 * d01) < 1e-20, 1e-20, d00 * d11 - d01 * d01)
    v = (d11 * d20 - d01 * d21) / denom
    w = (d00 * d21 - d01 * d20) / denom
    bary = np.stack([1 - v - w, v, w], 1).clip(0, 1)
    return bary / np.maximum(bary.sum(1, keepdims=True), 1e-12)


def _bone_columns(armature, body, face, toes):
    """Deform bones that carry weights on the body, with face/toe bones folded into head/foot."""
    bones = armature.data.bones
    def fold(name):
        if not face and name != 'head' and _has_ancestor(bones[name], 'head'):
            return 'head'
        if not toes and name.startswith('toe') and name[-2:] in ('.L', '.R'):
            return f'foot{name[-2:]}'
        return name
    mapping = {}
    for group in body.vertex_groups:
        bone = bones.get(group.name)
        if bone is None or not bone.use_deform:
            continue
        mapping[group.index] = fold(group.name)
    columns = sorted(set(mapping.values()))
    return mapping, columns


def _has_ancestor(bone, name):
    parent = bone.parent
    while parent is not None:
        if parent.name == name:
            return True
        parent = parent.parent
    return False


def _transfer(src_co, src_tris, src_nor_face, weights, tgt_co, tgt_tris, tgt_nor, distance, angle, influences, smooth):
    """Robust skin weight transfer (Abdrashitov et al., SIGGRAPH Asia 2023): copy weights where the target is
    close to and aligned with the source surface, inpaint the rest by a biharmonic solve, smooth, limit influences."""
    import robust_laplacian  # noqa: PLC0415
    from scipy.sparse import diags, identity  # noqa: PLC0415
    from scipy.sparse.csgraph import connected_components  # noqa: PLC0415
    from scipy.sparse.linalg import splu  # noqa: PLC0415
    tree = BVHTree.FromPolygons(src_co.tolist(), src_tris.tolist(), all_triangles=True)
    n = len(tgt_co)
    tri_index = np.zeros(n, np.int64)
    nearest = np.zeros((n, 3))
    for i, point in enumerate(tgt_co):
        location, _normal, index, _dist = tree.find_nearest(mathutils.Vector(point))
        nearest[i] = location
        tri_index[i] = index
    corners = src_tris[tri_index]
    bary = _barycentric(nearest, src_co[corners[:, 0]], src_co[corners[:, 1]], src_co[corners[:, 2]])
    copied = (weights[corners] * bary[:, :, None]).sum(1)
    gap = np.linalg.norm(tgt_co - nearest, axis=1)
    alignment = np.abs((src_nor_face[tri_index] * tgt_nor).sum(1))
    known = (gap <= distance) & (alignment >= math.cos(math.radians(angle)))
    L, M = robust_laplacian.mesh_laplacian(np.asarray(tgt_co, np.float64), np.asarray(tgt_tris, np.int64))
    L = L.tocsr()
    # parts of the target without any matched vertex cannot be inpainted: give them their nearest weights
    _count, labels = connected_components(L, directed=False)
    has_known = np.bincount(labels, weights=known.astype(float)) > 0
    known |= ~has_known[labels]
    result = copied.copy()
    unknown = np.nonzero(~known)[0]
    if len(unknown):
        mass = np.maximum(M.diagonal(), 1e-12)
        Q = (L @ diags(1.0 / mass) @ L).tocsr()
        known_idx = np.nonzero(known)[0]
        A = Q[unknown][:, unknown] + identity(len(unknown)) * 1e-10 * float(np.abs(Q.diagonal()).mean())
        B = -(Q[unknown][:, known_idx] @ copied[known_idx])
        result[unknown] = splu(A.tocsc()).solve(np.asarray(B))
        if smooth:
            adjacency = (L != 0).astype(float)
            adjacency.setdiag(0)
            degree = np.maximum(np.asarray(adjacency.sum(1)).ravel(), 1)
            for _ in range(int(smooth)):
                result[unknown] = (adjacency[unknown] @ result) / degree[unknown, None]
    result = result.clip(0, None)
    if influences and result.shape[1] > influences:
        cut = np.argpartition(-result, influences - 1, axis=1)[:, influences:]
        np.put_along_axis(result, cut, 0.0, axis=1)
    total = result.sum(1, keepdims=True)
    empty = total[:, 0] <= 1e-9
    result[empty] = copied[empty]
    result /= np.maximum(result.sum(1, keepdims=True), 1e-12)
    return result.astype(np.float32), int(known.sum()), int(len(unknown))


def _nearest_skin(src_co, src_tris, weights, tgt_co, influences):
    """Weights straight from the nearest point on the skin: barycentric mix of that triangle's three vertices.
    No inpainting/smoothing – on dense meshes it stays as calm as the skin itself (garments don't tear)."""
    tree = BVHTree.FromPolygons(src_co.tolist(), src_tris.tolist(), all_triangles=True)
    n = len(tgt_co)
    tri_index = np.zeros(n, np.int64)
    nearest = np.zeros((n, 3))
    for i, point in enumerate(tgt_co):
        location, _normal, index, _dist = tree.find_nearest(mathutils.Vector(point))
        if location is None:
            location, index = point, 0
        nearest[i] = location
        tri_index[i] = index
    corners = src_tris[tri_index]
    a, b, c = src_co[corners[:, 0]], src_co[corners[:, 1]], src_co[corners[:, 2]]
    v0, v1, v2 = b - a, c - a, nearest - a
    d00 = np.einsum('ij,ij->i', v0, v0); d01 = np.einsum('ij,ij->i', v0, v1); d11 = np.einsum('ij,ij->i', v1, v1)
    d20 = np.einsum('ij,ij->i', v2, v0); d21 = np.einsum('ij,ij->i', v2, v1)
    denom = np.where(np.abs(d00 * d11 - d01 * d01) < 1e-20, 1e-20, d00 * d11 - d01 * d01)
    v = np.clip((d11 * d20 - d01 * d21) / denom, 0, 1)
    w = np.clip((d00 * d21 - d01 * d20) / denom, 0, 1)
    u = np.clip(1 - v - w, 0, 1)
    bary = np.stack([u, v, w], 1)
    bary /= np.maximum(bary.sum(1, keepdims=True), 1e-12)
    result = (weights[corners] * bary[:, :, None]).sum(1)
    if influences and result.shape[1] > influences:
        cut = np.argsort(result, axis=1)[:, :-influences]
        np.put_along_axis(result, cut, 0, axis=1)
    result /= np.maximum(result.sum(1, keepdims=True), 1e-12)
    distance = np.linalg.norm(tgt_co - nearest, axis=1)
    return result.astype(np.float32), distance


def _write_groups(obj, columns, weights):
    for name in columns:
        if name in obj.vertex_groups:
            obj.vertex_groups.remove(obj.vertex_groups[name])
    for j, name in enumerate(columns):
        idx = np.nonzero(weights[:, j] > 1e-4)[0]
        if not len(idx):
            continue
        group = obj.vertex_groups.new(name=name)
        # one add() per distinct weight (1/2000 steps) instead of one per point: millions of points in seconds
        steps = np.round(weights[idx, j] * 2000).astype(np.int32)
        order = np.argsort(steps, kind='stable')
        steps, idx = steps[order], idx[order]
        cuts = np.flatnonzero(np.diff(steps)) + 1
        for chunk, value in zip(np.split(idx, cuts), steps[np.r_[0, cuts]]):
            if value > 0:
                group.add(chunk.tolist(), float(value) / 2000, 'REPLACE')


def gewichte_uebertragen(quelle, ziel, rig, abstand=0.03, winkel=35, max_einfluss=4, glaetten=3, gesicht=False,
                         zehen=False, grenze=300000, modus='robust'):
    """Skin a scan/AI mesh (`ziel`) to `rig` by robust weight transfer from a rigged body (`quelle`, e.g. the MPFB
    figure after figur.abgleichen). Both in the same A-pose. abstand in metres: closer target points copy the weights,
    the rest is filled smoothly (biharmonic inpainting). Meshes above `grenze` vertices are solved on a decimated
    copy and transferred back. Adds an Armature modifier and parents the target to the rig.
    modus='naechster': every point takes the weights of the nearest skin point (barycentric, no inpainting, no proxy) –
    calmer on dense meshes and for garments close to the skin (standard in kleid_anlegen); 'robust' = the method above,
    better for scans whose shape differs a lot from the body (open hands, hair)."""
    if modus not in ('robust', 'naechster'):
        raise ValueError("modus: 'robust' oder 'naechster'.")
    source, target, armature = _obj(quelle), _obj(ziel), _obj(rig)
    bpy.context.view_layer.update()
    mapping, columns = _bone_columns(armature, source, gesicht, zehen)
    if not columns:
        raise ValueError(f'{source.name} hat keine Knochen-Gewichte von {armature.name}.')
    col_of = {name: j for j, name in enumerate(columns)}
    helper_idx = {source.vertex_groups[g].index for g in HELPER_GROUPS if g in source.vertex_groups}
    n_src = len(source.data.vertices)
    weights = np.zeros((n_src, len(columns)), np.float32)
    helper = np.zeros(n_src, bool)
    for vertex in source.data.vertices:
        for element in vertex.groups:
            if element.group in helper_idx and element.weight > 0.5:
                helper[vertex.index] = True
            name = mapping.get(element.group)
            if name is not None:
                weights[vertex.index, col_of[name]] += element.weight
    weights /= np.maximum(weights.sum(1, keepdims=True), 1e-12)
    # shape with shape keys (MPFB body targets) but without modifiers, so vertex ids match the weights
    saved = [(m, m.show_viewport) for m in source.modifiers]
    for m, _ in saved:
        m.show_viewport = False
    try:
        bpy.context.view_layer.update()
        src_co, src_tris, _ = _mesh_arrays(source, evaluated=True)
    finally:
        for m, state in saved:
            m.show_viewport = state
        bpy.context.view_layer.update()
    if len(src_co) != n_src:
        raise RuntimeError('Quelle hat ausgewertet eine andere Punktzahl – Modifier, die Punkte ändern, vorher entfernen.')
    src_tris = src_tris[~helper[src_tris].any(1)]
    a, b, c = src_co[src_tris[:, 0]], src_co[src_tris[:, 1]], src_co[src_tris[:, 2]]
    face_nor = np.cross(b - a, c - a)
    face_nor /= np.maximum(np.linalg.norm(face_nor, axis=1, keepdims=True), 1e-12)

    work = target
    proxy = None
    if modus == 'naechster':
        tgt_co, _, _ = _mesh_arrays(target)
        result, distance = _nearest_skin(src_co, src_tris, weights, tgt_co, max_einfluss)
        _write_groups(target, columns, result)
        for mod in [m for m in target.modifiers if m.type == 'ARMATURE']:
            target.modifiers.remove(mod)
        arm_mod = target.modifiers.new('Armature', 'ARMATURE')
        arm_mod.object = armature
        world = target.matrix_world.copy()
        target.parent = armature
        target.matrix_parent_inverse = armature.matrix_world.inverted()
        target.matrix_world = world
        return {'knochen': len(columns), 'punkte': len(tgt_co), 'modus': 'naechster',
                'abstand_mm_mittel': round(float(distance.mean()) * 1000, 1),
                'abstand_mm_max': round(float(distance.max()) * 1000, 1),
                'weit_weg': int((distance > abstand).sum()),
                **({'hinweis': f'{int((distance > abstand).sum())} Punkte liegen weiter als {abstand} m von der Haut – dort '
                               "ggf. modus='robust' nehmen."} if (distance > abstand).any() else {})}
    if len(target.data.vertices) > grenze:
        proxy = target.copy()
        proxy.data = target.data.copy()
        proxy.name = f'{target.name}-gewichte-proxy'
        proxy.modifiers.clear()
        _link(proxy, target)
        dec = proxy.modifiers.new('Dezimieren', 'DECIMATE')
        dec.ratio = grenze / len(target.data.vertices)
        bpy.context.view_layer.update()
        reduced = bpy.data.meshes.new_from_object(proxy.evaluated_get(bpy.context.evaluated_depsgraph_get()))
        old = proxy.data
        proxy.modifiers.clear()
        proxy.data = reduced
        bpy.data.meshes.remove(old)
        work = proxy
    tgt_co, tgt_tris, tgt_nor = _mesh_arrays(work)
    result, matched, filled = _transfer(src_co, src_tris, face_nor, weights, tgt_co, tgt_tris, tgt_nor,
                                        abstand, winkel, max_einfluss, glaetten)
    _write_groups(work, columns, result)
    if proxy is not None:
        for name in columns:
            if name in target.vertex_groups:
                target.vertex_groups.remove(target.vertex_groups[name])
            if name in proxy.vertex_groups:
                target.vertex_groups.new(name=name)
        mod = target.modifiers.new('Gewichte', 'DATA_TRANSFER')
        mod.object = proxy
        mod.use_vert_data = True
        mod.data_types_verts = {'VGROUP_WEIGHTS'}
        mod.vert_mapping = 'POLYINTERP_NEAREST'
        mod.layers_vgroup_select_src = 'ALL'
        mod.layers_vgroup_select_dst = 'NAME'
        while target.modifiers[0] != mod:
            target.modifiers.move(target.modifiers.find(mod.name), 0)
        with bpy.context.temp_override(object=target, active_object=target, selected_objects=[target]):
            bpy.ops.object.modifier_apply(modifier=mod.name)
        bpy.data.objects.remove(proxy, do_unlink=True)
    for mod in [m for m in target.modifiers if m.type == 'ARMATURE']:
        target.modifiers.remove(mod)
    arm_mod = target.modifiers.new('Armature', 'ARMATURE')
    arm_mod.object = armature
    world = target.matrix_world.copy()
    target.parent = armature
    target.matrix_parent_inverse = armature.matrix_world.inverted()
    target.matrix_world = world
    return {'knochen': len(columns), 'punkte': len(tgt_co), 'kopiert': matched, 'aufgefuellt': filled,
            'ueber_proxy': proxy is not None}


# ------------------------------------------------------------------ posing
def ik(rig, knochen, kette=2, ziel=None, pol=None, name=None):
    """IK on `knochen` (its tail follows an empty). ziel/pol: world points or None (current tail / no pole).
    Returns the empty names; move them (location) to pose."""
    armature = _obj(rig)
    bpy.context.view_layer.update()
    pose_bone = armature.pose.bones[knochen]
    target = bpy.data.objects.new(name or f'IK-{knochen}', None)
    target.empty_display_type = 'SPHERE'
    target.empty_display_size = 0.03
    _link(target, armature)
    target.location = ziel if ziel is not None else armature.matrix_world @ pose_bone.tail
    for old in [c for c in pose_bone.constraints if c.type == 'IK']:
        pose_bone.constraints.remove(old)
    constraint = pose_bone.constraints.new('IK')
    constraint.target = target
    constraint.chain_count = kette
    names = {'ziel': target.name}
    if pol is not None:
        pole = bpy.data.objects.new(f'{target.name}-pol', None)
        pole.empty_display_size = 0.03
        _link(pole, armature)
        pole.location = pol
        constraint.pole_target = pole
        constraint.pole_angle = -math.pi / 2
        names['pol'] = pole.name
    return names


def arm_ik(rig, seite='L', ziel=None):
    """IK for a whole MPFB arm: the empty places the wrist; the elbow pole sits behind the arm."""
    armature = _obj(rig)
    bpy.context.view_layer.update()
    elbow = armature.matrix_world @ armature.pose.bones[f'lowerarm01.{seite}'].head
    return ik(armature, f'lowerarm02.{seite}', kette=4, ziel=ziel, pol=elbow + mathutils.Vector((0, 0.4, 0)),
              name=f'IK-Hand.{seite}')


def bein_ik(rig, seite='L', ziel=None):
    """IK for a whole MPFB leg: the empty places the ankle; the knee pole sits in front."""
    armature = _obj(rig)
    bpy.context.view_layer.update()
    knee = armature.matrix_world @ armature.pose.bones[f'lowerleg01.{seite}'].head
    return ik(armature, f'lowerleg02.{seite}', kette=4, ziel=ziel, pol=knee + mathutils.Vector((0, -0.4, 0)),
              name=f'IK-Fuss.{seite}')


def pose_zuruecksetzen(rig):
    """Back to the rest pose (A-pose); removes IK constraints and their empties."""
    armature = _obj(rig)
    for pose_bone in armature.pose.bones:
        for constraint in [c for c in pose_bone.constraints if c.type == 'IK']:
            for helper in (constraint.target, constraint.pole_target):
                if helper is not None and helper.type == 'EMPTY':
                    bpy.data.objects.remove(helper, do_unlink=True)
            pose_bone.constraints.remove(constraint)
        pose_bone.location = (0, 0, 0)
        pose_bone.rotation_quaternion = (1, 0, 0, 0)
        pose_bone.rotation_euler = (0, 0, 0)
        pose_bone.scale = (1, 1, 1)
    bpy.context.view_layer.update()


def _rotation(pose_bone):
    if pose_bone.rotation_mode == 'QUATERNION':
        return pose_bone.rotation_quaternion.to_matrix().to_4x4()
    if pose_bone.rotation_mode == 'AXIS_ANGLE':
        angle, *axis = pose_bone.rotation_axis_angle
        return mathutils.Matrix.Rotation(angle, 4, mathutils.Vector(axis))
    return pose_bone.rotation_euler.to_matrix().to_4x4()


def _chain_points(armature, chain, extra, samples=4):
    """World points along the chain for local rotation offsets `extra` (list of matrices), by plain forward
    kinematics from the parent's current pose (fingers have no constraints)."""
    world = armature.matrix_world
    parent = chain[0].parent
    matrix = parent.matrix.copy() if parent is not None else mathutils.Matrix()
    rest_parent = parent.bone.matrix_local if parent is not None else mathutils.Matrix()
    points = []
    for pose_bone, offset in zip(chain, extra):
        rest = pose_bone.bone.matrix_local
        basis = mathutils.Matrix.Translation(pose_bone.location) @ _rotation(pose_bone) @ offset
        matrix = matrix @ (rest_parent.inverted() @ rest) @ basis
        rest_parent = rest
        length = pose_bone.bone.length
        for t in np.linspace(0.25, 1.0, samples):
            points.append(world @ (matrix @ mathutils.Vector((0, length * t, 0))))
    return points


def _clearance(tree, points, thickness, first=0):
    """Smallest (distance to surface − finger thickness); negative = touching/penetrating, inside counts negative."""
    best = math.inf
    for point in points[first:]:
        location, normal, _index, distance = tree.find_nearest(point)
        if location is None:
            continue
        if normal is not None and (point - location).dot(normal) < 0:
            distance = -distance
        best = min(best, distance - thickness)
    return best


def handflaeche(rig, seite='L'):
    """World normal of the palm (pointing out of the palm, where a held object sits) and the palm centre."""
    armature = _obj(rig)
    bpy.context.view_layer.update()
    pb, mw = armature.pose.bones, armature.matrix_world
    wrist = mw @ pb[f'wrist.{seite}'].head
    index, pinky = mw @ pb[f'finger2-1.{seite}'].head, mw @ pb[f'finger5-1.{seite}'].head
    normal = (index - wrist).cross(pinky - wrist).normalized()
    # the fingers rest slightly curled: they bend towards the palm side
    bend = mathutils.Vector()
    for f in (2, 3, 4, 5):
        first, last = pb[f'finger{f}-1.{seite}'], pb[f'finger{f}-3.{seite}']
        d1 = (mw.to_3x3() @ (first.tail - first.head)).normalized()
        d3 = (mw.to_3x3() @ (last.tail - last.head)).normalized()
        bend += d3 - d1 * d1.dot(d3)
    if bend.length > 1e-3:
        if bend.dot(normal) < 0:
            normal = -normal
    else:
        thumb = mw @ pb[f'finger1-3.{seite}'].tail
        if (thumb - wrist).dot(normal) < 0:
            normal = -normal
    return normal, (wrist + index + pinky) / 3


def objekt_in_hand(objekt, rig, seite='L', haut=None, versatz=0.0):
    """Put an object into the palm the way a phone or book is held: its thinnest side against the palm
    (`haut` = bone-to-skin distance), its longest side across the hand (index to little finger), the middle side
    along the fingers so they can wrap over the far edge. versatz shifts it along the fingers (m).
    Then call hand_greifen. Returns the palm normal."""
    prop, armature = _obj(objekt), _obj(rig)
    normal, centre = handflaeche(armature, seite)
    pb, mw = armature.pose.bones, armature.matrix_world
    index, pinky = mw @ pb[f'finger2-1.{seite}'].head, mw @ pb[f'finger5-1.{seite}'].head
    wrist = mw @ pb[f'wrist.{seite}'].head
    across = (pinky - index)
    across = (across - normal * across.dot(normal)).normalized()
    along = normal.cross(across).normalized()
    if along.dot((index + pinky) / 2 - wrist) < 0:
        along = -along
    if prop.parent is not None:
        world = prop.matrix_world.copy()
        prop.parent = None
        prop.matrix_world = world
    dims = list(prop.dimensions)
    order = sorted(range(3), key=lambda k: dims[k])          # thin, middle, long
    targets = {order[0]: normal, order[1]: along, order[2]: across}
    columns = [targets[k] for k in range(3)]
    rotation = mathutils.Matrix(columns).transposed()
    if rotation.determinant() < 0:
        columns[order[2]] = -columns[order[2]]
        rotation = mathutils.Matrix(columns).transposed()
    scale = armature.matrix_world.to_scale()[2]
    skin = haut if haut is not None else 0.012 * scale
    prop.rotation_mode = 'QUATERNION'
    prop.rotation_quaternion = rotation.to_quaternion()
    bpy.context.view_layer.update()
    # centre of the bounding box may not be the origin: move so the box centre sits where we want it
    box = [prop.matrix_world @ mathutils.Vector(c) for c in prop.bound_box]
    box_centre = sum(box, mathutils.Vector()) / 8
    want = centre + normal * (skin + dims[order[0]] / 2) + along * versatz
    prop.location = prop.location + (want - box_centre)
    bpy.context.view_layer.update()
    return [round(v, 3) for v in normal]


def hand_greifen(rig, objekt, seite='L', finger=(1, 2, 3, 4, 5), dicke=None, abstand=0.001, max_winkel=100,
                 schritt=2.0, oeffnen=25.0, handflaeche_normale=None):
    """Curl the fingers of an MPFB hand around `objekt` until they touch it (place the hand first, e.g. with
    arm_ik; figur.handflaeche gives the palm normal and centre for placing the object). Each joint bends towards
    the palm in small steps until the finger surface (bone + `dicke`) is `abstand` from the object. The fingers
    first open by up to `oeffnen` degrees per joint (resting MPFB fingers are slightly curled).
    Returns per finger the bend angles and the final gap in mm (negative = inside the object)."""
    armature, prop = _obj(rig), _obj(objekt)
    bpy.context.view_layer.update()
    tree = _bvh(prop)
    scale = armature.matrix_world.to_scale()[2]
    thickness = dicke if dicke is not None else 0.0075 * scale
    if handflaeche_normale is not None:
        palm = mathutils.Vector(handflaeche_normale).normalized()
    else:
        palm = handflaeche(armature, seite)[0]
    mw = armature.matrix_world
    report = {'handflaeche': [round(v, 3) for v in palm]}
    for f in finger:
        chain = [armature.pose.bones.get(f'finger{f}-{i}.{seite}') for i in (1, 2, 3)]
        if any(b is None for b in chain):
            report[f'finger{f}'] = 'Knochen fehlen'
            continue
        identity = [mathutils.Matrix() for _ in chain]
        axes = []
        for pose_bone in chain:
            world = (mw @ pose_bone.matrix).to_3x3()
            direction = (world @ mathutils.Vector((0, 1, 0))).normalized()
            axis_world = direction.cross(palm)
            if axis_world.length < 1e-6:
                axis_world = world @ mathutils.Vector((1, 0, 0))
            axes.append((world.inverted() @ axis_world).normalized())
        opened = 0.0
        limit = oeffnen * (2.4 if f == 1 else 1.0)     # the thumb rests across the palm and needs more room
        while opened < limit:                      # open until the finger is clear of the object
            trial = [mathutils.Matrix.Rotation(math.radians(-opened), 4, a) for a in axes]
            if _clearance(tree, _chain_points(armature, chain, trial), thickness) >= abstand + 0.002:
                break
            opened += schritt
        angles = [-opened] * 3
        offsets = [mathutils.Matrix.Rotation(math.radians(-opened), 4, a) for a in axes]
        if _clearance(tree, _chain_points(armature, chain, offsets), thickness) < abstand:
            report[f'finger{f}'] = {'winkel': [0, 0, 0], 'abstand_mm': round(_clearance(tree, _chain_points(armature, chain, identity), thickness) * 1000, 1),
                                    'hinweis': 'steckt im Objekt, auch geöffnet – Hand oder Objekt verschieben'}
            continue
        for j in range(3):
            while angles[j] + schritt <= max_winkel:
                trial = list(offsets)
                trial[j] = mathutils.Matrix.Rotation(math.radians(angles[j] + schritt), 4, axes[j])
                # only the phalanges that move with this joint can newly touch
                gap = _clearance(tree, _chain_points(armature, chain, trial), thickness, first=4 * j)
                if gap < abstand:
                    break
                offsets, angles[j] = trial, angles[j] + schritt
        for pose_bone, offset in zip(chain, offsets):
            pose_bone.rotation_mode = 'QUATERNION'
            pose_bone.rotation_quaternion = (_rotation(pose_bone) @ offset).to_quaternion()
        bpy.context.view_layer.update()
        final = _clearance(tree, _chain_points(armature, chain, identity), thickness)
        entry = {'winkel': angles, 'abstand_mm': round(final * 1000, 1)}
        if final > 0.01:
            entry['hinweis'] = 'Objekt nicht erreicht (max_winkel oder Hand näher heran)'
        report[f'finger{f}'] = entry
    bpy.context.view_layer.update()
    return report


def _rounded_phone(name, width, length, thickness, corner):
    mesh = bpy.data.meshes.new(name)
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.scene.collection.objects.link(obj)
    import bmesh  # noqa: PLC0415
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0)
    for v in bm.verts:
        v.co = mathutils.Vector((v.co.x * width, v.co.y * length, v.co.z * thickness))
    bm.to_mesh(mesh)
    bm.free()
    bevel = obj.modifiers.new('Ecken', 'BEVEL')
    bevel.width = min(width, length) * corner
    bevel.segments = 6
    bevel.limit_method = 'ANGLE'
    rim = obj.modifiers.new('Kante', 'BEVEL')
    rim.width = thickness * 0.35
    rim.segments = 3
    with bpy.context.temp_override(object=obj, active_object=obj, selected_objects=[obj]):
        bpy.ops.object.modifier_apply(modifier=bevel.name)
        bpy.ops.object.modifier_apply(modifier=rim.name)
    return obj


def handy_griff(rig, seite='R', handy=None, haut=None, breite=0.0716, laenge=0.1476, dicke=0.0078, ecke=0.12,
                kante=-0.012, unten=0.012, luft=0.0008, knick=0.5, anhaengen_an=True):
    """Phone held upright in one hand (agent recipe griff_pose.py, 17.11.2026): back of the phone on the palm, the four
    fingers curl round the far long edge, the thumb rests on the near edge at screen height – no claw over the screen.
    Run after the arm pose. haut = the light skinned body mesh used for contact (default: the mesh with the fewest
    points that the rig deforms, e.g. MPFB 'Human'); heavy meshes are paused meanwhile. handy = existing object
    (its size is used, it is moved into place) or None (a rounded phone breite×laenge×dicke m is built).
    kante: far edge relative to the middle finger joints (negative = before them), unten: lower end below the little
    finger knuckle, knick: tip-joint share of the middle-joint bend. Returns curl angles, thumb pose and min. gap."""
    import itertools  # noqa: PLC0415
    armature = _obj(rig)
    side = seite.upper()
    if haut is None:
        candidates = [o for o in bpy.data.objects if o.type == 'MESH' and
                      any(m.type == 'ARMATURE' and m.object == armature for m in o.modifiers)]
        if not candidates:
            raise ValueError(f'Kein Mesh wird von {armature.name} verformt – haut=… angeben.')
        skin = min(candidates, key=lambda o: len(o.data.vertices))
    else:
        skin = _obj(haut)
    if handy is not None:
        phone = _obj(handy)
        d = sorted(phone.dimensions)
        dicke, breite, laenge = d[0], d[1], d[2]
    saved_skin = (skin.hide_viewport, [(m, m.show_viewport) for m in skin.modifiers])
    others = [(m, m.show_viewport) for o in bpy.data.objects if o.type == 'MESH' and o != skin for m in o.modifiers]
    skin.hide_viewport = False
    for m, _ in others:
        m.show_viewport = False          # heavy dress/body would re-deform on every finger step
    for m in skin.modifiers:
        if m.type != 'ARMATURE':
            m.show_viewport = False      # vertex ids stay those of the base mesh
    mwr, mwh = armature.matrix_world, np.array(skin.matrix_world)
    pbs = armature.pose.bones

    def rot(name, x=0.0, y=0.0, z=0.0):
        pb = pbs[name]
        pb.rotation_mode = 'XYZ'
        pb.rotation_euler = (math.radians(x), math.radians(y), math.radians(z))

    def verts():
        bpy.context.view_layer.update()
        ev = skin.evaluated_get(bpy.context.evaluated_depsgraph_get())
        me = ev.to_mesh()
        c = np.zeros(len(me.vertices) * 3, np.float32)
        me.vertices.foreach_get('co', c)
        ev.to_mesh_clear()
        return c.reshape(-1, 3).astype(np.float64) @ mwh[:3, :3].T + mwh[:3, 3]

    def head(name):
        bpy.context.view_layer.update()
        return np.array(mwr @ pbs[name].head)

    def tail(name):
        bpy.context.view_layer.update()
        return np.array(mwr @ pbs[name].tail)

    gi = {g.name: g.index for g in skin.vertex_groups}
    owner = np.zeros((len(skin.data.vertices), max(len(gi), 1)), np.float32)
    for v in skin.data.vertices:
        for g in v.groups:
            owner[v.index, g.group] = g.weight

    def grp(*names, t=0.4):
        cols = [gi[n] for n in names if n in gi]
        return owner[:, cols].sum(1) > t if cols else np.zeros(len(owner), bool)

    b = lambda name: f'{name}.{side}'  # noqa: E731
    try:
        fingers = (2, 3, 4, 5)
        for f in fingers:
            rot(b(f'finger{f}-1'), 10)
        wrist = head(b('wrist'))
        knuckles = {f: head(b(f'finger{f}-1')) for f in fingers}
        e1 = np.mean([knuckles[f] for f in fingers], 0) - wrist
        e1 /= np.linalg.norm(e1)
        e2 = knuckles[2] - knuckles[5]
        e2 -= np.dot(e2, e1) * e1
        e2 /= np.linalg.norm(e2)
        nrm = np.cross(e1, e2)
        t0 = tail(b('finger3-3'))
        rot(b('finger3-2'), 30)
        if np.dot(tail(b('finger3-3')) - t0, nrm) < 0:
            nrm = -nrm                    # palm side = where positive curls go
        for f in fingers:
            for j in (1, 2, 3):
                rot(b(f'finger{f}-{j}'))
        joints = {f: head(b(f'finger{f}-2')) for f in fingers}
        L = joints[2] - joints[5]
        L -= np.dot(L, nrm) * nrm
        L /= np.linalg.norm(L)
        Wd = np.cross(L, nrm)
        if np.dot(Wd, e1) < 0:
            Wd = -Wd
        X = np.cross(L, nrm)
        V = verts()
        hand_names = [n for n in gi if n.endswith('.' + side) and n.startswith(('finger', 'metacarpal', 'wrist'))]
        palm = grp(*hand_names) & ~grp(b('finger1-1'), b('finger1-2'), b('finger1-3'))
        u_far = np.mean([np.dot(joints[f] - wrist, Wd) for f in fingers]) + kante
        v_bot = np.dot(knuckles[5] - wrist, L) - unten
        uc, vc = u_far - breite / 2, v_bot + laenge / 2
        uu, vv, hh = (V - wrist) @ Wd, (V - wrist) @ L, (V - wrist) @ nrm
        under = palm & (np.abs(uu - uc) < breite / 2) & (np.abs(vv - vc) < laenge / 2)
        if not under.any():
            raise RuntimeError('Unter der Handyfläche liegt keine Handfläche – kante/unten anpassen oder Hand prüfen.')
        h_back = hh[under].max() + luft
        centre = wrist + uc * Wd + vc * L + (h_back + dicke / 2) * nrm
        R3 = np.column_stack([X, L, nrm])
        radius = dicke * 0.45
        half = np.array([breite / 2, laenge / 2, dicke / 2]) - radius

        def sdf(p):
            q = np.abs((p - centre) @ R3) - half
            return np.linalg.norm(np.maximum(q, 0), axis=1) + np.minimum(q.max(1), 0) - radius

        def curl_until(bone, mask, lo, hi, step):
            best = lo
            for angle in np.arange(lo, hi + 1e-6, step):
                rot(bone, angle)
                if sdf(verts()[mask]).min() < luft:
                    break
                best = angle
            rot(bone, best)
            return float(best)

        curls = {}
        for f in fingers:
            m1, m2, m3 = grp(b(f'finger{f}-1')), grp(b(f'finger{f}-2')), grp(b(f'finger{f}-3'))
            c1 = curl_until(b(f'finger{f}-1'), m1 | m2 | m3, 0, 80, 2)
            c2 = 0.0
            for angle in np.arange(0, 120, 2):
                rot(b(f'finger{f}-2'), angle)
                rot(b(f'finger{f}-3'), knick * angle)
                if sdf(verts()[m2 | m3]).min() < luft:
                    break
                c2 = float(angle)
            rot(b(f'finger{f}-2'), c2)
            rot(b(f'finger{f}-3'), knick * c2)
            c3 = curl_until(b(f'finger{f}-3'), m3, knick * c2, 90, 2)
            curls[f'finger{f}'] = [c1, c2, c3]
        mt = grp(b('finger1-1'), b('finger1-2'), b('finger1-3'))
        m23, mtip = grp(b('finger1-2'), b('finger1-3')), grp(b('finger1-3'))
        best = None
        for t1, tz, ty in itertools.product(range(-90, 91, 10), range(-90, 91, 10), (-45, -15, 15, 45)):
            rot(b('finger1-1'), t1, ty, tz)
            rot(b('finger1-2'))
            rot(b('finger1-3'))
            if sdf(verts()[mt]).min() < luft:
                continue
            for c2 in (0, 20, 40, 60):
                rot(b('finger1-2'), c2)
                if sdf(verts()[m23]).min() < luft:
                    break
                c3 = curl_until(b('finger1-3'), mtip, 0, 60, 10)
                tip = verts()[mtip]
                local = ((tip - centre) @ R3).mean(0)
                score = float(sdf(tip).min()) + 0.3 * abs(local[2] - dicke / 2) + 0.2 * max(0.0, -local[0])
                if best is None or score < best[0]:
                    best = (score, t1, tz, ty, c2, c3)
                rot(b('finger1-3'))
        if best is None:
            raise RuntimeError('Keine Daumenhaltung ohne Durchdringung gefunden – kante/unten anpassen.')
        rot(b('finger1-1'), best[1], best[3], best[2])
        rot(b('finger1-2'), best[4])
        rot(b('finger1-3'), best[5])
        V = verts()
        hand = grp(*hand_names, t=0.5)
        gap = float(sdf(V[hand]).min())
    finally:
        for m, state in saved_skin[1]:
            m.show_viewport = state
        skin.hide_viewport = saved_skin[0]
        for m, state in others:
            m.show_viewport = state
    if handy is None:
        old = bpy.data.objects.get('Handy')
        if old is not None:
            bpy.data.objects.remove(old, do_unlink=True)
        phone = _rounded_phone('Handy', breite, laenge, dicke, ecke)
    else:
        if phone.parent is not None:
            world = phone.matrix_world.copy()
            phone.parent = None
            phone.matrix_world = world
        dims = list(phone.dimensions)
        order = sorted(range(3), key=lambda k: dims[k])          # thin, middle (width), long
        axes = {order[1]: X, order[2]: L, order[0]: nrm}
        cols = [axes[k] for k in range(3)]
        rotation = np.column_stack(cols)
        if np.linalg.det(rotation) < 0:
            cols[order[1]] = -cols[order[1]]
            rotation = np.column_stack(cols)
        phone.matrix_world = mathutils.Matrix.Translation(mathutils.Vector(centre)) @ mathutils.Matrix(rotation.tolist()).to_4x4()
        bpy.context.view_layer.update()
        box = [phone.matrix_world @ mathutils.Vector(c) for c in phone.bound_box]
        phone.location = phone.location + (mathutils.Vector(centre) - sum(box, mathutils.Vector()) / 8)
    if handy is None:
        phone.matrix_world = mathutils.Matrix.Translation(mathutils.Vector(centre)) @ mathutils.Matrix(R3.tolist()).to_4x4()
    bpy.context.view_layer.update()
    if anhaengen_an:
        anhaengen(phone, armature, b('wrist'))
    return {'handy': phone.name, 'haut': skin.name, 'finger_winkel': curls,
            'daumen': {'wurzel_xyz': [best[1], best[3], best[2]], 'mitte': best[4], 'spitze': best[5]},
            'min_abstand_mm': round(gap * 1000, 2),
            'hinweis': 'Abstand < 0 = Hand steckt im Handy – unten/kante ändern.' if gap < 0 else 'ok'}


def anhaengen(objekt, rig, knochen):
    """Parent a prop to a bone so it follows the hand; keeps its current world placement."""
    prop, armature = _obj(objekt), _obj(rig)
    bpy.context.view_layer.update()
    world = prop.matrix_world.copy()
    prop.parent = armature
    prop.parent_type = 'BONE'
    prop.parent_bone = knochen
    bpy.context.view_layer.update()
    prop.matrix_world = world
    bpy.context.view_layer.update()
    return {'objekt': prop.name, 'knochen': knochen}


def aufstellen(objekte, boden=0.0):
    """Move objects so their lowest point stands on z = boden."""
    objs = _objs(objekte)
    bpy.context.view_layer.update()
    lowest = min(_height(o)[0] for o in objs)
    for obj in objs:
        if obj.parent is None or obj.parent not in objs:
            obj.location.z += boden - lowest
    bpy.context.view_layer.update()
    return round(boden - lowest, 4)


# ------------------------------------------------------------------ clothing
def _edges(mesh):
    edges = np.empty(len(mesh.edges) * 2, np.int32)
    mesh.edges.foreach_get('vertices', edges)
    return edges.reshape(-1, 2)


def _smooth_field(field, edges, n, steps, keep=None):
    """Average a per-vertex vector field over mesh neighbours (keep = vertices that do not change)."""
    if steps <= 0 or len(edges) == 0:
        return field
    degree = np.bincount(edges.ravel(), minlength=n).astype(np.float64)[:, None]
    for _ in range(steps):
        total = np.zeros_like(field)
        np.add.at(total, edges[:, 0], field[edges[:, 1]])
        np.add.at(total, edges[:, 1], field[edges[:, 0]])
        mean = np.where(degree > 0, total / np.maximum(degree, 1), field)
        new = 0.5 * field + 0.5 * mean
        if keep is not None:
            new[keep] = field[keep]
        field = new
    return field


def _nearest(tree, points):
    loc = np.empty_like(points)
    nor = np.empty_like(points)
    for i, p in enumerate(points):
        hit = tree.find_nearest(mathutils.Vector(p))
        if hit[0] is None:
            loc[i], nor[i] = p, (0, 0, 1)
        else:
            loc[i], nor[i] = hit[0], hit[1]
    signed = np.einsum('ij,ij->i', points - loc, nor)
    return loc, nor, signed


def kleid_anlegen(kleid, koerper, rig=None, abstand=0.004, anliegen=0.025, weich=0.04, straffheit=1.0, glaetten=12,
                  form_glaetten=6, frei=None, gewichte=True, gewichte_modus='naechster'):
    """Fit a garment to a body (same pose, garment without Armature modifier, ideally both in A-pose): parts within
    `anliegen` m of the skin are pulled to `abstand` m above it, softly fading out over `weich` m (skirts stay loose);
    everything inside the body is pushed out. form_glaetten first relaxes bumps/creases of the garment itself (open
    borders stay), the displacement is smoothed (no dents), then penetrations are fixed again. frei = vertex group of the garment that is only pushed out, never pulled in (e.g. a flowing skirt).
    With rig: weights are transferred from the body so the garment follows poses (+ Corrective Smooth); gewichte_modus
    'naechster' (default since 17.11.2026, from the nearest skin point – the robust inpainting made dense garments tear)
    or 'robust'.
    Returns numbers before/after (penetrating points, gap in the fitted zone)."""
    dress, body = _obj(kleid), _obj(koerper)
    if any(m.type == 'ARMATURE' for m in dress.modifiers):
        raise ValueError(f'{dress.name} hat schon einen Armature-Modifier – in der Ruhe-/A-Pose ohne ihn anlegen '
                         '(Modifier entfernen oder anwenden), danach überträgt kleid_anlegen die Gewichte neu.')
    if bpy.context.object is not None and bpy.context.object.mode != 'OBJECT':
        bpy.ops.object.mode_set(mode='OBJECT')
    bpy.context.view_layer.update()
    tree = _bvh(body)
    mesh = dress.data
    n = len(mesh.vertices)
    local = np.empty(n * 3, np.float64)
    mesh.vertices.foreach_get('co', local)
    local = local.reshape(-1, 3)
    mw = np.array(dress.matrix_world, np.float64)
    co = local @ mw[:3, :3].T + mw[:3, 3]
    edges = _edges(mesh)
    loc, nor, signed = _nearest(tree, co)
    before_signed = signed
    if form_glaetten:
        border = np.zeros(n, bool)
        loops = np.empty(len(mesh.loops), np.int32)
        mesh.loops.foreach_get('edge_index', loops)
        per_edge = np.bincount(loops, minlength=len(edges))
        border[edges[per_edge == 1].ravel()] = True
        co = _smooth_field(co, edges, n, int(form_glaetten), keep=border)
        loc, nor, signed = _nearest(tree, co)
    dist = np.abs(signed)
    inside = signed < abstand * 0.5
    before = {'durchstossend': int((before_signed < 0).sum()), 'zu_nah': int((before_signed < abstand * 0.5).sum())}
    zone = np.abs(before_signed) <= anliegen
    if zone.any():
        before['spalt_mm_mittel'] = round(float(np.mean(np.abs(before_signed[zone]))) * 1000, 2)
    weight = np.clip(1 - (dist - anliegen) / max(weich, 1e-6), 0, 1) * float(straffheit)
    if frei is not None:
        group = dress.vertex_groups.get(frei)
        if group is None:
            raise ValueError(f'Vertexgruppe „{frei}“ gibt es in {dress.name} nicht.')
        loose = np.zeros(n, bool)
        for v in mesh.vertices:
            if any(g.group == group.index and g.weight > 0.3 for g in v.groups):
                loose[v.index] = True
        weight[loose] = 0
    weight[inside] = 1
    target = loc + nor * abstand
    delta = (target - co) * weight[:, None]
    delta = _smooth_field(delta, edges, n, int(glaetten))
    new = co + delta
    start = local @ mw[:3, :3].T + mw[:3, 3]
    for _ in range(3):   # smoothing can pull points back in: push them out again (and smooth lightly)
        loc2, nor2, signed2 = _nearest(tree, new)
        bad = signed2 < abstand * 0.8
        if not bad.any():
            break
        fix = np.zeros_like(new)
        fix[bad] = (loc2[bad] + nor2[bad] * abstand) - new[bad]
        fix = _smooth_field(fix, edges, n, 2, keep=bad)
        new = new + fix
    loc2, nor2, signed2 = _nearest(tree, new)
    inv = np.linalg.inv(mw)
    mesh.vertices.foreach_set('co', (new @ inv[:3, :3].T + inv[:3, 3]).astype(np.float32).ravel())
    mesh.update()
    zone2 = zone   # same points as before, so the numbers compare
    after = {'durchstossend': int((signed2 < 0).sum()), 'zu_nah': int((signed2 < abstand * 0.5).sum()),
             'spalt_mm_mittel': round(float(np.mean(np.abs(signed2[zone2]))) * 1000, 2) if zone2.any() else None,
             'spalt_mm_max_anliegend': round(float(np.max(signed2[zone2])) * 1000, 2) if zone2.any() else None}
    answer = {'kleid': dress.name, 'punkte': n, 'bewegt': int((np.linalg.norm(new - start, axis=1) > 1e-4).sum()),
              'vorher': before, 'nachher': after}
    if rig is not None and gewichte:
        answer['gewichte'] = gewichte_uebertragen(body, dress, rig, abstand=max(0.05, anliegen * 2), modus=gewichte_modus)
        if not any(m.type == 'CORRECTIVE_SMOOTH' for m in dress.modifiers):
            smooth = dress.modifiers.new('Glätten nach Pose', 'CORRECTIVE_SMOOTH')
            smooth.iterations = 8
            smooth.use_only_smooth = False
            smooth.rest_source = 'ORCO'
    return answer


def kleid_simulieren(kleid, koerper, bilder=40, gewicht=0.3, steifigkeit=15.0, pin_gruppe=None, abstand=0.003,
                     anwenden=True):
    """Let a garment settle on the body with a cloth simulation (CPU, gravity, body as collider): for loose parts
    (skirt, sleeves) after kleid_anlegen. pin_gruppe = vertex group that stays in place (waistband, shoulders).
    anwenden=True applies the result at the last frame and removes the helpers. Run in the final pose."""
    dress, body = _obj(kleid), _obj(koerper)
    scene = bpy.context.scene
    added_collision = None
    if not any(m.type == 'COLLISION' for m in body.modifiers):
        added_collision = body.modifiers.new('Kollision', 'COLLISION')
    collision = next(m for m in body.modifiers if m.type == 'COLLISION')
    body.collision.thickness_outer = float(abstand)
    body.collision.cloth_friction = 5.0
    cloth = dress.modifiers.new('Stoff', 'CLOTH')
    settings = cloth.settings
    settings.quality = 8
    settings.mass = float(gewicht)
    settings.tension_stiffness = settings.compression_stiffness = float(steifigkeit)
    settings.shear_stiffness = float(steifigkeit) * 0.33
    settings.bending_stiffness = 0.5
    if pin_gruppe:
        if pin_gruppe not in dress.vertex_groups:
            raise ValueError(f'Vertexgruppe „{pin_gruppe}“ gibt es in {dress.name} nicht.')
        settings.vertex_group_mass = pin_gruppe
    cloth.collision_settings.distance_min = float(abstand)
    cloth.collision_settings.use_self_collision = False
    start = scene.frame_current
    cloth.point_cache.frame_start = start
    cloth.point_cache.frame_end = start + int(bilder)
    started = time.time()
    for frame in range(start, start + int(bilder) + 1):
        scene.frame_set(frame)
    answer = {'kleid': dress.name, 'bilder': int(bilder), 'sekunden': round(time.time() - started, 1)}
    if anwenden:
        with bpy.context.temp_override(object=dress, active_object=dress, selected_objects=[dress]):
            bpy.ops.object.modifier_apply(modifier=cloth.name)
        if added_collision is not None:
            body.modifiers.remove(added_collision)
        scene.frame_set(start)
        answer['angewendet'] = True
    else:
        answer['hinweis'] = f'Simulation liegt auf Bild {start + int(bilder)}; Stoff-Modifier bleibt aktiv.'
    del collision
    return answer


# ------------------------------------------------------------------ fast posing
FAST_HEAVY = ('ARMATURE', 'CORRECTIVE_SMOOTH', 'SURFACE_DEFORM', 'MESH_DEFORM', 'SUBSURF', 'MULTIRES', 'CLOTH', 'SHRINKWRAP',
              'SMOOTH', 'LAPLACIANSMOOTH', 'DATA_TRANSFER', 'SOLIDIFY')


def schnell_posieren(an=True, grenze=150000, vorschau=True, punkte=60000):
    """Fast posing switch for heavy figures (millions of points): an=True takes every mesh above `grenze` points that
    is deformed by an armature out of the evaluation (bone changes no longer recompute it) and – with vorschau – puts a
    light stand-in (~`punkte` points, same weights, follows the rig) in its place, also in blender_look.
    an=False removes the stand-ins and switches everything back exactly as it was. Saved in the scene, so it survives a
    session restart. Render/final look only with an=False."""
    scene = bpy.context.scene
    if not an:
        restored, removed = [], 0
        for obj in list(bpy.data.objects):
            if obj.get('studioportal_schnell_proxy'):
                bpy.data.objects.remove(obj, do_unlink=True)
                removed += 1
        for obj in bpy.data.objects:
            saved = obj.get('studioportal_schnell')
            if saved is None:
                continue
            state = dict(saved)
            obj.hide_viewport = bool(state.get('hide_viewport', False))
            obj.hide_render = bool(state.get('hide_render', False))
            for mod in obj.modifiers:
                if mod.name in state.get('mods', {}):
                    mod.show_viewport = bool(state['mods'][mod.name])
            del obj['studioportal_schnell']
            restored.append(obj.name)
        bpy.context.view_layer.update()
        return {'schnell': False, 'wieder_aktiv': restored, 'stellvertreter_entfernt': removed}
    switched, proxies = [], []
    for obj in list(scene.objects):
        if obj.type != 'MESH' or obj.get('studioportal_schnell') is not None or obj.get('studioportal_schnell_proxy'):
            continue
        if len(obj.data.vertices) < grenze or not any(m.type == 'ARMATURE' for m in obj.modifiers):
            continue
        state = {'hide_viewport': obj.hide_viewport, 'hide_render': obj.hide_render,
                 'mods': {m.name: m.show_viewport for m in obj.modifiers if m.type in FAST_HEAVY}}
        if vorschau and not obj.hide_render:
            proxy = obj.copy()
            proxy.data = obj.data.copy()
            proxy.name = f'{obj.name}-schnell'
            proxy.modifiers.clear()
            _link(proxy, obj)
            dec = proxy.modifiers.new('Dezimieren', 'DECIMATE')
            dec.ratio = max(0.005, min(1.0, punkte / len(obj.data.vertices)))
            bpy.context.view_layer.update()
            light = bpy.data.meshes.new_from_object(proxy.evaluated_get(bpy.context.evaluated_depsgraph_get()))
            old = proxy.data
            proxy.modifiers.clear()
            proxy.data = light
            bpy.data.meshes.remove(old)
            for group in list(proxy.vertex_groups):
                proxy.vertex_groups.remove(group)
            for group in obj.vertex_groups:
                proxy.vertex_groups.new(name=group.name)
            transfer = proxy.modifiers.new('Gewichte', 'DATA_TRANSFER')
            transfer.object = obj
            transfer.use_vert_data = True
            transfer.data_types_verts = {'VGROUP_WEIGHTS'}
            transfer.vert_mapping = 'NEAREST'
            transfer.layers_vgroup_select_src = 'ALL'
            transfer.layers_vgroup_select_dst = 'NAME'
            arm = next(m for m in obj.modifiers if m.type == 'ARMATURE')
            for mod in obj.modifiers:   # evaluate the stand-in's weights against the heavy mesh in rest shape
                if mod.type in FAST_HEAVY:
                    mod.show_viewport = False
            bpy.context.view_layer.update()
            with bpy.context.temp_override(object=proxy, active_object=proxy, selected_objects=[proxy]):
                bpy.ops.object.modifier_apply(modifier=transfer.name)
            new_arm = proxy.modifiers.new('Armature', 'ARMATURE')
            new_arm.object = arm.object
            proxy['studioportal_schnell_proxy'] = obj.name
            proxies.append(proxy.name)
        obj['studioportal_schnell'] = state
        for mod in obj.modifiers:
            if mod.type in FAST_HEAVY:
                mod.show_viewport = False
        obj.hide_viewport = True              # not evaluated at all while posing
        if vorschau:
            obj.hide_render = True            # blender_look shows the stand-in instead
        switched.append(f'{obj.name} ({len(obj.data.vertices)} Punkte)')
    bpy.context.view_layer.update()
    return {'schnell': True, 'pausiert': switched, 'stellvertreter': proxies,
            'hinweis': 'Posieren wie gewohnt (Knochen, IK-Empties). Vor Render, blender_check oder Kleid-Funktionen: '
                       'figur.schnell_posieren(False).' if switched else f'Kein Mesh über {grenze} Punkten mit Armature gefunden.'}


# ------------------------------------------------------------------ motion import (BVH / Mixamo FBX → MPFB)
_MOTION_MAP = {
    'hips': 'root', 'pelvis': 'root',
    'spine': 'spine04', 'spine1': 'spine03', 'spine2': 'spine01', 'spine3': 'spine01', 'chest': 'spine02',
    'neck': 'neck01', 'neck1': 'neck02', 'head': 'head',
}
_CMU_SPINE = {'lowerback': 'spine04', 'spine': 'spine03', 'spine1': 'spine01'}
for _side, _s in (('left', 'L'), ('right', 'R')):
    _MOTION_MAP.update({f'{_side}shoulder': f'clavicle.{_s}', f'{_side}arm': f'upperarm01.{_s}', f'{_side}upperarm': f'upperarm01.{_s}',
                        f'{_side}forearm': f'lowerarm01.{_s}', f'{_side}lowerarm': f'lowerarm01.{_s}', f'{_side}hand': f'wrist.{_s}',
                        f'{_side}upleg': f'upperleg01.{_s}', f'{_side}upperleg': f'upperleg01.{_s}', f'{_side}thigh': f'upperleg01.{_s}',
                        f'{_side}leg': f'lowerleg01.{_s}', f'{_side}lowerleg': f'lowerleg01.{_s}', f'{_side}shin': f'lowerleg01.{_s}',
                        f'{_side}foot': f'foot.{_s}'})
    for _i, _finger in enumerate(('thumb', 'index', 'middle', 'ring', 'pinky'), start=1):
        for _j in (1, 2, 3):
            _MOTION_MAP[f'{_side}hand{_finger}{_j}'] = f'finger{_i}-{_j}.{_s}'


def _motion_key(name):
    return ''.join(ch for ch in name.split(':')[-1].lower() if ch.isalnum())


def _facing(points_l, points_r):
    lateral = mathutils.Vector(points_l) - mathutils.Vector(points_r)
    lateral.z = 0
    forward = lateral.cross(mathutils.Vector((0, 0, 1)))
    return forward.normalized() if forward.length > 1e-6 else mathutils.Vector((0, -1, 0))


def bvh_laden(datei, rig, start=1, schritt=1, finger=True, zuordnung=None, quelle_behalten=False, name=None):
    """Motion from a BVH file (CMU, Truebones …) or a Mixamo FBX onto the MPFB rig (retargeting): imports the file,
    maps the bones by name (Mixamo/BVH standard names, own mapping via zuordnung={'SourceBone': 'mpfb_bone'}),
    compensates the different rest pose (limbs follow the source's bone directions, so a T-pose frame gives a T-pose –
    trunk bones get no rest correction; bones with an implausible swing, e.g. CMU's zero-length hands, take their
    parent's correction), facing direction, scales the hip motion to the figure's leg length (hip height above the
    clip's ankles, start at the figure's place), keeps the feet on the floor (line through the clip's lowest points,
    also evens out tilted mocap floors) and writes one keyframe per `schritt` frames from frame `start` into a new action.
    pruefung: kopf_ueber_huefte_cm, boden_abstand_cm, boden_korrigiert_cm, boden_neigung_ausgeglichen_cm, weg_m.
    The source armature is deleted unless quelle_behalten. Returns frames, mapped bones and the action name.
    For a heavy figure call figur.schnell_posieren(True) first; play/render with scene.frame_set or blender_render."""
    from bpy_extras import anim_utils  # noqa: PLC0415
    target = _obj(rig)
    path = str(Path(datei).expanduser())
    if not Path(path).is_file():
        raise ValueError(f'Datei {path} gibt es auf bigki nicht (blender_open lädt Dateien hoch, oder Pfad unter ~/).')
    scene = bpy.context.scene
    before = set(bpy.data.objects)
    if path.lower().endswith('.bvh'):
        bpy.ops.import_anim.bvh(filepath=path, rotate_mode='NATIVE', update_scene_fps=False, update_scene_duration=False)
    elif path.lower().endswith('.fbx'):
        bpy.ops.import_scene.fbx(filepath=path, automatic_bone_orientation=False, ignore_leaf_bones=True)
    else:
        raise ValueError('Nur .bvh oder .fbx (Mixamo: „FBX Binary“, „Without Skin“ reicht).')
    new = [o for o in bpy.data.objects if o not in before]
    sources = [o for o in new if o.type == 'ARMATURE']
    if not sources:
        for o in new:
            bpy.data.objects.remove(o, do_unlink=True)
        raise RuntimeError('In der Datei ist kein Skelett.')
    source = max(sources, key=lambda o: len(o.data.bones))
    try:
        action = source.animation_data.action if source.animation_data else None
        if action is None:
            raise RuntimeError('Das Skelett in der Datei hat keine Animation.')
        first, last = (int(round(v)) for v in action.frame_range)
        keys = {_motion_key(b.name): b.name for b in source.data.bones}
        table = dict(_MOTION_MAP)
        if 'lowerback' in keys:
            table.update(_CMU_SPINE)
        pairs = {}
        for key, src_name in keys.items():
            tgt = table.get(key)
            if tgt and tgt in target.pose.bones and (finger or not tgt.startswith('finger')):
                pairs[src_name] = tgt
        if zuordnung:
            for src_name, tgt in zuordnung.items():
                if src_name not in source.pose.bones or tgt not in target.pose.bones:
                    raise ValueError(f'zuordnung: {src_name} oder {tgt} gibt es nicht.')
                pairs[src_name] = tgt
        root_src = next((s for s, t in pairs.items() if t == 'root'), None)
        if root_src is None:
            raise RuntimeError('Hüfte (Hips) nicht gefunden – zuordnung={"<Hüftknochen>": "root"} angeben. '
                               f'Knochen in der Datei: {", ".join(list(keys.values())[:40])}')
        # rest data (world space)
        old_action = target.animation_data.action if target.animation_data else None
        if target.animation_data:
            target.animation_data.action = None
        saved_pose = {pb.name: (pb.rotation_mode, pb.matrix_basis.copy()) for pb in target.pose.bones}
        for pb in target.pose.bones:
            pb.matrix_basis = mathutils.Matrix()
        scene.frame_set(first)
        bpy.context.view_layer.update()
        sw, tw = source.matrix_world, target.matrix_world
        s_rest = {b.name: sw @ b.matrix_local for b in source.data.bones}
        t_rest = {b.name: tw @ b.matrix_local for b in target.data.bones}

        def bone_dir(world_mat, bone):
            return (world_mat.to_3x3() @ (bone.tail_local - bone.head_local)).normalized()

        # facing: rotate the source motion so it faces like the figure
        def hips_lr(arm, world, names):
            l = next((n for n in names if n.lower().replace('_', '').endswith(('leftupleg', 'leftthigh', 'leftupperleg', 'upperleg01.l'))), None)
            r = next((n for n in names if n.lower().replace('_', '').endswith(('rightupleg', 'rightthigh', 'rightupperleg', 'upperleg01.r'))), None)
            if l is None or r is None:
                return None
            return world @ arm.data.bones[l].head_local, world @ arm.data.bones[r].head_local
        s_lr = hips_lr(source, sw, [b.name for b in source.data.bones])
        t_lr = hips_lr(target, tw, [b.name for b in target.data.bones])
        turn = mathutils.Matrix()
        if s_lr and t_lr:
            fs, ft = _facing(*s_lr), _facing(*t_lr)
            angle = math.atan2(fs.cross(ft).z, fs.dot(ft))
            turn = mathutils.Matrix.Rotation(angle, 3, 'Z')
        # rest alignment: swing that turns the (turned) source rest bone onto the target rest bone
        # Trunk bones get no swing: the importer's hip bone direction is arbitrary (Blender's BVH import points it
        # at the mean of its children, i.e. downwards for Mixamo proportions) – a swing there flipped the whole
        # pelvis by 180° (Codex test 17.11.2026: head 55 cm below the hips in the neutral frame). Both skeletons
        # stand upright after `turn`, so identity is right for root/spine/neck/head. Limbs keep the swing (T- vs
        # A-pose), except implausible swings > 100° (odd bone axes in FBX files).
        align, skipped_swing = {}, []
        for src_name, tgt in pairs.items():
            sd = turn @ bone_dir(sw, source.data.bones[src_name])
            td = bone_dir(tw, target.data.bones[tgt])
            if tgt == 'root' or tgt.startswith(('spine', 'neck', 'head')):
                align[src_name] = mathutils.Matrix.Identity(3)
            elif sd.angle(td, 0.0) > math.radians(100):
                align[src_name] = mathutils.Matrix.Identity(3)
                skipped_swing.append(tgt)
            else:
                align[src_name] = sd.rotation_difference(td).to_matrix()
        # bones whose own direction says nothing – skipped swings and (near) zero-length source bones such as CMU's
        # hands ("zero length node") – take the correction of their nearest mapped parent, so a hand keeps the
        # forearm's alignment instead of twisting (CMU test 17.11.2026: hands bent into the hips)
        inherited = []
        for src_name, tgt in pairs.items():
            if tgt not in skipped_swing:
                continue
            parent = source.data.bones[src_name].parent
            while parent is not None and parent.name not in pairs:
                parent = parent.parent
            if parent is not None and parent.name in align:
                align[src_name] = align[parent.name].copy()
                inherited.append(tgt)
        s_root_rest = turn @ (sw @ source.data.bones[root_src].head_local)
        t_root_rest = tw @ target.data.bones['root'].head_local
        # height reference = the same joints on both skeletons (the ankles when mapped), so "lowest joint" means the
        # same thing (CMU has no toe tips, MPFB has – that alone lifted the figure by ~7 cm)
        ref = {s_name: t_name for s_name, t_name in pairs.items() if t_name.startswith('foot')} or dict(pairs)
        src_leg = max(1e-6, s_root_rest.z - min((turn @ (sw @ source.data.bones[n].head_local)).z for n in ref))
        t_floor = min((tw @ target.data.bones[n].head_local).z for n in ref.values())
        tgt_leg = max(1e-6, t_root_rest.z - t_floor)
        ratio = tgt_leg / src_leg
        t_lowest = min((tw @ b.head_local).z for b in target.data.bones)
        # height: hip above those joints' lowest point over the CLIP (not of the rest pose – a CMU BVH rest skeleton
        # hangs below a root at the origin, which put the figure a full hip height into the air); horizontal: relative
        # to the first frame, so the figure starts where it stands instead of jumping to the clip's world position
        frames = list(range(first, last + 1, max(1, int(schritt))))
        anim_floor = None
        for frame in frames[::max(1, len(frames) // 60)] + [frames[0]]:
            scene.frame_set(frame)
            low = min((turn @ (sw @ source.pose.bones[n].head)).z for n in ref)
            anim_floor = low if anim_floor is None else min(anim_floor, low)
        hip_first = turn @ (sw @ source.pose.bones[root_src].head)
        # order target bones parent-first, so pose matrices can be built without depsgraph updates
        order = [b for b in target.data.bones]
        order.sort(key=lambda b: len(b.parent_recursive))
        inverse_pairs = {t: s for s, t in pairs.items()}
        tw3_inv = tw.to_3x3().normalized().inverted()
        samples = {b.name: [] for b in order if b.name in inverse_pairs}
        root_loc = []
        for frame in frames:
            scene.frame_set(frame)
            pose_arm = {}
            for bone in order:
                pb = target.pose.bones[bone.name]
                parent = bone.parent
                rest_rel = (parent.matrix_local.inverted() @ bone.matrix_local) if parent else bone.matrix_local
                parent_arm = pose_arm[parent.name] if parent else mathutils.Matrix()
                base = parent_arm @ rest_rel
                src_name = inverse_pairs.get(bone.name)
                if src_name is None:
                    pose_arm[bone.name] = base
                    continue
                s_now = turn @ (sw @ source.pose.bones[src_name].matrix).to_3x3()
                s0 = align[src_name] @ (turn @ s_rest[src_name].to_3x3())
                desired_world = (s_now @ s0.inverted()) @ t_rest[bone.name].to_3x3()
                desired_arm = tw3_inv @ desired_world
                basis_rot = base.to_3x3().inverted() @ desired_arm
                basis = basis_rot.to_4x4()
                if bone.name == 'root':
                    hip_now = turn @ (sw @ source.pose.bones[src_name].head)
                    world_pos = mathutils.Vector((t_root_rest.x + (hip_now.x - hip_first.x) * ratio,
                                                  t_root_rest.y + (hip_now.y - hip_first.y) * ratio,
                                                  t_floor + (hip_now.z - anim_floor) * ratio))
                    arm_pos = tw.inverted() @ world_pos
                    offset = base.inverted() @ arm_pos
                    basis.translation = offset
                    root_loc.append(tuple(offset))
                pose_arm[bone.name] = base @ basis
                quat = basis_rot.to_quaternion()
                if samples[bone.name] and quat.dot(samples[bone.name][-1]) < 0:
                    quat.negate()
                samples[bone.name].append(quat)
        # write keys: one keyframe_insert per channel creates the action/slot/fcurves, then bulk-fill
        for pb in target.pose.bones:
            pb.matrix_basis = mathutils.Matrix()
        target.animation_data_create()
        new_action = bpy.data.actions.new(name or f'{Path(path).stem}-{target.name}')
        target.animation_data.action = new_action
        start_frame = int(start)
        keyed_frames = [start_frame + (f - first) for f in frames]
        for bone_name in samples:
            pb = target.pose.bones[bone_name]
            pb.rotation_mode = 'QUATERNION'
            pb.keyframe_insert('rotation_quaternion', frame=keyed_frames[0])
        target.pose.bones['root'].keyframe_insert('location', frame=keyed_frames[0])
        bag = anim_utils.animdata_get_channelbag_for_assigned_slot(target.animation_data)
        curves = {(fc.data_path, fc.array_index): fc for fc in bag.fcurves}

        def fill(path_, index, values):
            fc = curves[(path_, index)]
            fc.keyframe_points.clear()
            fc.keyframe_points.add(len(values))
            co = np.empty(len(values) * 2, np.float32)
            co[0::2] = keyed_frames
            co[1::2] = values
            fc.keyframe_points.foreach_set('co', co)
            fc.keyframe_points.foreach_set('interpolation', [2] * len(values))   # LINEAR: dense samples
            fc.update()
        for bone_name, quats in samples.items():
            data_path = f'pose.bones["{bone_name}"].rotation_quaternion'
            for i in range(4):
                fill(data_path, i, [q[i] for q in quats])
        for i in range(3):
            fill('pose.bones["root"].location', i, [p[i] for p in root_loc])
        scene.frame_start = min(scene.frame_start, keyed_frames[0]) if scene.frame_start > keyed_frames[0] else scene.frame_start
        scene.frame_end = max(scene.frame_end, keyed_frames[-1])
        scene.frame_set(keyed_frames[0])
        mapped = sorted(pairs.items(), key=lambda kv: kv[1])
        unmapped = sorted(set(keys.values()) - set(pairs))
        bpy.context.view_layer.update()
        hip_z = (tw @ target.pose.bones['root'].head).z
        head_z = (tw @ target.pose.bones['head'].head).z if 'head' in target.pose.bones else hip_z
        check = {'kopf_ueber_huefte_cm': round((head_z - hip_z) * 100, 1)}
        if head_z <= hip_z:
            check['warnung'] = 'Kopf liegt im ersten Bild nicht über der Hüfte – Zuordnung/Achsen prüfen (zuordnung=…).'
        # ground contact and distance: lowest joint over the clip vs. the rest pose's lowest joint, hip travel
        lows, hips, sampled = [], [], []
        for frame in keyed_frames[::max(1, len(keyed_frames) // 40)] + [keyed_frames[-1]]:
            scene.frame_set(frame)
            lows.append(min((tw @ pb.head).z for pb in target.pose.bones) - t_lowest)
            hips.append(tw @ target.pose.bones['root'].head)
            sampled.append(frame)
        # ground contact: different leg proportions (thigh/shin) leave the feet a few cm above or below the floor, and
        # mocap floors are often slightly tilted (CMU) – fit a line through the contact points (lowest joint per ~1/6 of
        # the clip) and move the root so the feet touch the rest pose's floor all the way through
        chunk = max(1, len(lows) // 6)
        contacts = [min(zip(lows[i:i + chunk], sampled[i:i + chunk])) for i in range(0, len(lows), chunk)]
        if len(contacts) >= 3:
            n = len(contacts); mx = sum(c[1] for c in contacts) / n; my = sum(c[0] for c in contacts) / n
            var = sum((c[1] - mx) ** 2 for c in contacts)
            slope = sum((c[1] - mx) * (c[0] - my) for c in contacts) / var if var else 0.0
            level = min(c[0] - slope * c[1] for c in contacts)   # line through the lowest contact, not the mean
        else:
            slope, level = 0.0, min(lows)
        drift = slope * (keyed_frames[-1] - keyed_frames[0])
        if abs(drift) < 0.01: slope, level = 0.0, min(lows)
        gap = level + slope * keyed_frames[0]
        if (abs(gap) > 0.005 or slope) and abs(gap) < 0.5 and abs(drift) < 0.5:
            to_local = target.data.bones['root'].matrix_local.to_3x3().inverted() @ tw.inverted().to_3x3()
            root_loc = [tuple(mathutils.Vector(p) + to_local @ mathutils.Vector((0, 0, -(level + slope * f))))
                        for p, f in zip(root_loc, keyed_frames)]
            for i in range(3):
                fill('pose.bones["root"].location', i, [p[i] for p in root_loc])
            check['boden_korrigiert_cm'] = round(-gap * 100, 1)
            if abs(drift) >= 0.01: check['boden_neigung_ausgeglichen_cm'] = round(-drift * 100, 1)
            lows = [l - (level + slope * f) for l, f in zip(lows, sampled)]
        gap = min(lows)
        scene.frame_set(keyed_frames[0])
        check['boden_abstand_cm'] = round(gap * 100, 1)
        check['weg_m'] = round((hips[-1] - hips[0]).xy.length, 2)
        if abs(gap) > 0.1:
            check.setdefault('warnung', f'Tiefstes Gelenk {gap * 100:.0f} cm vom Boden – Hüfthöhe prüfen.')
        return {'pruefung': check, 'ohne_ausrichtung': [t for t in skipped_swing if t not in inherited],
                'ausrichtung_vom_elternknochen': inherited,'aktion': new_action.name, 'bilder': [keyed_frames[0], keyed_frames[-1]], 'schluessel': len(frames),
                'knochen': len(pairs), 'zuordnung': dict(mapped), 'nicht_zugeordnet': unmapped[:60],
                'drehung_grad': round(math.degrees(math.atan2(turn[1][0], turn[0][0])), 1), 'huefte_faktor': round(ratio, 3),
                'vorige_aktion': old_action.name if old_action else None,
                'hinweis': 'Vorige Pose/Aktion ersetzt; mit target.animation_data.action = D.actions[vorige_aktion] zurück.'}
    finally:
        if not quelle_behalten:
            for o in new:
                if o.name in bpy.data.objects:
                    bpy.data.objects.remove(o, do_unlink=True)
        if 'saved_pose' in locals() and 'new_action' not in locals():
            for pb in target.pose.bones:
                mode, basis = saved_pose[pb.name]
                pb.rotation_mode = mode
                pb.matrix_basis = basis


UNIRIG = Path.home() / '.local/share/3d-modelle-app/figur'


def _readable_bone_names(rig):
    """Readable names for an anonymous skeleton (UniRig: bone_0 …) from topology and position, Rigify-style:
    hips, spine, spine.001 …, neck, head, shoulder/upper_arm/forearm/hand.L|R, thumb|index|middle|ring|pinky.01.L,
    pelvis/thigh/shin/foot/toe.L|R, tail.01 …, <parent>_extra.01(.L). Assumes an upright figure; the facing is taken
    from the feet (default -Y), left = the character's left. Elbow/knee = halfway between the limb's start and the
    wrist/ankle, so twist bones get .001 suffixes instead of shifting the names. Returns {old: new}."""
    mw = rig.matrix_world
    bones = list(rig.data.bones)
    head = {b.name: mw @ b.head_local for b in bones}
    tail = {b.name: mw @ b.tail_local for b in bones}
    roots = [b for b in bones if b.parent is None]
    if not roots:
        return {}
    root = max(roots, key=lambda b: len(b.children_recursive))
    zs = [v.z for v in list(head.values()) + list(tail.values())]
    height = max(1e-6, max(zs) - min(zs))
    tol = 0.03 * height

    def subtree(b):
        return [b] + list(b.children_recursive)

    def direction(b):
        d = tail[b.name] - head[b.name]
        return d.normalized() if d.length > 1e-9 else d

    def top(b):
        return max(max(tail[x.name].z, head[x.name].z) for x in subtree(b))

    def reach(b, start):
        return max(max((head[x.name] - start).length, (tail[x.name] - start).length) for x in subtree(b))

    # spine: from the root keep following the child that points up and reaches highest
    spine = [root]
    while True:
        ups = [c for c in spine[-1].children if direction(c).z > 0.5 and top(c) > head[c.name].z - 1e-6]
        if not ups:
            break
        spine.append(max(ups, key=top))
    in_spine = {b.name for b in spine}
    cx, root_z = head[root.name].x, head[root.name].z
    limbs = [(i, c) for i, b in enumerate(spine) for c in b.children if c.name not in in_spine]

    def mean(b, axis):
        pts = [head[x.name][axis] for x in subtree(b)]
        return sum(pts) / len(pts)

    def is_leg(c):
        return mean(c, 2) < root_z - tol and reach(c, head[c.name]) > 0.25 * height

    forward = -1.0                                # facing from the toes/feet; Blender front view = -Y
    tips = [x for _, c in limbs if is_leg(c) for x in subtree(c) if not x.children]
    if tips:
        dy = sum(tail[t.name].y - head[t.name].y for t in tips)
        if abs(dy) > 1e-4:
            forward = 1.0 if dy > 0 else -1.0
    side_sign = 1.0 if forward < 0 else -1.0     # facing -Y: the character's left is +X

    names, used = {}, set()

    def give(b, name):
        base, n = name, 1
        while name in used:
            n += 1
            name = f'{base}_{n}'
        used.add(name)
        names[b.name] = name

    def numbered(label, k):
        return label if k == 0 else f'{label}.{k:03d}'

    def side_of(c):
        dx = (mean(c, 0) - cx) * side_sign
        return '.L' if dx > tol else '.R' if dx < -tol else ''

    def is_arm(i, c):
        return bool(side_of(c)) and not is_leg(c) and i >= 1 and reach(c, head[c.name]) > 0.25 * height

    arms = [i for i, c in limbs if is_arm(i, c)]
    chest = max(arms) if arms else max(1, len(spine) - 3)
    give(spine[0], 'hips')
    for k, b in enumerate(spine[1:chest + 1]):
        give(b, numbered('spine', k))
    for k, b in enumerate(spine[chest + 1:-1]):
        give(b, numbered('neck', k))
    if spine[-1].name not in names:
        give(spine[-1], 'head')

    def main_chain(c):
        out = [c]
        while out[-1].children:
            kids = out[-1].children
            if len(kids) > 1:
                # several children: hand/foot with fingers – unless one child clearly carries the limb on
                big = max(kids, key=lambda k: len(k.children_recursive))
                if len(big.children_recursive) < 3 or sum(len(k.children_recursive) >= 3 for k in kids) > 1:
                    break
                out.append(big)
            else:
                out.append(kids[0])
        return out

    def label_arm(chain, side):
        hand_i = len(chain) - 1
        has_shoulder = len(chain) >= 4 and (tail[chain[0].name] - head[chain[0].name]).length < 0.3 * max(
            1e-6, (head[chain[hand_i].name] - head[chain[0].name]).length)
        start = head[chain[1].name] if has_shoulder else head[chain[0].name]   # measure from the shoulder joint
        wrist = head[chain[hand_i].name]
        total = max(1e-6, (wrist - start).length)
        k_sh = k_up = k_fo = 0
        for i, b in enumerate(chain):
            if i == hand_i:
                give(b, 'hand' + side)
            elif i == 0 and has_shoulder:
                give(b, 'shoulder' + side); k_sh += 1
            elif ((head[b.name] + tail[b.name]) / 2 - start).length < total * 0.5:
                give(b, numbered('upper_arm', k_up) + side); k_up += 1
            else:
                give(b, numbered('forearm', k_fo) + side); k_fo += 1

    def label_leg(chain, side):
        foot_i = next((i for i, b in enumerate(chain) if i > 0 and abs(direction(b).z) < 0.6), len(chain) - 1)
        offset = len(chain) > 2 and abs(direction(chain[0]).z) < 0.6           # sideways hip bone before the thigh
        start = head[chain[1].name] if offset else head[chain[0].name]
        ankle = head[chain[foot_i].name]
        total = max(1e-6, (ankle - start).length)
        k_th = k_sh = k_to = 0
        for i, b in enumerate(chain):
            if i == foot_i:
                give(b, 'foot' + side)
            elif i > foot_i:
                give(b, numbered('toe', k_to) + side); k_to += 1
            elif i == 0 and offset:
                give(b, 'pelvis' + side)            # hip offset bone (sideways) before the thigh
            elif ((head[b.name] + tail[b.name]) / 2 - start).length < total * 0.5:
                give(b, numbered('thigh', k_th) + side); k_th += 1
            else:
                give(b, numbered('shin', k_sh) + side); k_sh += 1

    def label_digits(end, side, hand):
        kids = [c for c in end.children if c.name not in names]
        kids.sort(key=lambda c: -(head[c.name].y - head[end.name].y) * forward)   # most forward first
        labels = ['thumb', 'index', 'middle', 'ring', 'pinky'] if hand else ['toe_big', 'toe_2', 'toe_3', 'toe_4', 'toe_small']
        for j, f in enumerate(kids):
            label = labels[j] if len(kids) == 5 else f'{"finger" if hand else "toe"}{j + 1}'
            for k, b in enumerate(subtree(f)):
                if b.name not in names:
                    give(b, f'{label}.{k + 1:02d}{side}')

    for i, c in limbs:
        side = side_of(c)
        if is_leg(c) and side:
            chain = main_chain(c)
            label_leg(chain, side)
            label_digits(chain[-1], side, hand=False)
        elif is_arm(i, c):
            chain = main_chain(c)
            label_arm(chain, side)
            label_digits(chain[-1], side, hand=True)
        else:
            parent = names.get(spine[i].name, 'spine').split('.')[0]
            label = 'tail' if (not side and mean(c, 2) < root_z - tol) else f'{parent}_extra'
            for k, b in enumerate(subtree(c)):
                if b.name not in names:
                    dx = (head[b.name].x - cx) * side_sign
                    own = '.L' if dx > tol / 3 else '.R' if dx < -tol / 3 else ''
                    give(b, f'{label}.{k + 1:02d}{own}')
    for b in bones:
        if b.name not in names:
            give(b, f'extra.{len(names):03d}')
    return names


def knochen_benennen(rig):
    """Gives an anonymous skeleton (UniRig bone_0 …) readable Rigify-style names (hips, spine, neck, head,
    upper_arm.L, forearm.L, hand.L, index.01.L, thigh.R, shin.R, foot.R …). Vertex groups follow automatically.
    Returns the mapping {old: new}. auto_rig does this by default."""
    target = _obj(rig)
    mapping = _readable_bone_names(target)
    for i, (old, new) in enumerate(mapping.items()):
        target.data.bones[old].name = f'__tmp{i}'
    for i, (old, new) in enumerate(mapping.items()):
        target.data.bones[f'__tmp{i}'].name = new
    return mapping


def auto_rig(objekt, original_ausblenden=True, max_minuten=40, sprechende_namen=True):
    """Automatisches Skelett + Gewichte für ein beliebiges Mesh mit UniRig (VAST-AI, MIT) auf der CPU, ~8–10 min.
    Gibt das neue Rig und das gewichtete Mesh zurück; das Original bleibt (ausgeblendet) erhalten."""
    import os, shutil, subprocess, tempfile, time  # noqa: E401, PLC0415
    obj = _obj(objekt)
    if obj.type != 'MESH':
        raise ValueError(f'{obj.name} ist kein Mesh')
    venv, repo, shims = UNIRIG / 'unirig-venv/bin', UNIRIG / 'unirig', UNIRIG / 'unirig-shims'
    if not (venv / 'python').exists():
        raise RuntimeError('UniRig ist auf bigki nicht eingerichtet (~/.local/share/3d-modelle-app/figur/unirig-venv fehlt).')
    work = Path(tempfile.mkdtemp(prefix='autorig-', dir=str(UNIRIG)))
    start = time.time()
    try:
        selected = list(bpy.context.selected_objects)
        for o in selected:
            o.select_set(False)
        obj.select_set(True)
        bpy.context.view_layer.objects.active = obj
        source = work / 'eingabe.glb'
        bpy.ops.export_scene.gltf(filepath=str(source), use_selection=True, export_apply=True, export_animations=False)
        for o in selected:
            o.select_set(True)
        env = {k: v for k, v in os.environ.items() if k not in ('OCIO', 'PYTHONPATH', 'PYTHONHOME')}
        env.update(PATH=f'{venv}:{env.get("PATH", "")}', PYTHONPATH=str(shims), HIP_VISIBLE_DEVICES='', CUDA_VISIBLE_DEVICES='')
        steps = (
            ['bash', 'launch/inference/generate_skeleton.sh', '--input', str(source), '--output', str(work / 'skelett.fbx'),
             '--skeleton_task', 'configs/task/cpu_skeleton.yaml', '--force_override', 'true'],
            ['bash', 'launch/inference/generate_skin.sh', '--input', str(work / 'skelett.fbx'), '--output', str(work / 'gewichte.fbx'),
             '--skin_task', 'configs/task/cpu_skin.yaml'],
            ['bash', 'launch/inference/merge.sh', '--source', str(work / 'gewichte.fbx'), '--target', str(source),
             '--output', str(work / 'ergebnis.glb')],
        )
        log = work / 'protokoll.txt'
        for step, expect in zip(steps, ('skelett.fbx', 'gewichte.fbx', 'ergebnis.glb')):
            left = max_minuten * 60 - (time.time() - start)
            with open(log, 'a') as out:
                subprocess.run(['nice', '-n', '10'] + step, cwd=str(repo), env=env, stdout=out, stderr=subprocess.STDOUT, timeout=max(60, left))
            if not (work / expect).exists():
                tail = log.read_text(errors='replace')[-1500:]
                raise RuntimeError(f'UniRig-Schritt {expect} ist fehlgeschlagen. Protokoll-Ende:\n{tail}')
        before = set(bpy.data.objects)
        bpy.ops.import_scene.gltf(filepath=str(work / 'ergebnis.glb'))
        new = [o for o in bpy.data.objects if o not in before]
        for o in list(new):  # UniRig's merge template leaves a small marker sphere
            if o.type == 'MESH' and len(o.data.vertices) <= 100 and o.name.startswith('Icosphere'):
                new.remove(o)
                bpy.data.objects.remove(o)
        rig = next(o for o in new if o.type == 'ARMATURE')
        mesh = max((o for o in new if o.type == 'MESH'), key=lambda o: len(o.data.vertices))
        rig.name, mesh.name = f'{obj.name}_Rig', f'{obj.name}_rigged'
        for o in new:
            if o.type == 'MESH' and obj.material_slots and not o.material_slots:
                for slot in obj.material_slots:
                    o.data.materials.append(slot.material)
        if original_ausblenden:
            obj.hide_set(True)
            obj.hide_render = True
        renamed = {}
        if sprechende_namen:
            try:
                renamed = knochen_benennen(rig)
            except Exception as error:  # noqa: BLE001 – naming is a convenience, the rig itself is fine
                renamed = {'fehler': f'{type(error).__name__}: {error}'}
        bpy.context.view_layer.update()
        bones = [{'name': b.name, 'parent': b.parent.name if b.parent else None,
                  'kopf': [round(x, 3) for x in rig.matrix_world @ b.head_local]} for b in rig.data.bones]
        named = sprechende_namen and 'fehler' not in renamed
        return {'rig': rig.name, 'mesh': mesh.name, 'knochen': len(bones), 'sekunden': round(time.time() - start),
                'skelett': bones, 'umbenannt': renamed,
                'hinweis': ('Knochen heißen jetzt wie bei Rigify (hips, spine…, neck, head, upper_arm.L, forearm.L, hand.L, '
                            'thumb.01.L …, thigh.R, shin.R, foot.R); die Zuordnung leitet sich aus Lage und Aufbau ab – bei Tieren '
                            'oder ungewöhnlichen Figuren mit skelett prüfen. ' if named else
                            'Knochen heißen bone_0 … (Wurzel bone_0); figur.knochen_benennen(rig) gibt sprechende Namen. ')
                           + 'Posieren über pose.bones[...].rotation_euler. Original ist ausgeblendet.'}
    finally:
        shutil.rmtree(work, ignore_errors=True)


def hilfe():
    """Short overview of the building blocks."""
    names = ['mensch', 'porzellan', 'studio_licht', 'scan_aufraeumen', 'abgleichen', 'gewichte_uebertragen', 'ik',
             'arm_ik', 'bein_ik', 'pose_zuruecksetzen', 'handflaeche', 'objekt_in_hand', 'hand_greifen', 'anhaengen', 'aufstellen',
             'handy_griff', 'kleid_anlegen', 'kleid_simulieren', 'schnell_posieren', 'auto_rig', 'knochen_benennen', 'bvh_laden']
    lines = [__doc__.strip(), '']
    for name in names:
        func = globals()[name]
        import inspect  # noqa: PLC0415
        lines.append(f'figur.{name}{inspect.signature(func)}\n    {(func.__doc__ or "").strip().splitlines()[0]}')
    return '\n'.join(lines)
