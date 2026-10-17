#!/usr/bin/env python3
"""Visit every terminal program on a booted simulator and keep screenshots.

The disposable host serves one folder (default: this repository) so Claude Code
and Codex open where they are already trusted. The UI test types into each
program but never submits anything, so no model is called. OpenCode runs from
the pinned binary with a disposable profile, as in check-ios-product.py.
"""

import argparse
import importlib.util
import json
import os
from pathlib import Path
import secrets
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("product", ROOT / "integration/check-ios-product.py")
product = importlib.util.module_from_spec(spec)
spec.loader.exec_module(product)


def resolvable(program):
    if program == "shell":
        return True
    if program == "opencode":
        return product.OPENCODE.is_file()
    for folder in ("/opt/homebrew/bin", "/usr/local/bin", str(Path.home() / ".local/bin")):
        if os.access(Path(folder) / program, os.X_OK):
            return True
    return shutil.which(program) is not None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("simulator", help="Already booted iPhone or iPad simulator UDID (never the paired parity simulator)")
    parser.add_argument("--project", default=str(ROOT), help="Folder the disposable host serves")
    parser.add_argument("--programs", default="shell,opencode,claude,codex")
    parser.add_argument("--evidence", default=str(ROOT / ".evidence/terminal-tour"))
    options = parser.parse_args()
    product.simulator_guard.refuse_protected(options.simulator)
    programs = [name for name in options.programs.split(",") if resolvable(name)]
    evidence = Path(options.evidence)
    evidence.mkdir(parents=True, exist_ok=True)
    original = product.FIXTURE.read_bytes()
    if json.loads(original).get("enabled") is not False:
        raise RuntimeError("Fixture.json must begin disabled")
    opencode = host = None
    stamp = str(int(time.time()))
    try:
        with tempfile.TemporaryDirectory(prefix="agentland-terminal-tour-") as location:
            temp = Path(location)
            password = secrets.token_urlsafe(32)
            env = product.open_code_environment(temp, password)
            oc_port = product.free_port()
            oc_url = f"http://127.0.0.1:{oc_port}"
            with (evidence / f"{stamp}-opencode.log").open("w") as oc_log:
                opencode = subprocess.Popen([str(product.OPENCODE), "serve", "--pure", "--hostname", "127.0.0.1",
                                             "--port", str(oc_port)], cwd=temp, env=env,
                                            stdout=oc_log, stderr=oc_log, start_new_session=True)
                product.wait_health(oc_url + "/global/health", process=opencode, password=password)
                binary = temp / "agentland-host"
                product.run(["go", "build", "-o", str(binary), "./cmd/agentland-host"], cwd=ROOT / "desktop", timeout=120)
                (temp / "opencode").symlink_to(product.OPENCODE)
                tls = json.loads(product.run([str(binary), "tls", "init", "--directory", str(temp / "tls"), "--hosts", "localhost"]))
                state = temp / "host.json"
                product.run([str(binary), "init", "--state", str(state), "--opencode-url", oc_url,
                             "--project", f"fixture=Fixture={options.project}"])
                port = product.free_port()
                address = f"https://localhost:{port}"
                host_env = os.environ.copy()
                host_env["AGENTLAND_OPENCODE_PASSWORD"] = password
                with (evidence / f"{stamp}-host.log").open("w") as host_log:
                    host = subprocess.Popen([str(binary), "serve", "--state", str(state), "--listen", f"127.0.0.1:{port}",
                                             "--cert", tls["certificateFile"], "--key", tls["keyFile"], "--enable-terminal",
                                             "--workspace-home", str(temp), "--no-agents"],
                                            env=host_env, stdout=host_log, stderr=host_log, start_new_session=True)
                    product.wait_health(address + "/v1/health", process=host, cafile=tls["certificateFile"], timeout=20)
                    product.run(["xcrun", "simctl", "ui", options.simulator, "appearance", "light"], timeout=10)
                    code = product.run([str(binary), "pair", "--pin", "--state", str(state)])
                    product.FIXTURE.write_text(json.dumps(dict(enabled=True, address=address, code=code,
                        fingerprint=tls["fingerprint"], phase="light", freshHost=True, tourPrograms=programs)) + "\n")
                    result = evidence / f"{stamp}-tour.xcresult"
                    log = evidence / f"{stamp}-tour.log"
                    command = ["xcodebuild", "-project", str(ROOT / "ios/AgentLand.xcodeproj"), "-scheme", "AgentLand",
                               "-destination", f"platform=iOS Simulator,id={options.simulator}",
                               "-derivedDataPath", str(product.DERIVED), "-resultBundlePath", str(result),
                               "-parallel-testing-enabled", "NO", "CODE_SIGNING_ALLOWED=YES", "CODE_SIGN_IDENTITY=-", "ARCHS=arm64",
                               "-only-testing:AgentLandUITests/FullWorkspaceUITests/testTerminalProgramsTour", "test"]
                    with log.open("w") as output:
                        code = subprocess.run(command, stdout=output, stderr=output, timeout=900).returncode
                    attachments = evidence / f"{stamp}-screenshots"
                    product.run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(result),
                                 "--output-path", str(attachments)], timeout=60)
                    print(f"{'PASS' if code == 0 else 'FAIL'}: {', '.join(programs)}; screenshots in {attachments}; log {log}")
    finally:
        product.FIXTURE.write_bytes(original)
        product.stop_process(host)
        product.stop_process(opencode)


if __name__ == "__main__":
    main()
