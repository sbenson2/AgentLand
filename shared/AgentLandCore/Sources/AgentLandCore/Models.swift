import Foundation

public enum ConnectionMode: String, Codable, CaseIterable, Sendable {
    case direct
    case tailscale
    case relay

    public var label: String {
        switch self {
        case .direct: "Direct HTTPS"
        case .tailscale: "Tailscale HTTPS"
        case .relay: "Owned relay"
        }
    }

    public var detail: String {
        switch self {
        case .direct: "Connect to a host reachable from this device."
        case .tailscale: "Use a Tailscale HTTPS address you already configured."
        case .relay: "Use the relay address supplied by your host administrator."
        }
    }
}

public enum AddressError: Error, Equatable, LocalizedError, Sendable {
    case invalid
    case requiresHTTPS

    public var errorDescription: String? {
        switch self {
        case .invalid: "Enter an HTTPS address without credentials, a query, or a fragment."
        case .requiresHTTPS: "This connection requires an HTTPS address."
        }
    }
}

public struct ServerAddress: Codable, Hashable, Sendable {
    public let url: URL

    public init(validating string: String) throws {
        guard let components = URLComponents(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == "https"
        else {
            if let candidate = URLComponents(string: string), candidate.scheme != nil { throw AddressError.requiresHTTPS }
            throw AddressError.invalid
        }
        guard components.host != nil,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil
        else { throw AddressError.invalid }

        var normalized = components
        normalized.path = normalized.path == "/" ? "" : normalized.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !normalized.path.isEmpty { normalized.path = "/" + normalized.path }
        guard let url = normalized.url else { throw AddressError.invalid }
        self.url = url
    }
}

public struct ConnectionIdentity: Codable, Hashable, Sendable {
    public let host: String
    public let deviceID: String

    public init(host: String, deviceID: String) {
        self.host = host
        self.deviceID = deviceID
    }

    public var storageKey: String { host + "|" + deviceID }
}

public struct Project: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let name: String
    /// The folder on the Mac, absolute. Hosts that list `details` in `capabilities.projects` send it
    /// (docs/HOST-API.md, "Workspaces"); nil from the others.
    public let directory: String?
    /// The folder holds a `.git` entry (`details`).
    public let gitRepository: Bool
    /// What runs in the workspace now, on any device (`details`).
    public let activity: ProjectActivity?

    public init(id: String, name: String, directory: String? = nil, gitRepository: Bool = false, activity: ProjectActivity? = nil) {
        self.id = id; self.name = name; self.directory = directory; self.gitRepository = gitRepository; self.activity = activity
    }

    enum CodingKeys: String, CodingKey { case id, name, directory, gitRepository, activity }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        // Details this version cannot read count as none; they never cost the workspace.
        directory = (try? container.decodeIfPresent(String.self, forKey: .directory)).flatMap { $0 }.flatMap { $0.isEmpty ? nil : $0 }
        gitRepository = (try? container.decodeIfPresent(Bool.self, forKey: .gitRepository)).flatMap { $0 } ?? false
        activity = (try? container.decodeIfPresent(ProjectActivity.self, forKey: .activity)).flatMap { $0 }
    }
}
/// A workspace's running chat turns and live terminals, counted over every device.
public struct ProjectActivity: Codable, Hashable, Sendable {
    public let busyChats: Int
    public let terminals: Int
    public init(busyChats: Int, terminals: Int) { self.busyChats = busyChats; self.terminals = terminals }
    enum CodingKeys: String, CodingKey { case busyChats, terminals }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        busyChats = max(0, try container.decodeIfPresent(Int.self, forKey: .busyChats) ?? 0)
        terminals = max(0, try container.decodeIfPresent(Int.self, forKey: .terminals) ?? 0)
    }
}
public struct ProjectsResponse: Codable, Sendable { public let projects: [Project] }

public struct Session: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let projectID: String
    public let provider: String
    /// The chat a fork or continued chat was made from.
    public let parentSessionID: String?
    /// Who named the chat, on hosts that say (`titleSource`).
    public let titleSource: ChatTitleSource?
    /// The ID of the newest message the title describes (`titleBasis`).
    public let titleBasis: String?
    public init(id: String, title: String, projectID: String, provider: String = "opencode", parentSessionID: String? = nil,
                titleSource: ChatTitleSource? = nil, titleBasis: String? = nil) {
        self.id = id; self.title = title; self.projectID = projectID; self.provider = provider
        self.parentSessionID = parentSessionID
        self.titleSource = titleSource; self.titleBasis = titleBasis
    }
    enum CodingKeys: String, CodingKey { case id, title, projectID = "projectId", provider, parentSessionID = "parentSessionId", titleSource, titleBasis }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        projectID = try container.decode(String.self, forKey: .projectID)
        provider = try container.decodeIfPresent(String.self, forKey: .provider) ?? "opencode"
        parentSessionID = try container.decodeIfPresent(String.self, forKey: .parentSessionID)
        (titleSource, titleBasis) = ChatTitleSource.decodeNaming(from: container, source: .titleSource, basis: .titleBasis)
    }
}
public struct SessionsResponse: Codable, Sendable { public let sessions: [Session] }

