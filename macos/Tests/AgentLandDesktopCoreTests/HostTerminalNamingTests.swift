import XCTest
import AgentLandBranding
import AgentLandChat
import AgentLandCore
@testable import AgentLandDesktopCore
@testable import AgentLandDesktop

/// The Mac names every terminal on its host (`HostTerminalNaming`): from each running terminal's own output, rendered
/// at its size, once per change, with nothing typed into it, and only while Apple Intelligence is on.
@MainActor
final class HostTerminalNamingTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suite = "HostTerminalNamingTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private func naming(_ host: FakeNamingHost, namer: FakeTerminalNamer) -> HostTerminalNaming {
        let naming = HostTerminalNaming(preferences: defaults, namer: namer, interval: .seconds(3600))
        naming.lowPowerMode = { false }
        naming.activate()
        naming.hostStarted(host)
        return naming
    }

    func testEveryRunningTerminalIsNamedFromItsScreenOnce() async {
        let host = FakeNamingHost()
        host.add("a", output: "› fix the login redirect\r\nDone\r\n", projectID: "p", rows: 24, cols: 80)
        // An agent typed in Terminal: no workspace, and no size the host knows.
        host.add("r", output: "› add login regression tests\r\nUpdated\r\n", projectID: "", routed: true)
        host.add("e", output: "› old work\r\nDone\r\n", projectID: "p", status: "exited")
        let namer = FakeTerminalNamer(["Fix the login redirect", "Add login regression tests"])
        let naming = naming(host, namer: namer)
        XCTAssertTrue(naming.isRunning)
        await naming.passNow()
        XCTAssertEqual(host.names.map(\.id), ["a", "r"])
        XCTAssertEqual(host.names.map(\.title), ["Fix the login redirect", "Add login regression tests"])
        XCTAssertEqual(host.names.map(\.basedOn), [host.end("a"), host.end("r")])
        XCTAssertFalse(host.reads.contains { $0.id == "e" }, "An ended terminal is never read")
        // The model read the screen, and nothing but the screen.
        XCTAssertTrue(namer.prompts.first?.contains("fix the login redirect") == true)
        // No new output: nothing is read or asked again.
        let reads = host.reads.count
        await naming.passNow()
        XCTAssertEqual(host.reads.count, reads)
        XCTAssertEqual(namer.prompts.count, 2)
        // New output is.
        host.append("a", "› now repair the logout redirect\r\nDone\r\n")
        namer.answers = ["Repair the logout redirect"]
        await naming.passNow()
        XCTAssertEqual(host.names.last?.title, "Repair the logout redirect")
        XCTAssertEqual(host.names.last?.basedOn, host.end("a"))
    }

    func testTheNameItHasAndStaleAnswersAreNotSentAgain() async {
        let host = FakeNamingHost()
        host.add("a", output: "› fix the login redirect\r\nDone\r\n", projectID: "p", title: "Fix the login redirect", source: "device")
        let namer = FakeTerminalNamer(["Fix the login redirect"])
        let naming = naming(host, namer: namer)
        await naming.passNow()
        XCTAssertEqual(namer.prompts.count, 1)
        XCTAssertTrue(namer.prompts[0].contains("Current name: Fix the login redirect"), "A device's name is the current one")
        XCTAssertTrue(host.names.isEmpty, "The name it has already is not sent")
        // A device named newer output: the host's answer is taken, and the same output never sent again.
        host.answer = .failed(.server(code: "title_stale", message: "The terminal already has a name from newer output"))
        host.append("a", "› add login regression tests\r\nUpdated\r\n")
        namer.answers = ["Add login regression tests"]
        await naming.passNow()
        XCTAssertEqual(host.names.count, 1)
        await naming.passNow()
        XCTAssertEqual(host.names.count, 1)
    }

    func testOffLowPowerOrNoModelReadsNothingAndTheSwitchStopsItAtOnce() async throws {
        let host = FakeNamingHost()
        host.add("a", output: "› fix the login redirect\r\nDone\r\n", projectID: "p")
        let namer = FakeTerminalNamer(["Fix the login redirect"])
        let naming = naming(host, namer: namer)
        defaults.set(false, forKey: AppleIntelligence.settingKey)
        // The preferences' change reaches it without being told.
        try await waitForCondition("naming to stop") { !naming.isRunning }
        await naming.passNow()
        XCTAssertEqual(host.lists, 0)
        defaults.set(true, forKey: AppleIntelligence.settingKey)
        try await waitForCondition("naming to start again") { naming.isRunning }
        naming.lowPowerMode = { true }
        await naming.passNow()
        XCTAssertEqual(host.lists, 0, "Nothing in Low Power Mode")
        naming.lowPowerMode = { false }
        namer.available = false
        await naming.passNow()
        XCTAssertEqual(host.lists, 0, "Nothing without the model")
        namer.available = true
        await naming.passNow()
        XCTAssertEqual(host.names.map(\.title), ["Fix the login redirect"])
        naming.hostStopped()
        XCTAssertFalse(naming.isRunning)
        host.append("a", "› add login regression tests\r\nUpdated\r\n")
        await naming.passNow()
        XCTAssertEqual(host.lists, 1, "A stopped host is not read")
    }

    func testANameArrivingAfterTheSwitchWentOffIsDropped() async {
        let host = FakeNamingHost()
        host.add("a", output: "› fix the login redirect\r\nDone\r\n", projectID: "p")
        let namer = FakeTerminalNamer(["Fix the login redirect"])
        let suite = self.suite
        namer.whileNaming = { UserDefaults(suiteName: suite)?.set(false, forKey: AppleIntelligence.settingKey) }
        let naming = naming(host, namer: namer)
        await naming.passNow()
        XCTAssertEqual(namer.prompts.count, 1)
        XCTAssertTrue(host.names.isEmpty)
    }

    func testTheScreenIsTheNewest256KBOfOutput() async throws {
        let host = FakeNamingHost()
        let old = String(repeating: "x", count: 300 << 10)
        host.add("a", output: old + "\r\n› fix the login redirect\r\nDone\r\n", projectID: "p")
        let listed = try await host.terminals()
        let terminal = try XCTUnwrap(listed.first)
        let read = try await HostTerminalNaming.read(terminal, from: host)
        XCTAssertEqual(read?.cursor, host.end("a"))
        XCTAssertEqual(read?.data.count, Int(HostTerminalNaming.outputRead))
        XCTAssertEqual(host.reads.first?.cursor, host.end("a") - HostTerminalNaming.outputRead)
        XCTAssertTrue(String(decoding: read?.data ?? Data(), as: UTF8.self).hasSuffix("Done\r\n"))
    }
}

