#!/usr/bin/env python3
"""Exercise the shipping iPhone app against disposable OpenCode, TLS host and local model.

Run with one already booted disposable simulator UDID (integration/simulator_guard.py refuses the
owner's paired simulators). The model fixture serves only on 127.0.0.1; it returns deterministic
text and never calls a paid provider. The app and its UI tests are built once per run and each test
runs from that build with its own fixture file.

A tester's sessions (ios/AgentLandUITests/ExploratoryUITests.swift):
  --script integration/scripts/<name>.json   a scripted session (steps, host checks, screenshots)
  --seed N [--walk-steps 60]                 a seeded random walk with invariants after every step
  --matrix <surface>:<interruption>[,...]    one surface through interruptions ("all" for every one)
  --erase                                    a true first install (Keychain and privacy grants wiped)
  --enable-preview                           Browser: a preview listener and a loopback page
  --keep-going                               run everything selected and report every failure at the end
Set AGENTLAND_EVIDENCE to keep a session's logs, results and screenshots in a folder of its own.
"""

import argparse
import base64
import contextlib
import fcntl
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
import pty
import re
from pathlib import Path
import secrets
import select
import shutil
import signal
import socket
import sqlite3
import ssl
import statistics
import struct
import subprocess
import tempfile
import termios
import threading
import time
import urllib.error
import urllib.request
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import simulator_guard  # noqa: E402


ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / "ios/AgentLandUITests/Fixture.json"
OPENCODE = ROOT / ".build/opencode/1.18.31/arm64/opencode"
# AGENTLAND_EVIDENCE keeps a session's logs, results and screenshots in a folder of its own.
EVIDENCE = Path(os.environ.get("AGENTLAND_EVIDENCE", ROOT / ".evidence/ios-product"))
# Worktrees that run this check at the same time pass their own build folder.
DERIVED = Path(os.environ.get("AGENTLAND_DERIVED_DATA", "/private/tmp/agentland-product-derived"))


def run(args, *, cwd=None, env=None, timeout=120):
    result = subprocess.run(args, cwd=cwd, env=env, capture_output=True, text=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError(f"{' '.join(map(str, args[:3]))} failed: {(result.stderr or result.stdout)[-2200:]}")
    return result.stdout.strip()


# The disposable host binary and state path that `stop_terminals` ends the keeper of (set once they exist).
KEEPER_TARGET = {"binary": None, "state": None}


def stop_terminals():
    """End every terminal and the keeper of the disposable state (terminals outlive the host)."""
    if KEEPER_TARGET["binary"] is None:
        return
    try:
        result = subprocess.run([str(KEEPER_TARGET["binary"]), "terminals", "stop", "--state", str(KEEPER_TARGET["state"])],
                                timeout=20, capture_output=True, text=True)
        if result.returncode:
            print(f"WARNING: terminals stop failed (exit {result.returncode}); a keeper may still run: "
                  f"{(result.stderr or result.stdout).strip()[-300:]}", flush=True)
    except (subprocess.TimeoutExpired, OSError) as error:  # cleanup never raises
        print(f"WARNING: terminals stop did not finish ({error!r}); a keeper may still run", flush=True)


@contextlib.contextmanager
def disposable_directory(prefix):
    """A temporary folder whose keeper is ended while the host binary and state in it still exist."""
    with tempfile.TemporaryDirectory(prefix=prefix) as location:
        try:
            yield location
        finally:
            stop_terminals()
            KEEPER_TARGET.update(binary=None, state=None)


def verify_terminal_survived_kill(project, state):
    """The shell lived through a killed host, and the archive recorded its whole output without a gap."""
    before = (project / "pid-before.txt").read_text().strip()
    after_file = project / "pid-after.txt"
    deadline = time.time() + 10
    while not after_file.exists() and time.time() < deadline:
        time.sleep(0.5)
    if not after_file.exists() or not before or after_file.read_text().strip() != before:
        raise RuntimeError(f"The terminal's shell changed across the killed host: before {before!r}, after "
                           f"{after_file.read_text().strip() if after_file.exists() else 'missing'!r}")
    typed = project / "after-kill.txt"
    if not typed.exists() or typed.read_text().strip() != "typed-after-kill":
        raise RuntimeError("Input typed after the host came back did not reach the same shell")
    archive = Path(str(state) + ".archive")
    # Read-only, so this check never changes the archive the host writes.
    database = sqlite3.connect(f"file:{archive / 'archive.db'}?mode=ro", uri=True, timeout=5)
    try:
        row = database.execute("SELECT gap_bytes, file FROM terminal_logs ORDER BY started_at DESC LIMIT 1").fetchone()
    finally:
        database.close()
    if row is None:
        raise RuntimeError("The archive has no terminal log")
    gap, relative = row
    if gap != 0:
        raise RuntimeError(f"The archived terminal log counts a gap of {gap} bytes across the killed host")
    log = archive / relative
    deadline = time.time() + 10
    missing = []
    while time.time() < deadline:
        text = log.read_bytes().decode("utf-8", "replace") if log.exists() else ""
        missing = [i for i in range(1, 41) if not re.search(rf"tick-{i}(?!\d)", text)]
        if not missing:
            break
        time.sleep(0.5)
    if missing:
        raise RuntimeError(f"The archived terminal log lacks tick-{missing[0]} (and {len(missing) - 1} more)")
    return before


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


def wait_health(url, *, process, password=None, cafile=None, timeout=35):
    context = ssl.create_default_context(cafile=cafile) if cafile else None
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f"{url} exited before readiness")
        request = urllib.request.Request(url)
        if password:
            credentials = base64.b64encode(f"opencode:{password}".encode()).decode()
            request.add_header("Authorization", "Basic " + credentials)
        try:
            with urllib.request.urlopen(request, context=context, timeout=2) as response:
                body = json.load(response)
                if body.get("healthy") is True or body.get("status") == "ok":
                    return
        except (OSError, urllib.error.URLError, json.JSONDecodeError):
            time.sleep(.15)
    raise RuntimeError(f"{url} did not become healthy within {timeout}s")


def host_json(url, cafile, token=None, body=None, timeout=10):
    """The host's JSON answer to a GET, or to a POST of `body`, as a paired device asks it (`token`)."""
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = "Bearer " + token
    request = urllib.request.Request(url, data=None if body is None else json.dumps(body).encode(),
                                     method="GET" if body is None else "POST", headers=headers)
    with urllib.request.urlopen(request, context=ssl.create_default_context(cafile=cafile), timeout=timeout) as response:
        return json.load(response)


def wait_plain_chats(address, cafile, token, log, timeout=60):
    """Waits until the host lists plain chats: its OpenCode confirmed the chat agent. Each test starts then, so the
    app it pairs reads capabilities with plain chats from the first and takes one known path to its chats."""
    deadline = time.monotonic() + timeout
    while True:
        try:
            plain = host_json(address + "/v1/capabilities", cafile, token).get("plainChats") or {}
            if plain.get("projectId") == "chats":
                return
        except (OSError, urllib.error.URLError, json.JSONDecodeError):
            pass
        if time.monotonic() > deadline:
            raise RuntimeError(f"The host did not list plain chats within {timeout}s (its chat agent unconfirmed); inspect {log}")
        time.sleep(0.5)


def opencode_json(url, password, project):
    request = urllib.request.Request(url)
    credentials = base64.b64encode(f"opencode:{password}".encode()).decode()
    request.add_header("Authorization", "Basic " + credentials)
    request.add_header("X-OpenCode-Directory", str(project))
    with urllib.request.urlopen(request, timeout=12) as response:
        return json.load(response)


def open_code_environment(temp, password):
    # Preserve HOME for shell tools; OpenCode's own test-home override and all
    # XDG paths are disposable. No provider key or inherited OpenCode setting.
    env = {key: os.environ[key] for key in ("HOME", "USER", "LANG") if key in os.environ}
    env["PATH"] = os.environ.get("PATH", "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin")
    for key, folder in (("OPENCODE_TEST_HOME", "home"), ("XDG_CONFIG_HOME", "config"),
                        ("XDG_DATA_HOME", "data"), ("XDG_STATE_HOME", "state"),
                        ("XDG_CACHE_HOME", "cache"), ("TMPDIR", "tmp")):
        path = temp / folder
        path.mkdir(mode=0o700)
        env[key] = str(path)
    env.update(OPENCODE_SERVER_PASSWORD=password, OPENCODE_DISABLE_AUTOUPDATE="true",
               SHELL="/bin/sh", HISTFILE=str(temp / "shell-history"))
    return env


# testNamedOpenCodeFlow asks OpenCode's TUI for this: sixty lines overflow its message list, so reaching
# the first line again takes scrolling.
SCROLL_REPLY = "\n".join(f"Scroll line {number:02d}" for number in range(1, 61))

MARKDOWN_REPLY = """## Fixture heading

- first item
- second item

| Name | Value |
|------|-------|
| fixture-cell | 1 |

```swift
print("fixture")
```"""


def last_user_text(body):
    for message in reversed(body.get("messages", [])):
        if message.get("role") != "user":
            continue
        content = message.get("content")
        if isinstance(content, str):
            return content
        if isinstance(content, list):
            return " ".join(part.get("text", "") for part in content if isinstance(part, dict))
    return ""


def stream_reply(marker):
    """The word-by-word reply of AGENTLAND_STREAM, ending in the run's marker."""
    return "Streaming reply from the local fixture arrives one word at a time and ends with " + marker


# Plain chats' memory (PlainChatUITests): AGENTLAND_MEMORY_SAVE makes the fixture model call the host's
# agentland_memory_save with the run's fact; AGENTLAND_MEMORY_FORGET calls agentland_memory_forget with the id of
# that fact, which it reads from the entries the host puts in the prompt's system text (docs/HOST-API.md "The chat
# agent"). Each calls its tool only when the prompt offers it, and answers in text once the tool has answered.
MEMORY_ENTRY = re.compile(r'\{"id":"(mem_[^"\\]+)","text":"((?:[^"\\]|\\.)*)"\}')
MEMORY_SAVED_REPLY = "I will remember that."
MEMORY_FORGOTTEN_REPLY = "I have forgotten that."


def system_text(body):
    texts = []
    for message in body.get("messages", []):
        if message.get("role") != "system":
            continue
        content = message.get("content")
        if isinstance(content, str):
            texts.append(content)
        elif isinstance(content, list):
            texts.extend(part.get("text", "") for part in content if isinstance(part, dict))
    return "\n".join(texts)


def remembered(body):
    """The memory entries the host put in the prompt's system text, as (id, text), oldest first."""
    return [(match.group(1), json.loads('"' + match.group(2) + '"')) for match in MEMORY_ENTRY.finditer(system_text(body))]


def offered_tools(body):
    return {tool.get("function", {}).get("name") for tool in body.get("tools") or [] if isinstance(tool, dict)}


def memory_call(prompt, body, fact):
    """The tool call a memory marker asks for, as (name, arguments), or None."""
    tools = offered_tools(body)
    if "AGENTLAND_MEMORY_SAVE" in prompt and "agentland_memory_save" in tools:
        return "agentland_memory_save", {"text": fact}
    if "AGENTLAND_MEMORY_FORGET" in prompt and "agentland_memory_forget" in tools:
        ids = [entry_id for entry_id, text in remembered(body) if text == fact]
        if ids:
            return "agentland_memory_forget", {"id": ids[-1]}
    return None


APPROVAL_COMMAND = "echo approved-by-phone > approval-proof.txt"
# testTerminalWheelScroll runs this in the phone's shell: it turns on the alternate screen and SGR mouse
# reporting as OpenCode does, keeps every byte it reads for twelve seconds in wheel-proof.txt, and puts
# the screen back.
WHEEL_PROBE = """import os, select, sys, termios, time, tty
fd = sys.stdin.fileno()
saved = termios.tcgetattr(fd)
tty.setraw(fd)
os.write(1, b"\\x1b[?1049h\\x1b[?1000h\\x1b[?1006h\\x1b[2J\\x1b[HWHEEL READY")
received = b""
end = time.time() + 12
while time.time() < end:
    ready, _, _ = select.select([fd], [], [], 0.2)
    if ready:
        received += os.read(fd, 4096)
os.write(1, b"\\x1b[?1006l\\x1b[?1000l\\x1b[?1049l")
termios.tcsetattr(fd, termios.TCSANOW, saved)
open("wheel-proof.txt", "wb").write(received)
"""
WHEEL_REPORTS = re.compile(rb"(?:\x1b\[<6[45];\d+;\d+M)+")
APPROVAL_FOLLOW_UP = "Command finished after approval."

# testFileOperations works in the project's disposable `ops` folder; the upload is the UI tests' small file.
UPLOAD_PROOF = "Uploaded by the AgentLand file operations test.\n"
# testGitStageAndCommit's repository and the identity in its own configuration.
GIT_NAME = "AgentLand Test"
GIT_EMAIL = "test@agentland.invalid"