public enum MessageRole: String, Codable, Sendable { case user, assistant }
public struct ChatMessage: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let role: MessageRole
    public let text: String
    public let tools: [ToolRecord]
    public let error: String?
    public let reasoning: [ReasoningRecord]
    public let attachments: [AttachmentRecord]
    /// With `?parts=1` (hosts that advertise `parts`): the ordered parts and
    /// the message's time, model and usage.
    public let parts: [ConversationPart]?
    public let createdAt: String?
    public let model: String?
    public let usage: ConversationUsage?

    public init(id: String, role: MessageRole, text: String, tools: [ToolRecord] = [], error: String? = nil,
                reasoning: [ReasoningRecord] = [], attachments: [AttachmentRecord] = [], parts: [ConversationPart]? = nil,
                createdAt: String? = nil, model: String? = nil, usage: ConversationUsage? = nil) {
        self.id = id; self.role = role; self.text = text; self.tools = tools; self.error = error
        self.reasoning = reasoning; self.attachments = attachments
        self.parts = parts; self.createdAt = createdAt; self.model = model; self.usage = usage
    }

    enum CodingKeys: String, CodingKey { case id, role, text, tools, error, reasoning, attachments, parts, createdAt, model, usage }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        role = try container.decode(MessageRole.self, forKey: .role)
        text = try container.decode(String.self, forKey: .text)
        tools = try container.decodeIfPresent([ToolRecord].self, forKey: .tools) ?? []
        error = try container.decodeIfPresent(String.self, forKey: .error)
        reasoning = try container.decodeIfPresent([ReasoningRecord].self, forKey: .reasoning) ?? []
        attachments = try container.decodeIfPresent([AttachmentRecord].self, forKey: .attachments) ?? []
        parts = try container.decodeIfPresent([ConversationPart].self, forKey: .parts)
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        usage = try container.decodeIfPresent(ConversationUsage.self, forKey: .usage)
    }
}
public struct ReasoningRecord: Codable, Hashable, Sendable {
    public let text: String
    public let durationMs: Int
    public init(text: String, durationMs: Int = 0) { self.text = text; self.durationMs = durationMs }
    enum CodingKeys: String, CodingKey { case text, durationMs }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        durationMs = try container.decodeIfPresent(Int.self, forKey: .durationMs) ?? 0
    }
}
/// A file sent with a user message. The host returns only display metadata, never file contents.
public struct AttachmentRecord: Codable, Hashable, Sendable {
    public let name: String
    public let mime: String
    /// Archived messages carry the file's size, and its SHA-256 when the host
    /// kept its bytes (docs/HOST-API.md, "Archive"). Live chats carry neither.
    public let size: Int64?
    public let sha256: String?
    public init(name: String, mime: String, size: Int64? = nil, sha256: String? = nil) {
        self.name = name; self.mime = mime; self.size = size; self.sha256 = sha256
    }
    public var isImage: Bool { mime.hasPrefix("image/") }
}
/// Set while an OpenCode chat is rewound to before `messageID`; the next prompt keeps the rewind.
public struct RewindState: Codable, Hashable, Sendable {
    public let messageID: String
    public init(messageID: String) { self.messageID = messageID }
    enum CodingKeys: String, CodingKey { case messageID = "messageId" }
}
public struct MessagesResponse: Codable, Sendable {
    public let messages: [ChatMessage]
    public let rewind: RewindState?
    public init(messages: [ChatMessage], rewind: RewindState? = nil) { self.messages = messages; self.rewind = rewind }
}

public enum QueuedPromptStatus: String, Codable, Hashable, Sendable {
    case queued, sending, failed

    /// A status this version does not know reads as waiting.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = QueuedPromptStatus(rawValue: raw) ?? .queued
    }
}
/// A prompt the host sends after the agent finishes its current work. Shared by every paired device.
public struct QueuedPrompt: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let text: String
    public let model: String?
    public let agent: String?
    public let createdAt: String
    public let status: QueuedPromptStatus
    public let error: String?
    public init(id: String, text: String, model: String? = nil, agent: String? = nil, createdAt: String = "",
                status: QueuedPromptStatus = .queued, error: String? = nil) {
        self.id = id; self.text = text; self.model = model; self.agent = agent
        self.createdAt = createdAt; self.status = status; self.error = error
    }
}
public struct QueueResponse: Codable, Sendable { public let items: [QueuedPrompt] }
public struct UploadedAttachment: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let mime: String
    public let size: Int64
    public init(id: String, name: String, mime: String, size: Int64) { self.id = id; self.name = name; self.mime = mime; self.size = size }
}
/// Chat features the host advertises in `chatFeatures`.
public enum ChatFeature: String, Sendable, CaseIterable {
    case reasoning, attachments, queue, rewind
    case events, parts, stop, regenerate, fork
    case `continue`
    case modes, effort, clientMessageId
    /// `POST /v1/chat/title`: a device names a chat.
    case title
}

/// What one provider's chats support (`chatProviderInfo.<provider>.features`).
public enum ChatProviderFeature: String, Sendable, CaseIterable {
    case rewind, restoreFiles, fork, approvals, questions, modes, effort
}

public struct ChatProviderInfo: Codable, Hashable, Sendable {
    public let version: String?
    /// `sse`, `stream-json`, `app-server`, `exec` or `coarse`.
    public let transport: String
    public let features: [String]
    public init(version: String? = nil, transport: String, features: [String]) {
        self.version = version; self.transport = transport; self.features = features
    }
    enum CodingKeys: String, CodingKey { case version, transport, features }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(String.self, forKey: .version)
        transport = try container.decodeIfPresent(String.self, forKey: .transport) ?? ""
        features = try container.decodeIfPresent([String].self, forKey: .features) ?? []
    }
}

public enum ToolStatus: String, Codable, Hashable, Sendable { case pending, running, completed, error }
public struct ToolRecord: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let callID: String
    public let name: String
    public let status: ToolStatus
    public let title: String
    public let input: String
    public let output: String
    public let error: String
    public let truncated: Bool

    public init(id: String, callID: String, name: String, status: ToolStatus, title: String, input: String, output: String, error: String, truncated: Bool) {
        self.id = id; self.callID = callID; self.name = name; self.status = status; self.title = title; self.input = input; self.output = output; self.error = error; self.truncated = truncated
    }
    enum CodingKeys: String, CodingKey { case id, callID = "callId", name, status, title, input, output, error, truncated }
}

public struct PermissionRequest: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let sessionID: String
    public let permission: String
    public let patterns: [String]
    public let details: String
    public init(id: String, sessionID: String, permission: String, patterns: [String], details: String) {
        self.id = id; self.sessionID = sessionID; self.permission = permission; self.patterns = patterns; self.details = details
    }
    enum CodingKeys: String, CodingKey { case id, sessionID = "sessionId", permission, patterns, details }
}

public struct QuestionOption: Codable, Hashable, Identifiable, Sendable {
    public let label: String
    public let description: String
    public var id: String { label }
    public init(label: String, description: String) { self.label = label; self.description = description }
}
public struct InteractionQuestion: Codable, Hashable, Sendable {
    public let header: String
    public let question: String
    public let options: [QuestionOption]
    public let multiple: Bool
    public let custom: Bool
    /// The answer is masked in the app and never stored.
    public let secret: Bool
    public init(header: String, question: String, options: [QuestionOption], multiple: Bool, custom: Bool, secret: Bool = false) {
        self.header = header; self.question = question; self.options = options; self.multiple = multiple; self.custom = custom
        self.secret = secret
    }
    enum CodingKeys: String, CodingKey { case header, question, options, multiple, custom, secret }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        header = try container.decodeIfPresent(String.self, forKey: .header) ?? ""
        question = try container.decodeIfPresent(String.self, forKey: .question) ?? ""
        options = try container.decodeIfPresent([QuestionOption].self, forKey: .options) ?? []
        multiple = try container.decodeIfPresent(Bool.self, forKey: .multiple) ?? false
        custom = try container.decodeIfPresent(Bool.self, forKey: .custom) ?? false
        secret = try container.decodeIfPresent(Bool.self, forKey: .secret) ?? false
    }
}
public struct QuestionRequest: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let sessionID: String
    public let questions: [InteractionQuestion]
    public init(id: String, sessionID: String, questions: [InteractionQuestion]) { self.id = id; self.sessionID = sessionID; self.questions = questions }
    enum CodingKeys: String, CodingKey { case id, sessionID = "sessionId", questions }
}
public struct InteractionsResponse: Codable, Sendable { public let permissions: [PermissionRequest]; public let questions: [QuestionRequest] }
/// `always` is sent only to a request whose `choices` offer it.
public enum PermissionReply: String, Codable, Sendable { case once, always, reject }

