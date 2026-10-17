# AgentLandArchive

This device's copy of a paired host's archive (docs/HOST-API.md, "Archive"): every chat, readable and searchable offline, terminal logs fetched when they are viewed, attachment files fetched when they are opened, and Continue with another model. The Mac keeps the original; this copy mirrors it, so nothing is lost on the phone or iPad if model access goes away.

Shared by iPhone, iPad and Mac (iOS 26, macOS 26). Not wired into the apps' navigation yet; the navigation phase adds the sidebar entries.

## What syncs, and when

- `SyncEngine` copies the host's change feed (`GET /v1/archive/changes`, 200 changes a page) into `ArchiveStore`: chats, messages with their parts (rewound messages kept and marked hidden), terminal log metadata and deletions.
- It runs only while the app model has started it: in the foreground, unlocked, with the host reachable, and only for hosts whose capabilities list `archive` with `sync`. It never watches app state itself. It reads page by page until `hasMore` is false. Then, from hosts that list `changesWait`, it asks again at once with a 20-second long-poll (`wait`) that the host answers as soon as something changes; an empty answer that comes back within a second (a host that is stopping) waits out that second. Older hosts are asked again every 30 seconds, without `wait`. `resume(connectionEpoch:)` after a reconnect and `syncNow()` sync at once, dropping a long-poll that may hang on the old connection.
- Each page is one transaction together with its cursor and epoch. A stop or a crash before the commit leaves the previous cursor, and applying a page again changes nothing.
- A page with `resync: true` clears the copy before it is applied (pins stay). A cursor the host refuses (`invalid_cursor`) clears the copy and starts over once.
- Failures wait 1, 2, 4, 8, 16, 32 and then 60 seconds between attempts, one request per attempt. 401 or 403 stops the engine (`.refused`) until the app gives it new credentials with `update(feed:capabilities:)`; `archive_unavailable` stops it as `.unavailable`.
- Terminal output is not synced. `TerminalLogCache` fetches `terminal-log` ranges (1 MiB each) only when the viewer shows them.
- Attachment bytes are not synced either, only each file's name, type, size and SHA-256 (a size without a SHA-256 means the host kept the name only). `AttachmentCache` fetches a file from `GET /v1/archive/blob` when someone opens it, from hosts that list `blobs`, sending the SHA-256 when the copy has it.
- Pins are this device's own and are never sent to the host.

## Storage

- **Database:** SQLite through GRDB 7.11.1 (MIT, pinned exactly; license in `ios/AgentLand/GRDB-LICENSE.txt` and `macos/licenses/GRDB-LICENSE.txt`), in WAL mode. One database per host identity: `ConnectionIdentity.storageKey`, the host address and device credential that `WorkspacePersistence` keys tabs by. The folder is named by that key's SHA-256: `Application Support/<bundle id>/Archive/<hash>/archive.sqlite`.
- **Protection:** on iOS the folder and the database files are `completeUntilFirstUserAuthentication`, so the engine can write after the first unlock. The folder is excluded from backups (iCloud, Finder, Time Machine): it mirrors the Mac.
- **Schema** (plain SQL, `ArchiveSchema`): `meta`, `sync_state` (host key, epoch, cursor), `chats`, `messages` (unique per chat, since every continued chat has an `agentland-seed` message; parts as JSON; `text` holds the text parts for search, at most 256 KiB, like the host), `terminal_logs` (metadata only) and `pins`. Times are milliseconds since 1970, UTC. Observed tables keep their rowid, because SQLite reports no changes to WITHOUT ROWID tables.
- **Full-text search:** FTS5 when a runtime probe (`CREATE VIRTUAL TABLE temp… USING fts5`) works, FTS4 otherwise; the choice is recorded in `meta`. Both are external-content indexes over `messages.text`, kept in step by triggers, with `unicode61` and diacritics removed. Terms are always quoted (never query syntax), all are required, and the last is a prefix while it is typed. Results rank by BM25: built in for FTS5, computed from `matchinfo` for FTS4. Snippets mark matches with U+0002/U+0003, like the host's, and render as emphasis. Rewound messages are not searched.
- **Terminal ranges:** `Caches/<bundle id>/TerminalLogs/<hash>/`, at most 256 MiB per host, least recently used out first; the system may purge it. A range is kept only once it can no longer change: the terminal has ended, or it is a full raw range.
- **Clearing and forgetting:** iPhone and iPad Settings → Privacy & Security clears the selected host's copy (`WorkspaceArchive.clearCopy`: the engine stops, `ArchiveStore.startOver` drops the chats, messages, terminal logs and cursor, pins stay, both caches empty, and the engine starts again, so the copy is made again from the host). Forgetting a host deletes its folders, the database and both caches (`ArchiveLocation.removeDeviceCopy`), once its copy has closed.
- **Attachment files:** `Caches/<bundle id>/Attachments/<hash>/`, a separate 256 MiB per host, least recently used out first; the system may purge it. Each file sits in its own folder under its own name (no folders, no leading dot, at most 120 characters), so Quick Look and the share sheet show it. A chat's files go when the chat is deleted.

## Using it from the app model

