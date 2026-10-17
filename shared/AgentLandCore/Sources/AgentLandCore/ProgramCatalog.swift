import Foundation

/// A program the host can start in a terminal. `id` is the name the host lists in `terminalPrograms` (and
/// `agentCatalog`) and accepts when it creates a terminal; clients send a name, never a command.
public struct TerminalProgram: Hashable, Identifiable, Sendable {
    public let id: String
    /// The host's name for a program this version cannot name (`agentCatalog`); nil for the known ones,
    /// which keep their own names.
    public let hostName: String?

    public init(id: String, name: String? = nil) {
        self.id = id
        hostName = Self.knownNames[id] == nil && AgentID.isValid(id) ? AgentID.displayName(name) : nil
    }

    public static let shell = TerminalProgram(id: "shell")
    public static let opencode = TerminalProgram(id: "opencode")
    public static let claude = TerminalProgram(id: "claude")
    public static let codex = TerminalProgram(id: "codex")
    /// Every program this version can name, in menu order.
    public static let known: [TerminalProgram] = [.shell, .opencode, .claude, .codex]
    private static let knownNames = ["shell": "Shell", "opencode": "OpenCode", "claude": "Claude Code", "codex": "Codex"]

    /// The known programs' names; the host's name for the others; the id itself when the host gave none;
    /// a neutral label for an id that is not a short plain token.
    public var displayName: String {
        Self.knownNames[id] ?? CatalogName.fallback(for: id, name: hostName, otherwise: "Unknown program")
    }

    /// The title of a new terminal tab. A plain shell is simply "Terminal".
    public var terminalTitle: String { self == .shell ? "Terminal" : displayName }

    /// The program named when creating a terminal. The shell is the host's default and is sent as no
    /// program, which every host version accepts.
    public var requestValue: String? { self == .shell ? nil : id }

    /// The programs to offer for a host, each once: the shell whenever the host runs terminals, then the
    /// known programs the host lists (in menu order), then the others it lists in its order, with its names:
    /// its catalog's terminal agents, then the rest of `terminalPrograms`. Ids that are not short plain
    /// tokens are left out.
    public static func offered(by capabilities: CapabilitiesResponse?) -> [TerminalProgram] {
        guard let capabilities, capabilities.terminal else { return [] }
        let catalog = capabilities.agentCatalog ?? []
        let listed = catalog.filter(\.terminal).map(\.id) + capabilities.terminalPrograms
        var offered = known.filter { $0 == .shell || listed.contains($0.id) }
        for id in listed where AgentID.isValid(id) && !offered.contains(where: { $0.id == id }) {
            offered.append(TerminalProgram(id: id, name: catalog.first { $0.id == id }?.name))
        }
        return offered
    }

    /// The program the host calls `id`, with its name when the host's catalog has one.
    public static func named(_ id: String, by capabilities: CapabilitiesResponse?) -> TerminalProgram {
        TerminalProgram(id: id, name: capabilities?.agentCatalog?.first { $0.id == id }?.name)
    }
}

/// An agent that runs chats on the host. `id` is the name the host lists in `chatProviders` (and
/// `agentCatalog`) and records as each session's `provider`.
public struct AgentProvider: Hashable, Identifiable, Sendable {
    public let id: String
    /// The host's name for an agent this version cannot name (`agentCatalog`); nil for the known ones,
    /// which keep their own names.
    public let hostName: String?

    public init(id: String, name: String? = nil) {
        self.id = id
        hostName = Self.knownNames[id] == nil && AgentID.isValid(id) ? AgentID.displayName(name) : nil
    }

    public static let opencode = AgentProvider(id: "opencode")
    public static let claude = AgentProvider(id: "claude")
    public static let codex = AgentProvider(id: "codex")
    /// Every agent this version can name, in menu order.
    public static let known: [AgentProvider] = [.opencode, .claude, .codex]
    private static let knownNames = ["opencode": "OpenCode", "claude": "Claude Code", "codex": "Codex"]

    /// The known agents' names; the host's name for the others; the id itself when the host gave none; a
    /// neutral label for an id that is not a short plain token.
    public var displayName: String {
        Self.knownNames[id] ?? CatalogName.fallback(for: id, name: hostName, otherwise: "Unknown agent")
    }

