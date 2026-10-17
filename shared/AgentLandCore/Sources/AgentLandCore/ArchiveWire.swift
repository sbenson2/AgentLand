import Foundation

// The host's archive routes (docs/HOST-API.md, "Archive"): the change feed a
// device copies, archived chat pages, search, export, terminal logs and
// delete. Decoders are tolerant like the chat wire: missing fields get their
// documented defaults, and a change this version cannot read is kept as
// `.unreadable` instead of failing its page.

/// Archive features a host lists in `archive.features`.
public enum ArchiveFeature: String, Sendable, CaseIterable {
    case sync, search, export, terminalLogs
    case `continue`
    /// `POST /v1/chat/continue` takes `throughMessageId`, the last message the
    /// seed may carry. Hosts list it in `archive.features` and `chatFeatures`.
    case continueThrough
    /// `GET /v1/archive/changes` takes `wait`: with nothing after the cursor
    /// the host answers when a change comes, or after the wait.
    case changesWait
    /// `GET /v1/archive/blob` serves an archived attachment's bytes.
    case blobs
}

/// `capabilities.archive`: present only when the host keeps an archive.
public struct ArchiveCapabilities: Codable, Hashable, Sendable {
    public let version: Int
    public let features: [String]

    public init(version: Int = 1, features: [String]) { self.version = version; self.features = features }

    enum CodingKeys: String, CodingKey { case version, features }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        features = try container.decodeIfPresent([String].self, forKey: .features) ?? []
    }

    public func supports(_ feature: ArchiveFeature) -> Bool { features.contains(feature.rawValue) }
}

public extension CapabilitiesResponse {
    /// An archive feature. Hosts without an archive claim none.
    func supportsArchive(_ feature: ArchiveFeature) -> Bool { archive?.supports(feature) == true }

    /// Continue can stop at a chosen message (`throughMessageId`).
    var continuesThroughMessage: Bool {
        supportsArchive(.continueThrough) || chatFeatures.contains(ArchiveFeature.continueThrough.rawValue)
    }
}

// MARK: Records

/// An archived chat as the change feed and chat pages carry it.
public struct ArchiveChatRecord: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var projectID: String
    public var provider: String
    public var title: String
    public var model: String?
    public var mode: String?
    public var effort: String?
    /// The chat this one was continued (or forked) from.
    public var parentID: String?
    /// How it follows `parentID`: `continue`.
    public var relation: String?
    public var createdAt: String
    public var updatedAt: String

    public init(id: String, projectID: String, provider: String = "opencode", title: String = "", model: String? = nil,
                mode: String? = nil, effort: String? = nil, parentID: String? = nil, relation: String? = nil,
                createdAt: String = "", updatedAt: String = "") {
        self.id = id; self.projectID = projectID; self.provider = provider; self.title = title; self.model = model
        self.mode = mode; self.effort = effort; self.parentID = parentID; self.relation = relation
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, projectID = "projectId", provider, title, model, mode, effort, parentID = "parentId", relation, createdAt, updatedAt
    }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func optional(_ key: CodingKeys) throws -> String? {
            let value = try container.decodeIfPresent(String.self, forKey: key)
            return value?.isEmpty == false ? value : nil
        }
        id = try container.decode(String.self, forKey: .id)
        projectID = try container.decodeIfPresent(String.self, forKey: .projectID) ?? ""
        provider = try container.decodeIfPresent(String.self, forKey: .provider) ?? "opencode"
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        model = try optional(.model)
        mode = try optional(.mode)
        effort = try optional(.effort)
        parentID = try optional(.parentID)
        relation = try optional(.relation)
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt) ?? createdAt
    }
}

/// An archived message: the conversation model plus `hidden` for messages a
/// rewind hid.
public struct ArchiveMessageRecord: Decodable, Hashable, Sendable {
    public var message: ConversationMessage
    public var hidden: Bool

    public init(message: ConversationMessage, hidden: Bool = false) { self.message = message; self.hidden = hidden }

