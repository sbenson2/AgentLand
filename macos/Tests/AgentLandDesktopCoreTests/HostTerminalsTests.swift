import Foundation
import XCTest
import AgentLandCore
@testable import AgentLandDesktopCore
@testable import AgentLandDesktop

/// The Mac-only terminal routes as the Mac reads them, the Quit question and the terminal-access switch.
final class HostTerminalsTests: XCTestCase {
    @MainActor
    private func connected(_ fixture: RestartFixture, feed: FakeTerminalsFeed?) async throws -> HostController {
        let host = try fixture.connectedController(backoff: RestartBackoff(delays: [30], limit: 3, window: 60), terminals: feed)
        let deadline = Date().addingTimeInterval(10)
        while !(host.status == .running && !host.isWorking) {
            guard Date() < deadline else { throw DesktopError.commandFailed("The host did not start.") }
            try await Task.sleep(for: .milliseconds(10))
        }
        return host
    }

    @MainActor
    func testOnlyTheDeliberateQuitAsks() async throws {
        let fixture = try RestartFixture(); defer { fixture.cleanUp() }
        let feed = FakeTerminalsFeed(running: 2)
        let host = try await connected(fixture, feed: feed)
        var asked = false
        let result = await host.prepareQuit { _ in asked = true; return .cancel }
        XCTAssertTrue(result)
        XCTAssertFalse(asked)
        XCTAssertEqual(feed.calls, [], "a quit that is not deliberate does not even ask the host")
    }

    @MainActor
    func testKeepRunningQuitsWithoutEnding() async throws {
        let fixture = try RestartFixture(); defer { fixture.cleanUp() }
        let feed = FakeTerminalsFeed(running: 2)
        let host = try await connected(fixture, feed: feed)
        host.deliberateQuit = true
        var counts: [HostRunningCount] = []
        let result = await host.prepareQuit { count in counts.append(count); return .keepRunning }
        XCTAssertTrue(result)
        XCTAssertEqual(counts, [HostRunningCount(running: 2, routed: 0)])
        XCTAssertEqual(feed.calls, ["running"])
    }

    @MainActor
    func testEndTerminalsEndsThemBeforeStopping() async throws {
        let fixture = try RestartFixture(); defer { fixture.cleanUp() }
        let log = TerminalCallLog()
        let feed = FakeTerminalsFeed(running: 3, log: log)
        fixture.processes.onTerminate = { log.add("terminate") }
        let host = try await connected(fixture, feed: feed)
        host.deliberateQuit = true
        let result = await host.prepareQuit { _ in .endTerminals }
        XCTAssertTrue(result)
        try await host.stopForApplicationTermination()
        XCTAssertEqual(log.events, ["running", "endAll", "terminate"])
    }

    @MainActor
    func testCancelKeepsTheAppRunning() async throws {
        let fixture = try RestartFixture(); defer { fixture.cleanUp() }
        let feed = FakeTerminalsFeed(running: 1)
        let host = try await connected(fixture, feed: feed)
        host.deliberateQuit = true
        let result = await host.prepareQuit { _ in .cancel }
        XCTAssertFalse(result)
        XCTAssertFalse(host.deliberateQuit)
        XCTAssertFalse(feed.calls.contains("endAll"))
    }

    @MainActor
    func testAHostThatDoesNotAnswerQuitsSilently() async throws {
        let fixture = try RestartFixture(); defer { fixture.cleanUp() }
        let feed = FakeTerminalsFeed(running: 2)
        feed.failWith(ClientError.server(code: "terminal_disabled", message: "off"))
        let host = try await connected(fixture, feed: feed)
        host.deliberateQuit = true
        var asked = false
        let result = await host.prepareQuit { _ in asked = true; return .cancel }
        XCTAssertTrue(result)
        XCTAssertFalse(asked)

        let none = FakeTerminalsFeed(running: 0)
        let quiet = try await connected(RestartFixture(), feed: none)
        quiet.deliberateQuit = true
        let quietResult = await quiet.prepareQuit { _ in asked = true; return .cancel }
        XCTAssertTrue(quietResult)
        XCTAssertFalse(asked, "nothing running, nothing to ask")
    }

    func testQuitTextCountsTerminals() {
        XCTAssertEqual(QuitText.title, "Keep terminals running?")
        XCTAssertEqual(QuitText.message(1), "1 terminal is running on this Mac. They can keep running after AgentLand quits; you’ll find them when it starts again.")
        XCTAssertEqual(QuitText.message(3), "3 terminals are running on this Mac. They can keep running after AgentLand quits; you’ll find them when it starts again.")
        XCTAssertEqual(QuitText.keep, "Keep Running")
        XCTAssertEqual(QuitText.end, "End Terminals")
        XCTAssertEqual(AdvancedText.endTerminalsTitle, "End running terminals?")
        XCTAssertEqual(AdvancedText.endTerminalsMessage(1), "Turning this off ends the 1 terminal running on this Mac.")
        XCTAssertEqual(AdvancedText.endTerminalsMessage(2), "Turning this off ends the 2 terminals running on this Mac.")
    }

    /// Agents typed in Terminal are released to their windows when AgentLand ends its terminals, so both questions say so.
    func testQuitTextSaysAgentsInTerminalKeepRunning() {
        XCTAssertEqual(QuitText.message(2, routed: 1), "2 terminals are running on this Mac. They can keep running after AgentLand quits; you’ll find them when it starts again. Agents open in Terminal keep running there.")
        XCTAssertEqual(QuitText.message(2), "2 terminals are running on this Mac. They can keep running after AgentLand quits; you’ll find them when it starts again.")
        XCTAssertEqual(QuitText.message(2, routed: 0), QuitText.message(2))
        XCTAssertEqual(AdvancedText.endTerminalsMessage(2, routed: 1), "Turning this off ends the 2 terminals running on this Mac. Agents open in Terminal keep running there.")
        XCTAssertEqual(AdvancedText.endTerminalsMessage(nil, routed: 0), "Turning this off ends every terminal running on this Mac.")
        XCTAssertEqual(AdvancedText.agentsKeepRunning, "Agents open in Terminal keep running there.")
        XCTAssertEqual(AdvancedText.agentsKeepRunning, QuitText.agentsKeepRunning, "one sentence, one source")
    }

    /// The Quit question and the switch's question get how many of the running terminals are agents in Terminal.
    @MainActor
    func testTheQuestionsCountAgentsInTerminal() async throws {
        let fixture = try RestartFixture(); defer { fixture.cleanUp() }
        let feed = FakeTerminalsFeed(running: 3, routed: 1)
        let host = try await connectedWithTerminals(fixture, feed: feed)
        let step = await host.terminalsOffStep()
        XCTAssertEqual(step, .ask(3, routed: 1))
        host.deliberateQuit = true
        var asked: [HostRunningCount] = []
        _ = await host.prepareQuit { count in asked.append(count); return .keepRunning }
        XCTAssertEqual(asked, [HostRunningCount(running: 3, routed: 1)])
    }

