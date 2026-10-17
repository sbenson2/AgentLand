import XCTest
import AgentLandCore
@testable import AgentLandWorkspace

final class TerminalNamingTests: XCTestCase {
    @MainActor func testRenderedContextRefreshesAndPersistsWithoutAppleIntelligence() async throws {
        let host = ScriptedHost()
        host.on("/v1/capabilities") { _ in (200, #"{"interactions":false,"terminal":true,"terminalFeatures":["title"]}"#) }
        host.on("/v1/projects") { _ in (200, #"{"projects":[{"id":"p","name":"Project"}]}"#) }
        host.on("/v1/terminal/title") { _ in (200, #"{"accepted":true}"#) }
        let suite = "terminal-naming-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let identity = ConnectionIdentity(host: "https://studio.local:9841", deviceID: "device-a")
        let model = WorkspaceModel(defaults: defaults)
        model.attach(hostID: "host", identity: identity,
                     client: APIClient(address: try ServerAddress(validating: "https://studio.local:9841"), token: "token", transport: host))
        await model.refreshProjects()
        model.naming.namer = FakeNamer(available: false)
        model.naming.lowPowerMode = { false }
        model.naming.foregroundBegan()
        let tab = WorkspaceTab.terminal(RemoteTerminal(id: "t", title: "Codex", projectID: "p", status: .running, exitCode: nil), projectID: "p")
        model.open(tab)
        let session = model.terminalSession(for: tab)
        defer { session.end() }
        let renderer = session.renderer(for: session.rendererID)
        var offset = 0
        for (output, expected) in [("› fix the login redirect\r\nDone\r\n", "Fix the login redirect"),
                                   ("› add login regression tests\r\nUpdated\r\n", "Add login regression tests")] {
            let data = Data(output.utf8), start = offset
            offset += data.count
            let end = offset
            host.on("/v1/terminal/output") { request in
                let bytes = ScriptedHost.query(request)["cursor"] == String(start) ? data : Data()
                return (200, #"{"data":"\#(bytes.base64EncodedString())","cursor":\#(end),"end":\#(end),"reset":false,"status":"exited"}"#)
            }
            await session.poll(view: tab.id, viewActive: true)
            for packet in session.packets { renderer.feed(byteArray: [UInt8](packet.data)[...]); session.fed(packet.id) }
            await waitUntil("updated context title", timeout: 8) { model.tab(tab.id)?.title == expected }
        }
        XCTAssertEqual(host.requests("/v1/terminal/title").count, 2)
        let restored = WorkspaceModel(defaults: defaults)
        restored.attach(hostID: "host", identity: identity, client: nil)
        XCTAssertEqual(restored.tab(tab.id)?.title, "Add login regression tests")
    }

    /// The Mac names every terminal from its output alone (`HostTerminalNaming`): a headless terminal of its size draws
    /// the screen, escape sequences applied, and only its visible rows are read.
    func testOutputRendersToTheVisibleScreenAtTheTerminalsSize() {
        // A full redraw clears what was there; a device status query is answered to nobody.
        let output = Data("old line\r\n\u{1b}[6n\u{1b}[2J\u{1b}[H› fix the login redirect\r\n\u{1b}[3;1HDone".utf8)
        let lines = TerminalOutputScreen.lines(of: output, columns: 40, rows: 5)
        XCTAssertEqual(lines, ["› fix the login redirect", "", "Done", "", ""])
        XCTAssertEqual(TerminalScreen(lines: lines).latestRequest, "fix the login redirect")
        XCTAssertEqual(TerminalOutputScreen.lines(of: Data("abcdefghij".utf8), columns: 4, rows: 3), ["abcd", "efgh", "ij"])
        // Rows that scrolled away are not on the screen.
        XCTAssertEqual(TerminalOutputScreen.lines(of: Data("one\r\ntwo\r\nthree".utf8), columns: 10, rows: 2), ["two", "three"])
        // A size the host doesn't know, or one past its limits, is the fallback.
        XCTAssertEqual(TerminalOutputScreen.lines(of: Data(), columns: nil, rows: nil).count, TerminalOutputScreen.fallbackRows)
        XCTAssertEqual(TerminalOutputScreen.lines(of: Data(), columns: 900, rows: 0).count, TerminalOutputScreen.fallbackRows)
    }

    func testFallbackNamesLatestEchoedTaskAndKeepsContextOnConfirmation() {
        XCTAssertEqual(TerminalNameRules.fallback("› fix the login redirect\nDone\n› add login regression tests\nUpdated\n› yes\n"), "Add login regression tests")
        XCTAssertEqual(TerminalNameRules.fallback("mini:~/app% go test ./...\nPASS"), "Run Go tests")
        XCTAssertNil(TerminalNameRules.fallback("Welcome to Codex\n› \n? for shortcuts"))
        XCTAssertNil(TerminalNameRules.fallback("› yes keep going\nDone"))
        XCTAssertNil(TerminalNameRules.fallback("❯ update api_key=secret in config"))
        XCTAssertNil(TerminalNameRules.fallback("Arbitrary output should never become the title"))
    }

    /// Any request of three or more words typed to a coding agent names the terminal, not only those opening with
    /// one of a few verbs, cut to six words; inside a box border too. Shell arguments still never do.
    func testFallbackTakesAnyTypedRequestInsideBoxesToo() {
        XCTAssertEqual(TerminalNameRules.fallback("│ > the tab bar sits too low on iPhone │\n⏺ Lifting it\n│ > │"),
                       "The tab bar sits too low")
        XCTAssertEqual(TerminalNameRules.fallback("› please make the quip wrap at two lines\n• Done\n› "), "Make the quip wrap at two")
        XCTAssertEqual(TerminalNameRules.fallback("s@mini AgentLand % swift test --filter Names\nok"), "Run Swift tests")
        XCTAssertNil(TerminalNameRules.fallback("s@mini AgentLand % rm -rf build products now\nremoved"))
        XCTAssertNil(TerminalNameRules.fallback("› ok do it again\n• Done\n› "))
        XCTAssertNil(TerminalNameRules.fallback("› /review my current changes\n• Reviewing\n› "))
        XCTAssertNil(TerminalNameRules.fallback("› export GITHUB_TOKEN=abc123 now please\nok\n› "))
    }

    // MARK: The screen

    /// Claude Code's screen: its welcome box, spinners, timers, token counters, the empty input box and its hints are
    /// chrome; the request inside the transcript and the work under it are what it shows.
    func testScreenStripsClaudeCodesChrome() {
        let screen = TerminalScreen(lines: [
            "╭───────────────────────────────────────╮",
            "│ ✻ Welcome to Claude Code!             │",
            "│   cwd: /Users/me/Developer            │",
            "╰───────────────────────────────────────╯",
            "",
            "> fix the tab bar gap",
            "",
            "⏺ I'll lift the tab bar by 10 pt. (12s · ↑ 1.2k tokens)",
            "  ⎿  Updated PhoneTabsHome.swift with 2 additions (ctrl+r to expand)",
            "",
            "✻ Thinking… (esc to interrupt)",
            "⠋ Working",
            "↑ 1.2k tokens · 12s",
            "─────────────────────────────────────────",
            "❯ ",
            "─────────────────────────────────────────",
            "  ⏵⏵ accept edits on (shift+tab to cycle)",
            "  ? for shortcuts",
        ])
        XCTAssertEqual(screen.requests, [TerminalScreen.Request(text: "fix the tab bar gap", shell: false)])
        XCTAssertEqual(screen.output, ["⏺ I'll lift the tab bar by 10 pt.", "⎿ Updated PhoneTabsHome.swift with 2 additions"])
        XCTAssertFalse(screen.isIdle)
    }

    /// Codex's: its header and session details, the working line, the input box's placeholder and its key hints.
    func testScreenStripsCodexsChromeAndPlaceholder() {
        let screen = TerminalScreen(lines: [
            ">_ OpenAI Codex (v0.46.0)",
            "model: gpt-5-codex high   /model to change",
            "directory: ~/Developer/AgentLand",
            "/init - create an AGENTS.md file with instructions for Codex",
            "› make the quip wrap",
            "• Working (5s • esc to interrupt)",
            "› Explain this codebase",
            "  ⏎ send   ⇧⏎ newline   ⌃T transcript   ⌃C quit",
        ])
        XCTAssertEqual(screen.requests.map(\.text), ["make the quip wrap"])
        XCTAssertEqual(screen.output, [])
        // A fresh screen with nothing typed is idle: no name, nothing sent.
        let fresh = TerminalScreen(lines: [">_ OpenAI Codex (v0.46.0)", "directory: ~/Developer", "› Summarize recent commits",
                                           "  100% context left · ? for shortcuts"])
        XCTAssertEqual(fresh.requests, [])
        XCTAssertTrue(fresh.isIdle)
        XCTAssertTrue(TerminalScreen(lines: ["✳ Claude Code", "", "> "]).isIdle)
    }

    /// The input box the person is typing in is no request until it is sent: the last prompt with no output under it.
    func testTheInputBeingTypedIsNoRequest() {
        XCTAssertEqual(TerminalScreen(text: "› fix the login redirect\nDone\n› add login reg").requests.map(\.text),
                       ["fix the login redirect"])
        XCTAssertEqual(TerminalScreen(text: "mini:~/app% go test ./...\nPASS\nmini:~/app% ").requests,
                       [TerminalScreen.Request(text: "go test ./...", shell: true)])
        XCTAssertEqual(TerminalScreen(text: "(venv) s@mini app % make lint\nok\nroot@box:~# ls\nREADME").requests.map(\.shell), [true, true])
    }

    /// A spinner's tick, a timer or a hint redrawn is no change; new output is, and so is a new request.
    func testScreensDifferingOnlyInChromeAreEqual() {
        let ticking = ["> fix the tab bar", "⏺ Lifting the bar (3s)", "✻ Thinking… (3s · esc to interrupt)", "> "]
        let ticked = ["> fix the tab bar", "⏺ Lifting the bar (4s)", "✶ Pondering… (4s · esc to interrupt)", "> "]
        XCTAssertEqual(TerminalScreen(lines: ticking), TerminalScreen(lines: ticked))
        XCTAssertNotEqual(TerminalScreen(lines: ticking), TerminalScreen(lines: ticking.dropLast() + ["⏺ Done lifting it", "> "]))
    }

    /// Lines that look like secrets never reach the model; the model reads the requests, the output and the current
    /// name, bounded so the name is never cut off.
    func testTheModelReadsRequestsOutputAndTheCurrentName() {
        var lines = ["> fix the tab bar", "export API_KEY=abc", "Your password is hunter2"]
        lines += (1...200).map { "⏺ Step \($0) of lifting the tab bar by ten points on every iPhone" }
        let text = TerminalScreen(lines: lines + ["> "]).namingText(current: "Fix the tab bar")
        XCTAssertTrue(text.hasPrefix("Requests the person typed, oldest first:\n- fix the tab bar\n"))
        XCTAssertTrue(text.hasSuffix("\n\nCurrent name: Fix the tab bar"))
        XCTAssertTrue(text.contains("Step 200 of lifting"))
        XCTAssertFalse(text.contains("Step 150 of lifting"))
        XCTAssertFalse(text.contains("API_KEY") || text.contains("hunter2"))
        XCTAssertLessThan(text.count, 4_000)
    }

    // MARK: Checking the model's name

    /// The model's name must share a word with the screen: "JSON format task" on a screen without "json" or "format" is
    /// rejected (the rules' own name stands in), a name of its own words is taken, inflections included.
    func testTheModelsNameMustBeGroundedInTheScreen() async {
        let lines = ["› review the onboarding copy", "• Reading Onboarding.swift", "• The welcome text repeats itself", "› "]
        let screen = TerminalScreen(lines: lines)
        XCTAssertFalse(TerminalNameRules.grounded("JSON format task", in: screen))
        XCTAssertTrue(TerminalNameRules.grounded("Reviewing onboarding text", in: screen))
        XCTAssertFalse(TerminalNameRules.grounded("Terminal task", in: screen))
        let invented = FakeNamer(["JSON format task"])
        let rejected = await TerminalContextNamer(namer: invented).name(lines: lines, current: nil)
        XCTAssertEqual(rejected, "Review the onboarding copy")
        XCTAssertEqual(invented.inputs.map(\.context), [.terminal])
        XCTAssertTrue(invented.inputs.first?.prompt.contains("- review the onboarding copy") == true)
        let grounded = await TerminalContextNamer(namer: FakeNamer(["Fix repeated welcome text"])).name(lines: lines, current: nil)
        XCTAssertEqual(grounded, "Fix repeated welcome text")
        // Nothing the screen supports and no request the rules can use: nothing is sent.
        let output = ["• Reading Onboarding.swift", "• The welcome text repeats itself in three places", "• Checked every screen of it",
                      "• Nothing else changed in the copy"]
        let nothing = await TerminalContextNamer(namer: FakeNamer(["JSON format task"])).name(lines: output, current: nil)
        XCTAssertNil(nothing)
    }

    /// The model's answer, or the rules', equal to the current name but for case or punctuation sends nothing; an idle
    /// screen never asks the model.
    func testTheCurrentNameAgainSendsNothing() async {
        let lines = ["› review the onboarding copy", "• Reading Onboarding.swift", "› "]
        let kept = await TerminalContextNamer(namer: FakeNamer(["review the Onboarding copy."])).name(lines: lines, current: "Review the onboarding copy")
        XCTAssertNil(kept)
        let unavailable = await TerminalContextNamer(namer: FakeNamer(available: false)).name(lines: lines, current: "Review the onboarding-copy")
        XCTAssertNil(unavailable)
        let idle = FakeNamer(["Claude Code welcome"])
        let fresh = await TerminalContextNamer(namer: idle).name(lines: ["✳ Claude Code", "", "> "], current: nil)
        XCTAssertNil(fresh)
        XCTAssertEqual(idle.inputs.count, 0)
        XCTAssertTrue(TerminalNameRules.sameName("Fix the tab-bar!", "fix the tab bar"))
        XCTAssertFalse(TerminalNameRules.sameName("Fix the tab bar", nil))
    }

    // MARK: When to ask

    /// A new request asks at once; changed output alone at most every 30 s; a redraw of chrome or an idle screen never.
    func testTheScheduleAsksOnNewRequestsAndEveryThirtySecondsForOutput() {
        var schedule = TerminalNamingSchedule()
        let start = Date(timeIntervalSince1970: 1_000)
        let first = TerminalScreen(lines: ["› fix the tab bar", "• Lifting it", "› "])
        XCTAssertEqual(schedule.due(TerminalScreen(lines: ["✳ Claude Code", "> "]), now: start), .no)
        XCTAssertEqual(schedule.due(first, now: start), .now)
        schedule.asked(first, at: start)
        XCTAssertEqual(schedule.due(TerminalScreen(lines: ["› fix the tab bar", "• Lifting it (4s)", "✻ Working… (esc to interrupt)", "› "]),
                                    now: start + 6), .no)
        let more = TerminalScreen(lines: ["› fix the tab bar", "• Lifting it", "• Updated PhoneTabsHome.swift", "› "])
        XCTAssertEqual(schedule.due(more, now: start + 10), .after(20))
        XCTAssertEqual(schedule.due(more, now: start + 31), .now)
        let next = TerminalScreen(lines: ["› fix the tab bar", "• Lifting it", "› now the quip", "• Wrapping it", "› "])
        XCTAssertEqual(schedule.due(next, now: start + 12), .now)
    }

    func testSavedContextWinsOverIdleProgramAndOldHostsStillDecode() throws {
        let decoder = JSONDecoder()
        let old = try decoder.decode(RemoteTerminal.self, from: Data(#"{"id":"t","projectId":"p","title":"Codex","status":"running"}"#.utf8))
        XCTAssertEqual(old.displayTitle, "Codex")
        XCTAssertNil(old.contextTitleSource)
        // Where the name came from; a source this version does not know counts as none.
        func source(_ value: String) throws -> TerminalNameSource? {
            let json = #"{"id":"t","projectId":"p","title":"Codex","status":"running","contextTitle":"Fix it","contextTitleSource":"\#(value)"}"#
            return try decoder.decode(RemoteTerminal.self, from: Data(json.utf8)).contextTitleSource
        }
        XCTAssertEqual(try source("device"), .device)
        XCTAssertEqual(try source("program"), .program)
        XCTAssertNil(try source("robot"))
        let shared = try decoder.decode(SharedTerminal.self, from: Data(#"{"id":"t","status":"running","contextTitle":"Fix it","contextTitleSource":"device"}"#.utf8))
        XCTAssertEqual(shared.remoteTerminal.contextTitleSource, .device)
        let current = RemoteTerminal(id: "t", title: "Codex", projectID: "p", status: .running, exitCode: nil,
                                     programTitle: "Codex", contextTitle: "Repair login redirect", command: "zsh")
        XCTAssertEqual(current.displayTitle, "Repair login redirect")
        XCTAssertEqual(WorkspaceTab.terminal(current, projectID: "p").title, "Repair login redirect")
        XCTAssertEqual(WorkspaceTab.terminal(current, projectID: "p").label, "Codex")
    }
}
