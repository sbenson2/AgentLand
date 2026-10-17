#!/usr/bin/env python3
"""Fetch and safely unpack the pinned OpenCode executable into .build/opencode, for tests.

The Mac app bundles no OpenCode (its host installs and updates OpenCode), and
its build no longer runs this. The UI test harness (integration/check-ios-product.py)
and the opt-in OpenCode checks use the executable it prints.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import stat
import subprocess
import sys
import tempfile
import urllib.request
import zipfile

DOWNLOAD_TIMEOUT_SECONDS = 30
MAX_BINARY_BYTES = 200 * 1024 * 1024


def progress(message: str) -> None:
    print(message, file=sys.stderr)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def architecture(value: str | None) -> str:
    raw = value or platform.machine().lower()
    aliases = {"arm64": "arm64", "aarch64": "arm64", "x86_64": "x86_64", "amd64": "x86_64"}
    try:
        return aliases[raw]
    except KeyError as error:
        raise SystemExit(f"Unsupported macOS architecture: {raw}") from error


def download(url: str, target: Path, expected_size: int, expected_hash: str) -> None:
    request = urllib.request.Request(url, headers={"User-Agent": "AgentLand-runtime-packager/1"})
    progress(f"Downloading pinned OpenCode runtime ({expected_size} bytes)…")
    with urllib.request.urlopen(request, timeout=DOWNLOAD_TIMEOUT_SECONDS) as response:
        content_length = response.headers.get("Content-Length")
        if content_length is not None and int(content_length) != expected_size:
            raise RuntimeError("OpenCode archive size did not match the pinned release metadata.")
        digest = hashlib.sha256()
        total = 0
        with target.open("wb") as destination:
            while True:
                chunk = response.read(1024 * 1024)
                if not chunk:
                    break
                total += len(chunk)
                if total > expected_size:
                    raise RuntimeError("OpenCode archive exceeded its pinned size.")
                digest.update(chunk)
                destination.write(chunk)
    if total != expected_size or digest.hexdigest() != expected_hash:
        raise RuntimeError("OpenCode archive checksum did not match the pinned release metadata.")


def verified_archive(cache: Path, metadata: dict[str, object]) -> Path:
    archive = cache / "opencode.zip"
    expected_size = metadata["size"]
    expected_hash = metadata["sha256"]
    if not isinstance(expected_size, int) or not isinstance(expected_hash, str):
        raise RuntimeError("Invalid pinned OpenCode metadata.")
    if archive.is_file() and archive.stat().st_size == expected_size and sha256(archive) == expected_hash:
        progress("Using checksum-verified cached OpenCode archive.")
        return archive
    archive.unlink(missing_ok=True)
    temporary = cache / "opencode.zip.partial"
    temporary.unlink(missing_ok=True)
    try:
        download(str(metadata["url"]), temporary, expected_size, expected_hash)
        os.replace(temporary, archive)
    finally:
        temporary.unlink(missing_ok=True)
    return archive


def extract_executable(archive: Path, destination: Path) -> None:
    with zipfile.ZipFile(archive) as bundle:
        entries = bundle.infolist()
        if len(entries) != 1:
            raise RuntimeError("Pinned OpenCode archive has unexpected entries.")
        entry = entries[0]
        mode = entry.external_attr >> 16
        if entry.filename != "opencode" or stat.S_ISLNK(mode) or not stat.S_ISREG(mode):
            raise RuntimeError("Pinned OpenCode archive has an unexpected executable entry.")
        if entry.file_size <= 0 or entry.file_size > MAX_BINARY_BYTES:
            raise RuntimeError("Pinned OpenCode executable has an unsafe size.")
        with bundle.open(entry) as source, destination.open("wb") as output:
            copied = shutil.copyfileobj(source, output, length=1024 * 1024)
    if destination.stat().st_size != entry.file_size:
        raise RuntimeError("OpenCode executable extraction was incomplete.")
    destination.chmod(0o755)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--architecture", help="arm64 or x86_64; defaults to this Mac")
    parser.add_argument("--verify-version", action="store_true", help="confirm the extracted executable reports the pinned version")
    args = parser.parse_args()

    root = Path(__file__).resolve().parent.parent
    manifest_path = root / "macos" / "Resources" / "OpenCodeRuntime.json"
    manifest = json.loads(manifest_path.read_text())
    version = manifest["version"]
    arch = architecture(args.architecture)
    metadata = manifest["architectures"][arch]
    if not isinstance(version, str) or not isinstance(metadata, dict):
        raise RuntimeError("Invalid pinned OpenCode manifest.")
    cache = root / ".build" / "opencode" / version / arch
    cache.mkdir(parents=True, exist_ok=True)
    archive = verified_archive(cache, metadata)
    executable = cache / "opencode"
    if not executable.is_file() or executable.stat().st_size > MAX_BINARY_BYTES:
        temporary = cache / "opencode.partial"
        temporary.unlink(missing_ok=True)
        try:
            extract_executable(archive, temporary)
            os.replace(temporary, executable)
        finally:
            temporary.unlink(missing_ok=True)
    if args.verify_version:
        result = subprocess.run([str(executable), "--version"], text=True, capture_output=True, timeout=15, check=True)
        if version not in result.stdout:
            raise RuntimeError("Extracted OpenCode executable did not report the pinned version.")
        progress(f"Verified OpenCode {version}.")
    print(executable)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"OpenCode runtime preparation failed: {error}", file=sys.stderr)
        raise SystemExit(1)
