#!/usr/bin/env python3
"""Check automatic LAContext unlock on a disposable iPhone simulator.

Pass the booted simulator's UDID; the paired parity simulator is refused. No
host fixture, credential or real Face ID enrollment is used. NSArgumentDomain
forces app lock and Light appearance for this launch without saving either.
"""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import time
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import simulator_guard  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
# The paired "AgentLand Parity iPhone" keeps the owner's pairing; checks never run on it.
EVIDENCE = ROOT / ".evidence/automatic-unlock-20260922"
# Worktrees that run this check at the same time pass their own build folder.
DERIVED = os.environ.get("AGENTLAND_DERIVED_DATA", "/private/tmp/agentland-product-derived")


def run(*args, timeout=30, check=True):
    return subprocess.run(args, check=check, capture_output=True, text=True, timeout=timeout)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("simulator", help="Already booted disposable iPhone simulator UDID (never the paired parity simulator)")
    DEVICE = parser.parse_args().simulator
    try:
        simulator_guard.refuse_protected(DEVICE)
    except simulator_guard.ProtectedSimulator as refusal:
        raise SystemExit(str(refusal))
    EVIDENCE.mkdir(parents=True, exist_ok=True)
    devices = json.loads(run("xcrun", "simctl", "list", "devices", "--json").stdout)
    device = next((d for group in devices["devices"].values() for d in group if d["udid"] == DEVICE), None)
    if device is None or device["state"] != "Booted" or "iPhone" not in device.get("deviceTypeIdentifier", device["name"]):
        raise SystemExit(f"Disposable iPhone simulator {DEVICE} must already be Booted")
    run("xcrun", "simctl", "spawn", DEVICE, "notifyutil", "-s",
        "com.apple.BiometricKit.enrollmentChanged", "1", "-p", "com.apple.BiometricKit.enrollmentChanged")
    fixture = ROOT / "ios/AgentLandUITests/Fixture.json"
    previous = fixture.read_bytes()
    assert not json.loads(previous)["enabled"], "Do not interrupt another active fixture workflow"
    stamp = str(int(time.time()))
    log_path = EVIDENCE / f"ui-{stamp}.log"
    result_path = EVIDENCE / f"ui-{stamp}.xcresult"
    command = ["xcodebuild", "-project", str(ROOT / "ios/AgentLand.xcodeproj"),
               "-scheme", "AgentLand", "-configuration", "Debug", "-destination",
               f"platform=iOS Simulator,id={DEVICE}", "-derivedDataPath", DERIVED,
               "-resultBundlePath", str(result_path), "-parallel-testing-enabled", "NO",
               "CODE_SIGN_IDENTITY=-", "-only-testing:AgentLandUITests/FullWorkspaceUITests/testAutomaticUnlock", "test"]
    try:
        fixture.write_text(json.dumps({"enabled": True, "phase": "unlock"}) + "\n")
        with log_path.open("w") as log:
            process = subprocess.Popen(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            try:
                code = process.wait(timeout=300)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=10)
                raise
        assert code == 0, f"Automatic-unlock UI test failed: {log_path}"
        result = {"simulator": DEVICE, "testPassed": True, "realLAContext": True,
                  "log": log_path.name, "resultBundle": result_path.name, "command": command}
        (EVIDENCE / "ui-verification.json").write_text(json.dumps(result, indent=2) + "\n")
        print(json.dumps(result))
    finally:
        fixture.write_bytes(previous)


if __name__ == "__main__":
    main()
