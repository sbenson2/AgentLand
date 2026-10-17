import Foundation
import Network

public protocol APITransport: Sendable {
    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
    /// Streams a response line by line. `request.timeoutInterval` is the idle
    /// limit between received bytes, not a limit on the whole stream.
    func lines(_ request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, HTTPURLResponse)
    /// The same, failing the stream with `ClientError.invalidResponse` as soon
    /// as one line grows past `maxLineBytes` bytes (its newline excluded).
    func lines(_ request: URLRequest, maxLineBytes: Int) async throws -> (AsyncThrowingStream<String, Error>, HTTPURLResponse)
    /// Sends the file at `file` as the request body, with its length, reporting the bytes sent so far
    /// and the total as they go.
    func upload(_ request: URLRequest, fromFile file: URL,
                progress: @escaping @Sendable (_ sent: Int64, _ total: Int64) -> Void) async throws -> (Data, HTTPURLResponse)
}

public extension APITransport {
    func lines(_ request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, HTTPURLResponse) {
        throw URLError(.unsupportedURL)
    }

    /// Transports without upload progress send the file as the body and report it whole once answered.
    func upload(_ request: URLRequest, fromFile file: URL,
                progress: @escaping @Sendable (_ sent: Int64, _ total: Int64) -> Void) async throws -> (Data, HTTPURLResponse) {
        var request = request
        let body = try Data(contentsOf: file, options: .mappedIfSafe)
        request.httpBody = body
        request.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
        let answer = try await execute(request)
        progress(Int64(body.count), Int64(body.count))
        return answer
    }

    /// Transports that only split lines themselves still enforce the bound.
    func lines(_ request: URLRequest, maxLineBytes: Int) async throws -> (AsyncThrowingStream<String, Error>, HTTPURLResponse) {
        let (source, response) = try await lines(request)
        let bounded = AsyncThrowingStream<String, Error> { continuation in
            let reader = Task {
                do {
                    for try await line in source {
                        guard line.utf8.count <= maxLineBytes else { throw ClientError.invalidResponse }
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in reader.cancel() }
        }
        return (bounded, response)
    }
}

/// Splits a byte stream into lines, each at most `limit` bytes. A trailing
/// carriage return is dropped, as NDJSON over HTTP allows `\r\n`.
struct BoundedLineSplitter {
    let limit: Int
    private var buffer: [UInt8] = []
    init(limit: Int) { self.limit = limit; buffer.reserveCapacity(min(limit, 4096)) }

    /// Returns a completed line, or nil while the line continues.
    mutating func append(_ byte: UInt8) throws -> String? {
        if byte == 0x0A {
            if buffer.last == 0x0D { buffer.removeLast() }
            let line = String(decoding: buffer, as: UTF8.self)
            buffer.removeAll(keepingCapacity: true)
            return line
        }
        guard buffer.count < limit else { throw ClientError.invalidResponse }
        buffer.append(byte)
        return nil
    }

    /// The unterminated last line, if any.
    mutating func finish() -> String? {
        guard !buffer.isEmpty else { return nil }
        if buffer.last == 0x0D { buffer.removeLast() }
        defer { buffer.removeAll() }
        return String(decoding: buffer, as: UTF8.self)
    }
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let trust: PinnedTrustEvaluator
    init(trust: PinnedTrustEvaluator) { self.trust = trust }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let (disposition, credential) = trust.evaluate(challenge)
        completionHandler(disposition, credential)
    }
    /// Streaming tasks (`bytes(for:delegate:)`) receive server-trust challenges
    /// here rather than at session level. Without it, a stream that opens a
    /// fresh connection (after a host restart) falls back to system trust and
    /// rejects the paired certificate.
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let (disposition, credential) = trust.evaluate(challenge)
        completionHandler(disposition, credential)
    }
}

/// An upload's own delegate: the same certificate check and redirect refusal as the session's, and
/// the bytes sent as they go.
private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let trust: PinnedTrustEvaluator
    let progress: @Sendable (Int64, Int64) -> Void
    init(trust: PinnedTrustEvaluator, progress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.trust = trust; self.progress = progress
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64,
                    totalBytesExpectedToSend: Int64) {
        progress(totalBytesSent, totalBytesExpectedToSend)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let (disposition, credential) = trust.evaluate(challenge)
        completionHandler(disposition, credential)
    }
}

public final class URLSessionTransport: APITransport, @unchecked Sendable {
    private let redirectDelegate: NoRedirectDelegate
    private let session: URLSession
    /// The certificate check every request of this transport passes. The host's preview listener
    /// presents the same certificate, so the browser checks that origin with it too.
    public let serverTrust: PinnedTrustEvaluator

    public convenience init(expectedHost: String? = nil, certificateSHA256: String? = nil, validatedCertificateHost: String? = nil) {
        self.init(expectedHost: expectedHost, certificateSHA256: certificateSHA256, validatedCertificateHost: validatedCertificateHost,
                  configuration: .ephemeral)
    }

