#!/usr/bin/env python3
"""Writes the license texts of the crates in AgentLand's iroh library (third_party/iroh-ffi).

The iPhone and iPad app and the Mac app link IrohLib.xcframework, which scripts/build-iroh-ffi.sh
builds from the pinned iroh-ffi commit and its patches. third_party/iroh-ffi/crates.tsv lists the
crates in the library's normal dependency graph for Apple targets (without proc-macro crates). This
script lists each crate's license expression and copies every LICENSE, COPYING, NOTICE or COPYRIGHT
file each of those crates ships, byte for byte, after iroh-ffi's own texts
(third_party/iroh-ffi/licenses). Files that differ only in whitespace are printed once, naming
every crate that ships them. The crates of the iroh repository that ship no license file in their
package get that repository's LICENSE-APACHE and LICENSE-MIT, which are iroh-ffi's texts byte for
byte.

It writes the same text to both apps' notices:
- third_party/iroh-ffi/crate-licenses.txt, which the Mac bundle carries as
  ThirdPartyNotices/iroh-ffi-crates.txt (macos/BuildPhases/third-party-notices.sh);
- ios/AgentLand/IrohLib-NOTICES.txt, which the iPhone and iPad app carries and shows in
  Settings → About.

Run it after scripts/build-iroh-ffi.sh (it reads the patched checkout the build left in its work
directory and the crates cargo downloaded), and commit both files whenever crates.tsv changes:

    scripts/collect-iroh-ffi-notices.py

It runs `cargo metadata --locked --offline` in the checkout and reads nothing from the network.
`--check` writes nothing and fails when either file differs from what it would write.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
from collections import OrderedDict
from pathlib import Path

LICENSE_FILE = re.compile(r"^(LICEN[CS]E|COPYING|NOTICE|COPYRIGHT|UNLICENSE)([-._].*)?$", re.IGNORECASE)


def find_cargo(rust_version: str) -> str:
    """The cargo of the pinned Rust in $RUSTUP_HOME's toolchains, as scripts/build-iroh-ffi.sh finds it."""
    rustup_home = Path(os.environ.get("RUSTUP_HOME", Path.home() / ".rustup"))
    for toolchain in sorted((rustup_home / "toolchains").glob("*")):
        rustc, cargo = toolchain / "bin/rustc", toolchain / "bin/cargo"
        if rustc.is_file() and cargo.is_file():
            version = subprocess.run([str(rustc), "--version"], capture_output=True, text=True).stdout
            if version.startswith(f"rustc {rust_version} "):
                return str(cargo)
    return "cargo"


