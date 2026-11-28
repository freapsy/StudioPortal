#!/bin/bash
# StudioPortal figure pipeline: fetch Hunyuan3D-Omni + UniRig (only the needed files) into our own dir.
set -u
B=$HOME/.local/share/3d-modelle-app/figur
mkdir -p "$B"; cd "$B"
export HF_HOME=$B/hf
echo "start $(date)"
[ -d omni ] || git clone --depth 1 https://github.com/Tencent-Hunyuan/Hunyuan3D-Omni omni
[ -d unirig ] || git clone --depth 1 https://github.com/VAST-AI-Research/UniRig unirig
hf download VAST-AI/UniRig --include "skeleton/articulation-xl_quantization_256/*" "skin/articulation-xl/*" "*.json" "*.yaml" "*.md" && echo "unirig ok"
hf download tencent/Hunyuan3D-Omni --exclude "model/pytorch_model_ema.bin" && echo "omni ok"
df -h / | tail -1
echo "ende $(date)"
