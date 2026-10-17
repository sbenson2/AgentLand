import Foundation
import AgentLandCore

/// The keeper's state as `GET /v1/terminals/all` reports it: `running`, `none` (no keeper runs, its
/// terminals are gone) or `unavailable` (with a short reason). Other values decode as they come.
public struct KeeperState: Decodable, Sendable, Equatable {
    public let state: String
    public let reason: String?
    /// Whether a running keeper takes routed agents' terminals. False: a keeper from an AgentLand before that, still
    /// holding terminals, so routing starts once they have ended. Nil when the host doesn't say (an older host, or no
    /// running keeper): nothing is known, so nothing is shown.
    public let adopts: Bool?

    public init(state: String, reason: String? = nil, adopts: Bool? = nil) {
        self.state = state
        self.reason = reason
        self.adopts = adopts
    }

    private enum CodingKeys: String, CodingKey { case state, reason, adopts }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = try c.decode(String.self, forKey: .state)
        reason = try? c.decodeIfPresent(String.self, forKey: .reason)
        adopts = (try? c.decodeIfPresent(Bool.self, forKey: .adopts)) ?? nil
    }
}

/// One terminal as the Mac lists it (docs/HOST-API.md "Mac-only terminal routes", `MacTerminal`).
public struct HostTerminal: Decodable, Sendable, Identifiable, Equatable {
    public let id: String
    public let deviceId: String
    public let deviceName: String
    public let deviceRemoved: Bool
    public let projectId: String
    public let workspace: String
    public let program: String
    public let title: String
    public let status: String
    public let startedAt: Date
    public let endedAt: Date?
    public let reason: String?
    /// A coding agent typed in Terminal.app that AgentLand's terminals took in (`terminals run`); false from a host
    /// before that.
    public let routed: Bool
    /// What the Mac's naming of every terminal reads (`HostTerminalNaming`): the size a device last gave the terminal
    /// (nil while the host knows none, and from a host before naming), the cursor after its newest output (0 from such
    /// a host) and where its name came from (`program` or `device`; nil before it has one).
    public let rows: Int?
    public let cols: Int?
    public let cursor: UInt64
    public let contextTitleSource: String?

    public init(id: String, deviceId: String, deviceName: String, deviceRemoved: Bool = false, projectId: String = "",
                workspace: String = "", program: String = "", title: String = "", status: String,
                startedAt: Date, endedAt: Date? = nil, reason: String? = nil, routed: Bool = false,
                rows: Int? = nil, cols: Int? = nil, cursor: UInt64 = 0, contextTitleSource: String? = nil) {
        self.id = id; self.deviceId = deviceId; self.deviceName = deviceName; self.deviceRemoved = deviceRemoved
        self.projectId = projectId; self.workspace = workspace; self.program = program; self.title = title
        self.status = status; self.startedAt = startedAt; self.endedAt = endedAt; self.reason = reason
        self.routed = routed
        self.rows = rows; self.cols = cols; self.cursor = cursor; self.contextTitleSource = contextTitleSource
    }

    enum CodingKeys: String, CodingKey {
        case id, deviceId, deviceName, deviceRemoved, projectId, workspace, program, title, status, startedAt, endedAt, reason
        case routed, rows, cols, cursor, contextTitleSource
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        deviceId = (try? c.decode(String.self, forKey: .deviceId)) ?? ""
        deviceName = (try? c.decode(String.self, forKey: .deviceName)) ?? ""
        deviceRemoved = (try? c.decode(Bool.self, forKey: .deviceRemoved)) ?? false
        projectId = (try? c.decode(String.self, forKey: .projectId)) ?? ""
        workspace = (try? c.decode(String.self, forKey: .workspace)) ?? ""
        program = (try? c.decode(String.self, forKey: .program)) ?? ""
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        status = (try? c.decode(String.self, forKey: .status)) ?? ""
        startedAt = try Self.date(c.decode(String.self, forKey: .startedAt), in: c, key: .startedAt)
        if let text = try? c.decodeIfPresent(String.self, forKey: .endedAt), !text.isEmpty {
            endedAt = try Self.date(text, in: c, key: .endedAt)
        } else {
            endedAt = nil
        }
        reason = try? c.decodeIfPresent(String.self, forKey: .reason)
        routed = (try? c.decode(Bool.self, forKey: .routed)) ?? false
        rows = (try? c.decodeIfPresent(Int.self, forKey: .rows)).flatMap { $0 }
        cols = (try? c.decodeIfPresent(Int.self, forKey: .cols)).flatMap { $0 }
        cursor = (try? c.decode(UInt64.self, forKey: .cursor)) ?? 0
        contextTitleSource = (try? c.decodeIfPresent(String.self, forKey: .contextTitleSource)).flatMap { $0 }
    }

    /// RFC 3339 UTC, with or without fractional seconds.
    static func parse(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? plain.date(from: text)
    }

    private static func date(_ text: String, in c: KeyedDecodingContainer<CodingKeys>, key: CodingKeys) throws -> Date {
        guard let date = parse(text) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: c, debugDescription: "not an RFC 3339 time")
        }
        return date
    }
}

