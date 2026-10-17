# AgentLand macOS companion

The macOS companion is a native SwiftUI app for macOS 26 or later. It packages
`agentland-host` and no OpenCode: the host installs and updates OpenCode, and
the app runs the host's managed OpenCode when it passes its checks (see
"OpenCode from the host" below). First launch asks for a folder,
prepares the local service and gets OpenCode through the host (a network
connection is needed the first time), optionally accepts a provider API key
and model, then offers device pairing. The key stays in Keychain and saving it does not
verify model access; that happens when OpenCode uses the provider. After setup,
launches are menu-bar-only. **Open AgentLand** opens the local terminal-first web
workspace in the default browser. **Settings…** (⌘,) and **Pair a Device…** open
independent native server windows; they do not open the mobile workspace shell.
Settings is a native Settings window like Safari's (2026-10-16): toolbar tabs for
General, Workspaces, Agents, Vault, Devices, Terminals, Remote Access,
Notifications, API Keys (Later) and Advanced, the window titled with the tab in
front and sized to it. Setup has its own window, which closes once setup is done.
Closing these windows or quitting the browser leaves the server running. Start/Stop Server changes the
remembered connection intent; **Quit AgentLand Server** gracefully stops the
owned processes. A later launch resumes only a desired connection. The native
Settings window's ⌘Q closes that window; the explicit server Quit action exits.

The browser runs only on this Mac, through a dedicated loopback listener with
short-lived launch grants and browser-scoped authentication. The mobile HTTPS
API and existing pairing remain unchanged. See
[the web workspace architecture](../docs/LOCAL-WEB-WORKSPACE.md).

The app does not install a daemon, VPN, or Tailscale configuration, and runs
no relay. Remote access over iroh (see "Remote access" below) is off until the
owner turns on **Reach this Mac from anywhere**.
**Open at login** is an optional macOS Login Items setting, never enabled by
default; macOS can require approval in Login Items.

## Build

Build requirements are Xcode 26 with Swift 6, XcodeGen, and Go 1.26.8 or newer
(on `PATH`, in `/opt/homebrew/bin` or in `/usr/local/go/bin`), plus Node.js and npm
for the static frontend build. Run `npm --prefix web ci` from the repository
root before the first build. No Node runtime is bundled or needed by users.

`AgentLandDesktop.xcodeproj` builds the app. XcodeGen generates it from
`agentland-desktop.yml`; after editing the spec, regenerate and commit both:

```sh
cd macos
xcodegen generate --spec agentland-desktop.yml
```

Scheme `AgentLand` builds `AgentLand.app` with bundle identifier
`dev.agentland.desktop`, executable `AgentLandDesktop` and
`Resources/Info.plist`. The app's code is the `AgentLandDesktop` library in
`Package.swift`, which links iroh's Swift bindings (`../shared/AgentLandIroh`).
Get those first with `scripts/fetch-iroh-ffi.sh` (prebuilt download), or build them
with `scripts/build-iroh-ffi.sh` (pinned Xcode and Rust, about 10 minutes); the
package's manifest stops with a message while they are missing,
and the `VerifyIrohLib` build tool plugin checks them against
`third_party/iroh-ffi/IrohLib.sha256` before anything links them, in SwiftPM and
in Xcode. The Xcode target adds only the entry point in `App/` and the app icon. Its script
phases in `BuildPhases/` build the Go host, copy it into `Contents/MacOS` as
`agentland-host`, sign it as `dev.agentland.desktop.host` before Xcode signs the
app (and remove an `opencode` an earlier build left there), and copy the third-party
notices. The app icon is `../ios/AgentLand/AppIcon.icon`, the layered Icon Composer icon
iPhone and iPad use too (`scripts/package-logo.py` writes it): Xcode's asset catalog
compiler builds `AppIcon.icns` and `Assets.car` from it and sets `CFBundleIconFile` and
`CFBundleIconName` to `AppIcon`, as `Resources/Info.plist` lists them. The web phase builds `web/dist`, records its asset hashes, and copies it
into `Contents/Resources/AgentLandWeb` before signing. The Go build and the host's signing run again only when their inputs
change. Xcode signs
the app automatically with an Apple Development certificate of team
572969HWXM and `AgentLandDesktop.entitlements`, which holds only the iCloud
entitlements for notifications (container `iCloud.dev.agentland`, service
CloudKit). Those need a provisioning profile: Xcode embeds its
"Mac Team Provisioning Profile: dev.agentland.desktop" and adds
`com.apple.application-identifier` and `com.apple.developer.team-identifier`
to the signature. A development profile lists the Macs the app may run on and
expires after a year; the check below prints its expiry. The hardened runtime
and App Sandbox are off.

