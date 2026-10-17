import Foundation

// Agents (docs/AGENT-CATALOG-PLAN.md, "Host contract"): the CLI agents a host runs, from the Agent Client
// Protocol registry and from the Mac itself. Hosts list what they serve in `capabilities.agents` and the
// agents that can be used now in `capabilities.agentCatalog`. Installs, updates and uninstalls run on the
// host in the background: the route answers 202 and `GET /v1/agents` shows how the work goes. Nothing here
// retries: a change whose answer was lost is reported as not confirmed, and the caller reads the list again.

/// An agent feature a host lists in `capabilities.agents`.
public enum AgentFeature: String, Sendable, CaseIterable {
    /// `GET /v1/agents` and `GET /v1/agents/icon`: every agent with its state.
    case catalog
    /// `POST /v1/agents/install`, `/uninstall` and `/update`.
    case install
    /// Chats of registry agents over the Agent Client Protocol.
    case acp
    /// Host-wide automatic CLI update policy.
    case updateSettings
}

/// Agent ids and the names hosts give them. The limits are the host's (docs/HOST-API.md "The registry"), so
/// everything a host lists fits.
public enum AgentID {
    /// The longest id the apps accept: the host's 64.
    public static let maximumLength = 64
    /// The longest name the apps show, the host's 100; a longer one is cut and ends with "…".
    public static let maximumNameLength = 100

    /// The host's rule for every agent id (`agentIDPattern` in desktop/agents_registry.go): 1–64 lowercase
    /// ASCII letters, digits, `.`, `_` and `-`, starting with a letter or digit, and not ending in `.json`.
    /// Anything else a host sends is never offered, sent or shown as a name.
    public static func isValid(_ id: String) -> Bool {
        let bytes = id.utf8
        guard (1...maximumLength).contains(bytes.count), let first = bytes.first, isLowercaseLetterOrDigit(first) else { return false }
        return bytes.allSatisfy { isLowercaseLetterOrDigit($0) || $0 == UInt8(ascii: ".") || $0 == UInt8(ascii: "_") || $0 == UInt8(ascii: "-") }
            && !id.hasSuffix(".json")
    }

    private static func isLowercaseLetterOrDigit(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
    }

    /// A name the host sent, as the apps show it: control characters dropped, runs of white space made one
    /// space, the ends trimmed and at most 100 characters. Nil when nothing is left.
    public static func displayName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let text = HostText.line(raw, limit: maximumNameLength)
        return text.isEmpty ? nil : text
    }
}

/// Text from the host, bounded before it is shown.
enum HostText {
    /// One line: control and formatting characters dropped (bidirectional overrides among them, so a name
    /// cannot read backwards), runs of white space (line breaks too) made one space, the ends trimmed, and
    /// cut to `limit` characters with "…".
    static func line(_ raw: String, limit: Int) -> String {
        var out = String.UnicodeScalarView()
        var gap = false
        for scalar in raw.unicodeScalars {
            if scalar.properties.isWhitespace {
                gap = true
                continue
            }
            switch scalar.properties.generalCategory {
            case .control, .format: continue
            default: break
            }
            if gap, !out.isEmpty { out.append(" ") }
            gap = false
            out.append(scalar)
        }
        return capped(String(out), limit: limit)
    }

    /// Paragraphs: control characters other than line breaks dropped, blank lines kept to one, the ends
    /// trimmed, and cut to `limit` characters with "…".
    static func text(_ raw: String, limit: Int) -> String {
        let lines = raw.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
            .map { line(String($0), limit: limit) }
        var kept: [String] = []
        for line in lines where !(line.isEmpty && (kept.last?.isEmpty ?? true)) { kept.append(line) }
        while kept.last?.isEmpty == true { kept.removeLast() }
        return capped(kept.joined(separator: "\n"), limit: limit)
    }