def git(repository, *args):
    """Runs Git in the fixture repository with the owner's global and system configuration hidden, so
    hooks, signing and identity come only from the repository's own configuration."""
    env = {key: os.environ[key] for key in ("PATH", "HOME", "LANG") if key in os.environ}
    env.update(GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1", GIT_TERMINAL_PROMPT="0")
    return run(["git", "-C", str(repository), *args], env=env, timeout=30)


def prepare_file_operations(project, token):
    ops = project / "ops"
    shutil.rmtree(ops, ignore_errors=True)
    (ops / "target").mkdir(parents=True)
    (ops / "rename-me.txt").write_text("Rename me from the phone.\n")
    (ops / "move-me.txt").write_text("Move me into target.\n")
    trash = ops / f"trash-me-{secrets.token_hex(4)}.txt"
    trash.write_text("Move me to the Trash.\n")
    (ops / "search-target.swift").write_text(f"// Search fixture\nlet first = 1\nlet token = \"{token}\"\nlet last = 2\n")
    return trash.name


def clean_file_operations(project, trash_name):
    """Removes the ops folder and, when the host moved the disposable fixture file into the owner's
    Trash, takes exactly that file back out."""
    trashed = Path.home() / ".Trash" / trash_name
    if trashed.is_file():
        trashed.unlink()
    shutil.rmtree(project / "ops", ignore_errors=True)


def verify_file_operations(project, trash_name):
    ops = project / "ops"
    trashed = Path.home() / ".Trash" / trash_name
    try:
        if not (ops / "renamed.txt").is_file() or (ops / "rename-me.txt").exists():
            raise RuntimeError("The rename from the phone did not reach the host")
        if not (ops / "made-on-phone").is_dir():
            raise RuntimeError("The new folder from the phone is missing on the host")
        if not (ops / "target" / "move-me.txt").is_file() or (ops / "move-me.txt").exists():
            raise RuntimeError("The move from the phone did not reach the host")
        if (ops / trash_name).exists():
            raise RuntimeError("The trashed file is still in the project")
        for name in ("upload-proof.txt", "upload-proof 2.txt"):
            if (ops / name).read_text() != UPLOAD_PROOF:
                raise RuntimeError(f"The upload {name} does not hold the phone's bytes")
        return "Trash" if trashed.exists() else "permanent delete"
    finally:
        clean_file_operations(project, trash_name)


def prepare_git_repository(project):
    repository = project / "git-fixture"
    shutil.rmtree(repository, ignore_errors=True)
    repository.mkdir()
    git(repository, "init", "-q", "-b", "main")
    for key, value in (("user.name", GIT_NAME), ("user.email", GIT_EMAIL), ("commit.gpgsign", "false")):
        git(repository, "config", key, value)
    (repository / "README.md").write_text("# Git fixture\n\nFirst line.\n")
    (repository / "notes.txt").write_text("Unchanged notes.\n")
    git(repository, "add", "-A")
    git(repository, "commit", "-q", "--no-verify", "-m", "Initial fixture commit")
    (repository / "README.md").write_text("# Git fixture\n\nFirst line.\nAdded from the harness for staging.\n")
    (repository / "new-file.txt").write_text("An untracked file that stays unstaged.\n")
    return repository


def verify_git_commit(repository, message):
    try:
        subject, name, email = git(repository, "log", "-1", "--format=%s%n%an%n%ae").splitlines()
        if subject != message:
            raise RuntimeError(f"The newest commit is {subject!r}, not the phone's {message!r}")
        if (name, email) != (GIT_NAME, GIT_EMAIL):
            raise RuntimeError(f"The commit was made as {name} <{email}>, not the repository's identity")
        files = git(repository, "show", "--name-only", "--format=", "HEAD").split()
        if files != ["README.md"]:
            raise RuntimeError(f"The commit holds {files}, not only the staged README.md")
        if "new-file.txt" not in git(repository, "status", "--porcelain"):
            raise RuntimeError("The unstaged file should still be untracked")
        return git(repository, "rev-parse", "--short", "HEAD")
    finally:
        shutil.rmtree(repository, ignore_errors=True)


def prepare_workspace_home(home):
    """The host's home folder for workspace management (`serve --workspace-home`): Developer, Desktop and
    Documents as the places to start from, and in Developer a small Git repository (testWorkspaceScreenshots
    adds it as a workspace and removes it again) and a plain folder."""
    for folder in ("Developer", "Desktop", "Documents"):
        (home / folder).mkdir(parents=True, exist_ok=True)
    sample = home / "Developer" / "sample-repo"
    sample.mkdir(exist_ok=True)
    git(sample, "init", "-q", "-b", "main")
    (sample / "README.md").write_text("# Sample repository\n")
    (home / "Developer" / "scratch").mkdir(exist_ok=True)


def configured_projects(binary, state):
    return json.loads(run([str(binary), "config", "show", "--state", str(state)])).get("projects") or []


def verify_workspace_management(binary, state, home, name):
    """testWorkspaceManagement made `name` in ~/Developer as a Git repository, renamed, closed and removed
    it: the folder and its repository stay on disk, and the host's state no longer lists it."""
    folder = home / "Developer" / name
    try:
        if not folder.is_dir():
            raise RuntimeError(f"The workspace folder {folder} made from the phone is missing")
        if not (folder / ".git").exists():
            raise RuntimeError("The new workspace was made without its Git repository")
        resolved = folder.resolve()
        for project in configured_projects(binary, state):
            directory = project.get("directory") or ""
            if directory and Path(directory).resolve() == resolved:
                raise RuntimeError(f"The host still lists the removed workspace: {project}")
        # A new repository has no commit yet: its branch is the unborn HEAD's.
        branch = git(folder, "symbolic-ref", "--short", "HEAD")
        if branch != "main":
            raise RuntimeError(f"The new repository is on {branch!r}, not main")
        return branch
    finally:
        shutil.rmtree(folder, ignore_errors=True)


def verify_plain_chat_memory(state, fact, requests):
    """testPlainChatFlow saved `fact` twice: a plain chat's prompt carried it in the host's memory text, so the
    host kept it, and its memory keeps it no more, since Undo removed one entry and the forget the other."""
    if not any(text == fact for body in list(requests) for _, text in remembered(body)):
        raise RuntimeError("No plain-chat prompt carried the saved fact: the host never kept it")
    memory = Path(str(state) + ".memory.json")
    kept = [entry.get("text") for entry in json.loads(memory.read_text()).get("entries") or []] if memory.exists() else []
    if fact in kept:
        raise RuntimeError(f"The host's memory still keeps the fact after Undo and the forget: {kept}")
    return len(kept)


def local_model_server(reply, memory_fact):
    requests = []
    lock = threading.Lock()

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass

        def write_json(self, value):
            body = json.dumps(value).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def chunk(self, delta, finish=None):
            chunk = {"id": "fixture-response", "object": "chat.completion.chunk", "created": 0,
                     "model": "fixture-model", "choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}
            self.wfile.write(b"data: " + json.dumps(chunk).encode() + b"\n\n")
            self.wfile.flush()

        def do_GET(self):
            if self.path == "/v1/models":
                self.write_json({"object": "list", "data": [{"id": "fixture-model", "object": "model"}]})
            else:
                self.send_error(404)

        def do_POST(self):
            if self.path != "/v1/chat/completions":
                self.send_error(404)
                return
            length = int(self.headers.get("Content-Length", "0"))
            if length > 2 << 20:
                self.send_error(413)
                return
            body = json.loads(self.rfile.read(length))
            with lock:
                requests.append(body)
            # Chat-feature markers: a formatted reply, and a slow one that keeps
            # the session busy long enough to queue a follow-up behind it.
            prompt = last_user_text(body)
            answer = MARKDOWN_REPLY if "AGENTLAND_MARKDOWN" in prompt else SCROLL_REPLY if "AGENTLAND_SCROLL" in prompt else reply
            if "AGENTLAND_SLOW" in prompt:
                time.sleep(8)
            if body.get("stream") is False:
                self.write_json({"id": "fixture-response", "object": "chat.completion", "created": 0,
                                 "model": "fixture-model", "choices": [{"index": 0, "message":
                                 {"role": "assistant", "content": answer}, "finish_reason": "stop"}],
                                 "usage": {"prompt_tokens": 20, "completion_tokens": 8, "total_tokens": 28}})
                return
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.end_headers()
            messages = body.get("messages", [])
            answered_tool = bool(messages) and messages[-1].get("role") == "tool"
            memory = None if answered_tool else memory_call(prompt, body, memory_fact)
            try:
                if memory is not None:
                    name, arguments = memory
                    self.chunk({"role": "assistant", "content": ""})
                    self.chunk({"tool_calls": [{"index": 0, "id": "call_fixture_" + name, "type": "function",
                                                "function": {"name": name, "arguments": ""}}]})
                    self.chunk({"tool_calls": [{"index": 0, "function": {"arguments": json.dumps(arguments)}}]})
                    self.chunk({}, "tool_calls")
                elif answered_tool and ("AGENTLAND_MEMORY_SAVE" in prompt or "AGENTLAND_MEMORY_FORGET" in prompt):
                    saved = "AGENTLAND_MEMORY_SAVE" in prompt
                    self.chunk({"role": "assistant", "content": MEMORY_SAVED_REPLY if saved else MEMORY_FORGOTTEN_REPLY})
                    self.chunk({}, "stop")
                elif "AGENTLAND_APPROVAL" in prompt and not answered_tool:
                    # A bash tool call; OpenCode asks for permission before running it.
                    arguments = json.dumps({"command": APPROVAL_COMMAND, "description": "Write the approval proof"})
                    self.chunk({"role": "assistant", "content": ""})
                    self.chunk({"tool_calls": [{"index": 0, "id": "call_fixture_approval", "type": "function",
                                                "function": {"name": "bash", "arguments": ""}}]})
                    self.chunk({"tool_calls": [{"index": 0, "function": {"arguments": arguments}}]})
                    self.chunk({}, "tool_calls")
                elif "AGENTLAND_APPROVAL" in prompt:
                    self.chunk({"role": "assistant", "content": APPROVAL_FOLLOW_UP})
                    self.chunk({}, "stop")
                elif "AGENTLAND_STREAM" in prompt or "AGENTLAND_LONG" in prompt:
                    # Word by word, so the app shows the reply growing.
                    words = stream_reply(reply).split(" ") if "AGENTLAND_STREAM" in prompt else \
                        ("This long reply keeps streaming so the phone can stop it " * 12).split(" ")
                    delay = 0.35 if "AGENTLAND_STREAM" in prompt else 0.5
                    self.chunk({"role": "assistant", "content": ""})
                    for index, word in enumerate(words):
                        self.chunk({"content": word if index == 0 else " " + word})
                        time.sleep(delay)
                    self.chunk({}, "stop")
                else:
                    self.chunk({"role": "assistant", "content": answer})
                    self.chunk({}, "stop")
                self.wfile.write(b"data: [DONE]\n\n")
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                # OpenCode closes the connection when the phone stops the reply.
                pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server, requests


class Forwarder:
    """A TCP forwarder from 127.0.0.1 to the host's port: the address the phone pairs at in
    testConnectsThroughAlternateRoute. `cut` closes it and every connection through it, as when the
    phone leaves the network that address belongs to; the host itself keeps running."""

    def __init__(self, target_port):
        self.target_port = target_port
        self.listener = socket.socket()
        self.listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.listener.bind(("127.0.0.1", 0))
        self.listener.listen(64)
        self.port = self.listener.getsockname()[1]
        self.lock = threading.Lock()
        self.sockets = set()
        self.closed = False
        threading.Thread(target=self.accept, daemon=True).start()

    def accept(self):
        while True:
            try:
                client, _ = self.listener.accept()
            except OSError:
                return
            try:
                upstream = socket.create_connection(("127.0.0.1", self.target_port), timeout=5)
                upstream.settimeout(None)
            except OSError:
                client.close()
                continue
            with self.lock:
                if self.closed:
                    client.close()
                    upstream.close()
                    return
                self.sockets.update((client, upstream))
            for source, target in ((client, upstream), (upstream, client)):
                threading.Thread(target=self.pump, args=(source, target), daemon=True).start()

    def pump(self, source, target):
        try:
            while data := source.recv(65536):
                target.sendall(data)
        except OSError:
            pass
        finally:
            for item in (source, target):
                try:
                    item.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass

    def cut(self):
        with self.lock:
            self.closed = True
            open_sockets, self.sockets = self.sockets, set()
        self.listener.close()
        for item in open_sockets:
            try:
                item.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            item.close()


def fake_tailscale(folder):
    """A Tailscale command line for the disposable host (serve --tailscale-cli): it answers only
    `status --json --peers=false`, with a running Tailscale whose name does not resolve and whose address is the
    loopback one the host listens on. The owner's Tailscale is never read."""
    path = folder / "tailscale"
    status = json.dumps({"BackendState": "Running",
                         "Self": {"DNSName": "agentland-tailnet.invalid.", "TailscaleIPs": ["127.0.0.1"]}})
    path.write_text("#!/bin/sh\n"
                    "[ \"$*\" = \"status --json --peers=false\" ] || exit 2\n"
                    f"printf '%s\\n' '{status}'\n")
    path.chmod(0o700)
    return path


# testConnectsThroughIrohTunnel: everything that binds an iroh endpoint runs under this profile, which
# refuses UDP to the router's port-mapping ports (SSDP 1900, NAT-PMP/PCP 5350 and 5351).
ROUTER_PORTS_PROFILE = ROOT / "shared/AgentLandIroh/Tests/router-ports-denied.sb"
# The address the Mac side reports for its endpoint. A report carries only global unicast addresses, and
# loopback is not one, so the router stand-in answers with this address from a deprecated range (the
# 6to4 relay anycast, RFC 7526). Nothing is ever sent to it: the app dials the loopback port in its place
# and drops every other address (RemoteAccessLoopbackDial).
TUNNEL_REPORTED_ADDRESS = "192.88.99.1"
TUNNEL_PROOF = "through-iroh-tunnel"


def compile_router_ports_profile(destination):
    """The profile's bytecode, compiled with the Mac's libsandbox: the simulator has no compiler, and a
    simulator process applies it with `sandbox_apply_bytecode` (integration/RouterPortsSandbox)."""
    import ctypes

    class Profile(ctypes.Structure):
        _fields_ = [("type", ctypes.c_uint32), ("data", ctypes.c_void_p), ("size", ctypes.c_size_t)]

    library = ctypes.CDLL("/usr/lib/libsandbox.1.dylib")
    library.sandbox_compile_file.restype = ctypes.POINTER(Profile)
    library.sandbox_compile_file.argtypes = [ctypes.c_char_p, ctypes.c_void_p, ctypes.POINTER(ctypes.c_char_p)]
    library.sandbox_free_profile.argtypes = [ctypes.POINTER(Profile)]
    error = ctypes.c_char_p()
    profile = library.sandbox_compile_file(str(ROUTER_PORTS_PROFILE).encode(), None, ctypes.byref(error))
    if not profile:
        raise RuntimeError(f"The router-ports profile did not compile: {error.value!r}")
    try:
        destination.write_bytes(ctypes.string_at(profile.contents.data, profile.contents.size))
    finally:
        library.sandbox_free_profile(profile)


def build_router_ports_dylib(destination):
    """integration/RouterPortsSandbox as a simulator dylib, signed ad hoc like the simulator app."""
    run(["xcrun", "--sdk", "iphonesimulator", "clang", "-target", "arm64-apple-ios26.0-simulator", "-dynamiclib",
         "-o", str(destination), str(ROOT / "integration/RouterPortsSandbox/router-ports-sandbox.c")], timeout=120)
    run(["codesign", "--force", "--sign", "-", str(destination)], timeout=60)


def build_remote_access_loopback():
    """The Mac side of remote access as a command line (macos/Tools/RemoteAccessLoopback)."""
    package = ROOT / "macos"
    run(["swift", "build", "--package-path", str(package), "--product", "agentland-remote-access-loopback"], timeout=1800)
    return Path(run(["swift", "build", "--package-path", str(package), "--show-bin-path"], timeout=120)) / "agentland-remote-access-loopback"


def free_udp_port():
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


class MacSide:
    """agentland-remote-access-loopback under the router-ports profile: the Mac endpoint on a free UDP port
    of this Mac, its gate on the host's peer list, the bridge to the host's tunnel socket and the mapping to
    a router stand-in on 127.0.0.1, with "Reach this Mac from anywhere" on. It prints one JSON object a
    line; the latest of each kind is kept."""

    def __init__(self, binary, *, host_port, fingerprint, tunnel_socket, token, folder, log):
        self.udp_port = free_udp_port()
        self.lock = threading.Lock()
        self.latest = {}
        env = {key: os.environ[key] for key in ("HOME", "USER", "LANG", "PATH") if key in os.environ}
        env["AGENTLAND_LOCAL_SESSION_TOKEN"] = token
        self.log = log
        self.process = subprocess.Popen(
            ["sandbox-exec", "-f", str(ROUTER_PORTS_PROFILE), str(binary), "--host-port", str(host_port),
             "--fingerprint", fingerprint, "--certificate-name", "localhost", "--tunnel-socket", str(tunnel_socket),
             "--udp-port", str(self.udp_port), "--external-address", TUNNEL_REPORTED_ADDRESS,
             "--state-directory", str(folder)],
            env=env, stdout=subprocess.PIPE, stderr=log, text=True, start_new_session=True)
        self.reader = threading.Thread(target=self.read, daemon=True)
        self.reader.start()

    def read(self):
        for line in self.process.stdout:
            self.log.write(line)
            self.log.flush()
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            with self.lock:
                self.latest[event.get("event")] = event

    def event(self, kind):
        with self.lock:
            return self.latest.get(kind)

    def wait(self, what, condition, timeout):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                raise RuntimeError(f"The Mac side exited ({self.process.returncode}) waiting for {what}")
            if condition():
                return
            time.sleep(0.1)
        raise RuntimeError(f"The Mac side did not reach {what} within {timeout}s: {self.event('status')}")

    @property
    def reported_address(self):
        return f"{TUNNEL_REPORTED_ADDRESS}:{self.udp_port}"

    def wait_reported(self):
        def reported():
            status = self.event("status") or {}
            report = status.get("reported") or {}
            return status.get("endpoint") == "running" and report.get("enabled") is True \
                and report.get("directAddresses") == [self.reported_address]
        self.wait("its report with the endpoint's address", reported, 60)

    def peers(self):
        event = self.event("peers") or {}
        return list(zip(event.get("deviceIds", []), event.get("nodeIds", [])))

    def stop(self):
        """Quit: SIGTERM, then the mapping must be gone."""
        if self.process.poll() is None:
            os.killpg(self.process.pid, signal.SIGTERM)
            try:
                self.process.wait(timeout=20)
            except subprocess.TimeoutExpired:
                os.killpg(self.process.pid, signal.SIGKILL)
                self.process.wait(timeout=5)
        self.reader.join(timeout=5)
        if not self.log.closed:
            self.log.close()
        stopped = self.event("stopped")
        return stopped is not None and stopped.get("mappingsLeft") == 0


# testTerminalFromTheMacShowsOnThePhone's `claude`: it says it is ready, then answers every line it reads with
# got:<line>, without echoing what is typed (so got:<line> is only ever its answer).
FAKE_CLAUDE = r"""#!/bin/sh
stty -echo
printf 'mac-agent-ready\n'
while IFS= read -r l; do printf 'got:%s\n' "$l"; done
"""


def set_routing(state, on):
    """The routing switch the zsh hook reads ("Open coding agents from Terminal in AgentLand"): the file `routing`
    in `shell/` beside the host's state, reading "on". While it does and terminal access is on, the host keeps a keeper
    running (it looks every 5 s). Written directly, never with `terminals hook on`, which edits a .zshrc."""
    folder = Path(state).parent / "shell"
    switch = folder / "routing"
    if on:
        folder.mkdir(mode=0o700, exist_ok=True)
        os.chmod(folder, 0o700)
        descriptor = os.open(switch, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(descriptor, "w") as handle:
            handle.write("on\n")
        os.chmod(switch, 0o600)
    else:
        switch.unlink(missing_ok=True)
        with contextlib.suppress(OSError):
            folder.rmdir()


class RoutedTerminal:
    """A Terminal.app window on the Mac in which the owner typed `claude`, with routing on: the zsh hook's
    `agentland-host terminals run --state <state> -- claude` runs in a PTY of the harness's own (pty.fork, so it has
    a controlling terminal and a size, as a window does), in a fresh folder under /private/tmp that is no workspace,
    with the fake `claude` (FAKE_CLAUDE) first on PATH. A reader thread keeps everything the window shows, so the
    CLI never blocks on a full PTY. `hang_up` ends it, whatever state it is in; call it in `finally`."""

    ROWS, COLUMNS = 24, 80

    def __init__(self):
        self.pid = None
        self.master = None
        self.folder = None
        self.status = None
        self.reader = None
        self.output = bytearray()
        self.changed = threading.Condition()
        self.stopping = threading.Event()

    def start(self, binary, state):
        self.folder = Path(tempfile.mkdtemp(prefix="agentland-routed-", dir="/private/tmp"))
        fake_bin = self.folder / "bin"
        fake_bin.mkdir()
        claude = fake_bin / "claude"
        claude.write_text(FAKE_CLAUDE)
        claude.chmod(0o755)
        home = self.folder / "home"
        home.mkdir(mode=0o700)
        project = self.folder / "mac-project"
        project.mkdir()
        # Built, never inherited: the harness may itself run in an AgentLand terminal, and a command started where
        # AGENTLAND_TERMINAL is set is never routed again.
        env = {"PATH": f"{fake_bin}:/usr/bin:/bin", "HOME": str(home), "TERM": "xterm-256color", "LANG": "en_US.UTF-8"}
        argv = [str(binary), "terminals", "run", "--state", str(state), "--", "claude"]
        size = struct.pack("HHHH", self.ROWS, self.COLUMNS, 0, 0)
        directory = str(project)
        pid, master = pty.fork()
        if pid == 0:
            # The child does only this before it becomes the CLI: the window's size, its folder, the CLI.
            try:
                with contextlib.suppress(OSError):
                    fcntl.ioctl(0, termios.TIOCSWINSZ, size)
                os.chdir(directory)
                os.execve(argv[0], argv, env)
            except BaseException as error:
                with contextlib.suppress(OSError):
                    os.write(2, f"routed window child failed: {error!r}\n".encode())
            finally:
                os._exit(127)
        self.pid, self.master = pid, master
        self.reader = threading.Thread(target=self.read, daemon=True)
        self.reader.start()

    def read(self):
        while not self.stopping.is_set():
            try:
                ready, _, _ = select.select([self.master], [], [], 0.2)
                data = os.read(self.master, 65536) if ready else None
            except (OSError, ValueError):  # EIO once the CLI, the window's last process, is gone
                return
            if data is None:
                continue
            if not data:
                return
            with self.changed:
                self.output += data
                self.changed.notify_all()

    def type(self, text):
        """Types `text` into the window, as keys: a Return is "\\r"."""
        data = text.encode()
        while data:
            data = data[os.write(self.master, data):]

    def wait_for(self, text, timeout=20):
        """Whether the window shows `text` within `timeout` seconds (all it showed counts, not only what comes)."""
        wanted = text.encode()
        deadline = time.monotonic() + timeout
        with self.changed:
            while wanted not in self.output:
                left = deadline - time.monotonic()
                if left <= 0:
                    return False
                self.changed.wait(left)
            return True

    def tail(self, length=600):
        with self.changed:
            return bytes(self.output[-length:]).decode("utf-8", "replace")

    def exited(self, timeout):
        """Whether the CLI exited (reaped) within `timeout` seconds."""
        deadline = time.monotonic() + timeout
        while self.status is None:
            try:
                pid, status = os.waitpid(self.pid, os.WNOHANG)
            except ChildProcessError:
                pid, status = self.pid, -1
            if pid:
                self.status = status
                break
            if time.monotonic() > deadline:
                return False
            time.sleep(0.1)
        return True

    def hang_up(self, timeout=15):
        """The window closes: SIGHUP to the CLI, as Terminal sends, and True once it exited of it within `timeout`.
        A CLI that did not is killed (the agent it adopted then stays with the keeper until `terminals stop`). Then the
        reader stops, the window's PTY closes and the folder goes. Safe to call again, and before `start`."""
        exited = True
        if self.pid is not None and self.status is None:
            with contextlib.suppress(ProcessLookupError):
                os.kill(self.pid, signal.SIGHUP)
            exited = self.exited(timeout)
            if not exited:
                with contextlib.suppress(ProcessLookupError):
                    os.kill(self.pid, signal.SIGKILL)
                self.exited(5)
        self.stopping.set()
        if self.reader is not None:
            self.reader.join(timeout=5)
        if self.master is not None:
            with contextlib.suppress(OSError):
                os.close(self.master)
            self.master = None
        if self.folder is not None:
            shutil.rmtree(self.folder, ignore_errors=True)
            self.folder = None
        return exited


def routed_start(window, binary, state, address, cafile, token):
    """testTerminalFromTheMacShowsOnThePhone's `routed-start`: routing on, a keeper the host keeps for it (as the Mac
    app's switch has it, since `terminals run` only dials one within its 1 s budget), then `claude` typed in the
    window. "ok" once the window shows mac-agent-ready and the Mac's own list (GET /v1/terminals/all with the local
    session `token`) has the routed terminal running; otherwise what it found."""
    # The whole call stays well under the Swift side's 60 s wait: 15 + 20 + 10 s, each request bounded by what is left.
    socket_path = Path(state).parent / "terminals-local.sock"
    if len(str(socket_path).encode()) > 103:
        return f"TMPDIR is too long: the host's local socket {socket_path} is {len(str(socket_path).encode())} bytes, over the 103 allowed"
    set_routing(state, True)
    limit = time.monotonic() + 45

    def mac_list():
        return host_json(address + "/v1/terminals/all", cafile, token, timeout=max(1.0, min(10.0, limit - time.monotonic())))

    deadline = time.monotonic() + 15
    while True:
        try:
            keeper = mac_list().get("keeper")
        except (OSError, urllib.error.URLError, json.JSONDecodeError) as error:
            keeper = repr(error)
        if isinstance(keeper, dict) and keeper.get("state") == "running":
            break
        if time.monotonic() > deadline:
            return f"the host kept no keeper for routing within 15 s: {keeper}"
        time.sleep(0.25)
    window.start(binary, state)
    if not window.wait_for("mac-agent-ready", max(1.0, min(20.0, limit - time.monotonic()))):
        return f"mac-agent-ready never showed in the window: {window.tail()!r}"
    deadline = min(time.monotonic() + 10, limit)
    while True:
        try:
            terminals = mac_list().get("terminals") or []
        except (OSError, urllib.error.URLError, json.JSONDecodeError) as error:
            terminals = [repr(error)]
        if any(isinstance(item, dict) and item.get("routed") and item.get("status") == "running" for item in terminals):
            return "ok"
        if time.monotonic() > deadline:
            return f"not routed: {terminals}; the window shows {window.tail()!r}"
        time.sleep(0.25)


def start_host_control(current, start, actions=None, payload_actions=None):
    """Let a UI test stop, restart, freeze or resume the disposable host.

    The simulator's test runner writes `<command>.request` into this folder and
    waits for `<command>.done`. Freezing (SIGSTOP) models a Mac that went to
    sleep or off the network: connections stay open but nothing answers.
    `actions` adds commands of a test's own (`cut` for the alternate route); what
    one returns ("ok", or what it found wrong) is written into `<command>.done`
    for the test to check. `payload_actions` take the request file's text (JSON
    from the exploratory interpreter's host steps) as their one argument.
    """
    folder = Path(tempfile.mkdtemp(prefix="agentland-control-", dir="/private/tmp"))
    stop = threading.Event()
    state = {"host": current()}
    actions = actions or {}
    payload_actions = payload_actions or {}

    def act(command, payload):
        process = state["host"]
        if command in payload_actions:
            try:
                return payload_actions[command](payload)
            except Exception as error:  # the test reads it from the .done file and fails with it
                return f"{command} failed: {error}"
        if command in actions:
            try:
                return actions[command]()
            except Exception as error:  # the test reads it from the .done file and fails with it
                return f"{command} failed: {error}"
        elif command == "stop":
            stop_process(process)
        elif command == "kill":
            # SIGKILL of the host's group; the keeper runs in its own session and is not in it.
            try:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(5)
            except (ProcessLookupError, subprocess.TimeoutExpired) as error:
                return f"kill failed: {error!r}"
            return "ok"
        elif command == "start":
            state["host"] = start()
        elif command == "pause":
            os.killpg(process.pid, signal.SIGSTOP)
        elif command == "resume":
            os.killpg(process.pid, signal.SIGCONT)
        else:
            # Answered, never raised: a raise would end this watcher and leave the test waiting.
            return f"Unknown host control command {command}"

    def watch():
        while not stop.is_set():
            for request in sorted(folder.glob("*.request")):
                command = request.stem
                try:
                    # Exactly as written: a payload's "\r" (a Return typed into a window) stays one.
                    payload = request.read_bytes().decode("utf-8", "replace")
                except OSError:
                    payload = ""
                request.unlink()
                answer = act(command, payload)
                # Whole or not at all: the test reads the answer as soon as the file exists.
                written = folder / f".{command}.answer"
                written.write_text(answer if isinstance(answer, str) else "")
                written.rename(folder / f"{command}.done")
            time.sleep(0.05)

    threading.Thread(target=watch, daemon=True).start()
    return folder, stop, state


# Tests that visit every screen several times need longer than the default limit; a short one may have less.
LONG_TESTS = {"testTerminalSurvivesHostKill": 600, "testAccessibilityAudits": 1200, "testHIGScreenshots": 1200, "testShellScreenshots": 900,
              "testFilesAndGitScreenshots": 900, "testWorkspaceScreenshots": 900,
              "testSettingsScreenshots": 1500, "testSettingsAccessibilityAudit": 1800,
              "testTerminalFromTheMacShowsOnThePhone": 300}


# The tester's sessions (ios/AgentLandUITests/ExploratoryUITests.swift, integration/scripts/*.json).
# What a script's "prepare" list may ask the harness to set up before it runs: the file operations
# folder, the Git fixture repository (with a loopback HTTP remote for "git-remote"), the twelve
# configured workspaces of Home's boxes, and a photo in the simulator's library.
SCRIPT_PREPARATIONS = {"ops", "git", "git-remote", "menu-workspaces", "photo"}
# Tests that get the eleven extra `Workspace N` projects (a script asks with `menu-workspaces`).
MENU_WORKSPACE_TESTS = {"testPhoneActionBoxes"}
EXPLORATORY_LIMIT = 1200


class GitHTTPRemote:
    """Bare repositories under `root` served by `git http-backend` on 127.0.0.1, so the phone's fetch, pull
    and push (which the host allows only over network protocols) reach a remote that never leaves this Mac."""

    def __init__(self, root):
        backend = Path(run(["git", "--exec-path"])) / "git-http-backend"
        environment = {key: os.environ[key] for key in ("PATH", "HOME", "LANG") if key in os.environ}

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_args):
                pass

            def body(self):
                if self.headers.get("Transfer-Encoding", "").lower() == "chunked":
                    data = b""
                    while True:
                        size = int(self.rfile.readline().strip().split(b";")[0], 16)
                        if size == 0:
                            self.rfile.readline()
                            return data
                        data += self.rfile.read(size)
                        self.rfile.readline()
                length = int(self.headers.get("Content-Length") or 0)
                return self.rfile.read(length) if length else b""

            def serve(self):
                path, _, query = self.path.partition("?")
                body = self.body()
                env = dict(environment, GIT_PROJECT_ROOT=str(root), GIT_HTTP_EXPORT_ALL="1", PATH_INFO=path,
                           QUERY_STRING=query, REQUEST_METHOD=self.command, REMOTE_ADDR="127.0.0.1",
                           CONTENT_TYPE=self.headers.get("Content-Type", ""), CONTENT_LENGTH=str(len(body)),
                           GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL="/dev/null")
                if self.headers.get("Content-Encoding"):
                    env["HTTP_CONTENT_ENCODING"] = self.headers["Content-Encoding"]
                if self.headers.get("Git-Protocol"):
                    env["GIT_PROTOCOL"] = self.headers["Git-Protocol"]
                result = subprocess.run([str(backend)], input=body, env=env, capture_output=True, timeout=120)
                separator = b"\r\n\r\n" if b"\r\n\r\n" in result.stdout else b"\n\n"
                head, _, payload = result.stdout.partition(separator)
                status = 200
                headers = []
                for line in head.decode("latin-1").splitlines():
                    name, _, value = line.partition(":")
                    if name.lower() == "status":
                        status = int(value.strip().split()[0])
                    elif name:
                        headers.append((name, value.strip()))
                self.send_response(status)
                for name, value in headers:
                    self.send_header(name, value)
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

            do_GET = serve
            do_POST = serve

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.port = self.server.server_port
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def url(self, name):
        return f"http://127.0.0.1:{self.port}/{name}"

    def stop(self):
        self.server.shutdown()
        self.server.server_close()


def prepare_git_remote(project, temp):
    """The Git fixture repository with an `origin` on a loopback HTTP remote: main is pushed and tracked, and
    the remote has one more commit (made from another clone) for the phone to fetch and pull. Returns the
    repository and the remote's server."""
    repository = prepare_git_repository(project)
    root = temp / "git-remotes"
    shutil.rmtree(root, ignore_errors=True)
    root.mkdir()
    bare = root / "git-fixture.git"
    run(["git", "init", "-q", "--bare", "-b", "main", str(bare)], timeout=30)
    git(bare, "config", "http.receivepack", "true")
    server = GitHTTPRemote(root)
    git(repository, "remote", "add", "origin", server.url("git-fixture.git"))
    git(repository, "push", "-q", "-u", "origin", "main")
    other = temp / "git-other-clone"
    shutil.rmtree(other, ignore_errors=True)
    env = {key: os.environ[key] for key in ("PATH", "HOME", "LANG") if key in os.environ}
    env.update(GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1", GIT_TERMINAL_PROMPT="0")
    run(["git", "clone", "-q", server.url("git-fixture.git"), str(other)], env=env, timeout=60)
    for key, value in (("user.name", GIT_NAME), ("user.email", GIT_EMAIL), ("commit.gpgsign", "false")):
        git(other, "config", key, value)
    (other / "remote-note.txt").write_text("Pushed to the remote from another clone.\n")
    git(other, "add", "remote-note.txt")
    git(other, "commit", "-q", "--no-verify", "-m", "Remote commit to pull")
    git(other, "push", "-q", "origin", "main")
    shutil.rmtree(other, ignore_errors=True)
    return repository, server


class PreviewPage:
    """A loopback web page for the Browser to open through the host's preview listener."""

    def __init__(self, marker):
        page = (f"<!doctype html><meta name=viewport content='width=device-width'><title>Preview fixture</title>"
                f"<h1>AgentLand preview fixture</h1><p id=marker>{marker}</p><a href='/second'>Second page</a>").encode()
        second = b"<!doctype html><title>Second page</title><h1>Second preview page</h1>"

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_args):
                pass

            def do_GET(self):
                body = second if self.path.startswith("/second") else page
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.port = self.server.server_port
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def stop(self):
        self.server.shutdown()
        self.server.server_close()


def fixture_photo(path, marker):
    """A small PNG for the simulator's photo library (`simctl addmedia`): a test pattern, no location."""
    import struct
    import zlib
    width = height = 96
    rows = b"".join(b"\x00" + bytes(channel for x in range(width)
                                    for channel in (x * 2 % 256, y * 2 % 256, (x + y + len(marker)) % 256))
                    for y in range(height))

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
                     + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))
    return path