    private enum Keys: String, CodingKey { case hidden }
    public init(from decoder: Decoder) throws {
        message = try ConversationMessage(from: decoder)
        hidden = try decoder.container(keyedBy: Keys.self).decodeIfPresent(Bool.self, forKey: .hidden) ?? false
    }
}

/// A terminal's recorded output: metadata only. The bytes are read in ranges.
public struct ArchiveTerminalLogRecord: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var projectID: String
    public var title: String
    public var program: String
    public var startedAt: String
    public var endedAt: String?
    /// `running` while the terminal lives.
    public var status: String
    public var exitCode: Int?
    /// Bytes recorded.
    public var bytes: Int64
    /// Output that was not recorded (capture paused under low disk space, or a write failed).
    public var gapBytes: Int64

    public init(id: String, projectID: String, title: String = "", program: String = "shell", startedAt: String = "",
                endedAt: String? = nil, status: String = "exited", exitCode: Int? = nil, bytes: Int64 = 0, gapBytes: Int64 = 0) {
        self.id = id; self.projectID = projectID; self.title = title; self.program = program; self.startedAt = startedAt
        self.endedAt = endedAt; self.status = status; self.exitCode = exitCode; self.bytes = bytes; self.gapBytes = gapBytes
    }

    enum CodingKeys: String, CodingKey { case id, projectID = "projectId", title, program, startedAt, endedAt, status, exitCode, bytes, gapBytes }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        projectID = try container.decodeIfPresent(String.self, forKey: .projectID) ?? ""
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        program = try container.decodeIfPresent(String.self, forKey: .program) ?? "shell"
        startedAt = try container.decodeIfPresent(String.self, forKey: .startedAt) ?? ""
        let ended = try container.decodeIfPresent(String.self, forKey: .endedAt)
        endedAt = ended?.isEmpty == false ? ended : nil
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? "exited"
        exitCode = try container.decodeIfPresent(Int.self, forKey: .exitCode)
        bytes = try container.decodeIfPresent(Int64.self, forKey: .bytes) ?? 0
        gapBytes = try container.decodeIfPresent(Int64.self, forKey: .gapBytes) ?? 0
    }
}

// MARK: Change feed

/// What one change does.
public enum ArchiveChangeItem: Hashable, Sendable {
    case chat(ArchiveChatRecord)
    case message(ArchiveMessageRecord)
    case terminalLog(ArchiveTerminalLogRecord)
    case chatDeleted(id: String)
    case messageDeleted(id: String, chatID: String)
    case terminalLogDeleted(id: String)
    /// An entity or operation this version does not know, or a payload it
    /// could not read. It is skipped and counted, never fatal.
    case unreadable(entity: String, op: String)
}

public struct ArchiveChange: Decodable, Hashable, Sendable {
    public var seq: Int64
    public var item: ArchiveChangeItem

    public init(seq: Int64, item: ArchiveChangeItem) { self.seq = seq; self.item = item }

    enum CodingKeys: String, CodingKey { case seq, entity, op, payload }
    private struct Tombstone: Decodable {
        let id: String
        let chatID: String?
        enum CodingKeys: String, CodingKey { case id, chatID = "chatId" }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        seq = try container.decodeIfPresent(Int64.self, forKey: .seq) ?? 0
        let entity = try container.decodeIfPresent(String.self, forKey: .entity) ?? ""
        let op = try container.decodeIfPresent(String.self, forKey: .op) ?? ""
        item = (try? Self.item(entity: entity, op: op, in: container)) ?? .unreadable(entity: entity, op: op)
    }