    private static func capped(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

// MARK: Capabilities

/// One agent of `capabilities.agentCatalog`: an agent that can be used now (installed, or found on the Mac),
/// so New Chat and New Terminal list it without another request.
public struct AgentCatalogEntry: Codable, Hashable, Identifiable, Sendable {
    /// At most this many entries are kept.
    public static let maximumEntries = 256

    public let id: String
    /// The host's name for it, bounded for display; the id when the host gave none.
    public let name: String
    /// It runs chats.
    public let chat: Bool
    /// It has a program for a terminal tab.
    public let terminal: Bool

    /// Nil when `id` is not a short plain token (`AgentID.isValid`).
    public init?(id: String, name: String? = nil, chat: Bool, terminal: Bool) {
        guard AgentID.isValid(id) else { return nil }
        self.id = id
        self.name = AgentID.displayName(name) ?? id
        self.chat = chat
        self.terminal = terminal
    }

    enum CodingKeys: String, CodingKey { case id, name, chat, terminal }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let entry = AgentCatalogEntry(id: try container.decode(String.self, forKey: .id),
                                            name: (try? container.decodeIfPresent(String.self, forKey: .name)).flatMap { $0 },
                                            chat: (try? container.decodeIfPresent(Bool.self, forKey: .chat)).flatMap { $0 } ?? false,
                                            terminal: (try? container.decodeIfPresent(Bool.self, forKey: .terminal)).flatMap { $0 } ?? false)
        else { throw DecodingError.dataCorruptedError(forKey: .id, in: container, debugDescription: "Not an agent id") }
        self = entry
    }

    /// Reads the list, leaving out entries this version cannot read and later entries for an id already
    /// listed, keeping at most `maximumEntries`; nil when the key is absent or is not a list.
    static func decodeList<Key: CodingKey>(from container: KeyedDecodingContainer<Key>, forKey key: Key) -> [AgentCatalogEntry]? {
        guard container.contains(key), var list = try? container.nestedUnkeyedContainer(forKey: key) else { return nil }
        var entries: [AgentCatalogEntry] = []
        while !list.isAtEnd && entries.count < maximumEntries {
            if let entry = try? list.decode(AgentCatalogEntry.self) {
                if !entries.contains(where: { $0.id == entry.id }) { entries.append(entry) }
            } else if (try? list.decode(Discarded.self)) == nil {
                break
            }
        }
        return entries
    }
}

/// Decodes any list element, to step over one this version cannot read.
struct Discarded: Decodable {
    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(), container.decodeNil() { return }
        if (try? decoder.singleValueContainer().decode(String.self)) != nil { return }
        if (try? decoder.singleValueContainer().decode(Double.self)) != nil { return }
        if (try? decoder.singleValueContainer().decode(Bool.self)) != nil { return }
        if (try? decoder.container(keyedBy: AnyKey.self)) != nil { return }
        _ = try decoder.unkeyedContainer()
    }
    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int?
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { self.stringValue = String(intValue); self.intValue = intValue }
    }
}

public extension CapabilitiesResponse {
    /// An agent feature. Hosts without `agents` claim none.
    func supportsAgents(_ feature: AgentFeature) -> Bool { agents.contains(feature.rawValue) }
}

// MARK: The catalog

/// Where an agent comes from, and so who updates it.
public enum AgentSource: Hashable, Sendable {
    /// From the ACP registry: AgentLand installs and updates it.
    case registry
    /// Found on the Mac: its own installer or updater keeps it current. The host may run its native updater.
    case local
    /// An older host's OpenCode from inside the Mac app, until a managed one took over. Hosts no longer send
    /// it (they list OpenCode as a registry agent); it is still read for the older ones.
    case bundled
    /// A source this version does not know, as the host sent it.
    case other(String)

    init(raw: String) {
        switch raw {
        case "registry": self = .registry
        case "local": self = .local
        case "bundled": self = .bundled
        default: self = .other(raw)
        }
    }

    public var rawValue: String {
        switch self {
        case .registry: "registry"
        case .local: "local"
        case .bundled: "bundled"
        case let .other(raw): raw
        }
    }
}

/// What the host is doing with an agent.
public enum AgentState: Hashable, Sendable {
    case notInstalled, installing, installed, updating, failed
    /// An uninstall runs on the host: the agent is still there until it ends. Hosts before this state
    /// show an uninstall only by the agent going.
    case uninstalling
    /// A state this version does not know, as the host sent it.
    case other(String)

