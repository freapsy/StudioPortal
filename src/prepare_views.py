#!/usr/bin/env python3
"""Prepare the selected views using the already installed CPU background remover."""
import os
import sys
from pathlib import Path

from PIL import Image, ImageOps

Image.MAX_IMAGE_PIXELS = 60_000_000
VIEWS = ('front', 'left', 'back', 'right')
root = Path(sys.argv[1])
source = root / 'input'
destination = root / 'views'
destination.mkdir(exist_ok=False)
session = None

for view in VIEWS:
    original = source / (view + '.image')
    if not original.is_file():
        continue
    with Image.open(original) as opened:
        image = ImageOps.exif_transpose(opened).convert('RGBA')
        image.thumbnail((2048, 2048), Image.Resampling.LANCZOS)
    if image.getchannel('A').getextrema()[0] >= 250:
        weights = Path(os.environ['U2NET_HOME']) / 'isnet-general-use.onnx'
        if not weights.is_file():
            raise RuntimeError('Das lokale Modell zum Freistellen fehlt.')
        if session is None:
            from rembg import new_session, remove
            session = new_session('isnet-general-use', providers=['CPUExecutionProvider'])
        image = remove(image.convert('RGB'), session=session)
    alpha = image.getchannel('A')
    if not alpha.getbbox():
        raise RuntimeError(f'Auf dem Bild {view} wurde kein Motiv gefunden.')
    with (destination / (view + '.png')).open('xb') as output:
        image.save(output, format='PNG')
    print('Prepared ' + view, flush=True)