    private static func item(entity: String, op: String, in container: KeyedDecodingContainer<CodingKeys>) throws -> ArchiveChangeItem {
        switch (entity, op) {
        case ("chat", "upsert"):
            return .chat(try container.decode(ArchiveChatRecord.self, forKey: .payload))
        case ("message", "upsert"):
            let record = try container.decode(ArchiveMessageRecord.self, forKey: .payload)
            return record.message.chatID.isEmpty ? .unreadable(entity: entity, op: op) : .message(record)
        case ("terminalLog", "upsert"):
            return .terminalLog(try container.decode(ArchiveTerminalLogRecord.self, forKey: .payload))
        case ("chat", "delete"):
            return .chatDeleted(id: try container.decode(Tombstone.self, forKey: .payload).id)
        case ("message", "delete"):
            let tombstone = try container.decode(Tombstone.self, forKey: .payload)
            guard let chatID = tombstone.chatID, !chatID.isEmpty else { return .unreadable(entity: entity, op: op) }
            return .messageDeleted(id: tombstone.id, chatID: chatID)
        case ("terminalLog", "delete"):
            return .terminalLogDeleted(id: try container.decode(Tombstone.self, forKey: .payload).id)
        default:
            return .unreadable(entity: entity, op: op)
        }
    }
}

/// One page of `GET /v1/archive/changes`. With `resync` the page already
/// starts over from the beginning: the device clears its copy first.
public struct ArchiveChangesPage: Decodable, Hashable, Sendable {
    public var epoch: String
    public var resync: Bool
    public var changes: [ArchiveChange]
    /// Opaque; the next request's `after`.
    public var cursor: String
    public var hasMore: Bool

    public init(epoch: String, resync: Bool = false, changes: [ArchiveChange], cursor: String, hasMore: Bool = false) {
        self.epoch = epoch; self.resync = resync; self.changes = changes; self.cursor = cursor; self.hasMore = hasMore
    }

    enum CodingKeys: String, CodingKey { case epoch, resync, changes, cursor, hasMore }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        epoch = try container.decodeIfPresent(String.self, forKey: .epoch) ?? ""
        resync = try container.decodeIfPresent(Bool.self, forKey: .resync) ?? false
        changes = try container.decodeIfPresent([ArchiveChange].self, forKey: .changes) ?? []
        cursor = try container.decodeIfPresent(String.self, forKey: .cursor) ?? ""
        hasMore = try container.decodeIfPresent(Bool.self, forKey: .hasMore) ?? false
    }
}

// MARK: Chat pages, search, terminal logs

/// `GET /v1/archive/chat`: the chat and one page of its messages, oldest
/// first; the first page holds the newest ones. Hidden messages are included.
public struct ArchiveChatPage: Decodable, Hashable, Sendable {
    public var chat: ArchiveChatRecord
    public var messages: [ArchiveMessageRecord]
    public var hasMore: Bool
    /// The next (older) page ends before this message.
    public var oldestID: String?

    public init(chat: ArchiveChatRecord, messages: [ArchiveMessageRecord], hasMore: Bool = false, oldestID: String? = nil) {
        self.chat = chat; self.messages = messages; self.hasMore = hasMore; self.oldestID = oldestID
    }

    enum CodingKeys: String, CodingKey { case chat, messages, hasMore, oldestID = "oldestId" }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        chat = try container.decode(ArchiveChatRecord.self, forKey: .chat)
        messages = try container.decodeIfPresent([ArchiveMessageRecord].self, forKey: .messages) ?? []
        hasMore = try container.decodeIfPresent(Bool.self, forKey: .hasMore) ?? false
        let oldest = try container.decodeIfPresent(String.self, forKey: .oldestID)
        oldestID = oldest?.isEmpty == false ? oldest : nil
    }
}

/// `GET /v1/archive/search`. The host quotes every term; a `*` ending the
/// last term makes it a prefix.
public struct ArchiveSearchRequest: Hashable, Sendable {
    /// `q` is limited to 256 bytes; longer text is cut at a character boundary.
    public static let maxTextBytes = 256

    public var text: String
    public var projectID: String?
    public var provider: String?
    /// Inclusive.
    public var from: Date?
    /// Exclusive.
    public var to: Date?
    public var limit: Int
    public var cursor: String?

    public init(text: String, projectID: String? = nil, provider: String? = nil, from: Date? = nil, to: Date? = nil,
                limit: Int = 20, cursor: String? = nil) {
        self.text = text; self.projectID = projectID; self.provider = provider; self.from = from; self.to = to
        self.limit = limit; self.cursor = cursor
    }
}