    init(raw: String) {
        switch raw {
        case "notInstalled": self = .notInstalled
        case "installing": self = .installing
        case "installed": self = .installed
        case "updating": self = .updating
        case "uninstalling": self = .uninstalling
        case "failed": self = .failed
        default: self = .other(raw)
        }
    }

    public var rawValue: String {
        switch self {
        case .notInstalled: "notInstalled"
        case .installing: "installing"
        case .installed: "installed"
        case .updating: "updating"
        case .uninstalling: "uninstalling"
        case .failed: "failed"
        case let .other(raw): raw
        }
    }

    /// An install, update or uninstall runs on the host now.
    public var isRunning: Bool { self == .installing || self == .updating || self == .uninstalling }
}

/// One agent of `GET /v1/agents`. Paths, commands and environments never leave the host; text fields are
/// bounded before they are shown, at the host's own limits.
public struct AgentInfo: Codable, Hashable, Identifiable, Sendable {
    /// The longest license name kept, as the host's registry check keeps it.
    public static let maximumLicenseLength = 100
    /// The longest `lastError` kept: the host cuts it to 1000 bytes.
    public static let maximumErrorLength = 1_000
    /// The longest description kept, as the host cuts it.
    public static let maximumDescriptionLength = 1_000

    public let id: String
    /// The registry's name, or the id when the host gave none.
    public let name: String
    public let description: String?
    /// The agent's own website, as the registry lists it.
    public let website: String?
    /// Its license's SPDX name, such as "Apache-2.0".
    public let license: String?
    public let source: AgentSource
    public let state: AgentState
    public let installedVersion: String?
    public let latestVersion: String?
    public let previousVersion: String?
    /// When it was last installed or updated; for a local CLI, when its native updater last succeeded.
    public let updatedAt: Date?
    /// Why the last install, update or check failed; present only after a failure.
    public let lastError: String?
    /// It can run chats.
    public let chat: Bool
    /// It has a program for a terminal tab.
    public let terminal: Bool
    /// Its download is checked against the registry's SHA-256, or it is a package pinned to its version.
    /// An unverified download installs only after the person confirms it (`allowUnverified`).
    public let verified: Bool
    /// The registry has something that runs on this Mac. The host sends `"supported": false` for a registry
    /// agent without one and leaves the field out otherwise; such an agent cannot be installed
    /// (`unsupported_platform`).
    public let supported: Bool
    /// The host schedules updates for this installed agent, including supported local CLI self-updaters.
    /// Older hosts omit it; local updates must be explicitly advertised.
    public let autoUpdates: Bool
    /// Native updater support, independent of policy; nil on older hosts.
    public let supportsUpdates: Bool?
    /// The Mac's local session only, on OpenCode's entry: a managed version newer than the running one is
    /// current, and how long nothing has run.
    public let restartWanted: Bool
    public let idleForSeconds: Int?
    /// How many running terminals an automatic update waits for (an in-place updater); nil when none, and on
    /// older hosts.
    public let updateWaitingTerminals: Int?

    public init(id: String, name: String, description: String? = nil, website: String? = nil, license: String? = nil,
                source: AgentSource = .registry, state: AgentState = .notInstalled, installedVersion: String? = nil,
                latestVersion: String? = nil, previousVersion: String? = nil, updatedAt: Date? = nil, lastError: String? = nil,
                chat: Bool = false, terminal: Bool = false, verified: Bool = false, supported: Bool = true, restartWanted: Bool = false,
                idleForSeconds: Int? = nil, autoUpdates: Bool = false, supportsUpdates: Bool? = nil, updateWaitingTerminals: Int? = nil) {
        self.id = id; self.name = name; self.description = description; self.website = website; self.license = license
        self.source = source; self.state = state; self.installedVersion = installedVersion; self.latestVersion = latestVersion
        self.previousVersion = previousVersion; self.updatedAt = updatedAt; self.lastError = lastError
        self.chat = chat; self.terminal = terminal; self.verified = verified; self.supported = supported
        self.restartWanted = restartWanted; self.idleForSeconds = idleForSeconds
        self.autoUpdates = autoUpdates
        self.supportsUpdates = supportsUpdates
        self.updateWaitingTerminals = updateWaitingTerminals
    }

