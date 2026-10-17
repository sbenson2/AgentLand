# Sourced (zsh) by the Go host build phases.
#
# Xcode runs script phases with a minimal PATH, so look for `go` on PATH first
# and then where Homebrew and the Go installer put it. go_clean runs it without
# Xcode's build settings in the environment (SDKROOT, MACOSX_DEPLOYMENT_TARGET
# and the rest), keeping HOME, TMPDIR, USER, the caller's GO*/CGO_* and proxy
# variables, and a plain PATH that still finds git and the C compiler: Go's
# VCS stamp uses git, and its CGO_ENABLED default depends on finding cc. The
# host then builds as it does from a terminal.

go_tool="$(command -v go 2>/dev/null || true)"
if [[ -z "$go_tool" ]]; then
  for candidate in /opt/homebrew/bin/go /usr/local/go/bin/go /usr/local/bin/go; do
    if [[ -x "$candidate" ]]; then
      go_tool="$candidate"
      break
    fi
  done
fi
if [[ -z "$go_tool" ]]; then
  print -u2 "error: go was not found on PATH, in /opt/homebrew/bin or in /usr/local/go/bin. See desktop/go.mod for the required release."
  exit 1
fi

go_clean() {
  local -a kept
  local name
  for name in ${(k)parameters[(I)GO*]} ${(k)parameters[(I)CGO_*]} ${(k)parameters[(I)*_proxy]} ${(k)parameters[(I)*_PROXY]}; do
    [[ ${parameters[$name]} == *export* ]] && kept+=("$name=${(P)name}")
  done
  env -i HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" USER="${USER:-}" \
    PATH="${go_tool:h}:/usr/bin:/bin:/usr/sbin:/sbin" "${kept[@]}" GOTOOLCHAIN=local "$go_tool" "$@"
}

# The module's minimum is also the release gate. Never auto-download a toolchain
# during a host build; tools are staged before disconnected execution.
python3 "${${(%):-%x}:A:h:h:h}/scripts/check-go-toolchain.py" --version "$(go_clean env GOVERSION)"
