# blender -b scene.blend [-o out/####] [-s A -e B] --python anim_setup.py -a  (-o/-s/-e before --python)
# env BENCH_DEV=HIP|HIP0|HIP1|CPU, BENCH_SET as in bench2.py. Only sets things up; -a renders. The .blend is never saved.
import bpy, os
s = bpy.context.scene
p = bpy.context.preferences.addons['cycles'].preferences
typ = os.environ.get('BENCH_DEV', 'HIP')
if typ == 'CPU':
    s.cycles.device = 'CPU'
else:
    p.compute_device_type = 'HIP'; p.get_devices()
    hips = [d for d in p.devices if d.type == 'HIP']
    for d in p.devices: d.use = False
    for i, d in enumerate(hips): d.use = typ == 'HIP' or typ == f'HIP{i}'
    s.cycles.device = 'GPU'
for kv in filter(None, os.environ.get('BENCH_SET', '').split(';')):
    k, v = kv.split('=', 1)
    obj, attr = s, k.strip()
    while '.' in attr:
        head, attr = attr.split('.', 1); obj = getattr(obj, head)
    setattr(obj, attr, eval(v))
    print('SET', k.strip(), '=', getattr(obj, attr), flush=True)
# ANIM_CLEAN=1 (a run without -a, before the render instances): frames left as empty placeholders by an aborted run
# are rendered again
if os.environ.get('ANIM_CLEAN') == '1':
    for f in range(s.frame_start, s.frame_end + 1):
        p = bpy.path.abspath(s.render.frame_path(frame=f))
        if os.path.isfile(p) and os.path.getsize(p) == 0:
            os.remove(p); print('placeholder removed', p, flush=True)