    enum CodingKeys: String, CodingKey {
        case id, name, description, website, license, source, state, installedVersion, latestVersion, previousVersion
        case updatedAt, lastError, chat, terminal, verified, supported, restartWanted, idleForSeconds, autoUpdates, supportsUpdates, updateWaitingTerminals
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id)
        guard AgentID.isValid(id) else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: container, debugDescription: "Not an agent id")
        }
        // Everything but the id is read leniently: a field this version cannot read counts as absent.
        func text(_ key: CodingKeys) -> String? { (try? container.decodeIfPresent(String.self, forKey: key)).flatMap { $0 } }
        func flag(_ key: CodingKeys) -> Bool { (try? container.decodeIfPresent(Bool.self, forKey: key)).flatMap { $0 } ?? false }
        func version(_ key: CodingKeys) -> String? {
            text(key).map { HostText.line($0, limit: 64) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        self.id = id
        name = AgentID.displayName(text(.name)) ?? id
        description = text(.description).map { HostText.text($0, limit: Self.maximumDescriptionLength) }.flatMap { $0.isEmpty ? nil : $0 }
        website = text(.website).flatMap(AgentInfo.webAddress)
        license = text(.license).map { HostText.line($0, limit: Self.maximumLicenseLength) }.flatMap { $0.isEmpty ? nil : $0 }
        source = text(.source).map(AgentSource.init(raw:)) ?? .registry
        installedVersion = version(.installedVersion)
        latestVersion = version(.latestVersion)
        previousVersion = version(.previousVersion)
        state = text(.state).map(AgentState.init(raw:)) ?? (installedVersion == nil ? .notInstalled : .installed)
        updatedAt = text(.updatedAt).flatMap(AgentInfo.parseTime)
        lastError = text(.lastError).map { HostText.text($0, limit: Self.maximumErrorLength) }.flatMap { $0.isEmpty ? nil : $0 }
        chat = flag(.chat)
        terminal = flag(.terminal)
        verified = flag(.verified)
        // Left out when true: only an explicit false marks an agent this Mac cannot run.
        supported = (try? container.decodeIfPresent(Bool.self, forKey: .supported)).flatMap { $0 } ?? true
        restartWanted = flag(.restartWanted)
        autoUpdates = flag(.autoUpdates)
        supportsUpdates = (try? container.decodeIfPresent(Bool.self, forKey: .supportsUpdates)).flatMap { $0 }
        idleForSeconds = (try? container.decodeIfPresent(Int.self, forKey: .idleForSeconds)).flatMap { $0 }.map { max(0, $0) }
        updateWaitingTerminals = (try? container.decodeIfPresent(Int.self, forKey: .updateWaitingTerminals)).flatMap { $0 }.map { max(0, $0) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(website, forKey: .website)
        try container.encodeIfPresent(license, forKey: .license)
        try container.encode(source.rawValue, forKey: .source)
        try container.encode(state.rawValue, forKey: .state)
        try container.encodeIfPresent(installedVersion, forKey: .installedVersion)
        try container.encodeIfPresent(latestVersion, forKey: .latestVersion)
        try container.encodeIfPresent(previousVersion, forKey: .previousVersion)
        try container.encodeIfPresent(updatedAt.map { $0.formatted(.iso8601) }, forKey: .updatedAt)
        try container.encodeIfPresent(lastError, forKey: .lastError)
        try container.encode(chat, forKey: .chat)
        try container.encode(terminal, forKey: .terminal)
        try container.encode(verified, forKey: .verified)
        if !supported { try container.encode(false, forKey: .supported) }
        if restartWanted { try container.encode(true, forKey: .restartWanted) }
        try container.encode(autoUpdates, forKey: .autoUpdates)
        try container.encodeIfPresent(supportsUpdates, forKey: .supportsUpdates)
        try container.encodeIfPresent(idleForSeconds, forKey: .idleForSeconds)
        try container.encodeIfPresent(updateWaitingTerminals, forKey: .updateWaitingTerminals)
    }

    /// Installed on the host: a version is there, whatever runs on it now (an update, an uninstall that has
    /// not removed it yet, or a failed update).
    public var isInstalled: Bool {
        switch state {
        case .installed, .updating, .uninstalling: true
        case .notInstalled, .installing: false
        case .failed, .other: installedVersion != nil
        }
    }

    /// AgentLand owns its installation. Local CLI self-updates do not change installation ownership.
    public var isManaged: Bool { source == .registry }

    /// A registry install, or an installed local CLI whose host explicitly supports its native updater.
    public var canUpdate: Bool { isManaged || (source == .local && (supportsUpdates ?? autoUpdates) && isInstalled) }

    /// Uninstall is offered for it: a registry agent AgentLand keeps, except OpenCode, which AgentLand's own
    /// chats run on (the host refuses to uninstall it with `agent_required`). Update Now stays.
    public var canUninstall: Bool { isManaged && id != AgentProvider.opencode.id }

    /// On the Mac now, so Settings lists it under Installed. A registry agent when a version is installed
    /// (`isInstalled`). An agent found on the Mac, or an older host's OpenCode from inside the Mac app, only
    /// while its state says it is there: installed, updating, or installing while AgentLand installs its own
    /// copy of an agent already on the Mac. The host lists Claude Code and Codex as `local` and
    /// `notInstalled` when their commands are not on the Mac; those are not, and AgentLand cannot install
    /// them.
    public var isPresent: Bool {
        guard !isManaged else { return isInstalled }
        switch state {
        case .installed, .updating, .installing, .uninstalling: return true
        case .notInstalled: return false
        case .failed, .other: return installedVersion != nil
        }
    }

    /// The website's host without "www.", as a confirmation names the source ("cursor.com").
    public var websiteName: String? {
        guard let website, let host = URL(string: website)?.host(percentEncoded: false)?.lowercased(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// An `https` or `http` address without credentials, or nil.
    static func webAddress(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 2_048, let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              components.host?.isEmpty == false, components.user == nil, components.password == nil else { return nil }
        return trimmed
    }

    static func parseTime(_ value: String) -> Date? {
        (try? Date(value, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true)))
            ?? (try? Date(value, strategy: .iso8601))
    }
}

/// How the host's last read of the registry went.
public struct AgentRegistryStatus: Codable, Hashable, Sendable {
    public let fetchedAt: Date?
    /// Why the last read failed, when it did.
    public let error: String?

    public init(fetchedAt: Date? = nil, error: String? = nil) { self.fetchedAt = fetchedAt; self.error = error }

    enum CodingKeys: String, CodingKey { case fetchedAt, error }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fetchedAt = (try? container.decodeIfPresent(String.self, forKey: .fetchedAt)).flatMap { $0 }.flatMap(AgentInfo.parseTime)
        error = (try? container.decodeIfPresent(String.self, forKey: .error)).flatMap { $0 }
            .map { HostText.text($0, limit: 600) }.flatMap { $0.isEmpty ? nil : $0 }
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(fetchedAt.map { $0.formatted(.iso8601) }, forKey: .fetchedAt)
        try container.encodeIfPresent(error, forKey: .error)
    }
}

/// `GET /v1/agents`: every agent the host knows, with its state.
public struct AgentCatalog: Codable, Hashable, Sendable {
    /// At most this many agents are kept.
    public static let maximumAgents = 512

    public let registry: AgentRegistryStatus?
    public let agents: [AgentInfo]
    /// Absent on older hosts.
    public let automaticUpdates: Bool?

    public init(registry: AgentRegistryStatus? = nil, agents: [AgentInfo], automaticUpdates: Bool? = nil) {
        self.registry = registry
        self.agents = agents
        self.automaticUpdates = automaticUpdates
    }

    enum CodingKeys: String, CodingKey { case registry, agents, automaticUpdates }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        automaticUpdates = (try? container.decodeIfPresent(Bool.self, forKey: .automaticUpdates)).flatMap { $0 }
        registry = (try? container.decodeIfPresent(AgentRegistryStatus.self, forKey: .registry)).flatMap { $0 }
        // Agents this version cannot read are left out; the others still show. Not a list at all is an
        // answer this version cannot read.
        var list = try container.nestedUnkeyedContainer(forKey: .agents)
        var agents: [AgentInfo] = []
        while !list.isAtEnd && agents.count < Self.maximumAgents {
            if let agent = try? list.decode(AgentInfo.self) {
                if !agents.contains(where: { $0.id == agent.id }) { agents.append(agent) }
            } else if (try? list.decode(Discarded.self)) == nil {
                break
            }
        }
        self.agents = agents
    }

    /// The same catalog with `agent` in place of the entry of its id (added when it had none).
    public func replacing(_ agent: AgentInfo) -> AgentCatalog {
        var agents = self.agents
        if let index = agents.firstIndex(where: { $0.id == agent.id }) { agents[index] = agent } else { agents.append(agent) }
        return AgentCatalog(registry: registry, agents: agents, automaticUpdates: automaticUpdates)
    }
}

