import Foundation

// The unified conversation model and the chat event stream of docs/HOST-API.md
// ("Conversation model", "Chat event stream"). Every decoder here is tolerant:
// fields a host leaves out get their documented defaults, `null` lists read as
// empty, and values this version does not know are kept as `.other` rather
// than failing the whole line.

/// A message's lifecycle. Unknown values read as `.complete`.
public enum ConversationMessageStatus: String, Codable, Hashable, Sendable {
    case streaming, complete, error, aborted

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ConversationMessageStatus(rawValue: raw) ?? .complete
    }
}

/// What a part carries. Kinds added by later hosts are kept by name.
public enum ConversationPartKind: Hashable, Sendable, Codable {
    case text, reasoning, tool, attachment, patch, notice, context
    case other(String)

    public init(rawValue: String) {
        switch rawValue {
        case "text": self = .text
        case "reasoning": self = .reasoning
        case "tool": self = .tool
        case "attachment": self = .attachment
        case "patch": self = .patch
        case "notice": self = .notice
        case "context": self = .context
        default: self = .other(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .text: "text"
        case .reasoning: "reasoning"
        case .tool: "tool"
        case .attachment: "attachment"
        case .patch: "patch"
        case .notice: "notice"
        case .context: "context"
        case let .other(value): value
        }
    }

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct ConversationUsage: Codable, Hashable, Sendable {
    public var input: Int64
    public var output: Int64
    public var reasoning: Int64
    public var cacheRead: Int64
    public var cacheWrite: Int64
    public var costMicros: Int64?

    public init(input: Int64 = 0, output: Int64 = 0, reasoning: Int64 = 0, cacheRead: Int64 = 0, cacheWrite: Int64 = 0,
                costMicros: Int64? = nil) {
        self.input = input; self.output = output; self.reasoning = reasoning
        self.cacheRead = cacheRead; self.cacheWrite = cacheWrite; self.costMicros = costMicros
    }

    enum CodingKeys: String, CodingKey { case input, output, reasoning, cacheRead, cacheWrite, costMicros }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        input = try container.decodeIfPresent(Int64.self, forKey: .input) ?? 0
        output = try container.decodeIfPresent(Int64.self, forKey: .output) ?? 0
        reasoning = try container.decodeIfPresent(Int64.self, forKey: .reasoning) ?? 0
        cacheRead = try container.decodeIfPresent(Int64.self, forKey: .cacheRead) ?? 0
        cacheWrite = try container.decodeIfPresent(Int64.self, forKey: .cacheWrite) ?? 0
        costMicros = try container.decodeIfPresent(Int64.self, forKey: .costMicros)
    }
}

public struct ConversationError: Codable, Hashable, Sendable {
    public var code: String
    public var message: String
    public init(code: String, message: String) { self.code = code; self.message = message }

    enum CodingKeys: String, CodingKey { case code, message }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decodeIfPresent(String.self, forKey: .code) ?? "agent_error"
        message = try container.decodeIfPresent(String.self, forKey: .message) ?? ""
    }
}

/// A tool call inside a reply. `name` is the provider's own tool name.
public struct ConversationTool: Codable, Hashable, Sendable {
    public var name: String
    public var callID: String
    public var status: ToolStatus
    public var title: String
    public var input: String
    public var output: String
    public var error: String
    public var truncated: Bool
    /// The web pages the tool found or read, in its order (`websearch`, `agentland_fetch`; docs/HOST-API.md
    /// "Plain chats"). Empty for other tools and from hosts that send none.
    public var sources: [ChatToolSource]
    /// The memory entry an `agentland_memory_save` stored, for "Memory updated" and its Undo.
    public var memory: ChatToolMemory?

    public init(name: String, callID: String = "", status: ToolStatus, title: String = "", input: String = "",
                output: String = "", error: String = "", truncated: Bool = false, sources: [ChatToolSource] = [],
                memory: ChatToolMemory? = nil) {
        self.name = name; self.callID = callID; self.status = status; self.title = title
        self.input = input; self.output = output; self.error = error; self.truncated = truncated
        self.sources = sources; self.memory = memory
    }

