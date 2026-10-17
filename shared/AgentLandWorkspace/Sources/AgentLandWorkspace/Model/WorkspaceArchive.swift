import Foundation
import Observation
import AgentLandCore
import AgentLandChat
import AgentLandArchive

/// One paired host's copy on this device (AgentLandArchive): the store the chat library, search and
/// chats read, the caches for terminal logs and attachment files, and the sync engine. The owning
/// app model drives the engine: it runs only in the foreground, unlocked, with the host reachable.
@MainActor @Observable public final class WorkspaceArchive {
    public let store: ArchiveStore
    /// Terminal output fetched when a log is viewed; nil when this device cannot keep it.
    public let terminalLogs: TerminalLogCache?
    /// Attachment files fetched when opened; nil when this device cannot keep them.
    public let attachments: AttachmentCache?
    /// The engine's latest status (syncing, up to date, refused …).
    public private(set) var status: SyncEngine.Status?

    @ObservationIgnored public let engine: SyncEngine
    /// Runs when the host's change feed moves to another epoch after the first one this copy saw.
    /// Adding, creating or removing a workspace on any device does (docs/HOST-API.md, "Workspaces"),
    /// so the owner reads the host's workspaces again.
    @ObservationIgnored public var onEpochChange: (@MainActor () -> Void)?
    /// Runs each time the copy has caught up with the host (the engine reports `upToDate`).
    @ObservationIgnored public var onCaughtUp: (@MainActor () -> Void)?
    @ObservationIgnored private var seenEpoch: String?
    @ObservationIgnored private var seenPages = 0
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    /// Commands reach the engine in the order they were given.
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var running = false
    @ObservationIgnored private var feed: APIClient?
    @ObservationIgnored private var capabilities: CapabilitiesResponse?
    @ObservationIgnored private var closed = false

    public init(store: ArchiveStore, terminalLogs: TerminalLogCache?, attachments: AttachmentCache?, client: APIClient?,
                engine: SyncEngine? = nil) {
        self.store = store
        self.terminalLogs = terminalLogs
        self.attachments = attachments
        self.feed = client
        self.engine = engine ?? SyncEngine(store: store, feed: client, capabilities: nil)
        let updates = self.engine
        statusTask = Task { [weak self] in
            for await status in await updates.statusUpdates() {
                guard let self, !self.closed else { return }
                self.status = status
                // A page was applied: its epoch is in the store now.
                if status.pagesApplied != self.seenPages {
                    self.seenPages = status.pagesApplied
                    await self.noteEpoch()
                }
                if status.phase == .upToDate, !self.closed { self.onCaughtUp?() }
            }
        }
    }

    private func noteEpoch() async {
        guard let epoch = try? await store.syncState().epoch, !closed else { return }
        let previous = seenEpoch
        seenEpoch = epoch
        if let previous, previous != epoch { onEpochChange?() }
    }

    /// Opens the copy of `identity`'s host, or nil when this device cannot keep one (the store could
    /// not be opened). The caches are optional: without them logs and attachments are not kept. The
    /// files open off the main actor: the database with its migrations, and the caches' folders.
    public static func open(for identity: ConnectionIdentity, client: APIClient?) async -> WorkspaceArchive? {
        let files = await Task.detached(priority: .userInitiated) { () -> Files? in
            guard let store = try? ArchiveStore.open(for: identity) else { return nil }
            return Files(store: store, terminalLogs: try? TerminalLogCache.open(for: identity),
                         attachments: try? AttachmentCache.open(for: identity))
        }.value
        guard let files else { return nil }
        return WorkspaceArchive(store: files.store, terminalLogs: files.terminalLogs, attachments: files.attachments, client: client)
    }

    /// Deletes this device's copy of `identity`'s host (its database and caches), off the main actor. Close the
    /// copy first (`WorkspaceModel.archiveClosing`).
    public static func removeDeviceCopy(for identity: ConnectionIdentity) async throws {
        try await Task.detached(priority: .utility) { try ArchiveLocation.removeDeviceCopy(for: identity) }.value
    }

    private struct Files: Sendable {
        let store: ArchiveStore
        let terminalLogs: TerminalLogCache?
        let attachments: AttachmentCache?
    }

    /// Chats read their saved copy before their first network load.
    public var transcriptCache: any ChatTranscriptCache { ArchiveTranscriptCache(store: store) }

    /// Whether the engine follows the host's changes: the app is in the foreground and unlocked, and
    /// the host is reachable. Repeating the same value changes nothing.
    public func setRunning(_ run: Bool) {
        guard !closed, run != running else { return }
        running = run
        let engine = engine
        enqueue { run ? await engine.start() : await engine.stop() }
    }

    /// The connection came back: sync at once, dropping a long-poll sent over the old connection.
    public func resume(connectionEpoch: Int) {
        guard !closed else { return }
        let engine = engine
        enqueue { await engine.resume(connectionEpoch: connectionEpoch) }
    }

    /// A new client or new capabilities for the same host. Unchanged values change nothing.
    public func update(client: APIClient?, capabilities: CapabilitiesResponse?) {
        guard !closed, client !== feed || capabilities != self.capabilities else { return }
        feed = client
        self.capabilities = capabilities
        let engine = engine
        enqueue { await engine.update(feed: client, capabilities: capabilities) }
    }

    /// Syncs now, as on pull to refresh.
    public func syncNow() {
        guard !closed else { return }
        let engine = engine
        enqueue { await engine.syncNow() }
    }

    /// Clears this device's copy (Settings → Privacy & Security): the engine stops, the chats, messages and
    /// terminal logs go with the cursor, so the copy is made again from the start (pins, this device's own, stay),
    /// and the terminal-log and attachment caches empty. The engine starts again if it was running. Drafts live
    /// with the tabs, not here. Throws when the database could not be cleared; the engine runs again either way.
    public func clearCopy() async throws {
        guard !closed else { return }
        let engine = engine, store = store, terminalLogs = terminalLogs, attachments = attachments
        // In order with the other commands: after those given before, and a start or stop given meanwhile after it.
        let previous = pending
        let clearing = Task { [weak self] () -> (any Error)? in
            await previous?.value
            await engine.stop()
            var failure: (any Error)?
            do { try await store.startOver() } catch { failure = error }
            if failure == nil {
                await terminalLogs?.removeAll()
                await attachments?.removeAll()
            }
            // The copy is made again from the start while the app wants it followed.
            if let self, self.running, !self.closed { await engine.start() }
            return failure
        }
        pending = Task { _ = await clearing.value }
        if let failure = await clearing.value { throw failure }
    }

    /// Waits for the commands given before (the stop of `close()` included) to reach the engine.
    public func settle() async {
        await pending?.value
    }

    /// Stops the engine for good: the host changed or was forgotten.
    public func close() {
        guard !closed else { return }
        let engine = engine
        enqueue { await engine.stop() }
        closed = true
        running = false
        statusTask?.cancel()
        statusTask = nil
    }

    private func enqueue(_ command: @escaping @Sendable () async -> Void) {
        let previous = pending
        pending = Task {
            await previous?.value
            await command()
        }
    }
}

/// The copy's transcripts for a chat made while the copy is still opening: read once it has opened.
struct OpeningArchiveTranscriptCache: ChatTranscriptCache {
    let opening: Task<WorkspaceArchive?, Never>

    func cachedTranscript(projectID: String, sessionID: String) async -> ChatSnapshot? {
        guard let archive = await opening.value else { return nil }
        return await ArchiveTranscriptCache(store: archive.store).cachedTranscript(projectID: projectID, sessionID: sessionID)
    }
}
