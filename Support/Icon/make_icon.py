#!/usr/bin/env python3
"""Draws the app icon: a tilted instant photo of a smiling sun over green hills, with a turning arrow.

    python3 Support/Icon/make_icon.py      # writes Support/Icon/AppIcon.png and Support/AppIcon.icns

Needs Pillow. Drawn at 2048 px and scaled down for smooth edges.
"""
import math
import os

from PIL import Image, ImageDraw, ImageFilter

S = 2048
HERE = os.path.dirname(os.path.abspath(__file__))


def vertical_gradient(size, top, bottom):
    w, h = size
    gradient = Image.new("RGBA", size)
    draw = ImageDraw.Draw(gradient)
    for y in range(h):
        t = y / max(h - 1, 1)
        draw.line([(0, y), (w, y)], fill=tuple(int(a + (b - a) * t) for a, b in zip(top, bottom)) + (255,))
    return gradient


def rounded_mask(size, box, radius):
    mask = Image.new("L", size, 0)
    ImageDraw.Draw(mask).rounded_rectangle(box, radius=radius, fill=255)
    return mask


def main():
    icon = Image.new("RGBA", (S, S), (0, 0, 0, 0))

    # Tile: macOS icon grid (824/1024 of the canvas), soft drop shadow, pastel peach-to-lavender gradient.
    inset = S * 100 // 1024
    tile_box = (inset, inset, S - inset, S - inset)
    radius = S * 185 // 1024
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        (tile_box[0], tile_box[1] + 24, tile_box[2], tile_box[3] + 24), radius=radius, fill=(60, 30, 80, 90))
    icon.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(28)))
    tile = vertical_gradient((S, S), (255, 214, 196), (214, 196, 255))
    icon.paste(tile, (0, 0), rounded_mask((S, S), tile_box, radius))

    # The photo: an instant-photo card with a little landscape.
    card_w, card_h = 1000, 1120
    card = Image.new("RGBA", (card_w, card_h), (0, 0, 0, 0))
    cd = ImageDraw.Draw(card)
    cd.rounded_rectangle((0, 0, card_w, card_h), radius=56, fill=(255, 255, 255, 255))
    pad = 70
    photo_box = (pad, pad, card_w - pad, pad + 840)
    pw, ph = photo_box[2] - photo_box[0], photo_box[3] - photo_box[1]
    photo = vertical_gradient((pw, ph), (150, 214, 255), (214, 240, 255))
    pd = ImageDraw.Draw(photo)
    # Rolling hills.
    pd.ellipse((-260, ph * 0.62, pw * 0.75, ph * 1.6), fill=(120, 205, 140, 255))
    pd.ellipse((pw * 0.3, ph * 0.70, pw + 300, ph * 1.7), fill=(92, 186, 120, 255))
    # The sun, with a happy face and rosy cheeks.
    cx, cy, r = pw * 0.66, ph * 0.36, 170
    for i in range(12):
        a = i * math.pi / 6
        x1, y1 = cx + math.cos(a) * (r + 40), cy + math.sin(a) * (r + 40)
        x2, y2 = cx + math.cos(a) * (r + 105), cy + math.sin(a) * (r + 105)
        pd.line([(x1, y1), (x2, y2)], fill=(255, 196, 64, 255), width=34)
    pd.ellipse((cx - r, cy - r, cx + r, cy + r), fill=(255, 210, 80, 255))
    eye = 22
    for ex in (cx - 62, cx + 62):
        pd.ellipse((ex - eye, cy - 40 - eye * 1.3, ex + eye, cy - 40 + eye * 1.3), fill=(80, 50, 40, 255))
    pd.arc((cx - 70, cy - 40, cx + 70, cy + 70), start=20, end=160, fill=(80, 50, 40, 255), width=18)
    for bx in (cx - 112, cx + 112):
        pd.ellipse((bx - 34, cy + 6, bx + 34, cy + 46), fill=(255, 150, 150, 200))
    card.paste(photo, photo_box[:2], rounded_mask((pw, ph), (0, 0, pw, ph), 26))

    # Card shadow, then the card itself, tilted as if it's being turned upright.
    tilt = 12
    card_shadow = Image.new("RGBA", card.size, (0, 0, 0, 0))
    card_shadow.paste((70, 40, 90, 110), (0, 0), card.split()[3])
    card_shadow = card_shadow.rotate(tilt, resample=Image.BICUBIC, expand=True).filter(ImageFilter.GaussianBlur(24))
    rotated = card.rotate(tilt, resample=Image.BICUBIC, expand=True)
    x = (S - rotated.width) // 2
    y = (S - rotated.height) // 2 + 40
    icon.alpha_composite(card_shadow, (x + 10, y + 34))
    icon.alpha_composite(rotated, (x, y))

    # A curved arrow sweeping round the top-right corner: "turn me".
    arrow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ad = ImageDraw.Draw(arrow)
    coral = (255, 107, 129, 255)
    rr = 640
    ring = (S * 0.5 - rr, S * 0.5 - rr, S * 0.5 + rr, S * 0.5 + rr)
    start, end = 232, 338
    ad.arc(ring, start=start, end=end, fill=coral, width=88)
    # Arrowhead at the end of the arc, pointing clockwise.
    a = math.radians(end)
    tip_center = (S * 0.5 + rr * math.cos(a), S * 0.5 + rr * math.sin(a))
    tangent = (-math.sin(a), math.cos(a))
    normal = (math.cos(a), math.sin(a))
    length, half = 170, 120
    tip = (tip_center[0] + tangent[0] * length, tip_center[1] + tangent[1] * length)
    base1 = (tip_center[0] + normal[0] * half, tip_center[1] + normal[1] * half)
    base2 = (tip_center[0] - normal[0] * half, tip_center[1] - normal[1] * half)
    ad.polygon([tip, base1, base2], fill=coral)
    # Round cap at the start.
    a0 = math.radians(start)
    sx, sy = S * 0.5 + rr * math.cos(a0), S * 0.5 + rr * math.sin(a0)
    ad.ellipse((sx - 44, sy - 44, sx + 44, sy + 44), fill=coral)
    arrow_shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    arrow_shadow.paste((120, 30, 60, 90), (0, 0), arrow.split()[3])
    icon.alpha_composite(arrow_shadow.filter(ImageFilter.GaussianBlur(14)), (0, 14))
    icon.alpha_composite(arrow)

    final = icon.resize((1024, 1024), Image.LANCZOS)
    final.save(os.path.join(HERE, "AppIcon.png"))
    final.save(os.path.join(HERE, "..", "AppIcon.icns"),
               sizes=[(16, 16), (32, 32), (64, 64), (128, 128), (256, 256), (512, 512), (1024, 1024)])
    print("wrote AppIcon.png and AppIcon.icns")


if __name__ == "__main__":
    main()