    enum CodingKeys: String, CodingKey { case name, callID = "callId", status, title, input, output, error, truncated, sources, memory }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "tool"
        callID = try container.decodeIfPresent(String.self, forKey: .callID) ?? ""
        let raw = try container.decodeIfPresent(String.self, forKey: .status) ?? "running"
        status = ToolStatus(rawValue: raw) ?? .running
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        input = try container.decodeIfPresent(String.self, forKey: .input) ?? ""
        output = try container.decodeIfPresent(String.self, forKey: .output) ?? ""
        error = try container.decodeIfPresent(String.self, forKey: .error) ?? ""
        truncated = try container.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
        // Sources and memory this version cannot read are left out; they never cost the part. Members it does
        // not know (`attachments`, reserved for a later round) are ignored.
        sources = ChatToolSource.decodeList(from: container, forKey: .sources)
        memory = ChatToolMemory.decodeIfPresent(from: container, forKey: .memory)
    }

    /// Sources and memory are left out when there are none, so a part without them encodes as before.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(callID, forKey: .callID)
        try container.encode(status, forKey: .status)
        try container.encode(title, forKey: .title)
        try container.encode(input, forKey: .input)
        try container.encode(output, forKey: .output)
        try container.encode(error, forKey: .error)
        try container.encode(truncated, forKey: .truncated)
        if !sources.isEmpty { try container.encode(sources, forKey: .sources) }
        try container.encodeIfPresent(memory, forKey: .memory)
    }
}

public struct ConversationPart: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var kind: ConversationPartKind
    public var ord: Int64
    public var text: String
    public var tool: ConversationTool?
    public var attachment: AttachmentRecord?
    public var start: String?
    public var end: String?
    public var truncated: Bool
    /// Reasoning time reported by hosts that predate part timestamps.
    public var durationMs: Int?

    public init(id: String, kind: ConversationPartKind, ord: Int64 = 0, text: String = "", tool: ConversationTool? = nil,
                attachment: AttachmentRecord? = nil, start: String? = nil, end: String? = nil, truncated: Bool = false,
                durationMs: Int? = nil) {
        self.id = id; self.kind = kind; self.ord = ord; self.text = text; self.tool = tool
        self.attachment = attachment; self.start = start; self.end = end; self.truncated = truncated
        self.durationMs = durationMs
    }

    enum CodingKeys: String, CodingKey { case id, kind, ord, text, tool, attachment, start, end, truncated }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decodeIfPresent(ConversationPartKind.self, forKey: .kind) ?? .other("")
        ord = try container.decodeIfPresent(Int64.self, forKey: .ord) ?? 0
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        tool = try container.decodeIfPresent(ConversationTool.self, forKey: .tool)
        attachment = try container.decodeIfPresent(AttachmentRecord.self, forKey: .attachment)
        start = try container.decodeIfPresent(String.self, forKey: .start)
        end = try container.decodeIfPresent(String.self, forKey: .end)
        truncated = try container.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
    }
}

public struct ConversationMessage: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var chatID: String
    public var turnID: String
    public var role: MessageRole
    public var status: ConversationMessageStatus
    public var ord: Int64
    public var createdAt: String
    public var completedAt: String?
    public var provider: String
    public var model: String?
    public var usage: ConversationUsage?
    public var error: ConversationError?
    public var parts: [ConversationPart]

    public init(id: String, chatID: String = "", turnID: String = "", role: MessageRole, status: ConversationMessageStatus = .complete,
                ord: Int64 = 0, createdAt: String = "", completedAt: String? = nil, provider: String = "opencode",
                model: String? = nil, usage: ConversationUsage? = nil, error: ConversationError? = nil,
                parts: [ConversationPart] = []) {
        self.id = id; self.chatID = chatID; self.turnID = turnID; self.role = role; self.status = status
        self.ord = ord; self.createdAt = createdAt; self.completedAt = completedAt; self.provider = provider
        self.model = model; self.usage = usage; self.error = error; self.parts = parts
    }

    enum CodingKeys: String, CodingKey {
        case id, chatID = "chatId", turnID = "turnId", role, status, ord, createdAt, completedAt, provider, model, usage, error, parts
    }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        chatID = try container.decodeIfPresent(String.self, forKey: .chatID) ?? ""
        turnID = try container.decodeIfPresent(String.self, forKey: .turnID) ?? ""
        let rawRole = try container.decodeIfPresent(String.self, forKey: .role) ?? "assistant"
        role = MessageRole(rawValue: rawRole) ?? .assistant
        status = try container.decodeIfPresent(ConversationMessageStatus.self, forKey: .status) ?? .complete
        ord = try container.decodeIfPresent(Int64.self, forKey: .ord) ?? 0
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        completedAt = try container.decodeIfPresent(String.self, forKey: .completedAt)
        provider = try container.decodeIfPresent(String.self, forKey: .provider) ?? "opencode"
        model = try container.decodeIfPresent(String.self, forKey: .model)
        usage = try container.decodeIfPresent(ConversationUsage.self, forKey: .usage)
        error = try container.decodeIfPresent(ConversationError.self, forKey: .error)
        parts = try container.decodeIfPresent([ConversationPart].self, forKey: .parts) ?? []
    }

    /// The message's text parts joined, as a copy or export shows them.
    public var plainText: String {
        parts.filter { $0.kind == .text }.map(\.text).joined(separator: "\n\n")
    }
}