/// `GET /v1/terminals/all`.
public struct HostTerminalList: Decodable, Sendable {
    public let keeper: KeeperState
    public let terminals: [HostTerminal]

    public init(keeper: KeeperState, terminals: [HostTerminal]) {
        self.keeper = keeper
        self.terminals = terminals
    }
}

/// `GET /v1/terminals/running`: the terminals running across all devices, and how many of them are coding agents typed
/// in Terminal.app (`routed`, 0 from a host before those), which ending them all leaves running in their windows.
public struct HostRunningCount: Equatable, Sendable, Decodable {
    public let running: Int
    public let routed: Int

    public init(running: Int, routed: Int = 0) {
        self.running = running
        self.routed = routed
    }

    enum CodingKeys: String, CodingKey { case running, routed }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        running = try c.decode(Int.self, forKey: .running)
        routed = (try? c.decode(Int.self, forKey: .routed)) ?? 0
    }
}

/// What the Quit question answers.
public enum QuitTerminalsChoice: Sendable { case keepRunning, endTerminals, cancel }

/// The Quit question's words.
public enum QuitText {
    public static let title = "Keep terminals running?"
    public static let keep = "Keep Running"
    public static let end = "End Terminals"
    /// Said wherever AgentLand's terminals may end while agents typed in Terminal run: those stay in their windows. The
    /// Advanced switch's question says it too (`AdvancedText.agentsKeepRunning`).
    public static let agentsKeepRunning = "Agents open in Terminal keep running there."

    /// `routed`: how many of the `count` running are agents typed in Terminal.
    public static func message(_ count: Int, routed: Int = 0) -> String {
        let running = count == 1 ? "1 terminal is running on this Mac." : "\(count) terminals are running on this Mac."
        let message = running + " They can keep running after AgentLand quits; you’ll find them when it starts again."
        return routed > 0 ? message + " " + agentsKeepRunning : message
    }
}

/// The host's Mac-only terminal routes, which only this Mac's own session may use.
public protocol HostTerminalsReading: Sendable {
    func list() async throws -> HostTerminalList
    /// Running terminals across all devices, and the agents typed in Terminal among them, answered within `within`
    /// seconds or not at all.
    func runningCount(within: TimeInterval) async throws -> HostRunningCount
    /// Ends every running terminal (the host takes up to 10 s); how many ended.
    func endAll() async throws -> Int
    func end(terminalID: String) async throws
    func clear(terminalID: String) async throws
    /// Ends and forgets all of a device's terminals; how many were running.
    func endDevice(_ deviceID: String) async throws -> Int
}

/// The routes over HTTPS with the Mac app's local session. Like `HostAgentsFeed`, `transport` must pin
/// the host's certificate. A host with terminals off answers 403 `terminal_disabled`.
public struct HostTerminalsFeed: HostTerminalsReading {
    public static let maximumBytes = 4 << 20

    private let baseURL: URL
    private let token: String
    private let transport: any APITransport

    public init(baseURL: URL, token: String, transport: any APITransport) {
        self.baseURL = baseURL
        self.token = token
        self.transport = transport
    }

    public func list() async throws -> HostTerminalList {
        try decode(HostTerminalList.self, from: try await send("GET", "/v1/terminals/all", timeout: 20))
    }

    public func runningCount(within: TimeInterval) async throws -> HostRunningCount {
        try decode(HostRunningCount.self, from: try await send("GET", "/v1/terminals/running", timeout: within))
    }

    public func endAll() async throws -> Int {
        try decode(Ended.self, from: try await send("POST", "/v1/terminals/end-all", body: [:], timeout: 15)).ended
    }

    public func end(terminalID: String) async throws {
        _ = try await send("POST", "/v1/terminals/end", body: ["terminalId": terminalID], timeout: 20)
    }

    public func clear(terminalID: String) async throws {
        _ = try await send("POST", "/v1/terminals/clear", body: ["terminalId": terminalID], timeout: 20)
    }

    /// Waits longer than the host, which bounds ending a device's terminals at 20 s.
    public func endDevice(_ deviceID: String) async throws -> Int {
        try decode(Ended.self, from: try await send("POST", "/v1/terminals/end-device", body: ["deviceId": deviceID], timeout: 25)).ended
    }

    /// Whether `error` says terminals are off on the host (403 `terminal_disabled`).
    public static func meansTerminalsOff(_ error: any Error) -> Bool {
        if case .server(code: "terminal_disabled", _)? = error as? ClientError { return true }
        return false
    }

    private struct Ended: Decodable { let ended: Int }

    private func send(_ method: String, _ path: String, body: [String: String]? = nil, timeout: TimeInterval) async throws -> Data {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.timeoutInterval = timeout
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        }
        let (data, response) = try await transport.execute(request)
        guard response.statusCode == 200 else {
            if let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data) {
                throw ClientError.server(code: envelope.error.code, message: envelope.error.message)
            }
            throw ClientError.unexpectedStatus(response.statusCode)
        }
        guard data.count <= Self.maximumBytes else { throw ClientError.invalidResponse }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) } catch { throw ClientError.decoding }
    }

    private struct ErrorEnvelope: Decodable { struct Body: Decodable { let code: String; let message: String }; let error: Body }
}
