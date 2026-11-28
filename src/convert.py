import math
import os
import posixpath
import stat
import sys
import zipfile
import xml.etree.ElementTree as ET
from pathlib import Path

import bpy
from mathutils import Matrix, Vector


FORMATS = ('.blend', '.glb', '.gltf', '.fbx', '.obj', '.3mf', '.stl', '.ply')
GEOMETRY_TYPES = {'MESH', 'CURVE', 'CURVES', 'SURFACE', 'META', 'FONT', 'POINTCLOUD', 'VOLUME'}


def unpack_archive(source, destination):
    os.makedirs(destination, exist_ok=True)
    root = Path(destination).resolve()
    with zipfile.ZipFile(source) as archive:
        entries = archive.infolist()
        if len(entries) > 10000 or sum(entry.file_size for entry in entries) > 4 * 1024 ** 3:
            raise RuntimeError('Das Archiv ist zu groß zum sicheren Entpacken.')
        for entry in entries:
            name = entry.filename.replace('\\', '/')
            target = (root / name).resolve()
            if name.startswith('/') or (target != root and root not in target.parents):
                raise RuntimeError('Das Archiv enthält einen ungültigen Dateipfad.')
            if stat.S_ISLNK(entry.external_attr >> 16):
                raise RuntimeError('Das Archiv enthält nicht unterstützte Verknüpfungen.')
        archive.extractall(destination)


def find_sources(source, output):
    if os.path.isfile(source) and source.lower().endswith('.zip'):
        folder = os.path.join(os.path.dirname(output), 'entpackt')
        unpack_archive(source, folder)
        source = folder
    if os.path.isfile(source):
        ext = Path(source).suffix.lower()
        if ext not in FORMATS:
            raise RuntimeError('Dieses Dateiformat wird nicht unterstützt.')
        return [source], os.path.dirname(os.path.realpath(source))
    if not os.path.isdir(source):
        raise RuntimeError('Die ausgewählte Datei wurde nicht gefunden.')
    files = []
    for root, dirs, names in os.walk(source):
        dirs[:] = [d for d in dirs if d != '__MACOSX' and not d.startswith('.')]
        for name in names:
            if not name.startswith('.'):
                files.append(os.path.join(root, name))
            if len(files) > 10000:
                raise RuntimeError('Der Ordner enthält zu viele Dateien.')
    for ext in FORMATS:
        matches = sorted(f for f in files if f.lower().endswith(ext))
        if matches:
            return matches, os.path.realpath(source)
    archives = [f for f in files if f.lower().endswith('.zip')]
    if len(archives) == 1:
        return find_sources(archives[0], output)
    raise RuntimeError('Keine unterstützte 3D-Datei gefunden.')


