import Foundation
import XCTest
import AgentLandCore
import AgentLandDesktopCore

/// A host's notice routes behind `URLProtocol`, following docs/HOST-API.md:
/// `GET /v1/notices` serves the notices after the cursor (after the
/// acknowledged ones without it), at most 100, and holds the request while
/// there are none; a cursor from another epoch starts over with `resync`.
/// `POST /v1/notices/ack` moves the acknowledgement forward and refuses a seq
/// not issued yet.
final class FakeNoticeHost: @unchecked Sendable {
    struct Request: Equatable {
        let method: String
        let path: String
        let query: [String: String]
        let body: [String: Int64]?
        let authorization: String?
    }

    let name = "relay-\(UUID().uuidString.lowercased()).notice-host.test"
    var baseURL: URL { URL(string: "https://\(name)")! }
    let timeline: Timeline

    private let lock = NSLock()
    private var epoch = "00000000000000e1"
    private var issued: [HostNotice] = []
    private var acked: Int64 = 0
    private var received: [Request] = []
    private var held: [Held] = []
    private var cancelledCount = 0
    private var failNextPolls: [Int] = []
    private var stopping = false

    private struct Held {
        let loader: FakeNoticeHostProtocol
        let from: Int64
        let resync: Bool
        let runLoop: CFRunLoop
        let mode: CFRunLoopMode
    }

    init(timeline: Timeline = Timeline()) {
        self.timeline = timeline
        FakeNoticeHostProtocol.registry.add(self)
    }

    deinit { FakeNoticeHostProtocol.registry.remove(name) }

    // MARK: Test controls

    var requests: [Request] { lock.withLock { received } }
    var polls: [Request] { requests.filter { $0.path == "/v1/notices" } }
    var acks: [Int64] { requests.compactMap { $0.path == "/v1/notices/ack" ? $0.body?["through"] : nil } }
    var acknowledged: Int64 { lock.withLock { acked } }
    var heldCount: Int { lock.withLock { held.count } }
    var cancelled: Int { lock.withLock { cancelledCount } }
    var currentEpoch: String { lock.withLock { epoch } }

    /// Issues notices (seq continues) and answers waiting long-polls.
    func issue(_ make: (_ seq: Int64) -> HostNotice) {
        issue(count: 1, make)
    }

    func issue(count: Int, _ make: (_ seq: Int64) -> HostNotice) {
        let waiting: [Held] = lock.withLock {
            for _ in 0..<count { issued.append(make((issued.last?.seq ?? 0) + 1)) }
            defer { held.removeAll() }
            return held
        }
        for request in waiting { answer(request) }
    }

    /// The next `GET /v1/notices` answers this status.
    func failNextPoll(status: Int) { lock.withLock { failNextPolls.append(status) } }

    /// As the host does once it starts stopping: long-polls end at once with
    /// no notices.
    func beginStopping() {
        let waiting: [Held] = lock.withLock {
            stopping = true
            defer { held.removeAll() }
            return held
        }
        for request in waiting { answer(request) }
    }

    /// A restart of a host that keeps notices in memory: a new epoch, the old
    /// notices and acknowledgement gone, numbering from 1 again.
    /// Waiting long-polls break, as their connection does.
    func restartWithoutArchive() {
        let broken: [Held] = lock.withLock {
            epoch = "00000000000000e2"
            issued = []
            acked = 0
            defer { held.removeAll() }
            return held
        }
        for request in broken {
            CFRunLoopPerformBlock(request.runLoop, request.mode.rawValue) {
                request.loader.client?.urlProtocol(request.loader, didFailWithError: URLError(.networkConnectionLost))
            }
            CFRunLoopWakeUp(request.runLoop)
        }
    }

    // MARK: Protocol

