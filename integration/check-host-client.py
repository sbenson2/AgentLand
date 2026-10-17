#!/usr/bin/env python3
"""Bounded integration check. Uses disposable state/certs, no real agent/model calls."""
import os
from pathlib import Path
import secrets
import signal
import socket
import subprocess
import tempfile
import time
import urllib.request
import ssl

root = Path(__file__).resolve().parents[1]
def run(args, cwd=None, env=None):
    result = subprocess.run(args, cwd=cwd, env=env, capture_output=True, text=True, timeout=240)
    if result.returncode:
        # Do not echo command arguments: pairing codes may be present.
        raise RuntimeError(result.stderr[-4000:] or result.stdout[-4000:])
    return result.stdout.strip()

with tempfile.TemporaryDirectory(prefix='agentland-integration-') as temporary:
    temp = Path(temporary)
    binary = temp/'agentland-host'
    run(['go', 'build', '-o', str(binary), './cmd/agentland-host'], root/'desktop')
    package = root/'integration/SwiftHostProbe'
    run(['swift', 'build', '--package-path', str(package)])
    binpath = Path(run(['swift', 'build', '--package-path', str(package), '--show-bin-path']))/'SwiftHostProbe'
    import json
    tls = json.loads(run([str(binary),'tls','init','--directory',str(temp/'tls'),'--hosts','localhost']))
    cert, key = Path(tls['certificateFile']), Path(tls['keyFile'])
    der, state = temp/'cert.der', temp/'host.json'
    run(['openssl','x509','-in',str(cert),'-outform','DER','-out',str(der)])
    project = temp/'project'; project.mkdir()
    (project/'hello.txt').write_text('Hello from the desktop\n')
    run([str(binary),'init','--state',str(state),'--project',f'fixture=Fixture={project}'])
    code = run([str(binary),'pair','--pin','--state',str(state)])
    with socket.socket() as s:
        s.bind(('127.0.0.1',0)); port=s.getsockname()[1]
    env = os.environ.copy(); env['AGENTLAND_OPENCODE_PASSWORD'] = secrets.token_urlsafe(32)
    env['AGENTLAND_TEST_LOCAL_TOKEN'] = secrets.token_urlsafe(32)
    with (temp/'host.log').open('w') as log:
        host = subprocess.Popen([str(binary),'serve','--state',str(state),'--listen',f'127.0.0.1:{port}','--cert',str(cert),'--key',str(key),'--local-session-env','AGENTLAND_TEST_LOCAL_TOKEN','--workspace-home',str(temp),'--no-agents'], env=env, stdout=log, stderr=log)
        try:
            address=f'https://localhost:{port}'
            context=ssl.create_default_context(cafile=str(cert))
            deadline=time.monotonic()+15
            while True:
                if host.poll() is not None: raise RuntimeError('fixture host exited before readiness')
                try:
                    with urllib.request.urlopen(address+'/v1/health',context=context,timeout=1) as response:
                        if response.status==200: break
                except (OSError, urllib.error.URLError):
                    if time.monotonic()>deadline: raise RuntimeError('fixture host readiness timeout')
                    time.sleep(.1)
            print(run([str(binpath),address,str(der),code,str(binary),str(state)], env=env))
        finally:
            if host.poll() is None:
                host.send_signal(signal.SIGINT)
                try: host.wait(timeout=8)
                except subprocess.TimeoutExpired: host.kill(); host.wait(timeout=3)
