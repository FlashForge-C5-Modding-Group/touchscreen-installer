#!/usr/bin/env python3
"""Render the boot logo (/usr/prog/logo.jpeg) from the OpenCreator SVG: drawn
at 800x480 and saved turned a quarter turn counter-clockwise (480x800), like
FlashForge's own, because the panel's framebuffer is portrait.

Usage: python3 scripts/gen-boot-logo.py [SVG] [OUT_JPEG]
Needs Pillow.
"""
import os
import re
import sys

from PIL import Image, ImageChops, ImageDraw, ImageFont

WIDTH, HEIGHT = 800, 480
SS = 4
BACKGROUND = (0x15, 0x1A, 0x22)
GRADIENT = ((0xFF, 0x6A, 0x2B), (0xFF, 0xB0, 0x2E))
TEXT = (0xF5, 0xF2, 0xEC)
LOGO_WIDTH = 380
FONTS = (
    "/usr/share/fonts/truetype/ubuntu/Ubuntu-B.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
)


def parse(svg):
    vb = [float(v) for v in re.search(r'viewBox="([^"]+)"', svg).group(1).split()]
    d = re.search(r'\sd="([^"]+)"', svg).group(1)
    polys = []
    for sub in re.split(r"[Zz]", d):
        pts = [(float(x), float(y))
               for x, y in re.findall(r"[ML]\s*([-\d.]+)[ ,]+([-\d.]+)", sub)]
        if len(pts) > 2:
            polys.append(pts)
    return vb, polys


def logo_mask(vb, polys, width):
    vx, vy, vw, vh = vb
    height = round(width * vh / vw)
    scale = width * SS / vw
    mask = Image.new("L", (width * SS, height * SS), 0)
    for pts in polys:
        layer = Image.new("L", mask.size, 0)
        ImageDraw.Draw(layer).polygon(
            [((x - vx) * scale, (y - vy) * scale) for x, y in pts], fill=255)
        mask = ImageChops.logical_xor(mask.convert("1"), layer.convert("1")).convert("L")
    return mask.resize((width, height), Image.LANCZOS)


def gradient(size):
    w, h = size
    image = Image.new("RGB", size)
    pixels = image.load()
    (r0, g0, b0), (r1, g1, b1) = GRADIENT
    for y in range(h):
        for x in range(w):
            t = (x / max(w - 1, 1) + y / max(h - 1, 1)) / 2
            pixels[x, y] = (round(r0 + (r1 - r0) * t), round(g0 + (g1 - g0) * t),
                            round(b0 + (b1 - b0) * t))
    return image


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    svg_path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(root, "opencreator-oc-white.svg")
    out = sys.argv[2] if len(sys.argv) > 2 else os.path.join(
        root, "payload-template", "common", "logo.jpeg")
    vb, polys = parse(open(svg_path).read())
    mask = logo_mask(vb, polys, LOGO_WIDTH)

    image = Image.new("RGB", (WIDTH, HEIGHT), BACKGROUND)
    font = next((ImageFont.truetype(f, 46) for f in FONTS if os.path.exists(f)), None)
    text = "OpenCreator"
    text_h = 0
    if font:
        left, top, right, bottom = font.getbbox(text)
        text_w, text_h = right - left, bottom - top
    gap = 34 if font else 0
    top_y = (HEIGHT - mask.height - gap - text_h) // 2
    image.paste(gradient(mask.size), ((WIDTH - mask.width) // 2, top_y), mask)
    if font:
        ImageDraw.Draw(image).text(
            ((WIDTH - text_w) // 2 - left, top_y + mask.height + gap - top),
            text, font=font, fill=TEXT)
    image = image.transpose(Image.ROTATE_90)
    image.save(out, "JPEG", quality=92, optimize=True)
    print(out, image.size)


if __name__ == "__main__":
    main()