public struct CapabilitiesResponse: Codable, Hashable, Sendable {
    public let interactions: Bool
    public let terminal: Bool
    public let terminalPrograms: [String]
    public let terminalFeatures: [String]
    public let chatProviders: [String]
    public let chatFeatures: [String]
    /// Present only when the host streams chats.
    public let chatProviderInfo: [String: ChatProviderInfo]?
    /// Present only when the host keeps an archive (docs/HOST-API.md, "Archive").
    public let archive: ArchiveCapabilities?
    /// Present only while the host's preview listener runs (docs/HOST-API.md, "Preview").
    public let preview: PreviewCapabilities?
    /// File routes beyond reading and saving (docs/HOST-API.md, "Files"): `move`, `mkdir`, `upload`,
    /// `trash`, `delete`, `search`. Empty for hosts that list none.
    public let files: [String]
    /// Git changes beyond status and diffs (docs/HOST-API.md, "Git"): `stage`, `unstage`, `commit`,
    /// `stagedDiff`, `unstagedDiff`, `identity`. Empty for hosts that list none.
    public let git: [String]
    /// Workspace management (docs/HOST-API.md, "Workspaces"); nil for hosts without it.
    public let projects: ProjectCapabilities?
    /// The ways devices reach the host (docs/HOST-API.md, "Routes"); nil for hosts that list none.
    public let routes: [HostRoute]?
    /// What the host last read of Tailscale, beside its routes: `running`, `notListening`, `off`,
    /// `notFound` or `unknown` (docs/HOST-API.md, "Routes"); nil for hosts without routes.
    public let tailscale: String?
    /// Remote access through iroh (docs/HOST-API.md, "Remote access (iroh)"); nil for hosts without the
    /// tunnel socket and for an entry of another version.
    public let remoteAccess: RemoteAccessCapabilities?
    /// What the host serves of its agents (`AgentFeature` names: `catalog`, `install`, `acp`); empty for
    /// hosts without them (docs/AGENT-CATALOG-PLAN.md, "Capabilities").
    public let agents: [String]
    /// The agents usable now, with the host's names and what each can run; nil for hosts that list none.
    /// Their ids are in `chatProviders` and `terminalPrograms` too.
    public let agentCatalog: [AgentCatalogEntry]?
    /// What `POST /v1/device/presence` takes beyond `active` (docs/HOST-API.md "Presence and notices"):
    /// `views`, the chat a device shows. Empty for hosts that list none.
    public let presence: [String]
    /// Plain AI chats outside every workspace (docs/HOST-API.md "Plain chats"): the Chats space and its tools.
    /// Nil while the host offers none, and for an entry this version cannot read.
    public let plainChats: PlainChatsCapability?
    /// Chat in workspaces (owner, 2026-10-12): the Claude Code and Codex chats the host runs in its workspaces now.
    /// Nil for hosts before it, and for an entry of another version or one this version cannot read.
    public let workspaceChats: WorkspaceChatsCapability?
    /// The vault, this Mac's Markdown copy of the archive (docs/HOST-API.md "Vault"): listed only for the Mac's own
    /// session on a host that keeps one. Nil otherwise, and for an entry of another version.
    public let vault: VaultCapabilities?
    public init(interactions: Bool, terminal: Bool, terminalPrograms: [String] = [], terminalFeatures: [String] = [], chatProviders: [String] = ["opencode"],
                chatFeatures: [String] = [], chatProviderInfo: [String: ChatProviderInfo]? = nil, archive: ArchiveCapabilities? = nil,
                preview: PreviewCapabilities? = nil, files: [String] = [], git: [String] = [],
                projects: ProjectCapabilities? = nil, routes: [HostRoute]? = nil, tailscale: String? = nil,
                remoteAccess: RemoteAccessCapabilities? = nil, agents: [String] = [], agentCatalog: [AgentCatalogEntry]? = nil,
                presence: [String] = [], plainChats: PlainChatsCapability? = nil, workspaceChats: WorkspaceChatsCapability? = nil,
                vault: VaultCapabilities? = nil) {
        self.interactions = interactions; self.terminal = terminal; self.terminalPrograms = terminalPrograms; self.chatProviders = chatProviders
        self.terminalFeatures = terminalFeatures
        self.chatFeatures = chatFeatures
        self.chatProviderInfo = chatProviderInfo
        self.archive = archive
        self.preview = preview
        self.files = files
        self.git = git
        self.projects = projects
        self.routes = routes
        self.tailscale = tailscale
        self.remoteAccess = remoteAccess
        self.agents = agents
        self.agentCatalog = agentCatalog
        self.presence = presence
        self.plainChats = plainChats
        self.workspaceChats = workspaceChats
        self.vault = vault
    }
    enum CodingKeys: String, CodingKey {
        case interactions, terminal, terminalPrograms, terminalFeatures, chatProviders, chatFeatures, chatProviderInfo, archive
        case preview, files, git, projects, routes, tailscale, remoteAccess, agents, agentCatalog, presence
        case plainChats, workspaceChats, vault
    }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        interactions = try container.decode(Bool.self, forKey: .interactions)
        terminal = try container.decode(Bool.self, forKey: .terminal)
        terminalPrograms = try container.decodeIfPresent([String].self, forKey: .terminalPrograms) ?? []
        terminalFeatures = (try? container.decodeIfPresent([String].self, forKey: .terminalFeatures)) ?? []
        chatProviders = try container.decodeIfPresent([String].self, forKey: .chatProviders) ?? ["opencode"]
        chatFeatures = try container.decodeIfPresent([String].self, forKey: .chatFeatures) ?? []
        chatProviderInfo = try container.decodeIfPresent([String: ChatProviderInfo].self, forKey: .chatProviderInfo)
        // An archive entry this version cannot read counts as no archive.
        archive = (try? container.decodeIfPresent(ArchiveCapabilities.self, forKey: .archive)) ?? nil
        // Likewise previews: an entry this version cannot read offers none. A `schedules` entry from a
        // host older than 2026-10-06 is ignored: schedules were removed.
        preview = (try? container.decodeIfPresent(PreviewCapabilities.self, forKey: .preview)) ?? nil
        files = (try? container.decodeIfPresent([String].self, forKey: .files)) ?? []
        git = (try? container.decodeIfPresent([String].self, forKey: .git)) ?? []
        // Like the others: an entry this version cannot read offers no workspace management.
        projects = (try? container.decodeIfPresent(ProjectCapabilities.self, forKey: .projects)) ?? nil
        // Routes this version cannot read are left out; the others still work.
        routes = HostRoute.decodeList(from: container, forKey: .routes)
        tailscale = (try? container.decodeIfPresent(String.self, forKey: .tailscale)).flatMap { $0 }
        // Only version 1 is read; another version or an unreadable entry offers no remote access.
        remoteAccess = RemoteAccessCapabilities.decodeSupported(from: container, forKey: .remoteAccess)
        // Like files and git: a list this version cannot read offers no agent features.
        agents = (try? container.decodeIfPresent([String].self, forKey: .agents)).flatMap { $0 } ?? []
        // Agents this version cannot read, or whose id is not a short plain token, are left out.
        agentCatalog = AgentCatalogEntry.decodeList(from: container, forKey: .agentCatalog)
        // Like files and git: a list this version cannot read offers nothing beyond `active`.
        presence = (try? container.decodeIfPresent([String].self, forKey: .presence)).flatMap { $0 } ?? []
        // Absent, or without a Chats space this version can read: no plain chats. A host with Terminal sign-ins
        // lists every provider in `generalChats` and keeps `plainChats`, which clients before providers read as
        // "OpenCode runs plain chats", for OpenCode alone.
        plainChats = PlainChatsCapability.decodeSupported(from: try decoder.container(keyedBy: GeneralChatsKey.self), forKey: .generalChats)
            ?? PlainChatsCapability.decodeSupported(from: container, forKey: .plainChats)
        // Only version 1 is read; another version or an unreadable entry offers no workspace chats.
        workspaceChats = WorkspaceChatsCapability.decodeSupported(from: container, forKey: .workspaceChats)
        // Only version 1 is read; another version or an unreadable entry offers no vault.
        vault = VaultCapabilities.decodeSupported(from: container, forKey: .vault)
    }
    private enum GeneralChatsKey: String, CodingKey { case generalChats }
    /// Older hosts omit `chatFeatures`; their clients keep the original chat surface.
    public func supports(_ feature: ChatFeature) -> Bool { chatFeatures.contains(feature.rawValue) }
    /// The presence heartbeat takes the chat a device shows (`presence: ["views"]`); other hosts refuse it.
    public var supportsPresenceViews: Bool { presence.contains("views") }
    /// A provider feature: as `chatProviderInfo` lists it for the provider (sent only while the host's OpenCode
    /// streams), else as the provider's `workspaceChats` entry does. Without either (older hosts) nothing is claimed.
    public func supports(_ feature: ChatProviderFeature, provider: String) -> Bool {
        if let info = chatProviderInfo?[provider] { return info.features.contains(feature.rawValue) }
        return workspaceChats?.provider(provider)?.features.contains(feature.rawValue) == true
    }
}
public extension CapabilitiesResponse {
    /// Every paired device reaches every terminal on the host, and `GET /v1/terminals/others` lists the other
    /// devices' and this Mac's (`terminalFeatures` lists `shared`); older hosts share none.
    var sharesTerminals: Bool { terminalFeatures.contains("shared") }
}
public enum TerminalStatus: String, Codable, Hashable, Sendable { case running, exited, disconnected }