def exploratory_actions(device, roots, binary, state, current_host):
    """The host steps of the exploratory interpreter, each taking the request's JSON payload and answering "ok"
    or what it found. Paths are `project:<relative>` or `home:<relative>` (the host's workspace home) and
    never leave those folders."""

    def resolve(value):
        root_name, _, relative = value.partition(":")
        if root_name not in roots or not relative or relative.startswith("/"):
            raise ValueError(f"{value!r} is not project:<path> or home:<path>")
        root = roots[root_name].resolve()
        target = (root / relative).resolve()
        if target != root and not target.is_relative_to(root):
            raise ValueError(f"{value!r} leaves its folder")
        return target

    def until(timeout, check):
        deadline = time.monotonic() + min(float(timeout or 0), 60)
        while True:
            problem = check()
            if problem is None or time.monotonic() >= deadline:
                return problem or "ok"
            time.sleep(0.25)

    def host_file(payload):
        request = json.loads(payload)
        path = resolve(request["path"])

        def check():
            if request.get("absent"):
                return None if not path.exists() else f"{request['path']} exists"
            if request.get("dir"):
                return None if path.is_dir() else f"{request['path']} is not a folder"
            if not path.is_file():
                return f"{request['path']} is missing"
            text = path.read_text(errors="replace")
            if "equals" in request and text != request["equals"]:
                return f"{request['path']} holds {text[:200]!r}, not {request['equals'][:200]!r}"
            if "contains" in request and request["contains"] not in text:
                return f"{request['path']} does not contain {request['contains']!r}: {text[:200]!r}"
            if "lacks" in request and request["lacks"] in text:
                return f"{request['path']} still contains {request['lacks']!r}"
            return None
        return until(request.get("timeout"), check)

    def host_write(payload):
        request = json.loads(payload)
        path = resolve(request["path"])
        if request.get("delete"):
            path.unlink(missing_ok=True)
        elif request.get("append"):
            with path.open("a") as stream:
                stream.write(request["append"])
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(request.get("content", ""))
        return "ok"

    def host_git(payload):
        request = json.loads(payload)
        repository = resolve(request["repo"])
        allowed = {"log", "status", "branch", "stash", "show", "rev-parse", "diff", "remote", "ls-remote"}
        if not request.get("args") or request["args"][0] not in allowed:
            return f"git {request.get('args')} is not a read the harness runs"

        def check():
            try:
                output = git(repository, *request["args"])
            except RuntimeError as error:
                return str(error)
            if "contains" in request and request["contains"] not in output:
                return f"git {' '.join(request['args'])} gave {output[:300]!r}, without {request['contains']!r}"
            if "lacks" in request and request["lacks"] in output:
                return f"git {' '.join(request['args'])} still shows {request['lacks']!r}"
            if "equals" in request and output != request["equals"]:
                return f"git {' '.join(request['args'])} gave {output[:300]!r}, not {request['equals']!r}"
            return None
        return until(request.get("timeout"), check)

    def host_projects(payload):
        request = json.loads(payload)

        def check():
            projects = configured_projects(binary, state)
            names = {project.get("name") for project in projects} | {Path(project.get("directory") or "").name for project in projects}
            if "contains" in request and request["contains"] not in names:
                return f"the host does not list {request['contains']!r}: {sorted(n for n in names if n)}"
            if "absent" in request and request["absent"] in names:
                return f"the host still lists {request['absent']!r}"
            return None
        return until(request.get("timeout"), check)

    def host_pid(payload):
        request = json.loads(payload)
        path = resolve(request["pidfile"])

        def check():
            if not path.is_file():
                return f"{request['pidfile']} is missing"
            pid = int(path.read_text().strip() or "0")
            try:
                os.kill(pid, 0)
                alive = True
            except ProcessLookupError:
                alive = False
            except PermissionError:
                alive = True
            if alive != bool(request.get("alive", True)):
                return f"process {pid} is {'alive' if alive else 'gone'}"
            return None
        return until(request.get("timeout"), check)

    def sim_ui(payload):
        request = json.loads(payload)
        if "appearance" in request:
            run(["xcrun", "simctl", "ui", device, "appearance", request["appearance"]], timeout=20)
        if "contentSize" in request:
            run(["xcrun", "simctl", "ui", device, "content_size", request["contentSize"]], timeout=20)
        return "ok"

    def add_media(payload):
        request = json.loads(payload) if payload.strip() else {}
        folder = Path(tempfile.mkdtemp(prefix="agentland-media-", dir="/private/tmp"))
        try:
            photo = fixture_photo(folder / f"{request.get('name', 'fixture-photo')}.png", request.get("name", "photo"))
            run(["xcrun", "simctl", "addmedia", device, str(photo)], timeout=60)
        finally:
            shutil.rmtree(folder, ignore_errors=True)
        return "ok"

    def host_alive(payload):
        request = json.loads(payload) if payload.strip() else {}
        process = current_host()
        running = process is not None and process.poll() is None
        return "ok" if running == bool(request.get("running", True)) else f"the host is {'running' if running else 'stopped'}"

    def pair_code(payload):
        # A pairing PIN of its own ("ok:<code>"), with a lifetime the script names: "2s" makes one that has
        # expired by the time it is typed.
        request = json.loads(payload) if payload.strip() else {}
        code = run([str(binary), "pair", "--pin", "--state", str(state), "--expires", request.get("expires", "10m")])
        return "ok:" + code

    return {"hostfile": host_file, "hostwrite": host_write, "hostgit": host_git, "hostprojects": host_projects,
            "hostpid": host_pid, "simui": sim_ui, "addmedia": add_media, "hostalive": host_alive, "paircode": pair_code}


