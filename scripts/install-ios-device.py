#!/usr/bin/env python3
"""Verify, and with --install update in place, AgentLand on an owner device.

Checks the build's signature, team, provisioning profile and packaged branding
resources against the source tree. With --install it records the device's saved
pairing and app-lock preferences, installs and launches the app, and fails if
those preferences changed. It refuses a device with no saved connection, so it
never replaces a fresh or test installation by accident.

    scripts/install-ios-device.py --app <Debug-iphoneos/AgentLand.app> --device <UDID> --pass <pass> [--install]
"""
from pathlib import Path
import argparse, datetime, fnmatch, hashlib, json, plistlib, subprocess, tempfile

ROOT = Path(__file__).resolve().parent.parent
BUNDLE = 'dev.agentland.client'
TEAM = '572969HWXM'
RESOURCES = ROOT / 'shared/AgentLandBranding/Sources/AgentLandBranding/Resources'


def run(args, timeout=45):
    result = subprocess.run(args, capture_output=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError(f'{args[0]} failed ({result.returncode}): {result.stderr.decode(errors="replace")[-1500:]}')
    return result


def digest(data):
    return hashlib.sha256(data).hexdigest()


def preferences(device):
    with tempfile.TemporaryDirectory(prefix='agentland-device-') as temporary:
        destination = Path(temporary) / 'preferences.plist'
        run(['xcrun', 'devicectl', '--timeout', '30', 'device', 'copy', 'from', '--device', device,
             '--domain-type', 'appDataContainer', '--domain-identifier', BUNDLE,
             '--source', f'Library/Preferences/{BUNDLE}.plist', '--destination', str(destination)])
        prefs = plistlib.loads(destination.read_bytes())
        hosts = json.loads(prefs.get('agentland.connections.v1', b'[]'))
        return dict(hasSavedConnection=bool(hosts),
                    canonicalConnectionsDigest=digest(json.dumps(hosts, sort_keys=True, separators=(',', ':')).encode()),
                    selectedConnectionDigest=digest(prefs.get('agentland.selected-connection.v1', '').encode()),
                    lockEnabled=bool(prefs.get('agentland.lock.enabled', False)))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--app', required=True)
    parser.add_argument('--device', required=True)
    parser.add_argument('--pass', dest='pass_name', required=True)
    parser.add_argument('--install', action='store_true')
    args = parser.parse_args()
    app = Path(args.app).resolve()
    out = ROOT / f'.evidence/{args.pass_name}/device-{args.device[:8]}'
    out.mkdir(parents=True, exist_ok=True)

    def save(name, value):
        (out / name).write_text(json.dumps(value, indent=2) + '\n')

    info = plistlib.loads((app / 'Info.plist').read_bytes())
    assert info['CFBundleIdentifier'] == BUNDLE
    run(['codesign', '--verify', '--deep', '--strict', str(app)])
    signature = run(['codesign', '-d', '--verbose=4', str(app)]).stderr.decode()
    assert f'TeamIdentifier={TEAM}' in signature
    entitlements = plistlib.loads(run(['codesign', '-d', '--entitlements', ':-', str(app)]).stdout)
    assert entitlements['application-identifier'] == f'{TEAM}.{BUNDLE}'
    profile = plistlib.loads(run(['security', 'cms', '-D', '-i', str(app / 'embedded.mobileprovision')]).stdout)
    assert TEAM in profile['TeamIdentifier']
    assert fnmatch.fnmatchcase(entitlements['application-identifier'], profile['Entitlements']['application-identifier'])
    assert profile['ExpirationDate'].replace(tzinfo=datetime.timezone.utc) > datetime.datetime.now(datetime.timezone.utc)
    packaged_bundle = app / 'AgentLandBranding_AgentLandBranding.bundle'
    resources = {}
    for source in sorted(p for p in RESOURCES.rglob('*') if p.is_file()):
        relative = source.relative_to(RESOURCES)
        packaged = packaged_bundle / relative
        if not packaged.exists():
            packaged = packaged_bundle / relative.name  # resources may be flattened when processed
        assert packaged.read_bytes() == source.read_bytes(), str(relative)
        resources[str(relative)] = digest(source.read_bytes())
    artifact = dict(bundleID=BUNDLE, version=info['CFBundleShortVersionString'], build=info['CFBundleVersion'],
                    signatureVerified=True, teamIdentifier=TEAM, device=args.device, resources=resources,
                    executableSHA256=digest((app / info['CFBundleExecutable']).read_bytes()))
    save('artifact.json', artifact)
    if not args.install:
        print(json.dumps({'signingVerified': True, 'resourcesMatched': len(resources), 'executableSHA256': artifact['executableSHA256']}))
        return
    before = preferences(args.device)
    assert before['hasSavedConnection'], 'Refuse a fixture/reset installation on an owner device'
    save('pairing-before.json', before)
    result = run(['xcrun', 'devicectl', '--timeout', '120', 'device', 'install', 'app', '--device', args.device,
                  '--json-output', str(out / 'install.json'), str(app)], timeout=150)
    (out / 'install.log').write_bytes(result.stdout + result.stderr)
    launched = True
    try:
        result = run(['xcrun', 'devicectl', '--timeout', '30', 'device', 'process', 'launch', '--device', args.device,
                      '--terminate-existing', '--json-output', str(out / 'launch.json'), BUNDLE], timeout=45)
        (out / 'launch.log').write_bytes(result.stdout + result.stderr)
    except RuntimeError as error:
        # A locked device refuses launches; the installation itself still succeeded.
        launched = False
        (out / 'launch.log').write_text(str(error))
    after = preferences(args.device)
    save('pairing-after.json', after)
    assert before == after, 'Saved pairing or lock preference changed across installation'
    result = dict(deviceInstalled=True, launched=launched, pairingAndLockSettingPreserved=True,
                  signingVerified=True, sourceResourcesMatched=len(resources),
                  device=args.device, executableSHA256=artifact['executableSHA256'])
    save('verification.json', result)
    print(json.dumps(result))


if __name__ == '__main__':
    main()