// MARK: Interactions

public struct ChatQuestionOption: Codable, Hashable, Sendable, Identifiable {
    public var label: String
    public var description: String
    public var id: String { label }
    public init(label: String, description: String = "") { self.label = label; self.description = description }

    enum CodingKeys: String, CodingKey { case label, description }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
    }
}

public struct ChatQuestion: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var text: String
    public var header: String
    public var options: [ChatQuestionOption]
    public var multiple: Bool
    public var custom: Bool
    public var secret: Bool

    public init(id: String, text: String, header: String = "", options: [ChatQuestionOption] = [], multiple: Bool = false,
                custom: Bool = false, secret: Bool = false) {
        self.id = id; self.text = text; self.header = header; self.options = options
        self.multiple = multiple; self.custom = custom; self.secret = secret
    }

    enum CodingKeys: String, CodingKey { case id, text, header, options, multiple, custom, secret }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        header = try container.decodeIfPresent(String.self, forKey: .header) ?? ""
        options = try container.decodeIfPresent([ChatQuestionOption].self, forKey: .options) ?? []
        multiple = try container.decodeIfPresent(Bool.self, forKey: .multiple) ?? false
        custom = try container.decodeIfPresent(Bool.self, forKey: .custom) ?? false
        secret = try container.decodeIfPresent(Bool.self, forKey: .secret) ?? false
    }
}

public struct ChatPermission: Codable, Hashable, Sendable {
    public var tool: String
    public var title: String
    public var detail: String
    public var input: String

    public init(tool: String, title: String = "", detail: String = "", input: String = "") {
        self.tool = tool; self.title = title; self.detail = detail; self.input = input
    }

    enum CodingKeys: String, CodingKey { case tool, title, detail, input }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tool = try container.decodeIfPresent(String.self, forKey: .tool) ?? ""
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        detail = try container.decodeIfPresent(String.self, forKey: .detail) ?? ""
        input = try container.decodeIfPresent(String.self, forKey: .input) ?? ""
    }
}

/// A permission request or a set of questions the agent is waiting on.
public struct ChatInteraction: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case permission, question

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .question
        }
    }
    public var id: String
    public var chatID: String
    public var kind: Kind
    public var createdAt: String
    /// Permission replies this request offers: `once`, `always`, `reject`.
    public var choices: [String]
    /// What `always` grants, worded by the host ("Allow Bash(npm test *) in this
    /// project"), with more detail when there is some; hosts without it send neither.
    public var alwaysLabel: String?
    public var alwaysDetail: String?
    public var permission: ChatPermission?
    public var questions: [ChatQuestion]

    public init(id: String, chatID: String = "", kind: Kind, createdAt: String = "", choices: [String] = [],
                alwaysLabel: String? = nil, alwaysDetail: String? = nil,
                permission: ChatPermission? = nil, questions: [ChatQuestion] = []) {
        self.id = id; self.chatID = chatID; self.kind = kind; self.createdAt = createdAt
        self.choices = choices; self.alwaysLabel = alwaysLabel; self.alwaysDetail = alwaysDetail
        self.permission = permission; self.questions = questions
    }

    enum CodingKeys: String, CodingKey {
        case id, chatID = "chatId", kind, createdAt, choices, alwaysLabel, alwaysDetail, permission, questions
    }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        chatID = try container.decodeIfPresent(String.self, forKey: .chatID) ?? ""
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .question
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        choices = try container.decodeIfPresent([String].self, forKey: .choices) ?? []
        alwaysLabel = try container.decodeIfPresent(String.self, forKey: .alwaysLabel)
        alwaysDetail = try container.decodeIfPresent(String.self, forKey: .alwaysDetail)
        permission = try container.decodeIfPresent(ChatPermission.self, forKey: .permission)
        questions = try container.decodeIfPresent([ChatQuestion].self, forKey: .questions) ?? []
    }

    /// Permissions from hosts that predate the choice list offer once and reject.
    public var offersAlways: Bool { choices.contains("always") }
}

// MARK: Chat state

/// The chat's activity: `waiting` means an interaction is pending.
public enum ChatRunState: String, Codable, Hashable, Sendable {
    case idle, running, waiting, retry, error, unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ChatRunState(rawValue: raw) ?? .unknown
    }

    public var isWorking: Bool { self == .running || self == .waiting || self == .retry }
}

