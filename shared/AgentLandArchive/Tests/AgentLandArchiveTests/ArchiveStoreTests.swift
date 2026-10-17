import Foundation
import GRDB
import XCTest
import AgentLandChat
import AgentLandCore
@testable import AgentLandArchive

final class ArchiveStoreTests: XCTestCase {
    private func search(_ store: ArchiveStore, _ text: String, limit: Int = 50, offset: Int = 0) async throws -> [String] {
        try await store.search(ArchiveSearchQuery(text: text), limit: limit, offset: offset).map(\.messageID)
    }

    // MARK: Migrations and files

    func testMigrationsCreateTheSchemaOnceAndAFileKeepsItsData() async throws {
        let folder = try TemporaryFolder()
        let location = folder.location()
        var store: ArchiveStore? = try ArchiveStore.open(at: location)
        try await store?.apply(Fixture.starter)
        let applied = try await store?.writer.read { db in try ArchiveSchema.migrator(forcing: nil, probeModule: "fts5").appliedMigrations(db) }
        XCTAssertEqual(applied, ["1-tables", "2-full-text"])
        store = nil

        let reopened = try ArchiveStore.open(at: location)
        let counts = try reopened.counts()
        XCTAssertEqual(counts.chats, 2)
        XCTAssertEqual(counts.messages, 3)
        XCTAssertEqual(counts.logs, 1)
        let state = try await reopened.syncState()
        XCTAssertEqual(state.cursor, "e1.6")
        XCTAssertEqual(state.epoch, "e1")
        XCTAssertEqual(state.hostKey, "https://mac.example|device-1")
        XCTAssertTrue(location.isExcludedFromBackup, "The copy mirrors the Mac, so backups skip it")
        XCTAssertTrue(FileManager.default.fileExists(atPath: location.databaseURL.path))
        XCTAssertFalse(location.directory.path.contains("mac.example"), "Folder names say nothing about the host")
    }

    func testEachHostHasItsOwnDatabase() throws {
        let folder = try TemporaryFolder()
        let first = ArchiveLocation.archive(hostKey: "https://mac.example|device-1", root: folder.url)
        _ = try ArchiveStore.open(at: first)
        XCTAssertThrowsError(try ArchiveStore.open(at: ArchiveLocation(hostKey: "https://other.example|device-9", directory: first.directory))) { error in
            XCTAssertEqual(error as? ArchiveStoreError, .otherHost)
        }
        let second = ArchiveLocation.archive(hostKey: "https://other.example|device-9", root: folder.url)
        XCTAssertNotEqual(second.directory, first.directory)
        XCTAssertEqual(first.directory.lastPathComponent, ArchiveLocation.folderName(for: "https://mac.example|device-1"))
        XCTAssertNoThrow(try ArchiveStore.open(at: second))
    }

    /// Forgetting a host deletes its database and both caches, and nothing of another host's.
    func testRemovingADeviceCopyDeletesThatHostsFilesOnly() throws {
        let support = try TemporaryFolder(), caches = try TemporaryFolder()
        let forgotten = "https://mac.example|device-1", kept = "https://other.example|device-9"
        for key in [forgotten, kept] {
            _ = try ArchiveStore.open(at: ArchiveLocation.archive(hostKey: key, root: support.url))
            for location in [ArchiveLocation.terminalLogCache(hostKey: key, root: caches.url),
                             ArchiveLocation.attachmentCache(hostKey: key, root: caches.url)] {
                try location.prepare()
                try Data("x".utf8).write(to: location.directory.appending(path: "range.chunk"))
            }
        }
        try ArchiveLocation.removeDeviceCopy(hostKey: forgotten, supportRoot: support.url, cachesRoot: caches.url)
        func exists(_ location: ArchiveLocation) -> Bool { FileManager.default.fileExists(atPath: location.directory.path) }
        XCTAssertFalse(exists(.archive(hostKey: forgotten, root: support.url)))
        XCTAssertFalse(exists(.terminalLogCache(hostKey: forgotten, root: caches.url)))
        XCTAssertFalse(exists(.attachmentCache(hostKey: forgotten, root: caches.url)))
        XCTAssertTrue(exists(.archive(hostKey: kept, root: support.url)))
        XCTAssertTrue(exists(.terminalLogCache(hostKey: kept, root: caches.url)))
        XCTAssertTrue(exists(.attachmentCache(hostKey: kept, root: caches.url)))
        // Again, with nothing left: nothing to do.
        XCTAssertNoThrow(try ArchiveLocation.removeDeviceCopy(hostKey: forgotten, supportRoot: support.url, cachesRoot: caches.url))
    }

