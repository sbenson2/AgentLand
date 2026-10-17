<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="branding/logo-dark.png">
    <img src="branding/logo-light.png" alt="AgentLand" width="160" height="160">
  </picture>
</p>

<h1 align="center">AgentLand</h1>

<p align="center">
  Run coding agents, terminals and AI chats on your Mac, and use them from your iPhone or iPad.
</p>

<p align="center">
  <a href="LICENSE"><img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-blue"></a>
  <img alt="iOS 26+" src="https://img.shields.io/badge/iOS-26%2B-lightgrey">
  <img alt="macOS 26+" src="https://img.shields.io/badge/macOS-26%2B-lightgrey">
  <img alt="Go 1.26.8+" src="https://img.shields.io/badge/Go-1.26.8%2B-00ADD8">
</p>

<p align="center">
  <a href="#get-it">Get it</a> ·
  <a href="#build-it-yourself-free">Build it yourself</a> ·
  <a href="#verify">Verify</a> ·
  <a href="#support">Support</a> ·
  <a href="#license-and-trademarks">License</a>
</p>

## What AgentLand is

AgentLand connects a native iPhone/iPad workspace and a local Mac web workspace
to a small host on your computer. The Mac companion runs in the menu bar.

The product includes a native macOS companion, a Go host, and a mobile app with plain AI chats (web search, reading web pages, and a memory you can review and undo), coding-agent conversations in projects, terminal tabs, a file browser and text editor. The Mac app bundles no OpenCode: its host installs the ACP registry's OpenCode (a checked download), keeps it updated and runs it; an existing loopback OpenCode service remains available in advanced settings. Tailscale is an optional network path; direct HTTPS works without it when the host is reachable.

AgentLand has no server of its own: devices talk to your Mac's host over HTTPS,
and notifications travel through your own iCloud.

## Get it

| Part | How to get it | Price |
|---|---|---|
| **iPhone and iPad app** | App Store (coming soon) | About $2.99. Buying it supports development. |
| **Mac companion** | Build from this repository ([macOS setup](macos/README.md)) | Free |
| **Host (`agentland-host`)** | Build from this repository ([host commands](desktop/README.md)) | Free |

The App Store build and this repository have the same code. You can build the
iPhone and iPad app yourself for free.

## Build it yourself (free)

