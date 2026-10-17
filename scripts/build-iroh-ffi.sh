#!/bin/bash
set -euo pipefail

# Builds AgentLand's copy of iroh's Swift bindings from pinned source:
#
#   shared/AgentLandIroh/Frameworks/IrohLib.xcframework   iOS arm64, iOS simulator arm64, macOS arm64
#   shared/AgentLandIroh/Sources/IrohLib/IrohLib.swift    the generated Swift wrapper (committed)
#   shared/AgentLandIroh/Frameworks/IrohLib.build.txt     versions and SHA-256 of inputs and outputs
#   shared/AgentLandIroh/Frameworks/iroh-relay            release relay binary for the package tests
#   third_party/iroh-ffi/crates.tsv                       crates in the library's graph (committed)
#
# It fetches n0-computer/iroh-ffi at the pinned commit, checks the commit, applies
# third_party/iroh-ffi/patches/*.patch in order and builds with the pinned Rust
# toolchain and the patched Cargo.lock (--locked). See third_party/iroh-ffi/README.md.
#
# The new xcframework must match the committed record third_party/iroh-ffi/IrohLib.sha256
# (scripts/verify-iroh-ffi.sh) before it replaces the one in Frameworks/; the package's
# VerifyIrohLib plugin checks the installed one against the same record before anything
# links it. After a deliberate change (the pin, a patch, the toolchain), rebuild with
# --update-record and commit the record with the change.
#
# The record holds for one toolchain: the Rust and Xcode versions pinned below. The
# libraries embed the Xcode compiler's version (C and assembly in ring and blake3), so
# another Xcode builds other bytes. The script stops before building when the selected
# Xcode (xcode-select, or DEVELOPER_DIR) is not the pinned one, with --update-record too,
# and compiles C with that Xcode's clang and SDKs whatever cc is on PATH or SDKROOT says.
# Where the Xcode is installed is not embedded, and its path may contain spaces.
#
# The toolchain is looked up in $RUSTUP_HOME (default ~/.rustup) and on PATH; it does
# not have to be on PATH. Missing rust-std targets are added with rustup when rustup
# exists, otherwise downloaded from static.rust-lang.org and checked against the
# SHA-256 in the toolchain's own channel manifest before they are installed.
#
# Work files (source checkout, cargo target directory) go to $AGENTLAND_IROH_WORK,
# default ~/Library/Caches/AgentLand/iroh-ffi, which every checkout and worktree shares.
# A run holds $AGENTLAND_IROH_WORK/.build-lock from start to end (shlock; a lock left by
# a process that is gone is taken over), so another checkout's run never changes the
# source while this one builds it; a second run waits up to $AGENTLAND_IROH_LOCK_WAIT
# seconds (default 3600). Crates are downloaded into $CARGO_HOME (default ~/.cargo).
# Nothing is installed besides the rust-std targets.
#
# Options:
#   --skip-relay      do not fetch the iroh-relay test binary
#   --update-record   write third_party/iroh-ffi/IrohLib.sha256 from this build instead
#                     of requiring the build to match it, and list the files that changed
#   --check-xcode     only check that the selected Xcode is the pinned one, then exit

upstream_url="https://github.com/n0-computer/iroh-ffi.git"
upstream_commit="3103bf5295be6d50c5272ff7a426e9b539f3f587"
rust_version="1.94.1"
targets="aarch64-apple-ios aarch64-apple-ios-sim aarch64-apple-darwin"
ios_deployment_target="26.0"
macos_deployment_target="26.0"
relay_url="https://github.com/n0-computer/iroh/releases/download/v1.2.0/iroh-relay-v1.2.0-aarch64-apple-darwin.tar.gz"
relay_sha256="ed0932770fcdd0ae862d94b8657c55311c429f17aa84b5614367d43445853602"
# The Xcode the record was made with, and the clang it has.
xcode_version="26.6"
xcode_build="17F113"
xcode_clang="Apple clang version 21.0.0 (clang-2100.1.1.101)"

