#!/bin/sh
set -eu

# Downloads the prebuilt IrohLib.xcframework from the AgentLand GitHub release, so the
# apps build without the pinned Xcode and Rust that scripts/build-iroh-ffi.sh needs.
# The zip's SHA-256 is pinned below, and the unpacked framework must match the
# committed record (third_party/iroh-ffi/IrohLib.sha256) before it is installed into
# shared/AgentLandIroh/Frameworks. The release has Apple-silicon slices only.
#
#   scripts/fetch-iroh-ffi.sh
#
# When scripts/build-iroh-ffi.sh --update-record changes the record, publish the new
# build as a release and update url and zip_sha256 here.

url="https://github.com/sbenson2/AgentLand/releases/download/iroh-ffi-3103bf5/IrohLib.xcframework.zip"
zip_sha256="b71ddd64fb0f3cc6b256cebff7080211fc54f74ef6a976d32f03a994f8719835"

root=$(cd "$(dirname "$0")/.." && pwd)
dest="$root/shared/AgentLandIroh/Frameworks"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

/usr/bin/curl -fsSL --retry 3 -o "$work/IrohLib.xcframework.zip" "$url"
actual=$(/usr/bin/shasum -a 256 "$work/IrohLib.xcframework.zip" | cut -d' ' -f1)
if [ "$actual" != "$zip_sha256" ]; then
  printf 'error: the download has SHA-256 %s, expected %s\n' "$actual" "$zip_sha256" >&2
  exit 1
fi
/usr/bin/ditto -x -k "$work/IrohLib.xcframework.zip" "$work/unpacked"
sh "$root/scripts/verify-iroh-ffi.sh" "$root/third_party/iroh-ffi/IrohLib.sha256" "$work/unpacked/IrohLib.xcframework"
mkdir -p "$dest"
rm -rf "$dest/IrohLib.xcframework"
mv "$work/unpacked/IrohLib.xcframework" "$dest/"
printf 'Installed %s/IrohLib.xcframework\n' "$dest"
