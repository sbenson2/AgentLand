import Foundation
import XCTest
import AgentLandCore

/// A host whose routes the test scripts, each answer possibly held back until the test releases it,
/// so late answers can arrive after the workspace moved on.
final class ScriptedHost: APITransport, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) async throws -> (Int, String)

    private let lock = NSLock()
    private var handlers: [String: Handler] = [:]
    private var headers: [String: [String: String]] = [:]
    private var log: [(request: URLRequest, body: Data?)] = []

    func on(_ path: String, _ handler: @escaping Handler) {
        lock.withLock { handlers[path] = handler }
    }

    /// Headers every answer on `path` carries, such as an icon's `Content-Type`.
    func headers(_ path: String, _ fields: [String: String]) {
        lock.withLock { headers[path] = fields }
    }

    func requests(_ path: String) -> [URLRequest] {
        lock.withLock { log.filter { $0.request.url?.path == path }.map(\.request) }
    }

    /// Every request's path, in the order the requests arrived.
    func paths() -> [String] {
        lock.withLock { log.compactMap { $0.request.url?.path } }
    }

    func bodies(_ path: String) -> [[String: Any]] {
        lock.withLock { log.filter { $0.request.url?.path == path } }.compactMap { entry in
            entry.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
    }

    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path ?? ""
        let (handler, fields) = lock.withLock { () -> (Handler?, [String: String]?) in
            log.append((request, request.httpBody))
            return (handlers[path], headers[path])
        }
        let (status, body) = try await handler?(request) ?? (404, #"{"error":{"code":"not_found","message":"Not found"}}"#)
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: fields)!)
    }

    static func query(_ request: URLRequest) -> [String: String] {
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
    }

    // MARK: Chat event streams

    private var streams: [String: [[String]]] = [:]
    private var openStreams: [String: AsyncThrowingStream<String, Error>.Continuation] = [:]

    /// The lines of the next `GET /v1/chat/events` for chat `sessionID`; the stream then stays open, as
    /// the host's does, until the client cancels it.
    func enqueueStream(_ sessionID: String, _ lines: [String]) {
        lock.withLock { streams[sessionID, default: []].append(lines) }
    }

    /// Sends a line on chat `sessionID`'s open stream.
    func push(_ sessionID: String, _ line: String) {
        _ = lock.withLock { openStreams[sessionID] }?.yield(line)
    }

    func lines(_ request: URLRequest, maxLineBytes: Int) async throws -> (AsyncThrowingStream<String, Error>, HTTPURLResponse) {
        let session = Self.query(request)["sessionId"] ?? ""
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        let script = lock.withLock { () -> [String] in
            log.append((request, nil))
            openStreams[session] = continuation
            return streams[session]?.isEmpty == false ? streams[session]!.removeFirst() : []
        }
        for line in script { continuation.yield(line) }
        return (stream, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
}

/// Opens once; everyone waiting, and everyone who waits later, goes on. A cancelled wait ends too.
actor Gate {
    private var opened = false
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    func wait() async {
        if opened { return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if opened || Task.isCancelled { continuation.resume() } else { waiters[id] = continuation }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func cancel(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume()
    }

    func open() {
        opened = true
        for waiter in waiters.values { waiter.resume() }
        waiters = [:]
    }
}

/// Waits until a host handler reached `gate`, failing (instead of hanging) after `timeout`.
@MainActor func arrive(at gate: Gate, _ message: String = "the request", timeout: TimeInterval = 3,
                       file: StaticString = #filePath, line: UInt = #line) async {
    let reached = await withTaskGroup(of: Bool.self) { group in
        group.addTask { await gate.wait(); return true }
        group.addTask { try? await Task.sleep(for: .seconds(timeout)); return false }
        let first = await group.next() ?? false
        group.cancelAll()
        return first
    }
    if !reached { XCTFail("Timed out waiting for \(message)", file: file, line: line) }
}

/// Waits until `condition` holds on the main actor, failing after `timeout`.
@MainActor func waitUntil(_ message: String = "condition", timeout: TimeInterval = 3, _ condition: () -> Bool,
                          file: StaticString = #filePath, line: UInt = #line) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        guard Date() < deadline else {
            XCTFail("Timed out waiting for \(message)", file: file, line: line)
            return
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
}
