"""Play Store feature graphic, 1024x500.

Spec: exactly 1024x500, JPEG or 24-bit PNG with no alpha (Google Play Console
Help 9866151). Everything important sits inside x 100-924, y 50-450. The
centre (512, 250) stays free of text, because Play puts a play button there
when a promo video exists. No "free", "best", "#1", badges or device imagery.

Layout: headline on the left, the icon's 3D earbuds with blue/pink glow on
the right (an illustration, not a copy of the icon tile).

Run: python3 store_assets/feature_graphic/make_feature_graphic.py
"""
import os
import sys
import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'icon'))
import generate_icon_3d as hp3d  # noqa: E402  (reuses the icon's earbuds)

W, H, K = 1024, 500, 2                 # rendered at 2x, then downscaled
FONT = '/System/Library/Fonts/Avenir Next.ttc'
HEAVY, DEMI = 8, 2
BLUE, PINK = (0x4A, 0x90, 0xE2), (0xE9, 0x4E, 0x77)


def background():
    w, h = W * K, H * K
    yy, xx = np.mgrid[0:h // 4, 0:w // 4].astype(float)
    u, v = xx / (w // 4), yy / (h // 4)
    top, bot = np.array([36, 34, 76.]), np.array([16, 15, 34.])
    col = top * (1 - v)[..., None] + bot * v[..., None]
    col = col * (1.0 - 0.10 * u)[..., None]
    img = Image.fromarray(col.astype(np.uint8)).resize((w, h), Image.BICUBIC).convert('RGBA')
    glow = Image.new('RGBA', (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(glow)
    d.ellipse((1080, -80, 1560, 400), fill=BLUE + (120,))
    d.ellipse((1500, 560, 2040, 1100), fill=PINK + (120,))
    d.ellipse((-300, 300, 500, 1100), fill=(90, 80, 170, 60))
    img.alpha_composite(glow.filter(ImageFilter.GaussianBlur(160)))
    return img


def earbuds_art(width):
    """The 3D earbuds + glow from the icon generator, cropped and scaled."""
    hp = hp3d.headphones()
    halo = hp3d.halo(hp, strength=1.9, cap=215)
    art = Image.new('RGBA', hp.size, (0, 0, 0, 0))
    art.alpha_composite(halo)
    art.alpha_composite(hp)
    x0, y0, x1, y1 = hp.split()[3].getbbox()
    pad = int((x1 - x0) * 0.12)
    art = art.crop((x0 - pad, y0 - pad, x1 + pad, y1 + pad))
    return art.resize((width, int(art.height * width / art.width)), Image.LANCZOS)


def build():
    img = background()
    d = ImageDraw.Draw(img)
    s = lambda v: int(v * K)  # noqa: E731

    # wordmark
    mark = ImageFont.truetype(FONT, s(30), index=DEMI)
    d.text((s(100), s(104)), 'Duo Music Player', font=mark, fill=(255, 255, 255, 215))

    # headline: "Two songs." / "One per ear."
    big = ImageFont.truetype(FONT, s(50), index=HEAVY)
    y = s(160)
    d.text((s(98), y), 'Two songs.', font=big, fill=(255, 255, 255))
    y += s(62)
    x = s(98)
    for text, fill in (('One per ', (255, 255, 255)), ('ear.', (255, 120, 160))):
        d.text((x, y), text, font=big, fill=fill)
        x += d.textlength(text, font=big)

    # "Duo Mode" pill with the blue -> pink gradient
    pill_font = ImageFont.truetype(FONT, s(28), index=DEMI)
    label = 'Duo Mode'
    pw = int(d.textlength(label, font=pill_font)) + s(56)
    ph = s(54)
    px, py = s(100), s(318)
    grad = Image.new('RGBA', (pw, ph))
    gp = grad.load()
    for gx in range(pw):
        t = gx / (pw - 1)
        c = tuple(int(BLUE[i] * (1 - t) + PINK[i] * t) for i in range(3)) + (255,)
        for gy in range(ph):
            gp[gx, gy] = c
    m = Image.new('L', (pw, ph), 0)
    ImageDraw.Draw(m).rounded_rectangle((0, 0, pw - 1, ph - 1), radius=ph // 2, fill=255)
    img.paste(grad, (px, py), m)
    d.text((px + s(28), py + s(9)), label, font=pill_font, fill=(255, 255, 255))

    # earbuds on the right, clear of the centre play-button zone
    art = earbuds_art(s(350))
    ax = s(745) - art.width // 2
    ay = s(250) - art.height // 2
    img.alpha_composite(art, (ax, ay))

    out = img.convert('RGB').resize((W, H), Image.LANCZOS)
    path = os.path.join(HERE, 'duo_feature_graphic_1024x500.png')
    out.save(path, optimize=True)
    print(path, out.size, out.mode, f'{os.path.getsize(path) // 1024} KB')

    # preview with the safe zone and the play-button zone outlined
    pv = out.copy()
    pd = ImageDraw.Draw(pv)
    pd.rectangle((100, 50, 924, 450), outline=(0, 255, 120), width=2)
    pd.ellipse((512 - 90, 250 - 90, 512 + 90, 250 + 90), outline=(255, 220, 0), width=2)
    pv.save(os.path.join(HERE, '_safe_zone_preview.png'))


if __name__ == '__main__':
    build()