def main() -> None:
    root = Path(__file__).resolve().parent.parent
    build_script = (root / "scripts/build-iroh-ffi.sh").read_text()
    rust_version = re.search(r'^rust_version="([^"]+)"', build_script, re.MULTILINE).group(1)
    commit = re.search(r'^upstream_commit="([0-9a-f]+)"', build_script, re.MULTILINE).group(1)
    work = Path(os.environ.get("AGENTLAND_IROH_WORK", Path.home() / "Library/Caches/AgentLand/iroh-ffi"))
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--source", type=Path, default=work / "src", help="the patched iroh-ffi checkout the build left")
    parser.add_argument("--cargo", default=find_cargo(rust_version))
    parser.add_argument("--output", type=Path, action="append",
                        help="write here instead (repeatable); default: both apps' notices files")
    parser.add_argument("--check", action="store_true", help="write nothing; fail when an output differs")
    args = parser.parse_args()
    outputs = args.output or [root / "third_party/iroh-ffi/crate-licenses.txt", root / "ios/AgentLand/IrohLib-NOTICES.txt"]

    listed = []
    for line in (root / "third_party/iroh-ffi/crates.tsv").read_text().splitlines():
        if line and not line.startswith("#"):
            name, version, _ = line.split("\t", 2)
            listed.append((name, version))
    source = args.source.resolve()
    # cargo runs the rustc beside it (the toolchain need not be on PATH).
    environment = dict(os.environ, PATH=f"{Path(args.cargo).parent}:{os.environ.get('PATH', '')}")
    metadata = json.loads(subprocess.run(
        [args.cargo, "metadata", "--locked", "--offline", "--format-version", "1", "--filter-platform", "aarch64-apple-ios"],
        cwd=source, env=environment, capture_output=True, check=True, text=True).stdout)
    packages = {(package["name"], package["version"]): package for package in metadata["packages"]}
    missing = [f"{name} {version}" for name, version in listed if (name, version) not in packages]
    if missing:
        raise SystemExit(f"{source} does not have these crates of crates.tsv (rebuild with scripts/build-iroh-ffi.sh): {missing}")

    texts: OrderedDict[str, tuple[bytes, list[str]]] = OrderedDict()

    def keep(path: Path, owner: str) -> None:
        text = path.read_bytes()
        key = hashlib.sha256(b" ".join(text.split())).hexdigest()
        texts.setdefault(key, (text, []))[1].append(owner)

    ffi_licenses = sorted((root / "third_party/iroh-ffi/licenses").iterdir())
    for path in ffi_licenses:
        keep(path, f"iroh-ffi ({path.name})")
    rows = [f"iroh-ffi {commit[:12]} (AgentLand build, third_party/iroh-ffi): MIT OR Apache-2.0 "
            f"[{', '.join(path.name for path in ffi_licenses)}]"]
    for name, version in sorted(listed):
        package = packages[(name, version)]
        directory = Path(package["manifest_path"]).parent
        expression = package.get("license") or "see its license file"
        files = sorted(path for path in directory.iterdir() if path.is_file() and LICENSE_FILE.match(path.name))
        if directory.is_relative_to(source) and directory != source:
            # Workspace members also carry the repository's license files.
            files += sorted(path for path in source.iterdir() if path.is_file() and LICENSE_FILE.match(path.name))
        if not files and name.startswith("iroh") and "n0-computer/iroh" in (package.get("repository") or ""):
            # The iroh repository's LICENSE-APACHE and LICENSE-MIT are iroh-ffi's texts, byte for byte.
            rows.append(f"{name} {version}: {expression} [the iroh repository's LICENSE-APACHE, LICENSE-MIT]")
            for path in ffi_licenses:
                keep(path, f"{name} {version} (the iroh repository's {path.name})")
            continue
        rows.append(f"{name} {version}: {expression}"
                    + (f" [{', '.join(path.name for path in files)}]" if files else " [no license file in the package]"))
        for path in files:
            keep(path, f"{name} {version} ({path.name})")

    out = [
        "iroh (IrohLib): crates in AgentLand's iroh library and their license texts\n",
        "=" * 78 + "\n\n",
        f"AgentLand links iroh's Swift bindings, built from n0-computer/iroh-ffi {commit}\n"
        "with the patches in third_party/iroh-ffi/patches (see third_party/iroh-ffi/README.md).\n"
        "These are iroh-ffi and the crates third_party/iroh-ffi/crates.tsv lists (the library's\n"
        "normal dependency graph for Apple targets, without proc-macro crates; a superset of what\n"
        "link-time optimization keeps), with each package's license expression and every\n"
        "license, copying or notice file the package ships, byte for byte. Files that differ\n"
        "only in whitespace are printed once, naming every crate that ships them. The uniffi\n"
        "crates (MPL-2.0) are used unmodified; their source is at their upstream. Generated by\n"
        "scripts/collect-iroh-ffi-notices.py.\n\n",
        "Crates\n------\n\n",
        "\n".join(rows) + "\n\n",
    ]
    for number, (text, owners) in enumerate(texts.values(), 1):
        out += ["-" * 78 + "\n", f"Text {number} of {len(texts)}, from: " + "; ".join(owners) + "\n", "-" * 78 + "\n\n",
                text.decode("utf-8", errors="replace").rstrip() + "\n\n"]
    # Bytes, not text: some license files end their lines with CR LF, which reading as text would change.
    data = "".join(out).encode("utf-8")
    stale = []
    for output in outputs:
        if args.check:
            if not output.is_file() or output.read_bytes() != data:
                stale.append(str(output))
        else:
            output.write_bytes(data)
    if stale:
        sys.exit(f"out of date (run scripts/collect-iroh-ffi-notices.py): {', '.join(stale)}")
    print(f"{len(rows)} crates, {len(texts)} texts: {', '.join(str(output) for output in outputs)}")


if __name__ == "__main__":
    main()