/// How a terminal ended, as hosts that record it say (docs/HOST-API.md "How terminals end"): on an ended terminal,
/// in its output, and with `terminal_not_found` when the host's archive recorded it. Every field is optional to
/// read: a value this version does not know counts as none.
public struct TerminalEnd: Codable, Hashable, Sendable {
    public enum Reason: String, Codable, Hashable, Sendable {
        /// `backendEnded`: OpenCode on the Mac ended the PTY without its program exiting (2026-10-14).
        case programExited, backendEnded, endedByDevice, workspaceRemoved, hostStopped, hostInterrupted, connectionLost
        /// The Mac's terminal service stopped (restart, logout, or the service quit) with the terminal running.
        case keeperStopped, endedOnMac, deviceRemoved
        /// A coding agent typed in Terminal.app that AgentLand stopped following: it keeps running in its Terminal
        /// window on the Mac.
        case keptInTerminal
    }
    /// Nil for a reason this version does not know, or a log from before the host recorded reasons.
    public let reason: Reason?
    public let at: Date?
    public let exitCode: Int?
    /// The name of the device that ended it.
    public let device: String?
    /// The program the terminal was opened with ("shell", "claude", …).
    public let program: String?
    /// A Claude Code terminal's conversation, which Resume continues.
    public let conversationID: String?
    /// The terminal it went on in (docs/HOST-API.md "Continuing a terminal in a new one", 2026-10-26): a tab showing
    /// this one switches to that one in place.
    public let continuedIn: String?

    public init(reason: Reason?, at: Date?, exitCode: Int? = nil, device: String? = nil, program: String? = nil, conversationID: String? = nil,
                continuedIn: String? = nil) {
        self.reason = reason; self.at = at; self.exitCode = exitCode; self.device = device; self.program = program
        self.conversationID = conversationID; self.continuedIn = continuedIn
    }
    enum CodingKeys: String, CodingKey { case reason, at, exitCode, device, program, conversationID = "conversationId", continuedIn }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        reason = (try? container.decodeIfPresent(String.self, forKey: .reason)).flatMap { $0 }.flatMap(Reason.init(rawValue:))
        at = (try? container.decodeIfPresent(String.self, forKey: .at)).flatMap { $0 }.flatMap(Self.parseDate)
        exitCode = (try? container.decodeIfPresent(Int.self, forKey: .exitCode)).flatMap { $0 }
        device = (try? container.decodeIfPresent(String.self, forKey: .device)).flatMap { $0 }
            .map { HostText.line($0, limit: 100) }.flatMap { $0.isEmpty ? nil : $0 }
        program = (try? container.decodeIfPresent(String.self, forKey: .program)).flatMap { $0 }.flatMap { $0.isEmpty ? nil : $0 }
        conversationID = (try? container.decodeIfPresent(String.self, forKey: .conversationID)).flatMap { $0 }.flatMap(TerminalResume.validConversation)
        continuedIn = (try? container.decodeIfPresent(String.self, forKey: .continuedIn)).flatMap { $0 }.flatMap(Self.validTerminalID)
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(reason?.rawValue, forKey: .reason)
        try container.encodeIfPresent(at.map { $0.formatted(.iso8601) }, forKey: .at)
        try container.encodeIfPresent(exitCode, forKey: .exitCode)
        try container.encodeIfPresent(device, forKey: .device)
        try container.encodeIfPresent(program, forKey: .program)
        try container.encodeIfPresent(conversationID, forKey: .conversationID)
        try container.encodeIfPresent(continuedIn, forKey: .continuedIn)
    }
    /// A terminal ID as hosts make them: 1 to 128 of `A-Z a-z 0-9 . _ : -`.
    static func validTerminalID(_ text: String) -> String? {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._:-")
        return (1...128).contains(text.count) && text.allSatisfy(allowed.contains) ? text : nil
    }
    static func parseDate(_ text: String) -> Date? {
        (try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))) ?? (try? Date(text, strategy: .iso8601))
    }
}

