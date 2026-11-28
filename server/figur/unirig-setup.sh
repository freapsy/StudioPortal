#!/bin/bash
# UniRig CPU environment in our own folder (no GPU: spconv/torch_scatter have no ROCm builds)
set -x
F=$HOME/.local/share/3d-modelle-app/figur
U=$F/unirig
cd $U
# checkpoints (retry the one that failed on DNS)
HF_HOME=$F/hf hf download VAST-AI/UniRig skeleton/articulation-xl_quantization_256/model.ckpt skin/articulation-xl/model.ckpt
SNAP=$(ls -d $F/hf/hub/models--VAST-AI--UniRig/snapshots/*/ | head -1)
mkdir -p experiments/skeleton/articulation-xl_quantization_256 experiments/skin/articulation-xl
ln -sf $SNAP/skeleton/articulation-xl_quantization_256/model.ckpt experiments/skeleton/articulation-xl_quantization_256/model.ckpt
ln -sf $SNAP/skin/articulation-xl/model.ckpt experiments/skin/articulation-xl/model.ckpt
# CPU configs
sed -e 's/_attn_implementation: flash_attention_2/_attn_implementation: sdpa/' -e 's/flash: True/flash: False/' configs/model/unirig_ar_350m_1024_81920_float32.yaml > configs/model/unirig_ar_cpu.yaml
sed -e 's/flash: True/flash: False/' configs/model/unirig_skin.yaml > configs/model/unirig_skin_cpu.yaml
sed -e 's/model: unirig_ar_350m_1024_81920_float32/model: unirig_ar_cpu/' -e 's/precision: bf16-mixed/precision: 32/' -e 's/accelerator: gpu/accelerator: cpu/' configs/task/quick_inference_skeleton_articulationxl_ar_256.yaml > configs/task/cpu_skeleton.yaml
sed -e 's/model: unirig_skin$/model: unirig_skin_cpu/' -e 's/precision: bf16-mixed/precision: 32/' -e 's/accelerator: gpu/accelerator: cpu/' configs/task/quick_inference_unirig_skin.yaml > configs/task/cpu_skin.yaml
grep -n "model:\|accelerator\|precision" configs/task/cpu_skeleton.yaml configs/task/cpu_skin.yaml
# venv
UV=$HOME/.local/bin/uv
$UV venv -q --python 3.11 $F/unirig-venv
P=$F/unirig-venv/bin/python
$UV pip install -q --python $P torch==2.5.1 torchvision==0.20.1 --index-url https://download.pytorch.org/whl/cpu
$UV pip install -q --python $P torch_scatter torch_cluster -f https://data.pyg.org/whl/torch-2.5.1+cpu.html
$UV pip install -q --python $P spconv cumm
$UV pip install -q --python $P bpy==4.2.0 "numpy<2"
$UV pip install -q --python $P transformers==4.51.3 python-box einops omegaconf pytorch_lightning lightning addict timm fast-simplification trimesh huggingface_hub scipy
$P -c "import torch, torch_scatter, torch_cluster, spconv.pytorch, bpy, lightning; print('UNIRIG-ENV OK', torch.__version__, bpy.app.version_string)"
du -sh $F/unirig-venv
echo ENDE
