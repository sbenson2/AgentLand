#!/usr/bin/env python3
"""Check build or embedded Go metadata against the shared go.mod minimum."""

import argparse
from pathlib import Path
import re
import shutil
import subprocess
import sys


def release(value: str) -> tuple[int, int, int]:
    match = re.fullmatch(r"(?:go)?(\d+)\.(\d+)\.(\d+)", value)
    if not match:
        raise ValueError(f"expected a stable Go patch release, got {value!r}")
    return tuple(int(part) for part in match.groups())


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--version", help="GOVERSION reported by the build tool")
    source.add_argument("--binary", type=Path, help="inspect the embedded helper independently")
    parser.add_argument("--go", help="Go metadata reader (defaults to PATH or standard install paths)")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    match = re.search(r"^go (\S+)$", (root / "desktop/go.mod").read_text(), re.MULTILINE)
    if match is None:
        raise ValueError("desktop/go.mod has no Go requirement")
    minimum = release(match[1])
    version = args.version
    if args.binary is not None:
        go = args.go or shutil.which("go")
        if go is None:
            go = next((str(path) for path in (
                Path("/opt/homebrew/bin/go"), Path("/usr/local/go/bin/go"), Path("/usr/local/bin/go")
            ) if path.is_file()), None)
        if go is None:
            raise ValueError("Go is required to inspect the helper build metadata")
        metadata = subprocess.run(
            [go, "version", "-m", str(args.binary)], check=True, capture_output=True,
            text=True, timeout=15,
        ).stdout
        # Read the compiler version, independently of the tool inspecting it.
        header = metadata.splitlines()[0] if metadata else ""
        binary_match = re.search(r":\s+(go\S+)\s*$", header)
        if binary_match is None:
            raise ValueError("helper has no recognizable Go build metadata")
        version = binary_match[1]
    if release(version) < minimum:
        raise ValueError(f"Go {match[1]} or later is required; found {version}")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        sys.exit(f"error: AgentLand Go toolchain check: {error}")
