"""Writes the Android launcher icons from the 3D Duo logo mark design.

Android 8+ (API 26+): an adaptive icon in mipmap-anydpi-v26/ic_launcher.xml
  - background: the Duo navy gradient with blue/pink glows (108 dp, full bleed)
  - foreground: the 3D logo mark + glow on transparent, kept inside the
    66 dp safe zone so every launcher mask (circle, squircle, teardrop) fits
  - monochrome: a plain silhouette for Android 13+ themed icons
Android 7.x (API 24-25): mipmap-*/ic_launcher.png, the full icon with rounded
corners (48 dp).

Run: python3 store_assets/icon/generate_launcher_icons.py
"""
import os
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

import generate_icon_3d as hp3d

HERE = os.path.dirname(os.path.abspath(__file__))
RES = os.path.join(HERE, '..', '..', 'android', 'app', 'src', 'main', 'res')
DENSITIES = {'mdpi': 1.0, 'hdpi': 1.5, 'xhdpi': 2.0, 'xxhdpi': 3.0, 'xxxhdpi': 4.0}
S = hp3d.S                       # 2048 master canvas


def foreground_master():
    """Earbuds + halo, scaled so the glow fits the 66/108 safe zone."""
    hp = hp3d.headphones()
    art = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    art.alpha_composite(hp3d.halo(hp, strength=1.9, cap=215))
    art.alpha_composite(hp)
    x0, y0, x1, y1 = hp.split()[3].getbbox()
    # logo mark span 58 dp of the 108 dp canvas, so even their corners stay
    # inside the 66 dp safe circle
    target = S * 50 / 108
    scale = target / max(x1 - x0, y1 - y0)
    art = art.resize((int(S * scale), int(S * scale)), Image.LANCZOS)
    cx, cy = (x0 + x1) / 2 * scale, (y0 + y1) / 2 * scale
    out = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    out.alpha_composite(art, (int(S / 2 - cx), int(S / 2 - cy)))
    return out, (hp, scale, cx, cy)


def monochrome_master(geom):
    hp, scale, cx, cy = geom
    a = hp3d.logo_mono().resize((int(S * scale), int(S * scale)), Image.LANCZOS)
    out = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    white = Image.new('RGBA', a.size, (255, 255, 255, 255))
    out.paste(white, (int(S / 2 - cx), int(S / 2 - cy)), a)
    return out


def background_master():
    return hp3d.background('duo')


def legacy_master():
    """Full icon with rounded corners for pre-adaptive launchers."""
    img = hp3d.background('duo')
    hp = hp3d.headphones()
    img.alpha_composite(hp3d.contact_shadow(hp))
    img.alpha_composite(hp3d.halo(hp, strength=1.9, cap=215))
    img.alpha_composite(hp)
    m = Image.new('L', (S, S), 0)
    ImageDraw.Draw(m).rounded_rectangle((0, 0, S - 1, S - 1), radius=int(S * 0.22), fill=255)
    img.putalpha(m)
    return img


def write(master, name, dp):
    for dens, k in DENSITIES.items():
        folder = os.path.join(RES, f'mipmap-{dens}')
        os.makedirs(folder, exist_ok=True)
        px = int(round(dp * k))
        master.resize((px, px), Image.LANCZOS).save(os.path.join(folder, name), optimize=True)


ADAPTIVE_XML = '''<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@mipmap/ic_launcher_background" />
    <foreground android:drawable="@mipmap/ic_launcher_foreground" />
    <monochrome android:drawable="@mipmap/ic_launcher_monochrome" />
</adaptive-icon>
'''


if __name__ == '__main__':
    fg, geom = foreground_master()
    write(fg, 'ic_launcher_foreground.png', 108)
    write(monochrome_master(geom), 'ic_launcher_monochrome.png', 108)
    write(background_master(), 'ic_launcher_background.png', 108)
    write(legacy_master(), 'ic_launcher.png', 48)
    anydpi = os.path.join(RES, 'mipmap-anydpi-v26')
    os.makedirs(anydpi, exist_ok=True)
    with open(os.path.join(anydpi, 'ic_launcher.xml'), 'w') as fh:
        fh.write(ADAPTIVE_XML)

    # preview: the adaptive layers under circle / squircle / rounded-square masks
    size = 432
    bg = Image.open(os.path.join(RES, 'mipmap-xxxhdpi', 'ic_launcher_background.png')).convert('RGBA')
    fgi = Image.open(os.path.join(RES, 'mipmap-xxxhdpi', 'ic_launcher_foreground.png'))
    mono = Image.open(os.path.join(RES, 'mipmap-xxxhdpi', 'ic_launcher_monochrome.png'))
    comp = bg.copy(); comp.alpha_composite(fgi)
    themed = Image.new('RGBA', (size, size), (40, 44, 60, 255))
    tint = Image.new('RGBA', (size, size), (200, 215, 255, 255))
    themed.paste(tint, (0, 0), mono.split()[3])
    view = int(size * 72 / 108)                      # visible 72 dp of 108 dp
    off = (size - view) // 2
    sheet = Image.new('RGB', (4 * (view + 40) + 40, view + 80), (236, 238, 242))
    masks = []
    for kind in ('circle', 'squircle', 'rounded'):
        m = Image.new('L', (view * 4, view * 4), 0)
        d = ImageDraw.Draw(m)
        if kind == 'circle':
            d.ellipse((0, 0, view * 4 - 1, view * 4 - 1), fill=255)
        elif kind == 'squircle':
            d.rounded_rectangle((0, 0, view * 4 - 1, view * 4 - 1), radius=int(view * 4 * 0.38), fill=255)
        else:
            d.rounded_rectangle((0, 0, view * 4 - 1, view * 4 - 1), radius=int(view * 4 * 0.18), fill=255)
        masks.append(m.resize((view, view), Image.LANCZOS))
    for i, (img, m) in enumerate([(comp, masks[0]), (comp, masks[1]), (comp, masks[2]), (themed, masks[0])]):
        crop = img.crop((off, off, off + view, off + view)).convert('RGB')
        sheet.paste(crop, (40 + i * (view + 40), 40), m)
    sheet.save(os.path.join(HERE, 'launcher_icon_preview.png'))
    print('launcher icons written; preview:', os.path.join(HERE, 'launcher_icon_preview.png'))