/// What `POST /v1/terminals` resumes for a Claude Code terminal on hosts that list `resume` in `terminalFeatures`:
/// a conversation by its UUID, or `pick`, Claude Code's own session picker in the new terminal (for an ended terminal
/// whose conversation the host never named). The host builds the arguments; nothing else is sent.
public enum TerminalResume: Hashable, Sendable {
    case conversation(String)
    case pick

    public var requestValue: String {
        switch self {
        case let .conversation(id): id
        case .pick: "pick"
        }
    }

    /// A conversation ID as the host gives it: a UUID, lowercased; nil otherwise.
    public static func validConversation(_ text: String) -> String? {
        UUID(uuidString: text) != nil ? text.lowercased() : nil
    }
}

/// The host no longer has this terminal (`terminal_not_found`): it ended and was forgotten, or the host started
/// again since. `ended` is how it ended, when the host's archive recorded it.
public struct TerminalGoneError: Error, Equatable, LocalizedError, Sendable {
    public let ended: TerminalEnd?
    public init(ended: TerminalEnd?) { self.ended = ended }
    public var errorDescription: String? { "This terminal is no longer running on the host." }
}
/// Where a terminal's `contextTitle` came from (docs/HOST-API.md "Contextual terminal names"): its program's window
/// title, or a device's name (`POST /v1/terminal/title`), which the host keeps until a device names the terminal again.
public enum TerminalNameSource: String, Codable, Hashable, Sendable { case program, device }

public struct RemoteTerminal: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    /// The label the terminal was created with ("OpenCode", "Claude Code", "Codex", "Terminal").
    public let title: String
    public let projectID: String
    public let status: TerminalStatus
    public let exitCode: Int?
    /// The latest window title its program set (OSC 0 or 2), as the host cleaned it; nil when it set none
    /// or the host does not read titles.
    public let programTitle: String?
    public let contextTitle: String?
    /// Where `contextTitle` came from; nil from hosts that do not say (their program's titles replace any name).
    public let contextTitleSource: TerminalNameSource?
    /// The foreground command, when the program set no title (hosts on macOS read it).
    public let command: String?
    /// Preparation notice; bounded before display.
    public let updateNotice: String?
    /// A Claude Code terminal's conversation (hosts that list `resume` in `terminalFeatures`).
    public let conversationID: String?
    /// How it ended, once it is not running (hosts that record it).
    public let ended: TerminalEnd?

    public init(id: String, title: String, projectID: String, status: TerminalStatus, exitCode: Int?,
                programTitle: String? = nil, contextTitle: String? = nil, contextTitleSource: TerminalNameSource? = nil,
                command: String? = nil, updateNotice: String? = nil, conversationID: String? = nil, ended: TerminalEnd? = nil) {
        self.id = id; self.title = title; self.projectID = projectID; self.status = status; self.exitCode = exitCode
        self.programTitle = programTitle; self.contextTitle = contextTitle; self.contextTitleSource = contextTitleSource
        self.command = command
        self.updateNotice = updateNotice.map { HostText.line($0, limit: 600) }.flatMap { $0.isEmpty ? nil : $0 }
        self.conversationID = conversationID; self.ended = ended
    }
    enum CodingKeys: String, CodingKey {
        case id, title, projectID = "projectId", status, exitCode, programTitle, contextTitle, contextTitleSource, command
        case updateNotice, conversationID = "conversationId", ended
    }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        projectID = try container.decode(String.self, forKey: .projectID)
        status = try container.decode(TerminalStatus.self, forKey: .status)
        exitCode = try container.decodeIfPresent(Int.self, forKey: .exitCode)
        // Names this version cannot read count as none; they never cost the terminal.
        programTitle = (try? container.decodeIfPresent(String.self, forKey: .programTitle)).flatMap { $0 }
        contextTitle = (try? container.decodeIfPresent(String.self, forKey: .contextTitle)).flatMap { $0 }
        contextTitleSource = (try? container.decodeIfPresent(TerminalNameSource.self, forKey: .contextTitleSource)).flatMap { $0 }
        command = (try? container.decodeIfPresent(String.self, forKey: .command)).flatMap { $0 }
        updateNotice = (try? container.decodeIfPresent(String.self, forKey: .updateNotice)).flatMap { $0 }
            .map { HostText.line($0, limit: 600) }.flatMap { $0.isEmpty ? nil : $0 }
        conversationID = (try? container.decodeIfPresent(String.self, forKey: .conversationID)).flatMap { $0 }
            .flatMap(TerminalResume.validConversation)
        ended = (try? container.decodeIfPresent(TerminalEnd.self, forKey: .ended)).flatMap { $0 }
    }

    /// Latest task context, then the program title, foreground command and launch label.
    /// Either is left out when it is only the program's own name (`TerminalTitle`).
    public var displayTitle: String {
        contextTitle.flatMap { TerminalTitle.clean($0, label: title) }
            ?? programTitle.flatMap { TerminalTitle.clean($0, label: title) }
            ?? command.flatMap { TerminalTitle.clean($0, label: title) }
            ?? title
    }
}
public struct TerminalsResponse: Codable, Sendable { public let terminals: [RemoteTerminal] }

/// A running terminal another device opened, or this Mac (a coding agent typed in Terminal.app, a terminal of the
/// Mac's web app), as `GET /v1/terminals/others` lists it for hosts that list `shared` in `terminalFeatures`. Every
/// paired device reaches every terminal: opened here it is a `RemoteTerminal` like this device's own. Values this
/// version cannot read count as none; they never cost the terminal.
public struct SharedTerminal: Codable, Hashable, Identifiable, Sendable {
    /// What it is doing: output within the last few seconds, waiting for the person (a notification or bell since
    /// its last input), or neither. A value this version does not know counts as quiet.
    public enum Activity: String, Codable, Sendable { case working, waiting, quiet }

