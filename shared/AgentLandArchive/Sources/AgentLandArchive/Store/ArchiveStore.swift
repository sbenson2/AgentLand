import Foundation
import GRDB
import AgentLandCore

public enum ArchiveStoreError: Error, Equatable, LocalizedError {
    /// The database file belongs to another host.
    case otherHost

    public var errorDescription: String? {
        switch self {
        case .otherHost: "This device’s archive belongs to another Mac."
        }
    }
}

/// This device's copy of one host's archive: chats, messages and terminal log
/// metadata in SQLite (GRDB), with full-text search over message text. The
/// host keeps the original; this copy is filled only by `apply(_:)` from the
/// change feed, except pins, which are this device's own.
public final class ArchiveStore: Sendable {
    public struct Options: Sendable {
        /// Skip the FTS5 probe and index with FTS4.
        public var forceFTS4: Bool
        /// The module the probe tries (tests name one that does not exist).
        var probeModule = "fts5"
        /// Called before each change a page applies (tests fail a page midway).
        var beforeChange: (@Sendable (Int) throws -> Void)?

        public init(forceFTS4: Bool = false) { self.forceFTS4 = forceFTS4 }
    }

    /// `ConnectionIdentity.storageKey` of the host this copy mirrors.
    public let hostKey: String
    /// The index this device's SQLite supports.
    public let fullTextIndex: FullTextIndex
    /// The database file, nil in memory.
    public let url: URL?
    let writer: any DatabaseWriter
    private let beforeChange: (@Sendable (Int) throws -> Void)?

    /// Opens (creating when needed) the archive for one paired host.
    public static func open(for identity: ConnectionIdentity, options: Options = Options()) throws -> ArchiveStore {
        try open(at: ArchiveLocation.archive(for: identity), options: options)
    }

    /// Opens (creating when needed) the archive in `location`.
    public static func open(at location: ArchiveLocation, options: Options = Options()) throws -> ArchiveStore {
        try location.prepare()
        let url = location.databaseURL
        let pool = try DatabasePool(path: url.path, configuration: configuration())
        let store = try ArchiveStore(writer: pool, hostKey: location.hostKey, url: url, options: options)
        for suffix in ["", "-wal", "-shm"] {
            try ArchiveLocation.protect(URL(filePath: url.path + suffix))
        }
        return store
    }

    /// An archive that lives only in memory (previews and tests).
    public static func inMemory(hostKey: String = "preview", options: Options = Options()) throws -> ArchiveStore {
        try ArchiveStore(writer: DatabaseQueue(configuration: configuration()), hostKey: hostKey, url: nil, options: options)
    }

    private static func configuration() -> Configuration {
        var configuration = Configuration()
        configuration.label = "AgentLandArchive"
        configuration.prepareDatabase { db in db.add(function: ArchiveRanking.function) }
        return configuration
    }

    init(writer: any DatabaseWriter, hostKey: String, url: URL?, options: Options) throws {
        self.writer = writer
        self.hostKey = hostKey
        self.url = url
        beforeChange = options.beforeChange
        try ArchiveSchema.migrator(forcing: options.forceFTS4 ? .fts4 : nil, probeModule: options.probeModule).migrate(writer)
        fullTextIndex = try writer.write { db in
            try db.execute(sql: "INSERT INTO sync_state (id, hostKey) VALUES (1, ?) ON CONFLICT (id) DO NOTHING", arguments: [hostKey])
            guard try String.fetchOne(db, sql: "SELECT hostKey FROM sync_state WHERE id = 1") == hostKey else { throw ArchiveStoreError.otherHost }
            let raw = try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'fullTextIndex'")
            return raw.flatMap(FullTextIndex.init(rawValue:)) ?? .fts4
        }
    }

    // MARK: Sync