fetch_relay=1
update_record=0
check_only=0
for arg in "$@"; do
  case "$arg" in
    --skip-relay) fetch_relay=0 ;;
    --update-record) update_record=1 ;;
    --check-xcode) check_only=1 ;;
    *) echo "usage: $0 [--skip-relay] [--update-record] [--check-xcode]" >&2; exit 64 ;;
  esac
done

started=$(date +%s)
script_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
root_dir="$(cd -- "$script_dir/.." && pwd)"
patch_dir="$root_dir/third_party/iroh-ffi/patches"
package_dir="$root_dir/shared/AgentLandIroh"
out_dir="$package_dir/Frameworks"
wrapper="$package_dir/Sources/IrohLib/IrohLib.swift"
record_file="$root_dir/third_party/iroh-ffi/IrohLib.sha256"
work="${AGENTLAND_IROH_WORK:-$HOME/Library/Caches/AgentLand/iroh-ffi}"
src="$work/src"
export CARGO_TARGET_DIR="$work/target"
export CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}"
rustup_home="${RUSTUP_HOME:-$HOME/.rustup}"

say() { printf '==> %s\n' "$*"; }
fail() { printf 'build-iroh-ffi: %s\n' "$*" >&2; exit 1; }
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }

# --- Xcode ----------------------------------------------------------------------

# Before the lock and the work directory: a Mac with another Xcode stops here at once.
xcode_help="third_party/iroh-ffi/IrohLib.sha256 matches only libraries built with Xcode $xcode_version ($xcode_build): they embed its compiler's version. Select that Xcode with DEVELOPER_DIR=<Xcode.app>/Contents/Developer or xcode-select -s. To move to another Xcode on purpose, change xcode_version, xcode_build and xcode_clang in $0, rebuild with --update-record and commit the script and the record together."
# Every xcrun lookup (here and cc-rs's) answers for the selected Xcode, not from xcrun's cache.
export xcrun_nocache=1
developer_dir=$(xcode-select -p 2>/dev/null || true)
xcode_info=$(xcodebuild -version 2>/dev/null || true)
found_version=$(printf '%s\n' "$xcode_info" | sed -n 's/^Xcode //p')
found_build=$(printf '%s\n' "$xcode_info" | sed -n 's/^Build version //p')
if [ -z "$found_version" ]; then
  fail "this build needs Xcode $xcode_version ($xcode_build); the selected developer directory ${developer_dir:-(none)} is not an Xcode. $xcode_help"
fi
if [ "$found_version" != "$xcode_version" ] || [ "$found_build" != "$xcode_build" ]; then
  fail "this build needs Xcode $xcode_version ($xcode_build); the selected developer directory ${developer_dir:-(none)} is Xcode $found_version ($found_build). $xcode_help"
fi
xcode_cc=$(xcrun --find clang 2>/dev/null || true)
found_clang=$([ -n "$xcode_cc" ] && "$xcode_cc" --version 2>/dev/null | head -n 1 || true)
if [ "$found_clang" != "$xcode_clang" ]; then
  fail "Xcode $xcode_version ($xcode_build) should compile with $xcode_clang, but ${xcode_cc:-the clang xcrun finds} reports ${found_clang:-nothing}. $xcode_help"
