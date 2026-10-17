import Foundation

// Plain chats (docs/HOST-API.md "Plain chats"): AI chats outside every workspace, in the host's Chats space,
// which OpenCode runs with AgentLand's `chat` agent. Hosts list what they offer in `capabilities.plainChats`;
// the apps offer plain chats, and call the memory routes (MemoryWire.swift), only while it is listed. A tool
// part of any OpenCode chat may name the web pages its tool used (`sources`), and a memory save the entry it
// stored (`memory`).

// MARK: Capabilities

/// A tool plain chats can use now (`capabilities.plainChats.tools`).
public enum PlainChatTool: Hashable, Sendable {
    /// OpenCode's web search; the queries go to `PlainChatsCapability.searchProvider`.
    case websearch
    /// `agentland_fetch`: reads one public web page.
    case fetch
    /// `agentland_memory_save` and `agentland_memory_forget`, and the memory routes (`APIClient.memory()`).
    case memory
    /// A tool this version does not know, as the host named it.
    case other(String)

    public init(rawValue: String) {
        switch rawValue {
        case "websearch": self = .websearch
        case "fetch": self = .fetch
        case "memory": self = .memory
        default: self = .other(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .websearch: "websearch"
        case .fetch: "fetch"
        case .memory: "memory"
        case let .other(raw): raw
        }
    }
}

/// The service that receives plain chats' web searches (`capabilities.plainChats.searchProvider`).
public enum PlainChatSearchProvider: Hashable, Sendable {
    /// Exa's hosted search, which OpenCode uses without a key.
    case exa
    /// A service this version does not know, as the host named it.
    case other(String)

    public init(rawValue: String) { self = rawValue == "exa" ? .exa : .other(rawValue) }

    public var rawValue: String {
        switch self {
        case .exa: "exa"
        case let .other(raw): raw
        }
    }
}

/// How a provider is signed in for Chat (`auth`, 2026-10-12). Chat runs only on the subscriptions the Mac is signed
/// into (Claude Code's Claude subscription, Codex's ChatGPT subscription), never on API keys: the host lists a provider
/// signed in otherwise among `PlainChatsCapability.unavailableProviders`, with `reason` and `message`.
public struct PlainChatAuth: Codable, Hashable, Sendable {
    /// The longest `label` and `message` read, in bytes.
    public static let maximumLabelBytes = 128
    public static let maximumMessageBytes = 1_024
    /// The `kind` of a sign-in Chat runs on.
    public static let subscription = "subscription"
    /// The `reason` of a Claude Code or Codex installed in a version Chat does not support: signing in again does not help.
    public static let versionUnsupported = "version_unsupported"

    /// `subscription`, `apiKey`, `other`, `signedOut` or `unknown`; kinds this version does not know are kept.
    public let kind: String
    /// The sign-in's name, one line: "Claude subscription", "ChatGPT subscription", "API key", "Not signed in".
    public let label: String
    /// Why Chat cannot use it (`subscription_required`, or `version_unsupported` for a version Chat does not support;
    /// other reasons are kept); nil for a sign-in it uses.
    public let reason: String?
    /// What to do, in the host's words ("Sign in to Claude Code with your Claude subscription (claude auth login).").
    public let message: String?

    public init(kind: String, label: String, reason: String? = nil, message: String? = nil) {
        self.kind = kind; self.label = label; self.reason = reason; self.message = message
    }

    /// Chat runs on this sign-in.
    public var isSubscription: Bool { kind == Self.subscription }

    enum CodingKeys: String, CodingKey { case kind, label, reason, message }

    /// `kind` and `label` are required, `label` one line; a `reason` or `message` this version cannot read counts as
    /// absent.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(String.self, forKey: .kind)
        let label = PlainChatText.line(try container.decode(String.self, forKey: .label))
        guard (1...64).contains(kind.utf8.count), (1...Self.maximumLabelBytes).contains(label.utf8.count) else {
            throw DecodingError.dataCorruptedError(forKey: .label, in: container, debugDescription: "Not a sign-in")
        }
        self.label = label
        reason = (try? container.decodeIfPresent(String.self, forKey: .reason)).flatMap { $0 }.flatMap { (1...64).contains($0.utf8.count) ? $0 : nil }
        message = (try? container.decodeIfPresent(String.self, forKey: .message)).flatMap { $0 }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { (1...Self.maximumMessageBytes).contains($0.utf8.count) ? $0 : nil }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(label, forKey: .label)
        try container.encodeIfPresent(reason, forKey: .reason)
        try container.encodeIfPresent(message, forKey: .message)
    }
}

