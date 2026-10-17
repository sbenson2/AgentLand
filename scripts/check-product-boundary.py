#!/usr/bin/env python3
"""Check that the removed CPTR/Computer reference stays out of AgentLand.

The copied reference tree was deleted from the repository and its history on
2026-09-23. This narrow engineering check confirms none of its paths came back
and searches the product's iOS, desktop-host, macOS, shared-package and
bundle-script inputs for reference identifiers. It does not determine
authorship, licensing, or legal independence.
"""

from __future__ import annotations

import argparse
import json
from datetime import UTC, datetime
from pathlib import Path


FORBIDDEN = ("computer/", "computercore", "cptr", "openwebui", "open-webui", "pocketcpu")
# iroh's upstream organization, named in the linked library's notices (github.com/n0-computer/iroh); it is
# not the removed reference, so its name is taken out before the scan.
UPSTREAM_NAMES = (b"n0-computer/",)
REMOVED_PATHS = (
    "ios/Computer",
    "ios/ComputerTests",
    "ios/Computer.xcodeproj",
    "ios/NativeTerminalChecks",
    "ios/Packages/ComputerCore",
    "ios/project.yml",
    # The reference's root LICENSE was removed with it; the root LICENSE is now AgentLand's own (MIT).
    "docs/CPTR-REFERENCE-GUIDANCE.md",
    "docs/IMPORT-MANIFEST.json",
    "docs/reference-source-inventory.json",
    "docs/native-provenance.json",
    "docs/dependency-inventory.json",
    "scripts/audit-reference-provenance.py",
)


def source_files(root: Path, suffixes: set[str] | None = None) -> list[Path]:
    return sorted(
        path for path in root.rglob("*")
        if path.is_file() and ".build" not in path.parts and (suffixes is None or path.suffix in suffixes)
    )


def scan(scope: str, files: list[Path], repository: Path) -> dict[str, object]:
    matches: list[dict[str, object]] = []
    for path in files:
        relative = path.relative_to(repository).as_posix()
        content = path.read_bytes().lower()
        for name in UPSTREAM_NAMES:
            content = content.replace(name, b"")
        for token in FORBIDDEN:
            offset = content.find(token.encode("utf-8"))
            if offset >= 0:
                matches.append({"file": relative, "token": token, "offset": offset})
    return {"scope": scope, "fileCount": len(files), "forbiddenMatches": matches}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", default=".evidence/product-boundary.json", help="repository-relative JSON report path")
    args = parser.parse_args()
    repository = Path(__file__).resolve().parent.parent
    report_path = (repository / args.report).resolve()
    if repository not in report_path.parents:
        parser.error("--report must remain inside the repository")

    ios = repository / "ios"
    desktop = repository / "desktop"
    macos = repository / "macos"
    shared = repository / "shared"
    returned = [path for path in REMOVED_PATHS if (repository / path).exists()]
    active_scopes = [
        scan("ios-generator-and-generated-project", [ios / "agentland.yml", ios / "AgentLand.xcodeproj/project.pbxproj"], repository),
        # AgentLandCore lives in shared/ and is scanned with the other shared packages.
        scan("ios-agentland-sources-assets-and-tests", source_files(ios / "AgentLand") + source_files(ios / "AgentLandTests") + source_files(ios / "AgentLandUITests"), repository),
        scan("desktop-runtime-and-module", [desktop / "go.mod", desktop / "go.sum"] + [path for path in source_files(desktop, {".go"}) if not path.name.endswith("_test.go")], repository),
        scan("macos-package-sources-and-resources", [macos / "Package.swift"] + source_files(macos / "Sources", {".swift"}) + source_files(macos / "Resources", {".plist", ".svg", ".png"}), repository),
        scan("shared-packages", [path for package in sorted(shared.iterdir()) if (package / "Package.swift").is_file()
                                 for path in source_files(package / "Sources") + [package / "Package.swift"]], repository),
        scan("desktop-app-bundle-script", [repository / "scripts/build-desktop-app.sh"], repository),
    ]
    passed = not returned and all(not scope["forbiddenMatches"] for scope in active_scopes)
    report = {
        "schemaVersion": 2,
        "checkedAt": datetime.now(UTC).isoformat(),
        "purpose": "engineering check that the removed reference stays out of product inputs; not a legal determination",
        "result": "pass" if passed else "fail",
        "removedReferencePathsPresent": returned,
        "activeInputScopes": active_scopes,
    }
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(report_path)
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
