#!/usr/bin/env python3
"""Replace the installed AgentLand Mac bundle in place after a graceful quit.

The staged bundle must carry the same bundle identifier and designated
requirement as the installed one, so Keychain items and saved settings keep
working. The installed bundle is moved to a backup first and restored if the
copy, signature check, launch or settings comparison fails.

    scripts/install-mac-app.py --staged .build/AgentLand-<pass>-signed.app --pass <pass>
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import plistlib
import subprocess
import time

ROOT = Path(__file__).resolve().parent.parent
INSTALLED = Path.home() / "Applications/AgentLand.app"
BUNDLE = "dev.agentland.desktop"


def run(*args, timeout=30):
    return subprocess.run(args, check=True, capture_output=True, text=True, timeout=timeout)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def settings_digest():
    exported = subprocess.run(["defaults", "export", BUNDLE, "-"], capture_output=True, check=True)
    settings = plistlib.loads(exported.stdout).get("dev.agentland.desktop.preferences.v1")
    assert settings, "Installed AgentLand settings are missing"
    return hashlib.sha256(settings).hexdigest()


def running_app():
    result = subprocess.run(["pgrep", "-x", "AgentLandDesktop"], capture_output=True, text=True)
    return [int(pid) for pid in result.stdout.split()]


def wait_for(predicate, seconds):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.2)
    return predicate()


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--staged", required=True, help="signed AgentLand.app to install")
    parser.add_argument("--pass", dest="pass_name", required=True, help="short name used for the backup and evidence folder")
    args = parser.parse_args()
    staged = Path(args.staged).resolve()
    backup = ROOT / f".build/AgentLand-installed-before-{args.pass_name}.bundle-backup"
    evidence = ROOT / f".evidence/{args.pass_name}"
    evidence.mkdir(parents=True, exist_ok=True)

    assert staged.is_dir() and INSTALLED.is_dir() and not backup.exists(), "staged/installed bundle missing or backup already exists"
    assert plistlib.loads((staged / "Contents/Info.plist").read_bytes())["CFBundleIdentifier"] == BUNDLE
    assert plistlib.loads((INSTALLED / "Contents/Info.plist").read_bytes())["CFBundleIdentifier"] == BUNDLE
    run("codesign", "--verify", "--deep", "--strict", str(staged))
    original_designation = run("codesign", "-dr", "-", str(INSTALLED)).stdout.split("designated =>", 1)[1]
    updated_designation = run("codesign", "-dr", "-", str(staged)).stdout.split("designated =>", 1)[1]
    assert original_designation == updated_designation, "Signing identity changed"
    before_settings = settings_digest()
    if running_app():
        run("osascript", "-e", f'tell application id "{BUNDLE}" to quit')
        assert wait_for(lambda: not running_app(), 20), "AgentLand did not quit gracefully"
    os.rename(INSTALLED, backup)
    executable = "Contents/MacOS/AgentLandDesktop"
    host = "Contents/MacOS/agentland-host"
    try:
        run("ditto", str(staged), str(INSTALLED), timeout=90)
        run("codesign", "--verify", "--deep", "--strict", str(INSTALLED))
        assert digest(staged / executable) == digest(INSTALLED / executable)
        assert digest(staged / host) == digest(INSTALLED / host)
        run("open", "-a", str(INSTALLED))
        assert wait_for(lambda: bool(running_app()), 15), "Updated AgentLand did not launch"
        assert before_settings == settings_digest(), "Saved Mac settings changed"
    except Exception:
        if INSTALLED.exists():
            os.rename(INSTALLED, staged.with_name(f"AgentLand-{args.pass_name}-install-failed.app"))
        os.rename(backup, INSTALLED)
        subprocess.run(["open", "-a", str(INSTALLED)], capture_output=True)
        raise
    result = {
        "installed": True,
        "launched": True,
        "savedSettingsPreserved": True,
        "designatedRequirementPreserved": True,
        "signatureVerified": True,
        "backup": str(backup),
        "executableSHA256": digest(INSTALLED / executable),
        "hostSHA256": digest(INSTALLED / host),
    }
    (evidence / "mac-install-verification.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result))


if __name__ == "__main__":
    main()
