import os
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]

class GoToolchainTests(unittest.TestCase):
    def source_phase(self, version):
        with tempfile.TemporaryDirectory() as directory:
            go = pathlib.Path(directory) / 'go'
            go.write_text('#!/bin/sh\nprintf "%s\\n" "'+version+'"\n')
            go.chmod(0o700)
            result = subprocess.run(['zsh', '-c', 'source "$1"', 'zsh', str(ROOT / 'macos/BuildPhases/go-tool.sh')],
                                    env={**os.environ, 'PATH':directory+':'+os.environ['PATH']}, capture_output=True, text=True)
            return result

    def test_build_phase_rejects_unpatched_toolchain(self):
        result = self.source_phase('go1.26.2')
        self.assertNotEqual(result.returncode, 0, 'host build accepted vulnerable Go 1.26.2')

    def test_build_phase_accepts_patched_toolchain(self):
        self.assertEqual(self.source_phase('go1.26.8').returncode, 0)

if __name__ == '__main__':
    unittest.main()
