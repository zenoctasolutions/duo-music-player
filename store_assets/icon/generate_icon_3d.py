"""Generates the 3D Duo logo Play Store icon.

Spec (developer.android.com/distribute/google-play/resources/icon-design-specifications):
512x512, 32-bit PNG, sRGB, <= 1024 KB, full square. Play applies the 30 %
corner radius and the outer drop shadow itself, so neither is baked in.
Lighting and shadows live inside the artwork only. The mark stays inside
a ~16 % safe margin so the rounded mask never clips them.

Colors come from lib/duo_page.dart: kDuoLeftColor (blue) / kDuoRightColor (pink).

Run: python3 store_assets/icon/generate_icon_3d.py
"""
import os
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

OUT = os.path.dirname(os.path.abspath(__file__))
S = 2048
BLUE = np.array([0x4A, 0x90, 0xE2], float)
PINK = np.array([0xE9, 0x4E, 0x77], float)

yy, xx = np.mgrid[0:S, 0:S].astype(float)
U, V = xx / (S - 1), yy / (S - 1)


def rgba(arr, alpha=None):
    arr = np.clip(arr, 0, 255)
    a = np.full(arr.shape[:2], 255.0) if alpha is None else np.clip(alpha, 0, 255)
    return Image.fromarray(np.dstack([arr, a]).astype(np.uint8), 'RGBA')


def mix(c1, c2, t):
    t = np.clip(t, 0, 1)[..., None]
    return c1 * (1 - t) + c2 * t


def mask_of(draw_fn):
    m = Image.new('L', (S, S), 0)
    draw_fn(ImageDraw.Draw(m))
    return m


# ---------------------------------------------------------------- background
BG_STOPS = {
    'duo': ((70, 22, 58), (20, 20, 44), (18, 44, 96)),
    'light': ((255, 212, 226), (240, 232, 255), (200, 224, 255)),
}
BG_HEX = {
    'duo': ('#46163A', '#14142C', '#122C60'),
    'light': ('#FFD4E2', '#F0E8FF', '#C8E0FF'),
}

def background(style):
    # Opposite of the note: the note runs blue -> pink, the background runs
    # pink -> blue. 'duo' = deep dark, 'light' = pale pastel (light mode).
    left, mid, right = BG_STOPS['light' if style == 'light' else 'duo']
    left, mid, right = (np.array(c, float) for c in (left, mid, right))
    t = U * 0.85 + V * 0.15
    col = np.where((t < 0.5)[..., None], mix(left, mid, t * 2), mix(mid, right, (t - 0.5) * 2))
    img = rgba(col)
    return img
    glow = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    g = ImageDraw.Draw(glow)
    g.ellipse((S * 0.00, S * 0.38, S * 0.50, S * 0.88), fill=tuple(BLUE.astype(int)) + (0,))
    g.ellipse((S * 0.50, S * 0.38, S * 1.00, S * 0.88), fill=tuple(PINK.astype(int)) + (0,))
    img.alpha_composite(glow.filter(ImageFilter.GaussianBlur(170)))
    return img


# ---------------------------------------------------------------- headphones
CX = S * 0.50
ARC_CY = S * 0.515            # centre of the headband arc
R_OUT, R_IN = S * 0.338, S * 0.258
CUP_TOP, CUP_BOT = S * 0.515, S * 0.815
CUP_W = S * 0.178
CUP_L = S * 0.155             # left cup's outer x (keeps a 16 % margin)
CUP_R = S - CUP_L


def band_layer():
    """White headband with tube shading: arc on top plus two straight drops."""
    dx, dy = xx - CX, yy - ARC_CY
    r = np.where(dy <= 0, np.hypot(dx, dy), np.abs(dx))
    inside = (r >= R_IN) & (r <= R_OUT) & (yy <= CUP_TOP + S * 0.04)
    t = (r - R_IN) / (R_OUT - R_IN)                     # 0 = inner edge, 1 = outer edge
    # tube profile: darker at both edges, bright ridge a bit toward the outside
    shade = 0.78 + 0.26 * np.sin(np.pi * np.clip(t, 0, 1)) ** 0.8
    light = 1.0 - 0.10 * V                              # top brighter than the drops
    base = np.array([242, 244, 252.])
    col = base * (shade * light)[..., None]
    ridge = np.exp(-((t - 0.62) / 0.09) ** 2) * (dy <= S * 0.02)
    col = col + 40 * ridge[..., None]
    alpha = inside * 255.0
    lay = rgba(col, alpha)
    return lay.filter(ImageFilter.GaussianBlur(1.2))


