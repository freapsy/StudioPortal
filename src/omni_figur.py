"""Hunyuan3D-Omni on bigki: one image of a person → untextured 3D figure in a given pose (default A-pose).

Runs in figur/omni-venv (torch from the shared ROCm install) on the card(s) the StudioPortal broker granted.
    python omni_figur.py --image bild.png --output figur.glb [--pose a|hand-hoch|arme-hoch|knochen.txt]
           [--steps 50] [--octree 512] [--guidance 4.5] [--seed 1234]
Pose files: one bone per line "x1 y1 z1 x2 y2 z2" in Omni's normalised space (Y up, figure about -1…1).
Hunyuan3D-Omni licence: Tencent Hunyuan 3D Omni Community License (not for use in the EU, UK, South Korea).
"""
import argparse
import os
import sys
import time
import warnings

warnings.filterwarnings('ignore')
HERE = os.path.dirname(os.path.abspath(__file__))
FIGUR = os.path.join(os.path.dirname(HERE), 'figur')
OMNI = os.path.join(FIGUR, 'omni')
sys.path.insert(0, OMNI)
POSES = {'a': 'a_pose_bone.txt', 'hand-hoch': 'handup_pose_bone.txt', 'arme-hoch': 'sky_pose_bone.txt'}


def model_dir():
    snapshots = os.path.join(FIGUR, 'hf', 'hub', 'models--tencent--Hunyuan3D-Omni', 'snapshots')
    for name in sorted(os.listdir(snapshots)):
        path = os.path.join(snapshots, name)
        if os.path.isfile(os.path.join(path, 'model', 'pytorch_model.bin')):
            return path
    raise SystemExit('Hunyuan3D-Omni-Gewichte fehlen.')


def cut_out(path, work):
    """RGBA with the person cut out (rembg) unless the image already has a useful alpha channel."""
    from PIL import Image
    image = Image.open(path)
    if image.mode == 'RGBA' and image.getchannel('A').getextrema()[0] < 250:
        return path
    from rembg import new_session, remove
    session = new_session('u2net')
    cut = remove(image.convert('RGB'), session=session)
    target = os.path.join(work, 'freigestellt.png')
    cut.save(target)
    return target


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--image', required=True)
    parser.add_argument('--output', required=True)
    parser.add_argument('--pose', default='a')
    parser.add_argument('--steps', type=int, default=50)
    parser.add_argument('--octree', type=int, default=512)
    parser.add_argument('--guidance', type=float, default=4.5)
    parser.add_argument('--seed', type=int, default=1234)
    # FlashVDM: only voxels near the surface are decoded (plain torch, works on gfx906); the full 512³ grid with
    # math attention takes far over 30 min on one MI50
    parser.add_argument('--full-decode', action='store_true')
    parser.add_argument('--chunks', type=int, default=20000)
    args = parser.parse_args()

    import numpy as np
    import torch
    # Omni forces flash/mem-efficient attention (enable_math=False); the MI50 (gfx906) has neither kernel,
    # so the plain math path stays allowed as fallback.
    _sdp_kernel = torch.backends.cuda.sdp_kernel

    def sdp_kernel_with_math(enable_flash=True, enable_math=True, enable_mem_efficient=True, **_):
        return _sdp_kernel(enable_flash=enable_flash, enable_math=True, enable_mem_efficient=enable_mem_efficient)
    torch.backends.cuda.sdp_kernel = sdp_kernel_with_math
    from hy3dshape.pipelines import Hunyuan3DOmniSiTFlowMatchingPipeline
    from hy3dshape.postprocessors import DegenerateFaceRemover, FloaterRemover

    pose_file = os.path.join(OMNI, 'demos', 'pose', POSES[args.pose]) if args.pose in POSES else args.pose
    bones = np.loadtxt(pose_file, dtype=np.float32).reshape(-1, 6)
    work = os.path.dirname(os.path.abspath(args.output))
    image = cut_out(args.image, work)
    print('PHASE Bild freigestellt', flush=True)

    start = time.time()
    pipeline = Hunyuan3DOmniSiTFlowMatchingPipeline.from_pretrained(model_dir(), device='cuda', dtype=torch.float16)
    print(f'Model loaded in {time.time() - start:.0f} s', flush=True)
    pose = torch.from_numpy(bones).to(pipeline.device).to(pipeline.dtype).unsqueeze(0)
    result = pipeline(image=image, pose=pose, num_inference_steps=args.steps, octree_resolution=args.octree,
                      mc_level=0, guidance_scale=args.guidance,
                      fast_decode=not args.full_decode, num_chunks=args.chunks,
                      generator=torch.Generator('cuda').manual_seed(args.seed))
    mesh = result['shapes'][0][0]
    mesh = FloaterRemover()(mesh)
    mesh = DegenerateFaceRemover()(mesh)
    mesh.export(args.output)
    print(f'FERTIG {len(mesh.vertices)} Punkte, {len(mesh.faces)} Dreiecke in {time.time() - start:.0f} s', flush=True)


if __name__ == '__main__':
    main()