    /// What Chat calls this agent: its `displayName`, Claude Code and Codex as Terminal names them (owner, 2026-10-12
    /// ~20:50, "Claude Code & Codex", replacing the Claude and ChatGPT of earlier that day).
    public var chatDisplayName: String { displayName }

    /// The title of a new chat: "New chat" for OpenCode, otherwise named after its agent ("Claude Code chat", "Gemini
    /// CLI chat"), which the host counts as a default title and names the chat from its first request. When that is
    /// longer than the host takes (`HostTitle`: a long name outside Latin scripts), none: the host then gives
    /// the chat its agent's name as the default title, where a cut title would count as a chosen one.
    public var newChatTitle: String {
        let title = self == .opencode ? "New chat" : chatDisplayName + " chat"
        return HostTitle.fits(title) ? title : ""
    }

    /// The provider named when creating a session. OpenCode is the host's default and is sent as no
    /// provider, which every host version accepts.
    public var requestValue: String? { self == .opencode ? nil : id }

    /// One of AgentLand's own adapters (OpenCode, Claude Code, Codex). Every other agent's chats run
    /// through the Agent Client Protocol (its `chatProviderInfo` transport is `acp`).
    public var isNative: Bool { Self.knownNames[id] != nil }

    /// Continue with another model offers a mode and an effort for a new chat of this agent: AgentLand's own
    /// agents only. An ACP agent's new chat lists no modes yet (docs/HOST-API.md "Continue with another
    /// model").
    public var continueTakesModeAndEffort: Bool { isNative }

    /// What Continue sends for a new chat of this agent (docs/HOST-API.md "Continue with another model"):
    /// AgentLand's own agents take the model, mode and effort chosen; an ACP agent takes `<id>/default` or no
    /// model, and no mode or effort, since the host answers anything else with 400 `invalid_agent_options`.
    public func continueSettings(model: String?, mode: String?, effort: String?) -> (model: String?, mode: String?, effort: String?) {
        guard !continueTakesModeAndEffort else { return (model, mode, effort) }
        return (model == id + "/default" ? model : nil, nil, nil)
    }

    /// The agents to offer for a host, each once: OpenCode always, then the known agents the host lists (in
    /// menu order), then the others it lists in its order, with its names: its catalog's chat agents, then
    /// the rest of `chatProviders`. The catalog's agents other than AgentLand's own chat through ACP, so they
    /// are offered only by hosts that list `acp` in `capabilities.agents`. Ids that are not short plain
    /// tokens are left out.
    public static func offered(by capabilities: CapabilitiesResponse?) -> [AgentProvider] {
        let catalog = capabilities?.agentCatalog ?? []
        let acp = capabilities?.supportsAgents(.acp) == true
        let chats = catalog.filter { $0.chat && (acp || knownNames[$0.id] != nil) }.map(\.id)
        let listed = chats + (capabilities?.chatProviders ?? [])
        var offered = known.filter { $0 == .opencode || listed.contains($0.id) }
        for id in listed where AgentID.isValid(id) && !offered.contains(where: { $0.id == id }) {
            offered.append(AgentProvider(id: id, name: catalog.first { $0.id == id }?.name))
        }
        return offered
    }

    /// The agent the host calls `id`, with its name when the host's catalog has one: for chats whose
    /// provider comes from the host (its sessions, the chat's snapshot, the archive).
    public static func named(_ id: String, by capabilities: CapabilitiesResponse?) -> AgentProvider {
        AgentProvider(id: id, name: capabilities?.agentCatalog?.first { $0.id == id }?.name)
    }

    /// The program that opens this agent in a terminal, when the host offers one: its id among the host's
    /// terminal programs (`claude-acp` is listed as `claude`, `codex-acp` as `codex`).
    public func terminalProgram(offeredBy capabilities: CapabilitiesResponse?) -> TerminalProgram? {
        TerminalProgram.offered(by: capabilities).first { $0.id == id && $0 != .shell }
    }
}

enum CatalogName {
    /// An id this version cannot name shows the host's name, or itself when it is a short plain token;
    /// anything else the host sends gets the neutral label.
    static func fallback(for id: String, name: String?, otherwise label: String) -> String {
        guard AgentID.isValid(id) else { return label }
        return name ?? id
    }
}
