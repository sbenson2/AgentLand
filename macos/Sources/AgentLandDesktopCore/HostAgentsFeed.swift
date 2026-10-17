import Foundation
import AgentLandCore

/// One agent of the host's `GET /v1/agents` (docs/AGENT-CATALOG-PLAN.md "Host contract"), as far as the
/// Mac app reads it. A field of the wrong type reads as absent.
public struct HostAgentStatus: Decodable, Equatable, Sendable {
    public let id: String
    public let source: String?
    public let state: String?
    public let installedVersion: String?
    public let latestVersion: String?
    public let lastError: String?
    /// On `opencode`, for the Mac's local session only: a managed version newer than the running one is
    /// current, so a restart would run it.
    public let restartWanted: Bool?
    /// On `opencode`, for the Mac's local session only: how long nothing has run on the host (no open
    /// terminal, no running chat turn, no device viewing a chat).
    public let idleForSeconds: Double?

    public init(id: String, source: String? = nil, state: String? = nil, installedVersion: String? = nil,
                latestVersion: String? = nil, lastError: String? = nil, restartWanted: Bool? = nil, idleForSeconds: Double? = nil) {
        self.id = id
        self.source = source
        self.state = state
        self.installedVersion = installedVersion
        self.latestVersion = latestVersion
        self.lastError = lastError
        self.restartWanted = restartWanted
        self.idleForSeconds = idleForSeconds
    }

    enum CodingKeys: String, CodingKey {
        case id, source, state, installedVersion, latestVersion, lastError, restartWanted, idleForSeconds
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        source = try? container.decodeIfPresent(String.self, forKey: .source)
        state = try? container.decodeIfPresent(String.self, forKey: .state)
        installedVersion = try? container.decodeIfPresent(String.self, forKey: .installedVersion)
        latestVersion = try? container.decodeIfPresent(String.self, forKey: .latestVersion)
        lastError = try? container.decodeIfPresent(String.self, forKey: .lastError)
        restartWanted = try? container.decodeIfPresent(Bool.self, forKey: .restartWanted)
        idleForSeconds = try? container.decodeIfPresent(Double.self, forKey: .idleForSeconds)
    }
}

/// The host's agent catalog. Entries that do not decode (no `id`) are skipped.
public struct HostAgentsCatalog: Decodable, Equatable, Sendable {
    public let agents: [HostAgentStatus]

    /// OpenCode's entry, which carries the restart fields for the local session.
    public var openCode: HostAgentStatus? { agents.first { $0.id == "opencode" } }

    public init(agents: [HostAgentStatus]) { self.agents = agents }

    enum CodingKeys: String, CodingKey { case agents }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        agents = (try container.decodeIfPresent([Lossy<HostAgentStatus>].self, forKey: .agents) ?? []).compactMap(\.value)
    }
}

/// Decodes one element of an array, or nothing, without failing the array.
struct Lossy<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: any Decoder) throws { value = try? Value(from: decoder) }
}

/// A version that did not start on this Mac, for the host (`POST /v1/agents/opencode/failed`).
public struct OpenCodeFailureReport: Equatable, Sendable {
    public let version: String
    /// A short reason, for the host's `lastError`.
    public let reason: String

    public init(version: String, reason: String) {
        self.version = version
        self.reason = reason
    }
}

/// The host's answer to a failed OpenCode version: whether it went back to the version it keeps, and the
/// version now current (empty when none is).
public struct OpenCodeFailureAnswer: Decodable, Equatable, Sendable {
    public let rolledBack: Bool
    public let current: String

    public init(rolledBack: Bool, current: String) {
        self.rolledBack = rolledBack
        self.current = current
    }

    enum CodingKeys: String, CodingKey { case rolledBack, current }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rolledBack = (try? container.decodeIfPresent(Bool.self, forKey: .rolledBack)) ?? false
        current = (try? container.decodeIfPresent(String.self, forKey: .current)) ?? ""
    }
}

/// Reads the host's agent catalog, and tells it about an OpenCode version that did not start.
public protocol HostAgentsReading: Sendable {
    func agents() async throws -> HostAgentsCatalog
    /// `POST /v1/agents/opencode/failed` (the local session only): when `version` is the current managed
    /// OpenCode, the host goes back to the previous version it keeps; it skips `version` in automatic
    /// updates until the registry offers another, and sets the `opencode` entry's `lastError`.
    func reportOpenCodeFailure(version: String, reason: String) async throws -> OpenCodeFailureAnswer
}

/// `GET /v1/agents` over HTTPS with the Mac app's local session, which alone gets the `opencode` entry's
/// restart fields and may report a failed OpenCode. Like `HostNoticeFeed`, `transport` must pin the host's
/// certificate.
public struct HostAgentsFeed: HostAgentsReading {
    /// The catalog lists about 40 agents; an answer past this is refused.
    public static let maximumBytes = 4 << 20
    /// The reason a report carries, at most.
    static let maximumReasonCharacters = 500

    private let baseURL: URL
    private let token: String
    private let transport: any APITransport

    public init(baseURL: URL, token: String, transport: any APITransport) {
        self.baseURL = baseURL
        self.token = token
        self.transport = transport
    }