    public let id: String
    public let deviceID: String
    /// The device that opened it; "" for this Mac's own, which the apps call by the host's name.
    public let deviceName: String
    /// The program it was opened with ("shell", "claude", …).
    public let program: String
    /// The label it was created with, as `RemoteTerminal.title`.
    public let title: String
    /// Its working folder on the Mac, and the same with the home folder as `~`.
    public let folder: String
    public let displayFolder: String
    /// This Mac opened it: a coding agent typed in Terminal.app, or a terminal of the Mac's web app.
    public let onMac: Bool
    /// A coding agent typed in Terminal.app that AgentLand's terminals took in.
    public let routed: Bool
    public let programTitle: String?
    public let contextTitle: String?
    /// Where `contextTitle` came from, as `RemoteTerminal`'s.
    public let contextTitleSource: TerminalNameSource?
    /// Its workspace's ID and name; nil for a terminal outside any workspace.
    public let projectID: String?
    public let workspace: String?
    public let status: TerminalStatus
    public let activity: Activity
    /// Its last output; nil before any.
    public let lastOutputAt: Date?
    /// The latest of its last output, its last input and its start; `.distantPast` when the host did not say.
    public let lastActiveAt: Date

    public init(id: String, deviceID: String, deviceName: String, program: String, title: String, folder: String = "",
                displayFolder: String = "", onMac: Bool = false, routed: Bool = false, programTitle: String? = nil,
                contextTitle: String? = nil, contextTitleSource: TerminalNameSource? = nil, projectID: String? = nil,
                workspace: String? = nil, status: TerminalStatus = .running,
                activity: Activity = .quiet, lastOutputAt: Date? = nil, lastActiveAt: Date = .distantPast) {
        self.id = id; self.deviceID = deviceID; self.deviceName = deviceName; self.program = program; self.title = title
        self.folder = folder; self.displayFolder = displayFolder; self.onMac = onMac; self.routed = routed
        self.programTitle = programTitle; self.contextTitle = contextTitle; self.contextTitleSource = contextTitleSource
        self.projectID = projectID.flatMap { $0.isEmpty ? nil : $0 }; self.workspace = workspace.flatMap { $0.isEmpty ? nil : $0 }
        self.status = status; self.activity = activity; self.lastOutputAt = lastOutputAt; self.lastActiveAt = lastActiveAt
    }
    enum CodingKeys: String, CodingKey {
        case id, deviceID = "deviceId", deviceName, program, title, folder, displayFolder, onMac, routed, programTitle, contextTitle
        case contextTitleSource, projectID = "projectId", workspace, status, activity, lastOutputAt, lastActiveAt
    }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        status = try container.decode(TerminalStatus.self, forKey: .status)
        func text(_ key: CodingKeys) -> String? { (try? container.decodeIfPresent(String.self, forKey: key)).flatMap { $0 } }
        func flag(_ key: CodingKeys) -> Bool { (try? container.decodeIfPresent(Bool.self, forKey: key)).flatMap { $0 } ?? false }
        deviceID = text(.deviceID) ?? ""
        deviceName = text(.deviceName).map { HostText.line($0, limit: 100) } ?? ""
        program = text(.program) ?? ""
        title = text(.title) ?? ""
        folder = text(.folder) ?? ""
        displayFolder = text(.displayFolder) ?? ""
        onMac = flag(.onMac)
        routed = flag(.routed)
        programTitle = text(.programTitle)
        contextTitle = text(.contextTitle)
        contextTitleSource = text(.contextTitleSource).flatMap(TerminalNameSource.init(rawValue:))
        // Outside any workspace the host sends null; "" says the same.
        projectID = text(.projectID).flatMap { $0.isEmpty ? nil : $0 }
        workspace = text(.workspace).flatMap { $0.isEmpty ? nil : $0 }
        activity = text(.activity).flatMap(Activity.init(rawValue:)) ?? .quiet
        lastOutputAt = text(.lastOutputAt).flatMap(TerminalEnd.parseDate)
        lastActiveAt = text(.lastActiveAt).flatMap(TerminalEnd.parseDate) ?? .distantPast
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let time = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        try container.encode(id, forKey: .id)
        try container.encode(deviceID, forKey: .deviceID)
        try container.encode(deviceName, forKey: .deviceName)
        try container.encode(program, forKey: .program)
        try container.encode(title, forKey: .title)
        try container.encode(folder, forKey: .folder)
        try container.encode(displayFolder, forKey: .displayFolder)
        try container.encode(onMac, forKey: .onMac)
        try container.encode(routed, forKey: .routed)
        try container.encodeIfPresent(programTitle, forKey: .programTitle)
        try container.encodeIfPresent(contextTitle, forKey: .contextTitle)
        try container.encodeIfPresent(contextTitleSource, forKey: .contextTitleSource)
        try container.encodeIfPresent(projectID, forKey: .projectID)
        try container.encodeIfPresent(workspace, forKey: .workspace)
        try container.encode(status, forKey: .status)
        try container.encode(activity, forKey: .activity)
        try container.encodeIfPresent(lastOutputAt.map { $0.formatted(time) }, forKey: .lastOutputAt)
        if lastActiveAt != .distantPast { try container.encode(lastActiveAt.formatted(time), forKey: .lastActiveAt) }
    }

    /// The terminal as this device opens it: projectless ("") outside any workspace.
    public var remoteTerminal: RemoteTerminal {
        RemoteTerminal(id: id, title: title, projectID: projectID ?? "", status: .running, exitCode: nil,
                       programTitle: programTitle, contextTitle: contextTitle, contextTitleSource: contextTitleSource)
    }
}
/// `GET /v1/terminals/others`. A terminal this version cannot read is left out; the others stay.
public struct SharedTerminalsResponse: Codable, Sendable {
    public let terminals: [SharedTerminal]
    public init(terminals: [SharedTerminal]) { self.terminals = terminals }
    enum CodingKeys: String, CodingKey { case terminals }
    private struct Readable: Decodable {
        let terminal: SharedTerminal?
        init(from decoder: Decoder) throws { terminal = try? SharedTerminal(from: decoder) }
    }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        terminals = try container.decode([Readable].self, forKey: .terminals).compactMap(\.terminal)
    }
}
/// Where a tab's terminal came from when another device opened it, or this Mac (`SharedTerminal`): kept with the
/// tab (`WorkspaceTab.sharedFrom`) so closing it here only stops following it.
public struct SharedOrigin: Codable, Hashable, Sendable {
    /// "" for this Mac's own.
    public let deviceName: String
    public let onMac: Bool
    public let routed: Bool
    public init(deviceName: String, onMac: Bool, routed: Bool) {
        self.deviceName = deviceName; self.onMac = onMac; self.routed = routed
    }
}
public struct TerminalOutput: Codable, Hashable, Sendable {
    public let data: String
    public let cursor: UInt64
    /// The cursor after the newest byte the host held when it answered; older hosts omit it.
    public let end: UInt64?
    public let reset: Bool
    public let status: TerminalStatus
    public let exitCode: Int?
    /// How the terminal ended, once `status` is not running (hosts that record it).
    public let ended: TerminalEnd?
    public var decodedData: Data? { Data(base64Encoded: data) }