    public func syncState() async throws -> ArchiveSyncState {
        try await writer.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT hostKey, epoch, cursor, syncedAt FROM sync_state WHERE id = 1") else {
                return ArchiveSyncState(hostKey: "", epoch: nil, cursor: nil, syncedAt: nil)
            }
            let syncedAt: Int64? = row["syncedAt"]
            return ArchiveSyncState(hostKey: row["hostKey"], epoch: row["epoch"], cursor: row["cursor"], syncedAt: syncedAt.map(ArchiveTime.date))
        }
    }

    /// Applies one page of the change feed and stores its cursor and epoch in
    /// the same transaction: a crash mid-page leaves the previous page's
    /// cursor, and applying a page again changes nothing. A `resync` page
    /// clears the copy first (pins stay).
    @discardableResult
    public func apply(_ page: ArchiveChangesPage, at now: Date = Date()) async throws -> ArchiveApplyResult {
        let index = fullTextIndex
        let beforeChange = beforeChange
        return try await writer.write { db in try Self.apply(page, in: db, index: index, beforeChange: beforeChange, now: now) }
    }

    /// The same, blocking the caller (previews and sample data).
    @discardableResult
    func applyNow(_ page: ArchiveChangesPage, at now: Date = Date()) throws -> ArchiveApplyResult {
        let index = fullTextIndex
        return try writer.write { db in try Self.apply(page, in: db, index: index, beforeChange: nil, now: now) }
    }

    private static func apply(_ page: ArchiveChangesPage, in db: Database, index: FullTextIndex,
                              beforeChange: (@Sendable (Int) throws -> Void)?, now: Date) throws -> ArchiveApplyResult {
        var result = ArchiveApplyResult(cleared: page.resync)
        if page.resync { try clearCopy(db, index: index) }
        for (position, change) in page.changes.enumerated() {
            try beforeChange?(position)
            if try apply(change.item, in: db) { result.applied += 1 } else { result.unreadable += 1 }
        }
        try db.execute(sql: "UPDATE sync_state SET epoch = ?, cursor = ?, syncedAt = ? WHERE id = 1",
                       arguments: [page.epoch, page.cursor.isEmpty ? nil : page.cursor, ArchiveTime.milliseconds(now)])
        return result
    }

    /// Drops the copy and the cursor, so the next sync starts from the
    /// beginning (after the host refused the cursor). Pins stay.
    public func startOver() async throws {
        let index = fullTextIndex
        try await writer.write { db in
            try Self.clearCopy(db, index: index)
            try db.execute(sql: "UPDATE sync_state SET epoch = NULL, cursor = NULL WHERE id = 1")
        }
    }

    /// Clearing a large copy row by row would re-tokenize every message, so
    /// the index is emptied at once with its triggers out of the way.
    private static func clearCopy(_ db: Database, index: FullTextIndex) throws {
        for trigger in index.triggerNames { try db.execute(sql: "DROP TRIGGER IF EXISTS \(trigger)") }
        try db.execute(sql: "DELETE FROM messages")
        try db.execute(sql: index.emptySQL)
        try db.execute(sql: index.triggersSQL)
        try db.execute(sql: "DELETE FROM chats")
        try db.execute(sql: "DELETE FROM terminal_logs")
    }

    /// False for a change this version cannot read.
    private static func apply(_ item: ArchiveChangeItem, in db: Database) throws -> Bool {
        switch item {
        case let .chat(chat):
            try db.cachedStatement(sql: """
                INSERT INTO chats (id, projectId, provider, title, model, mode, effort, parentId, relation, createdAt, updatedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT (id) DO UPDATE SET projectId = excluded.projectId, provider = excluded.provider, title = excluded.title,
                    model = excluded.model, mode = excluded.mode, effort = excluded.effort, parentId = excluded.parentId,
                    relation = excluded.relation, createdAt = excluded.createdAt, updatedAt = excluded.updatedAt
                """).execute(arguments: [chat.id, chat.projectID, chat.provider, chat.title, chat.model, chat.mode, chat.effort,
                                         chat.parentID, chat.relation, ArchiveTime.milliseconds(chat.createdAt) ?? 0,
                                         ArchiveTime.milliseconds(chat.updatedAt) ?? ArchiveTime.milliseconds(chat.createdAt) ?? 0])
        case let .message(record):
            let message = record.message
            let encoder = JSONEncoder()
            try db.cachedStatement(sql: """
                INSERT INTO messages (chatId, id, turnId, role, status, ord, createdAt, completedAt, provider, model, usage, error, hidden, parts, text)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT (chatId, id) DO UPDATE SET turnId = excluded.turnId, role = excluded.role, status = excluded.status,
                    ord = excluded.ord, createdAt = excluded.createdAt, completedAt = excluded.completedAt, provider = excluded.provider,
                    model = excluded.model, usage = excluded.usage, error = excluded.error, hidden = excluded.hidden,
                    parts = excluded.parts, text = excluded.text
                """).execute(arguments: [
                    message.chatID, message.id, message.turnID, message.role.rawValue, message.status.rawValue, message.ord,
                    ArchiveTime.milliseconds(message.createdAt), ArchiveTime.milliseconds(message.completedAt), message.provider,
                    message.model, try message.usage.map { String(decoding: try encoder.encode($0), as: UTF8.self) },
                    try message.error.map { String(decoding: try encoder.encode($0), as: UTF8.self) }, record.hidden,
                    String(decoding: try encoder.encode(message.parts), as: UTF8.self), searchText(message)])
        case let .terminalLog(log):
            try db.cachedStatement(sql: """
                INSERT INTO terminal_logs (id, projectId, title, program, startedAt, endedAt, status, exitCode, bytes, gapBytes)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT (id) DO UPDATE SET projectId = excluded.projectId, title = excluded.title, program = excluded.program,
                    startedAt = excluded.startedAt, endedAt = excluded.endedAt, status = excluded.status, exitCode = excluded.exitCode,
                    bytes = excluded.bytes, gapBytes = excluded.gapBytes
                """).execute(arguments: [log.id, log.projectID, log.title, log.program, ArchiveTime.milliseconds(log.startedAt) ?? 0,
                                         ArchiveTime.milliseconds(log.endedAt), log.status, log.exitCode, log.bytes, log.gapBytes])
        case let .chatDeleted(id):
            try deleteChat(id, in: db)
        case let .messageDeleted(id, chatID):
            try db.execute(sql: "DELETE FROM messages WHERE chatId = ? AND id = ?", arguments: [chatID, id])
        case let .terminalLogDeleted(id):
            try db.execute(sql: "DELETE FROM terminal_logs WHERE id = ?", arguments: [id])
        case .unreadable:
            return false
        }
        return true
    }

    private static func deleteChat(_ id: String, in db: Database) throws {
        try db.execute(sql: "DELETE FROM messages WHERE chatId = ?", arguments: [id])
        try db.execute(sql: "DELETE FROM chats WHERE id = ?", arguments: [id])
        try db.execute(sql: "DELETE FROM pins WHERE chatId = ?", arguments: [id])
    }

    /// Text parts, as the host indexes them: at most 256 KiB, without the
    /// characters that mark matches in snippets.
    static func searchText(_ message: ConversationMessage) -> String {
        let joined = message.parts.filter { $0.kind == .text && !$0.text.isEmpty }.map(\.text).joined(separator: "\n\n")
        let cleaned = String(String.UnicodeScalarView(joined.unicodeScalars.filter { $0 != "\u{2}" && $0 != "\u{3}" }))
        return cleaned.clipped(toBytes: 256 << 10)
    }

    // MARK: Chats

    /// Chats, most recent activity first, with this device's pins.
    public func chats(_ filter: ArchiveChatFilter = ArchiveChatFilter()) async throws -> [ArchivedChat] {
        try await writer.read { db in
            var conditions: [String] = []
            var arguments: StatementArguments = []
            if let projectID = filter.projectID { conditions.append("c.projectId = ?"); arguments += [projectID] }
            if let provider = filter.provider { conditions.append("c.provider = ?"); arguments += [provider] }
            if let from = filter.from { conditions.append("c.updatedAt >= ?"); arguments += [ArchiveTime.milliseconds(from)] }
            if let to = filter.to { conditions.append("c.updatedAt < ?"); arguments += [ArchiveTime.milliseconds(to)] }
            arguments += [max(filter.limit, 1)]
            let rows = try Row.fetchAll(db, sql: Self.chatSelect + (conditions.isEmpty ? "" : " WHERE " + conditions.joined(separator: " AND "))
                                        + " ORDER BY c.updatedAt DESC, c.id LIMIT ?", arguments: arguments)
            return rows.map(Self.chat)
        }
    }

    public func chat(id: String) async throws -> ArchivedChat? {
        try await writer.read { db in try Row.fetchOne(db, sql: Self.chatSelect + " WHERE c.id = ?", arguments: [id]).map(Self.chat) }
    }

    /// The chats among `ids` this device has copied.
    public func chats(ids: Set<String>) async throws -> [String: ArchivedChat] {
        guard !ids.isEmpty else { return [:] }
        return try await writer.read { db in
            var found: [String: ArchivedChat] = [:]
            for batch in Array(ids).chunked(into: 500) {
                let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ", ")
                for row in try Row.fetchAll(db, sql: Self.chatSelect + " WHERE c.id IN (\(placeholders))", arguments: StatementArguments(batch)) {
                    let chat = Self.chat(row)
                    found[chat.id] = chat
                }
            }
            return found
        }
    }

    /// The text of each chat's first prompt (its earliest visible user message, not a continued
    /// chat's seed), at most 400 characters, for chats among `chatIDs` that have one. A library names a
    /// chat the host still calls by a default title ("New chat") by its first prompt, as the chat does.
    public func firstPrompts(chatIDs: Set<String>) async throws -> [String: String] {
        guard !chatIDs.isEmpty else { return [:] }
        return try await writer.read { db in
            var found: [String: String] = [:]
            for batch in Array(chatIDs).chunked(into: 500) {
                let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ", ")
                let rows = try Row.fetchAll(db, sql: """
                    SELECT m.chatId, substr(m.text, 1, 400) AS text FROM messages m
                    WHERE m.chatId IN (\(placeholders)) AND m.role = 'user' AND m.hidden = 0 AND m.text != ''
                        AND m.id != '\(ContinueSeed.seedMessageID)'
                        AND m.ord = (SELECT min(x.ord) FROM messages x WHERE x.chatId = m.chatId AND x.role = 'user'
                                     AND x.hidden = 0 AND x.text != '' AND x.id != '\(ContinueSeed.seedMessageID)')
                    """, arguments: StatementArguments(batch))
                for row in rows { found[row["chatId"]] = row["text"] }
            }
            return found
        }
    }

    /// Projects and providers present in the copy, for the search chips.
    public func facets() async throws -> (projectIDs: [String], providers: [String]) {
        try await writer.read { db in
            (try String.fetchAll(db, sql: "SELECT DISTINCT projectId FROM chats ORDER BY projectId"),
             try String.fetchAll(db, sql: "SELECT DISTINCT provider FROM chats ORDER BY provider"))
        }
    }

    public func setPinned(_ pinned: Bool, chatID: String, at now: Date = Date()) async throws {
        try await writer.write { db in try Self.setPinned(pinned, chatID: chatID, now: now, in: db) }
    }

    func setPinnedNow(_ pinned: Bool, chatID: String) throws {
        try writer.write { db in try Self.setPinned(pinned, chatID: chatID, now: Date(), in: db) }
    }

    private static func setPinned(_ pinned: Bool, chatID: String, now: Date, in db: Database) throws {
        if pinned {
            try db.execute(sql: "INSERT INTO pins (chatId, pinnedAt) VALUES (?, ?) ON CONFLICT (chatId) DO NOTHING",
                           arguments: [chatID, ArchiveTime.milliseconds(now)])
        } else {
            try db.execute(sql: "DELETE FROM pins WHERE chatId = ?", arguments: [chatID])
        }
    }

    /// Removes a chat after the host confirmed deleting it; the tombstone
    /// that follows in the change feed then changes nothing.
    public func deleteChat(id: String) async throws {
        try await writer.write { db in try Self.deleteChat(id, in: db) }
    }

    private static let chatSelect = """
        SELECT c.id, c.projectId, c.provider, c.title, c.model, c.mode, c.effort, c.parentId, c.relation, c.createdAt, c.updatedAt,
            p.chatId IS NOT NULL AS pinned
        FROM chats c LEFT JOIN pins p ON p.chatId = c.id
        """

    private static func chat(_ row: Row) -> ArchivedChat {
        ArchivedChat(id: row["id"], projectID: row["projectId"], provider: row["provider"], title: row["title"], model: row["model"],
                     mode: row["mode"], effort: row["effort"], parentID: row["parentId"], relation: row["relation"],
                     createdAt: ArchiveTime.date(row["createdAt"]), updatedAt: ArchiveTime.date(row["updatedAt"]), pinned: row["pinned"])
    }

    // MARK: Messages

    /// A page of a chat's messages, oldest first, ending before `before`
    /// (a message ID) or with the newest.
    public func messages(chatID: String, before: String? = nil, limit: Int = 200,
                         includeHidden: Bool = false) async throws -> (messages: [ArchivedMessage], hasEarlier: Bool) {
        try await writer.read { db in try Self.messages(db, chatID: chatID, before: before, limit: limit, includeHidden: includeHidden) }
    }

    /// Where message `messageID` of chat `chatID` sits (its `ord`), rewound messages included; nil when this
    /// copy does not hold it (yet).
    public func messageOrder(chatID: String, messageID: String) async throws -> Int64? {
        try await writer.read { db in
            try Int64.fetchOne(db, sql: "SELECT ord FROM messages WHERE chatId = ? AND id = ?", arguments: [chatID, messageID])
        }
    }

    /// Every message of a chat, oldest first.
    public func allMessages(chatID: String, includeHidden: Bool = false) async throws -> [ArchivedMessage] {
        try await writer.read { db in
            try Row.fetchAll(db, sql: Self.messageSelect + " WHERE chatId = ?" + (includeHidden ? "" : " AND hidden = 0") + " ORDER BY ord, pk",
                             arguments: [chatID]).map(Self.message)
        }
    }

    /// The chat as a chat screen shows it before the host answers: its newest
    /// visible messages. Nil when this device has not copied it, or it
    /// belongs to another project.
    public func transcript(projectID: String, chatID: String, limit: Int = 200) async throws -> ChatSnapshot? {
        try await writer.read { db in
            guard let chat = try Row.fetchOne(db, sql: Self.chatSelect + " WHERE c.id = ?", arguments: [chatID]).map(Self.chat),
                  chat.projectID == projectID else { return nil }
            let page = try Self.messages(db, chatID: chatID, before: nil, limit: limit, includeHidden: false)
            guard !page.messages.isEmpty else { return nil }
            return ChatSnapshot(chat: chat.info, messages: page.messages.map(\.message), hasMore: page.hasEarlier,
                                status: ChatStatusInfo(state: .unknown))
        }
    }

    private static func messages(_ db: Database, chatID: String, before: String?, limit: Int,
                                 includeHidden: Bool) throws -> (messages: [ArchivedMessage], hasEarlier: Bool) {
        var sql = messageSelect + " WHERE chatId = ?"
        var arguments: StatementArguments = [chatID]
        if !includeHidden { sql += " AND hidden = 0" }
        if let before, let anchor = try Row.fetchOne(db, sql: "SELECT ord, pk FROM messages WHERE chatId = ? AND id = ?", arguments: [chatID, before]) {
            sql += " AND (ord, pk) < (?, ?)"
            arguments += [anchor["ord"] as Int64, anchor["pk"] as Int64]
        }
        sql += " ORDER BY ord DESC, pk DESC LIMIT ?"
        arguments += [max(limit, 1) + 1]
        var rows = try Row.fetchAll(db, sql: sql, arguments: arguments).map(message)
        let hasEarlier = rows.count > max(limit, 1)
        if hasEarlier { rows.removeLast() }
        return (Array(rows.reversed()), hasEarlier)
    }

    private static let messageSelect = """
        SELECT pk, chatId, id, turnId, role, status, ord, createdAt, completedAt, provider, model, usage, error, hidden, parts FROM messages
        """

    private static func message(_ row: Row) -> ArchivedMessage {
        let decoder = JSONDecoder()
        func decode<T: Decodable>(_ type: T.Type, _ column: String) -> T? {
            guard let text: String = row[column] else { return nil }
            return try? decoder.decode(T.self, from: Data(text.utf8))
        }
        let role: String = row["role"], status: String = row["status"]
        let message = ConversationMessage(
            id: row["id"], chatID: row["chatId"], turnID: row["turnId"], role: MessageRole(rawValue: role) ?? .assistant,
            status: ConversationMessageStatus(rawValue: status) ?? .complete, ord: row["ord"],
            createdAt: (row["createdAt"] as Int64?).map(ArchiveTime.text) ?? "", completedAt: (row["completedAt"] as Int64?).map(ArchiveTime.text),
            provider: row["provider"], model: row["model"], usage: decode(ConversationUsage.self, "usage"),
            error: decode(ConversationError.self, "error"), parts: decode([ConversationPart].self, "parts") ?? [])
        return ArchivedMessage(message: message, hidden: row["hidden"])
    }

    // MARK: Terminal logs

    /// Terminal logs, newest first.
    public func terminalLogs(projectID: String? = nil, limit: Int = 5_000) async throws -> [ArchivedTerminalLog] {
        try await writer.read { db in
            var arguments: StatementArguments = []
            if let projectID { arguments += [projectID] }
            arguments += [max(limit, 1)]
            return try Row.fetchAll(db, sql: Self.logSelect + (projectID == nil ? "" : " WHERE projectId = ?") + " ORDER BY startedAt DESC, id DESC LIMIT ?",
                                    arguments: arguments).map(Self.log)
        }
    }

    public func terminalLog(id: String) async throws -> ArchivedTerminalLog? {
        try await writer.read { db in try Row.fetchOne(db, sql: Self.logSelect + " WHERE id = ?", arguments: [id]).map(Self.log) }
    }

    /// Removes a log after the host confirmed deleting it.
    public func deleteTerminalLog(id: String) async throws {
        try await writer.write { db in try db.execute(sql: "DELETE FROM terminal_logs WHERE id = ?", arguments: [id]) }
    }

    private static let logSelect = "SELECT id, projectId, title, program, startedAt, endedAt, status, exitCode, bytes, gapBytes FROM terminal_logs"

    private static func log(_ row: Row) -> ArchivedTerminalLog {
        ArchivedTerminalLog(id: row["id"], projectID: row["projectId"], title: row["title"], program: row["program"],
                            startedAt: ArchiveTime.date(row["startedAt"]), endedAt: (row["endedAt"] as Int64?).map(ArchiveTime.date),
                            status: row["status"], exitCode: row["exitCode"], bytes: row["bytes"], gapBytes: row["gapBytes"])
    }

    // MARK: Search

    /// Full-text search over this device's copy: best matches first, then
    /// newest. Rewound (hidden) messages are not searched.
    public func search(_ query: ArchiveSearchQuery, limit: Int = 50, offset: Int = 0) async throws -> [ArchiveSearchHit] {
        let index = fullTextIndex
        guard let match = query.matchExpression(for: index) else { return [] }
        return try await writer.read { db in
            var conditions = ["messages_fts MATCH ?", "m.hidden = 0"]
            var arguments: StatementArguments = [match]
            if let projectID = query.projectID { conditions.append("c.projectId = ?"); arguments += [projectID] }
            if let provider = query.provider { conditions.append("c.provider = ?"); arguments += [provider] }
            if let from = query.from { conditions.append("m.createdAt >= ?"); arguments += [ArchiveTime.milliseconds(from)] }
            if let to = query.to { conditions.append("m.createdAt < ?"); arguments += [ArchiveTime.milliseconds(to)] }
            arguments += [max(limit, 1), max(offset, 0)]
            let rows = try Row.fetchAll(db, sql: """
                SELECT m.chatId, m.id, c.projectId, c.title, c.provider, m.role, m.createdAt, \(index.snippetSQL) AS snippet
                FROM messages_fts JOIN messages m ON m.pk = messages_fts.rowid JOIN chats c ON c.id = m.chatId
                WHERE \(conditions.joined(separator: " AND "))
                ORDER BY \(index.rankingSQL), m.createdAt DESC, m.pk DESC LIMIT ? OFFSET ?
                """, arguments: arguments)
            return rows.map { row in
                let role: String = row["role"]
                return ArchiveSearchHit(chatID: row["chatId"], messageID: row["id"], projectID: row["projectId"], title: row["title"],
                                        provider: row["provider"], role: MessageRole(rawValue: role),
                                        createdAt: (row["createdAt"] as Int64?).map(ArchiveTime.date), snippet: (row["snippet"] as String?) ?? "")
            }
        }
    }

    // MARK: Observation

    /// Yields after every committed change to chats, pins or terminal logs,
    /// so lists can reload. Ends when the task iterating it is cancelled.
    /// Registering waits for the writer, which a sync page holds while it
    /// commits, so it happens off the caller's thread (the main actor, for a
    /// list); it is in place when this returns, so no later commit is missed.
    public func changes() async -> AsyncStream<Void> {
        let writer = writer
        return await Task.detached(priority: .userInitiated) {
            AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
                let observation = DatabaseRegionObservation(tracking: Table("chats"), Table("pins"), Table("terminal_logs"))
                let cancellable = observation.start(in: writer, onError: { _ in continuation.finish() }, onChange: { _ in continuation.yield() })
                continuation.onTermination = { _ in cancellable.cancel() }
            }
        }.value
    }

    /// Row counts, for tests and diagnostics.
    func counts() throws -> (chats: Int, messages: Int, logs: Int, pins: Int, indexed: Int) {
        try writer.read { db in
            (try Int.fetchOne(db, sql: "SELECT count(*) FROM chats") ?? 0,
             try Int.fetchOne(db, sql: "SELECT count(*) FROM messages") ?? 0,
             try Int.fetchOne(db, sql: "SELECT count(*) FROM terminal_logs") ?? 0,
             try Int.fetchOne(db, sql: "SELECT count(*) FROM pins") ?? 0,
             try Int.fetchOne(db, sql: "SELECT count(*) FROM messages_fts_docsize") ?? 0)
        }
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
