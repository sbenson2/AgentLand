"""Which simulators the iOS integration checks may touch.

Every `integration/check-ios-*.py` calls `refuse_protected` before it builds, installs,
uninstalls or tests anything: the protected simulators hold the owner's own pairing and
app data. `erase_disposable` gives a truly fresh first run (Keychain, privacy grants and
app data wiped), and only on a simulator kept for disposable test runs.
"""

import json
import os
import subprocess

# Simulators that hold your own pairing and app data (none by default).
# No check may boot, install on, uninstall from, erase or test a simulator listed here.
PROTECTED = {}

# Simulators kept for disposable test runs: the only ones `--erase` may reset. List their UDIDs,
# comma-separated, in AGENTLAND_DISPOSABLE_SIMULATORS.
DISPOSABLE = {
    udid.strip().upper(): "disposable test simulator"
    for udid in os.environ.get("AGENTLAND_DISPOSABLE_SIMULATORS", "").split(",")
    if udid.strip()
}


class ProtectedSimulator(RuntimeError):
    pass


def refuse_protected(*udids):
    """Raises before anything touches a protected simulator; returns the UDIDs upper-cased."""
    checked = []
    for udid in udids:
        normalized = (udid or "").strip().upper()
        if normalized in PROTECTED:
            raise ProtectedSimulator(f"Refusing {normalized}: {PROTECTED[normalized]}. "
                                     "Pass a disposable simulator UDID.")
        checked.append(normalized)
    return checked


def _simctl(*args, timeout=180):
    result = subprocess.run(["xcrun", "simctl", *args], capture_output=True, text=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError(f"simctl {' '.join(args[:2])} failed: {(result.stderr or result.stdout)[-1500:]}")
    return result.stdout


def state(udid):
    devices = json.loads(_simctl("list", "devices", "--json"))
    for group in devices["devices"].values():
        for device in group:
            if device["udid"].upper() == udid.upper():
                return device["state"]
    raise RuntimeError(f"No simulator {udid}")


def erase_disposable(udid):
    """Shuts down, erases and boots one allow-listed disposable simulator, then waits until it has
    finished booting. Everything on it goes: the app, its Keychain items and privacy grants."""
    (udid,) = refuse_protected(udid)
    if udid not in DISPOSABLE:
        raise ProtectedSimulator(f"--erase works only on a disposable simulator: {', '.join(DISPOSABLE)}")
    if state(udid) != "Shutdown":
        _simctl("shutdown", udid, timeout=120)
    _simctl("erase", udid, timeout=300)
    _simctl("boot", udid, timeout=300)
    _simctl("bootstatus", udid, "-b", timeout=600)