def build_ui_tests(device, derived, log):
    """Builds the app and its UI tests once per run (build-for-testing) and returns the .xctestrun file.

    Each test then runs from this build with `test-without-building`, reading its fixture from the file
    the harness names (`TEST_RUNNER_AGENTLAND_FIXTURE`), so sources edited while a run goes on never
    change it, and no test waits for a build check."""
    command = ["xcodebuild", "-project", str(ROOT / "ios/AgentLand.xcodeproj"),
               "-scheme", "AgentLand", "-destination", f"platform=iOS Simulator,id={device}",
               "-derivedDataPath", str(derived), "-parallel-testing-enabled", "NO",
               "CODE_SIGNING_ALLOWED=YES", "CODE_SIGN_IDENTITY=-", "ARCHS=arm64", "build-for-testing"]
    with log.open("w") as output:
        process = subprocess.Popen(command, stdout=output, stderr=output, start_new_session=True)
        try:
            code = process.wait(timeout=2400)
        except subprocess.TimeoutExpired:
            stop_process(process)
            raise RuntimeError(f"build-for-testing timed out; inspect {log}")
    if code:
        raise RuntimeError(f"build-for-testing failed; inspect {log}")
    runs = sorted((derived / "Build/Products").glob("*iphonesimulator*.xctestrun"), key=lambda path: path.stat().st_mtime)
    if not runs:
        raise RuntimeError(f"build-for-testing wrote no .xctestrun into {derived / 'Build/Products'}")
    return runs[-1]