/// One matching message. Each match in `snippet` sits between U+0002 and U+0003.
public struct ArchiveSearchResult: Decodable, Hashable, Sendable, Identifiable {
    public var chatID: String
    public var messageID: String
    public var projectID: String
    /// The chat's provider. Hosts before it was added leave it out.
    public var provider: String?
    public var title: String
    public var role: String
    public var createdAt: String
    public var snippet: String
    public var id: String { chatID + "\u{1F}" + messageID }

    public init(chatID: String, messageID: String, projectID: String, provider: String? = nil, title: String, role: String,
                createdAt: String, snippet: String) {
        self.chatID = chatID; self.messageID = messageID; self.projectID = projectID; self.provider = provider; self.title = title
        self.role = role; self.createdAt = createdAt; self.snippet = snippet
    }

    enum CodingKeys: String, CodingKey { case chatID = "chatId", messageID = "messageId", projectID = "projectId", provider, title, role, createdAt, snippet }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        chatID = try container.decode(String.self, forKey: .chatID)
        messageID = try container.decodeIfPresent(String.self, forKey: .messageID) ?? ""
        projectID = try container.decodeIfPresent(String.self, forKey: .projectID) ?? ""
        let provider = try container.decodeIfPresent(String.self, forKey: .provider)
        self.provider = provider?.isEmpty == false ? provider : nil
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        role = try container.decodeIfPresent(String.self, forKey: .role) ?? ""
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        snippet = try container.decodeIfPresent(String.self, forKey: .snippet) ?? ""
    }
}

public struct ArchiveSearchPage: Decodable, Hashable, Sendable {
    public var results: [ArchiveSearchResult]
    /// Absent on the last page.
    public var nextCursor: String?

    public init(results: [ArchiveSearchResult], nextCursor: String? = nil) { self.results = results; self.nextCursor = nextCursor }

    enum CodingKeys: String, CodingKey { case results, nextCursor }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        results = try container.decodeIfPresent([ArchiveSearchResult].self, forKey: .results) ?? []
        let next = try container.decodeIfPresent(String.self, forKey: .nextCursor)
        nextCursor = next?.isEmpty == false ? next : nil
    }
}

public enum ArchiveExportFormat: String, Sendable, CaseIterable {
    case markdown, json
}

public struct ArchiveTerminalLogsPage: Decodable, Hashable, Sendable {
    /// Newest first.
    public var logs: [ArchiveTerminalLogRecord]
    public var nextCursor: String?

    enum CodingKeys: String, CodingKey { case logs, nextCursor }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        logs = try container.decodeIfPresent([ArchiveTerminalLogRecord].self, forKey: .logs) ?? []
        let next = try container.decodeIfPresent(String.self, forKey: .nextCursor)
        nextCursor = next?.isEmpty == false ? next : nil
    }
}

/// `raw` is the recorded bytes; `text` strips ANSI escapes.
public enum ArchiveTerminalLogFormat: String, Sendable, CaseIterable {
    case raw, text
}

/// One range of a terminal log. For `text`, `next` is the raw offset the
/// text covers, which may stop short of the range before an escape
/// sequence, a CR or a character the range cut off.
public struct ArchiveTerminalLogRange: Hashable, Sendable {
    public static let maxLength = 1 << 20

    /// Raw bytes, or UTF-8 text for `format=text`.
    public var data: Data
    public var offset: Int64
    public var next: Int64
    /// Set only once the terminal has ended and the read reached its end.
    public var eof: Bool
    public var size: Int64
    public var status: String

    public init(data: Data, offset: Int64, next: Int64, eof: Bool, size: Int64, status: String) {
        self.data = data; self.offset = offset; self.next = next; self.eof = eof; self.size = size; self.status = status
    }
}

public enum ArchiveDeleteKind: String, Sendable {
    case chat, terminalLog
}

public enum ArchiveDeleteOutcome: Equatable, Sendable {
    /// The host answered `deleted`; only now may the device drop its copy.
    case deleted
    /// The request may have reached the host. Never retried automatically.
    case uncertain
    case failed(ClientError)
}