fi
say "Xcode: $xcode_version ($xcode_build), $found_clang, at $developer_dir"
# Where this Xcode is, which the libraries must not embed: as xcrun names it in the clang and
# SDK paths the compiler gets, and resolved, as clang names its own headers (for an Xcode under
# /private/tmp xcrun says /tmp).
xcode_root=${xcode_cc%/Toolchains/*}
xcode_root_resolved=$(cd "$xcode_root" && pwd -P)
[ $check_only = 0 ] || exit 0

# --- Lock -----------------------------------------------------------------------

mkdir -p "$work"
lockfile="$work/.build-lock"
lock_wait="${AGENTLAND_IROH_LOCK_WAIT:-3600}"
waited=0
until /usr/bin/shlock -f "$lockfile" -p $$; do
  if [ $waited = 0 ]; then
    say "Waiting for the build holding $lockfile (pid $(cat "$lockfile" 2>/dev/null || echo '?')); set AGENTLAND_IROH_WORK to build elsewhere"
  fi
  [ $waited -lt "$lock_wait" ] || fail "another build held $lockfile for $lock_wait s"
  sleep 5
  waited=$((waited + 5))
done
trap 'rm -f "$lockfile"' EXIT

# --- Rust toolchain -------------------------------------------------------------

toolchain=""
for candidate in "$rustup_home"/toolchains/*; do
  [ -x "$candidate/bin/rustc" ] || continue
  if "$candidate/bin/rustc" --version | grep -q "^rustc $rust_version "; then
    toolchain="$candidate"
    break
  fi
done
if [ -z "$toolchain" ] && command -v rustc >/dev/null 2>&1; then
  if rustc --version | grep -q "^rustc $rust_version "; then
    toolchain="$(rustc --print sysroot)"
  fi
fi
[ -n "$toolchain" ] || fail "Rust $rust_version not found in $rustup_home/toolchains or on PATH"
export PATH="$toolchain/bin:$PATH"
export RUSTC="$toolchain/bin/rustc"
cargo="$toolchain/bin/cargo"
say "Rust: $("$RUSTC" --version) at $toolchain"

rustlib="$toolchain/lib/rustlib"
for target in $targets; do
  [ -d "$rustlib/$target/lib" ] && continue
  if command -v rustup >/dev/null 2>&1; then
    say "Adding target $target with rustup"
    rustup target add --toolchain "$(basename "$toolchain")" "$target"
    continue
  fi
  say "Adding target $target from the toolchain's channel manifest"
  manifest="$rustlib/multirust-channel-manifest.toml"
  [ -f "$manifest" ] || fail "no channel manifest at $manifest to verify rust-std-$target"
  read -r url hash < <(python3 - "$manifest" "$target" <<'EOF'
import sys, tomllib
package = tomllib.load(open(sys.argv[1], "rb"))["pkg"]["rust-std"]["target"][sys.argv[2]]
print(package["xz_url"], package["xz_hash"])
EOF
)
  download="$work/downloads/$(basename "$url")"
  mkdir -p "$work/downloads"
  [ -f "$download" ] || curl -fsSL -o "$download" "$url"
  [ "$(sha "$download")" = "$hash" ] || { rm -f "$download"; fail "SHA-256 mismatch for $url"; }
  unpacked="$work/downloads/rust-std-$target"
  rm -rf "$unpacked"; mkdir -p "$unpacked"
  tar -xJf "$download" -C "$unpacked"
  had_log=0; [ -e "$rustlib/install.log" ] && had_log=1
  had_uninstall=0; [ -e "$rustlib/uninstall.sh" ] && had_uninstall=1
  /bin/sh "$unpacked"/rust-std-*/install.sh --prefix="$toolchain" --disable-ldconfig
  [ $had_log = 1 ] || rm -f "$rustlib/install.log"
  [ $had_uninstall = 1 ] || rm -f "$rustlib/uninstall.sh"
  # Keep rustup's own component list in step, so a later rustup sees the target.
  if [ -f "$rustlib/multirust-config.toml" ]; then
    printf '\n[[components]]\npkg = "rust-std"\ntarget = "%s"\nis_extension = false\n' "$target" >> "$rustlib/multirust-config.toml"
  fi
  rm -rf "$unpacked"
done

# --- Source ---------------------------------------------------------------------

if [ -d "$src/.git" ] && [ "$(git -C "$src" rev-parse HEAD 2>/dev/null)" = "$upstream_commit" ]; then
  say "Reusing checkout of $upstream_commit"
  git -C "$src" reset -q --hard
  git -C "$src" clean -q -fdx
else
  say "Fetching $upstream_url at $upstream_commit"
  rm -rf "$src"
  git init -q "$src"
  git -C "$src" fetch -q --depth 1 "$upstream_url" "$upstream_commit"
  git -C "$src" checkout -q --detach FETCH_HEAD
fi
[ "$(git -C "$src" rev-parse HEAD)" = "$upstream_commit" ] || fail "checkout is not $upstream_commit"

patches=("$patch_dir"/*.patch)
[ -e "${patches[0]}" ] || fail "no patches in $patch_dir"
for patch in "${patches[@]}"; do
  say "Applying $(basename "$patch")"
  git -C "$src" apply --whitespace=nowarn "$patch"
done
# What was built: the patched tree as one diff against the pinned commit.
git -C "$src" add -A
source_sha256=$(git -C "$src" diff --cached --binary | shasum -a 256 | cut -d' ' -f1)

# iroh's port mapper (UPnP, PCP, NAT-PMP) must not be compiled in; see patch 0001.
if grep -qE '^name = "(portmapper|igd-next)"$' "$src/Cargo.lock"; then
  fail "the patched Cargo.lock still has a port mapper crate (portmapper or igd-next)"
fi

# --- Build ----------------------------------------------------------------------

# Same path normalization as upstream's make_swift.sh, so the libraries do not embed
# this machine's paths.
rustflags=(
  "--remap-path-prefix=$CARGO_HOME/registry=/cargo/registry"
  "--remap-path-prefix=$CARGO_HOME/git=/cargo/git"
  "--remap-path-prefix=$rustup_home=/rustup"
  "--remap-path-prefix=$src=/build"
)
cflags=(
  "-ffile-prefix-map=$CARGO_HOME/registry=/cargo/registry"
  "-ffile-prefix-map=$CARGO_HOME/git=/cargo/git"
  "-ffile-prefix-map=$src=/build"
  "-ffile-prefix-map=$xcode_root=/xcode"
  "-ffile-prefix-map=$xcode_root_resolved=/xcode"
)
# Any of these paths may contain spaces ("/Applications/Xcode 26.6.app" beside a newer
# Xcode, a work directory). cargo splits RUSTFLAGS and cc-rs splits CFLAGS at every space,
# so the flags go to cargo as CARGO_ENCODED_RUSTFLAGS (separated by 0x1f), and to cc-rs
# each in single quotes with CC_SHELL_ESCAPED_FLAGS=1 (cc-rs then splits CFLAGS as a shell
# would, with the shlex crate).
unset RUSTFLAGS
export CARGO_ENCODED_RUSTFLAGS
CARGO_ENCODED_RUSTFLAGS=$(IFS=$'\x1f'; printf '%s' "${rustflags[*]}")
shell_quote() { local escaped="'\\''"; printf "'%s'" "${1//\'/$escaped}"; }
CFLAGS=""
for flag in "${cflags[@]}"; do CFLAGS+="${CFLAGS:+ }$(shell_quote "$flag")"; done
export CFLAGS CC_SHELL_ESCAPED_FLAGS=1
# C and assembly are compiled by the checked Xcode's clang, not whatever cc is on PATH.
# cc-rs gives that clang -isysroot "$(xcrun --sdk <platform> --show-sdk-path)" for every
# target, so the macOS slice uses the Xcode's SDK too (through /usr/bin/cc it got the
# Command Line Tools' SDK, which Software Update changes on its own); SDKROOT would
# override that.
export CC="$xcode_cc"
unset SDKROOT
export IPHONEOS_DEPLOYMENT_TARGET="$ios_deployment_target"
export MACOSX_DEPLOYMENT_TARGET="$macos_deployment_target"

cd "$src"
for target in $targets; do
  say "Building $target"
  target_started=$(date +%s)
  if [ "$target" = aarch64-apple-darwin ]; then
    # The macOS build also runs uniffi-bindgen below, which builds the library's
    # declared crate types; building both here lets that step reuse them.
    "$cargo" build --locked --release --lib --target "$target"
  else
    "$cargo" rustc --locked --release --lib --crate-type staticlib --target "$target"
  fi
  say "$target took $(( $(date +%s) - target_started )) s"
done

say "Generating the Swift wrapper"
generated="$work/generated"
rm -rf "$generated"; mkdir -p "$generated"
"$cargo" run --locked --release --target aarch64-apple-darwin --bin uniffi-bindgen -- \
  generate --language swift --out-dir "$generated" \
  --library "$CARGO_TARGET_DIR/aarch64-apple-darwin/release/libiroh_ffi.a" --config uniffi.toml

# The C module is called IrohFFI; the Swift wrapper module is IrohLib, as upstream.
headers="$work/headers"
rm -rf "$headers"; mkdir -p "$headers"
cp "$generated/iroh_ffiFFI.h" "$headers/iroh_ffiFFI.h"
printf '#include "iroh_ffiFFI.h"\n' > "$headers/IrohFFI.h"
cat > "$headers/module.modulemap" <<'EOF'
module IrohFFI {
    umbrella header "IrohFFI.h"
    export *
}
EOF

staging="$work/IrohLib.xcframework"
rm -rf "$staging"
xcodebuild -create-xcframework \
  -library "$CARGO_TARGET_DIR/aarch64-apple-ios/release/libiroh_ffi.a" -headers "$headers" \
  -library "$CARGO_TARGET_DIR/aarch64-apple-ios-sim/release/libiroh_ffi.a" -headers "$headers" \
  -library "$CARGO_TARGET_DIR/aarch64-apple-darwin/release/libiroh_ffi.a" -headers "$headers" \
  -output "$staging" >/dev/null
# xcodebuild lists the libraries in no fixed order (two builds with the same Xcode gave two
# orders); sort them by identifier, with the Xcode's python3, so the record does not depend on it.
/usr/bin/python3 - "$staging/Info.plist" <<'EOF'
import plistlib, sys
with open(sys.argv[1], "rb") as file:
    info = plistlib.load(file)
info["AvailableLibraries"].sort(key=lambda library: library["LibraryIdentifier"])
with open(sys.argv[1], "wb") as file:
    plistlib.dump(info, file, fmt=plistlib.FMT_XML, sort_keys=True)
EOF

if [ $update_record = 1 ]; then
  previous_record=$(cat "$record_file" 2>/dev/null || true)
  (cd "$staging" && find . -type f ! -name .DS_Store | sed 's|^\./||' | LC_ALL=C sort | while IFS= read -r file; do
    shasum -a 256 "$file"
  done) > "$record_file"
  if [ "$previous_record" = "$(cat "$record_file")" ]; then
    say "The record is unchanged"
  else
    say "Wrote $record_file; these files are new or have another SHA-256:"
    diff <(printf '%s\n' "$previous_record") "$record_file" | sed -n 's/^> [0-9a-f]\{64\}  /    /p' || true
    say "Commit the record with the change that made it"
  fi
fi
"$script_dir/verify-iroh-ffi.sh" "$record_file" "$staging" \
  || fail "this build differs from $record_file; if the change is deliberate, run with --update-record"

mkdir -p "$out_dir" "$(dirname "$wrapper")"
rm -rf "$out_dir/IrohLib.xcframework"
mv "$staging" "$out_dir/IrohLib.xcframework"
{
  echo "// Generated by scripts/build-iroh-ffi.sh with uniffi-bindgen from iroh-ffi $upstream_commit"
  echo "// and third_party/iroh-ffi/patches (see third_party/iroh-ffi/README.md). Do not edit; rebuild."
  echo "// iroh-ffi license: MIT OR Apache-2.0 (third_party/iroh-ffi/licenses)."
  echo
  sed 's/iroh_ffiFFI/IrohFFI/g' "$generated/iroh_ffi.swift"
} > "$wrapper"

say "Listing the crates in the library's dependency graph"
"$cargo" metadata --locked --format-version 1 --filter-platform aarch64-apple-ios | python3 -c '
import json, sys
# Normal dependencies reachable from iroh-ffi, without proc-macro crates (build time only).
metadata = json.load(sys.stdin)
packages = {p["id"]: p for p in metadata["packages"]}
nodes = {n["id"]: n for n in metadata["resolve"]["nodes"]}
root = next(p["id"] for p in metadata["packages"] if p["name"] == "iroh-ffi")
seen, stack = set(), [root]
while stack:
    for dep in nodes[stack.pop()]["deps"]:
        package = packages[dep["pkg"]]
        if not any(kind["kind"] is None for kind in dep["dep_kinds"]):
            continue
        if any("proc-macro" in target["kind"] for target in package["targets"]):
            continue
        if dep["pkg"] not in seen:
            seen.add(dep["pkg"])
            stack.append(dep["pkg"])
print("# crate\tversion\tlicense (scripts/build-iroh-ffi.sh; see README.md)")
for name, version, license in sorted((packages[i]["name"], packages[i]["version"], packages[i]["license"] or "see its license file") for i in seen):
    print(f"{name}\t{version}\t{license}")
' > "$root_dir/third_party/iroh-ffi/crates.tsv"

# --- Test relay -----------------------------------------------------------------

if [ $fetch_relay = 1 ]; then
  relay_archive="$work/downloads/$(basename "$relay_url")"
  mkdir -p "$work/downloads"
  [ -f "$relay_archive" ] || curl -fsSL -o "$relay_archive" "$relay_url"
  [ "$(sha "$relay_archive")" = "$relay_sha256" ] || { rm -f "$relay_archive"; fail "SHA-256 mismatch for $relay_url"; }
  tar -xzf "$relay_archive" -C "$out_dir" iroh-relay
  chmod 755 "$out_dir/iroh-relay"
fi

# --- Record ---------------------------------------------------------------------

record="$out_dir/IrohLib.build.txt"
{
  echo "upstream $upstream_url $upstream_commit"
  for patch in "${patches[@]}"; do echo "patch $(sha "$patch") $(basename "$patch")"; done
  echo "rustc $("$RUSTC" --version)"
  echo "cargo $("$cargo" --version)"
  echo "xcode $(xcodebuild -version | tr '\n' ' ')at $developer_dir"
  echo "clang $found_clang"
  echo "deployment iOS $ios_deployment_target, macOS $macos_deployment_target"
  echo "crates $(grep -c '^name = ' Cargo.lock) packages in Cargo.lock, sha256 $(sha Cargo.lock)"
  echo "source sha256 $source_sha256 (git diff --cached --binary of the patched checkout)"
  echo "record sha256 $(sha "$record_file") third_party/iroh-ffi/IrohLib.sha256"
  for slice in "$out_dir"/IrohLib.xcframework/*/; do
    lib="$slice/libiroh_ffi.a"
    echo "sha256 $(sha "$lib") $(stat -f %z "$lib") bytes $(basename "$slice")/libiroh_ffi.a"
  done
  echo "sha256 $(sha "$headers/iroh_ffiFFI.h") iroh_ffiFFI.h"
  echo "sha256 $(sha "$wrapper") Sources/IrohLib/IrohLib.swift"
  [ $fetch_relay = 0 ] || echo "sha256 $(sha "$out_dir/iroh-relay") iroh-relay (from $(basename "$relay_url"), archive sha256 $relay_sha256)"
  echo "built in $(( $(date +%s) - started )) s on $(sw_vers -productName) $(sw_vers -productVersion) $(uname -m)"
} > "$record"
cat "$record"
say "Done: $out_dir"
