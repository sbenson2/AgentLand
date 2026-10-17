#!/bin/zsh
# Gate for a built AgentLand.app. The AgentLandBundleCheck target runs it after
# Xcode has signed the app; scripts/build-desktop-app.sh runs it on the copy it
# hands out.
#
#   1. codesign --verify --deep --strict passes.
#   2. A signed app's designated requirement is exactly the one Xcode gives
#      an Apple Development certificate, built here from the bundle ID and
#      the identity the build signed with: identifier dev.agentland.desktop,
#      anchor apple generic, the leaf certificate's subject CN equal to that
#      identity's name, and the Apple WWDR intermediate. Keychain items (the
#      provider keys and legacy external-service passwords) trust the app by
#      that requirement, so a build signed by anything else fails. The
#      identity is the second argument, else EXPANDED_CODE_SIGN_IDENTITY_NAME,
#      else AGENTLAND_CODE_SIGN_IDENTITY; with none the check fails. An ad-hoc
#      build cannot carry the requirement and skips only this comparison.
#   3. agentland-host is signed as dev.agentland.desktop.host by the same team
#      as the app. No opencode is bundled anywhere in the app (the host
#      installs and updates OpenCode), and no iroh-relay is (the Mac runs no
#      relay; remote access links iroh's library and uses n0's public relays
#      only as an opt-in fallback).
#   4. Info.plist has every key and value of macos/Resources/Info.plist, plus
#      at most the build-environment keys Xcode records (DT*, ...).
#   5. The signed entitlements are macos/AgentLandDesktop.entitlements:
#      - signed by the team: plus the two keys Xcode adds from the
#        provisioning profile (com.apple.application-identifier
#        572969HWXM.dev.agentland.desktop and com.apple.developer.team-identifier
#        572969HWXM) and, if present, com.apple.developer.icloud-container-environment;
#      - ad-hoc: without the com.apple.developer.* keys, which need a
#        provisioning profile (the app then keeps CloudKit off).
#   6. When the entitlements need a profile, Contents/embedded.provisionprofile
#      is for team 572969HWXM and this app ID, grants the iCloud containers and
#      services, holds the signing certificate, lists this Mac's provisioning
#      UDID and has not expired. Its expiry date is printed: past it, or on a
#      Mac it does not list, the app does not launch.
set -euo pipefail

app="${1:?usage: check-app-bundle.sh path/to/AgentLand.app [signing-identity]}"
# The identity the build signed with, as codesign accepts it: a certificate
# name, part of one, or the certificate's SHA-1 hash. The AgentLandBundleCheck
# target passes the name the app target recorded; scripts/build-desktop-app.sh
# passes AGENTLAND_CODE_SIGN_IDENTITY.
identity="${2:-${EXPANDED_CODE_SIGN_IDENTITY_NAME:-${AGENTLAND_CODE_SIGN_IDENTITY:-}}}"
macos_dir="${0:A:h:h}"
bundle_id=dev.agentland.desktop
expected_team=572969HWXM
fail() {
  print -u2 "error: AgentLand bundle check: $1"
  exit 1
}

# Without an identity, scripts/build-desktop-app.sh turns Xcode's signing off
# (CODE_SIGNING_ALLOWED=NO) and sets AGENTLAND_AD_HOC_COPY=YES. The app in the
# build folder is then not signed as a whole (it can keep a stale seal from an
# earlier signed build), so the check runs on the copy the wrapper signs
# ad-hoc instead.
if [[ -n "${ACTION:-}" && "${AGENTLAND_AD_HOC_COPY:-}" == YES ]]; then
  print "note: Xcode signing is off for this build; scripts/build-desktop-app.sh checks its ad-hoc signed copy."
  exit 0
fi

[[ -d "$app/Contents" ]] || fail "$app is not an app bundle"
python3 - "$app/Contents/Resources/AgentLandWeb" <<'PY'
import hashlib, json, pathlib, sys
root = pathlib.Path(sys.argv[1])
record = json.loads((root / 'integrity.json').read_text())
assert 'index.html' in record and 'THIRD_PARTY_NOTICES.txt' in record, 'Incomplete web workspace'
actual = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
          for p in root.rglob('*') if p.is_file() and p.name != 'integrity.json'}
assert actual == record, 'Packaged web assets differ from their build record'
assert not any(p.is_symlink() for p in root.rglob('*')), 'Web assets must not contain symlinks'
print(f'Packaged web workspace: {len(record)} matching assets')
PY
# Do not infer the embedded compiler from the build machine or a stale stamp.
python3 "$macos_dir/../scripts/check-go-toolchain.py" --binary "$app/Contents/MacOS/agentland-host" || fail "embedded helper toolchain is below desktop/go.mod's minimum"
codesign --verify --deep --strict "$app" || fail "codesign --verify --deep --strict failed for $app"