public struct AgentUpdateSettings: Codable, Hashable, Sendable {
    public let automaticUpdates: Bool
    public init(automaticUpdates: Bool) { self.automaticUpdates = automaticUpdates }
}

public enum AgentUpdateSettingsOutcome: Equatable, Sendable {
    case saved(Bool), uncertain, failed(ClientError)
}

// MARK: Changes

/// Why the host refused an install, update or uninstall.
public enum AgentRefusal: String, Sendable, CaseIterable {
    /// 404: no agent has that id (any more).
    case unknownAgent = "unknown_agent"
    /// 409: a chat turn or terminal of the agent runs now.
    case busy = "agent_busy"
    /// 409: an update or uninstall of an agent the Mac's own installer or the app keeps.
    case notManaged = "not_managed"
    /// 409: an uninstall of an agent AgentLand needs: OpenCode, which AgentLand's own chats run on.
    case required = "agent_required"
    /// 400: the registry has no download for this Mac.
    case unsupportedPlatform = "unsupported_platform"
    /// 400: a download without a SHA-256 to check, sent without `allowUnverified`.
    case unverifiedDownload = "unverified_download"
}

/// How an install, update or uninstall request ended.
public enum AgentChangeOutcome: Equatable, Sendable {
    /// 202: the host took it and works on it in the background; the agent as it answered, when this version
    /// could read it.
    case accepted(AgentInfo?)
    /// The host refused, with its words.
    case refused(AgentRefusal, message: String)
    /// Another refusal, or the request provably never reached the host.
    case failed(ClientError)
    /// The connection ended before an answer: the change may have started. The caller reads the list again
    /// rather than sending it again.
    case uncertain
}

