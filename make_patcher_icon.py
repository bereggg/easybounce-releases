#!/usr/bin/env python3
from PIL import Image, ImageDraw, ImageFilter
import math, os

S = 1024
OUT = os.path.dirname(__file__) + '/assets/'

def make_icon(size):
    img = Image.new('RGBA', (size, size), (0,0,0,0))
    d = ImageDraw.Draw(img)
    sc = size / 400

    # Radial gradient: #9333EA → #A020D0 → #E8409A
    # cx=30%, cy=25%, r=85%
    cx_r, cy_r = 0.30 * size, 0.25 * size
    r_max = 0.85 * size
    c0 = (147, 51, 234)
    c1 = (160, 32, 208)
    c2 = (232, 64, 154)
    for y in range(size):
        for x in range(size):
            dist = math.sqrt((x - cx_r)**2 + (y - cy_r)**2) / r_max
            t = min(dist, 1.0)
            if t < 0.55:
                s = t / 0.55
                col = tuple(int(c0[i]*(1-s) + c1[i]*s) for i in range(3))
            else:
                s = (t - 0.55) / 0.45
                col = tuple(int(c1[i]*(1-s) + c2[i]*s) for i in range(3))
            d.point((x, y), fill=col + (255,))

    # Rounded mask rx=90
    rx = int(90 * sc)
    mask = Image.new('L', (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, size, size], radius=rx, fill=255)
    img.putalpha(mask)

    # Checkmark: M118 200 L172 258 L282 148 (from SVG, scale to size)
    p1 = (int(118*sc), int(200*sc))
    p2 = (int(172*sc), int(258*sc))
    p3 = (int(282*sc), int(148*sc))
    sw = int(36 * sc)

    # Glow
    glow = Image.new('RGBA', (size, size), (0,0,0,0))
    gd = ImageDraw.Draw(glow)
    gd.line([p1, p2], fill=(255,255,255,80), width=sw + int(18*sc))
    gd.line([p2, p3], fill=(255,255,255,80), width=sw + int(18*sc))
    glow = glow.filter(ImageFilter.GaussianBlur(int(12*sc)))
    img = Image.alpha_composite(img, glow)

    d = ImageDraw.Draw(img)
    d.line([p1, p2], fill=(255,255,255,255), width=sw)
    d.line([p2, p3], fill=(255,255,255,255), width=sw)
    # Round caps
    r = sw // 2
    for p in [p1, p2, p3]:
        d.ellipse([p[0]-r, p[1]-r, p[0]+r, p[1]+r], fill=(255,255,255,255))

    return img

icon = make_icon(S)
icon.save(OUT + 'patcher_icon.png')

prev = make_icon(256)
prev.save(OUT + 'patcher_icon_256.png')
print('✓ done')
