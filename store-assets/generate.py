#!/usr/bin/env python3
"""Generate Connect IQ store assets for WatchShelf.
Brand: orange #FF8000, charcoal, cream; bookshelf + audio motif.
Rendered supersampled and downscaled (LANCZOS) for crisp edges."""
import os, math
from PIL import Image, ImageDraw, ImageFont, ImageFilter

OUT = os.path.dirname(os.path.abspath(__file__))  # regenerate in place (store-assets/)
os.makedirs(OUT, exist_ok=True)

ORANGE   = (255, 128, 0)
ORANGE_D = (214, 96,  0)
ORANGE_L = (255, 162, 66)
CHAR     = (22, 19, 16)     # near-black charcoal (warm)
CHAR2    = (38, 32, 26)
CREAM    = (255, 247, 236)
CREAM_D  = (232, 214, 190)
INK      = (20, 17, 14)
GREY     = (150, 140, 130)

def F(path, size):
    return ImageFont.truetype(path, size)

def font(size, bold=True):
    cands = (["/System/Library/Fonts/Supplemental/Arial Bold.ttf"] if bold
             else ["/System/Library/Fonts/Supplemental/Arial.ttf"])
    for c in cands:
        try: return F(c, size)
        except Exception: pass
    return ImageFont.load_default()

def vgrad(size, top, bot):
    w, h = size
    base = Image.new("RGB", (1, h))
    for y in range(h):
        t = y / max(1, h - 1)
        base.putpixel((0, y), tuple(int(top[i] + (bot[i]-top[i])*t) for i in range(3)))
    return base.resize((w, h))

def dgrad(size, c1, c2):
    """diagonal gradient TL->BR"""
    w, h = size
    img = Image.new("RGB", (w, h))
    px = img.load()
    for y in range(h):
        for x in range(w):
            t = (x/w + y/h) / 2
            px[x, y] = tuple(int(c1[i] + (c2[i]-c1[i])*t) for i in range(3))
    return img

def rrect(draw, box, r, fill, outline=None, width=1):
    draw.rounded_rectangle(box, radius=r, fill=fill, outline=outline, width=width)

def center_text(draw, cx, y, text, fnt, fill, anchor="ma"):
    draw.text((cx, y), text, font=fnt, fill=fill, anchor=anchor)

# ---------------------------------------------------------------- bookshelf motif
def bookshelf(draw, cx, cy, w, h, spine_colors, shelf=True):
    """Draw a row of book spines centered at (cx,cy) within w x h."""
    n = len(spine_colors)
    gap = w * 0.03
    bw = (w - gap*(n-1)) / n
    x = cx - w/2
    top = cy - h/2
    for i, (col, hh) in enumerate(spine_colors):
        bh = h * hh
        by = cy + h/2 - bh
        rrect(draw, [x, by, x+bw, cy+h/2], r=bw*0.18, fill=col)
        # a lighter cap line near top of spine
        draw.line([x+bw*0.2, by+bh*0.12, x+bw*0.8, by+bh*0.12],
                  fill=tuple(min(255,c+40) for c in col), width=max(2,int(bw*0.06)))
        x += bw + gap
    if shelf:
        sy = cy + h/2
        draw.rounded_rectangle([cx-w/2-w*0.04, sy, cx+w/2+w*0.04, sy+h*0.08],
                               radius=h*0.02, fill=INK)