def yoke(draw, x0, x1):
    """Small grey slider joint where the band meets a cup."""
    draw.rounded_rectangle((x0, CUP_TOP - S * 0.045, x1, CUP_TOP + S * 0.03), radius=S * 0.018, fill=255)


def cup_layer(color, left):
    x0 = CUP_L if left else CUP_R - CUP_W
    x1 = x0 + CUP_W
    rad = S * 0.07
    shell = mask_of(lambda d: d.rounded_rectangle((x0, CUP_TOP, x1, CUP_BOT), radius=rad, fill=255))
    # ear cushion peeking out on the inner side (toward the centre)
    off = S * 0.032 * (1 if left else -1)
    pad = mask_of(lambda d: d.rounded_rectangle((x0 + off, CUP_TOP + S * 0.02, x1 + off, CUP_BOT - S * 0.02),
                                                radius=rad * 0.9, fill=255))
    out = Image.new('RGBA', (S, S), (0, 0, 0, 0))

    # cushion: dark, softly shaded
    pc = mix(color * 0.30, color * 0.55, 1 - np.abs((yy - (CUP_TOP + CUP_BOT) / 2) / ((CUP_BOT - CUP_TOP) / 2)))
    out.alpha_composite(rgba(pc, np.array(pad, float)))

    # shell: horizontal cylinder shading plus top-to-bottom falloff
    u = (xx - x0) / CUP_W                                # 0..1 across the cup
    v = (yy - CUP_TOP) / (CUP_BOT - CUP_TOP)
    light_x = 0.38 if left else 0.62                     # light from above-centre of icon
    shade = 0.62 + 0.48 * np.exp(-((u - light_x) / 0.42) ** 2)
    shade = shade * (1.10 - 0.30 * np.clip(v, 0, 1))
    col = color * shade[..., None]
    out.alpha_composite(rgba(col, np.array(shell, float)))

    # rim light along the shell edge
    edge = np.array(shell.filter(ImageFilter.GaussianBlur(10)), float)
    ring = np.clip(np.array(shell, float) - edge, 0, 255) * 1.4
    out.alpha_composite(rgba(np.full((S, S, 3), 255.0), ring * 0.55))

    # glossy highlight near the top of the shell
    hl = mask_of(lambda d: d.rounded_rectangle((x0 + CUP_W * 0.22, CUP_TOP + S * 0.028,
                                                x1 - CUP_W * 0.22, CUP_TOP + S * 0.10),
                                               radius=S * 0.03, fill=255)).filter(ImageFilter.GaussianBlur(16))
    out.alpha_composite(rgba(np.full((S, S, 3), 255.0), np.array(hl, float) * 0.45))
    return out


def yokes_layer():
    m = mask_of(lambda d: (yoke(d, CX - R_OUT - S * 0.008, CX - R_IN + S * 0.008),
                           yoke(d, CX + R_IN - S * 0.008, CX + R_OUT + S * 0.008)))
    col = mix(np.array([200, 204, 222.]), np.array([120, 124, 150.]), (yy - (CUP_TOP - S * 0.045)) / (S * 0.075))
    return rgba(col, np.array(m, float))


# Two overlapping glass discs (left ear / right ear, stereo) with a white
# music note in the glowing overlap.
DISC_R = S * 0.222
DISC_DX = S * 0.125
DISC_CY = S * 0.50


def _disc_mask(cx):
    return mask_of(lambda d: d.ellipse((cx - DISC_R, DISC_CY - DISC_R, cx + DISC_R, DISC_CY + DISC_R), fill=255))


