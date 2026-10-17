#!/usr/bin/env python3
"""Verify that the opening circus covers a delayed selected tab until it is ready.

This opt-in check uses only a disposable simulator named on the command line
and a local HTTPS fixture; it refuses the paired parity simulator. It can run
the same newly compiled XCTest bundle against the immutable pre-fix app
(``--variant baseline``) or the current app (``--variant current``).
No model service, user credential, paired device, or existing backend is used.

The selected surface's first read after a relaunch is held until the test has
looked at the opening cover, however long the relaunch took. Between
terminating the app and launching it again the test writes ``hold-<read>``
into the control folder named in Fixture.json; the relaunched app's first
request of that read waits until the test writes ``release-<read>`` (at most
MAX_HOLD seconds). The app's own order of requests cannot mark the relaunch:
its surface may ask before its capabilities or project list do.
"""

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import socket
import ssl
import subprocess
import tempfile
import threading
import time
from urllib.parse import urlsplit
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import simulator_guard  # noqa: E402


ROOT = Path(__file__).resolve().parents[1]
# The paired "AgentLand Parity iPhone" keeps the owner's pairing; checks never run on it.
DEVICE = ""
FIXTURE = ROOT / "ios/AgentLandUITests/Fixture.json"
EVIDENCE = ROOT / ".evidence/opening-readiness-20260922"
BASELINE_APP = EVIDENCE / "baseline/AgentLand.app"
# Worktrees that run this check at the same time pass their own build folder.
DERIVED = Path(os.environ.get("AGENTLAND_DERIVED_DATA", "/private/tmp/agentland-opening-derived"))
CHAT_TEST = "AgentLandUITests/FullWorkspaceUITests/testOpeningWaitsForSelectedChat"
SURFACE_TEST = "AgentLandUITests/FullWorkspaceUITests/testOpeningSurfacesResolveAfterDelay"
# Longest a held read waits for the test's release.
MAX_HOLD = 30.0


def run(args, *, cwd=ROOT, timeout=120, check=True):
    result = subprocess.run(args, cwd=cwd, capture_output=True, text=True, timeout=timeout)
    if check and result.returncode:
        output = result.stderr or result.stdout
        raise RuntimeError(f"{' '.join(map(str, args[:4]))} failed: {output[-3000:]}")
    return result


def free_port():
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


def stop_process(process):
    if process is None or process.poll() is not None:
        return
    os.killpg(process.pid, signal.SIGTERM)
    try:
        process.wait(timeout=8)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=5)


def stop_recording(process):
    if process is None or process.poll() is not None:
        return
    # simctl recordVideo writes the MP4 trailer on SIGINT.
    process.send_signal(signal.SIGINT)
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        stop_process(process)


class DelayedFixture(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address, handler, request_log, control):
        super().__init__(address, handler)
        self.request_log = request_log
        self.control = control
        self.lock = threading.Lock()
        self.file_list_requests = 0
        self.file_requests = 0
        self.terminal_output_requests = 0
        self.terminal_cold_consumed = False
        self.terminal_cold_followups = 0

    def reset_run(self):
        with self.lock:
            self.file_list_requests = 0
            self.file_requests = 0
            self.terminal_output_requests = 0
            self.terminal_cold_consumed = False
            self.terminal_cold_followups = 0
            for request in self.control.glob("*-*"):
                request.unlink(missing_ok=True)

    def armed(self, name):
        """Whether this request is the held `name` read: the first since the test asked for the hold."""
        with self.lock:
            request = self.control / f"hold-{name}"
            if not request.exists():
                return False
            request.unlink()
            return True

    def hold(self, name):
        """Answers the held read only once the test released it (or after MAX_HOLD)."""
        release = self.control / f"release-{name}"
        deadline = time.monotonic() + MAX_HOLD
        while not release.exists() and time.monotonic() < deadline:
            time.sleep(0.05)
        release.unlink(missing_ok=True)

    def handle_error(self, request, client_address):
        # URLSession cancels in-flight polling connections during app
        # termination. That expected reset is not a fixture failure.
        return

    def record(self, method, path, started, status, delayed=False):
        # Deliberately omit headers and bodies: bearer tokens and pairing codes
        # never enter evidence.
        entry = {"method": method, "path": path, "started": started,
                 "elapsed": round(time.monotonic() - started, 3),
                 "status": status, "delayed": delayed, "answered": round(time.time(), 3)}
        with self.lock:
            with self.request_log.open("a") as output:
                output.write(json.dumps(entry, sort_keys=True) + "\n")


class FixtureHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_args):
        pass

    def reply(self, value, *, status=200, delayed=False, started=None):
        body = json.dumps(value, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass
        self.server.record(self.command, urlsplit(self.path).path,
                           started if started is not None else time.monotonic(), status, delayed)

    def do_POST(self):
        started = time.monotonic()
        length = min(int(self.headers.get("Content-Length", "0")), 1 << 20)
        if length:
            self.rfile.read(length)
        path = urlsplit(self.path).path
        if path == "/v1/pair":
            self.server.reset_run()
            self.reply({"token": "local-opening-token", "deviceId": "opening-device"}, started=started)
        elif path == "/v1/sessions":
            self.reply({"id": "opening-chat", "title": "Opening readiness",
                        "projectId": "fixture"}, status=201, started=started)
        elif path == "/v1/terminals":
            self.reply({"id": "opening-terminal", "title": "Terminal",
                        "projectId": "fixture", "status": "running", "exitCode": None},
                       status=201, started=started)
        elif path in ("/v1/terminal/input", "/v1/terminal/resize"):
            self.reply({"accepted": True}, started=started)
        else:
            self.reply({"error": {"code": "unsupported", "message": "Fixture route unavailable."}},
                       status=404, started=started)

    def do_GET(self):
        started = time.monotonic()
        path = urlsplit(self.path).path
        if path == "/v1/health":
            return self.reply({"status": "ok", "protocolVersion": 1}, started=started)
        if path == "/v1/pulse":
            # A host without a pulse: the app checks /v1/health instead. Any other refusal reads as
            # an unreachable host, which stops the terminal's reads after its first one.
            return self.reply({"error": {"code": "not_found", "message": "No pulse on this fixture."}},
                              status=404, started=started)
        if path == "/v1/projects":
            # Keep project discovery quick. The meaningful hold belongs to the
            # selected tab and begins only after the cold relaunch.
            time.sleep(0.25)
            return self.reply({"projects": [{"id": "fixture", "name": "Fixture"}]}, started=started)
        if path == "/v1/capabilities":
            return self.reply({"interactions": True, "terminal": True,
                               "terminalPrograms": []}, started=started)
        if path == "/v1/chat/options":
            return self.reply({"models": [], "defaultModel": "", "agents": []}, started=started)
        if path == "/v1/chat/status":
            return self.reply({"state": "idle"}, started=started)
        if path == "/v1/interactions":
            return self.reply({"permissions": [], "questions": []}, started=started)
        if path == "/v1/messages":
            delayed = self.server.armed("messages")
            if delayed:
                self.server.hold("messages")
            return self.reply({"messages": [{"id": "fixture-message", "role": "assistant",
                                              "text": "Opening readiness fixture",
                                              "tools": []}]}, delayed=delayed, started=started)
        if path == "/v1/files":
            with self.server.lock:
                self.server.file_list_requests += 1
            delayed = self.server.armed("files")
            if delayed:
                self.server.hold("files")
            return self.reply({"entries": [{"name": "hello.txt", "path": "hello.txt",
                                             "isDirectory": False, "size": 23}]},
                              delayed=delayed, started=started)
        if path == "/v1/file":
            with self.server.lock:
                self.server.file_requests += 1
            delayed = self.server.armed("file")
            if delayed:
                self.server.hold("file")
            return self.reply({"path": "hello.txt", "content": "Opening editor fixture\n",
                               "revision": "fixture-revision"}, delayed=delayed, started=started)
        if path == "/v1/terminal/output":
            cold = self.server.armed("terminal")
            with self.server.lock:
                self.server.terminal_output_requests += 1
                if cold:
                    self.server.terminal_cold_consumed = True
                elif self.server.terminal_cold_consumed:
                    self.server.terminal_cold_followups += 1
                followup = self.server.terminal_cold_followups
            if not self.server.terminal_cold_consumed:
                # Before the relaunch the terminal reads nothing new; it advances to cursor 1. The host holds a
                # read with nothing new until output comes (`wait`); answered at once, a terminal kept from an
                # earlier test reads again at once, hundreds of times a second, and the next test's app stops
                # answering XCUITest. A second stands in for the host's hold.
                time.sleep(1)
                return self.reply({"data": "", "cursor": 1, "reset": False,
                                   "status": "running", "exitCode": None}, started=started)
            if cold:
                # The relaunched renderer's first read, from cursor 0.
                self.server.hold("terminal")
                # Device-status report: SwiftTerm must parse this while the
                # opening overlay is present and send its reply through the
                # ordered production input queue.
                return self.reply({"data": "G1s2bg==", "cursor": 5, "reset": False,
                                   "status": "running", "exitCode": None},
                                  delayed=True, started=started)
            if followup == 1:
                time.sleep(1.5)
                return self.reply({"data": "", "cursor": 5, "reset": False,
                                   "status": "running", "exitCode": None}, started=started)
            return self.reply({"error": {"code": "terminal_unavailable",
                                          "message": "Fixture terminal disconnected."}},
                              status=503, started=started)
        return self.reply({"error": {"code": "unsupported", "message": "Fixture route unavailable."}},
                          status=404, started=started)


def validate_simulator():
    simulator_guard.refuse_protected(DEVICE)
    devices = json.loads(run(["xcrun", "simctl", "list", "devices", "--json"]).stdout)
    matches = [item for group in devices["devices"].values() for item in group
               if item["udid"] == DEVICE]
    if len(matches) != 1 or matches[0]["state"] != "Booted" or "iPhone" not in matches[0]["name"]:
        raise RuntimeError(f"Disposable iPhone simulator {DEVICE} must already be Booted")


def build_for_testing():
    command = ["xcodebuild", "-project", str(ROOT / "ios/AgentLand.xcodeproj"),
               "-scheme", "AgentLand", "-configuration", "Debug",
               "-destination", f"platform=iOS Simulator,id={DEVICE}",
               "-derivedDataPath", str(DERIVED), "-parallel-testing-enabled", "NO",
               "CODE_SIGNING_ALLOWED=YES", "CODE_SIGN_IDENTITY=-", "ARCHS=arm64", "build-for-testing"]
    log = EVIDENCE / "build-for-testing.log"
    with log.open("w") as output:
        process = subprocess.run(command, cwd=ROOT, stdout=output, stderr=subprocess.STDOUT,
                                 text=True, timeout=420)
    if process.returncode:
        raise RuntimeError(f"XCTest build failed; inspect {log}")
    runs = sorted((DERIVED / "Build/Products").glob("*.xctestrun"))
    if not runs:
        raise RuntimeError("build-for-testing produced no xctestrun file")
    return runs[0]


def xctestrun_for(source, variant):
    # __TESTROOT__ is resolved relative to the xctestrun file itself. Keep the
    # executable copy beside Build/Products and archive a second copy as evidence.
    target = source.parent / f"opening-{variant}.xctestrun"
    with source.open("rb") as stream:
        payload = plistlib.load(stream)
    if variant == "baseline":
        if not (BASELINE_APP / "AgentLand").is_file():
            raise RuntimeError(f"Immutable baseline app is missing: {BASELINE_APP}")
        test = payload["AgentLandUITests"]
        test["UITargetAppPath"] = str(BASELINE_APP)
        products = test.get("DependentProductPaths", [])
        if products:
            products[0] = str(BASELINE_APP)
    payload["AgentLandUITests"]["SystemAttachmentLifetime"] = "keepAlways"
    with target.open("wb") as stream:
        plistlib.dump(payload, stream)
    shutil.copy2(target, EVIDENCE / f"opening-{variant}.xctestrun")
    return target


def run_test(xctestrun, variant, selected_tests):
    result = EVIDENCE / f"opening-{variant}.xcresult"
    log = EVIDENCE / f"opening-{variant}.log"
    if result.exists():
        shutil.rmtree(result)
    command = ["xcodebuild", "test-without-building", "-xctestrun", str(xctestrun),
               "-destination", f"platform=iOS Simulator,id={DEVICE}",
               "-resultBundlePath", str(result), "-parallel-testing-enabled", "NO"]
    if selected_tests in ("chat", "all"):
        command.append("-only-testing:" + CHAT_TEST)
    if selected_tests in ("surfaces", "all"):
        command.append("-only-testing:" + SURFACE_TEST)
    video = EVIDENCE / f"opening-{variant}.mp4"
    video_log = EVIDENCE / f"opening-{variant}-record-video.log"
    video_output = video_log.open("w")
    video_process = subprocess.Popen(
        ["xcrun", "simctl", "io", DEVICE, "recordVideo", "--codec=h264", "--force", str(video)],
        stdout=video_output, stderr=subprocess.STDOUT, text=True, start_new_session=True)
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        if video_process.poll() is not None:
            video_output.close()
            raise RuntimeError(f"simctl recordVideo exited before recording; inspect {video_log}")
        video_output.flush()
        if "Recording started" in video_log.read_text(errors="replace"):
            break
        time.sleep(0.1)
    else:
        stop_recording(video_process)
        video_output.close()
        raise RuntimeError(f"simctl recordVideo did not start within 8s; inspect {video_log}")
    try:
        with log.open("w") as output:
            process = subprocess.Popen(command, cwd=ROOT, stdout=output, stderr=subprocess.STDOUT,
                                       text=True, start_new_session=True)
            try:
                code = process.wait(timeout=180)
            except subprocess.TimeoutExpired:
                stop_process(process)
                raise RuntimeError(f"{variant} UI test timed out after 180s; inspect {log}")
    finally:
        stop_recording(video_process)
        video_output.close()
    if not video.is_file() or video.stat().st_size < 1024:
        raise RuntimeError(f"simctl did not finalize a usable recording; inspect {video_log}")
    attachments = EVIDENCE / f"opening-{variant}-attachments"
    if attachments.exists():
        shutil.rmtree(attachments)
    if result.exists():
        export = run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(result),
                      "--output-path", str(attachments)], timeout=60, check=False)
        if export.returncode:
            (EVIDENCE / f"opening-{variant}-attachment-export.log").write_text(
                export.stdout + export.stderr)
    return code, log, result, command


