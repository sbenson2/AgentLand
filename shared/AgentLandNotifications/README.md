# AgentLandNotifications

Push notifications through the owner's own iCloud, with no AgentLand server.
The Mac app relays its host's notices (docs/HOST-API.md, "Presence and
notices") as CloudKit records in the owner's private database; iPhone and iPad
subscribe to those records, and iOS shows the alerts. A notice never holds
message text or a credential.

This package holds what both sides share: the record schema, the alert text,
the subscriptions, the push parser and a small database protocol, plus the
subscriber's model and tap route that iPhone and iPad use (`NotificationsModel`,
`NoticeRoute`). The Mac relay is `NoticeRelay` in
`macos/Sources/AgentLandDesktopCore`; the iOS app's side is in `ios/AgentLand`
(`AppDelegate.swift`, `AppModel+Notices.swift`, `NotificationsSettingsPane.swift`).
iOS 26 / macOS 26, Swift tools 6.2.

## Record

Container `iCloud.dev.agentland` (`NoticeRecord.containerIdentifier`), private
database, custom zone `Notices`, record type `Notice`:

| Field | Type | |
|---|---|---|
| `kind` | String | one of the four kinds below; queryable |
| `hostId` | String | `NoticeHostID` of the Mac's host; queryable |
| `projectId`, `projectName` | String | the project |
| `sessionId` | String, optional | when the notice names a chat |
| `title` | String, optional | the chat's title; absent when there is none, or when "Include chat titles" is off and the host marked it `mayContainContent` |
| `createdAt` | Date | when the host issued the notice; queryable and sortable |
| `alertBody` | String | the alert body the Mac composed, at most 100 UTF-16 units |

`macos/CloudKit/schema.ckdb` declares the type and its indexes; the indexes
must be applied before subscriptions can be saved (macos/CloudKit/README.md).
It also declares `scheduleId` and `runId`, unused since schedules were removed
on 2026-10-06: a field deployed to Production cannot be deleted.

**Record names** are `<hostId>-<notice id>` (`NoticeRecord.recordName`), so
writing a notice again updates the same record and the creation-only
subscriptions do not alert twice. The host's `id` is used rather than its
`seq`: `seq` starts over when the host's notice epoch changes. IDs outside
`A–Z a–z 0–9 _ . -` or over 100 characters are replaced by a hash. The test
notice is `<hostId>-test-<uuid>`.

**`hostId`** (`NoticeHostID.make(certificateSHA256:)`) is 32 hex digits of
SHA-256 over `agentland.notice.host.v1:<fingerprint>`, the fingerprint being
the host's TLS certificate SHA-256 (public; Bonjour and the pairing QR carry
it). iPhone and iPad find the host of a notice by deriving the same value
from the fingerprint they pinned when pairing.

CloudKit builds the alert on its servers from `alertBody`, so the fields
cannot use CloudKit's encrypted values. "Include chat titles" on the Mac is
the control for what reaches them.

## Alert text

| Kind | Title key | Title |
|---|---|---|
| `chat.turn.finished` | `notice.title.chat.turn.finished` | Reply ready |
| `chat.turn.failed` | `notice.title.chat.turn.failed` | Reply failed |
| `chat.approval.needed` | `notice.title.chat.approval.needed` | Needs your approval |
| `chat.question.needed` | `notice.title.chat.question.needed` | Question for you |

Body: "<title> · <project>", or the project alone when there is no title
(`NoticeAlertText.body`). The Mac composes it with `notice.body.titleAndProject`
("%1$@ · %2$@") into `alertBody`, cutting the project to 40 and the whole to
100 UTF-16 units with an ellipsis (CloudKit may cut longer values in a push).
The subscriptions show it through `notice.body` ("%@") with
`alertLocalizationArgs` `["alertBody"]`. Composing on the Mac keeps a missing
title from leaving an empty slot in the alert.