    func testTheFullTextStepIndexesMessagesStoredBeforeIt() async throws {
        let queue = try DatabaseQueue()
        try ArchiveSchema.migrator(forcing: nil, probeModule: "fts5").migrate(queue, upTo: ArchiveSchema.tablesMigration)
        try await queue.write { db in
            try db.execute(sql: "INSERT INTO chats (id, projectId, provider, title, createdAt, updatedAt) VALUES ('c', 'p1', 'opencode', 'Old', 0, 0)")
            try db.execute(sql: """
                INSERT INTO messages (chatId, id, turnId, role, status, ord, provider, parts, text)
                VALUES ('c', 'm', 'm', 'user', 'complete', 1, 'opencode', '[]', 'kept from before the index existed')
                """)
        }
        let store = try ArchiveStore(writer: queue, hostKey: "h", url: nil, options: ArchiveStore.Options())
        let hits = try await search(store, "existed")
        XCTAssertEqual(hits, ["m"])
    }

    // MARK: Full-text search, FTS5 and FTS4

    func testTheProbeFindsFTS5AndAFailedProbeFallsBackToFTS4() throws {
        try DatabaseQueue().write { db in
            XCTAssertTrue(ArchiveSchema.probe(db, module: "fts5"))
            XCTAssertFalse(ArchiveSchema.probe(db, module: "agentland_no_such_module"))
        }
        XCTAssertEqual(try ArchiveStore.inMemory().fullTextIndex, .fts5)
        var missing = ArchiveStore.Options()
        missing.probeModule = "agentland_no_such_module"
        XCTAssertEqual(try ArchiveStore.inMemory(options: missing).fullTextIndex, .fts4)
        XCTAssertEqual(try ArchiveStore.inMemory(options: ArchiveStore.Options(forceFTS4: true)).fullTextIndex, .fts4)
    }

