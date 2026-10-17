#!/bin/zsh
# Xcode script phase: puts the Go host into Contents/MacOS as agentland-host
# and signs it with its own identifier before Xcode signs the app, as
# scripts/build-desktop-app.sh did. The app bundles no OpenCode: the host
# installs and updates it (agentland-host install-opencode).
# Inputs: the built host and helper-signing.stamp. Output: the host in the
# bundle.
#
# EXPANDED_CODE_SIGN_IDENTITY is the identity Xcode signs the app with (a
# certificate hash, or "-" for an ad-hoc build). With signing off the host
# keeps the signature it came with.
set -euo pipefail

destination="${TARGET_BUILD_DIR:?}/${EXECUTABLE_FOLDER_PATH:?}"
mkdir -p "$destination"
# Replace rather than overwrite: a signed Mach-O rewritten in place can keep
# a stale cached signature in the kernel.
# What a build from before left goes too: an iroh-relay (the relay was
# retired) and an opencode (OpenCode is no longer bundled).
rm -f "$destination/agentland-host" "$destination/opencode" "$destination/iroh-relay"
cp "${DERIVED_FILE_DIR:?}/agentland-host" "$destination/agentland-host"

if [[ "${CODE_SIGNING_ALLOWED:-NO}" == YES && -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]]; then
  codesign --force --timestamp=none --sign "$EXPANDED_CODE_SIGN_IDENTITY" \
    --identifier dev.agentland.desktop.host "$destination/agentland-host"
fi