    public init(data: String, cursor: UInt64, end: UInt64?, reset: Bool, status: TerminalStatus, exitCode: Int?, ended: TerminalEnd? = nil) {
        self.data = data; self.cursor = cursor; self.end = end; self.reset = reset; self.status = status; self.exitCode = exitCode
        self.ended = ended
    }
    enum CodingKeys: String, CodingKey { case data, cursor, end, reset, status, exitCode, ended }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        data = try container.decode(String.self, forKey: .data)
        cursor = try container.decode(UInt64.self, forKey: .cursor)
        end = try container.decodeIfPresent(UInt64.self, forKey: .end)
        reset = try container.decode(Bool.self, forKey: .reset)
        status = try container.decode(TerminalStatus.self, forKey: .status)
        exitCode = try container.decodeIfPresent(Int.self, forKey: .exitCode)
        // An end this version cannot read counts as none; it never costs the output.
        ended = (try? container.decodeIfPresent(TerminalEnd.self, forKey: .ended)).flatMap { $0 }
    }
}

public struct PairResponse: Codable, Sendable {
    public let token: String
    public let deviceID: String
    enum CodingKeys: String, CodingKey { case token; case deviceID = "deviceId" }
}
public struct HealthResponse: Codable, Sendable { public let status: String; public let protocolVersion: Int }
public struct AcceptedResponse: Codable, Sendable { public let accepted: Bool }
public struct AbortResponse: Codable, Sendable { public let aborted: Bool }
public struct APIErrorEnvelope: Codable, Sendable { public let error: APIError }
public struct APIError: Codable, Sendable {
    public let code: String
    public let message: String
}

public struct SessionTab: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public let projectID: String
    public let sessionID: String
    public var title: String
    public var draft: String
    public init(id: UUID = UUID(), projectID: String, sessionID: String, title: String, draft: String = "") {
        self.id = id; self.projectID = projectID; self.sessionID = sessionID; self.title = title; self.draft = draft
    }
}

/// What a tab shows. Saved workspaces decode their tabs one at a time (`WorkspacePersistence`), so a
/// version that lacks a kind drops only that tab. `browser` (a web page or a port on the host, opened
/// through its preview listener) was added after the first five, and `git` (the workspace's
/// repositories: staging, diffs and commits) after it.
public enum WorkspaceTabKind: String, Codable, Sendable { case home, chat, terminal, files, editor, browser, git }

public struct WorkspaceTab: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var kind: WorkspaceTabKind
    public var projectID: String
    public var resourceID: String
    public var title: String
    public var draft: String
    public var chatModelID: String?
    /// OpenCode's agent (`build`, `plan`) or another provider's mode.
    public var chatAgent: String?
    public var chatEffort: String?
    /// The person confirmed, once for this chat, a mode that runs without asking (Claude Code's Bypass permissions,
    /// Codex's Full access; `ChatSessionStore.unattendedModeConfirmed`). Nil until then, and for other tabs.
    public var chatModeConfirmed: Bool?
    public var editorDirty: Bool
    public var editorBaseRevision: String?
    /// The title a terminal's tab was created with (its program's label: OpenCode, Claude Code, Codex or
    /// Terminal), kept while `title` follows what runs in it. Nil for other tabs and for terminal tabs
    /// saved before titles followed their terminal, whose `title` is still that label.
    public var creationLabel: String?
    /// A terminal another device opened, or this Mac, that this tab follows (`SharedTerminal`); nil for this
    /// device's own terminals, other tabs, and tabs saved before terminals were shared.
    public var sharedFrom: SharedOrigin?
    public init(id: UUID = UUID(), kind: WorkspaceTabKind, projectID: String, resourceID: String = "", title: String, draft: String = "") {
        self.id = id; self.kind = kind; self.projectID = projectID; self.resourceID = resourceID; self.title = title; self.draft = draft; self.editorDirty = false; self.editorBaseRevision = nil
    }
    enum CodingKeys: String, CodingKey { case id, kind, projectID, resourceID, title, draft, editorDirty, editorBaseRevision, chatModelID, chatAgent, chatEffort, chatModeConfirmed, creationLabel, sharedFrom }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decode(WorkspaceTabKind.self, forKey: .kind)
        projectID = try container.decode(String.self, forKey: .projectID)
        resourceID = try container.decode(String.self, forKey: .resourceID)
        title = try container.decode(String.self, forKey: .title)
        draft = try container.decodeIfPresent(String.self, forKey: .draft) ?? ""
        chatModelID = try container.decodeIfPresent(String.self, forKey: .chatModelID)
        chatAgent = try container.decodeIfPresent(String.self, forKey: .chatAgent)
        chatEffort = try container.decodeIfPresent(String.self, forKey: .chatEffort)
        chatModeConfirmed = try container.decodeIfPresent(Bool.self, forKey: .chatModeConfirmed)
        editorDirty = try container.decodeIfPresent(Bool.self, forKey: .editorDirty) ?? false
        editorBaseRevision = try container.decodeIfPresent(String.self, forKey: .editorBaseRevision)
        creationLabel = try container.decodeIfPresent(String.self, forKey: .creationLabel)
        sharedFrom = try container.decodeIfPresent(SharedOrigin.self, forKey: .sharedFrom)
    }

    /// What the tab was created as: its creation label, or its title while that has not moved on.
    public var label: String { creationLabel ?? title }

    /// The tab of a host terminal: named for what runs in it, with the label it was created with kept. `sharedFrom`:
    /// another device opened it, or this Mac.
    public static func terminal(_ terminal: RemoteTerminal, projectID: String, sharedFrom: SharedOrigin? = nil) -> WorkspaceTab {
        var tab = WorkspaceTab(kind: .terminal, projectID: projectID, resourceID: terminal.id, title: terminal.displayTitle)
        tab.creationLabel = terminal.title
        tab.sharedFrom = sharedFrom
        return tab
    }
}

public struct FileEntry: Codable, Hashable, Identifiable, Sendable {
    public let name: String
    public let path: String
    public let isDirectory: Bool
    public let size: Int64
    /// When the item last changed, for hosts whose listing names it (`modifiedAt`, RFC 3339). The
    /// current contract's entries do not, so this is nil and the iPad table leaves its column out.
    public let modifiedAt: Date?
    public var id: String { path }

    public init(name: String, path: String, isDirectory: Bool, size: Int64, modifiedAt: Date? = nil) {
        self.name = name; self.path = path; self.isDirectory = isDirectory; self.size = size; self.modifiedAt = modifiedAt
    }