    fileprivate func receive(_ loader: FakeNoticeHostProtocol) {
        let request = loader.request
        let url = request.url!
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let query = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
        let body = Self.body(of: request).flatMap { try? JSONDecoder().decode([String: Int64].self, from: $0) }
        let entry = Request(method: request.httpMethod ?? "GET", path: url.path, query: query, body: body,
                            authorization: request.value(forHTTPHeaderField: "Authorization"))
        lock.withLock { received.append(entry) }
        switch (entry.method, entry.path) {
        case ("GET", "/v1/notices"):
            timeline.add("poll \(query["after"] ?? "-")")
            if let status = lock.withLock({ failNextPolls.isEmpty ? nil : failNextPolls.removeFirst() }) {
                return loader.respond(status: status, json: ["error": ["code": "storage_error", "message": "Scripted failure"]])
            }
            let (from, resync): (Int64, Bool) = lock.withLock {
                guard let after = query["after"] else { return (acked, false) }
                let parts = after.split(separator: ".")
                guard parts.count == 2, String(parts[0]) == epoch, let seq = Int64(parts[1]),
                      seq <= (issued.last?.seq ?? 0) else { return (0, true) }
                return (seq, false)
            }
            let waiting = Held(loader: loader, from: from, resync: resync, runLoop: CFRunLoopGetCurrent(),
                               mode: CFRunLoopCopyCurrentMode(CFRunLoopGetCurrent()) ?? .defaultMode)
            let page: [String: Any]? = lock.withLock {
                let notices = issued.filter { $0.seq > from }
                if notices.isEmpty && !stopping { held.append(waiting); return nil }
                return pageLocked(from: from, resync: resync)
            }
            if let page { loader.respond(status: 200, json: page) }
        case ("POST", "/v1/notices/ack"):
            guard let through = body?["through"] else {
                return loader.respond(status: 400, json: ["error": ["code": "invalid_request", "message": "through"]])
            }
            let accepted: Int64? = lock.withLock {
                guard through <= (issued.last?.seq ?? 0) else { return nil }
                acked = max(acked, through)
                return acked
            }
            timeline.add("ack \(through)")
            if let accepted {
                loader.respond(status: 200, json: ["acked": accepted])
            } else {
                loader.respond(status: 400, json: ["error": ["code": "invalid_request", "message": "No notice has that seq yet"]])
            }
        default:
            loader.respond(status: 404, json: ["error": ["code": "not_found", "message": "Not found"]])
        }
    }

    fileprivate func cancel(_ loader: FakeNoticeHostProtocol) {
        lock.withLock {
            let before = held.count
            held.removeAll { $0.loader === loader }
            if held.count < before { cancelledCount += 1 }
        }
    }

    private func answer(_ request: Held) {
        let page = lock.withLock { pageLocked(from: request.from, resync: request.resync) }
        CFRunLoopPerformBlock(request.runLoop, request.mode.rawValue) { request.loader.respond(status: 200, json: page) }
        CFRunLoopWakeUp(request.runLoop)
    }

    private func pageLocked(from: Int64, resync: Bool) -> [String: Any] {
        let notices = Array(issued.filter { $0.seq > from }.prefix(100))
        let more = issued.filter { $0.seq > from }.count > notices.count
        let cursor = notices.last?.seq ?? from
        return ["notices": notices.map(Self.json), "cursor": "\(epoch).\(cursor)", "hasMore": more, "resync": resync]
    }

    private static func json(_ notice: HostNotice) -> [String: Any] {
        var value: [String: Any] = ["seq": notice.seq, "id": notice.id, "kind": notice.kind, "projectId": notice.projectID,
                                    "projectName": notice.projectName, "title": notice.title,
                                    "mayContainContent": notice.mayContainContent, "createdAt": notice.createdAt]
        if let sessionID = notice.sessionID { value["sessionId"] = sessionID }
        return value
    }

    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

final class FakeNoticeHostProtocol: URLProtocol, @unchecked Sendable {
    final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var hosts: [String: FakeNoticeHost] = [:]
        func add(_ host: FakeNoticeHost) { lock.withLock { hosts[host.name] = host } }
        func remove(_ name: String) { lock.withLock { hosts[name] = nil } }
        func host(_ name: String?) -> FakeNoticeHost? { lock.withLock { name.flatMap { hosts[$0] } } }
    }

    static let registry = Registry()
    private var host: FakeNoticeHost?

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".notice-host.test") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let host = Self.registry.host(request.url?.host) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        self.host = host
        host.receive(self)
    }

    override func stopLoading() { host?.cancel(self) }

    fileprivate func respond(status: Int, json: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// `APITransport` over a session whose only protocol is the fake host.
struct FakeHostTransport: APITransport {
    let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeNoticeHostProtocol.self]
        session = URLSession(configuration: configuration)
    }

    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        return (data, http)
    }
}

/// Events from the fake host and the fake database, in the order they
/// happened.
final class Timeline: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    func add(_ event: String) { lock.withLock { events.append(event) } }
    var all: [String] { lock.withLock { events } }
}

/// Virtual time: `sleep` records the wait, moves the clock by it and yields
/// for a few real milliseconds, so backoff never spins.
final class TestClock: NoticeRelayClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    private var waits: [TimeInterval] = []

    init(_ start: Date = Date(timeIntervalSince1970: 1_790_000_000)) { current = start }

    func now() -> Date { lock.withLock { current } }
    func advance(by seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
    var sleeps: [TimeInterval] { lock.withLock { waits } }

    func sleep(for duration: Duration) async throws {
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        lock.withLock {
            waits.append(seconds)
            current = current.addingTimeInterval(seconds)
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}

func noticeTime(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

/// Polls `condition` for up to `timeout` seconds of real time, on the
/// caller's actor.
func eventually(_ message: String = "condition", timeout: TimeInterval = 5, isolation: isolated (any Actor)? = #isolation,
                file: StaticString = #filePath, line: UInt = #line, _ condition: () async -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Timed out waiting for \(message)", file: file, line: line)
}
