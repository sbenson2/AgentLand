#!/usr/bin/env python3
"""Package AgentLand's logo, the tent (branding/tent-logo.json), from its PixelLab source.

Maps the sprite onto the riders' five tones and writes every place the logo appears: the app
icon of iPhone, iPad and the Mac (ios/AgentLand/AppIcon.icon, one layered Icon Composer icon with
iOS 27 glass: the tent in night tones over a slate gradient, a grey tent for Clear and Tinted), the
in-app mark (day tones; the app recolours it to night on slate) and the branding previews. Scaling
is by whole numbers with nearest-neighbour. The Mac menu-bar template is not the sprite: it is the
glyph drawn by hand for the bar's 1x grid (branding/tent-menubar.txt), written at 1x and doubled
pixel for pixel at 2x.
Run from the repository root.
"""
import json
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
BRANDING = ROOT / "branding"
# One icon for iPhone, iPad and the Mac: the Mac target references this same folder.
APP_ICON = ROOT / "ios/AgentLand/AppIcon.icon"
RESOURCES = ROOT / "shared/AgentLandBranding/Sources/AgentLandBranding/Resources"
SLATE = (0x27, 0x31, 0x3F)
SIDE = 1024
# The app icon (owner, 2026-10-17, design "B: tent 7x"): the tent at x7, 8 px below centre for more
# room than the flat icon's x8, on a vertical slate gradient from TOP to BOTTOM.
ICON_SCALE, ICON_DROP = 7, 8
ICON_TOP, ICON_BOTTOM = (0x3D, 0x4A, 0x5C), (0x22, 0x2B, 0x37)
# The menu-bar canvas in points (and pixels at 1x) and where the hand-drawn glyph sits in it.
MENU_BAR_SIDE, MENU_BAR_ORIGIN = 22, (0, 2)
MENU_BAR_ALPHA = {"#": 255, "+": 120, ".": 0}

def rgb(hex_colour):
    return tuple(int(hex_colour[i:i + 2], 16) for i in (1, 3, 5))

palette = json.loads((BRANDING / "clown-ride.json").read_text())["palette"]
day = [rgb(c) for c in palette["day"]["tones"]]
night = [rgb(c) for c in palette["night"]["tones"]]

def nearest(p):
    return min(range(5), key=lambda i: 0.3 * (p[0] - day[i][0]) ** 2 + 0.59 * (p[1] - day[i][1]) ** 2 + 0.11 * (p[2] - day[i][2]) ** 2)

source = Image.open(BRANDING / "tent-logo-pixellab-source.png").convert("RGBA")
tones = {}
for y in range(source.height):
    for x in range(source.width):
        p = source.getpixel((x, y))
        if p[3] >= 128:
            tones[x, y] = nearest(p)

def sprite(ramp):
    image = Image.new("RGBA", source.size, (0, 0, 0, 0))
    for point, tone in tones.items():
        image.putpixel(point, ramp[tone] + (255,))
    return image