public struct ChatRetryInfo: Codable, Hashable, Sendable {
    public var attempt: Int
    public var nextAt: String?
    public var message: String

    public init(attempt: Int, nextAt: String? = nil, message: String = "") {
        self.attempt = attempt; self.nextAt = nextAt; self.message = message
    }

    enum CodingKeys: String, CodingKey { case attempt, nextAt, message }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        attempt = try container.decodeIfPresent(Int.self, forKey: .attempt) ?? 0
        nextAt = try container.decodeIfPresent(String.self, forKey: .nextAt)
        message = try container.decodeIfPresent(String.self, forKey: .message) ?? ""
    }
}

public struct ChatStatusInfo: Codable, Hashable, Sendable {
    public var state: ChatRunState
    public var retry: ChatRetryInfo?
    public init(state: ChatRunState, retry: ChatRetryInfo? = nil) { self.state = state; self.retry = retry }

    enum CodingKeys: String, CodingKey { case state, retry }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        state = try container.decodeIfPresent(ChatRunState.self, forKey: .state) ?? .unknown
        retry = try container.decodeIfPresent(ChatRetryInfo.self, forKey: .retry)
    }
}

/// Who named a chat (`titleSource`): its `default` title, its `provider`, the host's own naming (`auto`)
/// or a paired `device`. Values a later host adds are kept as they are.
public struct ChatTitleSource: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let `default` = ChatTitleSource(rawValue: "default")
    public static let provider = ChatTitleSource(rawValue: "provider")
    public static let auto = ChatTitleSource(rawValue: "auto")
    public static let device = ChatTitleSource(rawValue: "device")
}

/// A chat's identity and settings, as a snapshot and `chat.updated` carry them.
public struct ChatInfo: Codable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var provider: String
    public var model: String?
    public var mode: String?
    public var effort: String?
    /// Who named the chat, on hosts that say (`titleSource`).
    public var titleSource: ChatTitleSource?
    /// The ID of the newest message the title describes (`titleBasis`).
    public var titleBasis: String?
    /// The chat this one went on in (`continuedIn`: the handoff skill started its next session there), the newest when
    /// it went on more than once, and when (`continuedAt`, UTC RFC 3339); nil until it has.
    public var continuedIn: String?
    public var continuedAt: String?

    public init(id: String, title: String = "", provider: String = "opencode", model: String? = nil, mode: String? = nil,
                effort: String? = nil, titleSource: ChatTitleSource? = nil, titleBasis: String? = nil,
                continuedIn: String? = nil, continuedAt: String? = nil) {
        self.id = id; self.title = title; self.provider = provider; self.model = model; self.mode = mode; self.effort = effort
        self.titleSource = titleSource; self.titleBasis = titleBasis; self.continuedIn = continuedIn; self.continuedAt = continuedAt
    }

    /// When the chat went on in `continuedIn`, nil when the host did not say or said it in a form this version cannot read.
    public var continuedDate: Date? { continuedAt.flatMap(TerminalEnd.parseDate) }

    enum CodingKeys: String, CodingKey { case id, title, provider, model, mode, effort, titleSource, titleBasis, continuedIn, continuedAt }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        provider = try container.decodeIfPresent(String.self, forKey: .provider) ?? "opencode"
        model = try container.decodeIfPresent(String.self, forKey: .model)
        mode = try container.decodeIfPresent(String.self, forKey: .mode)
        effort = try container.decodeIfPresent(String.self, forKey: .effort)
        (titleSource, titleBasis) = ChatTitleSource.decodeNaming(from: container, source: .titleSource, basis: .titleBasis)
        (continuedIn, continuedAt) = Self.decodeContinuation(from: container, chat: .continuedIn, at: .continuedAt)
    }

    /// `continuedIn` and `continuedAt` where a container carries them: a chat ID as a terminal's is checked, and an
    /// unreadable value counts as none and never costs the rest.
    static func decodeContinuation<Key: CodingKey>(from container: KeyedDecodingContainer<Key>, chat: Key, at: Key) -> (String?, String?) {
        let next = (try? container.decodeIfPresent(String.self, forKey: chat)).flatMap { $0 }.flatMap(TerminalEnd.validTerminalID)
        let at = (try? container.decodeIfPresent(String.self, forKey: at)).flatMap { $0 }
        return next == nil ? (nil, nil) : (next, at?.isEmpty == false ? at : nil)
    }
}