The strings are in `Sources/AgentLandNotifications/Resources/Localizable.xcstrings`.
**The iOS app must carry the same five keys** (`NoticeAlertText.appLocalizationKeys`:
the four titles and `notice.body`) with the same text in its own
`Localizable.xcstrings`: iOS resolves a push's localization keys in the app's
main bundle only. An app test can assert that
`NoticeAlertText.keysMissingOrDifferent(in: .main)` is empty.

Xcode compiles the catalog into `Localizable.strings`; SwiftPM on the command
line copies it uncompiled, so `NoticeAlertText.localized` reads the catalog
itself when the compiled table is missing (under `swift test`).

## Subscriptions (iPhone and iPad)

`NoticeSubscriptionPlan(enabledKinds:)` gives one `CKQuerySubscription` per
enabled kind: ID `agentland.notice.<kind>`, record type `Notice`, predicate
`kind == "<kind>"`, zone `Notices`, `.firesOnRecordCreation` only. Notification
info: `titleLocalizationKey` of the kind, `alertLocalizationKey` `notice.body`
with args `["alertBody"]`, `soundName` "default" (or, with the sound off,
`agentland-silent.caf`), `desiredKeys` `projectId`, `sessionId`. `subscriptionIDsToDelete` lists the kinds turned off,
then `retiredSubscriptionIDs`: the three `agentland.notice.schedule.run.*`
subscriptions earlier plans saved, before schedules were removed on 2026-10-06.
Plan version 2 makes each device that saved version 1 save once more when it
comes to the foreground, which deletes them (deleting one already gone counts
as done).
`NotificationsModel` saves them with `NoticeDatabase.modifySubscriptions` (one
`CKModifySubscriptionsOperation` in the private database) and keeps
`NoticeSubscriptionPlan.version` to save them again when it changes.
Subscriptions belong to the iCloud account, so they apply to every device
signed in to it.

Settings shows them as two `NoticeGroup`s: `replies` (turn finished, turn
failed) and `approvals` (approval needed, question needed). A group counts as
on when any of its kinds is subscribed; saving always writes whole groups. A
saved group this build does not know (`scheduledRuns`) is left out.

Checked against Apple's documentation:

- `CKQuerySubscription`: "You can set the subscription's zoneID property to
  further specialize the subscription to a specific record zone in the
  database" and "Only public and private databases support query
  subscriptions". Custom zones exist only in private databases, so the custom
  `Notices` zone is supported.
- `NotificationInfo.desiredKeys`: "You can request a maximum of three keys",
  and CloudKit "may truncate strings that are more than 100 characters". The
  kind therefore comes from the subscription ID and the host from the record
  name.
- `NotificationInfo`: without `alertBody`, `soundName` or `shouldBadge`,
  "CloudKit sends the push notification using a lower priority and doesn't
  display any content to the user" — hence the sound. With the sound off
  (`NoticeSubscriptionPlan(enabledKinds:sound: false)`) the subscriptions
  name `NoticeSubscriptionPlan.silentSoundName`, a quarter second of silence
  the iOS app bundles (`ios/AgentLand/agentland-silent.caf`), rather than no
  sound. iOS plays the default sound for a name its bundle lacks, so a device
  with an older build still alerts with sound.

## Deep links

`NoticeDeepLink(remoteNotification: userInfo)` (or `init(notification:)`)
reads a push: nil unless it is a query notification of one of these
subscriptions in the private database's `Notices` zone. It gives `kind`,
`hostID`, `recordName`, `projectID`, `sessionID` and a `destination`:
`.chat(sessionID)` for replies, `.pendingInteraction(sessionID)` for approvals
and questions, `.project` otherwise (the test notice). When `isComplete` is false (the push was pruned, a value may have been cut, or
`projectId` is missing), fetch the record by `recordName` in the `Notices`
zone and use `NoticeDeepLink(record: NoticeRecord(record:))`. The link is
`Codable`, so it can be held until the app unlocks.

