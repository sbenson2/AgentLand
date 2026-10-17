#!/usr/bin/env python3
"""Package the owner-approved 72-frame clown and juggling-ball artwork.

All candidate inputs are checked before this script creates or replaces an output.
The script only copies pixels; palette conversion and drawing belong to the source
artwork and runtime.
"""

from __future__ import annotations

import argparse
import json
import math
import shutil
import tempfile
from pathlib import Path

from PIL import Image


DESIGNS = ("whiteface", "auguste", "tramp", "harlequin", "ringmaster", "strongman")
DAY_TONES = ((17, 22, 29), (53, 64, 82), (102, 114, 138), (179, 189, 202), (255, 255, 255))
NIGHT_TONES = ((15, 20, 27), (98, 112, 138), (144, 157, 179), (199, 208, 220), (255, 255, 255))


def candidate(root: Path, design: str) -> Path:
    return root / "branding" / ("candidates/clown-one-piece-20261003" if design == "whiteface" else f"candidates/clown-gold-20261003/{design}")


def validate(root: Path) -> tuple[dict[str, list[Image.Image]], dict[str, list[dict[str, list[float]]]], list[Image.Image]]:
    frames: dict[str, list[Image.Image]] = {}
    palms: dict[str, list[dict[str, list[float]]]] = {}
    errors: list[str] = []
    for design in DESIGNS:
        folder = candidate(root, design)
        verification_path = folder / "animation-research-final-verification.json"
        try:
            verification = json.loads(verification_path.read_text())
            rows = verification["rows"]
        except (OSError, ValueError, KeyError) as exc:
            errors.append(f"{design}: invalid verification: {exc}")
            continue
        if len(rows) != 72:
            errors.append(f"{design}: verification has {len(rows)} rows, expected 72")
        design_frames: list[Image.Image] = []
        for index in range(72):
            path = folder / "animation-research-final" / f"frame-{index:02d}.png"
            try:
                image = Image.open(path).convert("RGBA")
            except Exception as exc:  # Pillow reports several input-specific errors.
                errors.append(f"{path}: cannot decode: {exc}")
                continue
            if image.size != (96, 96):
                errors.append(f"{path}: size {image.size}, expected (96, 96)")
            for pixel in image.getdata():
                if pixel[3] not in (0, 255):
                    errors.append(f"{path}: non-binary alpha {pixel[3]}")
                    break
                if pixel[3] == 255 and pixel[:3] not in DAY_TONES:
                    errors.append(f"{path}: off-palette colour {pixel[:3]}")
                    break
            design_frames.append(image)
        frames[design] = design_frames
        try:
            palm_rows = [row["palms"] for row in rows]
            near = [list(map(float, row["near"])) for row in palm_rows]
            far = [list(map(float, row["far"])) for row in palm_rows]
            if len(near) != 72 or len(far) != 72 or any(len(point) != 2 for point in near + far):
                raise ValueError("palm lists must contain 72 two-element points")
            if any(not math.isfinite(value) or not 0 <= value < 96 for point in near + far for value in point):
                raise ValueError("palm coordinates must be finite and inside the frame")
            palms[design] = [{"near": near[i], "far": far[i]} for i in range(72)]
        except (KeyError, TypeError, ValueError) as exc:
            errors.append(f"{design}: invalid palms: {exc}")

    ball_frames: list[Image.Image] = []
    for index in range(8):
        path = root / "branding/candidates/juggling-ball-20261003/frames" / f"frame-{index}.png"
        try:
            image = Image.open(path).convert("RGBA")
        except Exception as exc:
            errors.append(f"{path}: cannot decode: {exc}")
            continue
        if image.size != (16, 16):
            errors.append(f"{path}: size {image.size}, expected (16, 16)")
        if any(pixel[3] not in (0, 255) for pixel in image.getdata()):
            errors.append(f"{path}: non-binary alpha")
        ball_frames.append(image)
    if errors:
        raise ValueError("refusing to write outputs:\n" + "\n".join(errors))
    return frames, palms, ball_frames


