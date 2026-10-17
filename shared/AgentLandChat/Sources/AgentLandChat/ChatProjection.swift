import Foundation
import Observation
import AgentLandCore

/// One part of one message. Views read only the properties they show, so a
/// delta that grows this part's text redraws this part and nothing else.
@MainActor @Observable
public final class ChatPartModel: Identifiable {
    public let id: String
    public let messageID: String
    public let kind: ConversationPartKind
    public private(set) var ord: Int64
    public private(set) var text: String
    public private(set) var tool: ConversationTool?
    public private(set) var attachment: AttachmentRecord?
    public private(set) var start: String?
    public private(set) var end: String?
    public private(set) var truncated: Bool
    public private(set) var durationMs: Int?

    @ObservationIgnored private var parser: MarkdownStreamParser?
    @ObservationIgnored private var unparsed = ""

    init(_ part: ConversationPart, messageID: String) {
        id = part.id
        self.messageID = messageID
        kind = part.kind
        ord = part.ord
        text = part.text
        tool = part.tool
        attachment = part.attachment
        start = part.start
        end = part.end
        truncated = part.truncated
        durationMs = part.durationMs
    }

    /// Markdown blocks of the text, parsed incrementally: appended text is
    /// parsed from the last unfinished block on, never from the start.
    public var markdownBlocks: [MarkdownBlock] {
        let current = text
        guard let parser else {
            let created = MarkdownStreamParser(current)
            parser = created
            unparsed = ""
            return created.blocks
        }
        if !unparsed.isEmpty {
            parser.append(unparsed)
            unparsed = ""
        }
        return parser.blocks
    }

    /// Lines the parser has read so far (performance tests).
    public var parsedLineCount: Int { parser?.parsedLineCount ?? 0 }

    func append(_ delta: String, field: ConversationPartDelta.Field) {
        switch field {
        case .text:
            text.append(delta)
            if parser != nil { unparsed.append(delta) }
        case .output:
            var value = tool ?? ConversationTool(name: "tool", status: .running)
            value.output.append(delta)
            tool = value
        }
    }

    func update(from part: ConversationPart) {
        if ord != part.ord { ord = part.ord }
        if text != part.text {
            if part.text.hasPrefix(text) {
                append(String(part.text.dropFirst(text.count)), field: .text)
            } else {
                text = part.text
                parser = nil
                unparsed = ""
            }
        }
        if tool != part.tool { tool = part.tool }
        if attachment != part.attachment { attachment = part.attachment }
        if start != part.start { start = part.start }
        if end != part.end { end = part.end }
        if truncated != part.truncated { truncated = part.truncated }
        if durationMs != part.durationMs { durationMs = part.durationMs }
    }
}

@MainActor @Observable
public final class ChatMessageModel: Identifiable {
    public let id: String
    public let role: MessageRole
    public private(set) var turnID: String
    public private(set) var status: ConversationMessageStatus
    public private(set) var ord: Int64
    public private(set) var createdAt: String
    public private(set) var completedAt: String?
    public private(set) var provider: String
    public private(set) var model: String?
    public private(set) var usage: ConversationUsage?
    public private(set) var error: ConversationError?
    public private(set) var parts: [ChatPartModel] = []

    init(_ message: ConversationMessage) {
        id = message.id
        role = message.role
        turnID = message.turnID
        status = message.status
        ord = message.ord
        createdAt = message.createdAt
        completedAt = message.completedAt
        provider = message.provider
        model = message.model
        usage = message.usage
        error = message.error
        parts = message.parts.map { ChatPartModel($0, messageID: message.id) }
    }

    public func part(_ id: String) -> ChatPartModel? { parts.first { $0.id == id } }

    /// The text parts joined, as Copy and exports show a message.
    public var plainText: String {
        parts.filter { $0.kind == .text || $0.kind == .context }.map(\.text).joined(separator: "\n\n")
    }

    public var attachments: [AttachmentRecord] { parts.compactMap(\.attachment) }

    func updateHeader(from message: ConversationMessage) {
        if turnID != message.turnID { turnID = message.turnID }
        if status != message.status { status = message.status }
        if ord != message.ord { ord = message.ord }
        if createdAt != message.createdAt { createdAt = message.createdAt }
        if completedAt != message.completedAt { completedAt = message.completedAt }
        if provider != message.provider { provider = message.provider }
        if model != message.model { model = message.model }
        if usage != message.usage { usage = message.usage }
        if error != message.error { error = message.error }
    }

    /// Brings every part in line with the state, keeping part models (and
    /// their parse caches) for parts that stay.
    func syncParts(from message: ConversationMessage) {
        var existing = Dictionary(uniqueKeysWithValues: parts.map { ($0.id, $0) })
        var next: [ChatPartModel] = []
        next.reserveCapacity(message.parts.count)
        for part in message.parts {
            if let model = existing.removeValue(forKey: part.id), model.kind == part.kind {
                model.update(from: part)
                next.append(model)
            } else {
                next.append(ChatPartModel(part, messageID: message.id))
            }
        }
        if !next.elementsEqual(parts, by: ===) { parts = next }
    }
}

/// An agent reply: every assistant message of one turn, in order.
@MainActor @Observable
public final class ChatReplyModel: Identifiable {
    public let id: String
    public let turnKey: String
    public private(set) var messages: [ChatMessageModel] = []
    public private(set) var isLatest = false
    public private(set) var resolved: [ChatResolvedInteraction] = []

    init(turnKey: String) {
        self.turnKey = turnKey
        id = "reply-" + turnKey
    }

    func set(messages next: [ChatMessageModel]) {
        if !next.elementsEqual(messages, by: ===) { messages = next }
    }
    func set(latest: Bool) { if isLatest != latest { isLatest = latest } }
    func set(resolved next: [ChatResolvedInteraction]) { if resolved != next { resolved = next } }

