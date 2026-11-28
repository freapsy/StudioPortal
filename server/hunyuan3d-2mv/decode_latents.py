#!/usr/bin/env python3
"""Decode saved Hunyuan3D latents at a chosen surface resolution."""
import argparse
import os
from pathlib import Path
import ssl  # Load system OpenSSL before optional PyMeshLab plugins.
import sys
import time

ROOT = Path(__file__).resolve().parent

def positive(value):
    number = int(value)
    if number <= 0:
        raise argparse.ArgumentTypeError("must be a positive integer")
    return number

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--latents", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--model", choices=("standard", "turbo"), default="standard")
    parser.add_argument("--resolution", type=positive, required=True)
    parser.add_argument("--num-chunks", type=positive, default=10000)
    parser.add_argument("--gpus", type=int, choices=(1, 3), default=1)
    parser.add_argument("--kv-cache", action="store_true", help="reuse identical cross-attention key/value projections for this one mesh")
    parser.add_argument("--fast-dilation", action="store_true", help="use equivalent binary max-pooling for spatial dilation")
    args = parser.parse_args()
    if not args.latents.is_file():
        parser.error("latent file does not exist")
    if args.output.suffix.lower() != ".glb" or args.output.exists():
        parser.error("output must be a new .glb file")

    folder = "hunyuan3d-dit-v2-mv" + ("-turbo" if args.model == "turbo" else "")
    model_dir = ROOT / "models" / folder
    checkpoint = model_dir / "model.fp16.safetensors"
    config_path = model_dir / "config.yaml"
    if not checkpoint.is_file() or not config_path.is_file():
        parser.error("local model checkpoint or configuration is missing")

    os.environ["HF_HUB_OFFLINE"] = "1"
    os.environ["TRANSFORMERS_OFFLINE"] = "1"
    sys.path.insert(0, str(ROOT / "src"))
    import numpy as np
    import torch
    import yaml
    from safetensors import safe_open
    from safetensors.torch import load_file
    from hy3dgen.shapegen.pipelines import instantiate_from_config, export_to_trimesh

    if not torch.cuda.is_available():
        raise RuntimeError("MI50/ROCm device unavailable")
    if torch.cuda.device_count() < args.gpus:
        raise RuntimeError(f"requested {args.gpus} MI50 GPUs, found {torch.cuda.device_count()}")
    if args.gpus == 3:
        for device in range(3):
            properties = torch.cuda.get_device_properties(device)
            arch = getattr(properties, "gcnArchName", "gfx906")
            if properties.total_memory < 30 * 2**30 or not arch.startswith("gfx906"):
                raise RuntimeError(f"device {device} is not an expected 32 GB gfx906 MI50: {properties}")
    start = time.monotonic()
    config = yaml.safe_load(config_path.read_text())
    with safe_open(str(args.latents), framework="pt", device="cpu") as latent_file:
        metadata = latent_file.metadata() or {}
    if metadata.get("model") and metadata["model"] != args.model:
        raise ValueError(f"latent file uses model {metadata['model']}, not {args.model}")
    latent_data = load_file(str(args.latents), device="cpu")
    expected_shape = (1, config["vae"]["params"]["num_latents"], config["vae"]["params"]["embed_dim"])
    if set(latent_data) != {"latents"} or tuple(latent_data["latents"].shape) != expected_shape:
        raise ValueError(f"expected one latent tensor with shape {expected_shape}")
    if not torch.isfinite(latent_data["latents"]).all().item():
        raise ValueError("latent tensor contains non-finite values")

    vae = instantiate_from_config(config["vae"])
    with safe_open(str(checkpoint), framework="pt", device="cpu") as weights:
        state = {key[4:]: weights.get_tensor(key) for key in weights.keys() if key.startswith("vae.")}
    missing, unexpected = vae.load_state_dict(state, strict=False)
    unknown_missing = [key for key in missing if not key.startswith(("encoder.", "pre_kl."))]
    if unknown_missing or unexpected:
        raise RuntimeError(f"VAE weights incompatible: missing={unknown_missing[:5]}, unexpected={unexpected[:5]}")
    del state
    del vae.encoder, vae.pre_kl
    vae.eval().to(device="cuda", dtype=torch.float16)
    if args.kv_cache:
        attention = vae.geo_decoder.cross_attn_decoder.attn
        attention.data = None
        attention.kv_cache = True
        print("Reusing fixed cross-attention key/value projections within this mesh", flush=True)
    vae.enable_flashvdm_decoder(enabled=True, adaptive_kv_selection=False, mc_algo="mc")
    latents = latent_data["latents"].to(device="cuda", dtype=torch.float16)
    print(f"Loaded saved {args.model} latents and VAE on {torch.cuda.get_device_name(0)}; surface resolution={args.resolution}", flush=True)
    with torch.inference_mode():
        decoded = vae(latents / vae.scale_factor)
        if not torch.isfinite(decoded).all().item():
            raise RuntimeError("VAE produced non-finite values")
        if args.gpus == 3:
            import copy
            class ParallelGeoDecoder(torch.nn.Module):
                def __init__(self, original, context):
                    super().__init__()
                    self.devices = [torch.device(f"cuda:{i}") for i in range(3)]
                    self.replicas = torch.nn.ModuleList(
                        [original] + [copy.deepcopy(original).to(device) for device in self.devices[1:]]
                    )
                    self.contexts = [context] + [context.to(device) for device in self.devices[1:]]
                    self.calls = [0, 0, 0]
                    self.next_device = 0
                    sample = torch.linspace(-0.9, 0.9, 192, device=self.devices[0], dtype=context.dtype).reshape(1, 64, 3)
                    reference = self.replicas[0](queries=sample, latents=self.contexts[0]).cpu()
                    for i in (1, 2):
                        result = self.replicas[i](queries=sample.to(self.devices[i]), latents=self.contexts[i]).cpu()
                        if not torch.equal(result, reference):
                            difference = (result.float() - reference.float()).abs().max().item()
                            raise RuntimeError(f"MI50 {i} differs from MI50 0 in decoder self-test: max {difference}")
                    print("Three MI50 decoder replicas passed exact-output self-test", flush=True)

                def _decode(self, index, queries):
                    with torch.inference_mode(), torch.cuda.device(self.devices[index]):
                        local_queries = queries.to(self.devices[index], dtype=self.contexts[index].dtype)
                        values = self.replicas[index](queries=local_queries, latents=self.contexts[index])
                        torch.cuda.synchronize(self.devices[index])
                        return values.to(self.devices[0])

                def decode_batches(self, points, num_chunks, description):
                    from concurrent.futures import ThreadPoolExecutor
                    from tqdm import tqdm
                    if self.contexts[0].shape[0] != 1:
                        raise RuntimeError("parallel decoder currently supports one sample")
                    torch.cuda.synchronize(self.devices[0])
                    results, pending = [], []
                    with ThreadPoolExecutor(max_workers=3) as pool:
                        for n, start in enumerate(tqdm(range(0, points.shape[0], num_chunks), desc=description)):
                            index = n % 3
                            self.calls[index] += 1
                            query = points[start:start + num_chunks].unsqueeze(0)
                            pending.append(pool.submit(self._decode, index, query))
                            if len(pending) == 3:
                                results.extend(future.result() for future in pending)
                                pending.clear()
                        results.extend(future.result() for future in pending)
                    return results

            vae.geo_decoder = ParallelGeoDecoder(vae.geo_decoder, decoded)
        if args.fast_dilation:
            import torch.nn.functional as functional
            probe = torch.zeros((1, 1, 13, 14, 15), device="cuda", dtype=torch.float16)
            probe[0, 0, 0, 0, 0] = 2
            probe[0, 0, 5, 7, 9] = 1
            probe[0, 0, -1, -1, -1] = 1
            weights = torch.ones((1, 1, 3, 3, 3), device="cuda", dtype=torch.float16)
            dense, pooled = probe, probe
            for _ in range(2):
                dense = functional.conv3d(dense, weights, padding=1)
                pooled = functional.max_pool3d(pooled, 3, stride=1, padding=1)
                if not torch.equal(dense > 0, pooled > 0):
                    raise RuntimeError("binary dilation differs from original GPU convolution")
            vae.geo_decoder.fast_binary_dilation = True
            print("Equivalent binary max-pooling passed GPU support self-test", flush=True)
        outputs = vae.latents2mesh(decoded, bounds=1.01, mc_level=0.0, num_chunks=args.num_chunks,
                                   octree_resolution=args.resolution, mc_algo="mc", enable_pbar=True)
        meshes = export_to_trimesh(outputs)
    if not meshes or meshes[0] is None or meshes[0].is_empty:
        raise RuntimeError("decoder did not produce a mesh")
    mesh = meshes[0]
    if not np.isfinite(mesh.vertices).all():
        raise RuntimeError("mesh contains non-finite vertices")
    mesh.update_faces((mesh.area_faces > 1e-12) & mesh.unique_faces())
    mesh.remove_unreferenced_vertices()
    if mesh.is_empty:
        raise RuntimeError("mesh has no valid faces after cleanup")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("xb") as out:
        out.write(mesh.export(file_type="glb"))
    torch.cuda.synchronize()
    peaks = [round(torch.cuda.max_memory_allocated(i) / 2**30, 2) for i in range(args.gpus)]
    if args.gpus == 3:
        print(f"Decoder chunks by MI50: {vae.geo_decoder.calls}", flush=True)
    print(f"Saved {args.output}: {len(mesh.vertices)} vertices, {len(mesh.faces)} faces, "
          f"{time.monotonic() - start:.2f}s, peak allocated GiB {peaks}", flush=True)

if __name__ == "__main__":
    main()