def import_3mf(filename):
    print('HINWEIS_3MF: Bei 3MF können Farben und Texturen fehlen.', flush=True)
    ns = {'m': 'http://schemas.microsoft.com/3dmanufacturing/core/2015/02'}
    with zipfile.ZipFile(filename) as archive:
        candidates = [i for i in archive.infolist() if i.filename.lower().endswith('.model')]
        if not candidates:
            raise RuntimeError('Die 3MF-Datei enthält kein 3D-Modell.')
        entry = next((i for i in candidates if i.filename.lower() == '3d/3dmodel.model'), candidates[0])
        names = {i.filename: i for i in candidates}
        if sum(i.file_size for i in candidates) > 1024 ** 3:
            raise RuntimeError('Das 3MF-Modell ist zu groß.')
    cache = {}

    def document(name):
        name = posixpath.normpath(name.lstrip('/'))
        if name.startswith('../') or name not in names:
            raise RuntimeError('Ein verknüpftes 3MF-Teil wurde nicht gefunden.')
        if name not in cache:
            entry = names[name]
            if entry.file_size > 512 * 1024 * 1024:
                raise RuntimeError('Das 3MF-Modell ist zu groß.')
            with zipfile.ZipFile(filename) as archive:
                root = ET.fromstring(archive.read(entry))
            resources = root.find('m:resources', ns)
            if resources is None:
                raise RuntimeError('Die 3MF-Geometrie fehlt.')
            unit = {'micron': 0.001, 'millimeter': 1.0, 'centimeter': 10.0, 'inch': 25.4, 'foot': 304.8, 'meter': 1000.0}.get(root.get('unit', 'millimeter'), 1.0)
            cache[name] = (root, {obj.get('id'): obj for obj in resources.findall('m:object', ns)}, unit)
        return cache[name]

    def transform(raw, unit):
        if not raw:
            return Matrix.Identity(4)
        values = [float(v) for v in raw.split()]
        if len(values) != 12:
            raise RuntimeError('Ungültige 3MF-Transformation.')
        return Matrix(((values[0], values[3], values[6], values[9] * unit),
                       (values[1], values[4], values[7], values[10] * unit),
                       (values[2], values[5], values[8], values[11] * unit),
                       (0, 0, 0, 1)))

    def add_object(document_name, object_id, matrix, parents):
        identity = (document_name, object_id)
        if identity in parents or len(parents) > 50:
            raise RuntimeError('Ungültige 3MF-Objekthierarchie.')
        _, objects, unit = document(document_name)
        item = objects.get(object_id)
        if item is None:
            raise RuntimeError('Ein 3MF-Teil wurde nicht gefunden.')
        mesh = item.find('m:mesh', ns)
        if mesh is not None:
            vertices_node = mesh.find('m:vertices', ns)
            triangles_node = mesh.find('m:triangles', ns)
            if vertices_node is None or triangles_node is None:
                raise RuntimeError('Die 3MF-Geometrie ist unvollständig.')
            vertices = [(float(v.get('x')) * unit, float(v.get('y')) * unit, float(v.get('z')) * unit) for v in vertices_node.findall('m:vertex', ns)]
            faces = [(int(t.get('v1')), int(t.get('v2')), int(t.get('v3'))) for t in triangles_node.findall('m:triangle', ns)]
            data = bpy.data.meshes.new('Modell')
            data.from_pydata(vertices, [], faces)
            data.update()
            obj = bpy.data.objects.new('Modell', data)
            bpy.context.scene.collection.objects.link(obj)
            obj.matrix_world = matrix
        components = item.find('m:components', ns)
        if components is not None:
            for component in components.findall('m:component', ns):
                linked = next((value for key, value in component.attrib.items() if key.endswith('}path')), document_name)
                linked = posixpath.normpath(linked.lstrip('/'))
                add_object(linked, component.get('objectid'), matrix @ transform(component.get('transform'), unit), parents + (identity,))

    main_name = entry.filename
    root, objects, unit = document(main_name)
    build = root.find('m:build', ns)
    items = build.findall('m:item', ns) if build is not None else []
    if items:
        for item in items:
            linked = next((value for key, value in item.attrib.items() if key.endswith('}path')), main_name)
            linked = posixpath.normpath(linked.lstrip('/'))
            add_object(linked, item.get('objectid'), transform(item.get('transform'), unit), ())
    else:
        for object_id, item in objects.items():
            if item.find('m:mesh', ns) is not None:
                add_object(main_name, object_id, Matrix.Identity(4), ())


def import_sources(sources):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    for source in sources:
        ext = Path(source).suffix.lower()
        if ext == '.blend':
            if len(sources) == 1:
                bpy.ops.wm.open_mainfile(filepath=source, load_ui=False)
            else:
                with bpy.data.libraries.load(source, link=False) as (available, imported):
                    imported.objects = available.objects
                for obj in imported.objects:
                    if obj is not None:
                        bpy.context.scene.collection.objects.link(obj)
        elif ext in ('.glb', '.gltf'):
            bpy.ops.import_scene.gltf(filepath=source)
        elif ext == '.stl':
            bpy.ops.wm.stl_import(filepath=source)
        elif ext == '.obj':
            bpy.ops.wm.obj_import(filepath=source)
        elif ext == '.fbx':
            bpy.ops.import_scene.fbx(filepath=source)
        elif ext == '.ply':
            bpy.ops.wm.ply_import(filepath=source)
        elif ext == '.3mf':
            import_3mf(source)


def clear_properties(block):
    try:
        for key in list(block.keys()):
            del block[key]
    except (AttributeError, TypeError):
        pass