// MARK: Client

extension APIClient {
    /// Changes per page: the host's maximum.
    public static let archiveChangesPageLimit = 200
    /// The longest `wait` the host takes on the change feed.
    public static let archiveChangesMaxWait: Duration = .seconds(20)

    /// `GET /v1/archive/changes` after `cursor` (nil starts from the beginning).
    /// `wait` (at most 20 s) long-polls: with nothing after the cursor the host
    /// answers when a change comes or the wait ends. Pass it only to hosts that
    /// list `changesWait`; others answer at once.
    public func archiveChanges(after cursor: String?, limit: Int = APIClient.archiveChangesPageLimit,
                               wait: Duration? = nil) async throws -> ArchiveChangesPage {
        var query = [URLQueryItem(name: "limit", value: String(min(max(limit, 1), Self.archiveChangesPageLimit)))]
        if let cursor, !cursor.isEmpty { query.insert(URLQueryItem(name: "after", value: cursor), at: 0) }
        // A page is about 2 MiB; one large message can make it several.
        var timeout: TimeInterval = 60
        if let wait, wait > .zero {
            let clamped = min(wait, Self.archiveChangesMaxWait)
            let milliseconds = clamped.components.seconds * 1_000 + clamped.components.attoseconds / 1_000_000_000_000_000
            query.append(URLQueryItem(name: "wait", value: String(milliseconds)))
            timeout += Double(milliseconds) / 1_000
        }
        return try await get("/v1/archive/changes", query: query, timeout: timeout)
    }

    /// `GET /v1/archive/chat`: newest messages first page; `before` pages back.
    public func archiveChat(chatID: String, before: String? = nil, limit: Int = 50) async throws -> ArchiveChatPage {
        var query = [URLQueryItem(name: "chatId", value: chatID), URLQueryItem(name: "limit", value: String(min(max(limit, 1), 50)))]
        if let before, !before.isEmpty { query.append(URLQueryItem(name: "before", value: before)) }
        return try await get("/v1/archive/chat", query: query, timeout: 30)
    }

