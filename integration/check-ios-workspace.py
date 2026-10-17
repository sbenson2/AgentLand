#!/usr/bin/env python3
"""Pair the shipping simulator app with a disposable host; edit and restore tabs.

Requires booted iOS simulators. Pass their UDIDs as arguments. This never changes
other installed apps, their Keychain namespaces or backends, or Tailscale settings.
The temporary fixture contains only generated test credentials and is restored.
"""
import argparse
import json
import os
from pathlib import Path
import secrets
import signal
import socket
import ssl
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import simulator_guard  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / 'ios/AgentLandUITests/Fixture.json'


def run(args, cwd=None, env=None, timeout=240):
    result = subprocess.run(args, cwd=cwd, env=env, capture_output=True, text=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError(result.stderr[-3000:] or result.stdout[-3000:])
    return result.stdout.strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('simulator', nargs='+', help='Booted simulator UDID (never a physical device).')
    parser.add_argument('--discovery', action='store_true', help='Exercise actual Bonjour discovery and numeric PIN pairing on the local network.')
    options = parser.parse_args()
    simulator_guard.refuse_protected(*options.simulator)
    available = json.loads(run(['xcrun', 'simctl', 'list', 'devices', 'booted', '--json']))
    booted = {device['udid'] for group in available['devices'].values() for device in group if device['state'] == 'Booted'}
    if not set(options.simulator) <= booted:
        raise RuntimeError('Every requested device must be an already booted iOS simulator.')
    evidence = ROOT / '.evidence/ios-workspace'
    evidence.mkdir(parents=True, exist_ok=True)
    original = FIXTURE.read_bytes()
    try:
        with tempfile.TemporaryDirectory(prefix='agentland-ios-integration-') as temporary:
            temp = Path(temporary)
            binary = temp / 'agentland-host'
            run(['go', 'build', '-o', str(binary), './cmd/agentland-host'], ROOT / 'desktop')
            hostname = run(['scutil', '--get', 'LocalHostName']) + '.local' if options.discovery else 'localhost'
            tls = json.loads(run([str(binary), 'tls', 'init', '--directory', str(temp / 'tls'), '--hosts', hostname]))
            cert, key = tls['certificateFile'], tls['keyFile']
            project = temp / 'project'
            project.mkdir()
            state = temp / 'host.json'
            run([str(binary), 'init', '--state', str(state), '--project', f'fixture=Fixture={project}'])
            with socket.socket() as listener:
                listener.bind(('127.0.0.1', 0))
                port = listener.getsockname()[1]
            address = f'https://{hostname}:{port}'
            env = os.environ.copy()
            env['AGENTLAND_OPENCODE_PASSWORD'] = secrets.token_urlsafe(32)
            with (temp / 'host.log').open('w') as host_log:
                listener_host = '0.0.0.0' if options.discovery else '127.0.0.1'
                host = subprocess.Popen([str(binary), 'serve', '--state', str(state), '--listen', f'{listener_host}:{port}', '--cert', cert, '--key', key,
                                         # Its workspaces live in the disposable folder; no agent catalog is read.
                                         '--workspace-home', str(temp), '--no-agents'], env=env, stdout=host_log, stderr=host_log)
                publisher = None
                try:
                    context = ssl.create_default_context(cafile=cert)
                    deadline = time.monotonic() + 15
                    while True:
                        if host.poll() is not None:
                            raise RuntimeError('Fixture host exited before readiness.')
                        try:
                            with urllib.request.urlopen(address + '/v1/health', context=context, timeout=1):
                                break
                        except (OSError, urllib.error.URLError):
                            if time.monotonic() > deadline:
                                raise RuntimeError('Fixture host readiness timeout.')
                            time.sleep(.1)
                    discovery_name = 'AgentLand verification ' + secrets.token_hex(3) if options.discovery else None
                    if options.discovery:
                        publisher = subprocess.Popen(['dns-sd', '-R', discovery_name, '_agentland._tcp.', 'local.', str(port), 'v=1', 'url=' + address, 'fp=' + tls['fingerprint']], stdout=host_log, stderr=host_log)
                    for index, device in enumerate(options.simulator):
                        (project / 'hello.txt').write_text('Hello from AgentLand.\n')
                        marker = 'Saved from the shipping iOS editor ' + secrets.token_hex(4)
                        code = run([str(binary), 'pair', '--pin', '--state', str(state)])
                        FIXTURE.write_text(json.dumps(dict(enabled=True, address=address, code=code, fingerprint=tls['fingerprint'], marker=marker, discoveryName=discovery_name)) + '\n')
                        result_path = evidence / f'{device}-{time.time_ns()}.xcresult'
                        with (evidence / f'{device}.log').open('w') as build_log:
                            command = ['xcodebuild', '-project', str(ROOT / 'ios/AgentLand.xcodeproj'), '-scheme', 'AgentLand', '-destination', f'platform=iOS Simulator,id={device}', '-derivedDataPath', os.environ.get('AGENTLAND_DERIVED_DATA', '/private/tmp/agentland-derived'), '-resultBundlePath', str(result_path), '-parallel-testing-enabled', 'NO', 'CODE_SIGNING_ALLOWED=YES', 'CODE_SIGN_IDENTITY=-', 'ARCHS=arm64', '-only-testing:AgentLandUITests/HostWorkspaceUITests/testPairEditCloseAndRelaunch', 'test']
                            build = subprocess.Popen(command, stdout=build_log, stderr=build_log, start_new_session=True)
                            try:
                                returncode = build.wait(timeout=450)
                            except subprocess.TimeoutExpired:
                                os.killpg(build.pid, signal.SIGTERM)
                                try:
                                    build.wait(timeout=10)
                                except subprocess.TimeoutExpired:
                                    os.killpg(build.pid, signal.SIGKILL)
                                    build.wait(timeout=5)
                                raise RuntimeError(f'UI test timed out; inspect {build_log.name}')
                            if returncode:
                                raise RuntimeError(f'UI test failed; inspect {build_log.name}')
                        saved_content = (project / 'hello.txt').read_text()
                        (evidence / f'{device}-saved-file.txt').write_text(saved_content)
                        if marker not in saved_content:
                            raise RuntimeError('The host file did not contain the editor save.')
                        run(['xcrun', 'simctl', 'io', device, 'screenshot', str(evidence / f'{device}.png')])
                        pairing_mode = 'Bonjour discovery, explicit certificate comparison and numeric PIN' if options.discovery else 'Manual HTTPS and numeric PIN'
                        print(f'PASS {device}: {pairing_mode} pairing, file read/write verified on host, closed tabs remain closed after relaunch.', flush=True)
                finally:
                    if publisher is not None and publisher.poll() is None:
                        publisher.send_signal(signal.SIGINT)
                        try:
                            publisher.wait(timeout=3)
                        except subprocess.TimeoutExpired:
                            publisher.kill()
                            publisher.wait(timeout=3)
                    if host.poll() is None:
                        host.send_signal(signal.SIGINT)
                        try:
                            host.wait(timeout=8)
                        except subprocess.TimeoutExpired:
                            host.kill()
                            host.wait(timeout=3)
    finally:
        FIXTURE.write_bytes(original)


if __name__ == '__main__':
    main()