```swift
let store = try ArchiveStore.open(for: identity)                 // one per paired host
let engine = SyncEngine(store: store, feed: client, capabilities: capabilities)
await engine.start()                                              // foreground, unlocked, reachable
await engine.stop()                                               // background, locked, offline
await engine.resume(connectionEpoch: connectionEpoch)             // after a reconnect
await engine.update(feed: newClient, capabilities: newCapabilities)
for await status in await engine.statusUpdates() { … }            // .syncing, .upToDate, .waiting, .refused …

// Chats open from the archive first (AgentLandChat's ChatTranscriptCache).
ChatSessionStore(identity: …, transcriptCache: ArchiveTranscriptCache(store: store))

// Screens.
let logs = try TerminalLogCache.open(for: identity)
let files = try AttachmentCache.open(for: identity)
let environment = ArchiveEnvironment(client: client, capabilities: capabilities, reachable: reachable,
                                     hostName: host.name, workspaces: names, sync: status)
ArchiveBrowser(model: ArchiveBrowserModel(store: store, environment: environment), terminalCache: logs, attachmentCache: files,
               actions: ArchiveActions(openChat: { chat in … }, continued: { result in … }))
```

`ArchiveActions.openChat` returns false when the host no longer has the chat live; the browser then shows the archived copy. `continued` gets `.chat(Session)` from the host's `POST /v1/chat/continue`, or `.draft(ContinueDraft)` on hosts without Continue: a new chat of the chosen agent with the transcript attached as Markdown (or inline when the host takes no attachments) and a message to edit. The app puts the draft in the composer; nothing sends it.

## Screens

- `ArchiveBrowser`: Chats and Terminals. The library groups chats as Pinned, Today, Yesterday, This Week and then by month, by last activity in the device's time zone. `.searchable` with chips for agent, workspace and date range; chat titles match at once on the device; message results come from the host when it can be reached and from this device otherwise, and the section header says which. Swipe (and the context menu) to Pin or Delete; Delete asks first, calls `POST /v1/archive/delete`, and removes the device's copy only when the host answers `deleted`.
- `ArchivedChatView`: a read-only transcript (Markdown replies, reasoning, tool calls and changed files collapsed), from this device, or from the host's pages when it has no copy yet. Export (Markdown, JSON), Continue with…, Pin, and Open Chat when the app offers it. With an `AttachmentCache`, tapping an attachment opens it in Quick Look (fetched from the host the first time, with a spinner in its chip) and its context menu shares it; a file the host kept by name only stays a plain label, and a notice says why a file did not open (offline and not saved, a host without `blobs`, a name-only file).
- `ContinueChatSheet`: agent, model, mode and effort from the host's chat options, the message to stop at, and the context size with a preview (messages carried, characters, about how many tokens) computed on the device with the host's seed rules.
- `TerminalLogViewer`: a 2 MiB window of the log, newest first, replayed into a read-only SwiftTerm view that never takes the keyboard and has no key bar, or as text (`format=text`). It says how much output was not recorded (`gapBytes`), when earlier or later output is outside the window, and when the terminal still runs.

All text uses AgentLandDesign's type roles, controls meet the platform tap target, and rows have no glass. Previews use `ArchivePreviewData`.

## Limits

- Not in the apps yet: no navigation entry, and the iOS Settings list and the Mac bundle script do not list the GRDB notice until the package is linked.
- Host search results name each chat's agent (`provider`); from hosts before that field, the row shows the agent only when this device has the chat. The host searches message text only; titles are matched on the device.
- Attachment bytes are fetched only when opened, and only from hosts that list `blobs`. Copies synced before attachment sizes were decoded cannot tell a name-only file apart, so they offer every attachment and the host's answer (`attachment_not_archived`) shows as a notice.
- A terminal window that starts mid-log replays into a fresh terminal, so colors or screen state from before the window are missing. On the Mac the replay keeps selection but not ⌘C; Text mode copies.
- Offline exports are made from this device's copy: Markdown in Copy Chat's form, JSON of the copy with rewound messages marked. They are not byte-identical to the host's exports.
- The Continue preview is computed on the device; the host's seed can differ by a few characters.
- The cut-off goes out as `throughMessageId` only to hosts that list `continueThrough` (docs/HOST-API.md); an unknown or rewound message answers 400 `invalid_through_message`, which the sheet shows.
- File protection and backup exclusion run on iOS only on a device or simulator; the unit tests check the backup flag on macOS.

## Tests

```sh
swift test --package-path shared/AgentLandArchive
```

Store migrations (including indexing messages stored before the full-text step), the FTS5 probe and the FTS4 fallback with the same results and ranking, idempotent pages, resync clearing with pins kept, cursor persistence across a crash mid-page, tombstones and unreadable changes, the chat cache, observation; the sync engine's paging, backoff timing on an injected clock, resume, refusal, capabilities and a stuck page; its long-poll (`wait` only where advertised, no timer, the one-second gap after an early empty answer, backoff and a plain request after a failure, stop, start and resume dropping a waiting request); terminal ranges on demand, the running tail, least-recently-used eviction and relaunch, and the viewer's windows; attachment files on demand (one request for two opens at once, offline reads, a name-only file, relaunch, least-recently-used eviction, a chat's files dropped with it, safe file names) and the chat's open rules and notices; library grouping across day boundaries, time zones and a daylight-saving change; snippet rendering; chip-to-query mapping; delete after confirmation; host and device search; the Continue seed rules, the cut-off only where advertised, and the draft for hosts without Continue; export with its offline fallback.
