#!/bin/zsh
# A production static frontend is part of the signed app, never a dev server.
set -euo pipefail
phases="${0:A:h}"
root="${phases:h:h}"
"$root/scripts/build-web.sh"
destination="${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}/AgentLandWeb"
rm -rf "$destination"
ditto "$root/web/dist" "$destination"
