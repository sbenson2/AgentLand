#!/bin/zsh
# Xcode script phase that runs on every build and takes well under a second.
#
# Writes two stamps into DERIVED_FILE_DIR and rewrites a stamp only when its
# content changes, so the phases that list them as inputs run only then:
#   agentland-host.stamp  what the Go host is built from: the go version, the
#                         host build scripts, every file under desktop/, and
#                         the commit and clean/modified state that Go stamps
#                         into the binary
#   helper-signing.stamp  the identity the helpers are signed with
# and records signing-identity, the name of the identity Xcode signs the app
# with (empty with signing off). The AgentLandBundleCheck target, which Xcode
# gives no signing settings, passes it to check-app-bundle.sh.
set -euo pipefail

phases="${0:A:h}"
root="${phases:h:h}"
source "$phases/go-tool.sh"

write_if_changed() {
  local file="$1" content="$2"
  if [[ ! -f "$file" || "$(<"$file")" != "$content" ]]; then
    mkdir -p "${file:h}"
    print -r -- "$content" >"$file"
  fi
}

# Go stamps the repository whose .git directory is nearest above desktop/. A
# linked worktree's .git is a file, which Go skips, so a build in a worktree
# stamps the enclosing checkout; follow the same rule.
vcs_root="$root/desktop"
while [[ "$vcs_root" != / && ! -d "$vcs_root/.git" ]]; do
  vcs_root="${vcs_root:h}"
done

host_inputs="$(
  {
    go_clean version
    shasum -a 256 "$phases/build-host.sh" "$phases/go-tool.sh" "$root/scripts/check-go-toolchain.py" | sed "s|$phases/||"
    (cd "$root/desktop" && find . -type f ! -path '*/.build/*' -print0 | sort -z | xargs -0 shasum -a 256)
    if [[ -d "$vcs_root/.git" ]]; then
      git -C "$vcs_root" rev-parse HEAD 2>/dev/null || print "no commit"
      if [[ -n "$(git -C "$vcs_root" --no-optional-locks status --porcelain 2>/dev/null)" ]]; then
        print modified
      else
        print clean
      fi
    else
      print "not in a git checkout"
    fi
  } | shasum -a 256
)"
write_if_changed "${DERIVED_FILE_DIR:?}/agentland-host.stamp" "$host_inputs"
write_if_changed "$DERIVED_FILE_DIR/helper-signing.stamp" "${CODE_SIGNING_ALLOWED:-NO} ${EXPANDED_CODE_SIGN_IDENTITY:-}"
signing_identity=""
if [[ "${CODE_SIGNING_ALLOWED:-NO}" == YES ]]; then
  signing_identity="${EXPANDED_CODE_SIGN_IDENTITY_NAME:-}"
fi
write_if_changed "$DERIVED_FILE_DIR/signing-identity" "$signing_identity"