/// An agent's icon as the host served it (`GET /v1/agents/icon`).
public struct AgentIconData: Equatable, Sendable {
    public let data: Data
    /// The media type the host named in `Content-Type` (`image/svg+xml` or `image/png`), lowercased and
    /// without parameters; nil when it named none.
    public let contentType: String?

    public init(data: Data, contentType: String?) {
        self.data = data
        self.contentType = contentType.flatMap(Self.mediaType)
    }

    /// The media type of a `Content-Type` value: "image/svg+xml; charset=utf-8" is "image/svg+xml".
    public static func mediaType(_ value: String) -> String? {
        let type = value.split(separator: ";", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        return type.isEmpty ? nil : type
    }
}

/// Error codes of the icon route.
public enum AgentIconErrorCode {
    /// 404: an unknown agent, or one without an icon; final while the host is attached.
    public static let notFound = "not_found"
    /// 503: the host could not fetch the icon in time; it is not missing, and is asked for again later.
    public static let unavailable = "icon_unavailable"
}

public extension ClientError {
    /// The host could not fetch the icon in time (503 `icon_unavailable`): not a missing icon; ask again later.
    var isIconUnavailable: Bool {
        switch self {
        case let .server(code, _): code == AgentIconErrorCode.unavailable
        case let .unexpectedStatus(status): status == 503
        default: false
        }
    }
}

/// Error codes of the agents' chats.
public enum AgentErrorCode {
    /// The agent needs a sign-in before it starts a session: open it in a terminal and follow its sign-in.
    public static let authRequired = "agent_auth_required"
}

public extension ClientError {
    /// The host said the chat's agent needs a sign-in (`agent_auth_required`).
    var isAgentAuthRequired: Bool {
        if case let .server(code, _) = self { return code == AgentErrorCode.authRequired }
        return false
    }
}

// MARK: Providers

/// One model provider OpenCode speaks, from `GET /v1/providers`. Keys never leave the Mac. Text is bounded at
/// the host's limits: ids of 128 and names of 200, and at most 16 key variables of up to 128 characters.
public struct ModelProvider: Codable, Hashable, Identifiable, Sendable {
    public static let maximumIDLength = 128
    public static let maximumNameLength = 200
    public static let maximumVariables = 16
    public static let maximumVariableLength = 128

