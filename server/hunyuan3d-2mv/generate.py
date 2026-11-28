#!/usr/bin/env python3
"""Generate an untextured Hunyuan3D-2mv mesh from local views."""
import argparse
import math
import os
from pathlib import Path
import ssl  # Load system OpenSSL before optional PyMeshLab plugins.
import sys
import time

ROOT = Path(__file__).resolve().parent
MODELS = {
    'standard': ('hunyuan3d-dit-v2-mv', 30),
    'turbo': ('hunyuan3d-dit-v2-mv-turbo', 5),
}

def positive(value):
    number = int(value)
    if number <= 0:
        raise argparse.ArgumentTypeError('must be a positive integer')
    return number

def main():
    parser = argparse.ArgumentParser(description='Generate an untextured 3D mesh from one or more object views.')
    for view in ('front', 'left', 'back', 'right'):
        parser.add_argument('--' + view, type=Path, help=f'{view} view image')
    parser.add_argument('--output', '-o', type=Path, help='new .glb, .ply or .obj file')
    parser.add_argument('--latent-only', action='store_true', help='save latent data without extracting a mesh')
    parser.add_argument('--model', choices=MODELS, default='standard')
    parser.add_argument('--steps', type=positive, help='default: standard 30, turbo 5')
    parser.add_argument('--resolution', type=positive, default=380, help='surface resolution (default: 380)')
    parser.add_argument('--num-chunks', type=positive, default=20000, help='surface decoding chunk size (default: 20000)')
    parser.add_argument('--decoder', choices=('hierarchical', 'dense'), default='hierarchical', help='surface decoding method (default: hierarchical)')
    parser.add_argument('--guidance', type=float, default=5.0)
    parser.add_argument('--seed', type=int, default=12345)
    parser.add_argument('--save-latents', type=Path, help='optional new .safetensors file for diagnostics')
    args = parser.parse_args()
    views = {name: getattr(args, name) for name in ('front', 'left', 'back', 'right') if getattr(args, name) is not None}
    if not views:
        parser.error('provide at least one of --front, --left, --back, --right')
    for name, path in views.items():
        if not path.is_file():
            parser.error(f'{name} image not found: {path}')
    if args.latent_only:
        if not args.save_latents or args.output:
            parser.error('--latent-only requires --save-latents and does not use --output')
    else:
        if not args.output or args.output.suffix.lower() not in ('.glb', '.ply', '.obj'):
            parser.error('output must end in .glb, .ply or .obj')
        if args.output.exists():
            parser.error(f'output already exists: {args.output}')
    if args.save_latents and (args.save_latents.suffix != '.safetensors' or args.save_latents.exists()):
        parser.error('latent output must be a new .safetensors file')
    if not math.isfinite(args.guidance):
        parser.error('guidance must be finite')
    folder, default_steps = MODELS[args.model]
    model_dir = ROOT / 'models' / folder
    model = model_dir / 'model.fp16.safetensors'
    config = model_dir / 'config.yaml'
    if not model.is_file() or not config.is_file():
        parser.error(f'model files missing in {model_dir}; obtain approval before downloading large weights')

    os.environ['HF_HUB_OFFLINE'] = '1'
    os.environ['TRANSFORMERS_OFFLINE'] = '1'
    sys.path.insert(0, str(ROOT / 'src'))
    import torch
    from PIL import Image
    from hy3dgen.shapegen import Hunyuan3DDiTFlowMatchingPipeline

    images = {}
    for name, path in views.items():
        with Image.open(path) as image:
            if 'A' not in image.getbands():
                print(f'Warning: {name} has no alpha channel; a clean transparent background is recommended.', file=sys.stderr)
            images[name] = image.convert('RGBA').copy()
    if not torch.cuda.is_available():
        raise RuntimeError('MI50/ROCm device unavailable')
    start = time.monotonic()
    print(f'Loading {args.model} on {torch.cuda.get_device_name(0)}; views={list(images)}', flush=True)
    pipeline = Hunyuan3DDiTFlowMatchingPipeline.from_single_file(
        ckpt_path=str(model), config_path=str(config), device='cuda', dtype=torch.float16, use_safetensors=True)
    print(f'Model loaded in {time.monotonic() - start:.2f}s', flush=True)
    if args.decoder == 'hierarchical':
        pipeline.vae.enable_flashvdm_decoder(enabled=True, adaptive_kv_selection=False, mc_algo='mc')
    generator = torch.Generator(device='cpu').manual_seed(args.seed)
    steps = args.steps or default_steps
    def check_step(i, timestep, scheduler_output):
        latents = scheduler_output.prev_sample
        if not torch.isfinite(latents).all().item():
            raise RuntimeError(f'non-finite latent values after step {i + 1}')
        if i == steps - 1 and args.save_latents:
            from safetensors.torch import save
            args.save_latents.parent.mkdir(parents=True, exist_ok=True)
            with args.save_latents.open('xb') as out:
                out.write(save({'latents': latents.detach().to('cpu').contiguous()},
                               metadata={'model': args.model, 'steps': str(steps), 'seed': str(args.seed)}))
            print(f'Saved diagnostic latents: {args.save_latents}', flush=True)
    results = pipeline(image=images, num_inference_steps=steps,
                       guidance_scale=args.guidance, generator=generator,
                       octree_resolution=args.resolution, num_chunks=args.num_chunks,
                       callback=check_step, callback_steps=1,
                       mc_algo='mc', output_type='latent' if args.latent_only else 'trimesh')
    if args.latent_only:
        if not args.save_latents.is_file() or not torch.isfinite(results).all().item():
            raise RuntimeError('latent output was not saved or is non-finite')
        torch.cuda.synchronize()
        print(f'Latents complete in {time.monotonic() - start:.2f}s', flush=True)
        return
    if not results or results[0] is None or results[0].is_empty:
        raise RuntimeError('model did not produce a non-empty mesh')
    mesh = results[0]
    import numpy as np
    if not np.isfinite(mesh.vertices).all():
        raise RuntimeError('mesh contains non-finite vertices')
    mesh.update_faces((mesh.area_faces > 1e-12) & mesh.unique_faces())
    mesh.remove_unreferenced_vertices()
    if mesh.is_empty:
        raise RuntimeError('mesh has no valid faces after cleanup')
    data = mesh.export(file_type=args.output.suffix.lower()[1:])
    if isinstance(data, str):
        data = data.encode('utf-8')
    if not isinstance(data, bytes) or not data:
        raise RuntimeError('mesh export returned no data')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open('xb') as out:
        out.write(data)
    torch.cuda.synchronize()
    print(f'Saved {args.output}: {len(mesh.vertices)} vertices, {len(mesh.faces)} faces, '
          f'{len(data)} bytes, {time.monotonic() - start:.2f}s; untextured', flush=True)

if __name__ == '__main__':
    main()