# ---------------------------------------------------------------- APP ICON
def make_icon(px, path, pad_ratio=0.0, rounded=True):
    SS = 4
    S = px*SS
    img = Image.new("RGBA", (S, S), (0,0,0,0))
    # background rounded square with gradient
    bg = vgrad((S, S), ORANGE_L, ORANGE_D).convert("RGBA")
    mask = Image.new("L", (S, S), 0)
    md = ImageDraw.Draw(mask)
    rad = int(S*0.22) if rounded else 0
    md.rounded_rectangle([0,0,S-1,S-1], radius=rad, fill=255)
    img.paste(bg, (0,0), mask)
    d = ImageDraw.Draw(img)
    # subtle top sheen
    sheen = Image.new("L",(S,S),0); sd=ImageDraw.Draw(sheen)
    sd.rounded_rectangle([0,0,S-1,int(S*0.5)], radius=rad, fill=40)
    img.alpha_composite(Image.new("RGBA",(S,S),(255,255,255,255)).putalpha(sheen) or Image.new("RGBA",(S,S),(0,0,0,0)))
    # bookshelf motif (cream + charcoal spines, varying heights)
    spines = [(CHAR,0.78),(CREAM,0.92),(CHAR,0.66),(CREAM,0.82),(CHAR,0.72)]
    bookshelf(d, S/2, S*0.47, S*0.60, S*0.52, spines, shelf=True)
    # small "play" triangle badge (audio cue) bottom-right on a cream disc
    r = S*0.14; bx, by = S*0.72, S*0.72
    d.ellipse([bx-r,by-r,bx+r,by+r], fill=CREAM)
    tri = [(bx-r*0.35,by-r*0.5),(bx-r*0.35,by+r*0.5),(bx+r*0.55,by)]
    d.polygon(tri, fill=ORANGE_D)
    img = img.resize((px,px), Image.LANCZOS)
    img.convert("RGBA").save(path)
    return path

# ---------------------------------------------------------------- watch mockup
def watch(screen_draw_fn, D=900, bezel=True):
    SS = 3
    S = D*SS
    img = Image.new("RGBA",(S,S),(0,0,0,0))
    d = ImageDraw.Draw(img)
    cx=cy=S/2; R=S*0.47
    if bezel:
        d.ellipse([cx-R,cy-R,cx+R,cy+R], fill=(45,42,40))
        d.ellipse([cx-R*0.97,cy-R*0.97,cx+R*0.97,cy+R*0.97], fill=(20,20,22))
    # screen
    sr = R*0.90
    screen = Image.new("RGBA",(S,S),(0,0,0,0))
    sd = ImageDraw.Draw(screen)
    sd.ellipse([cx-sr,cy-sr,cx+sr,cy+sr], fill=(8,8,10,255))
    screen_draw_fn(sd, cx, cy, sr)
    mask = Image.new("L",(S,S),0)
    ImageDraw.Draw(mask).ellipse([cx-sr,cy-sr,cx+sr,cy+sr], fill=255)
    img.paste(screen,(0,0),mask)
    # glossy rim
    d.ellipse([cx-sr,cy-sr,cx+sr,cy+sr], outline=(70,66,62), width=int(S*0.006))
    return img.resize((D,D), Image.LANCZOS)

def menu_screen(title, rows, focus_idx):
    """returns a draw-fn rendering a Garmin Menu2-style list"""
    def fn(d, cx, cy, sr):
        top = cy - sr
        S = sr*2
        # title
        f_t = font(int(sr*0.15), bold=True)
        d.text((cx, top+sr*0.28), title, font=f_t, fill=ORANGE_L, anchor="mm")
        # rows
        f_r = font(int(sr*0.135), bold=True)
        f_s = font(int(sr*0.10), bold=False)
        y = cy - sr*0.28
        rh = sr*0.42
        for i,(t,s) in enumerate(rows):
            if i==focus_idx:
                d.rounded_rectangle([cx-sr*0.86, y-rh*0.42, cx+sr*0.86, y+rh*0.42],
                                    radius=sr*0.10, fill=(40,34,28))
            col = CREAM if i==focus_idx else CREAM_D
            d.text((cx-sr*0.72, y-(rh*0.16 if s else 0)), t, font=f_r, fill=col, anchor="lm")
            if s:
                d.text((cx-sr*0.72, y+rh*0.20), s, font=f_s, fill=GREY, anchor="lm")
            y += rh
        # scrollbar arc hint
        d.arc([cx-sr*0.97,cy-sr*0.97,cx+sr*0.97,cy+sr*0.97], start=-32, end=32,
              fill=(60,56,52), width=int(sr*0.03))
        d.arc([cx-sr*0.97,cy-sr*0.97,cx+sr*0.97,cy+sr*0.97], start=-30, end=-6,
              fill=ORANGE, width=int(sr*0.03))
    return fn