After Xcode signs the app, the `AgentLandBundleCheck` target runs
`BuildPhases/check-app-bundle.sh` with the signing identity the app target
recorded. The build fails unless the signature verifies, the designated
requirement is exactly the one for that identity (identifier
`dev.agentland.desktop`, `anchor apple generic`, the leaf certificate's
subject CN equal to the identity's name, and Apple's WWDR intermediate), the
host carries its identifier and the app's team, no `opencode` is anywhere in the
bundle and no `iroh-relay` is bundled, `Info.plist` matches
`Resources/Info.plist` (Xcode only adds build keys such as `DTXcode`), and the signed
entitlements equal the entitlements file (plus the two keys the profile adds,
and `com.apple.developer.icloud-container-environment` if Xcode sets it). For
a signed app it also checks `Contents/embedded.provisionprofile`: team
572969HWXM, app ID `572969HWXM.dev.agentland.desktop`, the iCloud container
and service granted, the signing certificate included, this Mac's
provisioning UDID (`system_profiler SPHardwareDataType`) listed and the
expiry date in the future. Keychain items trust the app by that designated
requirement, so sign every update with the same identity: another identity
gives another requirement, and macOS asks again before the app may read
those items. The check fails when it cannot tell which identity the build
used.

From the repository root:

```sh
swift test --package-path macos
AGENTLAND_CODE_SIGN_IDENTITY="Apple Development: your identity" scripts/build-desktop-app.sh /tmp/AgentLand.app
```

The script builds the Release configuration into `.build/xcode/`, copies the
app to the given path and runs the same check on the copy. It refuses to
overwrite an existing app bundle and removes its copy when a check fails. With
`AGENTLAND_CODE_SIGN_IDENTITY` it uses the project's automatic signing and
fails unless that identity signed the app. It passes
`-allowProvisioningUpdates` and `-allowProvisioningDeviceRegistration`, so
the Apple account signed in to Xcode can register this Mac, keep iCloud on
for the App ID and create or renew the profile. Use one identity from
`security find-identity -v -p codesigning` consistently for development
updates. Without it the copy is signed ad-hoc without the iCloud entitlements
(an ad-hoc signature cannot carry them) and without a profile, which is enough
for compile and bundle checks; that copy keeps notifications off and can cause
macOS to ask again before allowing access to existing Keychain provider
credentials. Do not remove or weaken those credentials' access controls to
avoid that prompt. Development signing is not Developer ID notarization or an
App Store release.