def _disc_color(cx, c_top, c_bot):
    t = np.clip((yy - (DISC_CY - DISC_R)) / (2 * DISC_R), 0, 1)
    # diagonal: lighter at the top-outer side, deeper toward the bottom-inner side
    t = np.clip(t * 0.8 + (np.abs(xx - cx) / DISC_R) * 0.0, 0, 1)
    return mix(c_top, c_bot, t)


# ---- the note as clean vector geometry, in a 1024 x 1024 design space ----
# Shared by the PNG renderer below and the SVG writer (write_svgs).
import math
DY = 27
NOTE_HEADS = [(368, 700 + DY), (662, 650 + DY)]      # centres of the two heads
HEAD_RX, HEAD_RY, HEAD_ROT = 80, 60, -20             # degrees, tilted up to the right
NOTE_STEMS = [(426, 300 + DY, 700 + DY), (720, 250 + DY, 650 + DY)]   # x centre, top, bottom
STEM_W = 34
NOTE_BEAM = [(409, 255 + DY), (737, 205 + DY), (737, 305 + DY), (409, 355 + DY)]
NOTE_X0, NOTE_X1 = 288, 737
BLUE_HEX, VIOLET_HEX, PINK_HEX = '#4A90E2', '#9A6AE8', '#E94E77'


def _ellipse_pts(cx, cy, rx, ry, rot, n=180):
    c, s_ = math.cos(math.radians(rot)), math.sin(math.radians(rot))
    pts = []
    for i in range(n):
        t = 2 * math.pi * i / n
        x, y = rx * math.cos(t), ry * math.sin(t)
        pts.append((cx + x * c - y * s_, cy + x * s_ + y * c))
    return pts


def big_note_mask():
    """Anti-aliased note mask (S x S), supersampled 2x from the design space."""
    k = S / 1024.0
    big = Image.new('L', (S * 2, S * 2), 0)
    d = ImageDraw.Draw(big)
    f = k * 2
    for cx, cy in NOTE_HEADS:
        d.polygon([(x * f, y * f) for x, y in _ellipse_pts(cx, cy, HEAD_RX, HEAD_RY, HEAD_ROT)], fill=255)
    for x, top, bot in NOTE_STEMS:
        d.rectangle(((x - STEM_W / 2) * f, top * f, (x + STEM_W / 2) * f, bot * f), fill=255)
    d.polygon([(x * f, y * f) for x, y in NOTE_BEAM], fill=255)
    return big.resize((S, S), Image.LANCZOS)


def _grad_t():
    """0..1 position across the note, for the blue -> violet -> pink gradient."""
    return np.clip((xx / S * 1024 - NOTE_X0) / (NOTE_X1 - NOTE_X0), 0, 1)


def write_svgs():
    """duo_logo.svg (note only, transparent) and duo_icon.svg (on the app background)."""
    def shapes():
        out = []
        for cx, cy in NOTE_HEADS:
            out.append(f'<ellipse cx="{cx}" cy="{cy}" rx="{HEAD_RX}" ry="{HEAD_RY}" transform="rotate({HEAD_ROT} {cx} {cy})"/>')
        for x, top, bot in NOTE_STEMS:
            out.append(f'<rect x="{x - STEM_W // 2}" y="{top}" width="{STEM_W}" height="{bot - top}"/>')
        out.append('<polygon points="' + ' '.join(f'{x},{y}' for x, y in NOTE_BEAM) + '"/>')
        return '\n    '.join(out)
    grad = (f'<linearGradient id="duo" gradientUnits="userSpaceOnUse" x1="{NOTE_X0}" y1="0" x2="{NOTE_X1}" y2="0">'
            f'<stop offset="0.22" stop-color="{BLUE_HEX}"/><stop offset="0.5" stop-color="{VIOLET_HEX}"/>'
            f'<stop offset="0.78" stop-color="{PINK_HEX}"/></linearGradient>')
    note = f'<g fill="url(#duo)">\n    {shapes()}\n  </g>'
    head = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">'
    open(os.path.join(OUT, 'duo_logo.svg'), 'w').write(f'{head}\n  <defs>{grad}</defs>\n  {note}\n</svg>\n')
    for style, name in (('duo', 'duo_icon.svg'), ('light', 'duo_icon_light.svg')):
        c0, c1, c2 = BG_HEX[style]
        bg = (f'<linearGradient id="bg" x1="0" y1="0" x2="1" y2="0.18"><stop offset="0" stop-color="{c0}"/>'
              f'<stop offset="0.5" stop-color="{c1}"/><stop offset="1" stop-color="{c2}"/></linearGradient>')
        open(os.path.join(OUT, name), 'w').write(
            f'{head}\n  <defs>{grad}{bg}</defs>\n  <rect width="1024" height="1024" fill="url(#bg)"/>\n  {note}\n</svg>\n')


