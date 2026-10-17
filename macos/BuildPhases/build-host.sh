#!/bin/zsh
# Xcode script phase: builds the Go host with the same command
# scripts/build-desktop-app.sh used before the Xcode project.
# Input: agentland-host.stamp. Output: DERIVED_FILE_DIR/agentland-host,
# unsigned; embed-helpers.sh copies it into the app and signs it.
set -euo pipefail

phases="${0:A:h}"
root="${phases:h:h}"
source "$phases/go-tool.sh"

output="${DERIVED_FILE_DIR:?}/agentland-host"
mkdir -p "${output:h}"
# Build under the final file name: Go's linker signs the binary ad-hoc and
# names that signature after the output file.
work="$(mktemp -d "$output.XXXXXX")"
trap 'rm -rf "$work"' EXIT
go_clean -C "$root/desktop" build -trimpath -ldflags='-s -w' -o "$work/agentland-host" ./cmd/agentland-host
mv -f "$work/agentland-host" "$output"