def copy_archive(root: Path, archive: Path) -> None:
    if archive.exists():
        return
    archive.mkdir(parents=True)
    rides = root / "branding" / "clown-ride"
    for design in DESIGNS:
        source = rides / design
        if source.exists():
            shutil.copytree(source, archive / design)
    if (rides / "source").exists():
        shutil.copytree(rides / "source", archive / "source")
    manifest = root / "branding/clown-ride.json"
    if manifest.exists():
        shutil.copy2(manifest, archive / manifest.name)
    resource_dir = root / "shared/AgentLandBranding/Sources/AgentLandBranding/Resources"
    destination = archive / "resources"
    destination.mkdir()
    for path in sorted(resource_dir.glob("ClownRide-*.png")):
        shutil.copy2(path, destination / path.name)
    for path in sorted(resource_dir.glob("ClownRide-*.json")):
        shutil.copy2(path, destination / path.name)
    for name in ("ClownUnicycle.png", "JugglingBall.png"):
        path = resource_dir / name
        if path.exists():
            shutil.copy2(path, destination / name)


def package(root: Path, frames: dict[str, list[Image.Image]], palms: dict[str, list[dict[str, list[float]]]], ball_frames: list[Image.Image]) -> None:
    rides = root / "branding" / "clown-ride"
    resources = root / "shared/AgentLandBranding/Sources/AgentLandBranding/Resources"
    archive = root / "branding/archive/2026-10-03-clown-before-gold"
    with tempfile.TemporaryDirectory(prefix="clown-gold-") as temporary:
        stage = Path(temporary)
        staged_rides = stage / "rides"
        staged_resources = stage / "resources"
        staged_resources.mkdir(parents=True)
        for design in DESIGNS:
            out_dir = staged_rides / design
            out_dir.mkdir(parents=True)
            for index in range(len(frames[design])):
                shutil.copy2(candidate(root, design) / "animation-research-final" / f"frame-{index:02d}.png",
                             out_dir / f"frame-{index:02d}.png")
            (out_dir / "provenance.json").write_text(json.dumps({
                "candidateFolder": str(candidate(root, design).relative_to(root)),
                "verification": str((candidate(root, design) / "animation-research-final-verification.json").relative_to(root)),
                "frameCount": 72,
                "frameSize": [96, 96],
            }, indent=2) + "\n")
            strip = Image.new("RGBA", (96 * 72, 96))
            for index, image in enumerate(frames[design]):
                strip.paste(image, (index * 96, 0))
            strip.save(staged_resources / f"ClownRide-{design}.png", format="PNG", optimize=False)
            metadata = {
                "frameDuration": 1 / 60,
                "framesPerBeat": 18,
                "ground": 94,
                "rightPalm": [p["near"] for p in palms[design]],
                "leftPalm": [p["far"] for p in palms[design]],
                "tones": {"day": [f"#{r:02X}{g:02X}{b:02X}" for r, g, b in DAY_TONES],
                          "night": [f"#{r:02X}{g:02X}{b:02X}" for r, g, b in NIGHT_TONES]},
            }
            (staged_resources / f"ClownRide-{design}.json").write_text(json.dumps(metadata, indent=2) + "\n")
        ball_strip = Image.new("RGBA", (16 * 8, 16))
        for index, image in enumerate(ball_frames):
            ball_strip.paste(image, (index * 16, 0))
        ball_strip.save(staged_resources / "JugglingBall.png", format="PNG", optimize=False)

        copy_archive(root, archive)
        for design in DESIGNS:
            destination = rides / design
            destination.mkdir(parents=True, exist_ok=True)
            for path in (staged_rides / design).iterdir():
                shutil.copy2(path, destination / path.name)
        resources.mkdir(parents=True, exist_ok=True)
        for path in staged_resources.iterdir():
            shutil.copy2(path, resources / path.name)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    frames, palms, ball_frames = validate(args.root)
    package(args.root, frames, palms, ball_frames)
    print("packaged six 72-frame clown rides and JugglingBall.png")


if __name__ == "__main__":
    main()