def name_attachments(folder):
    """xcresulttool exports attachments under UUIDs; give each its test's name (keeping the extension), in order,
    so a folder of screenshots reads as the test took them."""
    manifest = folder / "manifest.json"
    if not manifest.is_file():
        return
    entries = [item for test in json.loads(manifest.read_text()) for item in test.get("attachments", [])]
    entries.sort(key=lambda item: item.get("timestamp", 0))
    for index, item in enumerate(entries):
        source = folder / item["exportedFileName"]
        suggested = item.get("suggestedHumanReadableName", "")
        # XCTest's own records (event plists, UI snapshots, query descriptions) keep their UUID names.
        if not source.is_file() or suggested.startswith(("Synthesized Event", "UI Snapshot", "Debug description")):
            continue
        # "<name>_0_<UUID>.png" → "<name>.png"
        suggested = re.sub(r"_\d+_[0-9A-F]{8}-[0-9A-F-]{27}", "", suggested)
        name = re.sub(r"[^A-Za-z0-9._ -]+", "-", suggested or source.name).strip()
        if not Path(name).suffix and source.suffix:
            name += source.suffix
        source.rename(folder / f"{index:03d}-{name}")


def run_ui_test(device, test_name, result, log, xctestrun, fixture, limit=None):
    """Runs one FullWorkspaceUITests method from the run's build with `fixture` (a JSON file) as its fixture."""
    limit = limit or LONG_TESTS.get(test_name, 450)
    command = ["xcodebuild", "test-without-building", "-xctestrun", str(xctestrun),
               "-destination", f"platform=iOS Simulator,id={device}", "-resultBundlePath", str(result),
               "-parallel-testing-enabled", "NO", "-only-testing:AgentLandUITests/FullWorkspaceUITests/" + test_name]
    if test_name == "testPhoneBottomTabs":
        command += ["-only-testing:AgentLandTests/TerminalRendererTests/testPhoneChromeFollowsOnlyTheSelectedPaintedTerminal", "-only-testing:AgentLandTests/TerminalRendererTests/testRebuiltTerminalViewKeepsItsSessionAndRenderer"]
    env = os.environ.copy()
    # xcodebuild hands TEST_RUNNER_-prefixed variables to the test runner without the prefix.
    env["TEST_RUNNER_AGENTLAND_FIXTURE"] = str(fixture)
    with log.open("w") as output:
        process = subprocess.Popen(command, stdout=output, stderr=output, env=env, start_new_session=True)
        try:
            code = process.wait(timeout=limit)
        except subprocess.TimeoutExpired:
            stop_process(process)
            raise RuntimeError(f"{test_name} timed out after {limit}s; inspect {log}")
        finally:
            stop_process(process)
    attachments = result.parent / (result.stem + "-screenshots")
    if result.exists():
        # Kept for failures too: the screenshots up to the failure are the evidence.
        subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(result),
                        "--output-path", str(attachments)], capture_output=True, timeout=60)
        name_attachments(attachments)
    if "Executed 0 tests" in log.read_text(errors="replace"):
        raise RuntimeError(f"{test_name} is not a FullWorkspaceUITests method in the build; regenerate the project from ios/agentland.yml")
    if code:
        raise RuntimeError(f"{test_name} failed; inspect {log} and {attachments}")
    # A test that skips itself on this device (the iPad-only ones on an iPhone) attaches nothing.
    if re.search(r"Test Case .* skipped", log.read_text(errors="replace")):
        print(f"SKIPPED {test_name} on this device", flush=True)
        return
    if not list(attachments.glob("*.png")):
        raise RuntimeError(f"{test_name} produced no retained screenshots in {attachments}")