    /// `GET /v1/archive/search`.
    public func archiveSearch(_ request: ArchiveSearchRequest) async throws -> ArchiveSearchPage {
        var query = [URLQueryItem(name: "q", value: Self.clip(request.text, bytes: ArchiveSearchRequest.maxTextBytes))]
        if let projectID = request.projectID, !projectID.isEmpty { query.append(URLQueryItem(name: "projectId", value: projectID)) }
        if let provider = request.provider, !provider.isEmpty { query.append(URLQueryItem(name: "provider", value: provider)) }
        if let from = request.from { query.append(URLQueryItem(name: "from", value: Self.rfc3339(from))) }
        if let to = request.to { query.append(URLQueryItem(name: "to", value: Self.rfc3339(to))) }
        query.append(URLQueryItem(name: "limit", value: String(min(max(request.limit, 1), 50))))
        if let cursor = request.cursor, !cursor.isEmpty { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        return try await get("/v1/archive/search", query: query)
    }

    /// `GET /v1/archive/export` for one chat: the file's bytes.
    public func archiveExport(chatID: String, format: ArchiveExportFormat) async throws -> Data {
        try await getData("/v1/archive/export", query: [URLQueryItem(name: "chatId", value: chatID),
                                                       URLQueryItem(name: "format", value: format.rawValue)], timeout: 120)
    }

    /// The largest attachment the archive keeps.
    public static let archiveAttachmentLimit = 64 << 20

    /// `GET /v1/archive/blob`: the bytes of the attachment `name` of a message
    /// (for hosts that list `blobs`). `sha256`, when the device has it, picks
    /// one of several attachments with that name. 404 `attachment_not_archived`
    /// means the host kept the file's name only.
    public func archiveAttachment(chatID: String, messageID: String, name: String, sha256: String? = nil) async throws -> Data {
        var query = [URLQueryItem(name: "chatId", value: chatID), URLQueryItem(name: "messageId", value: messageID),
                     URLQueryItem(name: "name", value: name)]
        if let sha256, !sha256.isEmpty { query.append(URLQueryItem(name: "sha256", value: sha256)) }
        let data = try await getData("/v1/archive/blob", query: query, timeout: 120)
        guard data.count <= Self.archiveAttachmentLimit else { throw ClientError.invalidResponse }
        return data
    }

    /// `GET /v1/archive/terminal-logs`, newest first.
    public func archiveTerminalLogs(projectID: String? = nil, after cursor: String? = nil, limit: Int = 100) async throws -> ArchiveTerminalLogsPage {
        var query: [URLQueryItem] = []
        if let projectID, !projectID.isEmpty { query.append(URLQueryItem(name: "projectId", value: projectID)) }
        if let cursor, !cursor.isEmpty { query.append(URLQueryItem(name: "after", value: cursor)) }
        query.append(URLQueryItem(name: "limit", value: String(min(max(limit, 1), 200))))
        return try await get("/v1/archive/terminal-logs", query: query)
    }

    /// `GET /v1/archive/terminal-log`: one range of at most 1 MiB.
    public func archiveTerminalLog(id: String, offset: Int64, length: Int = ArchiveTerminalLogRange.maxLength,
                                   format: ArchiveTerminalLogFormat = .raw) async throws -> ArchiveTerminalLogRange {
        let query = [URLQueryItem(name: "id", value: id), URLQueryItem(name: "offset", value: String(max(offset, 0))),
                     URLQueryItem(name: "length", value: String(min(max(length, 1), ArchiveTerminalLogRange.maxLength))),
                     URLQueryItem(name: "format", value: format.rawValue)]
        let wire: TerminalRangeWire = try await get("/v1/archive/terminal-log", query: query, timeout: 30)
        let data: Data
        switch format {
        case .raw:
            guard let decoded = Data(base64Encoded: wire.data ?? "") else { throw ClientError.decoding }
            data = decoded
        case .text:
            data = Data((wire.data ?? "").utf8)
        }
        return ArchiveTerminalLogRange(data: data, offset: wire.offset ?? max(offset, 0), next: wire.next ?? max(offset, 0),
                                       eof: wire.eof ?? false, size: wire.size ?? 0, status: wire.status ?? "")
    }

    /// `POST /v1/archive/delete`. Nothing is retried; only `.deleted` means the
    /// host dropped it.
    public func archiveDelete(_ kind: ArchiveDeleteKind, id: String) async -> ArchiveDeleteOutcome {
        do {
            let response: DeletedResponse = try await post("/v1/archive/delete", body: ["kind": kind.rawValue, "id": id], expected: 200)
            return response.deleted ? .deleted : .failed(.unexpectedStatus(200))
        } catch let error as ClientError {
            switch mutationOutcome(for: error) {
            case .uncertain, .accepted: return .uncertain
            case let .failed(error): return .failed(error)
            }
        } catch { return ClientError.isUndelivered(error) ? .failed(.unreachable) : .uncertain }
    }

    func getData(_ path: String, query: [URLQueryItem], timeout: TimeInterval) async throws -> Data {
        try Task.checkCancellation()
        var request = try makeRequest(path: path, method: "GET", query: query)
        request.timeoutInterval = timeout
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        let (data, response) = try await transport.execute(request)
        try validate(response, data: data, expected: 200)
        return data
    }

    /// RFC 3339 in UTC, whole seconds.
    static func rfc3339(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(timeZone: TimeZone(identifier: "UTC")!))
    }

    /// The longest prefix of whole characters within `bytes` UTF-8 bytes.
    static func clip(_ text: String, bytes: Int) -> String {
        guard text.utf8.count > bytes else { return text }
        var result = ""
        for character in text {
            guard result.utf8.count + character.utf8.count <= bytes else { break }
            result.append(character)
        }
        return result
    }

    private struct TerminalRangeWire: Decodable {
        let data: String?; let offset: Int64?; let next: Int64?; let eof: Bool?; let size: Int64?; let status: String?
    }
    private struct DeletedResponse: Decodable { let deleted: Bool }
}