    /// A transport whose connections go through the phone's remote-access bridge (docs/HOST-API.md
    /// "The phone's bridge"): an HTTP CONNECT proxy on 127.0.0.1 at `bridge.port`, with the bridge's
    /// per-start secret as the credential URLSession sends after the bridge's 407. Requests still name
    /// the paired address: URLSession sends `CONNECT <paired host>:<port>` without resolving the name,
    /// and the TLS inside is the pinned TLS of every route. URLSession answers the 407 with the proxy
    /// configuration's credential on its own; the delegate never sees that challenge, so every challenge
    /// it sees gets the pinned check.
    public convenience init(expectedHost: String, certificateSHA256: String, validatedCertificateHost: String,
                            bridge: RemoteAccessBridgeAddress) {
        let configuration = URLSessionConfiguration.ephemeral
        let proxy = ProxyConfiguration(httpCONNECTProxy: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: bridge.port) ?? .any),
                                       tlsOptions: nil)
        proxy.applyCredential(username: RemoteAccessTunnel.Bridge.username, password: bridge.secret)
        configuration.proxyConfigurations = [proxy]
        self.init(expectedHost: expectedHost, certificateSHA256: certificateSHA256, validatedCertificateHost: validatedCertificateHost,
                  configuration: configuration)
    }

    /// `configuration` lets tests route requests through a stub `URLProtocol`.
    init(expectedHost: String?, certificateSHA256: String?, validatedCertificateHost: String?, configuration: URLSessionConfiguration) {
        let trust = PinnedTrustEvaluator(expectedHost: expectedHost, certificateSHA256: certificateSHA256,
                                         validatedCertificateHost: validatedCertificateHost)
        serverTrust = trust
        let redirectDelegate = NoRedirectDelegate(trust: trust)
        self.redirectDelegate = redirectDelegate
        session = URLSession(configuration: configuration, delegate: redirectDelegate, delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    public func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        return (data, http)
    }

    /// Streams the file from disk; URLSession sets its Content-Length. Progress is reported as the
    /// body goes out, and once more in full when the host has answered.
    public func upload(_ request: URLRequest, fromFile file: URL,
                       progress: @escaping @Sendable (_ sent: Int64, _ total: Int64) -> Void) async throws -> (Data, HTTPURLResponse) {
        let delegate = UploadProgressDelegate(trust: serverTrust, progress: progress)
        let (data, response) = try await session.upload(for: request, fromFile: file, delegate: delegate)
        guard let http = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        if let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
            progress(Int64(size), Int64(size))
        }
        return (data, http)
    }

    /// The pulse's lines are small; 16 KiB bounds a misbehaving host.
    public func lines(_ request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, HTTPURLResponse) {
        try await lines(request, maxLineBytes: 16 << 10)
    }

    /// Streams with the same pinning delegate as every other request: a
    /// streaming task gets its trust challenges at task level (see
    /// `NoRedirectDelegate`), so a fresh connection keeps the paired pin.
    public func lines(_ request: URLRequest, maxLineBytes: Int) async throws -> (AsyncThrowingStream<String, Error>, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request, delegate: redirectDelegate)
        guard let http = response as? HTTPURLResponse else { bytes.task.cancel(); throw ClientError.invalidResponse }
        let stream = AsyncThrowingStream<String, Error> { continuation in
            let reader = Task {
                do {
                    var splitter = BoundedLineSplitter(limit: maxLineBytes)
                    for try await byte in bytes {
                        if let line = try splitter.append(byte) { continuation.yield(line) }
                    }
                    if let line = splitter.finish() { continuation.yield(line) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in reader.cancel(); bytes.task.cancel() }
        }
        return (stream, http)
    }
}

public enum ClientError: Error, Equatable, LocalizedError, Sendable {
    case invalidResponse
    case server(code: String, message: String)
    case unexpectedStatus(Int)
    case decoding
    /// The request never reached the host: no route, refused connection or a
    /// failed TLS handshake. Unlike a lost connection it cannot have taken effect.
    case unreachable

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: "The host returned an invalid response."
        case let .server(_, message): message
        case .unexpectedStatus: "The host could not complete that request."
        case .decoding: "The host returned data this version cannot read."
        case .unreachable: "The host is not reachable, so nothing was sent."
        }
    }

    /// Transport failures that prove the request was not delivered. Lost
    /// connections and timeouts stay ambiguous: the host may have acted.
    public static func isUndelivered(_ error: Error) -> Bool {
        guard let error = error as? URLError else { return false }
        switch error.code {
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet,
             .internationalRoamingOff, .callIsActive, .dataNotAllowed,
             .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected:
            return true
        default:
            return false
        }
    }

    /// Any transport-level failure, delivered or not. Used to decide whether a
    /// problem is the connection rather than the requested operation.
    public static func isConnectionFailure(_ error: Error) -> Bool {
        if error as? ClientError == .unreachable { return true }
        guard let error = error as? URLError else { return false }
        switch error.code {
        case .networkConnectionLost, .timedOut, .cannotLoadFromNetwork: return true
        default: return isUndelivered(error)
        }
    }
}

/// One line of the host's pulse stream. Unknown future kinds are ignored.
public enum HostPulseEvent: Equatable, Sendable {
    case ready(interval: TimeInterval)
    case beat
    case end
    case stopping
    /// `capabilities.remoteAccess` has this revision now (sent after `ready` and on every change by
    /// hosts that list remote access, docs/HOST-API.md "Capabilities" under "Remote access (iroh)").
    case remoteAccess(revision: String)
    /// `capabilities.plainChats` has this revision now: sent after `ready` and whenever it appears, goes or
    /// lists other tools, search service or instruction files (docs/HOST-API.md "Plain chats"). Opaque.
    case plainChats(revision: String)
}

public enum SendOutcome: Equatable, Sendable { case accepted, uncertain, failed(ClientError) }
public enum TerminalCreateOutcome: Equatable, Sendable { case created(RemoteTerminal), uncertain, failed(ClientError) }

public final class APIClient: @unchecked Sendable {
    public let address: ServerAddress
    private let token: String
    let transport: any APITransport

    public init(address: ServerAddress, token: String, transport: any APITransport = URLSessionTransport()) {
        self.address = address; self.token = token; self.transport = transport
    }