The app bundles no OpenCode (the host installs it; see "OpenCode from the
host"), which leaves it about 135 MiB smaller than with the pinned 1.18.31
runtime it carried (an ad-hoc build measures 63 MiB with `du`, from 198 MiB).
The result contains:

```text
AgentLand.app/Contents/MacOS/AgentLandDesktop
AgentLand.app/Contents/MacOS/agentland-host
AgentLand.app/Contents/Resources/ThirdPartyNotices/SwiftTerm-LICENSE.txt
```

It also copies the Go, Gorilla WebSocket, x/sys and iroh-ffi notices to
`Contents/Resources/ThirdPartyNotices/`;
`iroh-ffi-crates.txt` (`third_party/iroh-ffi/crate-licenses.txt`, written by
`scripts/collect-iroh-ffi-notices.py` after a build of the library) lists the
crates of the linked iroh library with the license texts they ship. Linking iroh
adds about 12 MB to the app's executable. Build the
app first, then launch the result through Finder or the normal macOS app
workflow; the build script does not launch it. Running the scheme from Xcode
starts a second AgentLand next to an installed one, so quit the installed app
first.

`scripts/prepare-opencode-runtime.py` still fetches the pinned OpenCode 1.18.31
(`Resources/OpenCodeRuntime.json`: the 46 MB archive, checked against its
SHA-256) into `.build/opencode`, for tests only: the iPhone UI test harness
(`../integration/check-ios-product.py`) and the opt-in OpenCode checks use it.
The Mac build does not run it.

## First setup

1. Open AgentLand and choose the folder paired devices may edit and use for
   commands. Automatic setup creates local HTTPS credentials, gets OpenCode
   through the host when it has none ("Getting OpenCode…" with the version and
   a progress bar; the first time needs a network connection), and starts it
   with isolated XDG data/config/cache directories.
   Its internal service password is generated for each managed connection and
   kept in memory until its two owned services stop. Provider keys stay in
   Keychain; existing external-service passwords remain there too. When
   OpenCode can't be had (offline, say), the step says why, with **Try Again**;
   the host runs anyway, so files and terminals work, and **Continue without
   OpenCode** finishes setup.
2. Select an optional provider and model. You can continue with files and
   terminal without one. A saved provider key is not a successful-credit or
   model-access check.
3. Select **Connect** if needed, then **Pair a device**. On your phone, scan the QR code,
   or select this Mac under **Nearby computers**, compare the complete fingerprint,
   and enter the PIN. Both devices must be on a network that can reach the host.

Existing OpenCode users can choose **Settings → Advanced connection settings**,
turn off automatic management, and supply their loopback URL and password.
The app preserves existing host projects, paired devices, and pending codes
when it changes configuration.

New settings default to trusted HTTPS on `0.0.0.0:9841` and this Mac's Bonjour
hostname (`LocalHostName.local`); existing saved preferences are preserved.
Generate a local certificate before starting, or select a suitable existing
certificate and key. The app persists non-secret project, listener, terminal,
TLS file-path, advertised-host, and fingerprint preferences across relaunch. Host
configuration, pairing codes, and device records persist in the host state
file. A displayed pairing invitation remains only in memory and is cleared
when the host stops or a new PIN is requested.

## Connection modes and TLS

**Local development HTTP** listens only on a loopback address. It is intended
for local development and cannot connect a phone or tablet.

**Trusted HTTPS** supports a phone or tablet. Set the advertised DNS name or
IP address and either select your certificate and private-key files or choose
**Generate Local Certificate**. Generation creates a fresh certificate/key
directory in Application Support and displays its fingerprint. Copy that
fingerprint explicitly and use it in the mobile pairing flow. The client checks
the hostname, expiry, and fingerprint; the app never installs a trust root or
uses a certificate bypass.

Set a matching listener address, such as `0.0.0.0:9841`, only when HTTPS is
configured. When the owned HTTPS host answers its health check with the
configured certificate, the companion advertises `_agentland._tcp` on the
local network. The advertisement contains only the HTTPS address, certificate
fingerprint, and protocol version. It stops when the host stops or exits.
Direct HTTPS is not NAT traversal, and the companion does not start or
configure Tailscale.

## Pairing, revocation, stopping, and quitting

Use **Pair a Device…** from the menu bar, the main window or Settings once the HTTPS host is ready.
The sheet shows a QR code carrying the HTTPS address, the current certificate fingerprint and a
single-use code; a new code replaces it shortly before it expires. On the iPhone or iPad, tap
**Scan QR Code**. The Devices page lists paired devices, their current presence, and revocation controls.
Revocation is saved to host state and applies to later authenticated requests.

**Disconnect** sends a bounded shutdown request to only the Go host and managed
OpenCode process this app started. If necessary it escalates before releasing
ownership, so the app does not intentionally leave its host listening on the
configured port. On app quit, the companion delays termination until the same
owned-process shutdown has completed; a shutdown failure is shown in the app
and cancels that quit.

While the connection is wanted, an owned child that exits on its own is
started again instead of stopping everything: the host alone when only it
exited (OpenCode keeps its sessions), OpenCode and the host when OpenCode
exited. A restart reads the host's workspace list as it is then (devices may
have renamed or removed workspaces), starts OpenCode in the default listed
there and writes the list back unchanged, so it never adds a removed workspace
back or undoes a rename. Restarts wait 1, 2, 4, 8 and then 16 s; the sixth
failure within 10 minutes stops both and shows the count with the last
attempt's error, and Connect (or the next launch) starts them again.
Disconnect and Quit cancel a restart that is waiting.

Starting `agentland-host` from a terminal remains independent of the app. The
companion will not claim ownership of, stop, or replace that process.

## OpenCode from the host

