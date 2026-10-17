#!/usr/bin/env python3
"""Plain-chat turns survive the host's checks of the Chats space, and a message sent after Stop gets its reply.

No simulator. The disposable OpenCode (pinned binary, DEBUG log), fixture model and host of
check-ios-product.py (`--no-agents`, its own workspace home), a paired device of this check's own, and one
plain chat driven over the host's API as the app drives it, its chat event stream open. Each round a long
reply starts, `/v1/abort` stops it after 3 s, and after GAP seconds a new message goes (by default a slow one,
whose reply waits 8 s); the round passes when that message's reply completes.

B-15: OpenCode 1.18.31 writes "$schema" into the Chats space's opencode.json as it loads it, so the host found
the file changed at every check (once a minute), wrote its own again and had OpenCode dispose of the folder's
instance, which stopped whatever plain-chat turn was running. The rounds run for several minutes, through
several of those checks, and the check also fails if OpenCode disposed of the instance at all.

Usage: integration/check-plain-chat-turns.py [--rounds N] [--gaps 0,1,3] [--second TEXT]
Evidence: .evidence/plain-chat-turns/<stamp>/ (probe.log, events.log, host.log, opencode-debug.log, results.json).
"""

import argparse
import importlib.util
import json
import os
from pathlib import Path
import secrets
import ssl
import subprocess
import tempfile
import threading
import time
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("product", ROOT / "integration/check-ios-product.py")
product = importlib.util.module_from_spec(spec)
spec.loader.exec_module(product)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--rounds", type=int, default=8, help="Rounds for each gap")
    parser.add_argument("--gaps", default="0,1,3", help="Seconds between the stop and the next message, comma-separated")
    parser.add_argument("--second", default="AGENTLAND_SLOW after stop", help="The message sent after each stop")
    options = parser.parse_args()
    gaps = [float(gap) for gap in options.gaps.split(",")]
    out = Path(os.environ.get("AGENTLAND_EVIDENCE", ROOT / ".evidence/plain-chat-turns")) / str(int(time.time()))
    out.mkdir(parents=True, exist_ok=True)
    lock = threading.Lock()
    probe_log = (out / "probe.log").open("w")

    def note(text):
        line = time.strftime("%H:%M:%S") + f".{int(time.time() * 1000) % 1000:03d} {text}"
        with lock:
            print(line, file=probe_log, flush=True)
        print(line, flush=True)

    results = []
    with tempfile.TemporaryDirectory(prefix="agentland-plain-turns-") as location:
        temp = Path(location)
        server, requests = product.local_model_server("Fixture reply.", "Prefers tide tables in metres")
        project = temp / "project"
        project.mkdir(mode=0o700)
        provider = {"agentland-test": {"npm": "@ai-sdk/openai-compatible", "name": "AgentLand Local Fixture",
                    "options": {"baseURL": f"http://127.0.0.1:{server.server_port}/v1", "apiKey": "local-test-only"},
                    "models": {"fixture-model": {"name": "Deterministic Local Model", "limit": {"context": 8192, "output": 512}}}}}
        (project / "opencode.json").write_text(json.dumps({"$schema": "https://opencode.ai/config.json",
                                                           "model": "agentland-test/fixture-model", "provider": provider}) + "\n")
        password = secrets.token_urlsafe(32)
        env = product.open_code_environment(temp, password)
        # Plain chats run in the host's own folder: the profile's global configuration names the fixture model.
        (temp / "config" / "opencode").mkdir(mode=0o700)
        (temp / "config" / "opencode" / "opencode.json").write_text(json.dumps({
            "$schema": "https://opencode.ai/config.json", "model": "agentland-test/fixture-model",
            "small_model": "agentland-test/fixture-model", "provider": provider}) + "\n")
        oc_port = product.free_port()
        oc_url = f"http://127.0.0.1:{oc_port}"
        oc_log = (out / "opencode-debug.log").open("w")
        opencode = subprocess.Popen([str(product.OPENCODE), "serve", "--pure", "--hostname", "127.0.0.1", "--port", str(oc_port),
                                     "--print-logs", "--log-level", "DEBUG"], cwd=project, env=env, stdout=oc_log, stderr=oc_log,
                                    start_new_session=True)
        host = None
        try:
            product.wait_health(oc_url + "/global/health", process=opencode, password=password)
            binary = temp / "agentland-host"
            product.run(["go", "build", "-o", str(binary), "./cmd/agentland-host"], cwd=ROOT / "desktop", timeout=180)
            (temp / "opencode").symlink_to(product.OPENCODE)
            tls = json.loads(product.run([str(binary), "tls", "init", "--directory", str(temp / "tls"), "--hosts", "localhost"]))
            state = temp / "host.json"
            product.run([str(binary), "init", "--state", str(state), "--opencode-url", oc_url, "--project", f"fixture=Fixture={project}"])
            home = temp / "workspace-home"
            home.mkdir(mode=0o700)
            port = product.free_port()
            address = f"https://localhost:{port}"
            host_env = os.environ.copy()
            host_env["AGENTLAND_OPENCODE_PASSWORD"] = password
            host = subprocess.Popen([str(binary), "serve", "--state", str(state), "--listen", f"127.0.0.1:{port}",
                                     "--cert", tls["certificateFile"], "--key", tls["keyFile"], "--workspace-home", str(home),
                                     # OpenCode runs Chat only when asked (2026-10-12); this check drives its turns.
                                     "--no-agents", "--opencode-chat"], env=host_env, stdout=(out / "host.log").open("w"), stderr=subprocess.STDOUT,
                                    start_new_session=True)
            cafile = tls["certificateFile"]
            product.wait_health(address + "/v1/health", process=host, cafile=cafile, timeout=20)
            code = product.run([str(binary), "pair", "--pin", "--state", str(state)])
            token = product.host_json(address + "/v1/pair", cafile, body={"code": code, "deviceName": "Plain chat turns check"})["token"]
            product.wait_plain_chats(address, cafile, token, out / "host.log")
            context = ssl.create_default_context(cafile=cafile)

            def api(method, path, body=None, query=None):
                url = address + path + ("?" + urllib.parse.urlencode(query) if query else "")
                request = urllib.request.Request(url, data=None if body is None else json.dumps(body).encode(), method=method,
                                                 headers={"Content-Type": "application/json", "Authorization": "Bearer " + token})
                with urllib.request.urlopen(request, context=context, timeout=30) as response:
                    return json.load(response)

            sid = api("POST", "/v1/sessions", {"projectId": "chats", "title": "Plain chat turns", "provider": "opencode"})["id"]
            note(f"chat {sid}")
            events_log = (out / "events.log").open("w")

            def stream():
                url = address + "/v1/chat/events?" + urllib.parse.urlencode({"projectId": "chats", "sessionId": sid})
                request = urllib.request.Request(url, headers={"Authorization": "Bearer " + token})
                try:
                    with urllib.request.urlopen(request, context=context, timeout=900) as response:
                        for raw in response:
                            with lock:
                                events_log.write(time.strftime("%H:%M:%S ") + raw.decode(errors="replace"))
                                events_log.flush()
                except Exception as error:  # noqa: BLE001 - the stream ends with the host
                    note(f"event stream ended: {error}")

            threading.Thread(target=stream, daemon=True).start()

            def send(text):
                receipt = api("POST", "/v1/messages", {"projectId": "chats", "sessionId": sid, "text": text,
                                                       "model": "agentland-test/fixture-model", "clientMessageId": secrets.token_hex(16)})
                note(f"sent {text!r}: turn {receipt['turnId']}")
                return receipt["turnId"]

            def outcome(turn, timeout=45):
                deadline, last = time.monotonic() + timeout, None
                while time.monotonic() < deadline:
                    page = api("GET", "/v1/chat/messages", query={"projectId": "chats", "sessionId": sid, "limit": 10})
                    replies = [m for m in page["messages"] if m.get("role") == "assistant" and m.get("turnId") == turn]
                    if replies:
                        last = replies[0].get("status")
                        if last == "complete":
                            return "replied"
                        if last in ("aborted", "error", "failed"):
                            return "stopped (" + last + ")"
                    time.sleep(0.25)
                return f"no reply (last status {last})"

            note("first: " + outcome(send("Hello from the plain chat turns check")))
            for gap in gaps:
                for index in range(options.rounds):
                    send(f"AGENTLAND_LONG gap {gap} round {index}")
                    time.sleep(3)
                    started = time.monotonic()
                    api("POST", "/v1/abort", {"projectId": "chats", "sessionId": sid})
                    note(f"stopped in {(time.monotonic() - started) * 1000:.0f} ms")
                    time.sleep(gap)
                    row = {"gap": gap, "round": index, "outcome": outcome(send(f"{options.second} gap {gap} round {index}"))}
                    results.append(row)
                    note("round " + json.dumps(row))
        finally:
            if host is not None:
                product.stop_process(host)
            product.stop_process(opencode)
            server.shutdown()
            server.server_close()
            (out / "results.json").write_text(json.dumps(results, indent=1))
            (out / "model-prompts.json").write_text(json.dumps([product.last_user_text(item) for item in requests], indent=1))
    disposals = (out / "opencode-debug.log").read_text(errors="replace").count('message="disposing instance"')
    failed = [row for row in results if row["outcome"] != "replied"]
    if failed or disposals:
        raise SystemExit(f"FAIL: {len(failed)} of {len(results)} messages after Stop got no reply; OpenCode disposed of the "
                         f"Chats space's instance {disposals} times. Evidence: {out}")
    print(f"PASS: {len(results)} messages after Stop all replied; no instance disposed. Evidence: {out}")


if __name__ == "__main__":
    main()