    public func health(timeout: TimeInterval = 20) async throws -> HealthResponse { try await get("/v1/health", authenticated: false, timeout: timeout) }
    /// Opens one pulse stream. It ends normally after the host's lifetime and
    /// throws when the connection drops or stays silent past `idleTimeout`.
    public func pulse(idleTimeout: TimeInterval = 4.5) async throws -> AsyncThrowingStream<HostPulseEvent, Error> {
        try Task.checkCancellation()
        var request = try makeRequest(path: "/v1/pulse", method: "GET")
        request.setValue("application/x-ndjson", forHTTPHeaderField: "Accept")
        request.timeoutInterval = idleTimeout
        let (lines, response) = try await transport.lines(request)
        guard response.statusCode == 200 else {
            var data = Data()
            for try await line in lines where data.count < 16_384 { data.append(Data(line.utf8)) }
            try validate(response, data: data, expected: 200)
            throw ClientError.unexpectedStatus(response.statusCode)
        }
        return AsyncThrowingStream { continuation in
            let reader = Task {
                do {
                    for try await line in lines {
                        guard let data = line.data(using: .utf8),
                              let value = try? JSONDecoder().decode(PulseLine.self, from: data) else { continue }
                        switch value.type {
                        case "ready": continuation.yield(.ready(interval: Double(value.intervalMs ?? 1500) / 1000))
                        case "beat": continuation.yield(.beat)
                        case "stopping": continuation.yield(.stopping)
                        case "end": continuation.yield(.end)
                        case "remoteAccess":
                            guard let revision = value.revision, (1...64).contains(revision.utf8.count) else { continue }
                            continuation.yield(.remoteAccess(revision: revision))
                        case "plainChats":
                            guard let revision = value.revision, (1...64).contains(revision.utf8.count) else { continue }
                            continuation.yield(.plainChats(revision: revision))
                        default: continue
                        }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in reader.cancel() }
        }
    }
    /// `POST /v1/device/presence`: the device's heartbeat. `view` names the chat it shows, only for hosts that
    /// list `presence: ["views"]` (others refuse the member); each heartbeat replaces the view the host holds,
    /// and one without it, or with `active: false`, clears it (docs/HOST-API.md "Presence and notices").
    public func setPresence(active: Bool, view: PresenceView? = nil) async throws {
        let _: PresenceResponse = try await post("/v1/device/presence", body: PresenceBody(active: active, view: view), expected: 200)
    }
    public func capabilities() async throws -> CapabilitiesResponse { try await get("/v1/capabilities") }
    public func projects() async throws -> [Project] { let response: ProjectsResponse = try await get("/v1/projects"); return response.projects }
    public func sessions(projectID: String) async throws -> [Session] {
        let response: SessionsResponse = try await get("/v1/sessions", query: [URLQueryItem(name: "projectId", value: projectID)])
        return response.sessions
    }
    public func messages(projectID: String, sessionID: String) async throws -> [ChatMessage] {
        try Task.checkCancellation()
        let response: MessagesResponse = try await get("/v1/messages", query: [URLQueryItem(name: "projectId", value: projectID), URLQueryItem(name: "sessionId", value: sessionID)])
        return response.messages
    }
    public func chatOptions(projectID: String, sessionID: String? = nil) async throws -> ChatOptionsResponse {
        var query = [URLQueryItem(name: "projectId", value: projectID)]
        if let sessionID { query.append(URLQueryItem(name: "sessionId", value: sessionID)) }
        return try await get("/v1/chat/options", query: query)
    }
    public func chatStatus(projectID: String, sessionID: String) async throws -> ChatStatusResponse {
        try await get("/v1/chat/status", query: [URLQueryItem(name: "projectId", value: projectID), URLQueryItem(name: "sessionId", value: sessionID)])
    }
    public func interactions(projectID: String, sessionID: String) async throws -> InteractionsResponse {
        try await get("/v1/interactions", query: [URLQueryItem(name: "projectId", value: projectID), URLQueryItem(name: "sessionId", value: sessionID)])
    }
    public func terminals(projectID: String) async throws -> [RemoteTerminal] {
        let response: TerminalsResponse = try await get("/v1/terminals", query: [URLQueryItem(name: "projectId", value: projectID)])
        return response.terminals
    }
    /// The running terminals other devices opened, and this Mac's, most recently active first (hosts that list
    /// `shared` in `terminalFeatures`).
    public func otherTerminals() async throws -> [SharedTerminal] {
        let response: SharedTerminalsResponse = try await get("/v1/terminals/others")
        return response.terminals
    }
    /// `title` is cut to the host's limit (`HostTitle`). `resume` (a Claude Code terminal, on hosts that list `resume`
    /// in `terminalFeatures`) continues a conversation.
    public func createTerminal(projectID: String, title: String, rows: Int, cols: Int, program: String? = nil,
                               resume: TerminalResume? = nil) async -> TerminalCreateOutcome {
        do {
            let terminal: RemoteTerminal = try await post("/v1/terminals", body: CreateTerminalBody(projectID: projectID, title: HostTitle.clipped(title),
                                                                                                    rows: rows, cols: cols, program: program,
                                                                                                    resume: resume?.requestValue),
                                                          expected: 201, timeout: program != nil && program != "shell" ? 120 : 20)
            return .created(terminal)
        } catch let error as ClientError {
            switch mutationOutcome(for: error) {
            case .uncertain: return .uncertain
            case let .failed(error): return .failed(error)
            case .accepted: return .uncertain
            }
        } catch { return ClientError.isUndelivered(error) ? .failed(.unreachable) : .uncertain }
    }
    /// With `wait`, the host holds the request until new bytes arrive (or the
    /// wait passes), so output appears as soon as the shell writes it.
    /// A `projectID` of "" is a terminal outside any workspace: this call and the input, title, resize and close
    /// calls send no `projectId` for it.
    public func terminalOutput(projectID: String, terminalID: String, cursor: UInt64, wait: TimeInterval? = nil) async throws -> TerminalOutput {
        var query = Self.terminalProject(projectID).map { [URLQueryItem(name: "projectId", value: $0)] } ?? []
        query += [URLQueryItem(name: "terminalId", value: terminalID), URLQueryItem(name: "cursor", value: String(cursor))]
        var timeout: TimeInterval = 20
        if let wait {
            query.append(URLQueryItem(name: "wait", value: String(Int(max(0, wait) * 1000))))
            timeout = max(0, wait) + 10
        }
        // A terminal the host no longer has says how it ended, when the host's archive recorded it.
        try Task.checkCancellation()
        var request = try makeRequest(path: "/v1/terminal/output", method: "GET", query: query)
        request.timeoutInterval = timeout
        let (data, httpResponse) = try await transport.execute(request)
        if httpResponse.statusCode == 404, let gone = try? ProtocolDecoder.decode(TerminalGoneEnvelope.self, from: data),
           gone.error.code == "terminal_not_found" {
            throw TerminalGoneError(ended: gone.error.ended)
        }
        try validate(httpResponse, data: data, expected: 200)
        let response: TerminalOutput
        do { response = try ProtocolDecoder.decode(TerminalOutput.self, from: data) } catch { throw ClientError.decoding }
        guard response.decodedData != nil else { throw ClientError.decoding }
        return response
    }
    /// `title` is cut to the host's limit (`HostTitle`).
    public func createSession(projectID: String, title: String, provider: String? = nil) async throws -> Session {
        var body = ["projectId": projectID, "title": HostTitle.clipped(title)]
        if let provider { body["provider"] = provider }
        return try await post("/v1/sessions", body: body, expected: 201)
    }
    public func pair(code: String, deviceName: String) async throws -> PairResponse {
        try await post("/v1/pair", body: ["code": code, "deviceName": deviceName], authenticated: false, expected: 200)
    }
    public func files(projectID: String, path: String = "") async throws -> [FileEntry] {
        let response: FilesResponse = try await get("/v1/files", query: [URLQueryItem(name: "projectId", value: projectID), URLQueryItem(name: "path", value: path)])
        return response.entries
    }
    public func file(projectID: String, path: String) async throws -> FileDocument {
        try await get("/v1/file", query: [URLQueryItem(name: "projectId", value: projectID), URLQueryItem(name: "path", value: path)])
    }
    public func gitRepositories(projectID: String) async throws -> [GitRepository] {
        let response: GitRepositoriesResponse = try await get("/v1/git/repositories", query: [URLQueryItem(name: "projectId", value: projectID)])
        return response.repositories
    }
    public func gitStatus(projectID: String, repository: String) async throws -> GitStatusResponse {
        try await get("/v1/git/status", query: [URLQueryItem(name: "projectId", value: projectID), URLQueryItem(name: "path", value: repository)])
    }
    public func gitDiff(projectID: String, repository: String, file: String) async throws -> GitDiffResponse {
        try await get("/v1/git/diff", query: [URLQueryItem(name: "projectId", value: projectID), URLQueryItem(name: "path", value: repository), URLQueryItem(name: "file", value: file)])
    }
    public func saveFile(projectID: String, path: String, content: String, revision: String) async -> Result<FileDocument, FileSaveError> {
        do {
            let document: FileDocument = try await post("/v1/file", body: FileSaveBody(projectID: projectID, path: path, content: content, revision: revision), expected: 200)
            return .success(document)
        } catch let error as ClientError {
            if case let .server(code, _) = error, code == "file_conflict" { return .failure(.conflict) }
            return .failure(.client(error))
        } catch { return .failure(ClientError.isUndelivered(error) ? .client(.unreachable) : .uncertain) }
    }

    public func sendMessage(projectID: String, sessionID: String, text: String, model: String? = nil, agent: String? = nil,
                            attachments: [String] = []) async -> SendOutcome {
        do {
            let body = SendMessageBody(projectID: projectID, sessionID: sessionID, text: text,
                                       model: model?.isEmpty == false ? model : nil,
                                       agent: agent?.isEmpty == false ? agent : nil,
                                       attachments: attachments.isEmpty ? nil : attachments)
            let response: AcceptedResponse = try await post("/v1/messages", body: body, expected: 202)
            return response.accepted ? .accepted : .failed(.unexpectedStatus(202))
        } catch let error as ClientError { return mutationOutcome(for: error) }
        catch { return ClientError.isUndelivered(error) ? .failed(.unreachable) : .uncertain }
    }
    public func transcript(projectID: String, sessionID: String) async throws -> MessagesResponse {
        try await get("/v1/messages", query: [URLQueryItem(name: "projectId", value: projectID), URLQueryItem(name: "sessionId", value: sessionID)])
    }
    /// Uploads one file for the next message. A repeated upload only leaves an unsent copy that the host expires.
    public func uploadAttachment(projectID: String, sessionID: String, name: String, mime: String, data: Data) async throws -> UploadedAttachment {
        var request = try makeRequest(path: "/v1/attachments", method: "POST", query: [
            URLQueryItem(name: "projectId", value: projectID), URLQueryItem(name: "sessionId", value: sessionID),
            URLQueryItem(name: "name", value: name)
        ])
        request.httpBody = data
        request.setValue(mime, forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        let (body, response) = try await transport.execute(request)
        try validate(response, data: body, expected: 201)
        do { return try ProtocolDecoder.decode(UploadedAttachment.self, from: body) } catch { throw ClientError.decoding }
    }
    public func queue(projectID: String, sessionID: String) async throws -> [QueuedPrompt] {
        let response: QueueResponse = try await get("/v1/queue", query: [URLQueryItem(name: "projectId", value: projectID), URLQueryItem(name: "sessionId", value: sessionID)])
        return response.items
    }
    public func enqueue(projectID: String, sessionID: String, text: String, model: String? = nil, agent: String? = nil) async -> SendOutcome {
        await mutationOutcome {
            let body = SendMessageBody(projectID: projectID, sessionID: sessionID, text: text,
                                       model: model?.isEmpty == false ? model : nil,
                                       agent: agent?.isEmpty == false ? agent : nil, attachments: nil)
            let item: QueuedPrompt = try await post("/v1/queue", body: body, expected: 201)
            return !item.id.isEmpty
        }
    }
    public func removeQueued(projectID: String, sessionID: String, itemID: String) async -> SendOutcome {
        await mutationOutcome { let response: RemovedResponse = try await post("/v1/queue/remove", body: QueueRemoveBody(projectID: projectID, sessionID: sessionID, itemID: itemID), expected: 200); return response.removed }
    }
    public func rewind(projectID: String, sessionID: String, messageID: String) async -> SendOutcome {
        await mutationOutcome { let response: RewoundResponse = try await post("/v1/messages/rewind", body: ["projectId": projectID, "sessionId": sessionID, "messageId": messageID], expected: 200); return response.rewound }
    }
    public func restoreRewind(projectID: String, sessionID: String) async -> SendOutcome {
        await mutationOutcome { let response: RestoredResponse = try await post("/v1/messages/restore", body: ["projectId": projectID, "sessionId": sessionID], expected: 200); return response.restored }
    }
    public func abort(projectID: String, sessionID: String) async -> SendOutcome {
        do {
            let response: AbortResponse = try await post("/v1/abort", body: ["projectId": projectID, "sessionId": sessionID], expected: 200)
            return response.aborted ? .accepted : .failed(.unexpectedStatus(200))
        } catch let error as ClientError { return mutationOutcome(for: error) }
        catch { return ClientError.isUndelivered(error) ? .failed(.unreachable) : .uncertain }
    }
    public func replyPermission(projectID: String, sessionID: String, requestID: String, reply: PermissionReply) async -> SendOutcome {
        await mutationOutcome { let response: AcceptedResponse = try await post("/v1/permissions/reply", body: PermissionReplyBody(projectID: projectID, sessionID: sessionID, requestID: requestID, reply: reply), expected: 200); return response.accepted }
    }
    public func replyQuestion(projectID: String, sessionID: String, requestID: String, answers: [[String]]) async -> SendOutcome {
        await mutationOutcome { let response: AcceptedResponse = try await post("/v1/questions/reply", body: QuestionReplyBody(projectID: projectID, sessionID: sessionID, requestID: requestID, answers: answers), expected: 200); return response.accepted }
    }
    public func rejectQuestion(projectID: String, sessionID: String, requestID: String) async -> SendOutcome {
        await mutationOutcome { let response: AcceptedResponse = try await post("/v1/questions/reject", body: QuestionRejectBody(projectID: projectID, sessionID: sessionID, requestID: requestID), expected: 200); return response.accepted }
    }
    public func sendTerminalInput(projectID: String, terminalID: String, data: Data) async -> SendOutcome {
        await mutationOutcome { let response: AcceptedResponse = try await post("/v1/terminal/input", body: TerminalInputBody(projectID: Self.terminalProject(projectID), terminalID: terminalID, data: data.base64EncodedString()), expected: 200); return response.accepted }
    }
    public func nameTerminal(projectID: String, terminalID: String, title: String, basedOn: UInt64) async -> SendOutcome {
        struct Body: Encodable { let projectId: String?; let terminalId: String; let title: String; let basedOn: UInt64 }
        return await mutationOutcome {
            let response: AcceptedResponse = try await post("/v1/terminal/title", body: Body(projectId: Self.terminalProject(projectID), terminalId: terminalID, title: title, basedOn: basedOn), expected: 200)
            return response.accepted
        }
    }
    public func resizeTerminal(projectID: String, terminalID: String, rows: Int, cols: Int) async -> SendOutcome {
        await mutationOutcome { let response: AcceptedResponse = try await post("/v1/terminal/resize", body: TerminalResizeBody(projectID: Self.terminalProject(projectID), terminalID: terminalID, rows: rows, cols: cols), expected: 200); return response.accepted }
    }
    public func closeTerminal(projectID: String, terminalID: String) async -> SendOutcome {
        await mutationOutcome { let response: AcceptedResponse = try await post("/v1/terminal/close", body: TerminalCloseBody(projectID: Self.terminalProject(projectID), terminalID: terminalID), expected: 200); return response.accepted }
    }

    /// A terminal route's `projectId`: none for a terminal outside any workspace ("").
    private static func terminalProject(_ projectID: String) -> String? { projectID.isEmpty ? nil : projectID }

    func get<T: Decodable>(_ path: String, query: [URLQueryItem] = [], authenticated: Bool = true, timeout: TimeInterval = 20) async throws -> T {
        try Task.checkCancellation()
        var request = try makeRequest(path: path, method: "GET", query: query, authenticated: authenticated)
        request.timeoutInterval = timeout
        let (data, response) = try await transport.execute(request)
        try validate(response, data: data, expected: 200)
        do { return try ProtocolDecoder.decode(T.self, from: data) } catch { throw ClientError.decoding }
    }
    /// `bearer` is a token sent although the route is not `authenticated` (pairing again).
    func post<T: Decodable, Body: Encodable>(_ path: String, body: Body, authenticated: Bool = true, bearer: String? = nil, expected: Int, timeout: TimeInterval = 20) async throws -> T {
        var request = try makeRequest(path: path, method: "POST", authenticated: authenticated)
        if let bearer, !authenticated { request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization") }
        request.timeoutInterval = timeout
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await transport.execute(request)
        try validate(response, data: data, expected: expected)
        do { return try ProtocolDecoder.decode(T.self, from: data) } catch { throw ClientError.decoding }
    }
    func makeRequest(path: String, method: String, query: [URLQueryItem] = [], authenticated: Bool = true) throws -> URLRequest {
        guard path.hasPrefix("/v1/") else { throw ClientError.invalidResponse }
        var components = URLComponents(url: address.url.appending(path: path), resolvingAgainstBaseURL: false)!
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw ClientError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if authenticated { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        request.timeoutInterval = 20
        return request
    }
    func validate(_ response: HTTPURLResponse, data: Data, expected: Int) throws {
        guard response.statusCode == expected else {
            if let envelope = try? ProtocolDecoder.decode(APIErrorEnvelope.self, from: data) { throw ClientError.server(code: envelope.error.code, message: envelope.error.message) }
            throw ClientError.unexpectedStatus(response.statusCode)
        }
    }
    func mutationOutcome(for error: ClientError) -> SendOutcome {
        switch error {
        case .decoding, .invalidResponse: .uncertain
        case let .unexpectedStatus(status) where status >= 500: .uncertain
        case let .server(code, _) where ["connector_unavailable", "upstream_error", "timeout", "delivery_uncertain"].contains(code): .uncertain
        default: .failed(error)
        }
    }
    private func mutationOutcome(_ request: () async throws -> Bool) async -> SendOutcome {
        do { return try await request() ? .accepted : .failed(.unexpectedStatus(200)) }
        catch let error as ClientError { return mutationOutcome(for: error) }
        catch { return ClientError.isUndelivered(error) ? .failed(.unreachable) : .uncertain }
    }
    private struct PermissionReplyBody: Encodable { let projectID: String; let sessionID: String; let requestID: String; let reply: PermissionReply; enum CodingKeys: String, CodingKey { case projectID = "projectId", sessionID = "sessionId", requestID = "requestId", reply } }
    private struct QuestionReplyBody: Encodable { let projectID: String; let sessionID: String; let requestID: String; let answers: [[String]]; enum CodingKeys: String, CodingKey { case projectID = "projectId", sessionID = "sessionId", requestID = "requestId", answers } }
    private struct QuestionRejectBody: Encodable { let projectID: String; let sessionID: String; let requestID: String; enum CodingKeys: String, CodingKey { case projectID = "projectId", sessionID = "sessionId", requestID = "requestId" } }
    private struct CreateTerminalBody: Encodable { let projectID: String; let title: String; let rows: Int; let cols: Int; let program: String?; let resume: String?; enum CodingKeys: String, CodingKey { case projectID = "projectId", title, rows, cols, program, resume } }
    private struct TerminalGoneEnvelope: Decodable {
        struct Body: Decodable {
            let code: String
            let ended: TerminalEnd?
            enum CodingKeys: String, CodingKey { case code, ended }
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                code = try container.decode(String.self, forKey: .code)
                ended = (try? container.decodeIfPresent(TerminalEnd.self, forKey: .ended)).flatMap { $0 }
            }
        }
        let error: Body
    }
    private struct TerminalInputBody: Encodable { let projectID: String?; let terminalID: String; let data: String; enum CodingKeys: String, CodingKey { case projectID = "projectId", terminalID = "terminalId", data } }
    private struct TerminalResizeBody: Encodable { let projectID: String?; let terminalID: String; let rows: Int; let cols: Int; enum CodingKeys: String, CodingKey { case projectID = "projectId", terminalID = "terminalId", rows, cols } }
    private struct TerminalCloseBody: Encodable { let projectID: String?; let terminalID: String; enum CodingKeys: String, CodingKey { case projectID = "projectId", terminalID = "terminalId" } }
    private struct FileSaveBody: Encodable { let projectID: String; let path: String; let content: String; let revision: String; enum CodingKeys: String, CodingKey { case projectID = "projectId", path, content, revision } }
    private struct SendMessageBody: Encodable { let projectID: String; let sessionID: String; let text: String; let model: String?; let agent: String?; let attachments: [String]?; enum CodingKeys: String, CodingKey { case projectID = "projectId", sessionID = "sessionId", text, model, agent, attachments } }
    private struct QueueRemoveBody: Encodable { let projectID: String; let sessionID: String; let itemID: String; enum CodingKeys: String, CodingKey { case projectID = "projectId", sessionID = "sessionId", itemID = "itemId" } }
}

// MARK: Streaming chat (docs/HOST-API.md "Chat event stream", "Chat routes")

extension APIClient {
    /// Chat event lines never exceed 256 KiB (the host's contract).
    public static let chatEventLineLimit = 256 << 10

    /// Opens `GET /v1/chat/events` and returns its NDJSON lines, undecoded,
    /// so the caller decodes them off the main thread. `after` resumes from a
    /// cursor. The host beats every 10 s, so a silence past `idleTimeout` ends
    /// the stream with an error.
    public func chatEventLines(projectID: String, sessionID: String, after cursor: String?,
                               idleTimeout: TimeInterval = 25) async throws -> AsyncThrowingStream<String, Error> {
        try Task.checkCancellation()
        var query = [URLQueryItem(name: "projectId", value: projectID), URLQueryItem(name: "sessionId", value: sessionID)]
        if let cursor, !cursor.isEmpty { query.append(URLQueryItem(name: "after", value: cursor)) }
        var request = try makeRequest(path: "/v1/chat/events", method: "GET", query: query)
        request.setValue("application/x-ndjson", forHTTPHeaderField: "Accept")
        request.timeoutInterval = idleTimeout
        let (lines, response) = try await transport.lines(request, maxLineBytes: Self.chatEventLineLimit)
        guard response.statusCode == 200 else {
            var data = Data()
            for try await line in lines where data.count < 16_384 { data.append(Data(line.utf8)) }
            try validate(response, data: data, expected: 200)
            throw ClientError.unexpectedStatus(response.statusCode)
        }
        return lines
    }

    /// One page of `GET /v1/chat/messages`, newest first.
    public func chatMessagesPage(projectID: String, sessionID: String, before: String?, limit: Int = 50) async throws -> ConversationPage {
        var query = [URLQueryItem(name: "projectId", value: projectID), URLQueryItem(name: "sessionId", value: sessionID),
                     URLQueryItem(name: "limit", value: String(min(max(limit, 1), 50)))]
        if let before, !before.isEmpty { query.append(URLQueryItem(name: "before", value: before)) }
        return try await get("/v1/chat/messages", query: query, timeout: 30)
    }

    /// The legacy transcript. `withParts` adds each message's ordered parts,
    /// on hosts that advertise `parts`.
    public func transcript(projectID: String, sessionID: String, withParts: Bool) async throws -> MessagesResponse {
        var query = [URLQueryItem(name: "projectId", value: projectID), URLQueryItem(name: "sessionId", value: sessionID)]
        if withParts { query.append(URLQueryItem(name: "parts", value: "1")) }
        return try await get("/v1/messages", query: query)
    }

    /// Options for a new chat of `provider` in a project.
    public func chatOptions(projectID: String, provider: String) async throws -> ChatOptionsResponse {
        var query = [URLQueryItem(name: "projectId", value: projectID)]
        if provider != AgentProvider.opencode.id { query.append(URLQueryItem(name: "provider", value: provider)) }
        return try await get("/v1/chat/options", query: query)
    }

    /// `POST /v1/messages` with the fields the caller set. Nothing is retried.
    public func sendChatMessage(_ message: ChatSendRequest) async -> ChatSendOutcome {
        let body = ChatSendBody(projectID: message.projectID, sessionID: message.sessionID, text: message.text,
                                model: message.model?.isEmpty == false ? message.model : nil,
                                agent: message.agent?.isEmpty == false ? message.agent : nil,
                                attachments: message.attachments.isEmpty ? nil : message.attachments,
                                clientMessageID: message.clientMessageID?.isEmpty == false ? message.clientMessageID : nil,
                                mode: message.mode?.isEmpty == false ? message.mode : nil,
                                effort: message.effort?.isEmpty == false ? message.effort : nil)
        do {
            let receipt: ChatSendReceipt = try await post("/v1/messages", body: body, expected: 202)
            return receipt.accepted ? .accepted(receipt) : .failed(.unexpectedStatus(202))
        } catch let error as ClientError {
            switch mutationOutcome(for: error) {
            case .uncertain, .accepted: return .uncertain
            case let .failed(error): return .failed(error)
            }
        } catch { return ClientError.isUndelivered(error) ? .failed(.unreachable) : .uncertain }
    }

    /// `POST /v1/chat/regenerate`: runs the latest turn again.
    public func regenerateChat(projectID: String, sessionID: String, model: String? = nil, mode: String? = nil,
                               effort: String? = nil) async -> SendOutcome {
        let body = RegenerateBody(projectID: projectID, sessionID: sessionID, model: model?.isEmpty == false ? model : nil,
                                  mode: mode?.isEmpty == false ? mode : nil, effort: effort?.isEmpty == false ? effort : nil)
        do {
            try await postIgnoringBody("/v1/chat/regenerate", body: body, expected: 202)
            return .accepted
        } catch let error as ClientError { return mutationOutcome(for: error) }
        catch { return ClientError.isUndelivered(error) ? .failed(.unreachable) : .uncertain }
    }

    /// `POST /v1/chat/fork`: a new chat copied through `messageID`'s turn. `title` is cut to the host's limit
    /// (`HostTitle`).
    public func forkChat(projectID: String, sessionID: String, messageID: String?, title: String?) async -> ChatCreateOutcome {
        let title = title.map(HostTitle.clipped)
        return await createOutcome {
            try await post("/v1/chat/fork", body: ForkBody(projectID: projectID, sessionID: sessionID,
                                                           messageID: messageID?.isEmpty == false ? messageID : nil,
                                                           title: title?.isEmpty == false ? title : nil), expected: 201)
        }
    }

    /// `POST /v1/chat/continue`: a new chat, of any provider, seeded from an
    /// archived one. Nothing is sent until the person sends a message.
    /// `contextChars` and `throughMessageID` go out only when the caller set them; a `title` is cut to the
    /// host's limit (`HostTitle`).
    public func continueChat(_ request: ChatContinueRequest) async -> ChatCreateOutcome {
        let title = request.title.map(HostTitle.clipped)
        return await createOutcome {
            try await post("/v1/chat/continue", body: ContinueBody(
                projectID: request.projectID, sourceSessionID: request.sourceSessionID, provider: request.provider,
                model: request.model?.isEmpty == false ? request.model : nil, mode: request.mode?.isEmpty == false ? request.mode : nil,
                effort: request.effort?.isEmpty == false ? request.effort : nil,
                title: title?.isEmpty == false ? title : nil,
                throughMessageID: request.throughMessageID?.isEmpty == false ? request.throughMessageID : nil,
                contextChars: request.contextChars.map { min(max($0, ChatContinueRequest.contextCharsRange.lowerBound),
                                                             ChatContinueRequest.contextCharsRange.upperBound) }), expected: 201)
        }
    }

    /// Rewinds to before `messageID`; reports whether files come back too.
    public func rewindChat(projectID: String, sessionID: String, messageID: String) async -> ChatRewindOutcome {
        await rewindOutcome {
            let response: RewindResponse = try await post("/v1/messages/rewind", body: ["projectId": projectID, "sessionId": sessionID, "messageId": messageID], expected: 200)
            return response.rewound == true ? response : nil
        }
    }

    public func restoreChat(projectID: String, sessionID: String) async -> ChatRewindOutcome {
        await rewindOutcome {
            let response: RewindResponse = try await post("/v1/messages/restore", body: ["projectId": projectID, "sessionId": sessionID], expected: 200)
            return response.restored == true ? response : nil
        }
    }

    private func createOutcome(_ request: () async throws -> Session) async -> ChatCreateOutcome {
        do { return .created(try await request()) }
        catch let error as ClientError {
            switch mutationOutcome(for: error) {
            case .uncertain, .accepted: return .uncertain
            case let .failed(error): return .failed(error)
            }
        } catch { return ClientError.isUndelivered(error) ? .failed(.unreachable) : .uncertain }
    }

    private func rewindOutcome(_ request: () async throws -> RewindResponse?) async -> ChatRewindOutcome {
        do {
            guard let response = try await request() else { return .failed(.unexpectedStatus(200)) }
            return .accepted(response.filesRestore.flatMap(ChatFilesRestore.init(rawValue:)))
        } catch let error as ClientError {
            switch mutationOutcome(for: error) {
            case .uncertain, .accepted: return .uncertain
            case let .failed(error): return .failed(error)
            }
        } catch { return ClientError.isUndelivered(error) ? .failed(.unreachable) : .uncertain }
    }

    private func postIgnoringBody<Body: Encodable>(_ path: String, body: Body, expected: Int) async throws {
        var request = try makeRequest(path: path, method: "POST")
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await transport.execute(request)
        try validate(response, data: data, expected: expected)
    }

    private struct ChatSendBody: Encodable {
        let projectID: String; let sessionID: String; let text: String; let model: String?; let agent: String?
        let attachments: [String]?; let clientMessageID: String?; let mode: String?; let effort: String?
        enum CodingKeys: String, CodingKey {
            case projectID = "projectId", sessionID = "sessionId", text, model, agent, attachments, clientMessageID = "clientMessageId", mode, effort
        }
    }
    private struct RegenerateBody: Encodable {
        let projectID: String; let sessionID: String; let model: String?; let mode: String?; let effort: String?
        enum CodingKeys: String, CodingKey { case projectID = "projectId", sessionID = "sessionId", model, mode, effort }
    }
    private struct ForkBody: Encodable {
        let projectID: String; let sessionID: String; let messageID: String?; let title: String?
        enum CodingKeys: String, CodingKey { case projectID = "projectId", sessionID = "sessionId", messageID = "messageId", title }
    }
    private struct ContinueBody: Encodable {
        let projectID: String; let sourceSessionID: String; let provider: String; let model: String?; let mode: String?
        let effort: String?; let title: String?; let throughMessageID: String?; let contextChars: Int?
        enum CodingKeys: String, CodingKey {
            case projectID = "projectId", sourceSessionID = "sourceSessionId", provider, model, mode, effort, title
            case throughMessageID = "throughMessageId"
            case contextChars
        }
    }
    private struct RewindResponse: Decodable { let rewound: Bool?; let restored: Bool?; let filesRestore: String? }
}

private struct PresenceResponse: Decodable { let accepted: Bool }
/// The heartbeat's body; `view` is left out when there is none.
private struct PresenceBody: Encodable { let active: Bool; let view: PresenceView? }

/// The chat a device shows, as its presence heartbeat reports it (`view`, docs/HOST-API.md "Presence and
/// notices"): the host leaves out notices for it and counts the Mac as in use while one is reported.
public struct PresenceView: Hashable, Sendable, Encodable {
    /// The longest project or chat ID the host takes, in bytes.
    public static let maximumBytes = 256

    public let projectID: String
    public let sessionID: String

    /// Nil unless both IDs are 1–256 bytes, as the host takes them; it refuses the whole heartbeat otherwise.
    public init?(projectID: String, sessionID: String) {
        guard (1...Self.maximumBytes).contains(projectID.utf8.count), (1...Self.maximumBytes).contains(sessionID.utf8.count) else { return nil }
        self.projectID = projectID
        self.sessionID = sessionID
    }

    enum CodingKeys: String, CodingKey { case projectID = "projectId", sessionID = "sessionId" }
}
private struct PulseLine: Decodable { let type: String; let intervalMs: Int?; let revision: String? }
private struct RemovedResponse: Decodable { let removed: Bool }
private struct RewoundResponse: Decodable { let rewound: Bool }
private struct RestoredResponse: Decodable { let restored: Bool }

public enum FileSaveError: Error, Equatable, Sendable { case conflict, uncertain, client(ClientError) }