    enum CodingKeys: String, CodingKey { case name, path, isDirectory, size, modifiedAt }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        path = try container.decode(String.self, forKey: .path)
        isDirectory = try container.decodeIfPresent(Bool.self, forKey: .isDirectory) ?? false
        size = try container.decodeIfPresent(Int64.self, forKey: .size) ?? 0
        // A time this version cannot read counts as none; it never costs the entry.
        modifiedAt = (try? container.decodeIfPresent(String.self, forKey: .modifiedAt)).flatMap { $0 }.flatMap(FileEntry.parseTime)
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(path, forKey: .path)
        try container.encode(isDirectory, forKey: .isDirectory)
        try container.encode(size, forKey: .size)
        try container.encodeIfPresent(modifiedAt.map { $0.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true)) },
                                      forKey: .modifiedAt)
    }

    static func parseTime(_ value: String) -> Date? {
        (try? Date(value, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true)))
            ?? (try? Date(value, strategy: .iso8601))
    }
}
public struct FilesResponse: Codable, Sendable { public let entries: [FileEntry] }
public struct FileDocument: Codable, Hashable, Sendable {
    public let path: String
    public let content: String
    public let revision: String
}

public struct GitRepository: Codable, Hashable, Identifiable, Sendable {
    public let name: String
    public let path: String
    public var id: String { path }
}
public struct GitRepositoriesResponse: Codable, Sendable { public let repositories: [GitRepository] }
public struct GitChange: Codable, Hashable, Identifiable, Sendable {
    public let path: String
    /// Porcelain v1's two columns, such as "M ", " M", "MM" or "??".
    public let status: String
    /// The index column ("" when unchanged; "?" for an untracked file). Hosts before the index and
    /// worktree members get it from `status`.
    public let index: String
    /// The worktree column ("" when unchanged; "?" for an untracked file).
    public let worktree: String
    /// An unmerged path (`DD AU UD UA DU AA UU`).
    public let conflicted: Bool
    public let untracked: Bool
    /// A rename's or copy's source, relative to the repository.
    public let originalPath: String?
    public var id: String { path }

    public init(path: String, status: String, index: String? = nil, worktree: String? = nil, conflicted: Bool? = nil,
                untracked: Bool? = nil, originalPath: String? = nil) {
        self.path = path
        self.status = status
        let columns = GitChange.columns(status)
        self.index = index ?? columns.index
        self.worktree = worktree ?? columns.worktree
        self.conflicted = conflicted ?? GitChange.isConflict(status)
        self.untracked = untracked ?? (status == "??")
        self.originalPath = originalPath?.isEmpty == false ? originalPath : nil
    }

    enum CodingKeys: String, CodingKey { case path, status, index, worktree, conflicted, untracked, originalPath }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(path: try container.decode(String.self, forKey: .path),
                  status: try container.decodeIfPresent(String.self, forKey: .status) ?? "",
                  index: try container.decodeIfPresent(String.self, forKey: .index),
                  worktree: try container.decodeIfPresent(String.self, forKey: .worktree),
                  conflicted: try container.decodeIfPresent(Bool.self, forKey: .conflicted),
                  untracked: try container.decodeIfPresent(Bool.self, forKey: .untracked),
                  originalPath: try container.decodeIfPresent(String.self, forKey: .originalPath))
    }

    /// The two porcelain columns of `status`, a space read as "".
    static func columns(_ status: String) -> (index: String, worktree: String) {
        let letters = Array(status)
        func column(_ position: Int) -> String {
            guard letters.indices.contains(position), letters[position] != " " else { return "" }
            return String(letters[position])
        }
        return (column(0), column(1))
    }

    static func isConflict(_ status: String) -> Bool {
        ["DD", "AU", "UD", "UA", "DU", "AA", "UU"].contains(status)
    }
}
public struct GitStatusResponse: Codable, Hashable, Sendable {
    public let branch: String
    public let changes: [GitChange]
    public let truncated: Bool
    public init(branch: String, changes: [GitChange], truncated: Bool = false) {
        self.branch = branch; self.changes = changes; self.truncated = truncated
    }
    enum CodingKeys: String, CodingKey { case branch, changes, truncated }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        branch = try values.decode(String.self, forKey: .branch)
        changes = try values.decode([GitChange].self, forKey: .changes)
        truncated = try values.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
    }
}
public struct GitDiffResponse: Codable, Hashable, Identifiable, Sendable {
    public let path: String
    public let diff: String
    public var id: String { path }
    public init(path: String, diff: String) { self.path = path; self.diff = diff }
}

public enum EditorRevisionPolicy {
    /// Keep the revision that the unsaved draft was based on. A missing legacy
    /// revision deliberately saves with an empty value so an existing file conflicts.
    public static func saveRevision(for tab: WorkspaceTab, remoteRevision: String) -> String {
        tab.editorDirty ? (tab.editorBaseRevision ?? "") : remoteRevision
    }
    public static func remoteChanged(since tab: WorkspaceTab, remoteRevision: String) -> Bool {
        tab.editorDirty && tab.editorBaseRevision != remoteRevision
    }
}

public enum ProtocolDecoder {
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T { try JSONDecoder().decode(T.self, from: data) }
}

public struct AgentModelOption: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let provider: String
    public let contextWindow: Int?
    /// Reasoning efforts the model takes, when it lists them.
    public let efforts: [String]?
    public let defaultEffort: String?
    public init(id: String, name: String, provider: String, contextWindow: Int? = nil, efforts: [String]? = nil,
                defaultEffort: String? = nil) {
        self.id = id; self.name = name; self.provider = provider; self.contextWindow = contextWindow
        self.efforts = efforts; self.defaultEffort = defaultEffort
    }
}
/// A mode a chat can run in (Codex's approval presets).
public struct ChatModeOption: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}
public struct ChatOptionsResponse: Codable, Hashable, Sendable {
    public let models: [AgentModelOption]
    public let defaultModel: String
    public let agents: [String]
    public let modes: [ChatModeOption]?
    public let defaultMode: String?
    public init(models: [AgentModelOption], defaultModel: String, agents: [String], modes: [ChatModeOption]? = nil,
                defaultMode: String? = nil) {
        self.models = models; self.defaultModel = defaultModel; self.agents = agents; self.modes = modes; self.defaultMode = defaultMode
    }
    enum CodingKeys: String, CodingKey { case models, defaultModel, agents, modes, defaultMode }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        models = try container.decodeIfPresent([AgentModelOption].self, forKey: .models) ?? []
        defaultModel = try container.decodeIfPresent(String.self, forKey: .defaultModel) ?? ""
        agents = try container.decodeIfPresent([String].self, forKey: .agents) ?? []
        modes = try container.decodeIfPresent([ChatModeOption].self, forKey: .modes)
        defaultMode = try container.decodeIfPresent(String.self, forKey: .defaultMode)
    }
}
public struct ChatStatusResponse: Codable, Sendable { public let state: String }