extension ChatTitleSource {
    /// `titleSource` and `titleBasis` where a container carries them: an empty or unreadable value counts
    /// as none and never costs the rest.
    static func decodeNaming<Key: CodingKey>(from container: KeyedDecodingContainer<Key>, source: Key,
                                             basis: Key) -> (ChatTitleSource?, String?) {
        let sourceValue = (try? container.decodeIfPresent(String.self, forKey: source)).flatMap { $0 }
        let basisValue = (try? container.decodeIfPresent(String.self, forKey: basis)).flatMap { $0 }
        return (sourceValue.flatMap { $0.isEmpty ? nil : ChatTitleSource(rawValue: $0) }, basisValue.flatMap { $0.isEmpty ? nil : $0 })
    }
}

/// Everything a stream needs to replace its state: sent after `ready` when the
/// stream cannot resume, and again mid-stream after a rewind or restore.
public struct ChatSnapshot: Hashable, Sendable {
    public var chat: ChatInfo
    public var messages: [ConversationMessage]
    public var hasMore: Bool
    public var status: ChatStatusInfo
    public var interactions: [ChatInteraction]
    public var queue: [QueuedPrompt]
    public var rewind: RewindState?

    public init(chat: ChatInfo, messages: [ConversationMessage] = [], hasMore: Bool = false,
                status: ChatStatusInfo = ChatStatusInfo(state: .idle), interactions: [ChatInteraction] = [],
                queue: [QueuedPrompt] = [], rewind: RewindState? = nil) {
        self.chat = chat; self.messages = messages; self.hasMore = hasMore; self.status = status
        self.interactions = interactions; self.queue = queue; self.rewind = rewind
    }
}

public struct ChatInfoUpdate: Hashable, Sendable {
    public var title: String?
    public var model: String?
    public var mode: String?
    public var effort: String?
    public var titleSource: ChatTitleSource?
    public var titleBasis: String?
    /// The chat went on in another (`ChatInfo.continuedIn`), and when.
    public var continuedIn: String?
    public var continuedAt: String?
    public init(title: String? = nil, model: String? = nil, mode: String? = nil, effort: String? = nil,
                titleSource: ChatTitleSource? = nil, titleBasis: String? = nil, continuedIn: String? = nil, continuedAt: String? = nil) {
        self.title = title; self.model = model; self.mode = mode; self.effort = effort
        self.titleSource = titleSource; self.titleBasis = titleBasis; self.continuedIn = continuedIn; self.continuedAt = continuedAt
    }
}

public struct ConversationMessageUpdate: Hashable, Sendable {
    public var messageID: String
    public var status: ConversationMessageStatus?
    public var completedAt: String?
    public var usage: ConversationUsage?
    public var error: ConversationError?
    public init(messageID: String, status: ConversationMessageStatus? = nil, completedAt: String? = nil,
                usage: ConversationUsage? = nil, error: ConversationError? = nil) {
        self.messageID = messageID; self.status = status; self.completedAt = completedAt; self.usage = usage; self.error = error
    }
}

/// Text appended to a part's `text` or a tool's `output`. `offset` is the
/// field's length in UTF-8 bytes before this delta.
public struct ConversationPartDelta: Hashable, Sendable {
    public enum Field: String, Hashable, Sendable { case text, output }
    public var messageID: String
    public var partID: String
    public var field: Field
    public var offset: Int
    public var delta: String
    public init(messageID: String, partID: String, field: Field, offset: Int, delta: String) {
        self.messageID = messageID; self.partID = partID; self.field = field; self.offset = offset; self.delta = delta
    }
}

/// One line of `GET /v1/chat/events`.
public enum ChatEvent: Hashable, Sendable {
    case ready(cursor: String, resumed: Bool)
    case snapshot(ChatSnapshot)
    case chatUpdated(ChatInfoUpdate)
    case status(ChatStatusInfo)
    case messageCreated(ConversationMessage)
    case messageUpdated(ConversationMessageUpdate)
    case messageRemoved(messageID: String)
    case partCreated(messageID: String, part: ConversationPart)
    case partUpdated(messageID: String, part: ConversationPart)
    case partDelta(ConversationPartDelta)
    case partRemoved(messageID: String, partID: String)
    case interactionRequested(ChatInteraction)
    case interactionResolved(id: String, outcome: String)
    case queueUpdated([QueuedPrompt])
    case turnStarted(turnID: String)
    case turnFinished(turnID: String, outcome: String, usage: ConversationUsage?)
    case beat(cursor: String?)
    case end(cursor: String?)
    case stopping
    case unauthorized
    /// A line type this version does not know; ignored.
    case unknown(type: String)
}

public struct ChatEventEnvelope: Hashable, Sendable, Decodable {
    public var seq: UInt64
    public var event: ChatEvent

    public init(seq: UInt64, event: ChatEvent) { self.seq = seq; self.event = event }