# Prints one "Name=value" field of codesign's description of the code at a path.
signature_field() { # name, code path
  local details
  details="$(codesign -d --verbose=2 "$2" 2>&1)" || return 1
  print -r -- "$details" | sed -n "s/^$1=//p"
}

team="$(signature_field TeamIdentifier "$app")" || fail "$app is not signed"
signature=team
if [[ "$(signature_field Signature "$app")" == adhoc ]]; then
  signature=adhoc
  print "note: $app is ad-hoc signed, so its designated requirement is not compared."
else
  [[ "$team" == "$expected_team" ]] || fail "$app is signed by team $team, not $expected_team"
  [[ -n "$identity" ]] ||
    fail "cannot tell which identity should have signed $app, so its designated requirement cannot be checked.
  Pass the identity as the second argument or set AGENTLAND_CODE_SIGN_IDENTITY (a certificate name, part of one,
  or its SHA-1 hash). In Xcode the AgentLand target records it in DerivedSources/signing-identity."
  leaf="${${(f)"$(signature_field Authority "$app")"}[1]}"
  if [[ ${#identity} -eq 40 && "$identity" != *[^0-9A-Fa-f]* ]]; then
    # A hash names one certificate: it must be the one that signed the app.
    certificates="$(mktemp -d)"
    codesign -d --extract-certificates="$certificates/certificate" "$app" 2>/dev/null
    leaf_sha1="$(shasum -a 1 "$certificates/certificate0" | cut -d ' ' -f 1)"
    rm -rf "$certificates"
    [[ "${(U)leaf_sha1}" == "${(U)identity}" ]] ||
      fail "$app is signed with certificate $leaf_sha1 (\"$leaf\"), not the build's identity $identity"
    signer="$leaf"
  else
    # A name or part of one, resolved the way codesign does: the valid
    # code-signing identities in the keychain whose name contains it.
    names=("${(@fu)$(security find-identity -v -p codesigning |
      sed -n 's/^ *[0-9][0-9]*) [0-9A-Fa-f]\{40\} "\(.*\)"$/\1/p')}")
    if (( ${names[(Ie)$identity]} )); then
      signer="$identity"
    else
      matches=("${(@M)names:#*"$identity"*}")
      (( ${#matches} == 1 )) ||
        fail "the build's signing identity \"$identity\" matches ${#matches} valid code-signing identities in the keychain, not one${matches:+: ${(j:, :)matches}}"
      signer="${matches[1]}"
    fi
  fi
  expected="designated => identifier \"$bundle_id\" and anchor apple generic and certificate leaf[subject.CN] = \"$signer\" and certificate 1[field.1.2.840.113635.100.6.2.1] /* exists */"
  actual="$(codesign -d -r- "$app" 2>/dev/null)"
  [[ "$actual" == "$expected" ]] ||
    fail "the designated requirement is not the one for the build's identity; Keychain items would not trust the app.
  built:    $actual
  expected: $expected"
fi

for helper identifier in agentland-host dev.agentland.desktop.host; do
  # Not "path": zsh ties that name to PATH.
  helper_path="$app/Contents/MacOS/$helper"
  [[ -f "$helper_path" ]] || fail "Contents/MacOS/$helper is missing"
  helper_identifier="$(signature_field Identifier "$helper_path")" || fail "Contents/MacOS/$helper is not signed"
  [[ "$helper_identifier" == "$identifier" ]] ||
    fail "Contents/MacOS/$helper is signed as $helper_identifier, not $identifier"
  [[ "$(signature_field TeamIdentifier "$helper_path")" == "$team" ]] ||
    fail "Contents/MacOS/$helper is not signed by the app's team ($team)"
done
[[ ! -e "$app/Contents/MacOS/iroh-relay" ]] || fail "Contents/MacOS/iroh-relay is bundled; the Mac runs no relay"
bundled_opencode="$(find "$app" -name opencode -print -quit)"
[[ -z "$bundled_opencode" ]] ||
  fail "${bundled_opencode#$app/} is bundled; the host installs and updates OpenCode, the app bundles none"

python3 - "$app" "$macos_dir" "$signature" "$expected_team" <<'PY'
import datetime
import plistlib
import subprocess
import sys
import tempfile
from pathlib import Path

app, macos, signature, team = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3], sys.argv[4]
bundle_id = "dev.agentland.desktop"


def fail(message):
    sys.exit(f"error: AgentLand bundle check: {message}")


# Xcode's Info.plist processing records the SDK, Xcode and build machine.
xcode_keys = {"BuildMachineOSBuild", "CFBundleSupportedPlatforms", "DTCompiler", "DTPlatformBuild",
              "DTPlatformName", "DTPlatformVersion", "DTSDKBuild", "DTSDKName", "DTXcode", "DTXcodeBuild"}
expected = plistlib.loads((macos / "Resources/Info.plist").read_bytes())
built = plistlib.loads((app / "Contents/Info.plist").read_bytes())
different = sorted(key for key in expected if built.get(key) != expected[key])
unexpected = sorted(set(built) - set(expected) - xcode_keys)
if different or unexpected:
    fail(f"Info.plist differs from macos/Resources/Info.plist (changed or missing: {different}, unexpected: {unexpected})")

signed_xml = subprocess.run(["codesign", "-d", "--entitlements", "-", "--xml", str(app)],
                            capture_output=True, check=True).stdout
signed = plistlib.loads(signed_xml) if signed_xml.strip() else {}
committed = plistlib.loads((macos / "AgentLandDesktop.entitlements").read_bytes())
# Entitlements in the com.apple.developer namespace need a provisioning profile.
needs_profile = {key for key in committed if key.startswith("com.apple.developer.")}
environment_key = "com.apple.developer.icloud-container-environment"
if signature == "adhoc":
    wanted = {key: value for key, value in committed.items() if key not in needs_profile}
else:
    wanted = dict(committed)
    if needs_profile:
        wanted["com.apple.application-identifier"] = f"{team}.{bundle_id}"
        wanted["com.apple.developer.team-identifier"] = team
        if environment_key in signed and environment_key not in committed:
            if signed[environment_key] not in ("Development", "Production"):
                fail(f"unexpected {environment_key} {signed[environment_key]!r}")
            wanted[environment_key] = signed[environment_key]
if signed != wanted:
    fail(f"signed entitlements {signed} differ from the expected {wanted} "
         f"(macos/AgentLandDesktop.entitlements, {signature} signature)")

profile_path = app / "Contents/embedded.provisionprofile"
if signature == "adhoc" or not needs_profile:
    if profile_path.exists():
        fail(f"{profile_path.name} is in a build that needs no provisioning profile")
    sys.exit(0)

if not profile_path.is_file():
    fail("Contents/embedded.provisionprofile is missing; the iCloud entitlements need a provisioning profile")
# The profile is a signed CMS message around a property list; the system
# checks the signature at launch, this checks the content.
raw = profile_path.read_bytes()
start, end = raw.find(b"<?xml"), raw.rfind(b"</plist>")
if start < 0 or end < 0:
    fail("Contents/embedded.provisionprofile holds no property list")
profile = plistlib.loads(raw[start:end + len(b"</plist>")])
granted = profile.get("Entitlements", {})
name = profile.get("Name", "?")
if team not in profile.get("TeamIdentifier", []):
    fail(f"the provisioning profile {name!r} is for team {profile.get('TeamIdentifier')}, not {team}")
if "OSX" not in profile.get("Platform", []):
    fail(f"the provisioning profile {name!r} is not for macOS ({profile.get('Platform')})")
identifier = granted.get("com.apple.application-identifier") or granted.get("application-identifier")
if identifier not in (f"{team}.{bundle_id}", f"{team}.*"):
    fail(f"the provisioning profile {name!r} is for app ID {identifier}, not {team}.{bundle_id}")
for key in sorted(needs_profile):
    have = granted.get(key)
    have = have if isinstance(have, list) else [have]
    for value in committed[key] if isinstance(committed[key], list) else [committed[key]]:
        if value not in have and "*" not in have:
            fail(f"the provisioning profile {name!r} does not grant {key} {value!r} (it grants {granted.get(key)})")

with tempfile.TemporaryDirectory() as directory:
    subprocess.run(["codesign", "-d", f"--extract-certificates={directory}/certificate", str(app)],
                   capture_output=True, check=True)
    leaf = Path(directory, "certificate0").read_bytes()
if leaf not in [bytes(certificate) for certificate in profile.get("DeveloperCertificates", [])]:
    fail(f"the provisioning profile {name!r} does not include the certificate that signed the app")

hardware = subprocess.run(["system_profiler", "SPHardwareDataType"], capture_output=True, text=True, check=True).stdout
udid = next((line.split(":", 1)[1].strip() for line in hardware.splitlines() if "Provisioning UDID" in line), None)
if not profile.get("ProvisionsAllDevices"):
    if not udid:
        fail("this Mac's provisioning UDID could not be read (system_profiler SPHardwareDataType)")
    if udid not in profile.get("ProvisionedDevices", []):
        fail(f"the provisioning profile {name!r} does not list this Mac ({udid}); the app would not launch here")

expires = profile.get("ExpirationDate")
now = datetime.datetime.now(datetime.timezone.utc)
if expires is None:
    fail(f"the provisioning profile {name!r} has no expiry date")
if expires.tzinfo is None:
    expires = expires.replace(tzinfo=datetime.timezone.utc)
if expires <= now:
    fail(f"the provisioning profile {name!r} expired on {expires:%Y-%m-%d %H:%M} UTC")
environment = signed.get(environment_key, "Development (default)")
print(f"provisioning profile: {name!r} {profile.get('UUID')}, team {team}, this Mac {udid} listed, "
      f"iCloud {environment}, expires {expires:%Y-%m-%d %H:%M} UTC ({(expires - now).days} days)")
PY

print "AgentLand bundle check passed: $app (team ${team})"
