#!/bin/zsh
# Xcode script phase that runs on every build: fills
# Contents/Resources/ThirdPartyNotices with the files
# scripts/build-desktop-app.sh copied there. A file is written only when its
# content differs and files that are no longer notices are removed, so an
# unchanged build leaves the bundle untouched.
#
# The phase declares only ThirdPartyNotices/README.md as its output, and any
# change here also touches README.md. Xcode re-signs the app when a declared
# output changes; it would not notice the other files and would leave the
# app's sealed resources stale.
set -euo pipefail

macos_dir="${0:A:h:h}"
root="${macos_dir:h}"
destination="${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}/ThirdPartyNotices"

# Later entries win, as the copy order did before.
typeset -A notices
notices[README.md]="$root/desktop/THIRD_PARTY_NOTICES.md"
for file in "$root"/desktop/licenses/*.txt; do
  notices[${file:t}]="$file"
done
# OpenCode is not bundled (the host installs it), so its notice and manifest
# are not here; the phase removes them from an earlier build's bundle.
# iroh's Swift bindings, linked for remote access (shared/AgentLandIroh):
# iroh-ffi's licenses and every crate in the library's graph with the license
# texts it ships (third_party/iroh-ffi, scripts/collect-iroh-ffi-notices.py).
notices[iroh-ffi-LICENSE-MIT.txt]="$root/third_party/iroh-ffi/licenses/LICENSE-MIT"
notices[iroh-ffi-LICENSE-APACHE.txt]="$root/third_party/iroh-ffi/licenses/LICENSE-APACHE"
notices[iroh-ffi-crates.txt]="$root/third_party/iroh-ffi/crate-licenses.txt"
notices[SwiftTerm-LICENSE.txt]="$macos_dir/licenses/SwiftTerm-LICENSE.txt"
# The shared workspace keeps this Mac's copy of the archive with GRDB.
notices[GRDB-LICENSE.txt]="$macos_dir/licenses/GRDB-LICENSE.txt"
notices[HoltwoodOneSC-OFL.txt]="$macos_dir/licenses/HoltwoodOneSC-OFL.txt"

mkdir -p "$destination"
changed=0
for name in ${(k)notices}; do
  if ! cmp -s "${notices[$name]}" "$destination/$name"; then
    cp -f "${notices[$name]}" "$destination/$name"
    changed=1
  fi
done
for existing in "$destination"/*(ND); do
  if (( ! ${+notices[${existing:t}]} )); then
    rm -rf "$existing"
    changed=1
  fi
done
if (( changed )); then
  touch "$destination/README.md"
fi