    private enum Keys: String, CodingKey {
        case seq, type, cursor, resumed, chat, messages, hasMore, status, interactions, queue, rewind
        case title, model, mode, effort, state, retry, message, messageId, completedAt, usage, error
        case part, partId, field, offset, delta, interaction, id, outcome, items, turnId
        case titleSource, titleBasis, continuedIn, continuedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        seq = try container.decodeIfPresent(UInt64.self, forKey: .seq) ?? 0
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "ready":
            event = .ready(cursor: try container.decodeIfPresent(String.self, forKey: .cursor) ?? "",
                           resumed: try container.decodeIfPresent(Bool.self, forKey: .resumed) ?? false)
        case "snapshot":
            event = .snapshot(ChatSnapshot(
                chat: try container.decodeIfPresent(ChatInfo.self, forKey: .chat) ?? ChatInfo(id: ""),
                messages: try container.decodeIfPresent([ConversationMessage].self, forKey: .messages) ?? [],
                hasMore: try container.decodeIfPresent(Bool.self, forKey: .hasMore) ?? false,
                status: try container.decodeIfPresent(ChatStatusInfo.self, forKey: .status) ?? ChatStatusInfo(state: .unknown),
                interactions: try container.decodeIfPresent([ChatInteraction].self, forKey: .interactions) ?? [],
                queue: try container.decodeIfPresent([QueuedPrompt].self, forKey: .queue) ?? [],
                rewind: try container.decodeIfPresent(RewindState.self, forKey: .rewind)))
        case "chat.updated":
            let (titleSource, titleBasis) = ChatTitleSource.decodeNaming(from: container, source: .titleSource, basis: .titleBasis)
            let (continuedIn, continuedAt) = ChatInfo.decodeContinuation(from: container, chat: .continuedIn, at: .continuedAt)
            event = .chatUpdated(ChatInfoUpdate(title: try container.decodeIfPresent(String.self, forKey: .title),
                                                model: try container.decodeIfPresent(String.self, forKey: .model),
                                                mode: try container.decodeIfPresent(String.self, forKey: .mode),
                                                effort: try container.decodeIfPresent(String.self, forKey: .effort),
                                                titleSource: titleSource, titleBasis: titleBasis,
                                                continuedIn: continuedIn, continuedAt: continuedAt))
        case "status":
            event = .status(ChatStatusInfo(state: try container.decodeIfPresent(ChatRunState.self, forKey: .state) ?? .unknown,
                                           retry: try container.decodeIfPresent(ChatRetryInfo.self, forKey: .retry)))
        case "message.created":
            event = .messageCreated(try container.decode(ConversationMessage.self, forKey: .message))
        case "message.updated":
            event = .messageUpdated(ConversationMessageUpdate(
                messageID: try container.decode(String.self, forKey: .messageId),
                status: try container.decodeIfPresent(ConversationMessageStatus.self, forKey: .status),
                completedAt: try container.decodeIfPresent(String.self, forKey: .completedAt),
                usage: try container.decodeIfPresent(ConversationUsage.self, forKey: .usage),
                error: try container.decodeIfPresent(ConversationError.self, forKey: .error)))
        case "message.removed":
            event = .messageRemoved(messageID: try container.decode(String.self, forKey: .messageId))
        case "part.created", "part.updated":
            let messageID = try container.decode(String.self, forKey: .messageId)
            let part = try container.decode(ConversationPart.self, forKey: .part)
            event = type == "part.created" ? .partCreated(messageID: messageID, part: part) : .partUpdated(messageID: messageID, part: part)
        case "part.delta":
            let raw = try container.decodeIfPresent(String.self, forKey: .field) ?? "text"
            guard let field = ConversationPartDelta.Field(rawValue: raw) else {
                event = .unknown(type: "part.delta." + raw)
                return
            }
            event = .partDelta(ConversationPartDelta(messageID: try container.decode(String.self, forKey: .messageId),
                                                     partID: try container.decode(String.self, forKey: .partId),
                                                     field: field,
                                                     offset: try container.decode(Int.self, forKey: .offset),
                                                     delta: try container.decodeIfPresent(String.self, forKey: .delta) ?? ""))
        case "part.removed":
            event = .partRemoved(messageID: try container.decode(String.self, forKey: .messageId),
                                 partID: try container.decode(String.self, forKey: .partId))
        case "interaction.requested":
            event = .interactionRequested(try container.decode(ChatInteraction.self, forKey: .interaction))
        case "interaction.resolved":
            event = .interactionResolved(id: try container.decode(String.self, forKey: .id),
                                         outcome: try container.decodeIfPresent(String.self, forKey: .outcome) ?? "gone")
        case "queue.updated":
            event = .queueUpdated(try container.decodeIfPresent([QueuedPrompt].self, forKey: .items) ?? [])
        case "turn.started":
            event = .turnStarted(turnID: try container.decodeIfPresent(String.self, forKey: .turnId) ?? "")
        case "turn.finished":
            event = .turnFinished(turnID: try container.decodeIfPresent(String.self, forKey: .turnId) ?? "",
                                  outcome: try container.decodeIfPresent(String.self, forKey: .outcome) ?? "completed",
                                  usage: try container.decodeIfPresent(ConversationUsage.self, forKey: .usage))
        case "beat":
            event = .beat(cursor: try container.decodeIfPresent(String.self, forKey: .cursor))
        case "end":
            event = .end(cursor: try container.decodeIfPresent(String.self, forKey: .cursor))
        case "stopping":
            event = .stopping
        case "unauthorized":
            event = .unauthorized
        default:
            event = .unknown(type: type)
        }
    }

    /// Decodes one NDJSON line. Throws for lines that are not a JSON object
    /// with a `type`, or whose known type is missing required fields.
    public static func decode(line: String) throws -> ChatEventEnvelope {
        try JSONDecoder().decode(ChatEventEnvelope.self, from: Data(line.utf8))
    }
}