def enroll_face_id(device):
    """Chat's cold-relaunch regression uses the simulator's real LAContext. Other fixture runs (and an erase)
    may leave its Face ID enrollment notification at 0, which makes iOS present passcode entry instead of
    accepting Matching Face."""
    run(["xcrun", "simctl", "spawn", device, "notifyutil", "-s",
         "com.apple.BiometricKit.enrollmentChanged", "1", "-p",
         "com.apple.BiometricKit.enrollmentChanged"], timeout=30)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("simulator", help="Already booted disposable iPhone simulator UDID (never a protected one, "
                                          "see integration/simulator_guard.py)")
    parser.add_argument("--tests", help="Comma-separated FullWorkspaceUITests methods for a bounded retry")
    parser.add_argument("--script", action="append", default=[], metavar="FILE",
                        help="Run an exploratory tester script (integration/scripts/*.json) with testExploratoryScript; "
                             "repeatable. Without --tests only the scripts, walks and matrix rows given run")
    parser.add_argument("--seed", action="append", type=int, default=[],
                        help="Run testRandomWalk with this seed; repeatable. A failing seed replays the same walk")
    parser.add_argument("--walk-steps", type=int, default=60, help="Steps in each random walk")
    parser.add_argument("--matrix", action="append", default=[], metavar="SURFACE:INTERRUPTION[,...]",
                        help="Run testInterruptionMatrix for one surface and the interruptions named (or 'all'); repeatable")
    parser.add_argument("--erase", action="store_true",
                        help="Erase the (allow-listed, disposable) simulator before every test, so each starts as a true "
                             "first install: no Keychain items, privacy grants or app data")
    parser.add_argument("--enable-preview", action="store_true",
                        help="Serve web previews (Browser) from the host, with a loopback page for them to open")
    parser.add_argument("--keep-going", action="store_true",
                        help="Run every selected test, script, walk and matrix row even after one fails; report them all at the end")
    parser.add_argument("--opencode-debug", action="store_true",
                        help="Run OpenCode with its DEBUG log printed into the run's <stamp>-opencode.log (as for B-15's Stop-then-send race)")
    options = parser.parse_args()
    (options.simulator,) = simulator_guard.refuse_protected(options.simulator)
    default_tests = ("testPhoneBottomTabs", "testVisualSurfaces", "testFileFlow", "testFileOperations", "testGitStageAndCommit", "testChatFlow", "testChatFeaturesFlow", "testChatStreamingFlow", "testChatLibrary", "testAgentChatLanding", "testSidebarNavigation", "testWorkspaceManagement", "testVoiceOverReachesOnlyTheSelectedSurface", "testTerminalFlow", "testTerminalWheelScroll", "testNamedOpenCodeFlow", "testHostDisconnectFlow", "testTerminalSurvivesHostKill", "testTerminalFromTheMacShowsOnThePhone", "testConnectsThroughAlternateRoute", "testConnectsThroughIrohTunnel", "testAccessibilityAudits", "testPlainChatFlow", "testDarkAppearance", "testHomeCapsulesAndQuip", "testNativeBarButtons", "testDrawerSearchAndSettings", "testPhoneWorkspaceRecoveryAndRefusal")
    # Opt-in: the iPad launcher and keyboard commands need an iPad simulator; the title entrances run with
    # production motion for a screen recording; the landscape Home turns an iPhone; the HIG, shell and
    # workspace screenshots are review evidence; the launch timing measures cold launches; the agents'
    # Settings panes need a host that lists agents (without one the test checks the gating and skips). Home's
    # capsules and quip, the bar's outlines and the iPad's search and Settings drawer are HomeAndDrawerUITests.swift
    # (the bar's and the Settings drawer's are iPad-only and skip on iPhone); a chat across Text Size changes is
    # TextSizeUITests.swift; testPlainChatFlow (a reply, memory saved, undone and forgotten through the fixture model)
    # is PlainChatUITests.swift.
    # The text-size test runs only by name (owner, 2026-10-07: text size tests "don't matter right now").
    available = default_tests + ("testChatKeepsItsRowsAcrossTextSizes", "testTabletHomeTabLauncher", "testKeyboardCommands", "testSettingsEscapeKey", "testRetainedTabsStayBehindHome",
                                 "testTitleEntrances", "testLandscapeHome", "testHIGScreenshots", "testShellScreenshots",
                                 "testFilesAndGitScreenshots", "testWorkspaceScreenshots", "testLaunchTiming", "testAgentsSettings", "testSettingsScreenshots", "testSettingsAccessibilityAudit",
                                 # Home's four boxes need the twelve configured workspaces the harness then adds
                                 # (MENU_WORKSPACE_TESTS).
                                 "testPhoneActionBoxes",
                                 # Home's boxes closed with the app's animations on (the freeze of 2026-10-07).
                                 "testHomeBoxClosesWithAnimations",
                                 # The iPhone shake-down's route and keyboard regressions (2026-10-05);
                                 # testPhoneDrawerRoutes wants --enable-preview for New Browser Tab.
                                 "testPhoneDrawerRoutes", "testPhoneKeyboardStaysWithItsSurface",
                                 # The session loader over the whole iPhone screen (2026-10-12).
                                 "testPhoneSessionLoaderCoversScreen",
                                 # The tester's sessions (ExploratoryUITests.swift), usually run with --script,
                                 # --seed and --matrix.
                                 "testExploratoryScript", "testRandomWalk", "testInterruptionMatrix")
    scripted = bool(options.script or options.seed or options.matrix)
    selected = tuple(options.tests.split(",")) if options.tests else () if scripted else default_tests
    if (not selected and not scripted) or any(name not in available for name in selected) or len(set(selected)) != len(selected):
        raise RuntimeError(f"--tests must contain distinct names from: {', '.join(available)}")
    scripts = []
    for path in options.script:
        script_path = Path(path).resolve()
        script = json.loads(script_path.read_text())
        if not isinstance(script.get("steps"), list):
            raise RuntimeError(f"{path} has no steps")
        scripts.append((script_path, script))
    prepares = {item for _, script in scripts for item in script.get("prepare", [])}
    unknown = prepares - SCRIPT_PREPARATIONS
    if unknown:
        raise RuntimeError(f"Unknown script preparations: {', '.join(sorted(unknown))}")
    if any(script.get("preview") for _, script in scripts):
        options.enable_preview = True
    if not OPENCODE.is_file():
        raise RuntimeError(f"Pinned OpenCode runtime is missing: {OPENCODE}")
    if options.erase:
        simulator_guard.erase_disposable(options.simulator)
    booted = json.loads(run(["xcrun", "simctl", "list", "devices", "booted", "--json"]))
    devices = [item for group in booted["devices"].values() for item in group]
    if not any(item["udid"] == options.simulator and any(device in item.get("deviceTypeIdentifier", "") for device in ("iPhone", "iPad")) for item in devices):
        raise RuntimeError("Pass one already booted iPhone or iPad simulator; this check never boots or changes a physical device.")
    # The iPhone's Chat starts general chats only (bottom tabs, owner, 2026-10-11): no agent chat asks to run a tool.
    is_phone = any(item["udid"] == options.simulator and "iPhone" in item.get("deviceTypeIdentifier", "") for item in devices)
    enroll_face_id(options.simulator)
    original = FIXTURE.read_bytes()
    if json.loads(original).get("enabled") is not False:
        raise RuntimeError("Fixture.json must begin disabled to avoid colliding with another integration run.")
    EVIDENCE.mkdir(parents=True, exist_ok=True)
    stamp = str(int(time.time()))
    xctestrun = build_ui_tests(options.simulator, DERIVED, EVIDENCE / f"{stamp}-build.log")
    model_reply = "AGENTLAND_LOCAL_CHAT_" + secrets.token_hex(4)
    file_marker = "Saved from full iPhone flow " + secrets.token_hex(4)
    terminal_marker = "AGENTLAND_PTY_" + secrets.token_hex(4)
    search_token = "opsneedle" + secrets.token_hex(4)
    commit_message = "Commit from the phone " + secrets.token_hex(4)
    workspace_name = "Made on the phone " + secrets.token_hex(3)
    # Kept in the run's own host state: no two runs share it.
    memory_fact = "Prefers tide tables in metres"
    model_server = None
    opencode = None
    host = None
    host_ref = {}
    host_extra = {"arguments": [], "sandboxed": False}
    forwarder = {"current": None}
    mac_side = {"current": None}
    # testTerminalFromTheMacShowsOnThePhone's Terminal.app window (RoutedTerminal), while its test runs.
    mac_window = {"current": None}
    tunnel_files = None
    preview_page = None
    git_remote = {"server": None}
    failures = []
    try:
        if "testConnectsThroughIrohTunnel" in selected:
            # The Mac side and the app's profile, before anything starts. The folder is in /private/tmp,
            # which the simulator app reads (the profile, the dylib) and writes (the dylib's report).
            tunnel_files = Path(tempfile.mkdtemp(prefix="agentland-tunnel-", dir="/private/tmp"))
            remote_access_loopback = build_remote_access_loopback()
            compile_router_ports_profile(tunnel_files / "router-ports-denied.sbbc")
            build_router_ports_dylib(tunnel_files / "router-ports-sandbox.dylib")
        with disposable_directory("agentland-ios-product-") as location:
            temp = Path(location)
            model_server, model_requests = local_model_server(model_reply, memory_fact)
            project = temp / "project"
            project.mkdir(mode=0o700)
            (project / "hello.txt").write_text("Hello from AgentLand.\n")
            (project / "wheel-probe.py").write_text(WHEEL_PROBE)
            (project / "Sources").mkdir()
            (project / "Sources" / "example.swift").write_text("// Fixture source\nprint(\"AgentLand\")\n")
            (project / ".hidden-fixture").write_text("Hidden file fixture\n")
            fixture_provider = {"agentland-test": {"npm": "@ai-sdk/openai-compatible", "name": "AgentLand Local Fixture",
                "options": {"baseURL": f"http://127.0.0.1:{model_server.server_port}/v1", "apiKey": "local-test-only"},
                "models": {"fixture-model": {"name": "Deterministic Local Model", "limit": {"context": 8192, "output": 512}}}}}
            (project / "opencode.json").write_text(json.dumps({
                "$schema": "https://opencode.ai/config.json", "model": "agentland-test/fixture-model",
                # The fixture model's bash call must wait for the phone's approval.
                "permission": {"bash": "ask"},
                "provider": fixture_provider
            }) + "\n")
            password = secrets.token_urlsafe(32)
            env = open_code_environment(temp, password)
            # Plain chats run in the host's own folder beside its state, outside the project: the disposable
            # profile's global configuration makes the fixture model OpenCode's default there too, for replies
            # and titles.
            (temp / "config" / "opencode").mkdir(mode=0o700)
            (temp / "config" / "opencode" / "opencode.json").write_text(json.dumps({
                "$schema": "https://opencode.ai/config.json", "model": "agentland-test/fixture-model",
                "small_model": "agentland-test/fixture-model", "provider": fixture_provider
            }) + "\n")
            paths = run([str(OPENCODE), "debug", "paths"], cwd=project, env=env, timeout=20)
            for line in paths.splitlines():
                parts = line.split(maxsplit=1)
                if len(parts) != 2 or not Path(parts[1]).resolve().is_relative_to(temp.resolve()):
                    raise RuntimeError("OpenCode path inspection escaped the disposable profile")
            oc_port = free_port()
            oc_url = f"http://127.0.0.1:{oc_port}"
            with (EVIDENCE / f"{stamp}-opencode.log").open("w") as oc_log:
                debug = ["--print-logs", "--log-level", "DEBUG"] if options.opencode_debug else []
                opencode = subprocess.Popen([str(OPENCODE), "serve", "--pure", "--hostname", "127.0.0.1",
                                             "--port", str(oc_port), *debug], cwd=project, env=env,
                                            stdout=oc_log, stderr=oc_log, start_new_session=True)
                wait_health(oc_url + "/global/health", process=opencode, password=password)
                providers = opencode_json(oc_url + "/provider", password, project)
                config = opencode_json(oc_url + "/config", password, project)
                if "agentland-test" not in providers.get("connected", []) or config.get("model") != "agentland-test/fixture-model":
                    raise RuntimeError("Disposable OpenCode did not load the connected local model configuration")
                binary = temp / "agentland-host"
                run(["go", "build", "-o", str(binary), "./cmd/agentland-host"], cwd=ROOT / "desktop", timeout=90)
                (temp / "opencode").symlink_to(OPENCODE)
                tls = json.loads(run([str(binary), "tls", "init", "--directory", str(temp / "tls"), "--hosts", "localhost"]))
                state = temp / "host.json"
                KEEPER_TARGET.update(binary=binary, state=state)
                project_arguments = ["--project", f"fixture=Fixture={project}"]
                # Real configured folders in the disposable profile exercise long native menus without
                # touching owner workspaces or starting any model/agent work in them. They are configured
                # only while the test or script that asks for them runs (`wants_menu_workspaces`): with
                # them the drawer's root lists 13 workspaces and every other test would meet that list.
                menu_arguments = []
                if any(name in selected for name in MENU_WORKSPACE_TESTS) or "menu-workspaces" in prepares:
                    for index in range(1, 12):
                        extra = temp / f"menu-workspace-{index}"
                        extra.mkdir(mode=0o700)
                        menu_arguments.extend(["--project", f"menu-{index}=Workspace {index}={extra}"])
                host_projects = {"menu": False}
                run([str(binary), "init", "--state", str(state), "--opencode-url", oc_url,
                     *project_arguments])
                # Workspace management browses and adds folders only inside the host's home folder: a
                # disposable one of its own here (not the temporary folder, which holds the TLS key and
                # the host's state, and not OpenCode's test home), never the owner's.
                workspace_home = temp / "workspace-home"
                prepare_workspace_home(workspace_home)
                host_port = free_port()
                address = f"https://localhost:{host_port}"
                host_env = os.environ.copy()
                host_env["AGENTLAND_OPENCODE_PASSWORD"] = password
                # The Mac's local session, which only the remote access test's host takes (and the Mac side
                # uses for the peers and endpoint routes), and testTerminalFromTheMacShowsOnThePhone's, which reads
                # the Mac's list of every terminal.
                local_session_token = secrets.token_hex(32)
                host_env["AGENTLAND_LOCAL_SESSION_TOKEN"] = local_session_token
                with (EVIDENCE / f"{stamp}-host.log").open("w") as host_log:
                    host_command = [str(binary), "serve", "--state", str(state), "--listen",
                                    f"127.0.0.1:{host_port}", "--cert", tls["certificateFile"],
                                    "--key", tls["keyFile"], "--enable-terminal",
                                    # Plain chats run on the fixture OpenCode, which Chat leaves out
                                    # unless the host is asked for it (2026-10-12).
                                    "--opencode-chat",
                                    # Browsing and adding workspaces stay in the disposable folder.
                                    "--workspace-home", str(workspace_home)]
                    preview_fixture = {}
                    if options.enable_preview:
                        # Browser: the preview listener on a free loopback port (never the owner's 9842) and a
                        # page on another for it to open.
                        preview_marker = "AGENTLAND_PREVIEW_" + secrets.token_hex(4)
                        preview_page = PreviewPage(preview_marker)
                        host_command += ["--enable-preview", "--preview-listen", f"127.0.0.1:{free_port()}"]
                        preview_fixture = dict(previewPort=preview_page.port, previewMarker=preview_marker)
                    # testConnectsThroughAlternateRoute: the host lists routes, a local name that does not
                    # resolve and a Tailscale route at 127.0.0.1 (from the fake command line), while the
                    # phone pairs through a forwarder the test cuts.
                    route_arguments = ["--advertised-host", "agentland-home.invalid",
                                       "--tailscale-cli", str(fake_tailscale(temp))]
                    # testConnectsThroughIrohTunnel: the host serves its tunnel socket beside its state and
                    # takes the Mac's local session; it runs under the router-ports profile like the Mac side.
                    tunnel_socket = temp / "tunnel.sock"
                    tunnel_arguments = ["--local-session-env", "AGENTLAND_LOCAL_SESSION_TOKEN", "--tunnel-socket", str(tunnel_socket)]
                    # testTerminalFromTheMacShowsOnThePhone: the host takes the Mac's local session, whose list of every
                    # terminal (GET /v1/terminals/all) shows the routed one and whether a keeper runs.
                    local_session_arguments = ["--local-session-env", "AGENTLAND_LOCAL_SESSION_TOKEN"]
                    # The agent catalog (registry reads, `--version` runs of the agents found on this Mac)
                    # is on only for testAgentsSettings, which reads it; the other tests' host runs without it.
                    no_agents = ["--no-agents"]
                    host_extra["arguments"] = no_agents
                    host_log_path = EVIDENCE / f"{stamp}-host.log"
                    # A device of the harness's own, paired when the host first runs, reads what the host lists.
                    harness_device = {}

                    def start_host():
                        prefix = ["sandbox-exec", "-f", str(ROUTER_PORTS_PROFILE)] if host_extra["sandboxed"] else []
                        process = subprocess.Popen(prefix + host_command + host_extra["arguments"], env=host_env, stdout=host_log,
                                                   stderr=host_log, start_new_session=True)
                        wait_health(address + "/v1/health", process=process, cafile=tls["certificateFile"], timeout=20)
                        if "token" not in harness_device:
                            harness_code = run([str(binary), "pair", "--pin", "--state", str(state)])
                            harness_device["token"] = host_json(address + "/v1/pair", tls["certificateFile"],
                                                                body={"code": harness_code, "deviceName": "Product check"})["token"]
                        wait_plain_chats(address, tls["certificateFile"], harness_device["token"], host_log_path)
                        return process

                    def cut_forwarder():
                        if forwarder["current"] is not None:
                            forwarder["current"].cut()

                    def stop_mac_side():
                        side, mac_side["current"] = mac_side["current"], None
                        return side.stop() if side is not None else True

                    # What testConnectsThroughIrohTunnel asks the harness to check or change (hostCheck).
                    tunnel = {}

                    def audit_lines():
                        return [line for line in host_log_path.read_text(errors="replace").splitlines()
                                if "remote access: tunnel connection of device" in line]

                    def tunnel_registered():
                        # The app paired at the forwarder and registered its node ID there with a proof: the
                        # host's record of the newest device has it, and the Mac's gate got it from the peers route.
                        deadline = time.monotonic() + 30
                        found = None
                        while time.monotonic() < deadline:
                            peers = mac_side["current"].peers()
                            devices = [item for item in json.loads(state.read_text()).get("devices", []) if not item.get("revokedAt")]
                            newest = max(devices, key=lambda item: item.get("createdAt", ""), default=None)
                            found = (peers, newest and newest.get("id"), newest and newest.get("irohNodeId"))
                            if newest and newest.get("irohNodeId") and peers == [(newest["id"], newest["irohNodeId"])]:
                                tunnel["device"], tunnel["node"] = peers[0]
                                return "ok"
                            time.sleep(0.2)
                        return f"the gate's peers and the newest device do not match: {found}"

                    def tunnel_ran():
                        proof = project / "tunnel-proof.txt"
                        if not proof.exists() or proof.read_text().strip() != TUNNEL_PROOF:
                            return "the terminal command typed through the tunnel never ran on the host"
                        line = f"remote access: tunnel connection of device {tunnel['device']} (node {tunnel['node'][:8]})"
                        accepted = [item for item in audit_lines() if line in item]
                        if not accepted:
                            return "the host's audit has no tunnel connection of the device"
                        tunnel["accepted"] = len(accepted)
                        return "ok"

                    def tunnel_unpair():
                        # The owner removes the device on the Mac (as Settings → Devices does) while the app is
                        # closed; the gate must drop its node ID.
                        run([str(binary), "revoke", "--state", str(state), "--device", tunnel["device"]])
                        mac_side["current"].wait("the peer list without the device", lambda: mac_side["current"].peers() == [], 15)
                        tunnel["audit"] = len(audit_lines())
                        return "ok"

                    def tunnel_refused():
                        # The app's 403 came from the gate: no tunnel connection reached the host since.
                        if len(audit_lines()) != tunnel["audit"]:
                            return f"a tunnel connection reached the host after the device was removed: {audit_lines()[tunnel['audit']:]}"
                        return "ok"

                    def content_size(category):
                        # The simulator's Text Size, as Settings or Control Center changes it with the app open.
                        def change():
                            run(["xcrun", "simctl", "ui", options.simulator, "content_size", category], timeout=20)
                            return "ok"
                        return change

                    def content_size_sweep():
                        # Control Center's Text Size slider dragged up to the largest size and back, one size after
                        # another without a pause.
                        sizes = ["extra-large", "extra-extra-large", "extra-extra-extra-large", "accessibility-medium",
                                 "accessibility-large", "accessibility-extra-large", "accessibility-extra-extra-large",
                                 "accessibility-extra-extra-extra-large"]
                        for category in sizes + sizes[-2::-1] + ["large"]:
                            run(["xcrun", "simctl", "ui", options.simulator, "content_size", category], timeout=20)
                        return "ok"

                    control_actions = {"cut": cut_forwarder, "registered": tunnel_registered, "ran": tunnel_ran,
                                       "unpair": tunnel_unpair, "refused": tunnel_refused,
                                       "text-large": content_size("large"), "text-xxl": content_size("extra-extra-large"),
                                       "text-xxxl": content_size("extra-extra-extra-large"), "text-sweep": content_size_sweep}
                    host = start_host()
                    payload_actions = exploratory_actions(options.simulator, {"project": project, "home": workspace_home},
                                                          binary, state, lambda: host_ref.get("host"))

                    # testTerminalFromTheMacShowsOnThePhone: `claude` typed in a Terminal.app window on the Mac
                    # (RoutedTerminal), which the test starts, types into, reads and closes. The request's text is the
                    # payload of routed-type (keys) and routed-wait (what the window must show).
                    def end_mac_window():
                        """Closes the window and turns routing off: no CLI outlives its test, and no later test's host
                        keeps a keeper for routing. Never raises."""
                        window, mac_window["current"] = mac_window["current"], None
                        try:
                            if window is not None:
                                window.hang_up()
                        except Exception as error:  # cleanup never raises
                            print(f"WARNING: the Terminal window of testTerminalFromTheMacShowsOnThePhone did not close: {error!r}", flush=True)
                        try:
                            set_routing(state, False)
                        except OSError as error:
                            print(f"WARNING: the routing switch stayed on: {error!r}", flush=True)

                    def routed_start_action(_payload):
                        end_mac_window()  # a window an earlier attempt left
                        mac_window["current"] = RoutedTerminal()
                        return routed_start(mac_window["current"], binary, state, address, tls["certificateFile"],
                                            local_session_token)

                    def routed_window():
                        if mac_window["current"] is None or mac_window["current"].master is None:
                            raise RuntimeError("no Terminal window runs claude; ask routed-start first")
                        return mac_window["current"]

                    def routed_type(payload):
                        routed_window().type(payload)
                        return "ok"

                    def routed_wait(payload):
                        window = routed_window()
                        if window.wait_for(payload, 20):
                            return "ok"
                        return f"missing: {payload}; the window shows {window.tail()!r}"

                    def routed_stop(_payload):
                        if routed_window().hang_up():
                            return "ok"
                        return "the CLI did not exit within 15 s of SIGHUP; it was killed"

                    payload_actions.update({"routed-start": routed_start_action, "routed-type": routed_type,
                                            "routed-wait": routed_wait, "routed-stop": routed_stop})
                    control, control_stop, host_ref = start_host_control(lambda: host, start_host, control_actions, payload_actions)
                    executed = []
                    order = (("light", "testPhoneBottomTabs"), ("light", "testLaunchTiming"),
                             ("light", "testPhoneActionBoxes"),
                             ("light", "testHomeBoxClosesWithAnimations"),
                             ("light", "testPhoneDrawerRoutes"), ("light", "testPhoneKeyboardStaysWithItsSurface"),
                             ("light", "testPhoneSessionLoaderCoversScreen"),
                             ("light", "testPhoneWorkspaceRecoveryAndRefusal"),
                             ("light", "testVisualSurfaces"), ("light", "testFileFlow"), ("light", "testFileOperations"),
                             ("light", "testGitStageAndCommit"), ("light", "testChatFlow"),
                             ("light", "testChatFeaturesFlow"), ("light", "testChatStreamingFlow"), ("light", "testChatKeepsItsRowsAcrossTextSizes"),
                             ("light", "testChatLibrary"),
                             ("light", "testAgentChatLanding"), ("light", "testHomeCapsulesAndQuip"), ("light", "testNativeBarButtons"),
                             ("light", "testSidebarNavigation"), ("light", "testDrawerSearchAndSettings"),
                             ("light", "testWorkspaceManagement"), ("light", "testWorkspaceScreenshots"),
                             ("light", "testAgentsSettings"), ("light", "testSettingsScreenshots"), ("light", "testSettingsAccessibilityAudit"),
                             ("light", "testRetainedTabsStayBehindHome"), ("light", "testVoiceOverReachesOnlyTheSelectedSurface"),
                             ("light", "testTerminalFlow"), ("light", "testTerminalWheelScroll"), ("light", "testNamedOpenCodeFlow"),
                             ("light", "testHostDisconnectFlow"), ("light", "testTerminalSurvivesHostKill"),
                             ("light", "testTerminalFromTheMacShowsOnThePhone"),
                             ("light", "testConnectsThroughAlternateRoute"),
                             ("light", "testConnectsThroughIrohTunnel"),
                             ("light", "testAccessibilityAudits"), ("light", "testHIGScreenshots"), ("light", "testShellScreenshots"),
                             ("light", "testFilesAndGitScreenshots"),
                             ("light", "testTabletHomeTabLauncher"), ("light", "testKeyboardCommands"), ("light", "testSettingsEscapeKey"),
                             ("light", "testTitleEntrances"), ("light", "testLandscapeHome"),
                             # Late: the plain chats it leaves on the host are listed first in the later tests' sidebars.
                             ("light", "testPlainChatFlow"),
                             ("dark", "testDarkAppearance"))
                    # Tests run in this order whatever order --tests lists them in, then the scripts,
                    # walks and matrix rows in the order given. Each one starts from a fresh host state,
                    # whatever the one before it left or how it ended: the host is restarted (terminals
                    # outlive the host, so `terminals stop` ends the previous test's terminals), and the app is installed afresh (or the simulator erased, --erase)
                    # and pairs again, so no tab, workspace choice or device archive carries over.
                    runs = [(phase, name, {}, name, None) for phase, name in order if name in selected]
                    for script_path, script in scripts:
                        copy = control / f"script-{script_path.stem}.json"
                        shutil.copyfile(script_path, copy)
                        runs.append((script.get("appearance", "light"), "testExploratoryScript",
                                     {"script": str(copy), "scriptName": script_path.stem, "prepare": script.get("prepare", [])},
                                     f"script-{script_path.stem}", script.get("timeout", EXPLORATORY_LIMIT)))
                    for seed in options.seed:
                        runs.append(("light", "testRandomWalk", {"seed": seed, "walkSteps": options.walk_steps},
                                     f"walk-seed{seed}", 1500))
                    for row in options.matrix:
                        surface, _, interruptions = row.partition(":")
                        runs.append(("light", "testInterruptionMatrix",
                                     {"matrixSurface": surface, "matrixInterruptions": (interruptions or "all").split(",")},
                                     f"matrix-{surface}", 1500))
                    for phase, test_name, extras, label, limit in runs:
                      attempted = len(executed) + len(failures)
                      try:
                          routed = test_name == "testConnectsThroughAlternateRoute"
                          tunneled = test_name == "testConnectsThroughIrohTunnel"
                          from_mac = test_name == "testTerminalFromTheMacShowsOnThePhone"
                          wanted = (route_arguments if routed else tunnel_arguments if tunneled
                                    else local_session_arguments if from_mac else []) + \
                              ([] if test_name == "testAgentsSettings" else no_agents)
                          menu = bool(menu_arguments) and (test_name in MENU_WORKSPACE_TESTS
                                                           or "menu-workspaces" in extras.get("prepare", []))
                          if attempted or host_extra["arguments"] != wanted or host_extra["sandboxed"] != tunneled \
                                  or menu != host_projects["menu"]:
                              stop_mac_side()
                              previous = host_ref["host"]
                              if previous.poll() is None:
                                  os.killpg(previous.pid, signal.SIGCONT)  # a test may have left it paused
                              stop_process(previous)
                              stop_terminals()
                              host_extra["arguments"] = wanted
                              host_extra["sandboxed"] = tunneled
                              if menu != host_projects["menu"]:
                                  # The host is stopped: its configured workspaces change for this entry only.
                                  run([str(binary), "config", "set", "--state", str(state), "--opencode-url", oc_url,
                                       *project_arguments, *(menu_arguments if menu else [])])
                                  host_projects["menu"] = menu
                              host_ref["host"] = start_host()
                              host = host_ref["host"]
                          cut_forwarder()
                          forwarder["current"] = Forwarder(host_port) if routed or tunneled else None
                          paired_address = f"https://localhost:{forwarder['current'].port}" if routed or tunneled else address
                          tunnel_fixture = {}
                          if tunneled:
                              tunnel.clear()
                              report = tunnel_files / "router-ports-report.txt"
                              report.unlink(missing_ok=True)
                              (tunnel_files / "mac").mkdir(exist_ok=True)
                              mac_log = (EVIDENCE / f"{stamp}-{test_name}-mac.log").open("w")
                              mac_side["current"] = MacSide(remote_access_loopback, host_port=host_port, fingerprint=tls["fingerprint"],
                                                            tunnel_socket=tunnel_socket, token=local_session_token,
                                                            folder=tunnel_files / "mac", log=mac_log)
                              mac_side["current"].wait_reported()
                              side = mac_side["current"]
                              tunnel_fixture = dict(
                                  tunnelLoopback=f"{side.reported_address}=127.0.0.1:{side.udp_port}",
                                  routerPortsDylib=str(tunnel_files / "router-ports-sandbox.dylib"),
                                  routerPortsBytecode=str(tunnel_files / "router-ports-denied.sbbc"),
                                  routerPortsReport=str(report))
                          if options.erase and attempted:
                              simulator_guard.erase_disposable(options.simulator)
                              enroll_face_id(options.simulator)
                          subprocess.run(["xcrun", "simctl", "uninstall", options.simulator, "dev.agentland.client"],
                                         capture_output=True, timeout=60)
                          run(["xcrun", "simctl", "ui", options.simulator, "appearance", phase], timeout=10)
                          # Every test starts at the default Text Size, whatever one before it changed.
                          run(["xcrun", "simctl", "ui", options.simulator, "content_size", "large"], timeout=10)
                          code = run([str(binary), "pair", "--pin", "--state", str(state)])
                          # The run's fixture is a file of its own in the control folder (0700, removed with it);
                          # the test runner reads it through TEST_RUNNER_AGENTLAND_FIXTURE.
                          fixture_path = control / f"fixture-{label}.json"
                          fixture_path.write_text(json.dumps(dict(enabled=True, address=paired_address, code=code,
                              fingerprint=tls["fingerprint"], marker=file_marker, terminalMarker=terminal_marker,
                              chatReply=model_reply, streamReply=stream_reply(model_reply), approvalReply=APPROVAL_FOLLOW_UP,
                              searchToken=search_token, commitMessage=commit_message, workspaceName=workspace_name,
                              memoryFact=memory_fact, plainChats=True, modelID="agentland-test/fixture-model", phase=phase,
                              freshHost=True, control=str(control), project=str(project), workspaceHome=str(workspace_home),
                              gitRemote=git_remote["server"].url("git-fixture.git") if git_remote["server"] else None,
                              **tunnel_fixture, **preview_fixture, **extras)) + "\n")
                          result = EVIDENCE / f"{stamp}-{label}.xcresult"
                          log = EVIDENCE / f"{stamp}-{label}.log"
                          # A script's own preparations, undone after it whatever happened.
                          prepared = set(extras.get("prepare", []))
                          if "ops" in prepared:
                              trash_name = prepare_file_operations(project, search_token)
                          if "git" in prepared and "git-remote" not in prepared:
                              repository = prepare_git_repository(project)
                          if "git-remote" in prepared:
                              repository, git_remote["server"] = prepare_git_remote(project, temp)
                              # The fixture names the remote the phone's repository tracks.
                              written = json.loads(fixture_path.read_text())
                              written["gitRemote"] = git_remote["server"].url("git-fixture.git")
                              fixture_path.write_text(json.dumps(written) + "\n")
                          if "photo" in prepared:
                              payload_actions["addmedia"](json.dumps({"name": "agentland-fixture-photo"}))

                          def undo_preparations():
                              if "ops" in prepared:
                                  clean_file_operations(project, trash_name)
                              if prepared & {"git", "git-remote"}:
                                  shutil.rmtree(repository, ignore_errors=True)
                              if "git-remote" in prepared and git_remote["server"] is not None:
                                  git_remote["server"].stop()
                                  git_remote["server"] = None
                                  shutil.rmtree(temp / "git-remotes", ignore_errors=True)
                          # The disposable folder and repository exist only for their own test, so the
                          # other tests see the project (and "No Git Repositories") as before.
                          if test_name == "testFileOperations":
                              trash_name = prepare_file_operations(project, search_token)
                          if test_name == "testGitStageAndCommit":
                              repository = prepare_git_repository(project)
                          if test_name in ("testFilesAndGitScreenshots", "testPhoneWorkspaceRecoveryAndRefusal"):
                              trash_name = prepare_file_operations(project, search_token)
                              repository = prepare_git_repository(project)
                          try:
                              # The first test of a run waits out the freshly booted simulator's own start-up work.
                              first = 0 if attempted else 300
                              run_ui_test(options.simulator, test_name, result, log, xctestrun, fixture_path,
                                          (limit or LONG_TESTS.get(test_name, 450)) + first)
                              undo_preparations()
                              if test_name in ("testFilesAndGitScreenshots", "testPhoneWorkspaceRecoveryAndRefusal"):
                                  clean_file_operations(project, trash_name)
                                  shutil.rmtree(repository, ignore_errors=True)
                          except BaseException:
                              undo_preparations()
                              if test_name in ("testFilesAndGitScreenshots", "testPhoneWorkspaceRecoveryAndRefusal"):
                                  clean_file_operations(project, trash_name)
                                  shutil.rmtree(repository, ignore_errors=True)
                              if test_name == "testFileOperations":
                                  clean_file_operations(project, trash_name)
                              if test_name == "testGitStageAndCommit":
                                  shutil.rmtree(repository, ignore_errors=True)
                              raise
                          finally:
                              # testTerminalFromTheMacShowsOnThePhone's window, however the test ended.
                              end_mac_window()
                          host = host_ref["host"]
                          # Verify effects before another screen's failure can mask
                          # them, and while this disposable project still exists.
                          if test_name == "testFileOperations":
                              deleted = verify_file_operations(project, trash_name)
                              print(f"testFileOperations: rename, new folder, move and both uploads verified; delete by {deleted}", flush=True)
                          if test_name == "testGitStageAndCommit":
                              commit = verify_git_commit(repository, commit_message)
                              print(f"testGitStageAndCommit: commit {commit} is in the log with the phone's message and the test identity", flush=True)
                          if test_name == "testWorkspaceManagement":
                              branch = verify_workspace_management(binary, state, workspace_home, workspace_name)
                              print(f"testWorkspaceManagement: the folder and its repository ({branch}) stay on disk; the host no longer lists it", flush=True)
                          if test_name == "testPhoneBottomTabs":
                              if (project / "phone-tabs-terminal-proof.txt").read_text().strip() != "phone tabs terminal ready":
                                  raise RuntimeError("The phone-tabs terminal did not execute its proof command")
                              print("Phone-tabs PTY command execution verified on host", flush=True)
                          if test_name == "testPlainChatFlow":
                              kept = verify_plain_chat_memory(state, memory_fact, model_requests)
                              print(f"testPlainChatFlow: the host kept the saved fact, then Undo and the forget removed it ({kept} other entries)", flush=True)
                          if test_name == "testFileFlow":
                              saved_file = (project / "hello.txt").read_text()
                              if file_marker not in saved_file or "SECOND_" + file_marker[-8:] not in saved_file:
                                  raise RuntimeError("The iPhone editor did not save both complete typed markers on the host")
                          if test_name == "testTerminalFlow":
                              if (project / "terminal-proof.txt").read_text().strip() != terminal_marker:
                                  raise RuntimeError("The real PTY did not execute the iPhone command")
                              if (project / "key-proof.txt").read_text().strip() != terminal_marker:
                                  raise RuntimeError("The explicit Control-C menu action did not restore the shell")
                              touch_proof = project / "touch-proof.txt"
                              if not touch_proof.exists():
                                  raise RuntimeError("The terminal touch-read command never completed")
                              if touch_proof.read_bytes():
                                  raise RuntimeError("Touch scrolling sent bytes into the real PTY")
                              rebuild_proof = project / "rebuild-proof.txt"
                              if not rebuild_proof.exists() or rebuild_proof.read_text().strip() != terminal_marker:
                                  raise RuntimeError("After the surface rebuild the terminal was not the same shell")
                          if test_name == "testHostDisconnectFlow":
                              disconnect_before = (project / "disconnect-pid-before.txt").read_text().strip()
                              disconnect_after = (project / "disconnect-pid-after.txt").read_text().strip()
                              if not disconnect_before or disconnect_before != disconnect_after:
                                  raise RuntimeError(f"A restarted host did not keep the shell: {disconnect_before!r} then {disconnect_after!r}")
                              print(f"testHostDisconnectFlow: the same shell (pid {disconnect_before}) answered before the stop and after the restart", flush=True)
                          if test_name == "testTerminalSurvivesHostKill":
                              shell_pid = verify_terminal_survived_kill(project, state)
                              print(f"testTerminalSurvivesHostKill: shell pid {shell_pid} lived through the SIGKILLed host, typed input reached it, "
                                    "and the archived log has tick-1 to tick-40 with no gap", flush=True)
                          if test_name == "testTerminalFromTheMacShowsOnThePhone":
                              print("testTerminalFromTheMacShowsOnThePhone: claude typed in a Terminal window on the Mac ran as a "
                                    "routed terminal; the phone typed into it and the window saw the answer, the window typed "
                                    "into it and the phone saw the answer, and closing the window ended it", flush=True)
                          if test_name == "testTerminalWheelScroll":
                              wheel_proof = project / "wheel-proof.txt"
                              if not wheel_proof.exists():
                                  raise RuntimeError("The wheel probe never finished in the real PTY")
                              received = wheel_proof.read_bytes()
                              if not WHEEL_REPORTS.fullmatch(received):
                                  raise RuntimeError(f"A touch drag sent the mouse-reporting program something other than wheel reports: {received[:200]!r}")
                              if b"\x1b[<64;" not in received or b"\x1b[<65;" not in received:
                                  raise RuntimeError(f"Dragging down and up did not turn the wheel both ways: {received[:200]!r}")
                              print(f"testTerminalWheelScroll: {received.count(b'<64;')} wheel-up and {received.count(b'<65;')} wheel-down reports, nothing else", flush=True)
                          if test_name == "testConnectsThroughAlternateRoute":
                              cut_forwarder()
                              proof = project / "route-proof.txt"
                              try:
                                  if not proof.exists() or proof.read_text().strip() != "through-alternate-route":
                                      raise RuntimeError("The terminal command typed over the alternate route never ran on the host")
                              finally:
                                  proof.unlink(missing_ok=True)
                              print("testConnectsThroughAlternateRoute: after the paired address was cut the app worked through "
                                    "127.0.0.1 with the paired pin and name, and relaunched on it", flush=True)
                          if test_name == "testConnectsThroughIrohTunnel":
                              cut_forwarder()
                              (project / "tunnel-proof.txt").unlink(missing_ok=True)
                              # Every run of the app applied the router-ports profile before its own code ran.
                              applied = [line for line in (tunnel_files / "router-ports-report.txt").read_text().splitlines()
                                         if line.startswith("applied pid=") and line.endswith("1900,5350,5351=EPERM")]
                              if len(applied) < 3:
                                  raise RuntimeError(f"The app ran {len(applied)} times under the router-ports profile, not 3")
                              if not stop_mac_side():
                                  raise RuntimeError("The Mac side did not remove its mapping when it quit")
                              print(f"testConnectsThroughIrohTunnel: the app registered node {tunnel['node'][:8]}, reached the host "
                                    f"through iroh on loopback ({tunnel['accepted']} tunnel connections in the host's audit) and ran "
                                    f"a terminal command; with the device removed the next run was refused with 403 and no "
                                    f"connection reached the host; {len(applied)} app runs under the router-ports profile", flush=True)
                          if test_name == "testLaunchTiming":
                              runs = [dict(field.split("=") for field in line.split()[1:])
                                      for line in log.read_text(errors="replace").splitlines() if line.startswith("LAUNCH-TIMING ")]
                              timed = [run for run in runs if run["run"] != "0"]  # the first launch is a warm-up
                              if len(timed) != 5:
                                  raise RuntimeError(f"testLaunchTiming reported {len(runs)} launches; inspect {log}")
                              idle = statistics.median(float(run["idle"]) for run in timed)
                              shown = statistics.median(float(run["shown"]) for run in timed)
                              print(f"Launch timing (median of 5): idle {idle:.2f} s, Files shown {shown:.2f} s", flush=True)
                          if test_name == "testChatFlow" and (not model_requests or not any(item.get("model") == "fixture-model" for item in model_requests)):
                              raise RuntimeError("The iPhone chat never reached the deterministic local model")
                          if test_name == "testChatFeaturesFlow":
                              prompts = [last_user_text(item) for item in model_requests]
                              slow = next((i for i, text in enumerate(prompts) if "AGENTLAND_SLOW" in text), None)
                              follow = next((i for i, text in enumerate(prompts) if "Queued follow-up message" in text), None)
                              if slow is None or follow is None or follow < slow:
                                  raise RuntimeError("The host did not send the queued prompt after the slow reply")
                          if test_name == "testChatStreamingFlow":
                              prompts = [last_user_text(item) for item in model_requests]
                              if not any("AGENTLAND_STREAM" in text for text in prompts):
                                  raise RuntimeError("The streaming prompt never reached the local model")
                              proof = project / "approval-proof.txt"
                              if is_phone:
                                  print("testChatStreamingFlow: no approval on iPhone (general chats run no tools)", flush=True)
                              elif not proof.exists() or proof.read_text().strip() != "approved-by-phone":
                                  raise RuntimeError("The approved bash call did not run in the project after Allow Once")
                          executed.append(label)
                          print(f"Verified {label}: {log}", flush=True)
                      except Exception as error:
                        if not options.keep_going:
                            raise
                        failures.append((label, str(error)))
                        print(f"FAILED {label}: {error}", flush=True)
                    control_stop.set()
                    if failures:
                        raise RuntimeError(f"{len(failures)} of {len(runs)} runs failed: " +
                                           "; ".join(f"{label}: {error}" for label, error in failures))
                    if len(executed) != len(runs):
                        raise RuntimeError(f"Selected UI tests were not all executed: {[run[3] for run in runs if run[3] not in executed]}")
                    print(f"PASS: {options.simulator} paired to real HTTPS host/OpenCode; {', '.join(executed)} verified. Screenshots and logs: {EVIDENCE}")
    finally:
        FIXTURE.write_bytes(original)
        # A test that changed the Text Size and failed leaves the simulator as it found it.
        subprocess.run(["xcrun", "simctl", "ui", options.simulator, "content_size", "large"], capture_output=True, timeout=10)
        if forwarder["current"] is not None:
            forwarder["current"].cut()
        if mac_side["current"] is not None:
            mac_side["current"].stop()
        if mac_window["current"] is not None:
            mac_window["current"].hang_up()
        if tunnel_files is not None:
            shutil.rmtree(tunnel_files, ignore_errors=True)
        if preview_page is not None:
            preview_page.stop()
        if git_remote["server"] is not None:
            git_remote["server"].stop()
        for process in {id(item): item for item in (host, host_ref.get("host")) if item is not None}.values():
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGCONT)
            stop_process(process)
        stop_process(opencode)
        if model_server is not None and options.opencode_debug:
            # Which prompts reached the fixture model, in order, beside OpenCode's DEBUG log.
            (EVIDENCE / f"{stamp}-model-prompts.json").write_text(
                json.dumps([last_user_text(item) for item in model_requests], indent=1))
        if model_server is not None:
            model_server.shutdown()
            model_server.server_close()


if __name__ == "__main__":
    main()