    public let id: String
    public let name: String
    /// A key or sign-in is set up for it on the Mac.
    public let connected: Bool
    /// How many of its models OpenCode offers.
    public let models: Int
    /// The variables its key goes in, such as `ANTHROPIC_API_KEY`.
    public let env: [String]

    public init(id: String, name: String, connected: Bool, models: Int = 0, env: [String] = []) {
        self.id = id; self.name = name; self.connected = connected; self.models = models; self.env = env
    }

    enum CodingKeys: String, CodingKey { case id, name, connected, models, env }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = HostText.line(try container.decode(String.self, forKey: .id), limit: Self.maximumIDLength)
        guard !id.isEmpty else { throw DecodingError.dataCorruptedError(forKey: .id, in: container, debugDescription: "No provider id") }
        self.id = id
        let name = (try? container.decodeIfPresent(String.self, forKey: .name)).flatMap { $0 }
            .map { HostText.line($0, limit: Self.maximumNameLength) } ?? ""
        self.name = name.isEmpty ? id : name
        connected = (try? container.decodeIfPresent(Bool.self, forKey: .connected)).flatMap { $0 } ?? false
        models = max(0, (try? container.decodeIfPresent(Int.self, forKey: .models)).flatMap { $0 } ?? 0)
        env = ((try? container.decodeIfPresent([String].self, forKey: .env)).flatMap { $0 } ?? [])
            .prefix(Self.maximumVariables).map { HostText.line($0, limit: Self.maximumVariableLength) }.filter { !$0.isEmpty }
    }
}

/// `GET /v1/providers`.
struct ModelProvidersResponse: Decodable {
    static let maximumProviders = 512
    let providers: [ModelProvider]

    enum CodingKeys: String, CodingKey { case providers }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var list = try container.nestedUnkeyedContainer(forKey: .providers)
        var providers: [ModelProvider] = []
        while !list.isAtEnd && providers.count < Self.maximumProviders {
            if let provider = try? list.decode(ModelProvider.self) {
                if !providers.contains(where: { $0.id == provider.id }) { providers.append(provider) }
            } else if (try? list.decode(Discarded.self)) == nil {
                break
            }
        }
        self.providers = providers
    }
}

/// Error codes of the providers' route.
public enum ModelProviderErrorCode {
    /// 503: OpenCode did not answer on the Mac.
    public static let catalogUnavailable = "provider_catalog_unavailable"
}

// MARK: Routes

extension APIClient {
    /// The largest icon read: registry icons are small SVGs.
    public static let agentIconLimit = 256 << 10

    /// `GET /v1/agents`: every agent with its state.
    public func agents() async throws -> AgentCatalog { try await get("/v1/agents") }

    /// Saves once. A lost or unreadable answer is uncertain and is never replayed.
    public func setAgentAutomaticUpdates(_ enabled: Bool) async -> AgentUpdateSettingsOutcome {
        do {
            let value: AgentUpdateSettings = try await post("/v1/agents/settings", body: AgentUpdateSettings(automaticUpdates: enabled), expected: 200)
            return .saved(value.automaticUpdates)
        } catch let error as ClientError {
            if case let .failed(error) = mutationOutcome(for: error) { return .failed(error) }
            return .uncertain
        } catch { return ClientError.isUndelivered(error) ? .failed(.unreachable) : .uncertain }
    }