    func testBothIndexesFindRankAndMarkTheSameMatches() async throws {
        for index in FullTextIndex.allCases {
            let store = try ArchiveStore.inMemory(options: ArchiveStore.Options(forceFTS4: index == .fts4))
            XCTAssertEqual(store.fullTextIndex, index)
            try await store.apply(Fixture.page([
                Fixture.chat("c1", title: "Cookies"),
                Fixture.message("m1", chat: "c1", ord: 1, text: "The cookie domain is wrong. Cookie cookie cookie."),
                Fixture.message("m2", chat: "c1", role: .assistant, ord: 2, text: "A cookie jar has nothing to do with it; the redirect loops."),
                Fixture.message("m3", chat: "c1", ord: 3, text: "Unrelated text about CSV exports."),
                Fixture.message("m4", chat: "c1", ord: 4, text: "cookie in a rewound message", hidden: true),
                Fixture.message("m5", chat: "c1", ord: 5, text: "Crème brûlée cookies, with accents")
            ], cursor: "e1.6"))
            let hits = try await store.search(ArchiveSearchQuery(text: "cookie"))
            XCTAssertEqual(Set(hits.map(\.messageID)), ["m1", "m2", "m5"], "\(index): the rewound message is not searched")
            XCTAssertEqual(hits.first?.messageID, "m1", "\(index): the message with the most matches ranks first")
            let snippet = hits.first?.snippet.lowercased() ?? ""
            XCTAssertTrue(snippet.contains("\u{2}cookie\u{3}"), "\(index): matches are marked: \(snippet)")
            XCTAssertEqual(hits.first?.title, "Cookies")
            XCTAssertEqual(hits.first?.provider, "claude")
            let accents = try await search(store, "creme brulee")
            XCTAssertEqual(accents, ["m5"], "\(index): diacritics fold")
            let prefix = try await search(store, "redir")
            XCTAssertEqual(prefix, ["m2"], "\(index): the last term is a prefix")
            let both = try await search(store, "domain cookie")
            XCTAssertEqual(both, ["m1"], "\(index): every term is required")
            let syntax = try await search(store, #"" OR NEAR( * -"#)
            XCTAssertEqual(syntax, [], "\(index): query syntax is never interpreted")
            let paged = try await search(store, "cookie", limit: 1, offset: 1)
            XCTAssertEqual(paged.count, 1)
        }
    }

    func testBM25FromMatchinfo() {
        // One phrase, one column, 10 rows; this row has 3 hits in 20 tokens (average 10), 2 rows have hits.
        func blob(_ values: [UInt32]) -> Data { values.withUnsafeBufferPointer { Data(buffer: $0) } }
        let frequent = ArchiveRanking.bm25(matchinfo: blob([1, 1, 10, 10, 20, 3, 5, 2]))
        let rare = ArchiveRanking.bm25(matchinfo: blob([1, 1, 10, 10, 20, 1, 5, 2]))
        XCTAssertGreaterThan(frequent, rare)
        XCTAssertGreaterThan(rare, 0)
        XCTAssertEqual(ArchiveRanking.bm25(matchinfo: blob([1, 1])), 0, "A short blob scores nothing")
    }

    // MARK: Applying changes

    func testFirstPromptsSkipTheSeedHiddenMessagesAndReplies() async throws {
        let store = try ArchiveStore.inMemory()
        try await store.apply(Fixture.page([
            Fixture.chat("ses_1", provider: "opencode", title: "New chat"),
            Fixture.message("a0", chat: "ses_1", role: .assistant, ord: 0, text: "A reply before any prompt"),
            Fixture.message("u1", chat: "ses_1", ord: 1, text: "Rewound first try", hidden: true),
            Fixture.message("u2", chat: "ses_1", ord: 2, text: "Why does the login page loop?\nAfter a passkey sign-in."),
            Fixture.message("u3", chat: "ses_1", ord: 3, text: "A later prompt"),
            Fixture.chat("ses_2", title: "Claude Code chat"),
            Fixture.message("agentland-seed", chat: "ses_2", ord: 0, text: "Here is an earlier chat…"),
            Fixture.message("u4", chat: "ses_2", ord: 1, text: "Continue from there"),
            Fixture.chat("ses_3", title: "Empty")
        ], cursor: "e1.9"))
        let prompts = try await store.firstPrompts(chatIDs: ["ses_1", "ses_2", "ses_3", "missing"])
        XCTAssertEqual(prompts, ["ses_1": "Why does the login page loop?\nAfter a passkey sign-in.", "ses_2": "Continue from there"])
    }

    /// Chat naming asks where a title's message sits: rewound messages count, messages of other chats and
    /// messages this copy lacks do not.
    func testMessageOrderIncludesRewoundMessagesOfThatChatOnly() async throws {
        let store = try ArchiveStore.inMemory()
        try await store.apply(Fixture.page([
            Fixture.chat("ses_1"),
            Fixture.message("u1", chat: "ses_1", ord: 1, text: "Rewound try", hidden: true),
            Fixture.message("u2", chat: "ses_1", ord: 7, text: "Kept"),
            Fixture.chat("ses_2"),
            Fixture.message("u9", chat: "ses_2", ord: 3, text: "Elsewhere")
        ], cursor: "e1.5"))
        let hidden = try await store.messageOrder(chatID: "ses_1", messageID: "u1")
        let kept = try await store.messageOrder(chatID: "ses_1", messageID: "u2")
        let otherChat = try await store.messageOrder(chatID: "ses_1", messageID: "u9")
        let missing = try await store.messageOrder(chatID: "ses_1", messageID: "u10")
        XCTAssertEqual(hidden, 1)
        XCTAssertEqual(kept, 7)
        XCTAssertNil(otherChat)
        XCTAssertNil(missing)
    }

    func testApplyingAPageTwiceChangesNothing() async throws {
        let store = try ArchiveStore.inMemory()
        let first = try await store.apply(Fixture.starter)
        let before = try store.counts()
        let again = try await store.apply(Fixture.starter)
        XCTAssertEqual(first, again)
        XCTAssertEqual(first.applied, 6)
        let after = try store.counts()
        XCTAssertEqual(after.chats, before.chats)
        XCTAssertEqual(after.messages, before.messages)
        XCTAssertEqual(after.indexed, before.indexed, "No duplicate index rows")
        let passkey = try await search(store, "passkey")
        XCTAssertEqual(passkey, ["u1"])

        // An update replaces the text in the index too.
        try await store.apply(Fixture.page([Fixture.message("u1", chat: "ses_1", ord: 1, text: "Why does sign-in with a hardware key loop?")], cursor: "e1.7"))
        let gone = try await search(store, "passkey")
        XCTAssertEqual(gone, [])
        let hardware = try await search(store, "hardware")
        XCTAssertEqual(hardware, ["u1"])
        XCTAssertEqual(try store.counts().messages, 3)
    }

    func testMessagesMayArriveBeforeTheirChat() async throws {
        let store = try ArchiveStore.inMemory()
        try await store.apply(Fixture.page([Fixture.message("m1", chat: "late", ord: 1, text: "early bird")], cursor: "e1.1"))
        let noChatYet = try await store.chats()
        XCTAssertTrue(noChatYet.isEmpty)
        try await store.apply(Fixture.page([Fixture.chat("late", title: "Arrived later")], cursor: "e1.2"))
        let messages = try await store.allMessages(chatID: "late")
        XCTAssertEqual(messages.map(\.id), ["m1"])
        let hits = try await store.search(ArchiveSearchQuery(text: "early"))
        XCTAssertEqual(hits.first?.title, "Arrived later")
    }

    func testTombstonesAndUnreadableChanges() async throws {
        let store = try ArchiveStore.inMemory()
        try await store.apply(Fixture.starter)
        try await store.setPinned(true, chatID: "ses_1")
        let result = try await store.apply(Fixture.page([
            .messageDeleted(id: "u2", chatID: "ses_2"),
            .chatDeleted(id: "ses_1"),
            .terminalLogDeleted(id: "t1"),
            .unreadable(entity: "hologram", op: "upsert"),
            .messageDeleted(id: "never-seen", chatID: "nowhere")
        ], cursor: "e1.20"))
        XCTAssertEqual(result, ArchiveApplyResult(applied: 4, unreadable: 1, cleared: false))
        let counts = try store.counts()
        XCTAssertEqual(counts.chats, 1)
        XCTAssertEqual(counts.messages, 0, "A deleted chat takes its messages along")
        XCTAssertEqual(counts.logs, 0)
        XCTAssertEqual(counts.pins, 0)
        XCTAssertEqual(counts.indexed, 0)
    }

    func testResyncClearsTheCopyButKeepsPins() async throws {
        for index in FullTextIndex.allCases {
            let store = try ArchiveStore.inMemory(options: ArchiveStore.Options(forceFTS4: index == .fts4))
            try await store.apply(Fixture.starter)
            try await store.setPinned(true, chatID: "ses_1")
            let result = try await store.apply(Fixture.page([
                Fixture.chat("ses_3", title: "After the resync"),
                Fixture.message("n1", chat: "ses_3", ord: 1, text: "Fresh start")
            ], cursor: "e2.2", epoch: "e2", resync: true, hasMore: true))
            XCTAssertTrue(result.cleared)
            let chats = try await store.chats()
            XCTAssertEqual(chats.map(\.id), ["ses_3"], "\(index)")
            let counts = try store.counts()
            XCTAssertEqual(counts.messages, 1)
            XCTAssertEqual(counts.logs, 0)
            XCTAssertEqual(counts.indexed, 1, "\(index): the index was emptied too")
            let old = try await search(store, "passkey")
            XCTAssertEqual(old, [])
            let fresh = try await search(store, "fresh")
            XCTAssertEqual(fresh, ["n1"], "\(index): the triggers came back")
            let state = try await store.syncState()
            XCTAssertEqual(state.epoch, "e2")
            XCTAssertEqual(state.cursor, "e2.2")
            // The pinned chat comes back pinned in a later page of the resync.
            try await store.apply(Fixture.page([Fixture.chat("ses_1", title: "Fix the login loop")], cursor: "e2.3", epoch: "e2"))
            let returned = try await store.chat(id: "ses_1")
            XCTAssertEqual(returned?.pinned, true)
        }
    }

    func testCursorPersistsAcrossACrashMidPage() async throws {
        let folder = try TemporaryFolder()
        let location = folder.location()
        let second = Fixture.page([
            Fixture.chat("ses_9", title: "Second page"),
            Fixture.message("x1", chat: "ses_9", ord: 1, text: "written in the second page"),
            Fixture.message("x2", chat: "ses_9", ord: 2, text: "the crash happens before this one")
        ], cursor: "e1.9", firstSeq: 7)
        do {
            // The first page (six changes) goes through; the second fails at its third change.
            let calls = Counter()
            var crashing = ArchiveStore.Options()
            crashing.beforeChange = { _ in
                if calls.next() == 8 { throw CocoaError(.fileWriteUnknown) }
            }
            let store = try ArchiveStore.open(at: location, options: crashing)
            try await store.apply(Fixture.starter)
            do {
                try await store.apply(second)
                XCTFail("The page must fail midway")
            } catch {}
        }
        // Relaunch: the first page and its cursor are there, nothing of the second.
        let store = try ArchiveStore.open(at: location)
        let state = try await store.syncState()
        XCTAssertEqual(state.cursor, "e1.6")
        let missing = try await store.chat(id: "ses_9")
        XCTAssertNil(missing)
        XCTAssertEqual(try store.counts().messages, 3)
        // The same page again, now whole, applies once.
        try await store.apply(second)
        try await store.apply(second)
        let resumed = try await store.syncState()
        XCTAssertEqual(resumed.cursor, "e1.9")
        let messages = try await store.allMessages(chatID: "ses_9")
        XCTAssertEqual(messages.map(\.id), ["x1", "x2"])
    }

    // MARK: Reading

    func testMessagesRoundTripAndPage() async throws {
        let store = try ArchiveStore.inMemory()
        let tool = ConversationPart(id: "tool", kind: .tool, ord: 0, tool: ConversationTool(name: "bash", callID: "c1", status: .completed, title: "npm test",
                                                                                            input: "{\"command\":\"npm test\"}", output: "ok", truncated: true))
        let reasoning = ConversationPart(id: "why", kind: .reasoning, ord: 1, text: "Check the cookie", start: "2026-09-23T12:00:00.000Z", end: "2026-09-23T12:00:04.000Z")
        var items: [ArchiveChangeItem] = [Fixture.chat("c", title: "Paging")]
        for ord in 1...5 {
            items.append(Fixture.message("m\(ord)", chat: "c", role: ord % 2 == 0 ? .assistant : .user, ord: Int64(ord), text: "message \(ord)",
                                         created: "2026-09-23T12:0\(ord):00.123Z", extraParts: ord == 2 ? [tool, reasoning] : []))
        }
        items.append(Fixture.message("m6", chat: "c", ord: 6, text: "rewound", hidden: true))
        try await store.apply(Fixture.page(items, cursor: "e1.7"))

        let newest = try await store.messages(chatID: "c", limit: 2)
        XCTAssertEqual(newest.messages.map(\.id), ["m4", "m5"])
        XCTAssertTrue(newest.hasEarlier)
        let earlier = try await store.messages(chatID: "c", before: "m4", limit: 2)
        XCTAssertEqual(earlier.messages.map(\.id), ["m2", "m3"])
        let oldest = try await store.messages(chatID: "c", before: "m2", limit: 2)
        XCTAssertEqual(oldest.messages.map(\.id), ["m1"])
        XCTAssertFalse(oldest.hasEarlier)
        let withHidden = try await store.messages(chatID: "c", includeHidden: true)
        XCTAssertEqual(withHidden.messages.last?.hidden, true)

        let second = try XCTUnwrap(earlier.messages.first?.message)
        XCTAssertEqual(second.createdAt, "2026-09-23T12:02:00.123Z", "Times keep their milliseconds")
        XCTAssertEqual(second.parts.map(\.id), ["tool", "why", "m2-text"])
        XCTAssertEqual(second.parts.first?.tool?.output, "ok")
        XCTAssertEqual(second.parts.first?.tool?.truncated, true)
        XCTAssertEqual(second.parts[1].end, "2026-09-23T12:00:04.000Z")
        XCTAssertEqual(second.role, .assistant)
    }

    func testTheChatCacheShowsTheNewestVisibleMessages() async throws {
        let store = try ArchiveStore.inMemory()
        var items: [ArchiveChangeItem] = [Fixture.chat("ses_1", project: "p1", title: "Cached")]
        for ord in 1...5 { items.append(Fixture.message("m\(ord)", chat: "ses_1", ord: Int64(ord), text: "line \(ord)")) }
        items.append(Fixture.message("m6", chat: "ses_1", ord: 6, text: "rewound", hidden: true))
        try await store.apply(Fixture.page(items, cursor: "e1.7"))
        let cache = ArchiveTranscriptCache(store: store, limit: 3)
        let found = await cache.cachedTranscript(projectID: "p1", sessionID: "ses_1")
        let snapshot = try XCTUnwrap(found)
        XCTAssertEqual(snapshot.messages.map(\.id), ["m3", "m4", "m5"], "Rewound messages stay hidden")
        XCTAssertTrue(snapshot.hasMore)
        XCTAssertEqual(snapshot.chat.title, "Cached")
        XCTAssertEqual(snapshot.status.state, .unknown, "The saved copy does not know whether the chat runs")
        let otherProject = await cache.cachedTranscript(projectID: "p2", sessionID: "ses_1")
        XCTAssertNil(otherProject)
        let unknown = await cache.cachedTranscript(projectID: "p1", sessionID: "nope")
        XCTAssertNil(unknown)
    }

    @MainActor
    func testAChatScreenOpensFromTheArchiveOffline() async throws {
        let store = try ArchiveStore.inMemory()
        try await store.apply(Fixture.starter)
        let chat = ChatSessionStore(identity: .init(hostID: "h", projectID: "p1", sessionID: "ses_1", tabID: UUID()),
                                    transcriptCache: ArchiveTranscriptCache(store: store))
        chat.retryDelays = [.seconds(30)]
        let client = APIClient(address: try ServerAddress(validating: "https://mac.example"), token: "t", transport: SilentHost())
        chat.update(ChatSessionStore.Environment(client: client, capabilities: CapabilitiesResponse(interactions: true, terminal: true, chatFeatures: ["events"]),
                                                 reachable: false, connectionEpoch: 0, active: true, refreshGeneration: nil))
        await eventually("archived transcript") { chat.projection.rows.count == 2 }
        XCTAssertEqual(chat.phase, .ready)
        XCTAssertEqual(chat.info?.title, "Fix the login loop")
        chat.shutdown()
    }

    func testPinsFiltersAndFacets() async throws {
        let store = try ArchiveStore.inMemory()
        try await store.apply(Fixture.starter)
        try await store.setPinned(true, chatID: "ses_2")
        try await store.setPinned(true, chatID: "ses_2")
        let pinned = try await store.chats().filter(\.pinned).map(\.id)
        XCTAssertEqual(pinned, ["ses_2"])
        try await store.setPinned(false, chatID: "ses_2")
        let unpinned = try await store.chats().filter(\.pinned)
        XCTAssertTrue(unpinned.isEmpty)
        let facets = try await store.facets()
        XCTAssertEqual(facets.providers, ["claude", "codex"])
        XCTAssertEqual(facets.projectIDs, ["p1"])
        let filtered = try await store.chats(ArchiveChatFilter(provider: "codex"))
        XCTAssertEqual(filtered.map(\.id), ["ses_2"])
        let dated = try await store.chats(ArchiveChatFilter(from: ChatTime.date("2026-09-23T00:00:00.000Z")))
        XCTAssertEqual(dated.map(\.id), ["ses_1"])
        let found = try await store.chats(ids: ["ses_1", "missing"])
        XCTAssertEqual(Array(found.keys), ["ses_1"])
        let logs = try await store.terminalLogs()
        XCTAssertEqual(logs.first?.displayTitle, "Build")
        XCTAssertEqual(logs.first?.exitCode, 0)
    }

    func testChangesAreObservable() async throws {
        for store in [try ArchiveStore.inMemory(), try ArchiveStore.open(at: try TemporaryFolder().location())] {
            let changed = expectation(description: "a change")
            let changes = await store.changes()
            let listener = Task {
                for await _ in changes {
                    changed.fulfill()
                    return
                }
            }
            try await store.apply(Fixture.starter)
            await fulfillment(of: [changed], timeout: 3)
            listener.cancel()
            let pinned = expectation(description: "a pin")
            let more = await store.changes()
            let pinListener = Task {
                for await _ in more {
                    pinned.fulfill()
                    return
                }
            }
            try await store.setPinned(true, chatID: "ses_1")
            await fulfillment(of: [pinned], timeout: 3)
            pinListener.cancel()
        }
    }
}

/// A host that never answers (the chat stays on its saved copy).
final class SilentHost: APITransport, @unchecked Sendable {
    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw URLError(.cannotConnectToHost) }
    func lines(_ request: URLRequest, maxLineBytes: Int) async throws -> (AsyncThrowingStream<String, Error>, HTTPURLResponse) {
        throw URLError(.cannotConnectToHost)
    }
}

/// Counts calls across threads.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { value += 1; return value - 1 } }
}
