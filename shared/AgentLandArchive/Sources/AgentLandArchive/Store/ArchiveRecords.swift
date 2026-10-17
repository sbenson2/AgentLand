import Foundation
import AgentLandCore

/// A chat in this device's copy of the host's archive.
public struct ArchivedChat: Identifiable, Hashable, Sendable {
    public var id: String
    public var projectID: String
    /// `opencode`, `claude`, `codex` or a provider this version cannot name.
    public var provider: String
    public var title: String
    public var model: String?
    public var mode: String?
    public var effort: String?
    /// The chat this one was continued or forked from.
    public var parentID: String?
    public var relation: String?
    public var createdAt: Date
    /// The chat's last activity, as the host records it.
    public var updatedAt: Date
    /// Pinned on this device only.
    public var pinned: Bool

    public init(id: String, projectID: String, provider: String, title: String, model: String? = nil, mode: String? = nil,
                effort: String? = nil, parentID: String? = nil, relation: String? = nil, createdAt: Date, updatedAt: Date,
                pinned: Bool = false) {
        self.id = id; self.projectID = projectID; self.provider = provider; self.title = title; self.model = model
        self.mode = mode; self.effort = effort; self.parentID = parentID; self.relation = relation
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.pinned = pinned
    }

    public var agent: AgentProvider { AgentProvider(id: provider) }

    /// The title, or a neutral name for a chat nobody named.
    public var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled Chat" : trimmed
    }

    /// The chat as a chat screen names it.
    public var info: ChatInfo { ChatInfo(id: id, title: title, provider: provider, model: model, mode: mode, effort: effort) }
}

/// A message in this device's copy. Rewound messages stay, marked hidden.
public struct ArchivedMessage: Identifiable, Hashable, Sendable {
    public var message: ConversationMessage
    public var hidden: Bool

    public init(message: ConversationMessage, hidden: Bool = false) { self.message = message; self.hidden = hidden }

    public var id: String { message.id }
    /// The seed of a chat continued from another one.
    public var isContextSeed: Bool { !message.parts.isEmpty && message.parts.allSatisfy { $0.kind == .context } }
}

/// A terminal's recorded output, metadata only; the bytes are fetched on demand.
public struct ArchivedTerminalLog: Identifiable, Hashable, Sendable {
    public var id: String
    public var projectID: String
    public var title: String
    public var program: String
    public var startedAt: Date
    public var endedAt: Date?
    public var status: String
    public var exitCode: Int?
    public var bytes: Int64
    public var gapBytes: Int64

    public init(id: String, projectID: String, title: String, program: String, startedAt: Date, endedAt: Date? = nil,
                status: String, exitCode: Int? = nil, bytes: Int64, gapBytes: Int64 = 0) {
        self.id = id; self.projectID = projectID; self.title = title; self.program = program; self.startedAt = startedAt
        self.endedAt = endedAt; self.status = status; self.exitCode = exitCode; self.bytes = bytes; self.gapBytes = gapBytes
    }

    public var isRunning: Bool { status == "running" }
    public var programName: String { TerminalProgram(id: program).displayName }
    public var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? TerminalProgram(id: program).terminalTitle : trimmed
    }
}

/// Where this device's copy stands in the host's change feed.
public struct ArchiveSyncState: Equatable, Sendable {
    /// The host identity the database belongs to (`ConnectionIdentity.storageKey`).
    public var hostKey: String
    public var epoch: String?
    /// Opaque; nil starts from the beginning.
    public var cursor: String?
    /// When the last page was committed.
    public var syncedAt: Date?
}

/// What applying one page did.
public struct ArchiveApplyResult: Equatable, Sendable {
    public var applied = 0
    /// Changes this version could not read, skipped.
    public var unreadable = 0
    /// The page started over (`resync`), so the copy was cleared first.
    public var cleared = false
    public init(applied: Int = 0, unreadable: Int = 0, cleared: Bool = false) {
        self.applied = applied; self.unreadable = unreadable; self.cleared = cleared
    }
}

/// Narrows the chat list.
public struct ArchiveChatFilter: Equatable, Sendable {
    public var projectID: String?
    public var provider: String?
    /// Last activity at or after.
    public var from: Date?
    /// Last activity before.
    public var to: Date?
    public var limit: Int

    public init(projectID: String? = nil, provider: String? = nil, from: Date? = nil, to: Date? = nil, limit: Int = 5_000) {
        self.projectID = projectID; self.provider = provider; self.from = from; self.to = to; self.limit = limit
    }
}

/// One full-text match, from this device's copy or from the host.
public struct ArchiveSearchHit: Identifiable, Hashable, Sendable {
    public var chatID: String
    public var messageID: String
    public var projectID: String
    public var title: String
    /// Nil when this device has not copied the chat yet (host results carry no provider).
    public var provider: String?
    public var role: MessageRole?
    public var createdAt: Date?
    /// Matches sit between U+0002 and U+0003.
    public var snippet: String

    public init(chatID: String, messageID: String, projectID: String, title: String, provider: String?, role: MessageRole?,
                createdAt: Date?, snippet: String) {
        self.chatID = chatID; self.messageID = messageID; self.projectID = projectID; self.title = title
        self.provider = provider; self.role = role; self.createdAt = createdAt; self.snippet = snippet
    }

    public var id: String { chatID + "\u{1F}" + messageID }
    public var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled Chat" : trimmed
    }
}

/// Times as the archive stores them: milliseconds since 1970, UTC.
enum ArchiveTime {
    static func milliseconds(_ text: String?) -> Int64? {
        ChatTime.date(text).map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) }
    }

    static func milliseconds(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }

    static func date(_ milliseconds: Int64) -> Date { Date(timeIntervalSince1970: Double(milliseconds) / 1000) }

    /// RFC 3339 with milliseconds, as the host writes times.
    static func text(_ milliseconds: Int64) -> String {
        let seconds = milliseconds >= 0 ? milliseconds / 1000 : (milliseconds - 999) / 1000
        let remainder = milliseconds - seconds * 1000
        let whole = Date(timeIntervalSince1970: TimeInterval(seconds)).formatted(utcStyle)
        return String(whole.dropLast()) + String(format: ".%03lldZ", remainder)
    }

    private static let utcStyle = Date.ISO8601FormatStyle(timeZone: TimeZone(identifier: "UTC")!)
}

extension String {
    /// The longest prefix of whole characters within `bytes` UTF-8 bytes.
    func clipped(toBytes bytes: Int) -> String {
        guard utf8.count > bytes else { return self }
        var result = ""
        var used = 0
        for character in self {
            let size = character.utf8.count
            guard used + size <= bytes else { break }
            result.append(character)
            used += size
        }
        return result
    }
}