/// A runtime whose installed sign-in the host can use for general conversation.
public struct PlainChatProvider: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let tools: [String]
    public let features: [String]
    public let attachmentTypes: [String]?
    /// Files this provider's runtime gives its chats besides AgentLand's instructions, read and limited as
    /// `PlainChatsCapability.instructionFiles` (Codex's global `AGENTS.md`); empty when there are none.
    public let instructionFiles: [String]
    /// How it is signed in for Chat; nil from hosts before 2026-10-12, or when this version cannot read it.
    public let auth: PlainChatAuth?

    public init(id: String, name: String, tools: [String] = [], features: [String] = [], attachmentTypes: [String]? = nil,
                instructionFiles: [String] = [], auth: PlainChatAuth? = nil) {
        self.id = id; self.name = name; self.tools = tools; self.features = features
        self.attachmentTypes = attachmentTypes; self.instructionFiles = instructionFiles; self.auth = auth
    }

    enum CodingKeys: String, CodingKey { case id, name, tools, features, attachmentTypes, instructionFiles, auth }

    /// `instructionFiles` or `auth` this version cannot read counts as absent rather than dropping the provider.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        tools = try container.decode([String].self, forKey: .tools)
        features = try container.decode([String].self, forKey: .features)
        attachmentTypes = try container.decodeIfPresent([String].self, forKey: .attachmentTypes)
        instructionFiles = PlainChatsCapability.instructionFiles(in: container, forKey: .instructionFiles)
        auth = (try? container.decodeIfPresent(PlainChatAuth.self, forKey: .auth)) ?? nil
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(tools, forKey: .tools)
        try container.encode(features, forKey: .features)
        try container.encodeIfPresent(attachmentTypes, forKey: .attachmentTypes)
        if !instructionFiles.isEmpty { try container.encode(instructionFiles, forKey: .instructionFiles) }
        try container.encodeIfPresent(auth, forKey: .auth)
    }
}

/// `capabilities.plainChats`: the host's Chats space and what its plain chats can use now. Hosts list it only
/// while their OpenCode has AgentLand's `chat` agent; without it they offer no plain chats.
public struct PlainChatsCapability: Codable, Hashable, Sendable {
    /// The Chats space's reserved ID. Archived plain chats carry it whether or not the host lists the capability
    /// at the moment.
    public static let chatsProjectID = "chats"
    /// The longest `projectId` read, in bytes.
    public static let maximumProjectIDBytes = 256
    /// At most this many tools are kept, each at most `maximumToolBytes` bytes.
    public static let maximumTools = 32
    public static let maximumToolBytes = 64
    /// The host's limits for `instructionFiles`: 32 paths of at most 1,024 bytes each.
    public static let maximumInstructionFiles = 32
    public static let maximumInstructionFileBytes = 1_024

    /// The Chats space's ID (`chats`): the `projectId` of every plain chat, on the chat routes and in the archive.
    public let projectID: String
    /// What plain chats can use now, in the host's order; tools this version does not know are kept as `.other`.
    public let tools: [PlainChatTool]
    /// Who receives the search queries; hosts send it with `websearch`.
    public let searchProvider: PlainChatSearchProvider?
    /// The instruction files OpenCode adds to every plain chat besides the `chat` agent's prompt (`~/…` under the
    /// Mac user's home folder), one line each; empty when there are none.
    public let instructionFiles: [String]
    public let providers: [PlainChatProvider]?
    /// Installed providers whose sign-in Chat does not use (2026-10-12: not a subscription), each with its `auth`'s
    /// reason and message. Settings shows them; nothing offers them. Empty from older hosts.
    public let unavailableProviders: [PlainChatProvider]

    public var availableProviders: [PlainChatProvider] {
        providers ?? [PlainChatProvider(id: "opencode", name: "OpenCode", tools: tools.map(\.rawValue),
            features: ["events", "parts", "stop", "clientMessageId", "title", "attachments", "queue", "rewind", "regenerate"])]
    }

