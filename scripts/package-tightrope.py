#!/usr/bin/env python3
"""Package the PixelLab tightrope rig for the circus's tightrope act.

The source is branding/candidates/tightrope-20261003/rig.png (Pro Flash, reduced onto the riders' five day
tones) and its rig.json. The rig is checked before anything is written: binary alpha, the five day tones only,
and a rope row that is opaque between its two ends. It is copied to branding/tightrope/ and packaged as
TightropeRig.png with TightropeRig.json (the rope's row and ends, its free run between the two platforms, and
the poles' bottom row, in rig pixels). The app draws the free run itself so the rope gives under the wheel.
"""

from __future__ import annotations

import json
import shutil
import sys
from pathlib import Path

from PIL import Image

DAY_TONES = ((17, 22, 29), (53, 64, 82), (102, 114, 138), (179, 189, 202), (255, 255, 255))


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    source = root / "branding/candidates/tightrope-20261003"
    image = Image.open(source / "rig.png").convert("RGBA")
    info = json.loads((source / "rig.json").read_text())
    rope, bbox = info["rope"], info["bbox"]
    errors = []
    pixels = image.load()
    for y in range(image.height):
        for x in range(image.width):
            r, g, b, a = pixels[x, y]
            if a not in (0, 255):
                errors.append(f"({x},{y}): alpha {a}")
            elif a == 255 and (r, g, b) not in DAY_TONES:
                errors.append(f"({x},{y}): off-palette {(r, g, b)}")
    gaps = [x for x in range(rope["x0"], rope["x1"] + 1) if pixels[x, rope["row"]][3] != 255]
    if gaps:
        errors.append(f"rope row {rope['row']} has holes at {gaps}")
    # The free run: rope pixels with nothing above or below them, one unbroken stretch between the platforms.
    free = [x for x in range(rope["x0"], rope["x1"] + 1)
            if pixels[x, rope["row"]][3] == 255 and pixels[x, rope["row"] - 1][3] == 0 and pixels[x, rope["row"] + 1][3] == 0]
    if not free or free[-1] - free[0] + 1 != len(free):
        errors.append(f"the rope's free run is not one stretch: {free[:3]}...{free[-3:]}")
    elif len({pixels[x, rope["row"]][:3] for x in free}) != 1:
        errors.append("the rope's free run is not one tone")
    opaque = image.getchannel("A").getbbox()
    if opaque is None or opaque[3] - 1 != bbox[3]:
        errors.append(f"bottom row {None if opaque is None else opaque[3] - 1}, rig.json says {bbox[3]}")
    if errors:
        print("\n".join(errors[:20]), file=sys.stderr)
        return 1
    geometry = {"ropeRow": rope["row"], "ropeStart": rope["x0"], "ropeEnd": rope["x1"],
                "ropeFreeStart": free[0], "ropeFreeEnd": free[-1], "ground": bbox[3]}
    kept = root / "branding/tightrope"
    kept.mkdir(exist_ok=True)
    shutil.copyfile(source / "rig.png", kept / "rig.png")
    (kept / "rig.json").write_text(json.dumps({**info, "packaged": geometry}, indent=2) + "\n")
    resources = root / "shared/AgentLandBranding/Sources/AgentLandBranding/Resources"
    shutil.copyfile(source / "rig.png", resources / "TightropeRig.png")
    (resources / "TightropeRig.json").write_text(json.dumps(geometry, indent=2) + "\n")
    print(f"TightropeRig.png {image.width}x{image.height}, {geometry}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