/// A host's terminals and their output, read 64 KB at a time as the host answers.
private final class FakeNamingHost: TerminalNamingHost, @unchecked Sendable {
    struct Terminal {
        var listed: HostTerminal
        var output: Data
    }
    private let lock = NSLock()
    private var all: [Terminal] = []
    private var _lists = 0
    private var _reads: [(id: String, cursor: UInt64)] = []
    private var _names: [(id: String, title: String, basedOn: UInt64)] = []
    private var _answer = SendOutcome.accepted

    var lists: Int { lock.withLock { _lists } }
    var reads: [(id: String, cursor: UInt64)] { lock.withLock { _reads } }
    var names: [(id: String, title: String, basedOn: UInt64)] { lock.withLock { _names } }
    var answer: SendOutcome {
        get { lock.withLock { _answer } }
        set { lock.withLock { _answer = newValue } }
    }

    func add(_ id: String, output: String, projectID: String, status: String = "running", routed: Bool = false,
             rows: Int? = nil, cols: Int? = nil, title: String = "Shell", source: String? = nil) {
        let data = Data(output.utf8)
        lock.withLock {
            all.append(Terminal(listed: Self.listing(id, projectID: projectID, status: status, routed: routed, rows: rows, cols: cols,
                                                     title: title, source: source, cursor: UInt64(data.count)), output: data))
        }
    }

    func append(_ id: String, _ text: String) {
        lock.withLock {
            guard let index = all.firstIndex(where: { $0.listed.id == id }) else { return }
            all[index].output.append(Data(text.utf8))
            let old = all[index].listed
            all[index].listed = Self.listing(id, projectID: old.projectId, status: old.status, routed: old.routed, rows: old.rows,
                                             cols: old.cols, title: old.title, source: old.contextTitleSource,
                                             cursor: UInt64(all[index].output.count))
        }
    }

    func end(_ id: String) -> UInt64 { lock.withLock { UInt64(all.first { $0.listed.id == id }?.output.count ?? 0) } }

    private static func listing(_ id: String, projectID: String, status: String, routed: Bool, rows: Int?, cols: Int?,
                                title: String, source: String?, cursor: UInt64) -> HostTerminal {
        HostTerminal(id: id, deviceId: routed ? "local-mac" : "d1", deviceName: routed ? "This Mac" : "Phone", projectId: projectID,
                     program: "claude", title: title, status: status, startedAt: Date(), routed: routed, rows: rows, cols: cols,
                     cursor: cursor, contextTitleSource: source)
    }

    func terminals() async throws -> [HostTerminal] {
        lock.withLock { _lists += 1; return all.map(\.listed) }
    }

    func output(projectID: String, terminalID: String, cursor: UInt64) async throws -> TerminalOutput {
        lock.withLock {
            _reads.append((terminalID, cursor))
            let data = all.first { $0.listed.id == terminalID }?.output ?? Data()
            let begin = min(Int(cursor), data.count), end = min(begin + (64 << 10), data.count)
            return TerminalOutput(data: data[begin..<end].base64EncodedString(), cursor: UInt64(end), end: UInt64(data.count),
                                  reset: false, status: .running, exitCode: nil)
        }
    }

    func name(projectID: String, terminalID: String, title: String, basedOn: UInt64) async -> SendOutcome {
        lock.withLock {
            _names.append((terminalID, title, basedOn))
            return _answer
        }
    }
}

/// The model: its answers in order, what it was asked, and whether it is available.
private final class FakeTerminalNamer: ChatNamer, @unchecked Sendable {
    private let lock = NSLock()
    private var _answers: [String]
    private var _prompts: [String] = []
    private var _available = true
    var whileNaming: (@Sendable () -> Void)?

    init(_ answers: [String]) { _answers = answers }

    var answers: [String] {
        get { lock.withLock { _answers } }
        set { lock.withLock { _answers = newValue } }
    }
    var prompts: [String] { lock.withLock { _prompts } }
    var available: Bool {
        get { lock.withLock { _available } }
        set { lock.withLock { _available = newValue } }
    }

    var isAvailable: Bool { available }

    func name(for input: ChatNamingInput) async -> String? {
        let answer: String? = lock.withLock {
            _prompts.append(input.prompt)
            return _answers.isEmpty ? nil : _answers.removeFirst()
        }
        whileNaming?()
        return answer
    }
}
