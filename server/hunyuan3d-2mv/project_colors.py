#!/usr/bin/env python3
"""Project four transparent object views onto an existing mesh as vertex colors."""
import argparse
from pathlib import Path

import cv2
import numpy as np
from PIL import Image
from scipy.spatial import cKDTree
import trimesh

def colorize(mesh, image_dir, head_align=False):
    vertices = np.asarray(mesh.vertices)
    normals = np.asarray(mesh.vertex_normals)
    if not len(vertices) or not np.isfinite(vertices).all() or not np.isfinite(normals).all():
        raise ValueError("Mesh needs finite vertices and normals")
    up = np.array([0., 1., 0.])
    views = {
        "front": np.array([0., 0., 1.]),
        "left":  np.array([1., 0., 0.]),
        "back":  np.array([0., 0., -1.]),
        "right": np.array([-1., 0., 0.]),
    }
    color_sum = np.zeros((len(vertices), 3), dtype=np.float64)
    weight_sum = np.zeros(len(vertices), dtype=np.float64)
    depth_tolerance = max(mesh.extents) * 0.018

    for name, direction in views.items():
        path = image_dir / f"{name}.png"
        with Image.open(path) as im:
            rgba = np.asarray(im.convert("RGBA"))
        mask = rgba[:, :, 3] >= 128
        ys, xs = np.where(mask)
        if not len(xs):
            raise ValueError(f"No foreground in {path}")
        x0, x1, y0, y1 = xs.min(), xs.max(), ys.min(), ys.max()
        right = np.cross(up, direction)
        u, v, depth = vertices @ right, vertices @ up, vertices @ direction
        if np.ptp(u) == 0 or np.ptp(v) == 0:
            raise ValueError("Degenerate mesh projection")
        x = x0 + (u - u.min()) / np.ptp(u) * (x1 - x0)
        head_blend = np.zeros(len(vertices))
        if head_align:
            span = np.ptp(v)
            top = v.max() - 0.20 * span
            head = v >= top
            image_head_x = xs[ys <= y0 + 0.20 * (y1 - y0)]
            if head.any() and len(image_head_x) and np.ptp(u[head]) > 0:
                head_blend = np.clip((v - (top - 0.07 * span)) / (0.07 * span), 0, 1)
                head_x = image_head_x.min() + (u - u[head].min()) / np.ptp(u[head]) * np.ptp(image_head_x)
                x = x * (1 - head_blend) + head_x * head_blend
        x = np.rint(np.clip(x, 0, mask.shape[1] - 1)).astype(np.int32)
        y = np.rint(y1 - (v - v.min()) / np.ptp(v) * (y1 - y0)).astype(np.int32)

        h, w = mask.shape
        depth_buffer = np.full((h, w), -1e6, dtype=np.float32)
        np.maximum.at(depth_buffer, (y, x), depth.astype(np.float32))
        depth_buffer = cv2.dilate(depth_buffer, np.ones((3, 3), dtype=np.uint8))
        visible = depth >= depth_buffer[y, x] - depth_tolerance
        facing = np.clip(normals @ direction, 0, 1) ** (2 + 4 * head_blend)
        weight = facing * visible * (rgba[y, x, 3] >= 250)
        color_sum += rgba[y, x, :3] * weight[:, None]
        weight_sum += weight

    colored = weight_sum > 1e-6
    if colored.sum() < len(vertices) // 10:
        raise RuntimeError("Too few vertices received colors")
    rgb = np.empty((len(vertices), 3), dtype=np.uint8)
    rgb[colored] = np.clip(color_sum[colored] / weight_sum[colored, None], 0, 255).astype(np.uint8)
    if (~colored).any():
        nearest = cKDTree(vertices[colored]).query(vertices[~colored], workers=1)[1]
        rgb[~colored] = rgb[colored][nearest]
    print(f"Projected colors onto {colored.sum()}/{len(vertices)} vertices; remaining colors use nearest surface", flush=True)
    srgb = rgb.astype(np.float32) / 255.0
    linear = np.where(srgb <= 0.04045, srgb / 12.92, ((srgb + 0.055) / 1.055) ** 2.4)
    mesh.visual = trimesh.visual.ColorVisuals(mesh=mesh, vertex_colors=np.rint(linear * 255).astype(np.uint8))
    return mesh

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("mesh", type=Path)
    parser.add_argument("image_dir", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--head-align", action="store_true", help="align the head separately for a human subject")
    args = parser.parse_args()
    if args.output.suffix.lower() != ".glb":
        parser.error("output must be a new .glb file")
    mesh = colorize(trimesh.load(args.mesh, force="mesh"), args.image_dir, args.head_align)
    with args.output.open("xb") as out:
        out.write(mesh.export(file_type="glb"))

if __name__ == "__main__":
    main()

