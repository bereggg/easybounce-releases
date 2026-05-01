#!/usr/bin/env python3
from PIL import Image, ImageDraw, ImageFilter, ImageFont
import math, os

W, H = 820, 480
OUT = os.path.join(os.path.dirname(__file__), 'assets', 'dmg_bg.png')

bg = Image.new('RGB', (W, H))
bd = ImageDraw.Draw(bg)
for y in range(H):
    t = y / H
    bd.line([(0,y),(W,y)], fill=(int(8+t*6),int(8+t*4),int(20+t*16)))

def add_glow(base, cx, cy, radius, color, strength=0.45):
    glow = Image.new('RGB',(W,H),(0,0,0))
    gd = ImageDraw.Draw(glow)
    for r in range(radius,0,-4):
        t=1-r/radius; c=tuple(int(ch*t*0.6) for ch in color)
        gd.ellipse([cx-r,cy-r,cx+r,cy+r],fill=c)
    glow=glow.filter(ImageFilter.GaussianBlur(radius//2))
    return Image.blend(base,glow,strength)

bg=add_glow(bg,150,260,240,(40,80,200),0.45)
bg=add_glow(bg,670,220,220,(90,30,180),0.40)
bg=add_glow(bg,410,130,160,(60,40,160),0.28)
img=bg.convert('RGBA')
draw=ImageDraw.Draw(img)

for x in range(20,W,36):
    for y in range(20,H,36):
        draw.ellipse([x-1,y-1,x+1,y+1],fill=(255,255,255,16))

def font(size):
    for name in ['/System/Library/Fonts/Helvetica.ttc','/System/Library/Fonts/SFNSDisplay.ttf']:
        try: return ImageFont.truetype(name,size)
        except: pass
    return ImageFont.load_default()

f_title=font(24); f_sub=font(12); f_label=font(13); f_note=font(11); f_step=font(11)

# Title
tw=draw.textlength('EasyBounce',font=f_title)
draw.text(((W-tw)/2,34),'EasyBounce',font=f_title,fill=(255,255,255,230))
sw=draw.textlength('Logic Pro Stem Bouncer  ·  v1.0.0',font=f_sub)
draw.text(((W-sw)/2,66),'Logic Pro Stem Bouncer  ·  v1.0.0',font=f_sub,fill=(180,160,255,130))
for i in range(200):
    t=i/199; r=int(108*(1-t)+79*t); g=int(99*(1-t)+184*t); b=int(255*(1-t)+232*t)
    draw.point((W//2-100+i,90),fill=(r,g,b,int(200*math.sin(t*math.pi))))

# Glass cards
def glass_card(x0,y0,x1,y1):
    ov=Image.new('RGBA',(W,H),(0,0,0,0)); od=ImageDraw.Draw(ov)
    od.rounded_rectangle([x0,y0,x1,y1],radius=18,fill=(255,255,255,14))
    od.rounded_rectangle([x0+1,y0+1,x1-1,y0+36],radius=18,fill=(255,255,255,8))
    od.rounded_rectangle([x0,y0,x1,y1],radius=18,outline=(255,255,255,36),width=1)
    return ov

# Layout: Patcher left, App+Patcher together left, Applications right
# Two items left, arrow, Applications right
img=Image.alpha_composite(img,glass_card(55,118,390,362))   # left card (app+patcher)
img=Image.alpha_composite(img,glass_card(490,118,765,362))  # right card (Applications)
draw=ImageDraw.Draw(img)

# Arrow
ax,ay=440,240
draw.rounded_rectangle([ax-36,ay-4,ax+36,ay+4],radius=3,fill=(108,99,255,190))
draw.polygon([(ax+36,ay-15),(ax+62,ay),(ax+36,ay+15)],fill=(108,99,255,220))

# App icon (left side of left card)
icon_path=os.path.join(os.path.dirname(__file__),'assets','icon.png')
if os.path.exists(icon_path):
    ic=Image.open(icon_path).convert('RGBA').resize((96,96),Image.LANCZOS)
    img.paste(ic,(82,162),ic)

# Patcher icon (right side of left card, smaller)
picon_path=os.path.join(os.path.dirname(__file__),'assets','patcher_icon.png')
if os.path.exists(picon_path):
    pi=Image.open(picon_path).convert('RGBA').resize((60,60),Image.LANCZOS)
    img.paste(pi,(298,228),pi)

# Applications icon
draw=ImageDraw.Draw(img)
fx,fy=603,168
draw.rounded_rectangle([fx,fy,fx+96,fy+96],radius=22,fill=(30,100,200,180),outline=(79,184,232,80),width=1)
draw.rounded_rectangle([fx+2,fy+2,fx+94,fy+38],radius=20,fill=(255,255,255,16))
draw.text((fx+48,fy+50),font(36).getbbox('A') and 'A',font=font(36),fill=(255,255,255,220),anchor='mm')

# Labels
def clabel(text,cx,y=282):
    w=draw.textlength(text,font=f_label)
    draw.text((cx-w/2,y),text,font=f_label,fill=(255,255,255,170))

clabel('EasyBounce',178,272)
clabel('+ Patcher',325,284)
clabel('Applications',651,282)

# Step badges
def badge(n,cx,cy):
    draw.ellipse([cx-11,cy-11,cx+11,cy+11],fill=(108,99,255,190))
    w=draw.textlength(str(n),font=f_step)
    draw.text((cx-w/2,cy-6),str(n),font=f_step,fill=(255,255,255,240))

badge(1,130,152)
badge(2,628,152)

# Bottom note
note='1. Open Patcher  ·  2. Drag EasyBounce → Applications'
nw=draw.textlength(note,font=f_note)
draw.text(((W-nw)/2,410),note,font=f_note,fill=(255,255,255,70))

img.convert('RGB').save(OUT,'PNG')
print('✓ dmg_bg.png')
