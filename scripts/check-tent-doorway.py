#!/usr/bin/env python3
"""Render the packaged tent doorway over its PixelLab export, for checking a door box by eye.

Reads Home's tent record, branding/tent-home.json (its source, the logo's PixelLab sprite, the crop window and the
door seed and box in source pixels), and the packaged branding/tent-mono.png and tent-doorway.png, which are
that window's size. Writes one PNG with three panels:
the export at 8x with the doorway in red, the box in green and the seed in yellow; the opening
(white on #27313F); and Home on light paper (#354052 on #F4F0E7). The doorway is #1B222C in both.
It fails if the doorway leaves the box, overlaps the mark, or differs from the recorded pixel count.

Usage (from the project root, after swift scripts/package-tent.swift):
    python3 scripts/check-tent-doorway.py .evidence/<pass>/doorway-check.png
"""

import json
import sys
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
BRANDING = ROOT / "branding"
RECORD = json.loads((BRANDING / "tent-home.json").read_text())
CROP = RECORD["crop"]
SIDE = CROP["side"]


def rgba(path):
    image = Image.open(path).convert("RGBA")
    if image.size != (SIDE, SIDE):
        raise SystemExit(f"{path} must be {SIDE}x{SIDE}")
    return image


def alpha_mask(path):
    alpha = rgba(path).getchannel("A").load()
    return [[alpha[x, y] >= 128 for x in range(SIDE)] for y in range(SIDE)]


def rgba_crop(image):
    """The source's crop window, the packaged images' size."""
    return image.crop((CROP["x"], CROP["y"], CROP["x"] + SIDE, CROP["y"] + SIDE))


def hex_rgb(value):
    return ((value >> 16) & 255, (value >> 8) & 255, value & 255)


def main():
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    output = Path(sys.argv[1])
    door = RECORD["cleanup"]["doorway"]
    # The record's box and seed are source pixels; the packaged images are the crop window.
    box = {key: door["box"][key] - (CROP["x"] if key.endswith("X") else CROP["y"]) for key in door["box"]}
    seed = [door["seed"][0] - CROP["x"], door["seed"][1] - CROP["y"]]
    source = Image.open(BRANDING / RECORD["source"]["file"]).convert("RGBA")
    source = rgba_crop(source)
    mark = alpha_mask(BRANDING / "tent-mono.png")
    doorway = alpha_mask(BRANDING / "tent-doorway.png")

    opening = [(x, y) for y in range(SIDE) for x in range(SIDE) if doorway[y][x]]
    outside = [(x, y) for x, y in opening
               if not (box["minX"] <= x <= box["maxX"] and box["minY"] <= y <= box["maxY"])]
    overlap = [(x, y) for x, y in opening if mark[y][x]]
    bounds = {"minX": min(x for x, _ in opening) + CROP["x"], "minY": min(y for _, y in opening) + CROP["y"],
              "maxX": max(x for x, _ in opening) + CROP["x"], "maxY": max(y for _, y in opening) + CROP["y"]}
    if bounds != door["bounds"]:
        raise SystemExit(f"Doorway check failed: bounds {bounds} differ from the recorded {door['bounds']}")
    if outside or overlap or len(opening) != door["pixels"]:
        raise SystemExit(f"Doorway check failed: {len(opening)} px (recorded {door['pixels']}), "
                         f"{len(outside)} outside the box, {len(overlap)} overlapping the mark")

    big, small, gap = 8, 4, 24
    width = SIDE * big + 2 * (SIDE * small) + 4 * gap
    height = SIDE * big + 2 * gap + 40
    sheet = Image.new("RGB", (width, height), (255, 255, 255))
    draw = ImageDraw.Draw(sheet)
    draw.text((gap, 10), f"Doorway {len(opening)} px, box {box['minX']},{box['minY']}-{box['maxX']},{box['maxY']} "
              f"(green), seed {seed[0]},{seed[1]} (yellow), in the {SIDE} px crop of {RECORD['source']['file']}",
              fill=(20, 20, 20))

    # Panel 1: the export with the doorway, the box and the seed.
    left, top = gap, 40
    pixels = source.load()
    for y in range(SIDE):
        for x in range(SIDE):
            r, g, b, a = pixels[x, y]
            color = (228, 234, 220) if a < 128 else (r, g, b)
            if doorway[y][x]:
                color = (214, 40, 40)
            draw.rectangle([left + x * big, top + y * big, left + (x + 1) * big - 1, top + (y + 1) * big - 1], fill=color)
    draw.rectangle([left + box["minX"] * big, top + box["minY"] * big,
                    left + (box["maxX"] + 1) * big - 1, top + (box["maxY"] + 1) * big - 1], outline=(0, 160, 0), width=2)
    draw.rectangle([left + seed[0] * big + 2, top + seed[1] * big + 2,
                    left + (seed[0] + 1) * big - 3, top + (seed[1] + 1) * big - 3], fill=(250, 205, 0))

    # Panels 2 and 3: the renders, doorway beneath the mark.
    for index, (paper, ink) in enumerate(((0x27313F, 0xFFFFFF), (0xF4F0E7, 0x354052))):
        left = gap * (2 + index) + SIDE * big + index * SIDE * small
        draw.rectangle([left, top, left + SIDE * small - 1, top + SIDE * small - 1], fill=hex_rgb(paper))
        for y in range(SIDE):
            for x in range(SIDE):
                color = hex_rgb(ink) if mark[y][x] else hex_rgb(0x1B222C) if doorway[y][x] else None
                if color:
                    draw.rectangle([left + x * small, top + y * small, left + (x + 1) * small - 1,
                                    top + (y + 1) * small - 1], fill=color)
    output.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(output)
    print(json.dumps({"output": str(output), "doorwayPixels": len(opening), "box": box, "seed": seed,
                      "outsideBox": 0, "overlapsMark": 0}))


if __name__ == "__main__":
    main()