def main():
    if '--' not in sys.argv:
        raise RuntimeError('Eingabe- oder Ausgabedatei fehlt.')
    args = sys.argv[sys.argv.index('--') + 1:]
    if len(args) != 2:
        raise RuntimeError('Eingabe- oder Ausgabedatei fehlt.')
    source, output = args
    if not os.path.exists(source) or os.path.exists(output):
        raise RuntimeError('Die Eingabedatei fehlt oder die Ausgabedatei existiert bereits.')

    sources, allowed_root = find_sources(source, output)
    import_sources(sources)
    bpy.context.view_layer.update()
    scene = bpy.context.scene
    models = [obj for obj in scene.objects if obj.type in GEOMETRY_TYPES]
    if not models and any(path.lower().endswith('.blend') for path in sources):
        models = [obj for obj in bpy.data.objects if obj.type in GEOMETRY_TYPES]
        for obj in models:
            scene.collection.objects.link(obj)
    if not models:
        raise RuntimeError('Das Modell enthält keine 3D-Geometrie.')

    # Animated models and rigs need their hierarchy; static models only need meshes.
    keep_hierarchy = bool(bpy.data.actions) or any(
        obj.type == 'ARMATURE' or obj.animation_data for obj in scene.objects
    )
    keep_types = GEOMETRY_TYPES | ({'ARMATURE', 'EMPTY'} if keep_hierarchy else set())
    kept = [obj for obj in scene.objects if obj.type in keep_types]
    kept_set = set(kept)
    for obj in kept:
        if obj.parent and obj.parent not in kept_set:
            matrix = obj.matrix_world.copy()
            obj.parent = None
            obj.matrix_world = matrix
    for obj in list(bpy.data.objects):
        if obj not in kept_set:
            bpy.data.objects.remove(obj, do_unlink=True)
    bpy.context.view_layer.update()

    mesh_index = armature_index = empty_index = 0
    for obj in kept:
        if obj.type in GEOMETRY_TYPES:
            mesh_index += 1
            name = 'Modell' if len(models) == 1 else f'Modell {mesh_index}'
        elif obj.type == 'ARMATURE':
            armature_index += 1
            name = f'Armatur {armature_index}'
        else:
            empty_index += 1
            name = f'Gruppe {empty_index}'
        obj.name = name
        if obj.data is not None:
            obj.data.name = name

    for i, material in enumerate(list(bpy.data.materials), start=1):
        material.name = 'Material' if len(bpy.data.materials) == 1 else f'Material {i}'
        if material.use_nodes and material.node_tree:
            clear_properties(material.node_tree)
            for node in material.node_tree.nodes:
                node.label = ''
                clear_properties(node)

    for i, image in enumerate(list(bpy.data.images), start=1):
        if image.source == 'FILE':
            if not image.packed_file:
                image_path = os.path.realpath(bpy.path.abspath(image.filepath, library=image.library))
                if os.path.commonpath((allowed_root, image_path)) != allowed_root:
                    raise RuntimeError('Eine Textur liegt außerhalb des Modellordners.')
                image.pack()
            ext = {'JPEG': '.jpg', 'PNG': '.png', 'WEBP': '.webp', 'OPEN_EXR': '.exr'}.get(image.file_format, '.png')
            image.filepath = f'//Textur_{i}{ext}'
        image.name = f'Textur {i}'
    # Images are packed explicitly above. Avoid re-reading their old paths on save.
    bpy.data.use_autopack = False

    for i, action in enumerate(list(bpy.data.actions), start=1):
        action.name = f'Animation {i}'
    for i, collection in enumerate(list(bpy.data.collections), start=1):
        collection.name = f'Sammlung {i}'
    for i, scene_item in enumerate(list(bpy.data.scenes), start=1):
        scene_item.name = 'Szene' if len(bpy.data.scenes) == 1 else f'Szene {i}'
    for text in list(bpy.data.texts):
        bpy.data.texts.remove(text)

    for collection_name in ('objects', 'meshes', 'curves', 'hair_curves', 'pointclouds', 'volumes', 'metaballs', 'materials', 'scenes', 'worlds', 'collections', 'node_groups', 'images', 'actions', 'armatures'):
        for block in getattr(bpy.data, collection_name, []):
            clear_properties(block)

    bpy.ops.object.select_all(action='DESELECT')
    for obj in models:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = models[0]

    corners = [obj.matrix_world @ Vector(corner) for obj in models for corner in obj.bound_box]
    if corners:
        minimum = [min(p[i] for p in corners) for i in range(3)]
        maximum = [max(p[i] for p in corners) for i in range(3)]
        center = [(minimum[i] + maximum[i]) / 2 for i in range(3)]
        size = max(maximum[i] - minimum[i] for i in range(3))
        if all(math.isfinite(value) for value in center) and math.isfinite(size):
            for screen in bpy.data.screens:
                for area in screen.areas:
                    if area.type == 'VIEW_3D':
                        area.spaces.active.region_3d.view_location = center
                        area.spaces.active.region_3d.view_distance = max(size * 1.8, 0.1)

    faces = sum(len(obj.data.polygons) for obj in models if obj.type == 'MESH')
    print(f'MODELL objects={len(models)} faces={faces}', flush=True)
    bpy.ops.wm.save_as_mainfile(filepath=output, compress=True)
    if not os.path.isfile(output) or os.path.getsize(output) == 0:
        raise RuntimeError('Die Blender-Datei konnte nicht gespeichert werden.')
    thumbnail = os.environ.get('STUDIOPORTAL_THUMBNAIL')
    if thumbnail and corners:
        try:
            render_thumbnail(models, corners, thumbnail)
        except Exception as error:  # the preview is optional; the .blend is already saved
            print('VORSCHAU_FEHLER', error, flush=True)


