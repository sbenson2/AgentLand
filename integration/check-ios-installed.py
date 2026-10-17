#!/usr/bin/env python3
"""Pair the iPhone simulator to an already healthy installed Mac companion.

The JSON fixture is a private 0600 file under /private/tmp containing address,
fingerprint, and one-time code. This runner never starts or stops the Mac host.
"""

import argparse
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import signal
import stat
import subprocess
import tempfile
import time
from urllib.parse import urlparse
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import simulator_guard  # noqa: E402


ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / "ios/AgentLandUITests/Fixture.json"
EVIDENCE = ROOT / ".evidence/ios-installed"


def command(args, *, timeout=30):
    result = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError(f"{args[0]} failed: {(result.stderr or result.stdout)[-500:]}")
    return result.stdout


def private_fixture(path):
    if path.is_symlink() or not path.resolve().is_relative_to(Path("/private/tmp")):
        raise RuntimeError("The installed-host fixture must be a regular private file under /private/tmp")
    info = path.stat()
    if not stat.S_ISREG(info.st_mode) or info.st_mode & 0o077:
        raise RuntimeError("The installed-host fixture must be a regular file with mode 0600")
    value = json.loads(path.read_text())
    address = value.get("address")
    code = value.get("code")
    fingerprint = value.get("fingerprint")
    parsed = urlparse(address) if isinstance(address, str) else None
    if not parsed or parsed.scheme != "https" or not parsed.hostname or not parsed.port or parsed.username or parsed.password or parsed.path not in ("", "/") or parsed.query or parsed.fragment:
        raise RuntimeError("Fixture address must be an HTTPS host URL with a port and no credentials or path")
    if not isinstance(code, str) or not re.fullmatch(r"[0-9]{10}", code):
        raise RuntimeError("Fixture code must be a ten-digit one-time PIN")
    if not isinstance(fingerprint, str) or not re.fullmatch(r"[0-9a-fA-F]{64}", fingerprint):
        raise RuntimeError("Fixture fingerprint must be the 64-character SHA-256 hex value")
    return {"enabled": True, "phase": "installed", "freshHost": True,
            "address": address, "code": code, "fingerprint": fingerprint}


def stop_test(process):
    if process.poll() is not None:
        return
    os.killpg(process.pid, signal.SIGTERM)
    try:
        process.wait(timeout=8)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=5)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("simulator", help="Already booted iPhone simulator UDID")
    parser.add_argument("fixture", type=Path, help="Private 0600 /private/tmp JSON from the installed Mac companion")
    options = parser.parse_args()
    simulator_guard.refuse_protected(options.simulator)
    value = private_fixture(options.fixture)
    booted = json.loads(command(["xcrun", "simctl", "list", "devices", "booted", "--json"]))
    devices = [device for group in booted["devices"].values() for device in group]
    if not any(device["udid"] == options.simulator and "iPhone" in device["name"] for device in devices):
        raise RuntimeError("Pass one already booted iPhone simulator; no physical device is changed")
    original = FIXTURE.read_bytes()
    if json.loads(original).get("enabled") is not False:
        raise RuntimeError("Fixture.json must begin disabled; another integration run may own it")

    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()) + "-" + secrets.token_hex(2)
    output = EVIDENCE / stamp
    output.mkdir(parents=True)
    with tempfile.TemporaryDirectory(prefix="agentland-installed-ui-") as location:
        temporary = Path(location)
        raw_log = temporary / "xcodebuild.log"
        result = temporary / "InstalledHost.xcresult"
        try:
            FIXTURE.write_text(json.dumps(value) + "\n")
            invocation = ["xcodebuild", "-project", str(ROOT / "ios/AgentLand.xcodeproj"),
                          "-scheme", "AgentLand", "-destination", f"platform=iOS Simulator,id={options.simulator}",
                          "-derivedDataPath", str(temporary / "DerivedData"), "-resultBundlePath", str(result),
                          "-parallel-testing-enabled", "NO", "CODE_SIGNING_ALLOWED=YES", "CODE_SIGN_IDENTITY=-",
                          "-only-testing:AgentLandUITests/FullWorkspaceUITests/testInstalledHostSmoke", "test"]
            with raw_log.open("w") as stream:
                process = subprocess.Popen(invocation, stdout=stream, stderr=stream, start_new_session=True)
                try:
                    exit_code = process.wait(timeout=450)
                except subprocess.TimeoutExpired as error:
                    stop_test(process)
                    raise RuntimeError("Installed-host UI smoke timed out after 450 seconds") from error
                finally:
                    stop_test(process)
            if exit_code or "Executed 0 tests" in raw_log.read_text(errors="replace"):
                raise RuntimeError("Installed-host UI smoke failed; inspect the redacted evidence log")
            attachments = temporary / "attachments"
            command(["xcrun", "xcresulttool", "export", "attachments", "--path", str(result),
                     "--output-path", str(attachments)], timeout=40)
            manifest = json.loads((attachments / "manifest.json").read_text())
            saved = set()
            for group in manifest:
                for item in group["attachments"]:
                    match = re.match(r"(installed-(?:workspace|files|terminal))_0_", item["suggestedHumanReadableName"])
                    if match and item["exportedFileName"].endswith(".png"):
                        shutil.copy2(attachments / item["exportedFileName"], output / (match.group(1) + ".png"))
                        saved.add(match.group(1))
            if saved != {"installed-workspace", "installed-files", "installed-terminal"}:
                raise RuntimeError("Installed-host smoke did not retain all three post-pair screenshots")
        finally:
            FIXTURE.write_bytes(original)
            if raw_log.exists():
                redacted = raw_log.read_text(errors="replace").replace(value["code"], "<redacted PIN>")
                if value["code"] in redacted:
                    raise RuntimeError("One-time PIN remained in the saved test log")
                (output / "xcodebuild.log").write_text(redacted)
    print(f"PASS: installed-host iPhone smoke; redacted log and post-pair screenshots: {output}")


if __name__ == "__main__":
    main()