    public init(projectID: String = PlainChatsCapability.chatsProjectID, tools: [PlainChatTool] = [],
                searchProvider: PlainChatSearchProvider? = nil, instructionFiles: [String] = [], providers: [PlainChatProvider]? = nil,
                unavailableProviders: [PlainChatProvider] = []) {
        self.projectID = projectID; self.tools = tools; self.searchProvider = searchProvider
        self.instructionFiles = instructionFiles
        self.providers = providers
        self.unavailableProviders = unavailableProviders
    }

    /// Plain chats can use `tool` now.
    public func offers(_ tool: PlainChatTool) -> Bool {
        tools.contains(tool) || providers?.contains(where: { $0.tools.contains(tool.rawValue) }) == true
    }

    /// The Chats space of a host that lists plain chats as `capability` (nil while it lists none), where
    /// `isWorkspace` says which IDs are its workspaces: the space its plain chats name. While it lists none (its
    /// `chat` agent not confirmed yet, or its capabilities not read) it is still `chats`, which archived plain chats
    /// keep, unless one of the host's workspaces has that ID: an older host's workspace stays a workspace, and that
    /// host has no Chats space (nil). Hosts with plain chats never list `chats` among their workspaces.
    public static func chatsSpace(capability: PlainChatsCapability?, isWorkspace: (String) -> Bool) -> String? {
        if let capability { return capability.projectID }
        return isWorkspace(chatsProjectID) ? nil : chatsProjectID
    }

    /// 503 on a new chat, a send, Run Again or a continue in the Chats space while the host has not confirmed its
    /// `chat` agent: nothing was sent, and the client reads capabilities again.
    public static let agentUnavailableCode = "agent_unavailable"

    enum CodingKeys: String, CodingKey { case projectID = "projectId", tools, searchProvider, instructionFiles, providers, unavailableProviders }

    /// Only `projectId` is required: without it the entry offers nothing. A member this version cannot read counts
    /// as absent, and a list entry it cannot read is left out.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let projectID = try container.decode(String.self, forKey: .projectID)
        guard (1...Self.maximumProjectIDBytes).contains(projectID.utf8.count) else {
            throw DecodingError.dataCorruptedError(forKey: .projectID, in: container, debugDescription: "Not a project ID")
        }
        self.projectID = projectID
        let providers = container.contains(.providers) ? Self.providers(in: container, forKey: .providers) : nil
        self.providers = providers
        // A provider Chat can use is never also unavailable.
        unavailableProviders = Self.providers(in: container, forKey: .unavailableProviders).filter { entry in
            !(providers ?? []).contains { $0.id == entry.id }
        }