/// A cursor is opaque to the client except for telling epochs apart: the
/// stream starts over (a new snapshot) whenever the epoch changes.
public struct ChatCursor: Hashable, Sendable {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
    public var epoch: String { raw.split(separator: ".", maxSplits: 1).first.map(String.init) ?? raw }
}

// MARK: Paged history

public struct ConversationPage: Decodable, Hashable, Sendable {
    /// Newest first, as the host pages them.
    public var messages: [ConversationMessage]
    public var hasMore: Bool
    public var oldestID: String

    public init(messages: [ConversationMessage], hasMore: Bool, oldestID: String) {
        self.messages = messages; self.hasMore = hasMore; self.oldestID = oldestID
    }

    enum CodingKeys: String, CodingKey { case messages, hasMore, oldestID = "oldestId" }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        messages = try container.decodeIfPresent([ConversationMessage].self, forKey: .messages) ?? []
        hasMore = try container.decodeIfPresent(Bool.self, forKey: .hasMore) ?? false
        oldestID = try container.decodeIfPresent(String.self, forKey: .oldestID) ?? ""
    }
}

// MARK: Requests and outcomes

/// `POST /v1/messages`. New fields go out only when the caller set them, and a
/// caller sets them only when the host advertises the matching capability.
public struct ChatSendRequest: Hashable, Sendable {
    public var projectID: String
    public var sessionID: String
    public var text: String
    public var model: String?
    public var agent: String?
    public var attachments: [String]
    public var clientMessageID: String?
    public var mode: String?
    public var effort: String?

    public init(projectID: String, sessionID: String, text: String, model: String? = nil, agent: String? = nil,
                attachments: [String] = [], clientMessageID: String? = nil, mode: String? = nil, effort: String? = nil) {
        self.projectID = projectID; self.sessionID = sessionID; self.text = text; self.model = model; self.agent = agent
        self.attachments = attachments; self.clientMessageID = clientMessageID; self.mode = mode; self.effort = effort
    }
}

public struct ChatSendReceipt: Decodable, Hashable, Sendable {
    public var accepted: Bool
    public var messageID: String?
    public var turnID: String?
    public var duplicate: Bool

    public init(accepted: Bool = true, messageID: String? = nil, turnID: String? = nil, duplicate: Bool = false) {
        self.accepted = accepted; self.messageID = messageID; self.turnID = turnID; self.duplicate = duplicate
    }

    enum CodingKeys: String, CodingKey { case accepted, messageID = "messageId", turnID = "turnId", duplicate }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accepted = try container.decodeIfPresent(Bool.self, forKey: .accepted) ?? false
        messageID = try container.decodeIfPresent(String.self, forKey: .messageID)
        turnID = try container.decodeIfPresent(String.self, forKey: .turnID)
        duplicate = try container.decodeIfPresent(Bool.self, forKey: .duplicate) ?? false
    }
}

public enum ChatSendOutcome: Equatable, Sendable {
    case accepted(ChatSendReceipt)
    /// The request may have reached the host. Never retried automatically.
    case uncertain
    case failed(ClientError)
}

/// A chat the host created (fork, continue).
public enum ChatCreateOutcome: Equatable, Sendable {
    case created(Session)
    case uncertain
    case failed(ClientError)
}

