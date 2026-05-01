#!/usr/bin/env python3
from PIL import Image, ImageDraw, ImageFilter
import math, os

S = 1024
OUT = os.path.dirname(__file__) + '/assets/'

def lerp(a, b, t):
    return tuple(int(a[i] * (1-t) + b[i] * t) for i in range(3))

def make_icon(size):
    img = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    # Linear gradient diagonal: #5B21B6 → #9333EA → #EC4899
    c0 = (91, 33, 182)
    c1 = (147, 51, 234)
    c2 = (236, 72, 153)
    for y in range(size):
        for x in range(size):
            t = (x + y) / (2 * size)
            if t < 0.45:
                col = lerp(c0, c1, t / 0.45)
            else:
                col = lerp(c1, c2, (t - 0.45) / 0.55)
            d.point((x, y), fill=col + (255,))

    # Subtle radial shine: soft white glow top-left only
    shine = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    cx_s = int(0.30 * size)
    cy_s = int(0.25 * size)
    r_s  = int(0.65 * size)
    # Draw concentric ellipses fading outward
    steps = 60
    for i in range(steps, 0, -1):
        t = i / steps
        r = int(r_s * t)
        alpha = int(28 * (1 - t))  # very subtle
        sd = ImageDraw.Draw(shine)
        sd.ellipse([cx_s - r, cy_s - r, cx_s + r, cy_s + r],
                   fill=(255, 255, 255, alpha))
    shine = shine.filter(ImageFilter.GaussianBlur(size // 10))
    img = Image.alpha_composite(img, shine)

    # Rounded mask
    rx = int(93 / 400 * size)
    mask = Image.new('L', (size, size), 0)
    md = ImageDraw.Draw(mask)
    md.rounded_rectangle([0, 0, size, size], radius=rx, fill=255)
    img.putalpha(mask)

    # White circle
    d = ImageDraw.Draw(img)
    cr = int(66 / 400 * size)
    cx, cy = size // 2, size // 2
    d.ellipse([cx-cr, cy-cr, cx+cr, cy+cr], fill=(255, 255, 255, 255))

    return img

icon = make_icon(S)
icon.save(OUT + 'icon_new.png')
print(f'✓ icon_new.png ({S}x{S})')

prev = make_icon(256)
prev.save(OUT + 'icon_new_256.png')
print(f'✓ icon_new_256.png (preview)')

# Remove old variants
for f in ['logo_v1.png', 'logo_v2.png', 'logo_v3.png']:
    p = OUT + f
    if os.path.exists(p):
        os.remove(p)
        print(f'  removed {f}')
