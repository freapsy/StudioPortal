"""Create original, transparent test views of a simple toy robot."""
from pathlib import Path
from PIL import Image, ImageDraw

destination = Path('/tmp/modelle-robot-test')
destination.mkdir(exist_ok=True)
for view in ('front', 'left', 'back', 'right'):
    image = Image.new('RGBA', (512, 512), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    side = view in ('left', 'right')
    width = 70 if side else 112
    center = 256
    draw.rounded_rectangle((center-width-26, 205, center-width+4, 358), 12, fill='#e99b34')
    draw.rounded_rectangle((center+width-4, 205, center+width+26, 358), 12, fill='#e99b34')
    draw.rounded_rectangle((center-width, 175, center+width, 365), 16, fill='#3f82aa')
    draw.rounded_rectangle((center-75, 354, center-20, 475), 12, fill='#424b57')
    draw.rounded_rectangle((center+20, 354, center+75, 475), 12, fill='#424b57')
    draw.rounded_rectangle((center-80 if not side else center-60, 68,
                            center+80 if not side else center+60, 191), 25, fill='#e8c04e')
    if view == 'front':
        draw.ellipse((213, 110, 235, 132), fill='#1d2630')
        draw.ellipse((277, 110, 299, 132), fill='#1d2630')
    elif side:
        x = 275 if view == 'left' else 215
        draw.ellipse((x, 110, x+18, 128), fill='#1d2630')
    image.save(destination / (view + '.png'))
print(destination)
