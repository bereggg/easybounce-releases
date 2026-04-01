#!/usr/bin/env python3
from PIL import Image, ImageDraw, ImageFilter, ImageFont
import math, os

S = 512
OUT = os.path.dirname(__file__) + '/assets'

def rounded_mask(size, radius):
    mask = Image.new('L', (size, size), 0)
    d = ImageDraw.Draw(mask)
    d.rounded_rectangle([0, 0, size, size], radius=radius, fill=255)
    return mask

def gradient_bg(colors, size=S):
    """Diagonal gradient from colors[0] to colors[1]"""
    img = Image.new('RGB', (size, size))
    d = ImageDraw.Draw(img)
    for i in range(size):
        t = i / size
        r = int(colors[0][0] * (1-t) + colors[1][0] * t)
        g = int(colors[0][1] * (1-t) + colors[1][1] * t)
        b = int(colors[0][2] * (1-t) + colors[1][2] * t)
        d.line([(0, i), (size, i)], fill=(r, g, b))
    return img

def add_noise(img, amount=8):
    import random
    arr = img.load()
    w, h = img.size
    for _ in range(w * h // 6):
        x, y = random.randint(0, w-1), random.randint(0, h-1)
        p = arr[x, y]
        n = random.randint(-amount, amount)
        arr[x, y] = tuple(max(0, min(255, c + n)) for c in p)
    return img

def font(size):
    for name in ['/System/Library/Fonts/Helvetica.ttc',
                 '/System/Library/Fonts/SFNSDisplay.ttf']:
        try: return ImageFont.truetype(name, size)
        except: pass
    return ImageFont.load_default()

radius = int(S * 0.22)  # macOS icon corner radius ~22%

# ══════════════════════════════════════════════════════════════════════════════
# VARIANT 1 — Purple-Pink gradient, white ring + dot (like reference)
# ══════════════════════════════════════════════════════════════════════════════
img1 = gradient_bg([(120, 60, 200), (220, 80, 180)]).convert('RGBA')
d = ImageDraw.Draw(img1)

# Subtle top highlight
d.rounded_rectangle([0, 0, S, S//3], radius=radius, fill=(255,255,255,18))

# Outer ring
cx, cy, r_out, r_in = S//2, S//2, 155, 110
d.ellipse([cx-r_out, cy-r_out, cx+r_out, cy+r_out], fill=(255,255,255,50))
d.ellipse([cx-r_in,  cy-r_in,  cx+r_in,  cy+r_in],  fill=(255,255,255,0))

# Glow behind dot
glow = Image.new('RGBA', (S, S), (0,0,0,0))
gd = ImageDraw.Draw(glow)
for gr in range(90, 0, -3):
    a = int(80 * (1 - gr/90))
    gd.ellipse([cx-gr, cy-gr, cx+gr, cy+gr], fill=(255,255,255,a))
glow = glow.filter(ImageFilter.GaussianBlur(16))
img1 = Image.alpha_composite(img1, glow)
d = ImageDraw.Draw(img1)

# Center dot
d.ellipse([cx-52, cy-52, cx+52, cy+52], fill=(255,255,255,240))
# Inner shadow on dot
d.ellipse([cx-48, cy-48, cx+48, cy+48], fill=(255,255,255,255))

# Apply rounded mask
mask1 = rounded_mask(S, radius)
img1.putalpha(mask1)
img1.save(f'{OUT}/logo_v1.png')
print('✓ logo_v1.png  (Purple-Pink + ring)')

# ══════════════════════════════════════════════════════════════════════════════
# VARIANT 2 — Blue-Violet gradient, soundwave arrow symbol
# ══════════════════════════════════════════════════════════════════════════════
img2 = gradient_bg([(30, 100, 220), (108, 60, 230)]).convert('RGBA')
d = ImageDraw.Draw(img2)

# Top shimmer
d.rounded_rectangle([10, 10, S-10, S//4], radius=radius-4, fill=(255,255,255,14))

# Draw a stylized bounce symbol: wave + upward arrow
# Wave bars (equalizer style)
bars = [
    (S//2 - 90, 80),
    (S//2 - 54, 50),
    (S//2 - 18, 90),
    (S//2 + 18, 40),
    (S//2 + 54, 70),
    (S//2 + 90, 30),
]
bar_w = 26
bar_bottom = S//2 + 80
for bx, bh in bars:
    # Glow
    glow2 = Image.new('RGBA', (S, S), (0,0,0,0))
    gd2 = ImageDraw.Draw(glow2)
    gd2.rounded_rectangle([bx - bar_w//2 - 4, bar_bottom - bh - 4,
                            bx + bar_w//2 + 4, bar_bottom + 4],
                           radius=8, fill=(255,255,255,30))
    glow2 = glow2.filter(ImageFilter.GaussianBlur(6))
    img2 = Image.alpha_composite(img2, glow2)
    d = ImageDraw.Draw(img2)
    d.rounded_rectangle([bx - bar_w//2, bar_bottom - bh,
                          bx + bar_w//2, bar_bottom],
                         radius=6, fill=(255,255,255,220))

mask2 = rounded_mask(S, radius)
img2.putalpha(mask2)
img2.save(f'{OUT}/logo_v2.png')
print('✓ logo_v2.png  (Blue-Violet + equalizer)')

# ══════════════════════════════════════════════════════════════════════════════
# VARIANT 3 — Dark navy, neon purple ring + lightning bolt
# ══════════════════════════════════════════════════════════════════════════════
img3 = gradient_bg([(12, 10, 30), (28, 16, 60)]).convert('RGBA')
d = ImageDraw.Draw(img3)

# Big glow circle behind symbol
for gr in range(200, 0, -5):
    t = 1 - gr/200
    a = int(60 * math.sin(t * math.pi))
    col = (int(108*t), int(40*t), int(255*t), a)
    d.ellipse([S//2-gr, S//2-gr, S//2+gr, S//2+gr], fill=col)

# Outer neon ring
ring_out, ring_in = 170, 145
for rr in range(ring_out, ring_in, -1):
    t = (rr - ring_in) / (ring_out - ring_in)
    a = int(180 * t)
    ri = int(108 + (79-108)*t)
    gi = int(60  + (184-60)*t)
    bi = int(255 + (232-255)*t)
    d.ellipse([S//2-rr, S//2-rr, S//2+rr, S//2+rr],
              outline=(ri, gi, bi, a), width=1)

# Lightning bolt / arrow up
pts_bolt = [
    (S//2 + 20, S//2 - 120),  # top right
    (S//2 - 10, S//2 - 10),   # middle left
    (S//2 + 30, S//2 - 10),   # middle right
    (S//2 - 20, S//2 + 120),  # bottom left
    (S//2 + 10, S//2 + 10),   # middle right low
    (S//2 - 30, S//2 + 10),   # middle left low
]
# Glow
glow3 = Image.new('RGBA', (S, S), (0,0,0,0))
gd3 = ImageDraw.Draw(glow3)
gd3.polygon(pts_bolt, fill=(140, 100, 255, 80))
glow3 = glow3.filter(ImageFilter.GaussianBlur(18))
img3 = Image.alpha_composite(img3, glow3)
d = ImageDraw.Draw(img3)
d.polygon(pts_bolt, fill=(200, 160, 255, 230))

mask3 = rounded_mask(S, radius)
img3.putalpha(mask3)
img3.save(f'{OUT}/logo_v3.png')
print('✓ logo_v3.png  (Dark + neon ring + bolt)')
print('\nDone! Check assets/logo_v1.png, logo_v2.png, logo_v3.png')
