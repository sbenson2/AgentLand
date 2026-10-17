# AgentLand contributor and agent guide

This guide is for people and coding agents working on AgentLand. Read the
README first; this file adds the layout, the rules the code depends on, and the
checks to run before you send a change.

## Code layout

- `desktop/`: the Go HTTPS host (`agentland-host`): pairing, projects, files,
  Git, terminals and the terminal keeper, chats, the agent catalog and the
  managed OpenCode runtime. Module `agentland/host`; see `desktop/README.md`.
- `macos/`: the SwiftUI Mac companion that runs and supervises its own host.
  XcodeGen definition `macos/agentland-desktop.yml`
  (`cd macos && xcodegen generate --spec agentland-desktop.yml`).
- `ios/`: the iPhone and iPad app. XcodeGen definition `ios/agentland.yml`
  (`cd ios && xcodegen generate --spec agentland.yml`), project
  `ios/AgentLand.xcodeproj`, scheme `AgentLand`.
- `shared/`: Swift packages used by the apps:
  `AgentLandCore` (the `/v1` models, HTTPS client, persistence),
  `AgentLandWorkspace` (tabs, sessions, Home), `AgentLandChat` (the chat
  screen and its event engine), `AgentLandPairing` (QR invitations),
  `AgentLandArchive` (the device's copy of a host's archive),
  `AgentLandNotifications` (CloudKit notices), `AgentLandRemoteAccess` and
  `AgentLandIroh` (remote access over iroh), `AgentLandDesign` (tokens, text
  styles, notices) and `AgentLandBranding` (artwork, fonts, quips).
- `web/`: the local web workspace the Mac serves on loopback.
- `integration/`: end-to-end checks against a real host and simulator.
- `scripts/`: builds, packaging and installers. `third_party/`: pinned
  third-party sources and their notices.
- `docs/`: the host API (`docs/HOST-API.md`), architecture
  (`docs/INDEPENDENT-ARCHITECTURE.md`) and design specs.

The Xcode projects are generated. Change the `.yml` definitions and
regenerate; don't edit the `.pbxproj` by hand.

## Rules the code depends on

State and lifecycle

- A tab's live state is a session owned by the workspace, not by its view.
  Closing a tab ends the session, never the remote process. Closing a terminal
  tab leaves the terminal running on the host.
- Capture host, project and tab identity before asynchronous work, and discard
  stale results and errors. Cancellation never overwrites current UI with an
  old error.
- Editor drafts keep the revision they were based on. Saves compare revisions
  and keep the user's edits on conflict.
- Keep terminal parser replies separate from user input. Inactive tabs never
  take keyboard input.
- The Mac app owns exactly the processes it launches (the host, its terminal
  keeper and the managed OpenCode) and stops them on quit.

Network, pairing and storage

- The apps accept HTTPS origins only, with platform certificate validation or
  an explicitly paired certificate fingerprint.
- Pairing codes expire and work once. The host stores hashed device
  credentials; devices keep tokens in their own Keychain namespace. Keep the
  PIN guessing limits, and keep pairing payloads out of logs.
- Tailscale is an optional route chosen by the user. Never configure a VPN.
- Files stay inside configured project roots: keep traversal-resistant
  handles, size and UTF-8 limits and revision checks.
- Keep secrets out of preferences, command lines, diagnostics, screenshots and
  committed files. State edits must preserve other projects, devices and
  pending pairings.
- The agent catalog installs only what the ACP registry lists, by id. Devices
  never send a URL, package or command to install.

Interface

- Follow Apple's Human Interface Guidelines. Take colours, text styles, tap
  targets and notices from `shared/AgentLandDesign`; use Dynamic Type styles
  rather than fixed font sizes, and at least 44 pt targets on iPhone and iPad.
- Keep unsupported features absent rather than adding inert controls.
- Every action has one home; don't repeat a control in several places.

## Checks

Run the checks that cover what you changed:

```sh
go -C desktop test -race ./...
go -C desktop vet ./...
swift test --package-path macos
swift test --package-path shared/AgentLandCore
swift test --package-path shared/AgentLandChat
swift test --package-path shared/AgentLandBranding
swift test --package-path shared/AgentLandPairing
python3 integration/check-host-client.py
```

The apps link iroh's Swift bindings, which are not committed: run
`scripts/fetch-iroh-ffi.sh` (prebuilt, checked against the record) or
`scripts/build-iroh-ffi.sh` (from pinned source) once before building the iOS
app, the Mac app or the packages that depend on `AgentLandIroh`.

For mobile changes, also build the app and run its unit tests on a simulator
(see `ios/README.md`). The `integration/check-ios-*.py` checks take a booted
simulator UDID; use a simulator you can erase. `--erase` works only on
simulators listed in `AGENTLAND_DISPOSABLE_SIMULATORS`.

Tests use fake CLIs, loopback servers and disposable state. Don't point a test
at your own running host or spend model credits in a check.

## Documentation

Record API changes in `docs/HOST-API.md`. Describe notable behaviour changes
in the pull request or commit message, and say there what was verified and
how: unit tests, builds, simulator runs and physical devices are different
kinds of evidence.