def centred(mark, side, limit, backdrop):
    """The mark cropped to its pixels, scaled by the largest whole number within limit, centred on backdrop."""
    mark = mark.crop(mark.getbbox())
    scale = limit // max(mark.size)
    mark = mark.resize((mark.width * scale, mark.height * scale), Image.NEAREST)
    backdrop.alpha_composite(mark, ((side - mark.width) // 2, (side - mark.height) // 2))
    return backdrop, scale

def grey(colour):
    """The Clear and Tinted grey of a tone, from its luminance."""
    level = (colour[0] * 299 + colour[1] * 587 + colour[2] * 114) / 1000
    return 255 if level > 230 else 205 if level > 140 else 140 if level > 90 else 80 if level > 40 else 28

def icon_layer(ramp):
    """The tent cropped to its pixels, scaled by ICON_SCALE, centred on a clear canvas and moved down ICON_DROP."""
    tent = sprite(ramp)
    tent = tent.crop(tent.getbbox())
    tent = tent.resize((tent.width * ICON_SCALE, tent.height * ICON_SCALE), Image.NEAREST)
    layer = Image.new("RGBA", (SIDE, SIDE), (0, 0, 0, 0))
    layer.alpha_composite(tent, ((SIDE - tent.width) // 2, (SIDE - tent.height) // 2 + ICON_DROP))
    return layer

# App icon (iPhone, iPad and Mac): Icon Composer's folder, two groups. The tent group is glass with the
# system's specular highlight and a neutral shadow, in the day tones: the prototype the owner chose showed
# the source's own colours, and the night tones were lighter and softened the outline. Its tinted image
# (which drives Clear and Tinted) is the same tent in greys, one per day tone, so the five tones stay five
# greys. The background is an opaque image, not a fill: ictool 27 ignores a fill's dark specialization
# and renders System Dark instead, so only an image keeps the slate in Dark.
assets = APP_ICON / "Assets"
assets.mkdir(parents=True, exist_ok=True)
icon_layer(day).save(assets / "tent.png", optimize=True)
icon_layer([(g, g, g) for g in map(grey, day)]).save(assets / "tent-mono.png", optimize=True)
gradient = Image.new("RGB", (SIDE, SIDE))
for y in range(SIDE):
    row = tuple(round(top + (bottom - top) * y / (SIDE - 1)) for top, bottom in zip(ICON_TOP, ICON_BOTTOM))
    gradient.paste(row, (0, y, SIDE, y + 1))
gradient.save(assets / "bg.png", optimize=True)

def srgb(colour):
    return "srgb:" + ",".join(f"{c / 255:.5f}" for c in colour) + ",1.00000"

icon_json = {
    "fill": {"linear-gradient": [srgb(ICON_TOP), srgb(ICON_BOTTOM)],
             "orientation": {"start": {"x": 0.5, "y": 0}, "stop": {"x": 0.5, "y": 1}}},
    "groups": [
        {"name": "Tent",
         "layers": [{"name": "tent", "image-name": "tent.png", "glass": True,
                     "image-name-specializations": [{"appearance": "tinted", "value": "tent-mono.png"}]}],
         "shadow": {"kind": "neutral", "opacity": 0.5},
         "specular": True,
         "translucency": {"enabled": False, "value": 0.0}},
        {"name": "Background",
         "layers": [{"name": "bg", "image-name": "bg.png", "glass": False}]},
    ],
    "supported-platforms": {"squares": "shared"},
}
(APP_ICON / "icon.json").write_text(json.dumps(icon_json, indent=1) + "\n")

# In-app mark: day tones (AgentLandMark recolours them to night), cropped to the sprite's pixels and
# padded with clear pixels to a centred square, so the mark's frame is the tent and nothing else.
cropped = sprite(day).crop(sprite(day).getbbox())
mark_side = max(cropped.size)
mark = Image.new("RGBA", (mark_side, mark_side), (0, 0, 0, 0))
mark.paste(cropped, ((mark_side - cropped.width) // 2, (mark_side - cropped.height) // 2))
mark.save(RESOURCES / "LogoMark.png", optimize=True)

# Menu-bar template: the hand-drawn 1x glyph, black with its alpha levels, in a clear 22x22 canvas;
# the 2x file is exactly that image doubled with nearest-neighbour. Never resampled from the sprite:
# at the bar's size a scaled painting blurs to grey (.evidence/icon-redesign-20261012/menubar-study).
rows = (BRANDING / "tent-menubar.txt").read_text().split()
assert len({len(row) for row in rows}) == 1 and set("".join(rows)) <= set(MENU_BAR_ALPHA), "tent-menubar.txt is a grid of # + ."
assert MENU_BAR_ORIGIN[0] + len(rows[0]) <= MENU_BAR_SIDE and MENU_BAR_ORIGIN[1] + len(rows) <= MENU_BAR_SIDE
menu_bar = Image.new("RGBA", (MENU_BAR_SIDE, MENU_BAR_SIDE), (0, 0, 0, 0))
for y, row in enumerate(rows):
    for x, cell in enumerate(row):
        if MENU_BAR_ALPHA[cell]:
            menu_bar.putpixel((MENU_BAR_ORIGIN[0] + x, MENU_BAR_ORIGIN[1] + y), (0, 0, 0, MENU_BAR_ALPHA[cell]))
menu_bar.save(RESOURCES / "LogoMenuBar.png", optimize=True)
menu_bar.resize((MENU_BAR_SIDE * 2, MENU_BAR_SIDE * 2), Image.NEAREST).save(RESOURCES / "LogoMenuBar-2x.png", optimize=True)

# Previews: day tones on white and night tones on slate, at the tent previews' 76% of 512.
for name, ramp, colour in (("logo-light.png", day, (255, 255, 255)), ("logo-dark.png", night, SLATE)):
    preview, _ = centred(sprite(ramp), 512, 512 * 76 // 100, Image.new("RGBA", (512, 512), colour + (255,)))
    preview.convert("RGB").save(BRANDING / name, optimize=True)

print(f"tent logo: {source.width}x{source.height} sprite, {cropped.width}x{cropped.height} tent; app icon x{ICON_SCALE} "
      f"({APP_ICON.relative_to(ROOT)}), in-app mark {mark_side}x{mark_side}, menu-bar template {len(rows[0])}x{len(rows)} glyph "
      f"in {MENU_BAR_SIDE}x{MENU_BAR_SIDE} (1x) and {MENU_BAR_SIDE * 2}x{MENU_BAR_SIDE * 2} (2x), previews written")