/// Whether a rewind or restore also changes the project's files.
public enum ChatFilesRestore: String, Hashable, Sendable {
    case immediate, onSend, unavailable
}

public enum ChatRewindOutcome: Equatable, Sendable {
    case accepted(ChatFilesRestore?)
    case uncertain
    case failed(ClientError)
}

public struct ChatContinueRequest: Hashable, Sendable {
    /// The seed sizes the host accepts, in characters (its default is 48 000).
    public static let contextCharsRange = 1_000...200_000
    public static let defaultContextChars = 48_000

    public var projectID: String
    public var sourceSessionID: String
    public var provider: String
    public var model: String?
    public var mode: String?
    public var effort: String?
    public var title: String?
    /// The source message the seed ends with (`throughMessageId`); later ones are
    /// left out. Set it only for hosts that list `continueThrough`.
    public var throughMessageID: String?
    /// How many characters of the source the seed may carry
    /// (`contextChars`, 1 000–200 000; the host's default is 48 000).
    public var contextChars: Int?

    public init(projectID: String, sourceSessionID: String, provider: String, model: String? = nil, mode: String? = nil,
                effort: String? = nil, title: String? = nil, throughMessageID: String? = nil, contextChars: Int? = nil) {
        self.projectID = projectID; self.sourceSessionID = sourceSessionID; self.provider = provider
        self.model = model; self.mode = mode; self.effort = effort; self.title = title
        self.throughMessageID = throughMessageID
        self.contextChars = contextChars
    }
}

// MARK: Legacy transcripts

public extension ConversationMessage {
    /// The unified form of a message from `GET /v1/messages`, for hosts that do
    /// not stream. Parts follow the legacy order: reasoning, tools, text, files.
    init(legacy message: ChatMessage, chatID: String, turnID: String, ord: Int64, provider: String, streaming: Bool) {
        // `?parts=1` carries the host's own order, text and tools interleaved.
        let parts = message.parts ?? ConversationMessage.legacyParts(message)
        var status: ConversationMessageStatus = .complete
        var error: ConversationError?
        if let failure = message.error, !failure.isEmpty {
            status = .error
            error = ConversationError(code: "agent_error", message: failure)
        } else if streaming {
            status = .streaming
        }
        self.init(id: message.id, chatID: chatID, turnID: message.role == .user ? message.id : turnID, role: message.role,
                  status: status, ord: ord, createdAt: message.createdAt ?? "", provider: provider, model: message.model,
                  usage: message.usage, error: error, parts: parts)
    }

    private static func legacyParts(_ message: ChatMessage) -> [ConversationPart] {
        var parts: [ConversationPart] = []
        func next(_ kind: ConversationPartKind) -> ConversationPart {
            ConversationPart(id: "\(message.id):\(parts.count)", kind: kind, ord: Int64(parts.count + 1))
        }
        for reasoning in message.reasoning {
            var part = next(.reasoning)
            part.text = reasoning.text
            part.durationMs = reasoning.durationMs > 0 ? reasoning.durationMs : nil
            parts.append(part)
        }
        for tool in message.tools {
            var part = next(.tool)
            if !tool.id.isEmpty { part.id = tool.id }
            part.tool = ConversationTool(name: tool.name, callID: tool.callID, status: tool.status, title: tool.title,
                                         input: tool.input, output: tool.output, error: tool.error, truncated: tool.truncated)
            parts.append(part)
        }
        if !message.text.isEmpty {
            var part = next(.text)
            part.text = message.text
            parts.append(part)
        }
        for attachment in message.attachments {
            var part = next(.attachment)
            part.attachment = attachment
            parts.append(part)
        }
        return parts
    }
}

public extension ChatInteraction {
    init(legacy permission: PermissionRequest) {
        self.init(id: permission.id, chatID: permission.sessionID, kind: .permission, choices: ["once", "reject"],
                  permission: ChatPermission(tool: permission.permission, title: permission.patterns.joined(separator: ", "),
                                             detail: "", input: permission.details))
    }

    init(legacy question: QuestionRequest) {
        self.init(id: question.id, chatID: question.sessionID, kind: .question,
                  questions: question.questions.enumerated().map { index, item in
                      ChatQuestion(id: String(index), text: item.question, header: item.header,
                                   options: item.options.map { ChatQuestionOption(label: $0.label, description: $0.description) },
                                   multiple: item.multiple, custom: item.custom, secret: item.secret)
                  })
    }
}

/// RFC 3339 times from the host, with or without fractional seconds.
public enum ChatTime {
    public static func date(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        if let date = try? Date(value, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return date }
        return try? Date(value, strategy: .iso8601)
    }
}
