#!/bin/sh
set -eu

# Checks an IrohLib.xcframework against a SHA-256 record (normally the committed
# third_party/iroh-ffi/IrohLib.sha256): the framework holds exactly the files the
# record lists (Finder's .DS_Store aside), and each has its recorded SHA-256.
#
#   scripts/verify-iroh-ffi.sh RECORD XCFRAMEWORK [STAMP]
#
# scripts/build-iroh-ffi.sh runs it on every fresh build before installing it, and
# the AgentLandIroh package's VerifyIrohLib plugin runs it before the IrohLib target
# compiles, so nothing links a library that differs from the record. With STAMP it
# writes that Swift file after a match (the plugin's output). Exits 1 on a mismatch.

[ $# -ge 2 ] && [ $# -le 3 ] || { echo "usage: $0 RECORD XCFRAMEWORK [STAMP]" >&2; exit 64; }
record=$1
framework=$2
stamp=${3:-}

fail() {
  printf 'error: %s does not match %s: %s\n' "$framework" "$record" "$1" >&2
  printf 'error: run scripts/fetch-iroh-ffi.sh or scripts/build-iroh-ffi.sh (see third_party/iroh-ffi/README.md)\n' >&2
  exit 1
}

[ -f "$record" ] || fail "the record is missing"
[ -d "$framework" ] || fail "the xcframework is missing"
record=$(cd "$(dirname "$record")" && pwd)/$(basename "$record")

grep -qvE '^[0-9a-f]{64}  [^ ].*$' "$record" && fail "the record has a line that is not '<sha256>  <path>'"
expected=$(sed 's/^[0-9a-f]\{64\}  //' "$record" | LC_ALL=C sort)
[ -n "$expected" ] || fail "the record is empty"
actual=$(cd "$framework" && find . -type f ! -name .DS_Store | sed 's|^\./||' | LC_ALL=C sort)
if [ "$expected" != "$actual" ]; then
  fail "different files. Recorded: $(echo $expected). Present: $(echo $actual)."
fi
if ! mismatched=$(cd "$framework" && /usr/bin/shasum -a 256 -c "$record" 2>/dev/null); then
  fail "SHA-256 differs for $(printf '%s\n' "$mismatched" | grep -v ': OK$' | sed 's/: FAILED.*//' | tr '\n' ' ')"
fi

if [ -n "$stamp" ]; then
  printf '// %s matched %s when this file was written.\n' "$(basename "$framework")" "$(basename "$record")" > "$stamp"
fi