    public func agents() async throws -> HostAgentsCatalog {
        var request = URLRequest(url: baseURL.appending(path: "/v1/agents"))
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20
        let (data, response) = try await transport.execute(request)
        guard response.statusCode == 200 else {
            if let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data) {
                throw ClientError.server(code: envelope.error.code, message: envelope.error.message)
            }
            throw ClientError.unexpectedStatus(response.statusCode)
        }
        guard data.count <= Self.maximumBytes else { throw ClientError.invalidResponse }
        do { return try JSONDecoder().decode(HostAgentsCatalog.self, from: data) } catch { throw ClientError.decoding }
    }

    public func reportOpenCodeFailure(version: String, reason: String) async throws -> OpenCodeFailureAnswer {
        var request = URLRequest(url: baseURL.appending(path: "/v1/agents/opencode/failed"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "version": version, "reason": String(reason.prefix(Self.maximumReasonCharacters))
        ], options: [.sortedKeys])
        let (data, response) = try await transport.execute(request)
        guard response.statusCode == 200 else {
            if let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data) {
                throw ClientError.server(code: envelope.error.code, message: envelope.error.message)
            }
            throw ClientError.unexpectedStatus(response.statusCode)
        }
        guard data.count <= 64 * 1024 else { throw ClientError.invalidResponse }
        do { return try JSONDecoder().decode(OpenCodeFailureAnswer.self, from: data) } catch { throw ClientError.decoding }
    }

    private struct ErrorEnvelope: Decodable { struct Body: Decodable { let code: String; let message: String }; let error: Body }

    /// Whether an error of `agents()` says the host has no agent catalog: a host from before it answers
    /// 404 `not_found`, one started with `--no-agents` 501 `agents_unavailable` (docs/HOST-API.md
    /// "Agents"). Such a host never says when it is idle; other failures are worth asking again.
    public static func meansNoCatalog(_ error: any Error) -> Bool {
        switch error as? ClientError {
        case .unexpectedStatus(404)?, .unexpectedStatus(501)?,
             .server(code: "not_found", _)?, .server(code: "agents_unavailable", _)?:
            true
        default:
            false
        }
    }
}

/// When the Mac app restarts its OpenCode, and the host with it, on its own (docs/AGENT-CATALOG-PLAN.md
/// "OpenCode", "The Mac app"). While its host runs, the app reads `GET /v1/agents` every `pollInterval`,
/// and at once after a provider key or the default model changes. It restarts only for what a restart
/// applies, and only while the host's `opencode` entry says nothing runs:
///
/// - `settings`: provider keys or the default model changed since OpenCode started. It restarts as soon
///   as nothing runs (a positive `idleForSeconds`).
/// - `update`: the host asks for it (`restartWanted`) and a start would run another managed OpenCode than
///   the one running (`ManagedOpenCodeRuntime.restartWouldChangeBinary()`), so a version that failed to
///   start or fails the checks never restarts it again and again. It waits until nothing has run for
///   `idleSeconds`, unless a restart for settings comes first: every start runs the newest OpenCode.
///
/// A host that does not report `idleForSeconds` is never idle: what waits then applies at the next start.
public enum OpenCodeRestartPolicy {
    public static let idleSeconds: Double = 600
    public static let pollInterval: Duration = .seconds(300)

    public enum Reason: String, Hashable, Sendable {
        case update
        case settings
    }

    public enum Decision: Equatable, Sendable {
        /// Nothing to apply.
        case nothing
        /// Something to apply once nothing runs (settings) or nothing has run for `idleSeconds` (a new version).
        case waitForIdle
        case restart(Set<Reason>)
    }

    /// Whether the host says nothing has run for `idleSeconds`.
    public static func isIdle(_ entry: HostAgentStatus?) -> Bool {
        guard let idle = entry?.idleForSeconds, idle.isFinite else { return false }
        return idle >= idleSeconds
    }

    /// Whether the host says nothing runs now: no open terminal, no running chat turn, no device viewing
    /// a chat (`idleForSeconds` is 0 while something does).
    public static func isQuiet(_ entry: HostAgentStatus?) -> Bool {
        guard let idle = entry?.idleForSeconds, idle.isFinite else { return false }
        return idle > 0
    }

    /// Whether to ask the runtime about the host's program, which reads and hashes it: only while the
    /// host asks for a restart and one would come now (it has been idle, or changed settings restart it).
    public static func shouldCheckBinary(_ entry: HostAgentStatus?, settingsPending: Bool = false) -> Bool {
        entry?.restartWanted == true && (isIdle(entry) || (settingsPending && isQuiet(entry)))
    }

    public static func decide(entry: HostAgentStatus?, settingsPending: Bool, binaryWouldChange: Bool) -> Decision {
        let updateWanted = entry?.restartWanted == true
        let settingsNow = settingsPending && isQuiet(entry)
        var reasons = Set<Reason>()
        if updateWanted && binaryWouldChange && (isIdle(entry) || settingsNow) { reasons.insert(.update) }
        if settingsNow { reasons.insert(.settings) }
        if !reasons.isEmpty { return .restart(reasons) }
        return settingsPending || (updateWanted && !isIdle(entry)) ? .waitForIdle : .nothing
    }
}