def player_screen(title, author, elapsed, total, frac):
    def fn(d, cx, cy, sr):
        # progress ring
        d.arc([cx-sr*0.9,cy-sr*0.9,cx+sr*0.9,cy+sr*0.9], start=130, end=410,
              fill=(50,46,42), width=int(sr*0.05))
        d.arc([cx-sr*0.9,cy-sr*0.9,cx+sr*0.9,cy+sr*0.9], start=130, end=130+int(280*frac),
              fill=ORANGE, width=int(sr*0.05))
        f_t = font(int(sr*0.15), bold=True)
        f_a = font(int(sr*0.11), bold=False)
        f_c = font(int(sr*0.105), bold=True)
        # title (wrap to 2 lines)
        words = title.split()
        l1, l2 = " ".join(words[:2]), " ".join(words[2:])
        d.text((cx, cy-sr*0.36), l1, font=f_t, fill=CREAM, anchor="mm")
        if l2: d.text((cx, cy-sr*0.18), l2, font=f_t, fill=CREAM, anchor="mm")
        d.text((cx, cy+sr*0.02), author, font=f_a, fill=GREY, anchor="mm")
        # controls row
        y = cy+sr*0.34
        # prev
        d.polygon([(cx-sr*0.5,y),(cx-sr*0.34,y-sr*0.1),(cx-sr*0.34,y+sr*0.1)], fill=CREAM_D)
        d.rectangle([cx-sr*0.53,y-sr*0.1,cx-sr*0.5,y+sr*0.1], fill=CREAM_D)
        # play (center, orange disc)
        pr=sr*0.16
        d.ellipse([cx-pr,y-pr,cx+pr,y+pr], fill=ORANGE)
        d.polygon([(cx-pr*0.3,y-pr*0.45),(cx-pr*0.3,y+pr*0.45),(cx+pr*0.5,y)], fill=INK)
        # next
        d.polygon([(cx+sr*0.5,y),(cx+sr*0.34,y-sr*0.1),(cx+sr*0.34,y+sr*0.1)], fill=CREAM_D)
        d.rectangle([cx+sr*0.5,y-sr*0.1,cx+sr*0.53,y+sr*0.1], fill=CREAM_D)
        # time
        d.text((cx, cy+sr*0.62), f"{elapsed}  /  {total}", font=f_c, fill=GREY, anchor="mm")
    return fn

# ---------------------------------------------------------------- HERO / COVER
def wordmark(d, x, y, size, sub=None, align="l"):
    fw = font(size, bold=True)
    anchor = {"l":"lm","m":"mm"}[align]
    d.text((x, y), "WatchShelf", font=fw, fill=CREAM, anchor=anchor)