def logo_mark():
    """Duo mark: one music note fading from blue (left) to pink (right)."""
    nm = big_note_mask()
    m = np.array(nm, float)
    t = _grad_t()
    u = np.clip((t - 0.22) / 0.56, 0, 1)
    VIOLET = np.array([0x9A, 0x6A, 0xE8], float)
    col = np.where((u < 0.5)[..., None], mix(BLUE, VIOLET, u * 2), mix(VIOLET, PINK, (u - 0.5) * 2))
    lay = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    lay.alpha_composite(rgba(col, m))
    return lay


def logo_mono():
    """Alpha-only silhouette for Android 13 themed icons."""
    return big_note_mask()


def headphones():
    """Name kept for the launcher / feature-graphic scripts: the Duo logo mark."""
    return logo_mark()


def contact_shadow(obj):
    """Soft shadow of the logo on the background (inside the artwork)."""
    a = np.array(obj.split()[3], float)
    sh = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    sh.putalpha(Image.fromarray((a * 0.0).astype(np.uint8)))
    moved = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    moved.alpha_composite(sh, (0, int(S * 0.028)))
    return moved.filter(ImageFilter.GaussianBlur(38))


def build(style, name):
    img = background(style)
    hp = headphones()
    img.alpha_composite(contact_shadow(hp))
    img.alpha_composite(hp)
    out = img.resize((512, 512), Image.LANCZOS)
    path = os.path.join(OUT, name)
    out.save(path, optimize=True)
    return path


def halo(hp, strength=1.6, cap=200):
    """Soft glow around the logo: blue on the left ear, pink on the right."""
    a = np.array(hp.split()[3].filter(ImageFilter.GaussianBlur(S * 0.035)), float) * 0
    return rgba(mix(BLUE, PINK, (U - 0.3) / 0.4), np.clip(a, 0, cap))


def build_glow(style, name, sizes=(512, 1024)):
    """The glow logo on a full-bleed background: Play icon (512) and hi-res (1024)."""
    img = background(style)
    hp = headphones()
    img.alpha_composite(contact_shadow(hp))
    img.alpha_composite(halo(hp, strength=1.9, cap=215))
    img.alpha_composite(hp)
    paths = []
    for s in sizes:
        path = os.path.join(OUT, name.format(s))
        img.resize((s, s), Image.LANCZOS).save(path, optimize=True)
        paths.append(path)
    return paths


def transparent_logo(glow, name, size=1024, margin=0.07):
    """Logo only on a transparent background, ."""
    hp = headphones()
    box = hp.split()[3].getbbox()
    w, h = box[2] - box[0], box[3] - box[1]
    side = int(max(w, h) / (1 - 2 * margin))
    canvas = Image.new('RGBA', (side, side), (0, 0, 0, 0))
    ox, oy = (side - w) // 2 - box[0], (side - h) // 2 - box[1]
    if glow:
        # soft halo: blue on the left ear, pink on the right, fading outward
        a = Image.new('L', (side, side), 0)
        a.paste(hp.split()[3], (ox, oy))
        halo_a = np.array(a.filter(ImageFilter.GaussianBlur(side * 0.035)), float) * 0
        u = np.linspace(0, 1, side)[None, :].repeat(side, 0)
        col = mix(BLUE, PINK, (u - 0.3) / 0.4)
        canvas.alpha_composite(rgba(col, np.clip(halo_a, 0, 200)))
    canvas.alpha_composite(hp, (ox, oy))
    out = canvas.resize((size, size), Image.LANCZOS)
    path = os.path.join(OUT, name)
    out.save(path, optimize=True)
    return path