The app bundles no OpenCode (owner's decision). The host installs and updates
OpenCode itself (docs/AGENT-CATALOG-PLAN.md, "OpenCode") in
`<state>.agents/opencode/`, beside its state file
(`~/Library/Application Support/agentland/host.json.agents/opencode/`), and
names the current version in `current.json` (`{version, command, args, sha256,
installedAt, …}`), with the version before it in `previous`. The record's
`args` are ACP arguments and are not used; the app runs `serve`.

**Getting it.** Before OpenCode starts, when the current version does not pass
the checks below (none is installed yet, or it is damaged), the app runs
`agentland-host install-opencode --state <state>` while its host is stopped
(the command takes the state and fails while a host serves it). The command
prints one JSON line per step (`registry`, `downloading` with bytes received and
the total when known, `checking`, then `ready` or `failed` with a code);
`HostOpenCodeInstaller` reads them and the onboarding step, the menu and
Settings → AI Providers show "Getting OpenCode 1.18.32…" with a progress bar
(the menu, which holds no bar, the percentage). It is stopped after 40 minutes
and when the start is cancelled. Nothing downloads while a valid managed
OpenCode exists. When it fails, the host still starts without OpenCode, so
devices keep terminals and files; the menu, Settings → AI Providers and
onboarding say why ("AgentLand needs a network connection to get OpenCode the
first time.", …) with **Try Again**, which stops the host, runs the command
again, tries every version the host keeps again and starts both. The host
itself installs a missing OpenCode when it starts, and a version it installs
later starts by the rule below.

**Which version runs.** Each start runs a version only when:

- the command (absolute, or relative to `opencode/<version>/` or `opencode/`)
  resolves, links followed, to a regular executable file inside `opencode/`
  that belongs to you and that no one else can change;
- the agents folder, `opencode/` and every folder down to the program are
  real folders of yours with mode 0700;
- the program's SHA-256 matches the version's `sha256` (a version without one
  is refused).

The current version runs first. When it does not start (it cannot run, exits,
or does not answer `/global/health` within 30 s; a first timeout gets one more
start in this launch, the second counts), it is stopped and the previous
version starts at once, checked the same way. Settings → AI Providers says why.
The failed version is remembered in
`~/Library/Application Support/AgentLand/OpenCode/managed-opencode-failure.json`
only when the previous one then started (otherwise the fault is not shown to be
the version's), and is run neither as the current nor as the previous version
while the host keeps it. Once the host runs, the app reports it
(`POST /v1/agents/opencode/failed` with its version and a short reason, the
local session only): the host goes back to the previous version, skips the
failed one in automatic updates until the registry offers another, and sets
the `opencode` entry's `lastError`. A report the host did not answer goes again
at the next start. When the current version fails the checks, the previous one
runs alone; with neither, no OpenCode runs and the host starts without it.

**OpenCode's data.** Every version runs with the same data folder, the isolated
`XDG_DATA_HOME` the app gives OpenCode
(`~/Library/Application Support/AgentLand/OpenCode/data`). Before the first
start of a version that has never started on this Mac, `OpenCodeDataGuard`
clones that folder (an APFS clone) into
`opencode-data-before-<version>` beside it. If that version then does not start
and the previous one runs, the data folder moves aside to
`opencode-data-after-failed-<version>` and the snapshot moves back into place
first, so the previous version reads the data as it was. A version that has
started here is never rolled back. The newest two of each are kept, in the order
`opencode-versions.json` records them (never by modification time); it also
records the versions that started.

**Restarts.** A new OpenCode takes effect when OpenCode and the host restart.
While the host runs, the app reads `GET /v1/agents` with its local session every
5 minutes. When the `opencode` entry says `restartWanted` and `idleForSeconds`
is at least 600 (no open terminal, no running chat turn and no device viewing a
chat for 10 minutes), and a start would run another program than the one
running (or, with none running, one the last start did not try), the app
restarts both the way it restarts a child that exited: in the workspace the
host lists then, writing that list back unchanged, with the restart backoff
after a failed attempt. A version that failed to start or fails the checks is no
reason to restart again, and a host running without OpenCode is not restarted
for it, so nothing loops. The next launch also runs the current one. A host
that does not report `idleForSeconds` is never treated as idle.

## AI Providers

Settings → AI Providers shows which OpenCode runs (the host's current version or
its previous one, and why the previous one runs), the progress while a start
gets OpenCode, or why none is available with **Try Again**; then the default
model for new OpenCode chats, and every
provider the running OpenCode lists (`GET /provider`, models.dev's catalog):
those in use (connected, or with a key saved here) and the rest, each with
whether it is connected and its model count, with a search over name, ID and
variable. Connected providers list the models OpenCode's chats offer.

**Add Key…** saves a key in the Keychain for the provider's key variable, the
first of its variables named `<X>_API_KEY` or `<X>_TOKEN` that AgentLand may set
(`ManagedOpenCodeRuntime.supportsProviderEnvironmentKey`), exactly as the
onboarding step saves one: the Keychain item `provider.<id>.api-key` (service
`dev.agentland.desktop`) and, in the preferences, only the variable's name.
OpenCode reads one value per variable, so a key saved for one provider replaces
another provider's key for the same variable (the sheet names it). Saving a key
does not check it. **Remove Key** deletes the Keychain item after a
confirmation. Every saved key reaches OpenCode's environment; keys saved before
this pane, and the provider and model chosen during setup, keep working
unchanged.

Keys and the default model reach OpenCode when it restarts: at once when the
host has been idle for 10 minutes (checked right after the change), otherwise
as soon as it has, by the same rule as updates. The pane says so, says when the
host does not report idleness (then Disconnect and Connect apply them), and
shows the last restart AgentLand made on its own.

## Remote access

Remote access over iroh lets a paired phone reach this Mac from anywhere without
Tailscale (contract: `../docs/HOST-API.md`, "Remote access (iroh)"). It is off by
default. **Reach this Mac from anywhere** is in Settings → Remote Access, with **Use a public relay if a direct connection fails**
under it once it is on. The parts are in `AgentLandDesktopCore`;
`RemoteAccessController` holds them for `HostController`, never a view:

- `RemoteAccessService` runs from the app's launch to Quit. At launch it deletes
  the router mappings an earlier run left (`removeLeftovers()`), whether or not
  the switch is on, and, while the switch is off, the address record it may have
  left in iCloud. The switch starts the endpoint, maps its port and reports to the
  host once the mapping attempt has finished; off reports it off, deletes the
  mapping and the record, and closes the endpoint. The endpoint and the mapping
  follow the switch, not the host; Quit deletes the mapping and closes the
  endpoint without a report, so devices keep their way back. Network changes and
  wakes map again at once. The switches and the last mapping are saved in the
  preferences under `dev.agentland.desktop.remoteAccess.v1`.
- `IrohMacEndpoint`: an iroh endpoint on UDP 38842 (every address) with
  `presetMinimal()`, the ALPN `agentland/tunnel/1` and this Mac's key
  (`KeychainRemoteAccessKeyStore`: the data protection Keychain, this device
  only; an ad-hoc build uses the login Keychain). No relay unless the fallback is
  on; then n0's relays only until it has a home relay, and that one relay from
  then on. Every connection goes through `IrohPeerGate`, which answers 503 until
  the host's first peer list and 403 to a node ID not on it; the list comes from
  `GET /v1/remote-access/peers` (`RemoteAccessPeerFeed`), and connections of node
  IDs that leave it are closed.
- `MacTunnelBridge` copies each stream of an admitted connection to a new
  connection to the host's tunnel socket (`<state folder>/tunnel.sock`, passed
  to every HTTPS host start), after the 84-byte preamble naming the peer, in
  chunks of at most 64 KiB, and ends each direction on its own
  (`RemoteAccessTunnel.StreamEnds`): a normal end finishes, a failure resets or
  stops with code 1, and a host that sends nothing (or no socket) is code 2.
  `TunnelSocket` reads and writes the Unix socket without a thread per stream.
- `RemoteAccessMapping` maps UDP 38842 through `PortMapper` (below) and decides
  the reported addresses with `RemoteAccessMappingPlan`; it never maps while
  another program holds the port.
- `RemoteAccessAddressRecordWriter` keeps the `RemoteAccessAddress` record in
  the owner's private iCloud database (zone `RemoteAccess`, encrypted fields;
  schema in `CloudKit/schema.ckdb`), one change at a time, retried with the
  notice relay's backoff; a write never lands after the delete that followed it.

`PortMapper` asks the router with PCP, or NAT-PMP, for UDP 38842 (never
Tailscale's 41641), with 2-hour leases renewed at half-life, a changed external
port reported, mappings made again after a router restart (its epoch), and every
mapping deleted on stop, after any renewal already in flight. A mapping is known
by its transport and internal port, whatever external port the router grants.
Each mapping is recorded with its PCP nonce in
`~/Library/Application Support/AgentLand/RemoteAccess/port-mappings.json` (0600,
folder 0700) before every request that makes or renews it, until the router
confirms its delete, so after a crash, a lost answer or an unanswered delete the
next run deletes it or takes it over; a PCP router accepts neither with another
nonce. One mapper at a time owns the records, with a lock on
`port-mappings.lock` from its first request until it holds nothing; another copy
of AgentLand gets "Another copy of AgentLand is managing this Mac's router
mappings", sends nothing and changes no record. `DefaultGateway` reads the
router's address from the routing table and its link-layer address from the ARP
table; both only read. An attempt the router did not answer keeps the last
mapping's addresses only on the same router and only until that mapping's lease
ends; while no mapping is held it retries after 15 s, 30 s, 1, 2 and 5 minutes
and then every 10 minutes.

Tests: `MacTunnelBridgeTests` (stream ends against a fake socket host),
`RemoteAccessMappingTests` and `PortMapperTests` (a fake router on loopback),
`RemoteAccessServiceTests` (the reports, the gate's list, the fallback's relay,
Quit, a port in use, the launch cleanup), `RemoteAccessAddressRecordWriterTests`
and `RemoteAccessSummaryTests`. `RemoteAccessEndToEndTests` builds a host, starts
it with its tunnel socket, runs the service with a real endpoint and has a
phone-side dialer pair a node ID and speak HTTPS through the tunnel (503 before
the first list, 403 for a stranger); opt in with
`AGENTLAND_TEST_REMOTE_ACCESS=1`. Run the bundle under the profile that refuses
the router's port-mapping ports:

```sh
cd macos
swift build --build-tests
sandbox-exec -f ../shared/AgentLandIroh/Tests/router-ports-denied.sb \
  xcrun xctest .build/debug/AgentLandDesktopPackageTests.xctest
```

The phone's endpoint, bridge and routes are `../shared/AgentLandRemoteAccess` and
the iOS app. The package's `agentland-remote-access-loopback` product
(`Tools/RemoteAccessLoopback`, never bundled) runs this service with "Reach this
Mac from anywhere" on for the phone's simulator UI test
(`../integration/check-ios-product.py`, `testConnectsThroughIrohTunnel`): an
in-memory key instead of the Keychain, a free UDP port instead of 38842, a PCP
stand-in on 127.0.0.1 (`LoopbackRouter`) instead of the router, and no iCloud
record. The harness runs it, and the host, under the profile above. Nothing here
ran against a real router, a public relay or a phone outside this Mac.

## Notifications on iPhone and iPad

AgentLand sends notices through your own iCloud: no AgentLand server is
involved. While its managed HTTPS host runs, `NoticeRelay` reads the host's
local notice feed with the app's local session (`GET /v1/notices`, a 20-second
long-poll) and writes each notice as a `Notice` record in the private database
of `iCloud.dev.agentland`. iPhone and iPad signed in to the same Apple Account
subscribe to those records and show the alerts: "Reply ready", "Needs your
approval" and so on, with the chat title and the project. Message
text is never sent; the host does not provide it. The records, alert text and
subscriptions are in `shared/AgentLandNotifications`.

The relay writes each page of notices in one CloudKit request under
deterministic record names, so a retry never adds a second alert. It waits as
long as CloudKit's `retryAfterSeconds` asks, backs off on other errors, drops
notices older than 10 minutes instead of alerting late, acknowledges only
notices it wrote or dropped, starts over when the host does (`resync`), and
once an hour deletes this host's records older than 24 hours. It stops with
the host on Disconnect and Quit and never holds Quit up for more than about a
second. The relay belongs to `HostController`, not to a window.

**Settings → Notifications** shows the iCloud account state and what to do
about it, and has **Send notifications to my iPhone and iPad** (on),
**Include chat titles** (on; off leaves out chat titles, which can contain
words from the chat) and **Send Test
Notification** (one "Reply ready" notice titled "Test from AgentLand"). Turning
sending on does not send what happened while it was off. The two settings are
saved in the app's preferences under `dev.agentland.desktop.notifications.v1`.

CloudKit is used only by a copy signed with the iCloud entitlements and when
`AGENTLAND_CLOUDKIT=0` is not set; otherwise the relay stays off and Settings
says why. Ad-hoc builds and `swift test` never create a CloudKit container.
Apply the CloudKit schema in `CloudKit/schema.ckdb` once
(`CloudKit/README.md`): the subscriptions and the cleanup need its indexes.

## Current limits and tests

The app is macOS-only. The Go host can cross-compile as a CLI for Windows and
Linux, but native desktop GUI and tray behavior on those platforms remain
unverified.

Run the desktop tests with:

```sh
swift test --package-path macos
```

The suite covers argument construction, certificate identity and hostname
validation, project preservation, owned-child lifecycle shutdown, redacted
launch errors, concurrent large stdout/stderr draining, bounded output
truncation, and timeout escalation. The host's managed OpenCode is covered by
`ManagedOpenCodeBinaryTests` (a host-made agents folder in a temporary folder:
the valid choice, a program outside the folder, a link that leads out, a
checksum mismatch, a missing program, folders and programs others can change,
malformed records, nothing bundled, the previous version checked like the
current one, and a version that did not start skipped as either),
`ManagedOpenCodeRuntimeTests` (stand-in programs: the previous version at once,
a hanging one stopped first, one more start after a timeout, the failure kept
and reported until the host keeps it no more, nothing remembered when the
previous one fails too, no OpenCode without a previous version, and the data
put back only after a version's first start), `OpenCodeDataGuardTests` (the
snapshots, the failed data folders and their order in temporary folders),
`OpenCodeInstallerTests` (`install-opencode`'s lines from a stub host script,
failures, a too-long line, the time limit and cancelling), `OpenCodeSetupTests`
(the controller with a fake command and runtime: nothing downloads while a
valid OpenCode exists, the progress before OpenCode and the host start, the
host without OpenCode and Try Again, onboarding, the report once the host
runs), `HostAgentsTests` (`GET /v1/agents` and the failure report through a
fake transport, and the restart rule), `OpenCodeIdleRestartTests` (the idle
restart and provider keys with a fake host catalog, runtime, host process and
Keychain) and `OpenCodeProviderListTests` (OpenCode's `GET /provider`).
`AGENTLAND_TEST_MANAGED_OPENCODE=/absolute/path/to/opencode` opts in to two
checks with the real program copied into an agents folder and disposable state
(no prompt is sent): the provider catalog, and the program running as the
host's. The notice relay runs against a fake host
behind `URLProtocol` and the in-memory CloudKit database with virtual time:
long-polling, one write per page, `retryAfterSeconds`, stale notices,
acknowledgement order, `resync`, the hourly cleanup, the titles setting, a
build without the iCloud entitlement, and stopping. A bounded local HTTPS,
Bonjour, and QR runtime check uses disposable state when run with:

```sh
AGENTLAND_TEST_HOST_READINESS=1 swift test --package-path macos
AGENTLAND_TEST_ONBOARDING=1 AGENTLAND_OPENCODE_TEST_BINARY=/absolute/path/to/opencode swift test --package-path macos --filter OnboardingIntegrationTests
```

The host-readiness check builds its own temporary Go host and certificate,
then verifies the pinned health response, Bonjour advertisement and withdrawal,
and QR decoding. The onboarding check puts the supplied OpenCode executable where
the host installs it, in disposable state, so nothing downloads. Neither launches the GUI, installs an app, or changes a
user's persistent host configuration.

Check the packaged menu-bar interface using a re-signed, isolated copy with
bundle ID `dev.agentland.desktop.uitest`:

```sh
swift integration/check-mac-controls.swift /path/to/TestAgentLand.app /tmp/agentland-ui-evidence
```

The bounded check uses disposable settings and host state, verifies a configured
launch without a window or Dock icon, opens each Settings tab, closes the
window without quitting, and invokes explicit Quit AgentLand Server. It requires
Accessibility and Screen Recording access and preserves the installed owner app.

Browser checks use local fixtures and do not send model prompts:

```sh
npm --prefix web test
npm --prefix web run test:browser
AGENTLAND_WEB_BROWSER_TEST=1 go -C desktop test -run TestLocalWebBrowserSmoke -count=1
```

Install the Playwright Chromium and WebKit browsers before the browser suite.
The opt-in Go check serves the production bundle, so run `scripts/build-web.sh`
first. `check-mac-session.swift` is retained as a historical native-workspace
check; it is not applicable to the browser workspace.
