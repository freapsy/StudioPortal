cd $HOME/.local/share/3d-modelle-app/figur/omni
~/.local/bin/uv pip install -q --python $HOME/.local/share/3d-modelle-app/figur/omni-venv/bin/python --no-deps pytorch_lightning==2.5.5 torchmetrics timm torchdiffeq
$HOME/.local/share/3d-modelle-app/figur/omni-venv/bin/python -c "import torch; print(torch.__version__, torch.cuda.device_count()); from hy3dshape.pipelines import Hunyuan3DOmniSiTFlowMatchingPipeline; print(\"pipeline import ok\")"
echo FERTIG