def checker_preview(paths):
    """Transparent logos shown on a checkerboard, white and dark."""
    n, s, pad = len(paths), 300, 20
    sheet = Image.new('RGB', (pad + (s + pad) * 3, pad + (s + pad) * n), (255, 255, 255))
    tile = Image.new('RGB', (s, s), (255, 255, 255))
    d = ImageDraw.Draw(tile)
    for i in range(0, s, 20):
        for j in range(0, s, 20):
            if (i // 20 + j // 20) % 2:
                d.rectangle((i, j, i + 19, j + 19), fill=(220, 220, 220))
    bgs = [tile, Image.new('RGB', (s, s), (255, 255, 255)), Image.new('RGB', (s, s), (18, 18, 22))]
    for r, p in enumerate(paths):
        logo = Image.open(p).convert('RGBA').resize((s, s), Image.LANCZOS)
        for c, bg in enumerate(bgs):
            cell = bg.copy().convert('RGBA')
            cell.alpha_composite(logo)
            sheet.paste(cell.convert('RGB'), (pad + c * (s + pad), pad + r * (s + pad)))
    out = os.path.join(OUT, 'logo_transparent_preview.png')
    sheet.save(out)
    return out


def rounded(im, size):
    """Preview only: Play's 30 % corner radius."""
    im = im.resize((size, size), Image.LANCZOS)
    m = Image.new('L', (size * 4, size * 4), 0)
    ImageDraw.Draw(m).rounded_rectangle((0, 0, size * 4 - 1, size * 4 - 1), radius=int(size * 4 * 0.30), fill=255)
    return im, m.resize((size, size), Image.LANCZOS)


def preview(paths):
    sizes, pad, row = [256, 128, 72, 48], 30, 300
    half = pad + sum(s + pad for s in sizes)
    sheet = Image.new('RGB', (half * 2, pad + row * len(paths)), (245, 245, 247))
    ImageDraw.Draw(sheet).rectangle((half, 0, half * 2, sheet.height), fill=(32, 33, 36))
    for r, p in enumerate(paths):
        icon = Image.open(p).convert('RGBA')
        for side in range(2):
            x = side * half + pad
            for s in sizes:
                im, m = rounded(icon, s)
                sheet.paste(im, (x, pad + r * row + (256 - s) // 2), m)
                x += s + pad
    out = os.path.join(OUT, 'icon_3d_preview.png')
    sheet.save(out)
    return out


if __name__ == '__main__':
    write_svgs()
    paths = [build('duo', 'duo_icon_3D_duo_gradient.png'),
]
    for p in paths:
        im = Image.open(p)
        print(os.path.basename(p), im.size, im.mode, f'{os.path.getsize(p) // 1024} KB')
    print(preview(paths))
    logos = [transparent_logo(True, 'duo_logo_glow.png', margin=0.13),
             transparent_logo(False, 'duo_logo.png')]
    for p in logos:
        im = Image.open(p)
        print(os.path.basename(p), im.size, im.mode, f'{os.path.getsize(p) // 1024} KB',
              'alpha', im.getchannel('A').getextrema())
    print(checker_preview(logos))
    glow = [build_glow('duo', 'duo_icon_3D_glow_duo_{}.png'),
]
    for pair in glow:
        for p in pair:
            im = Image.open(p)
            print(os.path.basename(p), im.size, im.mode, f'{os.path.getsize(p) // 1024} KB',
                  'min alpha', im.getchannel('A').getextrema()[0])
    build_glow('light', 'duo_icon_light_{}.png')
    os.replace(preview([g[0] for g in glow]), os.path.join(OUT, 'icon_3d_glow_preview.png'))
    print(os.path.join(OUT, 'icon_3d_glow_preview.png'))
    preview(paths)  # the glow preview reused this file name, so rebuild the plain one