def make_hero(path, W=1440, H=720):
    SS=2; img = dgrad((W*SS,H*SS), (26,22,18), (120,52,0)).convert("RGBA")
    # orange glow blob right
    glow = Image.new("RGBA",(W*SS,H*SS),(0,0,0,0)); gd=ImageDraw.Draw(glow)
    gd.ellipse([W*SS*0.55,H*SS*0.05,W*SS*1.15,H*SS*1.05], fill=(255,128,0,90))
    glow = glow.filter(ImageFilter.GaussianBlur(120))
    img.alpha_composite(glow)
    d = ImageDraw.Draw(img)
    # left text
    lx = W*SS*0.075
    wordmark(d, lx, H*SS*0.34, int(H*SS*0.15))
    d.text((lx, H*SS*0.50), "Your Audiobookshelf library, on your wrist.",
           font=font(int(H*SS*0.058), bold=True), fill=CREAM, anchor="lm")
    d.text((lx, H*SS*0.585), "Download books to your Garmin. Listen offline, phone-free.",
           font=font(int(H*SS*0.040), bold=False), fill=CREAM_D, anchor="lm")
    # chips
    chips=["OFFLINE","PHONE-FREE","RESUME ANYWHERE"]
    cx=lx
    for c in chips:
        f=font(int(H*SS*0.030), bold=True); w=d.textlength(c,font=f)
        pad=H*SS*0.026
        d.rounded_rectangle([cx,H*SS*0.655,cx+w+pad*2,H*SS*0.655+H*SS*0.066],
                            radius=H*SS*0.033, fill=(0,0,0,130), outline=ORANGE, width=SS*2)
        d.text((cx+pad,H*SS*0.655+H*SS*0.033), c, font=f, fill=CREAM, anchor="lm")
        cx += w+pad*2+H*SS*0.02
    # small bookshelf mark above wordmark
    bookshelf(d, lx+H*SS*0.04, H*SS*0.18, H*SS*0.16, H*SS*0.14,
              [(ORANGE_L,0.8),(CREAM,0.95),(ORANGE_L,0.7),(CREAM,0.85)], shelf=True)
    img = img.resize((W,H), Image.LANCZOS)
    # paste watch on right
    w = watch(player_screen("Project Hail Mary","Andy Weir","4:12:09","16:20:41",0.26), D=int(H*0.82))
    img.alpha_composite(w, (int(W*0.66), int(H*0.09)))
    img.convert("RGB").save(path, quality=95)
    return path

def make_cover(path, W=1280, H=640):
    SS=2; img = dgrad((W*SS,H*SS), (24,20,16), (150,64,0)).convert("RGBA")
    d = ImageDraw.Draw(img)
    # centered bookshelf + wordmark
    bookshelf(d, W*SS/2, H*SS*0.34, W*SS*0.24, H*SS*0.26,
              [(CHAR,0.8),(CREAM,0.95),(ORANGE_L,0.7),(CREAM,0.85),(CHAR,0.75)], shelf=True)
    wordmark(d, W*SS/2, H*SS*0.60, int(H*SS*0.15), align="m")
    d.text((W*SS/2, H*SS*0.74), "Audiobookshelf, on your Garmin watch",
           font=font(int(H*SS*0.052), bold=True), fill=CREAM_D, anchor="mm")
    img = img.resize((W,H), Image.LANCZOS)
    img.convert("RGB").save(path, quality=95)
    return path

# ---------------------------------------------------------------- RUN
print("icon 500 ->", make_icon(500, f"{OUT}/icon_500.png"))
print("icon 128 ->", make_icon(128, f"{OUT}/icon_128_on_device.png"))
print("hero    ->", make_hero(f"{OUT}/hero_1440x720.png"))
print("cover   ->", make_cover(f"{OUT}/cover_1280x640.png"))

# screens (framed watch mockups)
screens = {
 "screen_1_library": menu_screen("All Books",
     [("Project Hail Mary","Andy Weir"),("The Way of Kings","Sanderson"),
      ("Dune","Frank Herbert"),("Children of Time","Tchaikovsky")], 0),
 "screen_2_playmenu": menu_screen("Play downloaded",
     [("Project Hail Mary","103 parts"),("Dune","287 parts"),
      ("All Systems Red","41 parts")], 0),
 "screen_3_bookactions": menu_screen("Project Hail Mary",
     [("Resume",None),("Play from start",None),("Delete from watch",None)], 0),
}
for name, fn in screens.items():
    watch(fn, D=900).save(f"{OUT}/{name}.png"); print("screen ->", name)
watch(player_screen("Project Hail Mary","Andy Weir","4:12:09","16:20:41",0.26), D=900)\
    .save(f"{OUT}/screen_4_player.png"); print("screen -> screen_4_player")
print("DONE ->", OUT)