        tools = Self.strings(in: container, forKey: .tools, limit: Self.maximumTools) { raw in
            (1...Self.maximumToolBytes).contains(raw.utf8.count) ? raw : nil
        }.map(PlainChatTool.init(rawValue:))
        searchProvider = (try? container.decodeIfPresent(String.self, forKey: .searchProvider)).flatMap { $0 }
            .flatMap { (1...Self.maximumToolBytes).contains($0.utf8.count) ? PlainChatSearchProvider(rawValue: $0) : nil }
        instructionFiles = Self.instructionFiles(in: container, forKey: .instructionFiles)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(projectID, forKey: .projectID)
        try container.encodeIfPresent(providers, forKey: .providers)
        if !unavailableProviders.isEmpty { try container.encode(unavailableProviders, forKey: .unavailableProviders) }
        try container.encode(tools.map(\.rawValue), forKey: .tools)
        try container.encodeIfPresent(searchProvider?.rawValue, forKey: .searchProvider)
        if !instructionFiles.isEmpty { try container.encode(instructionFiles, forKey: .instructionFiles) }
    }

    /// The provider entries at `key`, each read on its own: one this version cannot read is left out, never the whole
    /// list. Known providers only (`known`), each once, within the host's limits; no list reads as empty.
    static func providers<Key: CodingKey>(in container: KeyedDecodingContainer<Key>, forKey key: Key,
                                          known: Set<String> = ["opencode", "claude", "codex"]) -> [PlainChatProvider] {
        var values: [PlainChatProvider] = []
        if var list = try? container.nestedUnkeyedContainer(forKey: key) {
            while !list.isAtEnd && values.count < 16 {
                if let value = try? list.decode(PlainChatProvider.self) {
                    values.append(value)
                } else if (try? list.decode(Discarded.self)) == nil {
                    break
                }
            }
        }
        var seen = Set<String>()
        return values.filter {
            known.contains($0.id) && !$0.name.isEmpty && $0.name.utf8.count <= 128 &&
            $0.tools.count <= 32 && $0.features.count <= 32 && ($0.attachmentTypes?.count ?? 0) <= 16 &&
            ($0.attachmentTypes?.allSatisfy { $0.utf8.count <= 128 } ?? true) && seen.insert($0.id).inserted
        }
    }

    /// The entry, or nil when the key is absent or holds nothing this version can read.
    static func decodeSupported<Key: CodingKey>(from container: KeyedDecodingContainer<Key>, forKey key: Key) -> PlainChatsCapability? {
        (try? container.decodeIfPresent(PlainChatsCapability.self, forKey: key)) ?? nil
    }

    /// The instruction file paths at `key`: one line each, at most `maximumInstructionFiles` of at most
    /// `maximumInstructionFileBytes` bytes, each once.
    static func instructionFiles<Key: CodingKey>(in container: KeyedDecodingContainer<Key>, forKey key: Key) -> [String] {
        strings(in: container, forKey: key, limit: maximumInstructionFiles) { raw in
            let path = PlainChatText.line(raw)
            return !path.isEmpty && path.utf8.count <= maximumInstructionFileBytes ? path : nil
        }
    }

    /// The strings of the list at `key` that `keep` keeps (as it returns them), each once and at most `limit`;
    /// entries that are not strings are stepped over. No list reads as empty.
    private static func strings<Key: CodingKey>(in container: KeyedDecodingContainer<Key>, forKey key: Key, limit: Int,
                                                keep: (String) -> String?) -> [String] {
        guard container.contains(key), var list = try? container.nestedUnkeyedContainer(forKey: key) else { return [] }
        var values: [String] = []
        while !list.isAtEnd && values.count < limit {
            if let raw = try? list.decode(String.self) {
                if let value = keep(raw), !values.contains(value) { values.append(value) }
            } else if (try? list.decode(Discarded.self)) == nil {
                break
            }
        }
        return values
    }
}

/// `capabilities.workspaceChats` (owner, 2026-10-12: Chat is Claude Code and Codex in the selected workspace): the
/// providers whose chats run in the host's workspaces now, each signed in with a subscription, and the installed ones
/// signed in otherwise, with their `auth`'s reason and message. It follows the Mac's sign-ins, not OpenCode. Only
/// version 1 is read; another version, or an entry this version cannot read, offers no workspace chats.
public struct WorkspaceChatsCapability: Codable, Hashable, Sendable {
    public static let supportedVersion = 1
    /// The providers whose workspace chats this version shows: OpenCode's and ACP agents' stay out of Chat.
    static let knownProviders: Set<String> = ["claude", "codex"]

    public let version: Int
    /// Signed in with a subscription: Chat offers these, in the host's order, with their chat features.
    public let providers: [PlainChatProvider]
    /// Installed but signed in otherwise; Settings shows them with what to do, nothing offers them.
    public let unavailableProviders: [PlainChatProvider]

    public init(providers: [PlainChatProvider] = [], unavailableProviders: [PlainChatProvider] = []) {
        version = Self.supportedVersion; self.providers = providers; self.unavailableProviders = unavailableProviders
    }

    /// The entry Chat can use for `id`, if any.
    public func provider(_ id: String) -> PlainChatProvider? { providers.first { $0.id == id } }

    /// Chat can start `provider`'s chats in a workspace now.
    public func offers(_ provider: AgentProvider) -> Bool { self.provider(provider.id) != nil }

    enum CodingKeys: String, CodingKey { case version, providers, unavailableProviders }

    /// `version` is required; the lists are read entry by entry as `generalChats`' are, and absent ones read as empty.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        let providers = PlainChatsCapability.providers(in: container, forKey: .providers, known: Self.knownProviders)
        self.providers = providers
        unavailableProviders = PlainChatsCapability.providers(in: container, forKey: .unavailableProviders, known: Self.knownProviders)
            .filter { entry in !providers.contains { $0.id == entry.id } }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(providers, forKey: .providers)
        try container.encode(unavailableProviders, forKey: .unavailableProviders)
    }

    /// The entry when it is of the supported version; nil when absent, of another version or unreadable.
    static func decodeSupported<Key: CodingKey>(from container: KeyedDecodingContainer<Key>, forKey key: Key) -> WorkspaceChatsCapability? {
        guard let entry = (try? container.decodeIfPresent(WorkspaceChatsCapability.self, forKey: key)) ?? nil,
              entry.version == supportedVersion else { return nil }
        return entry
    }
}