def main():
    global DEVICE
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("simulator", help="Already booted disposable iPhone simulator UDID (never the paired parity simulator)")
    parser.add_argument("--variant", choices=("baseline", "current", "both"), default="current")
    parser.add_argument("--tests", choices=("chat", "surfaces", "all"), default="all")
    options = parser.parse_args()
    DEVICE = options.simulator
    if options.variant != "current" and options.tests != "chat":
        parser.error("baseline variants support only --tests chat")
    EVIDENCE.mkdir(parents=True, exist_ok=True)
    validate_simulator()
    original = FIXTURE.read_bytes()
    if json.loads(original).get("enabled") is not False:
        raise RuntimeError("Fixture.json must begin disabled; another opt-in workflow may own it")

    server = None
    thread = None
    with tempfile.TemporaryDirectory(prefix="agentland-opening-") as location:
        temp = Path(location)
        binary = temp / "agentland-host"
        # The test's hold and release requests; the simulator's test runner writes into it.
        control = Path(tempfile.mkdtemp(prefix="agentland-opening-control-", dir="/private/tmp"))
        try:
            run(["go", "build", "-o", str(binary), "./cmd/agentland-host"],
                cwd=ROOT / "desktop", timeout=120)
            tls = json.loads(run([str(binary), "tls", "init", "--directory", str(temp / "tls"),
                                  "--hosts", "localhost"]).stdout)
            port = free_port()
            request_log = EVIDENCE / f"opening-{options.variant}-requests.jsonl"
            request_log.write_text("")
            server = DelayedFixture(("127.0.0.1", port), FixtureHandler, request_log, control)
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.load_cert_chain(tls["certificateFile"], tls["keyFile"])
            server.socket = context.wrap_socket(server.socket, server_side=True)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()

            FIXTURE.write_text(json.dumps({"enabled": True, "phase": "opening",
                                           "address": f"https://localhost:{port}",
                                           "code": "local-opening-code",
                                           "fingerprint": tls["fingerprint"],
                                           "chatReply": "Opening readiness fixture",
                                           "control": str(control)}) + "\n")
            xctestrun = build_for_testing()
            run(["xcrun", "simctl", "spawn", DEVICE, "notifyutil", "-s",
                 "com.apple.BiometricKit.enrollmentChanged", "1", "-p",
                 "com.apple.BiometricKit.enrollmentChanged"], timeout=30)

            variants = ("baseline", "current") if options.variant == "both" else (options.variant,)
            report = {"simulator": DEVICE, "maxHoldSeconds": MAX_HOLD,
                      "selectedTests": options.tests, "results": {}}
            for variant in variants:
                server.reset_run()
                # The disposable simulator may contain state from a previous
                # integration check. Start each variant with the shipping first
                # launch rather than letting an unrelated saved host consume the
                # fixture's cold-relaunch counter.
                run(["xcrun", "simctl", "uninstall", DEVICE, "dev.agentland.client"],
                    timeout=30, check=False)
                runfile = xctestrun_for(xctestrun, variant)
                code, log, result, command = run_test(runfile, variant, options.tests)
                report["results"][variant] = {"exitCode": code, "passed": code == 0,
                                               "log": str(log.relative_to(ROOT)),
                                               "resultBundle": str(result.relative_to(ROOT)),
                                               "command": command}
                print(f"{variant.upper()}: {'PASS' if code == 0 else 'FAIL'} ({log})", flush=True)
            (EVIDENCE / f"opening-{options.variant}-verification.json").write_text(
                json.dumps(report, indent=2) + "\n")

            if "current" in variants and options.tests in ("surfaces", "all"):
                paths = [json.loads(line)["path"] for line in request_log.read_text().splitlines()]
                if "/v1/terminal/input" not in paths:
                    raise RuntimeError("Terminal ESC[6n fixture produced no protocol reply at /v1/terminal/input")

            if options.variant == "baseline" and report["results"]["baseline"]["passed"]:
                raise RuntimeError("Baseline unexpectedly passed; the regression did not reproduce")
            if options.variant == "current" and not report["results"]["current"]["passed"]:
                raise RuntimeError("Current opening regression failed")
            if options.variant == "both":
                if report["results"]["baseline"]["passed"]:
                    raise RuntimeError("Baseline unexpectedly passed; the regression did not reproduce")
                if not report["results"]["current"]["passed"]:
                    raise RuntimeError("Current opening regression failed")
        finally:
            FIXTURE.write_bytes(original)
            shutil.rmtree(control, ignore_errors=True)
            if server is not None:
                server.shutdown()
                server.server_close()
            if thread is not None:
                thread.join(timeout=3)


if __name__ == "__main__":
    main()
