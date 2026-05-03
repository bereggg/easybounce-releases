#!/usr/bin/env python3
from PIL import Image, ImageDraw, ImageFilter, ImageChops
import math, os

W, H = 820, 480
OUT = os.path.join(os.path.dirname(__file__), 'assets', 'dmg_bg.png')

# ── Gradient background ───────────────────────────────────────────────────────
bg = Image.new('RGB', (W, H))
bd = ImageDraw.Draw(bg)
for y in range(H):
    t = y / H
    bd.line([(0, y), (W, y)], fill=(int(10 + t * 8), int(8 + t * 6), int(28 + t * 20)))

# ── Glows (screen blend = additive, never darkens) ───────────────────────────
def add_glow(base, cx, cy, radius, color, strength=1.0):
    glow = Image.new('RGB', (W, H), (0, 0, 0))
    gd = ImageDraw.Draw(glow)
    for r in range(radius, 0, -3):
        t = (1 - r / radius) ** 1.5
        c = tuple(int(ch * t * strength) for ch in color)
        gd.ellipse([cx - r, cy - r, cx + r, cy + r], fill=c)
    glow = glow.filter(ImageFilter.GaussianBlur(radius // 3))
    return ImageChops.add(base, glow)

# Large ambient glows
bg = add_glow(bg, 180, 220, 300, (18,  45, 130), 1.0)   # left blue
bg = add_glow(bg, 660, 190, 260, (55,  10, 110), 1.0)   # right purple
bg = add_glow(bg, 410, 100, 180, (25,  15,  90), 1.0)   # top center

# Per-icon glows
bg = add_glow(bg, 140, 184, 130, (20,  50, 160), 0.9)   # README
bg = add_glow(bg, 294, 184, 130, (30,  20, 140), 0.8)   # Manual
bg = add_glow(bg, 498, 184, 150, (50,  10, 170), 1.0)   # EasyBounce
bg = add_glow(bg, 672, 184, 130, (70,  15, 120), 0.9)   # Applications

img = bg.convert('RGBA')
draw = ImageDraw.Draw(img)


# ── Glass cards ───────────────────────────────────────────────────────────────
def glass_card(x0, y0, x1, y1):
    ov = Image.new('RGBA', (W, H), (0, 0, 0, 0))
    od = ImageDraw.Draw(ov)
    od.rounded_rectangle([x0, y0, x1, y1], radius=18, fill=(255, 255, 255, 14))
    od.rounded_rectangle([x0 + 1, y0 + 1, x1 - 1, y0 + 36], radius=18, fill=(255, 255, 255, 8))
    od.rounded_rectangle([x0, y0, x1, y1], radius=18, outline=(255, 255, 255, 36), width=1)
    return ov

# Icon centers are at y=184, icon is 72px → top~148, bottom~220, label~240
# Cards centered around y=184, spanning ±110px → y: 74–294
# Left card: README + Manual (x: 70–375)
img = Image.alpha_composite(img, glass_card(70, 74, 375, 294))
# Right card: EasyBounce + Applications (x: 435–760)
img = Image.alpha_composite(img, glass_card(435, 74, 760, 294))

draw = ImageDraw.Draw(img)

# ── Arrow between cards ───────────────────────────────────────────────────────
ax, ay = 405, 184
draw.rounded_rectangle([ax - 22, ay - 3, ax + 22, ay + 3], radius=3, fill=(108, 99, 255, 160))
draw.polygon([(ax + 22, ay - 12), (ax + 42, ay), (ax + 22, ay + 12)], fill=(108, 99, 255, 200))

# ── Arrow between EasyBounce and Applications (within right card) ─────────────
bx, by = 590, 184
draw.rounded_rectangle([bx - 18, by - 3, bx + 18, by + 3], radius=3, fill=(108, 99, 255, 130))
draw.polygon([(bx + 18, by - 10), (bx + 36, by), (bx + 18, by + 10)], fill=(108, 99, 255, 170))

# ── Subtle logo icon on background ───────────────────────────────────────────
icon_path = os.path.join(os.path.dirname(__file__), 'assets', 'icon.png')
if os.path.exists(icon_path):
    ic = Image.open(icon_path).convert('RGBA').resize((32, 32), Image.LANCZOS)
    ic.putalpha(Image.eval(ic.split()[3], lambda a: int(a * 0.08)))
    img.paste(ic, (W // 2 - 16, 420), ic)

img.convert('RGB').save(OUT, 'PNG')
print('✓ dmg_bg.png')