extension APIClient {
    /// Asks this Mac's host to check Claude Code's and Codex's sign-ins now (`POST /v1/chat/providers/check`, this
    /// Mac's session alone; owner, 2026-10-17, Sign In… in the Mac's setup and Settings → Agents): 204 once checked,
    /// and `capabilities.workspaceChats` then lists what the CLIs answered. False for a host without the check (404,
    /// an older host or one without Claude Code and Codex chats), whose capabilities keep its minute-paced check.
    /// The check may take up to the host's 15 s bound.
    public func checkChatSignIns() async throws -> Bool {
        try Task.checkCancellation()
        var request = try makeRequest(path: "/v1/chat/providers/check", method: "POST")
        request.timeoutInterval = 30
        let (data, response) = try await transport.execute(request)
        if response.statusCode == 404 { return false }
        try validate(response, data: data, expected: 204)
        return true
    }
}

public extension ClientError {
    /// The host has not confirmed its `chat` agent (503 `agent_unavailable`): plain chats take nothing now.
    var isPlainChatAgentUnavailable: Bool {
        if case let .server(code, _) = self { return code == PlainChatsCapability.agentUnavailableCode }
        return false
    }
}

// MARK: Tool parts

/// One web page a tool part names (`sources`): a result of a web search, or the page `agentland_fetch` read.
public struct ChatToolSource: Codable, Hashable, Sendable {
    /// The host's limits: 20 sources per tool part, titles of 200 bytes and addresses of 2,048 bytes.
    public static let maximumSources = 20
    public static let maximumTitleBytes = 200
    public static let maximumURLBytes = 2_048

    /// One line to show: the page's title, or the address's host name when the page gave none.
    public let title: String
    /// An `http` or `https` address without credentials.
    public let url: URL

    /// Nil unless `url` is such an address of at most 2,048 bytes. The title is cleaned as the host cleans it and
    /// cut to 200 bytes at a character boundary.
    public init?(title: String?, url: String) {
        guard let address = Self.webAddress(url) else { return nil }
        self.url = address
        let line = PlainChatText.prefix(PlainChatText.line(title ?? ""), maximumBytes: Self.maximumTitleBytes)
        self.title = line.isEmpty ? (address.host(percentEncoded: false).flatMap { $0.isEmpty ? nil : $0 } ?? url) : line
    }

    enum CodingKeys: String, CodingKey { case title, url }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let url = try container.decode(String.self, forKey: .url)
        let title = (try? container.decodeIfPresent(String.self, forKey: .title)).flatMap { $0 }
        guard let source = ChatToolSource(title: title, url: url) else {
            throw DecodingError.dataCorruptedError(forKey: .url, in: container, debugDescription: "Not an http or https address")
        }
        self = source
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(title, forKey: .title)
        try container.encode(url.absoluteString, forKey: .url)
    }

    /// An `http` or `https` address with a host and without user information, of at most 2,048 bytes.
    static func webAddress(_ raw: String) -> URL? {
        guard (1...maximumURLBytes).contains(raw.utf8.count), let components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              components.host?.isEmpty == false, components.user == nil, components.password == nil else { return nil }
        return URL(string: raw)
    }

    /// The sources at `key`: those this version can read, in the host's order, each address once, at most 20. No
    /// list reads as none.
    static func decodeList<Key: CodingKey>(from container: KeyedDecodingContainer<Key>, forKey key: Key) -> [ChatToolSource] {
        guard container.contains(key), var list = try? container.nestedUnkeyedContainer(forKey: key) else { return [] }
        var sources: [ChatToolSource] = []
        while !list.isAtEnd && sources.count < maximumSources {
            if let source = try? list.decode(ChatToolSource.self) {
                if !sources.contains(where: { $0.url == source.url }) { sources.append(source) }
            } else if (try? list.decode(Discarded.self)) == nil {
                break
            }
        }
        return sources
    }
}

