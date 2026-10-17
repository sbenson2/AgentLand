# Local terminal workspace

Owner-approved direction, 2026-10-02: AgentLand on Mac is a menu-bar server with
a terminal-first browser workspace. This supersedes the earlier Mac workspace
that reused the iPad shell. The native iPhone/iPad apps remain separate clients.

## Product behavior

Configured launches show only the menu-bar tent. Open AgentLand starts the
desired server if needed and opens an authenticated local browser session.
Setup, Settings and Pair a Device remain independent native server controls.
Closing these windows or the browser leaves the server running. Only the
explicit Quit AgentLand Server action exits it. Login-item preferences and
the remembered server connection intent are preserved.

The main browser surface is a terminal or chat, selected from a top tab strip.
Start working chooses a folder and an available agent; the host runs its named
terminal program, so beginners need no startup command. Agent sign-in remains
the agent's actual interactive flow. Brief help explains input, interruption,
new tabs and resuming. Files and Git are optional supporting panels; opened
documents and diffs use tabs. Closing a terminal tab detaches its view; Running
Sessions reopens it and End Session explicitly terminates it.

The first release includes projects, terminals, agent/plain chats, approvals,
attachments, files/editing, and Git status/diffs. Since 2026-10-12 Chat is
Claude Code and Codex in the selected workspace; the allowlist also carries its
Run again (`/v1/chat/regenerate`), queue (`/v1/queue`, `/v1/queue/remove`) and
Continue in a workspace (`/v1/chat/continue`), each a POST. Archives, previews and
broader web administration are outside this release. Provider credentials,
agent management, device pairing and remote-access settings remain native.

## Process and trust boundaries

The signed Mac app contains the static React/TypeScript browser bundle. Vite,
Node and npm are build tools, not installed runtime services. xterm.js renders
the host's actual terminal stream; CodeMirror renders editable text.

The Go host serves the bundle and browser API on a separate ephemeral literal
127.0.0.1 HTTP listener. The device-facing HTTPS API retains its browser Origin
rejection. Browser requests pass exact Host/Origin checks and an explicit
method/path allowlist before reaching existing handlers as the local Mac's
session. Pairing and server administration are excluded. Since 2026-10-15
(terminals from other devices) terminal routes are not owner-scoped: every
paired device reaches every terminal by its ID. The browser lists only its own
terminals, routed agents typed in Terminal included, through its own
`GET /v1/terminals`; `/v1/terminals/others` and the Mac's own terminal routes
are not on its allowlist (`TestLocalWebListsNoOtherDevicesTerminals`).

The native companion requests a single-use launch grant using its existing
authenticated local HTTPS session. The grant travels in a URL fragment, which
the frontend removes before exchanging it for an expiring browser credential.
That credential stays in session storage and request headers; no native token,
cookie authentication or model-provider credential is exposed. The grant URL
must never be logged. Server restarts invalidate browser credentials.

Browser state lives beside the host state in a private, atomically written
file with revision checks. Tabs retain their project/session identity, and
drafts retain the original file revision. Native tabs/drafts are exported
read-only and imported once; originals and newer browser work are preserved.
Lost responses do not authorize automatic retries of terminal/chat mutations.

## Build and verification

Install locked frontend dependencies with `npm --prefix web ci`, then run
`scripts/build-web.sh`. The Mac Xcode build runs the same production build and
packages it as `Contents/Resources/AgentLandWeb`. The bundle gate compares all
web assets to their SHA-256 record and requires packaged third-party notices.

Use disposable host/agent fixtures for terminal and chat checks. Tests must
exercise grants and expiry, rejected origins/hosts/routes, state conflicts,
draft migration, stream reconnection, terminal ownership and close-versus-end
behavior. Browser compilation alone is not runtime verification. Installed
Mac signing/state/health checks and physical mobile connectivity are checked
separately.

The browser credential is valid for eight hours and lives only in the browser
session. Reopen through the menu bar after expiry or a host restart. State writes
are limited to 2 MiB, with an 8 MiB cap on the merged persistent document. A failed
save keeps drafts in the current window and offers a recovery download. Concurrent
browser windows require explicit conflict resolution; they never silently replace
one another's drafts. Development-HTTP companion mode is not a browser-launch
configuration: use the normal trusted-HTTPS companion connection.

Verified release evidence is indexed in
`.evidence/web-workspace-20261002/verification-summary.json`. Browser fixture tests
run in Chromium and WebKit; the separate opt-in Go smoke serves the production
bundle through real authentication and CSP. These checks do not run paid models.