    public var parts: [ChatPartModel] { messages.flatMap(\.parts) }
    public var isStreaming: Bool { messages.contains { $0.status == .streaming } }
    public var error: ConversationError? { messages.last(where: { $0.error != nil })?.error }
    public var failed: Bool { messages.contains { $0.status == .error } }
    public var aborted: Bool { messages.last?.status == .aborted }
    public var model: String? { messages.last(where: { $0.model != nil })?.model }
    /// The reply's text, as Copy and exports show it (no reasoning or tools).
    public var plainText: String {
        messages.map(\.plainText).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}

/// A row of the transcript.
public enum ChatRow: Identifiable {
    /// Older messages exist before the first loaded one.
    case earlier
    case user(ChatMessageModel)
    /// The seed of a chat continued from another one.
    case context(ChatMessageModel)
    case reply(ChatReplyModel)

    public var id: String {
        switch self {
        case .earlier: "earlier"
        case let .user(message): "user-" + message.id
        case let .context(message): "context-" + message.id
        case let .reply(reply): reply.id
        }
    }
}

/// The transcript as observable models, kept in step with `ChatState`.
@MainActor @Observable
public final class ChatProjection {
    public private(set) var rows: [ChatRow] = []
    @ObservationIgnored private var messageModels: [String: ChatMessageModel] = [:]
    @ObservationIgnored private var replyModels: [String: ChatReplyModel] = [:]
    @ObservationIgnored private var rowIDs: [String] = []

    public init() {}

    public func message(_ id: String) -> ChatMessageModel? { messageModels[id] }
    public var latestReply: ChatReplyModel? {
        for row in rows.reversed() { if case let .reply(reply) = row { return reply } }
        return nil
    }
    public var messages: [ChatMessageModel] {
        rows.flatMap { row -> [ChatMessageModel] in
            switch row {
            case .earlier: []
            case let .user(message), let .context(message): [message]
            case let .reply(reply): reply.messages
            }
        }
    }

    /// Applies what `changes` says moved. Messages synced in full skip their
    /// appended text, which the full sync already includes.
    public func sync(_ state: ChatState, changes: ChatChanges) {
        var synced = Set<String>()
        let rebuild = changes.reset || changes.structure || (messageModels.isEmpty && !state.messages.isEmpty)
        if rebuild {
            var models: [String: ChatMessageModel] = [:]
            for message in state.messages {
                if let model = messageModels[message.id] {
                    if changes.reset || changes.messages.contains(message.id) { model.updateHeader(from: message) }
                    if changes.reset || changes.partLists.contains(message.id) {
                        model.syncParts(from: message)
                        synced.insert(message.id)
                    }
                    models[message.id] = model
                } else {
                    models[message.id] = ChatMessageModel(message)
                    synced.insert(message.id)
                }
            }
            messageModels = models
        } else {
            for id in changes.messages {
                guard let model = messageModels[id], let index = state.messageIndex(id) else { continue }
                model.updateHeader(from: state.messages[index])
            }
            for id in changes.partLists {
                guard let model = messageModels[id], let index = state.messageIndex(id) else { continue }
                model.syncParts(from: state.messages[index])
                synced.insert(id)
            }
        }
        for key in changes.parts where !synced.contains(key.messageID) {
            guard let index = state.messageIndex(key.messageID),
                  let part = state.messages[index].parts.first(where: { $0.id == key.partID }),
                  let model = messageModels[key.messageID]?.part(key.partID) else { continue }
            model.update(from: part)
        }
        for (key, text) in changes.appended where !synced.contains(key.messageID) && !changes.parts.contains(key) {
            messageModels[key.messageID]?.part(key.partID)?.append(text, field: key.field)
        }
        if rebuild || changes.meta { rebuildRows(state) }
    }

    private func rebuildRows(_ state: ChatState) {
        var next: [ChatRow] = []
        var replies: [String: ChatReplyModel] = [:]
        if state.hasMore { next.append(.earlier) }
        var current: (key: String, reply: ChatReplyModel, messages: [ChatMessageModel])?
        func closeReply() {
            guard let open = current else { return }
            open.reply.set(messages: open.messages)
            current = nil
        }
        for message in state.messages {
            guard let model = messageModels[message.id] else { continue }
            if message.role == .user {
                closeReply()
                let seed = !message.parts.isEmpty && message.parts.allSatisfy { $0.kind == .context }
                next.append(seed ? .context(model) : .user(model))
                continue
            }
            let key = message.turnID.isEmpty ? message.id : message.turnID
            if current?.key == key {
                current?.messages.append(model)
                continue
            }
            closeReply()
            let reply = replies[key] ?? replyModels[key] ?? ChatReplyModel(turnKey: key)
            replies[key] = reply
            current = (key, reply, [model])
            next.append(.reply(reply))
        }
        closeReply()
        replyModels = replies
        let latestID = next.last.flatMap { row -> String? in if case let .reply(reply) = row { return reply.id } else { return nil } }
        for reply in replies.values {
            reply.set(latest: reply.id == latestID)
            reply.set(resolved: state.resolved.filter { $0.turnID == reply.turnKey })
        }
        let ids = next.map(\.id)
        if ids != rowIDs || next.count != rows.count || !zip(next, rows).allSatisfy(Self.sameRow) {
            rowIDs = ids
            rows = next
        }
    }

    private static func sameRow(_ pair: (ChatRow, ChatRow)) -> Bool {
        switch pair {
        case (.earlier, .earlier): true
        case let (.user(a), .user(b)), let (.context(a), .context(b)): a === b
        case let (.reply(a), .reply(b)): a === b
        default: false
        }
    }
}