/// The memory entry an `agentland_memory_save` tool part stored (`memory`), as the host keeps it. The apps show
/// "Memory updated" with its text, and Undo removes it with `APIClient.deleteMemory(id:)`.
public struct ChatToolMemory: Codable, Hashable, Sendable {
    /// The entry's ID, as `GET /v1/memory` lists it.
    public let id: String
    /// One line, as the host keeps it.
    public let text: String

    /// Nil unless `id` is 1–64 bytes and there is text to show.
    public init?(id: String, text: String) {
        let shown = PlainChatText.memoryText(text)
        guard PlainChatText.isMemoryID(id), !shown.isEmpty else { return nil }
        self.id = id
        self.text = shown
    }

    enum CodingKeys: String, CodingKey { case id, text }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let memory = ChatToolMemory(id: try container.decode(String.self, forKey: .id),
                                          text: try container.decode(String.self, forKey: .text)) else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: container, debugDescription: "Not a memory entry")
        }
        self = memory
    }

    /// The entry at `key`, or nil when there is none this version can read.
    static func decodeIfPresent<Key: CodingKey>(from container: KeyedDecodingContainer<Key>, forKey key: Key) -> ChatToolMemory? {
        (try? container.decodeIfPresent(ChatToolMemory.self, forKey: key)) ?? nil
    }
}

// MARK: Text

/// Text plain chats show from the host, cleaned as the host cleans memory text and source titles
/// (docs/HOST-API.md "Plain chats"), and the host's rules for memory entries.
enum PlainChatText {
    /// Memory IDs are 1–64 bytes.
    static let maximumMemoryIDBytes = 64
    /// Memory holds at most 2,000 characters of text over all entries.
    static let maximumMemoryCharacters = 2_000

    static func isMemoryID(_ id: String) -> Bool { (1...maximumMemoryIDBytes).contains(id.utf8.count) }

    /// Memory text as the apps show it: one line, at most `maximumMemoryCharacters` characters.
    static func memoryText(_ raw: String) -> String { String(line(raw).prefix(maximumMemoryCharacters)) }

    /// One line of what can be seen, as the host cleans it: each run of white space (Unicode White_Space, line
    /// breaks included) one space; of the rest only letters, marks, numbers, punctuation and symbols kept that
    /// are not default-ignorable, so control, format (bidirectional controls and tag characters among them),
    /// private-use, surrogate and unassigned code points, the other Default_Ignorable_Code_Point characters
    /// (variation selectors, the combining grapheme joiner, the Hangul fillers) and the blank Braille pattern
    /// are dropped; the ends trimmed.
    static func line(_ raw: String) -> String {
        var out = String.UnicodeScalarView()
        var gap = false
        for scalar in raw.unicodeScalars {
            if scalar.properties.isWhitespace {
                gap = true
                continue
            }
            guard isShown(scalar) else { continue }
            if gap, !out.isEmpty { out.append(" ") }
            gap = false
            out.append(scalar)
        }
        return String(out)
    }

    /// U+2800 BRAILLE PATTERN BLANK, a symbol that shows nothing.
    static let brailleBlank: UInt32 = 0x2800

    /// Letters, marks, numbers, punctuation and symbols, except the default-ignorable ones and the blank Braille
    /// pattern.
    static func isShown(_ scalar: Unicode.Scalar) -> Bool {
        let properties = scalar.properties
        guard !properties.isDefaultIgnorableCodePoint, !properties.isVariationSelector, scalar.value != brailleBlank else {
            return false
        }
        switch properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .nonspacingMark, .spacingMark, .enclosingMark,
             .decimalNumber, .letterNumber, .otherNumber,
             .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation, .initialPunctuation,
             .finalPunctuation, .otherPunctuation,
             .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol:
            return true
        default:
            return false
        }
    }

    /// `text` whole when it fits in `maximumBytes` of UTF-8; otherwise its longest start that fits and ends at a
    /// character boundary, without trailing white space.
    static func prefix(_ text: String, maximumBytes: Int) -> String {
        guard text.utf8.count > maximumBytes else { return text }
        var bytes = 0
        var end = text.startIndex
        for index in text.indices {
            bytes += text[index].utf8.count
            guard bytes <= maximumBytes else { break }
            end = text.index(after: index)
        }
        return String(text[..<end]).trimmingCharacters(in: .whitespaces)
    }
}