    func testRunningCountDecodesRouted() async throws {
        let base = URL(string: "https://127.0.0.1:9841")!
        let both = HostTerminalsFeed(baseURL: base, token: "t", transport: FakeAgentsTransport(status: 200, body: #"{"running":2,"routed":1}"#))
        let counted = try await both.runningCount(within: 1)
        XCTAssertEqual(counted, HostRunningCount(running: 2, routed: 1))
        let older = HostTerminalsFeed(baseURL: base, token: "t", transport: FakeAgentsTransport(status: 200, body: #"{"running":2}"#))
        let olderCount = try await older.runningCount(within: 1)
        XCTAssertEqual(olderCount, HostRunningCount(running: 2, routed: 0), "a host before routing counts none")
        let odd = HostTerminalsFeed(baseURL: base, token: "t", transport: FakeAgentsTransport(status: 200, body: #"{"running":2,"routed":"x"}"#))
        let oddCount = try await odd.runningCount(within: 1)
        XCTAssertEqual(oddCount.routed, 0)
        let none = HostTerminalsFeed(baseURL: base, token: "t", transport: FakeAgentsTransport(status: 200, body: #"{"routed":1}"#))
        do { _ = try await none.runningCount(within: 1); XCTFail("no running count is no answer") }
        catch { XCTAssertEqual(error as? ClientError, .decoding) }
    }

    func testHostTerminalDecodesRouted() throws {
        let decode = { (json: String) in try JSONDecoder().decode(HostTerminal.self, from: Data(json.utf8)) }
        let base = #""id":"t1","deviceId":"local-mac","deviceName":"This Mac","status":"running","startedAt":"2026-10-15T10:00:00Z""#
        XCTAssertTrue(try decode("{\(base),\"routed\":true}").routed)
        XCTAssertFalse(try decode("{\(base),\"routed\":false}").routed)
        XCTAssertFalse(try decode("{\(base)}").routed, "an older host lists none")
        XCTAssertFalse(try decode("{\(base),\"routed\":\"yes\"}").routed)
        XCTAssertFalse(HostTerminal(id: "t", deviceId: "d", deviceName: "x", status: "running", startedAt: Date()).routed)
    }

    /// What the Mac's naming of every terminal reads: the size, the output's end and the name's source; an older
    /// host lists none of them.
    func testHostTerminalDecodesWhatNamingReads() throws {
        let decode = { (json: String) in try JSONDecoder().decode(HostTerminal.self, from: Data(json.utf8)) }
        let base = #""id":"t1","deviceId":"d1","deviceName":"Phone","status":"running","startedAt":"2026-10-16T10:00:00Z""#
        let named = try decode("{\(base),\"rows\":40,\"cols\":100,\"cursor\":512,\"contextTitleSource\":\"device\"}")
        XCTAssertEqual(named.rows, 40)
        XCTAssertEqual(named.cols, 100)
        XCTAssertEqual(named.cursor, 512)
        XCTAssertEqual(named.contextTitleSource, "device")
        let older = try decode("{\(base)}")
        XCTAssertNil(older.rows)
        XCTAssertNil(older.cols)
        XCTAssertEqual(older.cursor, 0)
        XCTAssertNil(older.contextTitleSource)
    }

    func testRoutedTerminalCaptionSaysTerminal() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let started = now.addingTimeInterval(-2 * 3600 - 60)
        let routed = HostTerminal(id: "t1", deviceId: "local-mac", deviceName: "This Mac", workspace: "tower", status: "running",
                                  startedAt: started, routed: true)
        XCTAssertEqual(TerminalsText.caption(routed, now: now), "This Mac · Terminal · tower · running for 2h")
        let nowhere = HostTerminal(id: "t2", deviceId: "local-mac", deviceName: "This Mac", status: "running", startedAt: started, routed: true)
        XCTAssertEqual(TerminalsText.caption(nowhere, now: now), "This Mac · Terminal · No workspace · running for 2h")
        let ended = HostTerminal(id: "t3", deviceId: "local-mac", deviceName: "This Mac", status: "ended", startedAt: started,
                                 endedAt: now.addingTimeInterval(-3 * 3600 - 60), routed: true)
        XCTAssertEqual(TerminalsText.caption(ended, now: now), "This Mac · Terminal · No workspace · finished 3h ago")
        let device = HostTerminal(id: "t4", deviceId: "d1", deviceName: "Sam’s iPhone", status: "running", startedAt: started)
        XCTAssertEqual(TerminalsText.caption(device, now: now), "Sam’s iPhone · running for 2h", "a device's terminal is as before")
    }

    /// Open in Terminal's file: only this user can read or run it, it attaches that terminal, and an ID that isn't the
    /// keeper's kind never becomes a file name.
    @MainActor
    func testOpenInTerminalWritesAnAttachFileOnlyItsUserCanRun() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("agentland-open-\(UUID().uuidString)/AgentLand")
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let binary = URL(fileURLWithPath: "/Applications/AgentLand.app/Contents/MacOS/agentland-host")
        let file = try TerminalWindowOpener.write(terminalID: "term_0123456789abcdef", binary: binary, statePath: "/s/host.json", in: folder)
        XCTAssertEqual(file.url.lastPathComponent, "attach-term_0123456789abcdef.command")
        XCTAssertEqual(try String(contentsOf: file.url, encoding: .utf8),
                       TerminalAttachScript.contents(binary: binary.path, statePath: "/s/host.json", terminalID: "term_0123456789abcdef"))
        let mode = { (path: String) in (try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue }
        XCTAssertEqual(try mode(file.url.path), 0o700)
        XCTAssertEqual(try mode(folder.path), 0o700)
        XCTAssertNotNil(file.written)
        for bad in ["", "../x", "a/b", "a b", "ünï", String(repeating: "a", count: 129)] {
            XCTAssertThrowsError(try TerminalWindowOpener.write(terminalID: bad, binary: binary, statePath: "/s/host.json", in: folder), bad)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["attach-term_0123456789abcdef.command"])
    }

    // MARK: Coding agents from Terminal

    /// A host controller that runs only the hook commands (`HookRunner`); nothing else starts.
    @MainActor
    private func routingController(_ fixture: RestartFixture, runner: any HostCommandRunning) -> HostController {
        HostController(statePath: fixture.state.path, runner: runner, secrets: NoRestartSecrets(),
                       preferences: fixture.defaults, runtime: fixture.runtime)
    }

    private func hook(_ action: String, _ fixture: RestartFixture) -> [String] {
        ["terminals", "hook", action, "--state", fixture.state.path]
    }

    @MainActor
    func testTerminalRoutingRunsTheHookCommand() async throws {
        let fixture = try RestartFixture(); defer { fixture.cleanUp() }
        let runner = HookRunner()
        let host = routingController(fixture, runner: runner)
        host.terminalEnabled = true
        await host.setTerminalRouting(true)
        XCTAssertTrue(host.terminalRoutingEnabled)
        XCTAssertNil(host.terminalRoutingIssue)
        XCTAssertTrue(routingController(fixture, runner: runner).terminalRoutingEnabled, "saved for the next launch")
        await host.setTerminalRouting(false)
        XCTAssertFalse(host.terminalRoutingEnabled)
        XCTAssertEqual(runner.commands, [hook("on", fixture), hook("off", fixture)])
        XCTAssertFalse(host.changingTerminalRouting)

        let damaged = "AgentLand's block in /x/.zshrc is damaged. Remove the lines from \"# >>> AgentLand: coding agents from Terminal >>>\" to \"# <<< AgentLand: coding agents from Terminal <<<\" by hand, then try again."
        runner.fail(with: DesktopError.commandFailed(damaged + "\n"))
        await host.setTerminalRouting(true)
        XCTAssertFalse(host.terminalRoutingEnabled, "the switch goes back")
        XCTAssertEqual(host.terminalRoutingIssue, damaged, "the command's own words")
        XCTAssertNil(host.errorMessage, "only the switch shows it")
        XCTAssertFalse(routingController(fixture, runner: runner).terminalRoutingEnabled)

        runner.fail(with: nil)
        await host.setTerminalRouting(true)
        XCTAssertTrue(host.terminalRoutingEnabled)
        XCTAssertNil(host.terminalRoutingIssue, "a change that works clears it")

        // Off can fail after it already turned routing off; the switch never claims off then.
        runner.fail(with: DesktopError.commandFailed("/Users/x/.zshrc: permission denied"))
        await host.setTerminalRouting(false)
        XCTAssertTrue(host.terminalRoutingEnabled)
        XCTAssertEqual(host.terminalRoutingIssue, "/Users/x/.zshrc: permission denied")
        host.dismissTerminalRoutingIssue()
        XCTAssertNil(host.terminalRoutingIssue)
    }

    @MainActor
    func testTurningTerminalAccessOffPausesRouting() async throws {
        let fixture = try RestartFixture(); defer { fixture.cleanUp() }
        let log = TerminalCallLog()
        fixture.runner.log = log
        fixture.processes.onTerminate = { log.add("stop host") }
        let host = try await connectedWithTerminals(fixture, feed: FakeTerminalsFeed(running: 0, log: log))
        host.terminalRoutingEnabled = true
        await host.turnTerminalsOffNow()
        XCTAssertFalse(host.terminalEnabled)
        XCTAssertTrue(host.terminalRoutingEnabled, "kept, paused until terminal access is back")
        XCTAssertEqual(fixture.runner.hooks, [hook("pause", fixture)])
        XCTAssertEqual(log.events, ["hook pause", "stop host"], "paused before the host restarts without terminals")

        host.turnTerminalsOn()
        XCTAssertTrue(host.terminalEnabled, "at once, as the switch always did")
        await host.waitForTerminalRouting()
        XCTAssertEqual(fixture.runner.hooks, [hook("pause", fixture), hook("on", fixture)])

        // End Terminals pauses it the same way.
        await host.turnOffTerminals()
        XCTAssertFalse(host.terminalEnabled)
        XCTAssertEqual(fixture.runner.hooks.last, hook("pause", fixture))

        // With routing off, terminal access changes run no hook.
        let runner = HookRunner()
        let quiet = routingController(fixture, runner: runner)
        quiet.terminalRoutingEnabled = false
        quiet.terminalEnabled = true
        await quiet.turnTerminalsOffNow()
        quiet.turnTerminalsOn()
        await quiet.waitForTerminalRouting()
        XCTAssertEqual(runner.commands, [])
    }

    @MainActor
    func testLaunchRefreshesTheHookWhenRoutingIsOn() async throws {
        let fixture = try RestartFixture(); defer { fixture.cleanUp() }
        let saved = routingController(fixture, runner: HookRunner())
        saved.terminalEnabled = true
        saved.terminalRoutingEnabled = true

        // On: the hook is written again, so it names the host where the app is now.
        let launched = routingController(fixture, runner: fixture.runner)
        launched.load()
        try await waitForCondition("the hook") { fixture.runner.hooks.count == 1 }
        XCTAssertEqual(fixture.runner.hooks, [hook("on", fixture)])

        // Terminal access off: paused.
        saved.terminalEnabled = false
        let paused = routingController(fixture, runner: fixture.runner)
        paused.load()
        try await waitForCondition("the hook") { fixture.runner.hooks.count == 2 }
        XCTAssertEqual(fixture.runner.hooks.last, hook("pause", fixture))

        // Routing off: nothing.
        saved.terminalRoutingEnabled = false
        let off = routingController(fixture, runner: fixture.runner)
        off.load()
        await off.waitForCurrentOperation()
        await off.waitForTerminalRouting()
        XCTAssertEqual(fixture.runner.hooks.count, 2)

        // A launch whose hook fails keeps the switch and says why.
        saved.terminalEnabled = true
        saved.terminalRoutingEnabled = true
        let failing = HookRunner()
        failing.fail(with: DesktopError.commandFailed("AgentLand's block in /x/.zshrc is damaged."))
        let broken = routingController(fixture, runner: failing)
        broken.load()
        try await waitForCondition("the issue") { broken.terminalRoutingIssue != nil }
        XCTAssertEqual(broken.terminalRoutingIssue, "AgentLand's block in /x/.zshrc is damaged.")
        XCTAssertTrue(broken.terminalRoutingEnabled)
    }

    // MARK: Fix round 1

    /// Ruling 41: the off direction is always allowed, even while terminal access is off; turning on still needs it.
    @MainActor
    func testRoutingCanAlwaysBeTurnedOff() async throws {
        let fixture = try RestartFixture(); defer { fixture.cleanUp() }
        let runner = HookRunner()
        let host = routingController(fixture, runner: runner)
        host.terminalEnabled = false
        host.terminalRoutingEnabled = true
        XCTAssertFalse(host.terminalRoutingSwitchDisabled, "routing on with access off: the switch can turn it off")
        await host.setTerminalRouting(false)
        XCTAssertFalse(host.terminalRoutingEnabled)
        XCTAssertEqual(runner.commands, [hook("off", fixture)])
        XCTAssertTrue(host.terminalRoutingSwitchDisabled, "routing off with access off: nothing to turn on")
        host.terminalEnabled = true
        XCTAssertFalse(host.terminalRoutingSwitchDisabled)
    }

    /// A failed `on` keeps its words when terminal access goes off during it: no `pause` is queued for a switch that
    /// reverts to off.
    @MainActor
    func testAFailedOnKeepsItsWordsWhenAccessGoesOffDuringIt() async throws {
        let fixture = try RestartFixture(); defer { fixture.cleanUp() }
        let runner = HookRunner()
        runner.failOnly("on", with: DesktopError.commandFailed("damaged block"))
        runner.slow(0.2)
        let host = routingController(fixture, runner: runner)
        host.terminalEnabled = true
        let change = Task { await host.setTerminalRouting(true) }
        try await waitForCondition("the hook starts") { host.changingTerminalRouting }
        await host.turnTerminalsOffNow()
        await change.value
        await host.waitForTerminalRouting()
        XCTAssertEqual(runner.commands, [hook("on", fixture)], "no pause for a switch that went back to off")
        XCTAssertEqual(host.terminalRoutingIssue, "damaged block")
        XCTAssertFalse(host.terminalRoutingEnabled)
        XCTAssertFalse(host.terminalEnabled)
    }

    /// An unreadable count with routing on still says the agents in Terminal keep running.
    @MainActor
    func testAnUnknownCountStillSaysAgentsKeepRunning() async throws {
        let fixture = try RestartFixture(); defer { fixture.cleanUp() }
        let feed = FakeTerminalsFeed(running: 1)
        let host = try await connectedWithTerminals(fixture, feed: feed)
        let unavailable = ClientError.server(code: "terminals_unavailable", message: "not answering")
        host.terminalRoutingEnabled = true
        feed.failNext("running", unavailable)
        let step = await host.terminalsOffStep()
        guard case let .ask(count, routed) = step else { return XCTFail("\(step)") }
        XCTAssertNil(count)
        XCTAssertGreaterThan(routed, 0)
        XCTAssertTrue(AdvancedText.endTerminalsMessage(count, routed: routed).hasSuffix(" " + AdvancedText.agentsKeepRunning))
        host.terminalRoutingEnabled = false
        feed.failNext("running", unavailable)
        let plain = await host.terminalsOffStep()
        XCTAssertEqual(plain, .ask(nil))
    }

    /// Attach files an earlier run left (the app quit within their lifetime) go on the next open.
    @MainActor
    func testStaleAttachFilesAreRemoved() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("agentland-stale-\(UUID().uuidString)/AgentLand")
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let binary = URL(fileURLWithPath: "/Applications/AgentLand.app/Contents/MacOS/agentland-host")
        let old = try TerminalWindowOpener.write(terminalID: "term_old", binary: binary, statePath: "/s/host.json", in: folder)
        let other = folder.appendingPathComponent("notes.txt")
        try Data("keep".utf8).write(to: other)
        let past = Date().addingTimeInterval(-120)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: old.url.path)
        let fresh = try TerminalWindowOpener.write(terminalID: "term_new", binary: binary, statePath: "/s/host.json", in: folder)
        TerminalWindowOpener.removeStale(in: folder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.url.path), "a recent one may still be waiting for Terminal")
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path), "only attach-*.command files")
    }

    /// Open in Terminal's failure has a title of its own, not the other actions'.
    @MainActor
    func testOpenInTerminalFailureHasItsOwnTitle() async throws {
        let fixture = try RestartFixture(); defer { fixture.cleanUp() }
        let host = routingController(fixture, runner: HookRunner())
        // Its own folder: the test never clears the real `$TMPDIR/AgentLand`.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("agentland-open-\(UUID().uuidString)/AgentLand")
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        host.terminalAttachFolder = folder
        XCTAssertEqual(TerminalsText.openFailedTitle, "Couldn’t open it in Terminal")
        XCTAssertNotEqual(TerminalsText.openFailedTitle, TerminalsText.actionFailedTitle)
        await host.openInTerminal("a b")   // not an ID the keeper makes: fails whether or not Terminal is installed
        XCTAssertNotNil(host.terminalActionError)
        XCTAssertEqual(host.terminalActionErrorTitle, TerminalsText.openFailedTitle)
    }

    @MainActor
    func testTurningTerminalsOffEndsThemFirst() async throws {
        let fixture = try RestartFixture(); defer { fixture.cleanUp() }
        let feed = FakeTerminalsFeed(running: 2)
        let host = try await connected(fixture, feed: feed)
        host.terminalEnabled = true
        await host.turnOffTerminals()
        XCTAssertEqual(feed.calls, ["endAll", "running"])
        XCTAssertFalse(host.terminalEnabled)

        let bare = HostController(statePath: fixture.state.path, preferences: fixture.defaults)
        bare.terminalEnabled = true
        await bare.turnOffTerminals()
        XCTAssertFalse(bare.terminalEnabled, "with no host it just turns off")
    }

    @MainActor
    func testSwitchStaysOnWhenEndAllFails() async throws {
        let fixture = try RestartFixture(); defer { fixture.cleanUp() }
        let feed = FakeTerminalsFeed(running: 2)
        feed.failEndAll(ClientError.server(code: "terminals_unavailable", message: "The terminal service is busy."))
        let host = try await connected(fixture, feed: feed)
        host.terminalEnabled = true
        let off = await host.turnOffTerminals()
        XCTAssertFalse(off)
        XCTAssertTrue(host.terminalEnabled)
        XCTAssertNotNil(host.errorMessage)
        XCTAssertFalse(host.endingTerminals)
    }

    @MainActor
    func testSwitchStaysOnWhenSomeTerminalsStillRun() async throws {
        let fixture = try RestartFixture(); defer { fixture.cleanUp() }
        let feed = FakeTerminalsFeed(running: 3)
        feed.endAllLeaves(1)
        let host = try await connected(fixture, feed: feed)
        host.terminalEnabled = true
        let off = await host.turnOffTerminals()
        XCTAssertFalse(off)
        XCTAssertTrue(host.terminalEnabled)
        XCTAssertTrue(host.errorMessage?.contains("1 terminal is still running") ?? false)
    }

    @MainActor
    func testTerminalsAlreadyOffTurnsOffQuietly() async throws {
        let fixture = try RestartFixture(); defer { fixture.cleanUp() }
        let feed = FakeTerminalsFeed(running: 2)
        feed.failEndAll(ClientError.server(code: "terminal_disabled", message: "off"))
        let host = try await connected(fixture, feed: feed)
        host.terminalEnabled = true
        let off = await host.turnOffTerminals()
        XCTAssertTrue(off)
        XCTAssertFalse(host.terminalEnabled)
        XCTAssertNil(host.errorMessage)
    }

    @MainActor
    func testASecondOffRequestWhileOneRunsDoesNotEndAllTwice() async throws {
        let fixture = try RestartFixture(); defer { fixture.cleanUp() }
        let feed = FakeTerminalsFeed(running: 2)
        feed.delayEndAll(.milliseconds(300))
        let host = try await connected(fixture, feed: feed)
        host.terminalEnabled = true
        async let first = host.turnOffTerminals()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(host.endingTerminals)
        let second = await host.turnOffTerminals()
        XCTAssertFalse(second)
        let firstResult = await first
        XCTAssertTrue(firstResult)
        XCTAssertEqual(feed.calls.filter { $0 == "endAll" }.count, 1)
    }

    /// A host launched with terminals on, as the switch finds it when the owner turns it off.
    @MainActor
    private func connectedWithTerminals(_ fixture: RestartFixture, feed: FakeTerminalsFeed) async throws -> HostController {
        let host = try fixture.connectedController(backoff: RestartBackoff(delays: [30], limit: 3, window: 60), terminals: feed, connect: false)
        host.terminalEnabled = true
        host.start()
        try await waitForCondition("the host to start") { host.status == .running && !host.isWorking }
        XCTAssertTrue(fixture.processes.last?.command.arguments.contains("--enable-terminal") ?? false)
        return host
    }

    @MainActor
    func testSwitchingOffWithTheHostRunningEndsThemThenRestartsOnlyTheHost() async throws {
        let fixture = try RestartFixture(); defer { fixture.cleanUp() }
        let log = TerminalCallLog()
        fixture.processes.onTerminate = { log.add("stop host") }
        let feed = FakeTerminalsFeed(running: 2, log: log)
        let host = try await connectedWithTerminals(fixture, feed: feed)
        let hosts = fixture.processes.count
        let openCodeStarts = await fixture.runtime.starts

        let step = await host.terminalsOffStep()
        XCTAssertEqual(step, .ask(2))
        XCTAssertTrue(host.terminalEnabled, "asking changes nothing")
        let off = await host.turnOffTerminals()
        XCTAssertTrue(off)
        XCTAssertFalse(host.terminalEnabled)
        XCTAssertFalse(host.endingTerminals, "the switch's progress lasts until the host is back")
        XCTAssertEqual(log.events, ["running", "endAll", "running", "stop host"])
        XCTAssertEqual(fixture.processes.count, hosts + 1, "the host restarted once")
        XCTAssertFalse(fixture.processes.last?.command.arguments.contains("--enable-terminal") ?? true,
                       "the new host runs with terminals off")
        let startsAfter = await fixture.runtime.starts
        XCTAssertEqual(startsAfter, openCodeStarts, "OpenCode keeps running")
        XCTAssertEqual(host.status, .running)
        XCTAssertNil(host.errorMessage)
    }

    @MainActor
    func testSwitchingOffWithNoneRunningRestartsOnlyTheHost() async throws {
        let fixture = try RestartFixture(); defer { fixture.cleanUp() }
        let feed = FakeTerminalsFeed(running: 0)
        let host = try await connectedWithTerminals(fixture, feed: feed)
        let hosts = fixture.processes.count
        let step = await host.terminalsOffStep()
        XCTAssertEqual(step, .turnOff)
        await host.turnTerminalsOffNow()
        XCTAssertFalse(host.terminalEnabled)
        XCTAssertEqual(feed.calls, ["running"], "nothing to end")
        XCTAssertEqual(fixture.processes.count, hosts + 1)
        XCTAssertFalse(fixture.processes.last?.command.arguments.contains("--enable-terminal") ?? true)
        XCTAssertEqual(host.status, .running)
    }

    @MainActor
    func testACountTheSwitchCannotReadAsksAndStaysOnWhileTheServiceIsUnusable() async throws {
        let fixture = try RestartFixture(); defer { fixture.cleanUp() }
        let feed = FakeTerminalsFeed(running: 1)
        let host = try await connectedWithTerminals(fixture, feed: feed)
        // What the real host sends while the keeper is unusable: 503 terminals_unavailable, on running and end-all alike.
        let unavailable = ClientError.server(code: "terminals_unavailable", message: "AgentLand's terminal service isn't answering; your terminals are still running.")
        feed.failNext("running", unavailable)
        let step = await host.terminalsOffStep()
        XCTAssertEqual(step, .ask(nil))
        XCTAssertTrue(host.terminalEnabled, "never a silent off")
        XCTAssertEqual(feed.calls, ["running"])
        feed.failEndAll(unavailable)
        let off = await host.turnOffTerminals()
        XCTAssertFalse(off, "end-all answers 503 too: the error shows and the switch stays on")
        XCTAssertTrue(host.terminalEnabled)
        XCTAssertEqual(feed.calls, ["running", "endAll"])
    }

    @MainActor
    func testAnUnusableTerminalServiceQuitsSilently() async throws {
        let fixture = try RestartFixture(); defer { fixture.cleanUp() }
        let feed = FakeTerminalsFeed(running: 2)
        feed.failWith(ClientError.server(code: "terminals_unavailable", message: "AgentLand's terminal service isn't answering; your terminals are still running."))
        let host = try await connected(fixture, feed: feed)
        host.deliberateQuit = true
        var asked = false
        let result = await host.prepareQuit { _ in asked = true; return .cancel }
        XCTAssertTrue(result, "quits, leaving the terminals running")
        XCTAssertFalse(asked)
        XCTAssertFalse(feed.calls.contains("endAll"))
    }

    @MainActor
    func testWithNoHostTheSwitchOnlySavesThePreference() async throws {
        let fixture = try RestartFixture(); defer { fixture.cleanUp() }
        let host = try fixture.connectedController(backoff: RestartBackoff(delays: [30], limit: 3, window: 60),
                                                   terminals: FakeTerminalsFeed(running: 2), connect: false)
        host.terminalEnabled = true
        let step = await host.terminalsOffStep()
        XCTAssertEqual(step, .turnOff)
        await host.turnTerminalsOffNow()
        XCTAssertFalse(host.terminalEnabled)
        XCTAssertEqual(fixture.processes.count, 0, "no host starts")
        XCTAssertFalse(HostController(statePath: fixture.state.path, preferences: fixture.defaults).terminalEnabled,
                       "the preference is saved")
    }

    func testTerminalsOffShowsOnlyTheNotice() {
        let now = Date()
        XCTAssertEqual(TerminalsText.listContent(off: true, terminals: nil, issue: nil), .hidden)
        XCTAssertEqual(TerminalsText.listContent(off: true, terminals: [], issue: nil), .hidden)
        XCTAssertEqual(TerminalsText.listContent(off: false, terminals: [], issue: nil), .empty)
        XCTAssertEqual(TerminalsText.listContent(off: false, terminals: [terminal("t1", started: now)], issue: nil), .rows)
        XCTAssertEqual(TerminalsText.listContent(off: false, terminals: nil, issue: nil), .loading)
        XCTAssertEqual(TerminalsText.listContent(off: false, terminals: nil, issue: "no answer"), .issue)
    }

    @MainActor
    func testTheReadinessWindowOutlastsTheHostsRestore() {
        // The host restores terminals (at most 5 s) before it listens; the app must not stop it meanwhile.
        XCTAssertGreaterThanOrEqual(HostController.readinessWindow, .seconds(10))
    }

    func testFeedCallsTheMacOnlyRoutes() async throws {
        let base = URL(string: "https://127.0.0.1:9841")!
        let list = """
        {"keeper":{"state":"unavailable","reason":"busy"},"terminals":[
         {"id":"t1","deviceId":"d1","deviceName":"iPhone","deviceRemoved":false,"projectId":"p","workspace":"/w","program":"zsh",
          "title":"build","status":"running","startedAt":"2026-10-14T10:00:00.123Z"},
         {"id":"t2","deviceId":"d2","deviceName":"","deviceRemoved":true,"projectId":"p","workspace":"/w","program":"zsh",
          "title":"","status":"exited","startedAt":"2026-10-14T09:00:00Z","endedAt":"2026-10-14T09:30:00.5Z","reason":"endedOnMac"}]}
        """
        let transport = FakeAgentsTransport(status: 200, body: list)
        let feed = HostTerminalsFeed(baseURL: base, token: "session-token", transport: transport)
        let all = try await feed.list()
        XCTAssertEqual(all.keeper, KeeperState(state: "unavailable", reason: "busy"))
        XCTAssertEqual(all.terminals.map(\.id), ["t1", "t2"])
        XCTAssertEqual(all.terminals[0].startedAt.timeIntervalSince1970, 1_791_972_000.123, accuracy: 0.001)
        XCTAssertNil(all.terminals[0].endedAt)
        XCTAssertTrue(all.terminals[1].deviceRemoved)
        XCTAssertEqual(all.terminals[1].reason, "endedOnMac")
        XCTAssertNotNil(all.terminals[1].endedAt)
        let get = transport.requests[0]
        XCTAssertEqual(get.url?.path, "/v1/terminals/all")
        XCTAssertEqual(get.httpMethod, "GET")
        XCTAssertEqual(get.value(forHTTPHeaderField: "Authorization"), "Bearer session-token")

        let unknown = FakeAgentsTransport(status: 200, body: #"{"keeper":{"state":"warming"},"terminals":[]}"#)
        let odd = try await HostTerminalsFeed(baseURL: base, token: "t", transport: unknown).list()
        XCTAssertEqual(odd.keeper.state, "warming")

        let counting = FakeAgentsTransport(status: 200, body: #"{"running":4,"ended":2}"#)
        let counts = HostTerminalsFeed(baseURL: base, token: "t", transport: counting)
        let running = try await counts.runningCount(within: 1)
        XCTAssertEqual(running, HostRunningCount(running: 4, routed: 0))
        XCTAssertEqual(counting.requests[0].url?.path, "/v1/terminals/running")
        XCTAssertEqual(counting.requests[0].timeoutInterval, 1)
        let ended = try await counts.endAll()
        XCTAssertEqual(ended, 2)
        XCTAssertEqual(counting.requests[1].url?.path, "/v1/terminals/end-all")
        XCTAssertEqual(counting.requests[1].httpMethod, "POST")
        XCTAssertEqual(counting.requests[1].timeoutInterval, 15)
        XCTAssertEqual(String(data: counting.requests[1].httpBody ?? Data(), encoding: .utf8), "{}")
        try await counts.end(terminalID: "t1")
        XCTAssertEqual(counting.requests[2].url?.path, "/v1/terminals/end")
        XCTAssertEqual(String(data: counting.requests[2].httpBody ?? Data(), encoding: .utf8), #"{"terminalId":"t1"}"#)
        try await counts.clear(terminalID: "t2")
        XCTAssertEqual(counting.requests[3].url?.path, "/v1/terminals/clear")
        XCTAssertEqual(String(data: counting.requests[3].httpBody ?? Data(), encoding: .utf8), #"{"terminalId":"t2"}"#)
        let deviceEnded = try await counts.endDevice("d1")
        XCTAssertEqual(deviceEnded, 2)
        XCTAssertEqual(counting.requests[4].url?.path, "/v1/terminals/end-device")
        XCTAssertEqual(String(data: counting.requests[4].httpBody ?? Data(), encoding: .utf8), #"{"deviceId":"d1"}"#)
        XCTAssertEqual(counting.requests[4].value(forHTTPHeaderField: "Authorization"), "Bearer t")
        XCTAssertEqual(counting.requests[4].timeoutInterval, 25, "longer than the host's 20 s bound")

        let off = HostTerminalsFeed(baseURL: base, token: "t", transport: FakeAgentsTransport(status: 403,
            body: #"{"error":{"code":"terminal_disabled","message":"Terminals are off."}}"#))
        do { _ = try await off.runningCount(within: 1); XCTFail("an error envelope throws") }
        catch {
            XCTAssertTrue(HostTerminalsFeed.meansTerminalsOff(error))
            XCTAssertEqual(error as? ClientError, .server(code: "terminal_disabled", message: "Terminals are off."))
        }
    }
}

extension HostTerminalsTests {
    private func terminal(_ id: String, device: String = "Sam’s iPhone", removed: Bool = false, started: Date,
                          ended: Date? = nil) -> HostTerminal {
        HostTerminal(id: id, deviceId: "d1", deviceName: device, deviceRemoved: removed, workspace: "tower",
                     status: ended == nil ? "running" : "ended", startedAt: started, endedAt: ended)
    }

    func testTerminalRowsSayWhoWhereAndHowLong() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let running = terminal("t1", started: now.addingTimeInterval(-2 * 3600 - 60))
        XCTAssertEqual(TerminalsText.caption(running, now: now), "Sam’s iPhone · tower · running for 2h")
        let finished = terminal("t2", started: now.addingTimeInterval(-5 * 3600), ended: now.addingTimeInterval(-3 * 3600 - 60))
        XCTAssertEqual(TerminalsText.caption(finished, now: now), "Sam’s iPhone · tower · finished 3h ago")
        let removed = terminal("t3", removed: true, started: now.addingTimeInterval(-2 * 3600 - 60))
        XCTAssertEqual(TerminalsText.caption(removed, now: now), "Sam’s iPhone (removed) · tower · running for 2h")
    }

    func testTheUnavailableAndNotRunningWords() {
        XCTAssertEqual(TerminalsText.unavailable(reason: nil),
                       "AgentLand's terminal service isn't answering. Your terminals are still running.")
        // The host's reason is its own full sentence, shown once.
        let hosts = "AgentLand's terminal service isn't answering; your terminals are still running."
        XCTAssertEqual(TerminalsText.unavailable(reason: hosts), hosts)
        XCTAssertEqual(TerminalsText.notRunningTitle, "AgentLand isn't running")
        XCTAssertEqual(TerminalsText.notRunningDetail, "Start the server to see its terminals.")
    }

    func testRevokeAsksAboutRunningTerminals() {
        XCTAssertEqual(DevicesText.revokeMessage(count: 0), "It can no longer reach this Mac until it pairs again.")
        XCTAssertTrue(DevicesText.revokeMessage(count: 2).contains("2 terminals started from it are still running"))
        XCTAssertTrue(DevicesText.revokeMessage(count: 1).contains("1 terminal started from it is still running"))
        XCTAssertTrue(DevicesText.revokeMessage(count: 2).hasSuffix("Nobody can open them once the device is removed."))
    }

    @MainActor
    func testRevokingWithEndEndsTheDevicesTerminalsFirst() async throws {
        let fixture = try RestartFixture(); defer { fixture.cleanUp() }
        let log = TerminalCallLog()
        fixture.runner.log = log
        let host = try await connected(fixture, feed: FakeTerminalsFeed(running: 2, log: log))
        let device = ManagedDevice(id: "d1", status: "active", createdAt: "", name: "iPhone", isPresent: false)
        host.revoke(device, endingTerminals: true)
        try await waitForCondition("the revoke") { log.events.contains("revoke") }
        XCTAssertEqual(log.events.filter { $0 == "endDevice" || $0 == "revoke" }, ["endDevice", "revoke"])
    }

    @MainActor
    func testRevokingAndKeepingLeavesTheTerminalsAlone() async throws {
        let fixture = try RestartFixture(); defer { fixture.cleanUp() }
        let log = TerminalCallLog()
        fixture.runner.log = log
        let host = try await connected(fixture, feed: FakeTerminalsFeed(running: 2, log: log))
        host.revoke(ManagedDevice(id: "d1", status: "active", createdAt: "", name: "iPhone", isPresent: false), endingTerminals: false)
        try await waitForCondition("the revoke") { log.events.contains("revoke") }
        XCTAssertFalse(log.events.contains("endDevice"))
    }

    @MainActor
    func testTheListFollowsTheHostAndStopsWhenCancelled() async throws {
        let fixture = try RestartFixture(); defer { fixture.cleanUp() }
        let feed = FakeTerminalsFeed(running: 1)
        let host = try await connected(fixture, feed: feed)
        host.terminalsPollInterval = .milliseconds(10)
        let task = Task { await host.followTerminals() }
        try await waitForCondition("the list") { host.terminalList != nil }
        task.cancel()
        await task.value
        let calls = feed.calls.filter { $0 == "list" }.count
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(feed.calls.filter { $0 == "list" }.count, calls, "a closed pane stops asking")
    }

    /// The routing switch's older-keeper note reads live data: the Advanced pane follows the list while it shows, and a
    /// list left from an earlier visit shows no note while the new read is out or after it fails.
    @MainActor
    func testTheAdvancedPaneFollowsTheKeeperStateForItsNote() async throws {
        let fixture = try RestartFixture(); defer { fixture.cleanUp() }
        let feed = FakeTerminalsFeed(running: 1)
        let host = try await connected(fixture, feed: feed)
        host.terminalsPollInterval = .milliseconds(10)
        func note() -> String? {
            AdvancedText.routingNote(terminalAccess: true, routing: true, keeper: host.terminalList?.keeper)
        }
        // An earlier visit to the Terminals pane left a list that said the keeper adopts.
        feed.keeperIs(KeeperState(state: "running", adopts: true))
        let earlier = Task { await host.followTerminals() }
        try await waitForCondition("the earlier list") { host.terminalList != nil }
        earlier.cancel(); await earlier.value
        XCTAssertNil(note())
        // The Mac's keeper is now an older one that holds terminals.
        feed.keeperIs(KeeperState(state: "running", adopts: false))
        feed.failWith(ClientError.unexpectedStatus(500))
        let pane = Task { await host.followRoutingKeeper() }
        try await waitForCondition("the issue") { host.terminalsIssue != nil }
        XCTAssertNil(host.terminalList, "a list from before is dropped, so no stale note shows")
        XCTAssertNil(note())
        feed.failWith(nil)
        try await waitForCondition("the note") { note() == AdvancedText.routingWaitsForTerminals }
        pane.cancel(); await pane.value
        let calls = feed.calls.filter { $0 == "list" }.count
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(feed.calls.filter { $0 == "list" }.count, calls, "leaving the pane stops asking")
    }

    @MainActor
    func testAFailingListShowsAnIssueAndTerminalsOffShowsNoError() async throws {
        let fixture = try RestartFixture(); defer { fixture.cleanUp() }
        let feed = FakeTerminalsFeed(running: 1)
        let host = try await connected(fixture, feed: feed)
        host.terminalsPollInterval = .milliseconds(10)
        feed.failWith(ClientError.unexpectedStatus(500))
        let task = Task { await host.followTerminals() }
        try await waitForCondition("the issue") { host.terminalsIssue != nil }
        XCTAssertNil(host.errorMessage, "a failing list never raises the host error")
        feed.failWith(ClientError.server(code: "terminal_disabled", message: "off"))
        try await waitForCondition("terminals off") { host.terminalsOff }
        XCTAssertNil(host.terminalsIssue)
        task.cancel()
        await task.value
    }

    func testTheEndDialogNamesWhereItStops() {
        let now = Date()
        func make(_ name: String, removed: Bool = false) -> HostTerminal {
            HostTerminal(id: "t", deviceId: "d", deviceName: name, deviceRemoved: removed, status: "running", startedAt: now)
        }
        XCTAssertEqual(TerminalsText.endMessage(make("Sam’s iPhone")), "It stops on this Mac and on Sam’s iPhone.")
        XCTAssertEqual(TerminalsText.endMessage(make("This Mac")), "It stops on this Mac.")
        XCTAssertEqual(TerminalsText.endMessage(make("Old iPhone", removed: true)), "It stops on this Mac.")
        let routed = HostTerminal(id: "t", deviceId: "local-mac", deviceName: "This Mac", deviceRemoved: false, status: "running",
                                  startedAt: now, routed: true)
        XCTAssertEqual(TerminalsText.endMessage(routed), "It stops on this Mac and in its Terminal window.")
    }

    /// `adopts` is read when the host says it and is unknown otherwise, never an error.
    func testKeeperAdoptsIsReadLeniently() throws {
        func keeper(_ json: String) throws -> KeeperState { try JSONDecoder().decode(KeeperState.self, from: Data(json.utf8)) }
        XCTAssertEqual(try keeper(#"{"state":"running","adopts":false}"#).adopts, false)
        XCTAssertEqual(try keeper(#"{"state":"running","adopts":true}"#).adopts, true)
        XCTAssertNil(try keeper(#"{"state":"running"}"#).adopts)
        XCTAssertNil(try keeper(#"{"state":"running","adopts":"no"}"#).adopts)
        XCTAssertNil(try keeper(#"{"state":"none"}"#).adopts)
    }

    @MainActor
    func testAFailedEndStaysVisibleAfterTheNextRefresh() async throws {
        let fixture = try RestartFixture(); defer { fixture.cleanUp() }
        let feed = FakeTerminalsFeed(running: 1, terminals: [terminal("a", started: Date())])
        let host = try await connected(fixture, feed: feed)
        host.terminalsPollInterval = .milliseconds(10)
        let task = Task { await host.followTerminals() }
        try await waitForCondition("a refresh") { host.terminalList != nil }
        feed.failNext("end", ClientError.server(code: "boom", message: "The host said no."))
        await host.endTerminal("a")
        XCTAssertNotNil(host.terminalActionError)
        try await Task.sleep(for: .milliseconds(50))
        task.cancel(); await task.value
        XCTAssertNotNil(host.terminalActionError, "polling never clears an action's error")
        await host.endTerminal("a")
        XCTAssertNil(host.terminalActionError, "the next successful action does")
    }

    @MainActor
    func testAnEndDeviceFailureIsReportedAfterTheRevoke() async throws {
        let fixture = try RestartFixture(); defer { fixture.cleanUp() }
        let log = TerminalCallLog()
        fixture.runner.log = log
        let feed = FakeTerminalsFeed(running: 2, log: log)
        feed.failNext("endDevice", ClientError.server(code: "terminals_unavailable", message: "The keeper is busy."))
        let host = try await connected(fixture, feed: feed)
        host.revoke(ManagedDevice(id: "d1", status: "active", createdAt: "", name: "iPhone", isPresent: false), endingTerminals: true)
        try await waitForCondition("the notice") { host.revokeNotice != nil }
        XCTAssertEqual(log.events.filter { $0 == "endDevice" || $0 == "revoke" }, ["endDevice", "revoke"])
        let notice = try XCTUnwrap(host.revokeNotice)
        XCTAssertTrue(notice.contains("The device was removed, but its terminals couldn’t be ended"), notice)
        XCTAssertTrue(notice.contains("The keeper is busy."), notice)
        XCTAssertTrue(notice.contains("Settings → Terminals"), notice)
    }

    @MainActor
    func testAFinishedTerminalWithoutAnEndTimeIsNotCounted() async throws {
        let fixture = try RestartFixture(); defer { fixture.cleanUp() }
        let feed = FakeTerminalsFeed(running: 1, terminals: [
            HostTerminal(id: "a", deviceId: "d1", deviceName: "x", status: "running", startedAt: Date()),
            HostTerminal(id: "b", deviceId: "d1", deviceName: "x", status: "ended", startedAt: Date())])
        let host = try await connected(fixture, feed: feed)
        let count = await host.runningTerminals(forDevice: "d1")
        XCTAssertEqual(count, 1)
        XCTAssertTrue(TerminalsText.isRunning(feed.terminals[0]))
        XCTAssertFalse(TerminalsText.isRunning(feed.terminals[1]))
    }

    @MainActor
    func testRunningTerminalsForADeviceAsksTheHost() async throws {
        let fixture = try RestartFixture(); defer { fixture.cleanUp() }
        let feed = FakeTerminalsFeed(running: 1, terminals: [
            terminal("a", started: Date()), terminal("b", started: Date()),
            HostTerminal(id: "c", deviceId: "d2", deviceName: "iPad", status: "running", startedAt: Date()),
            HostTerminal(id: "e", deviceId: "d1", deviceName: "x", status: "ended", startedAt: Date(), endedAt: Date())])
        let host = try await connected(fixture, feed: feed)
        let count = await host.runningTerminals(forDevice: "d1")
        XCTAssertEqual(count, 2)
    }
}

final class TerminalCallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []
    func add(_ event: String) { lock.withLock { list.append(event) } }
    var events: [String] { lock.withLock { list } }
}

final class FakeTerminalsFeed: HostTerminalsReading, @unchecked Sendable {
    private let lock = NSLock()
    private let running: Int
    private let routed: Int
    private let log: TerminalCallLog?
    private var failure: (any Error)?
    private var made: [String] = []
    private var endAllFailure: (any Error)?
    private var left = 0
    private var endAllWait: Duration = .zero
    private var ended = false
    private var keeper = KeeperState(state: "running")

    let terminals: [HostTerminal]
    private var failures: [String: any Error] = [:]

    init(running: Int, routed: Int = 0, log: TerminalCallLog? = nil, terminals: [HostTerminal] = []) {
        self.running = running; self.routed = routed; self.log = log; self.terminals = terminals
    }

    var calls: [String] { lock.withLock { made } }
    func failEndAll(_ error: any Error) { lock.withLock { endAllFailure = error } }
    func endAllLeaves(_ count: Int) { lock.withLock { left = count } }
    func delayEndAll(_ wait: Duration) { lock.withLock { endAllWait = wait } }
    /// The next call named `name` throws `error`, once.
    func failNext(_ name: String, _ error: any Error) { lock.withLock { failures[name] = error } }
    func failWith(_ error: (any Error)?) { lock.withLock { failure = error } }
    func keeperIs(_ keeper: KeeperState) { lock.withLock { self.keeper = keeper } }

    private func record(_ name: String) throws {
        log?.add(name)
        try lock.withLock {
            made.append(name)
            if let once = failures.removeValue(forKey: name) { throw once }
            if let failure { throw failure }
        }
    }

    func list() async throws -> HostTerminalList { try record("list"); return HostTerminalList(keeper: lock.withLock { keeper }, terminals: terminals) }
    func runningCount(within: TimeInterval) async throws -> HostRunningCount {
        try record("running")
        // Ending all releases the agents in Terminal to their windows: none of those is left running.
        return lock.withLock { ended ? HostRunningCount(running: left, routed: 0) : HostRunningCount(running: running, routed: routed) }
    }
    func endAll() async throws -> Int {
        try record("endAll")
        let (failure, wait) = lock.withLock { (endAllFailure, endAllWait) }
        if wait > .zero { try await Task.sleep(for: wait) }
        if let failure { throw failure }
        lock.withLock { ended = true }
        return running
    }
    func end(terminalID: String) async throws { try record("end") }
    func clear(terminalID: String) async throws { try record("clear") }
    func endDevice(_ deviceID: String) async throws -> Int { try record("endDevice"); return running }
}

/// Stands in for `agentland-host` in the routing tests: records every command and answers each with success, or
/// with the failure a test sets.
final class HookRunner: HostCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var made: [[String]] = []
    private var failure: (any Error)?
    private var failing: Set<String> = []
    private var delay: TimeInterval = 0

    var commands: [[String]] { lock.withLock { made } }
    func fail(with error: (any Error)?) { lock.withLock { failure = error } }
    /// Only commands of this hook action (`on`, `off`, `pause`) fail, with `failure`.
    func failOnly(_ action: String, with error: any Error) { lock.withLock { failure = error; failing = [action] } }
    func slow(_ seconds: TimeInterval) { lock.withLock { delay = seconds } }

    func run(_ command: HostCommand) throws -> CommandOutput {
        let wait = lock.withLock { delay }
        if wait > 0 { Thread.sleep(forTimeInterval: wait) }
        try lock.withLock {
            made.append(command.arguments)
            if let failure, failing.isEmpty || failing.contains(command.arguments.dropFirst(2).first ?? "") { throw failure }
        }
        return CommandOutput(standardOutput: "", standardError: "", exitCode: 0)
    }
}