    /// `GET /v1/agents/icon?id=`: the registry icon the host keeps for `id` (SVG or a bitmap), at most
    /// `agentIconLimit` bytes, with the type the host named. Devices never ask the registry's CDN. A 404
    /// `not_found` means the agent has no icon; a 503 `icon_unavailable` that the host could not fetch it in
    /// time (`ClientError.isIconUnavailable`).
    public func agentIcon(id: String) async throws -> AgentIconData {
        try Task.checkCancellation()
        guard AgentID.isValid(id) else { throw ClientError.invalidResponse }
        var request = try makeRequest(path: "/v1/agents/icon", method: "GET", query: [URLQueryItem(name: "id", value: id)])
        request.setValue("image/svg+xml, image/png, image/*;q=0.8", forHTTPHeaderField: "Accept")
        let (data, response) = try await transport.execute(request)
        try validate(response, data: data, expected: 200)
        guard !data.isEmpty, data.count <= Self.agentIconLimit else { throw ClientError.invalidResponse }
        return AgentIconData(data: data, contentType: response.value(forHTTPHeaderField: "Content-Type"))
    }

    /// `POST /v1/agents/install`. `allowUnverified` goes out only when true, after the person confirmed a
    /// download the host cannot check.
    public func installAgent(id: String, allowUnverified: Bool = false) async -> AgentChangeOutcome {
        await agentChange("/v1/agents/install", body: AgentChangeBody(id: id, allowUnverified: allowUnverified ? true : nil))
    }

    /// `POST /v1/agents/update`: the latest version now, instead of at the next automatic update.
    /// `allowUnverified` goes out only when true, after the person confirmed that the update may switch the
    /// agent to a download the host cannot check.
    public func updateAgent(id: String, allowUnverified: Bool = false) async -> AgentChangeOutcome {
        await agentChange("/v1/agents/update", body: AgentChangeBody(id: id, allowUnverified: allowUnverified ? true : nil))
    }

    /// `POST /v1/agents/uninstall`.
    public func uninstallAgent(id: String) async -> AgentChangeOutcome {
        await agentChange("/v1/agents/uninstall", body: AgentChangeBody(id: id, allowUnverified: nil))
    }

    /// `GET /v1/providers`: the providers OpenCode speaks, whether each is connected, and how many models
    /// it offers. 503 `provider_catalog_unavailable` when OpenCode does not answer.
    public func modelProviders() async throws -> [ModelProvider] {
        let response: ModelProvidersResponse = try await get("/v1/providers")
        return response.providers
    }

    private func agentChange(_ path: String, body: AgentChangeBody) async -> AgentChangeOutcome {
        guard AgentID.isValid(body.id) else { return .failed(.invalidResponse) }
        do {
            var request = try makeRequest(path: path, method: "POST")
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let (data, response) = try await transport.execute(request)
            // The host took it (202); an answer this version cannot read still means the work began.
            if (200..<300).contains(response.statusCode) { return .accepted(try? ProtocolDecoder.decode(AgentInfo.self, from: data)) }
            try validateWithRefusal(response, data: data, expected: 202)
            return .uncertain
        } catch let refusal as HostRefusal {
            if let reason = AgentRefusal(rawValue: refusal.error.code), refusal.status < 500 {
                return .refused(reason, message: refusal.error.message)
            }
            // A server error may have started the work; a refusal it named did not.
            guard refusal.status < 500, case let .failed(error) = mutationOutcome(for: refusal.clientError) else { return .uncertain }
            return .failed(error)
        } catch let error as ClientError {
            if case let .failed(error) = mutationOutcome(for: error) { return .failed(error) }
            return .uncertain
        } catch is CancellationError {
            return .uncertain
        } catch {
            return ClientError.isUndelivered(error) ? .failed(.unreachable) : .uncertain
        }
    }

    private struct AgentChangeBody: Encodable {
        let id: String
        let allowUnverified: Bool?
    }
}
