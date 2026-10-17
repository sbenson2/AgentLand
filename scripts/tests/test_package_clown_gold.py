"""Exercise packaging in disposable roots, including all-or-nothing validation."""

import importlib.util
import json
import shutil
import tempfile
import unittest
from pathlib import Path

from PIL import Image


REPO = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("package_clown_gold", REPO / "scripts/package-clown-gold.py")
PACKAGER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PACKAGER)


class GoldPackagingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.template = tempfile.TemporaryDirectory(prefix="gold-input-test-")
        cls.inputs = Path(cls.template.name)
        for design in PACKAGER.DESIGNS:
            source = PACKAGER.candidate(REPO, design)
            destination = PACKAGER.candidate(cls.inputs, design)
            shutil.copytree(source / "animation-research-final", destination / "animation-research-final")
            shutil.copy2(source / "animation-research-final-verification.json", destination)
        balls = Path("branding/candidates/juggling-ball-20261003/frames")
        shutil.copytree(REPO / balls, cls.inputs / balls)

    @classmethod
    def tearDownClass(cls):
        cls.template.cleanup()

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="gold-package-test-")
        self.root = Path(self.temporary.name)
        shutil.copytree(self.inputs, self.root, dirs_exist_ok=True)

    def tearDown(self):
        self.temporary.cleanup()

    def package(self):
        PACKAGER.package(self.root, *PACKAGER.validate(self.root))

    def assert_no_outputs(self):
        for relative in ("branding/clown-ride", "branding/archive", "shared"):
            self.assertFalse((self.root / relative).exists(), relative)

    def test_each_invalid_clown_input_leaves_all_outputs_untouched(self):
        source = PACKAGER.candidate(self.root, "strongman") / "animation-research-final/frame-71.png"
        original = source.read_bytes()
        for violation in ("size", "tone", "alpha"):
            with self.subTest(violation=violation):
                source.write_bytes(original)
                with Image.open(source) as input_image:
                    frame = input_image.convert("RGBA")
                if violation == "size":
                    frame = frame.crop((0, 0, 95, 96))
                else:
                    frame.putpixel((48, 48), (1, 2, 3, 255) if violation == "tone" else (17, 22, 29, 128))
                frame.save(source)
                with self.assertRaisesRegex(ValueError, "refusing to write"):
                    self.package()
                self.assert_no_outputs()

    def test_invalid_palm_lists_leave_all_outputs_untouched(self):
        path = PACKAGER.candidate(self.root, "strongman") / "animation-research-final-verification.json"
        original = json.loads(path.read_text())
        for violation in ("count", "shape", "finite"):
            with self.subTest(violation=violation):
                data = json.loads(json.dumps(original))
                if violation == "count":
                    data["rows"].pop()
                else:
                    data["rows"][-1]["palms"]["near"] = [1] if violation == "shape" else [float("nan"), 30]
                path.write_text(json.dumps(data))
                with self.assertRaisesRegex(ValueError, "refusing to write"):
                    self.package()
                self.assert_no_outputs()

    def test_invalid_ball_frame_leaves_all_outputs_untouched(self):
        source = self.root / "branding/candidates/juggling-ball-20261003/frames/frame-7.png"
        Image.new("RGBA", (15, 16)).save(source)
        with self.assertRaisesRegex(ValueError, "refusing to write"):
            self.package()
        self.assert_no_outputs()

    def test_packaging_preserves_sources_and_archive_across_reruns(self):
        old = self.root / "branding/clown-ride/whiteface/frame-00.png"
        old.parent.mkdir(parents=True)
        old.write_bytes(b"prior source bytes")
        self.package()
        archive = self.root / "branding/archive/2026-10-03-clown-before-gold/whiteface/frame-00.png"
        self.assertEqual(archive.read_bytes(), b"prior source bytes")
        resources = self.root / "shared/AgentLandBranding/Sources/AgentLandBranding/Resources"
        for design in PACKAGER.DESIGNS:
            source = PACKAGER.candidate(self.root, design)
            verification = json.loads((source / "animation-research-final-verification.json").read_text())
            metadata = json.loads((resources / f"ClownRide-{design}.json").read_text())
            self.assertEqual(metadata["frameDuration"], 1 / 60)
            self.assertEqual(metadata["framesPerBeat"], 18)
            self.assertEqual(metadata["ground"], 94)
            self.assertEqual(metadata["rightPalm"], [row["palms"]["near"] for row in verification["rows"]])
            self.assertEqual(metadata["leftPalm"], [row["palms"]["far"] for row in verification["rows"]])
            with Image.open(resources / f"ClownRide-{design}.png") as strip:
                self.assertEqual(strip.size, (72 * 96, 96))
                for index in range(72):
                    name = f"frame-{index:02d}.png"
                    source_frame = source / "animation-research-final" / name
                    copied = self.root / "branding/clown-ride" / design / name
                    self.assertEqual(copied.read_bytes(), source_frame.read_bytes())
                    with Image.open(source_frame) as frame:
                        self.assertEqual(strip.crop((index * 96, 0, (index + 1) * 96, 96)).tobytes(), frame.convert("RGBA").tobytes())
        with Image.open(resources / "JugglingBall.png") as strip:
            self.assertEqual(strip.size, (128, 16))
            for index in range(8):
                with Image.open(self.root / f"branding/candidates/juggling-ball-20261003/frames/frame-{index}.png") as frame:
                    self.assertEqual(strip.crop((index * 16, 0, (index + 1) * 16, 16)).tobytes(), frame.convert("RGBA").tobytes())
        before = {path.name: path.read_bytes() for path in resources.iterdir()}
        self.package()
        self.assertEqual(before, {path.name: path.read_bytes() for path in resources.iterdir()})
        self.assertEqual(archive.read_bytes(), b"prior source bytes")


if __name__ == "__main__":
    unittest.main()
