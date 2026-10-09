"""Turns raw emulator captures into Play Store phone screenshots.

Layout (from the Play guidelines research):
- 1440x2560 (9:16), RGB PNG with no alpha. Play needs >= 1080 px, and at
  least 4 such screenshots for large-format placements.
- Headline (<= 6 words, one accented keyword) and a short subline in the top
  band. Text stays well under 20 % of the image.
- The whole real app screen in a generic phone frame (no brand device), so no
  UI is cut off.
- Deep navy background with the icon's blue (left) / pink (right) glow, so the
  set matches the new app icon.
- No "best", "#1", "free", prices, rankings or calls to action.

Run: python3 store_assets/screenshots/compose_screenshots.py
Input: raw/<name>.png   Output: phone/<NN>_<name>.png + phone/_overview.jpg
"""
import os
import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
RAW, OUT = os.path.join(HERE, 'raw'), os.path.join(HERE, 'phone')
W, H = 1440, 2560
BLUE, PINK = (0x4A, 0x90, 0xE2), (0xE9, 0x4E, 0x77)
ACCENT = {'blue': (120, 180, 255), 'pink': (255, 120, 160)}
FONT = '/System/Library/Fonts/Avenir Next.ttc'
HEAVY, DEMI = 8, 2

# (raw file, headline parts [(text, accent or None)], subline, accent side)
SHOTS = [
    ('01_duo', [('Two songs.', None), ('\n', None), ('One per ', None), ('ear.', 'pink')],
     'Duo Mode: share your earphones', 'pink'),
    ('02_now_playing', [('Hi-Res ', 'blue'), ('offline', None), ('\n', None), ('music player', None)],
     'FLAC, MP3, M4A, OGG, Opus & WAV', 'blue'),
    ('03_lyrics', [('Synced lyrics', 'blue'), ('\n', None), ('that sing along', None)],
     'Tap any line to jump right there', 'blue'),
    ('04_equalizer', [('10-band', 'pink'), ('\n', None), ('equalizer', None)],
     'Presets, plus a separate EQ for each device', 'pink'),
    ('05_sound_effects', [('Bass boost', 'blue'), (' &', None), ('\n', None), ('crossfade', None)],
     'Virtualizer, loudness and volume leveling', 'blue'),
    ('06_8d_audio', [('Turn any song', None), ('\n', None), ('into ', None), ('8D audio', 'pink')],
     'Immersive sound on your headphones', 'pink'),
    ('07_library', [('Your library,', None), ('\n', None), ('organized', 'blue')],
     'Recently added, most played, folders & artists', 'blue'),
    ('08_appearance', [('Make it', None), ('\n', None), ('yours', 'pink')],
     'Pure black theme, 8 accents, Material You', 'pink'),
]


def background(i):
    """Navy gradient with blue/pink glows; glow positions drift per frame."""
    yy, xx = np.mgrid[0:H // 4, 0:W // 4].astype(float)
    v = yy / (H // 4)
    top, bot = np.array([34, 32, 70.]), np.array([14, 13, 30.])
    col = top * (1 - v)[..., None] + bot * v[..., None]
    img = Image.fromarray(col.astype(np.uint8)).resize((W, H), Image.BICUBIC).convert('RGBA')
    glow = Image.new('RGBA', (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(glow)
    shift = (i % 2) * 180
    d.ellipse((-500, 500 + shift, 700, 1700 + shift), fill=BLUE + (120,))
    d.ellipse((W - 700, 1100 - shift, W + 500, 2300 - shift), fill=PINK + (120,))
    d.ellipse((W // 2 - 500, -500, W // 2 + 500, 300), fill=(90, 80, 170, 70))
    img.alpha_composite(glow.filter(ImageFilter.GaussianBlur(260)))
    return img


def draw_headline(img, parts, sub, y0=150):
    d = ImageDraw.Draw(img)
    big = ImageFont.truetype(FONT, 118, index=HEAVY)
    small = ImageFont.truetype(FONT, 52, index=DEMI)
    lines, cur = [], []
    for text, acc in parts:
        if text == '\n':
            lines.append(cur); cur = []
        else:
            cur.append((text, acc))
    lines.append(cur)
    y = y0
    for line in lines:
        width = sum(d.textlength(t, font=big) for t, _ in line)
        x = (W - width) / 2
        for t, acc in line:
            fill = ACCENT[acc] if acc else (255, 255, 255)
            d.text((x, y), t, font=big, fill=fill)
            x += d.textlength(t, font=big)
        y += 138
    sw = d.textlength(sub, font=small)
    d.text(((W - sw) / 2, y + 22), sub, font=small, fill=(210, 210, 230))
    return y + 22 + 70


def phone(shot, top, bottom_margin=70):
    """Generic rounded phone frame around the whole capture, fitted below the text."""
    bez = 24
    sh = H - top - bottom_margin - 2 * bez
    sw = int(shot.width * sh / shot.height)
    shot = shot.convert('RGB').resize((sw, sh), Image.LANCZOS)
    rad = 96
    fw, fh = sw + 2 * bez, sh + 2 * bez
    x0 = (W - fw) // 2
    layer = Image.new('RGBA', (W, H), (0, 0, 0, 0))
    # soft shadow inside the artwork
    sh_mask = Image.new('L', (W, H), 0)
    ImageDraw.Draw(sh_mask).rounded_rectangle((x0, top + 30, x0 + fw, top + 30 + fh), radius=rad, fill=150)
    layer.paste((0, 0, 0, 255), (0, 0), sh_mask.filter(ImageFilter.GaussianBlur(45)))
    d = ImageDraw.Draw(layer)
    d.rounded_rectangle((x0, top, x0 + fw, top + fh), radius=rad, fill=(22, 22, 28, 255))
    d.rounded_rectangle((x0, top, x0 + fw, top + fh), radius=rad, outline=(90, 92, 110, 255), width=4)
    m = Image.new('L', (sw, sh), 0)
    ImageDraw.Draw(m).rounded_rectangle((0, 0, sw - 1, sh - 1), radius=rad - bez, fill=255)
    layer.paste(shot, (x0 + bez, top + bez), m)
    # camera punch-hole
    cx, cy = W // 2, top + bez + 36
    d.ellipse((cx - 15, cy - 15, cx + 15, cy + 15), fill=(8, 8, 10, 255))
    return layer


def compose():
    os.makedirs(OUT, exist_ok=True)
    paths = []
    for i, (name, parts, sub, _) in enumerate(SHOTS):
        img = background(i)
        text_bottom = draw_headline(img, parts, sub)
        img.alpha_composite(phone(Image.open(os.path.join(RAW, name + '.png')), text_bottom + 50))
        out = os.path.join(OUT, f'{name}.png')
        img.convert('RGB').save(out, optimize=True)
        paths.append(out)
        print(os.path.basename(out), Image.open(out).size, Image.open(out).mode, f'{os.path.getsize(out) // 1024} KB')
    # overview sheet for review
    th = 900
    tw = int(W * th / H)
    sheet = Image.new('RGB', (len(paths) * (tw + 20) + 20, th + 40), (245, 245, 247))
    for i, p in enumerate(paths):
        sheet.paste(Image.open(p).resize((tw, th), Image.LANCZOS), (20 + i * (tw + 20), 20))
    sheet.save(os.path.join(OUT, '_overview.jpg'), quality=88)


if __name__ == '__main__':
    compose()