`link.showsAlert(whileShowing:)` decides a notice that arrives while the app is
in front: no alert when it names the chat on screen (`NoticeVisibleChat`: the
selected host's `NoticeHostID` and the selected chat), an alert otherwise.

## Tapped notices

`NoticeRoute(link:)` takes a tapped notice to the screen it names, one
`next(in: NoticeRouteState)` step at a time; the app runs the steps through its
own paths:

1. `.fetchRecord` for a push that left values out (once, even while locked);
   the app calls `recordFetched(_:)` with `NotificationsModel.completeLink(_:)`.
2. `.wait` until the app is unlocked, in front and the opening cover has
   cleared.
3. `.selectHost(id)` when the notice's host is another saved host (the saved
   host whose pinned fingerprint gives `NoticeHostID.make(certificateSHA256:) ==
   link.hostID`; the selected host wins a tie). From then on the route no
   longer waits for a cover, so it opens behind the new host's opening cover.
4. `.wait` until the host's projects answer, then `.open(.chat(projectID:
   sessionID:))` for replies, approvals and questions (a pending approval or
   question shows at the end of its chat), or `.open(.workspace(projectID:))`
   for the test notice.
5. `.unknownHost` when no saved host matches (also a host saved without a
   pinned fingerprint), `.projectMissing` when the host's project list no longer
   has the project, `.done` when the notice names no project. A host whose
   projects could not load (offline, needs pairing) still opens the chat, which
   shows its own state.

## iPhone and iPad: `NotificationsModel`

`@MainActor @Observable`, built with a `NoticeSystem` (the permission and the
push registration; the app's is `UNUserNotificationCenter` and `UIApplication`),
`NoticeCloudKit.unavailability(environment:)` and a database factory that runs
only when iCloud is first needed.

- **Permission only in context.** `setGroup(_:enabled:)` turning a group on and
  `requestPermission()` ask when the permission was never asked;
  `sceneBecameActive()` never asks. It reads the permission, calls
  `registerForRemoteNotifications()` once it is allowed, and saves the
  account's subscriptions again when this device last saved another
  `NoticeSubscriptionPlan.version`. Without CloudKit it asks nothing.
- **Changes start from the account.** A change checks the account
  (`accountStatus()`), reads the account's subscription IDs (another device may
  have changed them), creates the `Notices` zone when any kind is on, and saves
  one plan: the enabled kinds' subscriptions and deletions for
  `subscriptionIDsToDelete`. A missing zone is created again once. Turning a
  group off needs no permission.
- **Sound.** `setSound(_:)` saves every notice subscription again with the
  default or the silent sound (no permission needed); the account's sound is
  read with its groups (`NoticeDatabase.subscriptions()`, off when every notice
  subscription is silent), and with nothing subscribed the choice waits on
  this device (`agentland.notifications.sound`) for the next group turned on.
  It belongs to the account, so it applies to every device on it.
- **State for Settings.** `permission`, `account` (`unavailable`, `unknown`,
  `checking`, `status(NoticeAccountStatus)`, `checkFailed`), `enabledGroups`
  and `displayedGroups` (a change in progress shows at once), `soundOn` and
  `displayedSound`, `working`,
  `problem` (`NoticeSetupProblem`) and `registrationError`. `refresh()` reads
  the permission, the account and its groups; `accountChanged()` follows
  `CKAccountChanged` once the account was looked at.
- **The tip.** `observeChatTurn(_:at:)` takes the selected chat's turn; a turn
  longer than `tipTurnDuration` (30 s) that ends with its chat still selected
  sets `tipVisible`, once per device (`agentland.notifications.tipShown`), only
  while the permission was never asked and CloudKit is on. `acceptTip()` asks
  for permission and turns every group on.
- **iCloud only when used.** Nothing makes a `CKContainer` until a Settings
  control or pane, the tip, a version change or an incomplete tapped push needs
  it. User defaults: `agentland.notifications.subscriptionVersion`,
  `…groups`, `…tipShown`.

## Database

`NoticeDatabase` is the CloudKit calls notices use. The Mac's: `accountStatus()`,
`createZone()`, `save(_:)` (one modify operation, not atomic, `.allKeys`, a
result per record) and `deleteRecords(hostID:createdBefore:limit:)` (a query
and deletes). iPhone's and iPad's: `subscriptionIDs()` (`allSubscriptions`),
`modifySubscriptions(saving:deleting:)` (one modify operation, not atomic, an
outcome per ID; deleting a gone subscription counts as done) and
`record(named:)` (nil when the record is gone). A database that only writes
notices, like the Mac relay's test doubles, gets versions of the subscriber's
calls that throw `NoticeDatabaseUnsupported` (classified `.rejected`).
`CloudKitNoticeDatabase` is the real one; `NoticeFailure` classifies its errors
(retry after `retryAfterSeconds`, zone missing, account, quota, rejected).
`InMemoryNoticeDatabase` in the `AgentLandNotificationsTesting` product is for
tests; it scripts failures (per call, record or subscription), needs the zone
like CloudKit does for records and zone subscriptions, tells creations from
updates, and records the subscriber's calls in `subscriberEvents`, apart from
the relay's `events`. Tests never touch CloudKit.

`CKContainer(identifier:)` stops a process that lacks the iCloud entitlement.
`NoticeCloudKit.makeDatabase()` returns a database only when
`NoticeCloudKit.unavailability()` is nil: `AGENTLAND_CLOUDKIT` is not `0`, and
on macOS the signed app carries `com.apple.developer.icloud-container-identifiers`
with `iCloud.dev.agentland` and `com.apple.developer.icloud-services` with
`CloudKit` (read with `SecTaskCopyValueForEntitlement`). iOS has no such call;
the iOS app carries the entitlements (`ios/AgentLand/AgentLand.entitlements`)
and turns CloudKit off itself for test runs: the unit tests' host gets
`AGENTLAND_CLOUDKIT=0` from the scheme, and launches with `-AgentLandUITests…`
flags or under XCTest count as off (`AppModel.cloudKitEnvironment`).

## The iOS app

- Entitlements: `aps-environment` (development), `com.apple.developer.icloud-container-identifiers`
  `[iCloud.dev.agentland]`, `com.apple.developer.icloud-services` `[CloudKit]`.
  No `remote-notification` background mode: iOS shows the alerts, and taps and
  foreground arrivals reach `UNUserNotificationCenterDelegate` without it.
- The eight localization keys in the app's `Localizable.xcstrings`
  (`NotificationTests.testTheAppCarriesTheNoticeAlertText`).
- `AgentLandAppDelegate` owns the app model, sets the notification center's
  delegate before launching finishes, and forwards taps (`openNotice`),
  foreground arrivals (`presentationOptions(for:)`), the registration result and
  `CKAccountChanged`.
- Settings → Notifications: this device's permission (Open Settings when it is
  off), the two groups and the alerts' Sound (for every device on the Apple
  ID), the iCloud account, and where chat titles are set (the Mac's "Include
  chat titles"). With the sound off an alert shown in front plays none either.
- `agentland-silent.caf` in the app's bundle (`NotificationTests`).
- The schema in `macos/CloudKit/schema.ckdb` applied to the environment the
  build uses; without its `kind` index CloudKit refuses the subscriptions and
  Settings shows CloudKit's message.

## Tests

```sh
swift test --package-path shared/AgentLandNotifications
```

Record mapping and names, the host ID vector, alert text and the 100-unit
limit, the catalog and the app-bundle check, the subscription plan and groups,
the push parser (with payloads CloudKit's own parser reads), the entitlement
gate, error classification, the in-memory database (records, subscriptions,
reads), CloudKit's per-ID subscription outcomes, `NotificationsModel`
(permission only in context, saving and deleting subscriptions, another
device's choices, versions, account states, CloudKit off, a missing zone,
refused saves, the tip, completing a link) and `NoticeRoute` (waiting for
unlock and the cover, fetching, switching host, destinations, unknown hosts and
projects, foreground alerts).