def render_thumbnail(models, corners, path):
    """Small Workbench preview for the StudioPortal library (after saving, so the .blend is unchanged)."""
    import numpy
    scene = bpy.context.scene
    meshes = [obj for obj in models if obj.type == 'MESH']
    points = []
    for obj in meshes:
        count = len(obj.data.vertices)
        if not count:
            continue
        coords = numpy.empty(count * 3, dtype=numpy.float64)
        obj.data.vertices.foreach_get('co', coords)
        coords = coords.reshape(-1, 3)
        matrix = numpy.array(obj.matrix_world)
        points.append(coords @ matrix[:3, :3].T + matrix[:3, 3])
    if points:
        # trim stray fragments so the preview frames the actual model
        points = numpy.concatenate(points)
        low, high = numpy.percentile(points, 0.5, axis=0), numpy.percentile(points, 99.5, axis=0)
    else:
        low = numpy.array([min(p[i] for p in corners) for i in range(3)])
        high = numpy.array([max(p[i] for p in corners) for i in range(3)])
    box = [Vector((x, y, z)) for x in (low[0], high[0]) for y in (low[1], high[1]) for z in (low[2], high[2])]
    center = (Vector(low) + Vector(high)) / 2
    camera_data = bpy.data.cameras.new('Vorschau')
    camera_data.lens = 50
    camera_data.sensor_fit = 'AUTO'
    camera = bpy.data.objects.new('Vorschau', camera_data)
    scene.collection.objects.link(camera)
    direction = Vector((0.55, -1.0, 0.45)).normalized()
    forward = -direction
    right = forward.cross(Vector((0, 0, 1))).normalized()
    up = right.cross(forward).normalized()
    tangent = math.tan(camera_data.angle / 2)
    distance = 1e-3
    for corner in box:
        offset = corner - center
        depth = offset.dot(direction)
        distance = max(distance, depth + abs(offset.dot(right)) / tangent, depth + abs(offset.dot(up)) / tangent)
    distance *= 1.08
    camera.location = center + direction * distance
    camera.rotation_euler = (center - camera.location).to_track_quat('-Z', 'Y').to_euler()
    camera_data.clip_start = distance / 1000
    camera_data.clip_end = distance * 10
    scene.camera = camera
    scene.render.engine = 'BLENDER_WORKBENCH'
    scene.render.resolution_x = scene.render.resolution_y = 512
    scene.render.resolution_percentage = 100
    scene.render.film_transparent = True
    scene.render.image_settings.file_format = 'PNG'
    shading = scene.display.shading
    shading.light = 'STUDIO'
    if any(len(obj.data.color_attributes) for obj in meshes):
        shading.color_type = 'VERTEX'
    elif any(image.source == 'FILE' for image in bpy.data.images):
        shading.color_type = 'TEXTURE'
    else:
        shading.color_type = 'MATERIAL'
    scene.render.filepath = path
    bpy.ops.render.render(write_still=True)


def thumbnail_only(path):
    """Preview for a .blend that has none (opened by Blender from the command line): visible meshes, Workbench, 512 px."""
    models = [obj for obj in bpy.context.scene.objects if obj.type == 'MESH' and not obj.hide_render and len(obj.data.vertices)]
    if not models:
        raise RuntimeError('keine sichtbaren Meshes')
    corners = [obj.matrix_world @ Vector(corner) for obj in models for corner in obj.bound_box]
    render_thumbnail(models, corners, path)


if '--thumbnail-only' in sys.argv:
    position = sys.argv.index('--thumbnail-only')
    if len(sys.argv) > position + 2:  # a .glb/.fbx/.obj: import it into the empty factory scene first
        bpy.ops.object.select_all(action='SELECT')
        bpy.ops.object.delete()
        import_sources([sys.argv[position + 2]])
    thumbnail_only(sys.argv[position + 1])
else:
    main()
