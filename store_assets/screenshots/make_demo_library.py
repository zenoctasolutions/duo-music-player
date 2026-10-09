"""Builds a royalty-free demo music library for Play Store screenshots.

All artists, albums and titles are fictional, the audio is synthesized with
ffmpeg, the cover art is generated, and the lyrics are original. Nothing here
belongs to a real artist or label.

Output: store_assets/screenshots/demo_library/<Album>/<NN - Title>.<ext>
Run:    python3 store_assets/screenshots/make_demo_library.py
Push:   adb push demo_library/. /sdcard/Music/
"""
import math
import os
import random
import subprocess
from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'demo_library')

# (album, artist, genre, year, palette, [(title, seconds, root_hz)], ext)
ALBUMS = [
    ('Neon Horizon', 'Luna Vale', 'Synthwave', 2025, [(255, 64, 160), (60, 40, 170), (20, 12, 48)],
     [('Midnight Drive', 214, 110), ('City of Glass', 238, 123), ('Afterglow', 201, 98)], 'flac'),
    ('Harbor Lights', 'Coral Avenue', 'Indie Pop', 2024, [(64, 200, 220), (40, 110, 200), (250, 220, 170)],
     [('Ocean Letters', 187, 146), ('Summer Static', 205, 164), ('Paper Boats', 176, 130)], 'mp3'),
    ('Golden Hour', 'Mira Solis', 'Pop', 2025, [(255, 190, 80), (240, 100, 90), (120, 40, 90)],
     [('Golden Hour', 199, 138), ('Slow Motion', 222, 155), ('Heartbeat Radio', 183, 174)], 'mp3'),
    ('Quiet Forest', 'Aurel Winds', 'Ambient', 2023, [(90, 170, 120), (30, 80, 70), (220, 235, 200)],
     [('Morning Rain', 265, 87), ('Moss & Stone', 243, 98), ('Firefly Path', 251, 110)], 'mp3'),
    ('Velvet Nights', 'Jonah Reyes', 'R&B', 2024, [(150, 60, 200), (40, 20, 80), (230, 120, 200)],
     [('Velvet', 208, 116), ('Late Calls', 226, 104)], 'm4a'),
    ('Concrete Dreams', 'Kairo Beats', 'Hip Hop', 2025, [(250, 90, 40), (30, 30, 36), (250, 200, 60)],
     [('Rise Up', 194, 82), ('Concrete Dreams', 212, 92), ('Night Shift', 189, 73)], 'mp3'),
]

# Original lyrics (written for this demo), timed for the hero track.
LYRICS = {
    'Midnight Drive': [
        (0, 'Headlights on an empty road'), (6, 'City humming soft and low'),
        (12, 'Every signal turning green'), (18, 'Like the night was made for me'),
        (24, 'Windows down, the air is cool'), (30, 'Neon painting every view'),
        (36, 'Turn it up and let it play'), (42, 'We can drive until the day'),
        (48, 'Midnight drive, just you and I'), (54, 'Chasing stars across the sky'),
        (60, 'Midnight drive, the world asleep'), (66, 'Every mile a song to keep'),
        (72, 'Radio glow on the dash'), (78, 'Moments here that never pass'),
        (84, 'Hold the wheel and hold the tune'), (90, 'Racing shadows of the moon'),
    ],
}


def cover(palette, seed, path):
    """Abstract generated artwork: gradient, soft orbs and a few lines."""
    rnd = random.Random(seed)
    S = 1200
    a, b, c = palette
    img = Image.new('RGB', (S, S))
    px = img.load()
    for y in range(0, S, 4):
        for x in range(0, S, 4):
            t = (x + y) / (2 * S)
            col = tuple(int(a[i] * (1 - t) + b[i] * t) for i in range(3))
            for dy in range(4):
                for dx in range(4):
                    px[x + dx, y + dy] = col
    layer = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    for _ in range(5):
        r = rnd.randint(150, 420)
        x, y = rnd.randint(0, S), rnd.randint(0, S)
        col = rnd.choice([a, b, c])
        d.ellipse((x - r, y - r, x + r, y + r), fill=col + (rnd.randint(90, 170),))
    img = Image.alpha_composite(img.convert('RGBA'), layer.filter(ImageFilter.GaussianBlur(60)))
    lines = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(lines)
    cx, cy = rnd.randint(350, 850), rnd.randint(350, 850)
    for i in range(rnd.randint(3, 6)):
        r = 120 + i * 70
        d.ellipse((cx - r, cy - r, cx + r, cy + r), outline=c + (150,), width=6)
    img = Image.alpha_composite(img, lines)
    img.convert('RGB').resize((600, 600), Image.LANCZOS).save(path, quality=90)


def tone_expr(root, seconds):
    """A soft chord with slow tremolo and a fade in/out, so it sounds pleasant."""
    f = [root, root * 1.26, root * 1.5, root * 2]
    parts = '+'.join(f'{0.18 / (k + 1):.3f}*sin(2*PI*{fr:.2f}*t)' for k, fr in enumerate(f))
    return (f'({parts})*(0.75+0.25*sin(2*PI*0.25*t))'
            f'*min(1,t/3)*min(1,({seconds}-t)/4)')


def build():
    os.makedirs(ROOT, exist_ok=True)
    seed = 0
    for album, artist, genre, year, palette, tracks, ext in ALBUMS:
        folder = os.path.join(ROOT, album)
        os.makedirs(folder, exist_ok=True)
        art = os.path.join(folder, 'cover.jpg')
        cover(palette, seed, art)
        seed += 1
        for n, (title, secs, root) in enumerate(tracks, 1):
            out = os.path.join(folder, f'{n:02d} - {title}.{ext}')
            if os.path.exists(out):
                continue
            src = ['-f', 'lavfi', '-i', f"aevalsrc='{tone_expr(root, secs)}|{tone_expr(root * 1.003, secs)}':s=" +
                   ('96000' if ext == 'flac' else '44100') + f':d={secs}']
            meta = ['-metadata', f'title={title}', '-metadata', f'artist={artist}',
                    '-metadata', f'album={album}', '-metadata', f'album_artist={artist}',
                    '-metadata', f'genre={genre}', '-metadata', f'date={year}',
                    '-metadata', f'track={n}/{len(tracks)}']
            if ext == 'mp3':
                codec = ['-c:a', 'libmp3lame', '-b:a', '320k', '-id3v2_version', '3']
            elif ext == 'flac':
                codec = ['-c:a', 'flac', '-sample_fmt', 's32', '-bits_per_raw_sample', '24']
            else:
                codec = ['-c:a', 'aac', '-b:a', '256k']
            cmd = (['ffmpeg', '-v', 'error', '-y'] + src + ['-i', art, '-map', '0:a', '-map', '1:v'] +
                   codec + ['-c:v', 'mjpeg' if ext != 'm4a' else 'copy', '-disposition:v', 'attached_pic'] +
                   meta + [out])
            subprocess.run(cmd, check=True)
            if title in LYRICS:
                with open(os.path.splitext(out)[0] + '.lrc', 'w') as fh:
                    fh.write(f'[ti:{title}]\n[ar:{artist}]\n')
                    for sec, line in LYRICS[title]:
                        fh.write(f'[{sec // 60:02d}:{sec % 60:02d}.00]{line}\n')
            print('made', os.path.relpath(out, ROOT))


if __name__ == '__main__':
    build()
