#!/bin/zsh
set -euo pipefail

# Builds AgentLand.app with macos/AgentLandDesktop.xcodeproj (scheme AgentLand,
# Release) and copies it to the given path, default .build/AgentLand.app.
#
# With AGENTLAND_CODE_SIGN_IDENTITY set, Xcode's automatic Apple Development
# signing for team 572969HWXM signs the app and its helper (agentland-host; the
# app bundles no OpenCode, the host installs it), and the build stops unless
# the certificate it used is that identity (a name, part of one, or a SHA-1
# hash, as codesign accepts). Use the same identity for every local
# update so Keychain keeps recognizing the app by its designated requirement.
# The iCloud entitlements need a development provisioning profile, so
# xcodebuild runs with -allowProvisioningUpdates: with the account signed in
# to Xcode it may register the iCloud container, enable iCloud for the App ID
# and create or renew the profile. The profile lists the Macs the app may run
# on, so -allowProvisioningDeviceRegistration lets it add this Mac to the
# team's devices when it is not there yet.
# Without the variable Xcode does not sign, and this script signs the copy
# ad-hoc without the iCloud entitlements (they need a profile; the app then
# keeps CloudKit off): enough for compile and bundle checks, but macOS will
# not let it read the Keychain items of the signed app without asking.
#
# Either way macos/BuildPhases/check-app-bundle.sh checks the copy; for a
# signed copy it builds the expected designated requirement from the bundle ID
# and this identity.
# Notarization and hardened-runtime distribution are a separate release step.

script_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
root_dir="$(cd -- "$script_dir/.." && pwd)"
app_path="${1:-$root_dir/.build/AgentLand.app}"

if [[ -e "$app_path" ]]; then
  print -u2 "Refusing to overwrite existing app bundle: $app_path"
  exit 1
fi

derived_data="$root_dir/.build/xcode/AgentLandDesktop"
log="$root_dir/.build/xcode/build-desktop-app.log"
identity="${AGENTLAND_CODE_SIGN_IDENTITY:-}"
# The bundled host is built for this Mac only. On the command line the
# setting also reaches the Swift packages, which a Release build would
# otherwise compile for both architectures.
settings=(ONLY_ACTIVE_ARCH=YES)
provisioning=()
if [[ -n "$identity" ]]; then
  provisioning=(-allowProvisioningUpdates -allowProvisioningDeviceRegistration)
else
  # AGENTLAND_AD_HOC_COPY tells the check target to leave the unsigned build
  # to the check below.
  settings+=(CODE_SIGNING_ALLOWED=NO AGENTLAND_AD_HOC_COPY=YES)
fi

mkdir -p "${log:h}"
print -u2 "Building AgentLand.app with Xcode; log: $log"
if ! xcodebuild -project "$root_dir/macos/AgentLandDesktop.xcodeproj" -scheme AgentLand \
    -configuration Release -destination "platform=macOS,arch=$(uname -m)" \
    -derivedDataPath "$derived_data" "${provisioning[@]}" "${settings[@]}" build >"$log" 2>&1; then
  grep -E '(error|fatal error):' "$log" | sort -u | tail -n 20 >&2 || true
  print -u2 "xcodebuild failed; see $log"
  exit 1
fi

mkdir -p "$(dirname -- "$app_path")"
# From here on, a failed check removes the copy so it cannot be installed.
checked=0
trap '(( checked )) || { rm -rf "$app_path"; print -u2 "Removed $app_path: it did not pass the checks."; }' EXIT
ditto "$derived_data/Build/Products/Release/AgentLand.app" "$app_path"

if [[ -n "$identity" ]]; then
  leaf="$(codesign -d --verbose=2 "$app_path" 2>&1 | sed -n 's/^Authority=//p' | head -n 1)"
  matches=0
  [[ -n "$leaf" && "$leaf" == *"$identity"* ]] && matches=1
  if (( ! matches )) && [[ ${#identity} -eq 40 && "$identity" != *[^0-9A-Fa-f]* ]]; then
    certificates="$(mktemp -d)"
    codesign -d --extract-certificates="$certificates/certificate" "$app_path" 2>/dev/null
    leaf_sha1="$(shasum -a 1 "$certificates/certificate0" | cut -d ' ' -f 1)"
    rm -rf "$certificates"
    [[ "${(U)leaf_sha1}" == "${(U)identity}" ]] && matches=1
  fi
  if (( ! matches )); then
    print -u2 "Xcode signed $app_path as \"$leaf\", not with AGENTLAND_CODE_SIGN_IDENTITY \"$identity\"."
    exit 1
  fi
else
  # An ad-hoc signature cannot carry entitlements that need a provisioning
  # profile (com.apple.developer.*, here iCloud): the app would not launch.
  # Sign without them; a profile left from an earlier signed build goes too.
  ad_hoc_entitlements="$(mktemp -d)/AgentLandDesktop.entitlements"
  python3 - "$root_dir/macos/AgentLandDesktop.entitlements" "$ad_hoc_entitlements" <<'PY'
import plistlib
import sys
from pathlib import Path

committed = plistlib.loads(Path(sys.argv[1]).read_bytes())
kept = {key: value for key, value in committed.items() if not key.startswith("com.apple.developer.")}
Path(sys.argv[2]).write_bytes(plistlib.dumps(kept))
PY
  rm -f "$app_path/Contents/embedded.provisionprofile"
  codesign --force --sign - --identifier dev.agentland.desktop.host "$app_path/Contents/MacOS/agentland-host"
  codesign --force --sign - --entitlements "$ad_hoc_entitlements" "$app_path"
  rm -rf "${ad_hoc_entitlements:h}"
fi

"$root_dir/macos/BuildPhases/check-app-bundle.sh" "$app_path" "$identity" >&2
checked=1
print "$app_path"
