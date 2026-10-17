# AgentLand for iPhone and iPad

Open `AgentLand.xcodeproj`, scheme `AgentLand`. Generate it with `xcodegen generate --spec agentland.yml`. The target is built from `AgentLand/`, the shared packages under `../shared/` (including `AgentLandCore`, which the Mac companion also uses), and a pinned upstream SwiftTerm package.

The bundle identifier is `dev.agentland.client`; Keychain and preferences are scoped to AgentLand. Use the host companion to configure a project, HTTPS address and a one-time pairing code. For a generated private certificate, compare and enter its complete SHA-256 fingerprint. Tailscale is optional routing to an already reachable HTTPS host.

The app includes projects, agent conversations and interaction responses, retained native terminals, persistent tabs/drafts, file browsing, text editing with conflicts, saved hosts and device authentication. A closed tab stays closed on relaunch. A closed terminal tab leaves its process running and it can be reopened from Existing terminals.

Notifications come from the paired Mac through the owner's iCloud (`shared/AgentLandNotifications`): the app carries `aps-environment` and the `iCloud.dev.agentland` CloudKit container (`AgentLand/AgentLand.entitlements`), so a device build needs the explicit App ID `dev.agentland.client` with iCloud and Push; `-allowProvisioningUpdates` creates it. Settings → Notifications asks for permission and saves the account's subscriptions; nothing is asked at launch. Test runs keep CloudKit off (`AGENTLAND_CLOUDKIT=0` in the scheme's test action, and `-AgentLandUITests…` launches).

## Build and checks

Use Xcode 26 with Swift 6. The app requires iOS 26 or later on the device or simulator. The app links AgentLand's iroh library for remote access (`shared/AgentLandRemoteAccess`), which is built from pinned source and not committed: run `scripts/build-iroh-ffi.sh` once (it needs the pinned Xcode, 26.6) before the first build; the package's plugin checks it against `third_party/iroh-ffi/IrohLib.sha256`. Regenerate only from the independent definition:

```sh
cd ios
xcodegen generate --spec agentland.yml
```

From the repository root:

```sh
swift test --package-path shared/AgentLandCore
xcodebuild -project ios/AgentLand.xcodeproj -scheme AgentLand -destination 'generic/platform=iOS Simulator' -derivedDataPath /private/tmp/agentland-derived CODE_SIGNING_ALLOWED=NO build
```

For app model tests, use a concrete booted simulator destination and `-only-testing:AgentLandTests test`. An unsigned build is a compile check; Keychain runtime tests need simulator signing. The live UI test normally skips because its resource fixture is disabled. To verify real HTTPS pairing, file editing and tab closure on one or more booted simulators:

```sh
python3 integration/check-ios-workspace.py SIMULATOR_UDID [SECOND_SIMULATOR_UDID]
```

The runner creates its own host/certificate/code, verifies the saved file on disk, restores Fixture.json and stops its own backend. It does not issue model prompts. Select a personal development team in Xcode or via build arguments for physical device signing; no team credential is committed.

A fuller iPhone check includes a real pinned OpenCode runtime, a disposable HTTPS
host and a local deterministic model fixture. It exercises model selection, Plan
mode, real terminal input, scrolling, tab restoration and file editing without
paid provider calls:

```sh
python3 integration/check-ios-product.py SIMULATOR_UDID
```

Its evidence belongs under `.evidence/ios-product/`. Keep `Fixture.json` disabled
after every check; never use an owner's credentials or backend as a test fixture.

`--tests testConnectsThroughIrohTunnel` checks remote access through iroh on this
Mac's loopback: the host with its tunnel socket and the Mac side built from the
Mac app's code (`agentland-remote-access-loopback`) run under
`shared/AgentLandIroh/Tests/router-ports-denied.sb`; the app gets the same profile
from `integration/RouterPortsSandbox` (inserted by the test; the app ends if it
cannot apply it) and, in debug builds, dials only the loopback port
(`RemoteAccessLoopbackDial`). The app pairs through a forwarder and registers its
node ID there, the forwarder is cut and a terminal command runs through the
tunnel with the paired pin; with the device removed on the Mac, the next run is
refused with 403 and the banner says to connect at home.