You need a Mac with Xcode 26 and Swift 6, Go 1.26.8 or later (the shared
minimum is in `desktop/go.mod`), [XcodeGen](https://github.com/yonaskolb/XcodeGen),
and an Apple-silicon Mac. The apps link iroh's Swift bindings, which are not
committed: run `scripts/fetch-iroh-ffi.sh` once before the first app build. It
downloads the prebuilt library from this repo's releases and checks every file
against `third_party/iroh-ffi/IrohLib.sha256`. To build the library from source
instead, run `scripts/build-iroh-ffi.sh`, which needs the pinned Xcode and Rust;
see [third_party/iroh-ffi](third_party/iroh-ffi/README.md).

- **Mobile:** open `ios/AgentLand.xcodeproj`, scheme `AgentLand`. See [iOS instructions](ios/README.md). Bundle ID: `dev.agentland.client`.
- **Desktop:** run `AGENTLAND_CODE_SIGN_IDENTITY="Apple Development: your identity" scripts/build-desktop-app.sh /absolute/new/path/AgentLand.app`. Keep that signing identity consistent for updates. See [macOS setup](macos/README.md). Bundle ID: `dev.agentland.desktop`.
- **Host CLI:** see [host commands and configuration](desktop/README.md).

The Xcode projects are generated from `ios/agentland.yml` and
`macos/agentland-desktop.yml`; change those and run `xcodegen generate`.

### Identifiers to change

The repository is set up for the official builds. Bundle identifiers, iCloud
containers and the signing team are tied to one Apple developer account, so a
build of your own needs its own:

| What | Official value | Where it is set |
|---|---|---|
| Apple team | `572969HWXM` | `macos/agentland-desktop.yml` (`DEVELOPMENT_TEAM`), `macos/BuildPhases/check-app-bundle.sh` (`expected_team`), `scripts/install-ios-device.py` (`TEAM`). The iOS project leaves the team empty; pick yours in Xcode. |
| Mac signing requirement | the official certificate | Nothing to edit: `macos/BuildPhases/check-app-bundle.sh` builds the expected designated requirement from the bundle ID and the identity the build signed with (`AGENTLAND_CODE_SIGN_IDENTITY`, or the one Xcode chose). Sign every update with the same identity. |
| iPhone/iPad bundle ID | `dev.agentland.client` (tests: `.tests`, `.uitests`) | `ios/agentland.yml`, `shared/AgentLandCore/Sources/AgentLandCore/ProductIdentity.swift` |
| Mac bundle IDs | `dev.agentland.desktop`, helper `dev.agentland.desktop.host` | `macos/agentland-desktop.yml`, `macos/BuildPhases/`, `scripts/build-desktop-app.sh` |
| iCloud container | `iCloud.dev.agentland` | `ios/AgentLand/AgentLand.entitlements`, `macos/AgentLandDesktop.entitlements`, `ios/agentland.yml`, `shared/AgentLandNotifications/Sources/AgentLandNotifications/NoticeRecord.swift`, `shared/AgentLandCore/Sources/AgentLandCore/RemoteAccessWire.swift`, `macos/Sources/AgentLandDesktopCore/RemoteAccessAddressRecordWriter.swift`, `macos/CloudKit/` |

`grep -rn "dev.agentland\|572969HWXM" .` finds every use. Notifications and
remote-access address sharing use CloudKit; to use them, create your own
container and import `macos/CloudKit/schema.ckdb` (see
[macos/CloudKit/README.md](macos/CloudKit/README.md)).

### Signing on your iPhone or iPad

- **Free Apple ID:** Xcode can sign the app with a free Apple ID ("Personal
  Team"). The app stops opening after 7 days; build and install it again to
  renew it. Free accounts can't use iCloud or push: remove `aps-environment`
  and the iCloud entries from `ios/AgentLand/AgentLand.entitlements` before
  building, and notifications and iCloud address sharing stay off.
- **Paid Apple Developer Program:** a development build lasts a year, and the
  iCloud and push capabilities work.

## How it works

On first launch, the Mac app asks for a workspace folder, prepares its local HTTPS
service and gets OpenCode through its host, then optionally accepts provider
configuration and pairs devices. Configured launches run in the menu bar by
default. **Open AgentLand** opens a local web workspace with tabs for real agent
terminals, shells and chats. Beginners choose a folder and an agent instead of
typing a startup command; Files and Git are optional supporting panels.

Server Settings and device pairing have independent native windows. Closing
these windows or the browser keeps the server running. **Quit AgentLand Server**
stops its owned processes. Start/Stop Server preserves the desired connection
state, and Open at login remains opt-in. Browser access is local to this Mac;
the existing mobile HTTPS API retains its separate authentication boundary.
See [local web workspace](docs/LOCAL-WEB-WORKSPACE.md) for architecture and build
instructions. Frontend builds require `npm --prefix web ci`; installed users
need no Node runtime.

Pairing is by QR code only. Once a configured HTTPS host is running, the Mac shows a pairing QR code; scan it with the iPhone or iPad. The code carries the Mac's HTTPS address, its other routes (local name, Tailscale name and addresses), its certificate fingerprint and a one-time code, so a valid scan pairs at once, with nothing to type or compare. Codes work once and expire after ten minutes; while the QR code shows, the Mac replaces it before it expires. Macs this device paired with stay listed on the pairing screen. Pairing does not provide internet routing or NAT traversal.

The mobile app keeps its own credentials, hosts, tabs and drafts. Closing a terminal tab leaves the remote terminal running. Closing any tab is persisted immediately. File saves compare the original revision and reject conflicting changes.

No other app's installation, data, backend or Tailscale configuration is migrated or replaced.

## Verify

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

The [architecture](docs/INDEPENDENT-ARCHITECTURE.md) records process, trust and state ownership. Full simulator workflows are reproducible with `python3 integration/check-ios-product.py <booted-iPhone-simulator-UDID>`; its `testHostDisconnectFlow` stops, restarts, freezes and resumes the real host process. `python3 integration/check-ios-terminals.py <booted-simulator-UDID>` visits each terminal program (shell, OpenCode, Claude Code, Codex) with and without the keyboard and keeps screenshots; it types but never submits. The narrower discovery check remains in `integration/check-ios-workspace.py`. Checks that erase a simulator only do so for UDIDs listed in `AGENTLAND_DISPOSABLE_SIMULATORS`.

## Contributing

Issues and pull requests are welcome. [AGENTS.md](AGENTS.md) describes the code
layout, the rules the code depends on and the checks to run; it is written for
people and coding agents alike.

## Support

AgentLand is free and open source. If it is useful to you, you can support its
development by buying the App Store build (coming soon) or through
[GitHub Sponsors](https://github.com/sponsors/OWNER) <!-- TODO: replace OWNER with the GitHub account -->.

## License and trademarks

AgentLand's source code is released under the [MIT License](LICENSE).

The AgentLand name, app icon, tent logo and wordmark are trademarks. They, the
artwork (the PixelLab tent, clowns, characters and animation frames) and the
AgentLand Rubber Hose font are all rights reserved and not covered by the code
license. Forks that you distribute must use a different name and replace the
icon, logos, artwork and font with their own; [TRADEMARKS.md](TRADEMARKS.md)
lists the reserved files and the open-licensed fonts that are exceptions.

Third-party components keep their own licenses and notices: the Go host's in `desktop/THIRD_PARTY_NOTICES.md` and `desktop/licenses/`, the Mac app's in `macos/licenses/` (copied into the app bundle), SwiftTerm's in `ios/AgentLand/SwiftTerm-LICENSE.txt` (shown in Settings), GRDB's (the device archive's database library) in `ios/AgentLand/GRDB-LICENSE.txt` and `macos/licenses/`, iroh's in `third_party/iroh-ffi/` and `ios/AgentLand/IrohLib-NOTICES.txt`, and the bundled fonts' SIL Open Font License texts next to each font (`shared/AgentLandBranding/Sources/AgentLandBranding/Resources/Fonts/`, `branding/fonts/`). The chat interface's clean-room UX reference is described in [docs/CHAT-UX-SPEC.md](docs/CHAT-UX-SPEC.md); no Open WebUI code, text or assets are included.
