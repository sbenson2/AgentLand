import XCTest
import UIKit
import Vision

/// A tester's sessions on the iPhone app, against the harness's disposable host (integration/check-ios-product.py):
///
/// - `testExploratoryScript` runs a JSON script of steps a person would take (integration/scripts/*.json,
///   `--script`): taps, typing, swipes, waits and assertions, screenshots, lock and unlock, the background,
///   relaunches, rotation, Text Size, appearance, and the host stopped, started, paused or checked on disk.
/// - `testRandomWalk` (`--seed N`) takes about sixty seeded steps among the actions on screen and checks the
///   app's invariants after each; a seed replays the same walk.
/// - `testInterruptionMatrix` (`--matrix surface:interruption,…`) brings one surface to the front, applies each
///   interruption and checks that the right surface is still in front, intact and taking input (or refusing it
///   visibly while offline), with no stuck cover or orphan presentation.
///
/// Every drawer, task-switcher and Settings interaction goes through `TesterSession`'s helpers (MARK: Navigation
/// helpers), so the iPhone drawer and Settings redesign changes them in one place.
///
/// A script is `{"name", "about", "appearance", "timeout", "prepare": [...], "preview": bool, "launch": {...},
/// "steps": [...]}`. Each step is an object with `do` and its arguments; `soft: true` records a failure and goes
/// on, `invariants: true` checks the invariants after it, `note` is logged. `${name}` in any string is a
/// variable: the fixture's (address, code, fingerprint, chatReply, streamReply, terminalMarker, commitMessage,
/// project, workspaceHome, previewPort, previewMarker, gitRemote, rand) or one a step captured.
/// Elements: `id`, `idPrefix`, `label`, `labelContains`, `valueContains`, `type` (any, button, text, field,
/// textView, secure, switch, search, image, cell, other), `within`, `index`, `last`, `springboard`; `scroll`
/// (up, down) scrolls until it can be touched, up to `scrolls` drags (6); `timeout` in seconds.
/// Steps: launch (appearance, animations, lock, largestText, args, pair), relaunch, terminate, pair, tap,
/// tapIfExists, tapAt (at: [x, y]), doubleTap, longPress (duration), swipe (direction), type (text, noTap),
/// typeKey (key, modifiers), clear, back, wait (hittable), waitGone, assertExists, assertAbsent, assertHittable,
/// assertNotHittable, assertEnabled, assertDisabled, assertSelected, assertNotSelected (a checkmarked choice),
/// assertValue / assertLabel (equals, contains, lacks),
/// assertCount (equals, atLeast), keyboard (shown), screenshot (name), sleep (seconds), background, foreground,
/// unlock, faceID, rotate (to), textSize (size), systemAppearance (value), host (command: stop, start, pause,
/// resume), hostCheck (command: hostfile, hostwrite, hostgit, hostprojects, hostpid, simui, addmedia, hostalive,
/// paircode; payload; as), alert (button, optional), terminalType (text), terminalSees / terminalLacks (text),
/// screenSees / screenLacks (text), capture (attribute, as, strip), invariants, repeat (times, steps), helper
/// (name, argument: openDrawer, closeDrawer, drawerPane, openSettings, closeSettings, settingsPage, goHome,
/// taskSwitcher, dismissTaskSwitcher, chooseTask, chooseTaskID, captureCurrentTask, surfaceMenu, surfaceAction,
/// closeTask, homeChoice, newTerminal, newPlainChat, newAgentChat, openWorkspace, openFile, setAppearance,
/// chooseFixtureModel, hideChatKeyboard).
extension FullWorkspaceUITests {
    /// What the harness adds to the fixture for these tests.
    struct TesterFixture: Decodable {
        let script: String?
        let scriptName: String?
        let seed: UInt64?
        let walkSteps: Int?
        let matrixSurface: String?
        let matrixInterruptions: [String]?
        let project: String?
        let workspaceHome: String?
        let previewPort: Int?
        let previewMarker: String?
        let gitRemote: String?
    }

    func testerSession() throws -> TesterSession {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "The tester's sessions drive the iPhone interface")
        // Their steps still drive the left drawer the bottom tabs replaced (owner, 2026-10-11): its sections, workspace
        // rows and groups, and the tab menu's items. Until they move to the tabs they skip rather than pass doing nothing.
        try XCTSkipUnless(Self.sessionsFollowBottomTabs,
                          "The exploratory sessions still drive the iPhone's removed drawer; they skip until ported to the bottom tabs")
        let fixture = try fixture(for: (try? Self.fixturePhase()) ?? "light")
        let extra = try JSONDecoder().decode(TesterFixture.self, from: Data(contentsOf: Self.fixtureURL()))
        // The simulator keeps its orientation between tests: a walk or matrix that failed in landscape must
        // not hand the next session a sideways pairing screen. Every session starts upright and ends upright.
        XCUIDevice.shared.orientation = .portrait
        addTeardownBlock { XCUIDevice.shared.orientation = .portrait }
        return TesterSession(test: self, fixture: fixture, extra: extra)
    }

    /// Whether the exploratory sessions' steps drive the iPhone's bottom tabs (`testerSession`).
    static let sessionsFollowBottomTabs = false

    static func fixturePhase() throws -> String {
        struct Phase: Decodable { let phase: String? }
        return try JSONDecoder().decode(Phase.self, from: Data(contentsOf: fixtureURL())).phase ?? "light"
    }

    func testExploratoryScript() throws {
        continueAfterFailure = true
        let session = try testerSession()
        let path = try XCTUnwrap(session.extra.script, "Run with integration/check-ios-product.py --script <file>")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path)))
        let script = try XCTUnwrap(object as? [String: Any], "A script is a JSON object")
        let steps = try XCTUnwrap(script["steps"] as? [[String: Any]], "A script has its steps")
        session.note("script \(session.extra.scriptName ?? path): \(steps.count) steps")
        if let launch = script["launch"] as? [String: Any] { try session.launch(launch) }
        defer { session.finish() }
        do {
            try session.run(steps, path: "")
        } catch let failure as TesterSession.StepFailure {
            session.record(failure)
        }
    }

    func testRandomWalk() throws {
        continueAfterFailure = true
        let session = try testerSession()
        let seed = session.extra.seed ?? 1
        let walk = RandomWalk(session: session, seed: seed, steps: session.extra.walkSteps ?? 60)
        defer { session.finish() }
        do {
            try walk.run()
        } catch let failure as TesterSession.StepFailure {
            session.record(failure)
        }
    }

    func testInterruptionMatrix() throws {
        continueAfterFailure = true
        let session = try testerSession()
        let surface = try XCTUnwrap(session.extra.matrixSurface, "Run with --matrix surface:interruption,…")
        var interruptions = session.extra.matrixInterruptions ?? ["all"]
        if interruptions == ["all"] { interruptions = InterruptionMatrix.interruptions }
        let matrix = InterruptionMatrix(session: session, surface: surface)
        defer { session.finish() }
        do {
            try matrix.run(interruptions)
        } catch let failure as TesterSession.StepFailure {
            session.record(failure)
        }
    }
}

/// One tester's session: the app, the fixture, the script's variables and what the host is doing.
final class TesterSession {
    struct StepFailure: Error, CustomStringConvertible {
        let step: String
        let message: String
        var description: String { "\(step): \(message)" }
    }

    unowned let test: FullWorkspaceUITests
    let app = XCUIApplication()
    let fixture: FullWorkspaceUITests.Fixture
    let extra: FullWorkspaceUITests.TesterFixture
    var variables: [String: String] = [:]
    private(set) var launchArguments: [String] = []
    private(set) var lockEnabled = false
    /// When the app last came up (XCUITest's `launch()` returned with it in front), for steps that time something
    /// from the launch (`sinceLaunch`), such as the opening cover.
    private(set) var launchedAt = Date()
    private(set) var transcript: [String] = []
    /// What the host process is doing, as this session asked for it.
    var hostRunning = true
    var hostPaused = false
    /// Failures recorded without stopping (`soft` steps, walk and matrix findings).
    private(set) var findings: [String] = []
    private var currentStep = "setup"
    /// The text the last unsuccessful OCR read.
    private var lastOCR = ""
    private var shots = 0

    init(test: FullWorkspaceUITests, fixture: FullWorkspaceUITests.Fixture, extra: FullWorkspaceUITests.TesterFixture) {
        self.test = test
        self.fixture = fixture
        self.extra = extra
        let values: [String: String?] = [
            "address": fixture.address, "code": fixture.code, "fingerprint": fixture.fingerprint,
            "marker": fixture.marker, "terminalMarker": fixture.terminalMarker, "chatReply": fixture.chatReply,
            "streamReply": fixture.streamReply, "commitMessage": fixture.commitMessage,
            "workspaceName": fixture.workspaceName, "approvalReply": fixture.approvalReply,
            "searchToken": fixture.searchToken, "modelID": fixture.modelID, "project": extra.project,
            "workspaceHome": extra.workspaceHome, "previewPort": extra.previewPort.map(String.init),
            "previewMarker": extra.previewMarker, "gitRemote": extra.gitRemote,
            "rand": String(UInt32.random(in: 0x1000_0000...0xffff_ffff), radix: 16)
        ]
        for (key, value) in values { if let value { variables[key] = value } }
    }

    // MARK: Logging and failures

    func note(_ line: String) {
        let stamped = String(format: "%7.1f ", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 10_000)) + line
        transcript.append(stamped)
        print("TESTER " + stamped)
    }

    func failure(_ message: String) -> StepFailure { StepFailure(step: currentStep, message: message) }

    /// Names what follows in the transcript and in failures.
    func begin(_ step: String) {
        currentStep = step
        note("step " + step)
    }

    func screenshot(_ name: String) {
        shots += 1
        test.attach(app, String(format: "%03d-%@", shots, name))
    }

    /// Records a failure with a screenshot and the element tree, so the evidence says what was on screen.
    func record(_ failure: StepFailure) {
        note("FAIL " + failure.description)
        screenshot("failure")
        test.attachText(app.debugDescription, String(format: "%03d-failure-hierarchy", shots))
        XCTFail(failure.description)
    }

    func finding(_ message: String) {
        findings.append("\(currentStep): \(message)")
        note("FINDING \(currentStep): \(message)")
        screenshot("finding")
        test.attachText(app.debugDescription, String(format: "%03d-finding-hierarchy", shots))
        XCTFail("\(currentStep): \(message)")
    }

    func finish() {
        test.attachText(transcript.joined(separator: "\n"), "tester-transcript")
        if !findings.isEmpty { test.attachText(findings.joined(separator: "\n"), "tester-findings") }
    }

    // MARK: Launching

    /// Launches the app (terminating it first). `appearance` (light, dark, system), `animations` (false keeps
    /// the UI tests' instant motion), `lock`, `largestText`, `quip` and extra `args`.
    func launch(_ options: [String: Any]) throws {
        var arguments: [String] = []
        if (options["animations"] as? Bool) != true { arguments.append("-AgentLandUITestsDisableAnimations") }
        lockEnabled = (options["lock"] as? Bool) == true
        arguments += ["-agentland.lock.enabled", lockEnabled ? "YES" : "NO"]
        let appearance = (options["appearance"] as? String) ?? "light"
        if appearance != "default" { arguments += ["-agentland.appearance", appearance] }
        arguments += ["-AgentLandFixedQuip", (options["quip"] as? String) ?? test.fixedQuip]
        if (options["largestText"] as? Bool) == true {
            arguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        arguments += ((options["args"] as? [String]) ?? []).map(substitute)
        launchArguments = arguments
        app.terminate()
        app.launchArguments = arguments
        app.launch()
        launchedAt = Date()
        note("launched \(arguments.joined(separator: " "))")
        if lockEnabled { try unlock(timeout: 20, required: false) }
        if (options["pair"] as? Bool) == true { try pair() }
    }

    func relaunch() throws {
        app.terminate()
        app.launchArguments = launchArguments
        app.launch()
        launchedAt = Date()
        if lockEnabled { try unlock(timeout: 10, required: false) }
    }

    /// Pairs with the fixture's host when the pairing screen shows, and opens the fixture workspace when asked.
    func pair() throws {
        // A first install asks for the local network as the pairing screen's nearby search starts.
        try alert(["button": "Allow", "optional": true, "timeout": 3])
        try test.pairIfNeeded(app, fixture: fixture, forceFreshHost: false)
        guard test.workspaceHeader(app).waitForExistence(timeout: 30) else { throw failure("pairing did not reach the workspace") }
    }

    /// Brings the app back from the background as a person does, and fails when it does not come: `activate()`
    /// can return with the app still in the background (seen after a few seconds there), so it is asked again
    /// and then the Home Screen icon is tapped.
    func foreground(unlocking: Bool = true) throws {
        app.activate()
        if !wait(6, until: { self.app.state == .runningForeground }) {
            note("activate left the app in state \(app.state.rawValue); activating again")
            app.activate()
        }
        if !wait(6, until: { self.app.state == .runningForeground }) {
            let icon = XCUIApplication(bundleIdentifier: "com.apple.springboard").icons["AgentLand"]
            if icon.exists { icon.tap() }
        }
        guard wait(8, until: { self.app.state == .runningForeground }) else {
            throw failure("the app did not come back to the front (state \(app.state.rawValue))")
        }
        if lockEnabled && unlocking { try unlock(timeout: 8, required: false) }
    }

    /// Waits for the app lock and answers it with a matching face.
    func unlock(timeout: TimeInterval, required: Bool) throws {
        let lock = app.otherElements["appLockScreen"]
        guard lock.waitForExistence(timeout: timeout) else {
            if required { throw failure("the app lock did not cover the app") }
            return
        }
        // The face counts only once the system's Face ID prompt is up; a match sent before it is lost.
        let prompt = XCUIApplication(bundleIdentifier: "com.apple.springboard").staticTexts["Face ID"]
        for _ in 0..<3 {
            _ = prompt.waitForExistence(timeout: 4)
            test.simulateMatchingFace()
            if lock.waitForNonExistence(timeout: 6) { return }
        }
        throw failure("a matching face did not take the app lock away")
    }

    // MARK: Variables

    func substitute(_ text: String) -> String {
        guard text.contains("${") else { return text }
        var result = text
        for (key, value) in variables { result = result.replacingOccurrences(of: "${\(key)}", with: value) }
        return result
    }

    private func string(_ step: [String: Any], _ key: String) -> String? {
        (step[key] as? String).map(substitute)
    }

    private func number(_ step: [String: Any], _ key: String) -> Double? {
        if let value = step[key] as? Double { return value }
        if let value = step[key] as? Int { return Double(value) }
        return nil
    }

    // MARK: Elements

    private static let types: [String: XCUIElement.ElementType] = [
        "any": .any, "button": .button, "text": .staticText, "field": .textField, "textView": .textView,
        "secure": .secureTextField, "cell": .cell, "switch": .switch, "search": .searchField, "other": .other,
        "segment": .button, "link": .link, "image": .image, "menuItem": .menuItem, "webView": .webView
    ]

    /// The element a step names: `id`, `label`, `labelContains`, `idPrefix`, `valueContains`, optionally of a
    /// `type`, `within` another element's identifier, at an `index` (or the `last`).
    func element(_ step: [String: Any]) -> XCUIElement {
        let type = Self.types[(step["type"] as? String) ?? "any"] ?? .any
        var root: XCUIElement = app
        if let within = string(step, "within") {
            root = app.descendants(matching: .any).matching(identifier: within).firstMatch
        }
        if string(step, "springboard") != nil || (step["springboard"] as? Bool) == true {
            root = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        }
        var query = root.descendants(matching: type)
        var predicates: [NSPredicate] = []
        if let id = string(step, "id") { predicates.append(NSPredicate(format: "identifier == %@", id)) }
        if let prefix = string(step, "idPrefix") { predicates.append(NSPredicate(format: "identifier BEGINSWITH %@", prefix)) }
        if let label = string(step, "label") { predicates.append(NSPredicate(format: "label == %@", label)) }
        if let label = string(step, "labelContains") { predicates.append(NSPredicate(format: "label CONTAINS %@", label)) }
        if let value = string(step, "valueContains") { predicates.append(NSPredicate(format: "value CONTAINS %@", value)) }
        if !predicates.isEmpty { query = query.matching(NSCompoundPredicate(andPredicateWithSubpredicates: predicates)) }
        if (step["last"] as? Bool) == true { return query.element(boundBy: max(0, query.count - 1)) }
        if let index = step["index"] as? Int { return query.element(boundBy: index) }
        return query.firstMatch
    }

    func describe(_ step: [String: Any]) -> String {
        ["id", "idPrefix", "label", "labelContains", "valueContains", "within"].compactMap { key in
            string(step, key).map { "\(key)=\($0)" }
        }.joined(separator: " ")
    }

    func wait(_ timeout: TimeInterval, interval: TimeInterval = 0.25, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            Thread.sleep(forTimeInterval: interval)
        } while Date() < deadline
        return condition()
    }

    /// Waits for the step's element to exist (and to be hittable, for a tap), scrolling `scroll` (up or down)
    /// up to six times first when asked.
    enum ScrollDirection { case up, down }

    /// Drags the content above the keyboard: up shows what is further down.
    func drag(_ direction: ScrollDirection) {
        // Below the header and the drawer's pane picker, so the drag lands on the list and not on a control.
        let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        let bottom = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
        if direction == .up {
            bottom.press(forDuration: 0.05, thenDragTo: top)
        } else {
            top.press(forDuration: 0.05, thenDragTo: bottom)
        }
    }

    /// Whether a touch reaches `element`: it is there, hittable and not under a navigation bar. XCUITest's hit test
    /// is the accessibility tree's, which sees through a bar's empty middle to a row scrolled beneath it, while a
    /// touch there lands on the bar (2026-10-06: Remotes' header, scrolled under the drawer's Git bar, took no tap).
    /// An element in a bar, or one holding a bar, is not under it; neither is a bar behind a sheet.
    func inReach(_ element: XCUIElement) -> Bool {
        guard element.exists, element.isHittable else { return false }
        let frame = element.frame
        return !app.navigationBars.allElementsBoundByIndex.contains { bar in
            let edge = bar.frame
            guard !edge.isEmpty, !edge.insetBy(dx: -8, dy: -8).contains(frame), !frame.contains(edge),
                  frame.minX < edge.maxX, edge.minX < frame.maxX else { return false }
            return frame.maxY > edge.minY && frame.midY < edge.maxY && bar.isHittable
        }
    }

    func find(_ step: [String: Any], hittable: Bool, timeout: TimeInterval? = nil) throws -> XCUIElement {
        let target = element(step)
        let limit = timeout ?? number(step, "timeout") ?? 10
        if let direction = string(step, "scroll") {
            // `scrolls` for a long list: the host's web servers run to dozens of rows on a busy Mac.
            for _ in 0..<((step["scrolls"] as? Int) ?? 6) where !inReach(target) { drag(direction == "down" ? .down : .up) }
        }
        var found = wait(hittable ? min(limit, 3) : limit) { target.exists && (!hittable || inReach(target)) }
        if !found && hittable && target.exists {
            // There but out of reach, under the keyboard, a bar or below the fold: scroll to it, as a person would.
            for direction in [ScrollDirection.up, .up, .up, .up, .down, .down, .down, .down, .down, .down, .down, .down]
            where !inReach(target) {
                drag(direction)
            }
        }
        found = found || wait(max(0, limit - 3)) { target.exists && (!hittable || inReach(target)) }
        guard found else {
            throw failure("\(describe(step)) \(target.exists ? "is not hittable" : "never appeared") within \(Int(limit)) s")
        }
        return target
    }

    // MARK: Running steps

    func run(_ steps: [[String: Any]], path: String) throws {
        for (index, step) in steps.enumerated() {
            let name = (step["do"] as? String) ?? "?"
            currentStep = "\(path)\(index + 1) \(name) \(describe(step))".trimmingCharacters(in: .whitespaces)
            if let text = string(step, "note") { note("# " + text) }
            note("step " + currentStep)
            do {
                try perform(name, step)
            } catch let failure as StepFailure {
                if (step["soft"] as? Bool) == true {
                    finding(failure.message)
                } else {
                    throw failure
                }
            }
            if (step["invariants"] as? Bool) == true { try checkInvariants() }
        }
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func perform(_ action: String, _ step: [String: Any]) throws {
        switch action {
        case "note":
            break
        case "launch":
            try launch(step)
        case "relaunch":
            try relaunch()
        case "terminate":
            app.terminate()
        case "pair":
            try pair()
        case "tap":
            let target = try find(step, hittable: true)
            if let offset = step["at"] as? [Double], offset.count == 2 {
                target.coordinate(withNormalizedOffset: CGVector(dx: offset[0], dy: offset[1])).tap()
            } else {
                target.tap()
            }
        case "tapIfExists":
            let target = element(step)
            if wait(number(step, "timeout") ?? 2, until: { target.exists && target.isHittable }) { target.tap() }
        case "tapAt":
            let point = (step["at"] as? [Double]) ?? [0.5, 0.5]
            app.coordinate(withNormalizedOffset: CGVector(dx: point[0], dy: point[1])).tap()
        case "doubleTap":
            try find(step, hittable: true).doubleTap()
        case "longPress":
            try find(step, hittable: true).press(forDuration: number(step, "duration") ?? 1.2)
        case "swipe":
            let direction = string(step, "direction") ?? "up"
            let target: XCUIElement = describe(step).isEmpty ? app : try find(step, hittable: true)
            switch direction {
            case "left": target.swipeLeft()
            case "right": target.swipeRight()
            case "down": target.swipeDown()
            default: target.swipeUp()
            }
        case "type":
            let text = string(step, "text") ?? ""
            if describe(step).isEmpty {
                // Typed with whatever keyboard is up. With none, a person's keys go nowhere; XCUITest's
                // typeText would fail the whole test instead.
                let focused = app.descendants(matching: .any).matching(NSPredicate(format: "hasKeyboardFocus == true")).firstMatch
                if app.keyboards.firstMatch.waitForExistence(timeout: 1), focused.exists {
                    app.typeText(text)
                } else {
                    // A keyboard (or a lone key bar) with nothing focused takes no typing either (B-8).
                    note(app.keyboards.firstMatch.exists ? "a keyboard is up but nothing has its focus: nothing typed"
                                                         : "no keyboard is up: nothing typed")
                }
            } else {
                let target = try find(step, hittable: true)
                if (step["noTap"] as? Bool) != true { target.tap() }
                // Typed at the keyboard, as a person does: a field can drop its identifier while it edits
                // (a sheet's name field did), and the element's own typeText then finds nothing.
                if app.keyboards.firstMatch.waitForExistence(timeout: 3) {
                    app.typeText(text)
                } else {
                    target.typeText(text)
                }
            }
        case "typeKey":
            let key = string(step, "key") ?? ""
            let named: [String: String] = ["escape": XCUIKeyboardKey.escape.rawValue, "return": XCUIKeyboardKey.return.rawValue,
                                           "delete": XCUIKeyboardKey.delete.rawValue, "tab": XCUIKeyboardKey.tab.rawValue,
                                           "up": XCUIKeyboardKey.upArrow.rawValue, "down": XCUIKeyboardKey.downArrow.rawValue]
            var flags: XCUIElement.KeyModifierFlags = []
            for modifier in (step["modifiers"] as? [String]) ?? [] {
                switch modifier {
                case "command": flags.insert(.command)
                case "control": flags.insert(.control)
                case "shift": flags.insert(.shift)
                case "option": flags.insert(.option)
                default: break
                }
            }
            app.typeKey(named[key] ?? key, modifierFlags: flags)
        case "clear":
            let target = try find(step, hittable: true)
            // A touch at the trailing end puts the caret after the text, so deleting removes all of it.
            target.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.5)).tap()
            let length = (target.value as? String)?.count ?? 0
            let deletes = String(repeating: XCUIKeyboardKey.delete.rawValue, count: length + 2)
            if length > 0 {
                if app.keyboards.firstMatch.waitForExistence(timeout: 3) { app.typeText(deletes) } else { target.typeText(deletes) }
            }
        case "back":
            let back = app.navigationBars.buttons["BackButton"].firstMatch
            guard back.waitForExistence(timeout: number(step, "timeout") ?? 5) else { throw failure("no Back button") }
            back.tap()
        case "wait":
            _ = try find(step, hittable: (step["hittable"] as? Bool) == true, timeout: number(step, "timeout") ?? 15)
        case "waitGone":
            let target = element(step)
            let limit = number(step, "timeout") ?? 15
            // `sinceLaunch`: the timeout counts from the last launch, not from this step (an opening's budget).
            let sinceLaunch = (step["sinceLaunch"] as? Bool) == true
            let budget = sinceLaunch ? max(0.5, limit - Date().timeIntervalSince(launchedAt)) : limit
            guard target.waitForNonExistence(timeout: budget) else {
                guard sinceLaunch else { throw failure("\(describe(step)) is still there after \(Int(limit)) s") }
                // How late it was, for the failure: up to 30 s more.
                let late = target.waitForNonExistence(timeout: 30)
                throw failure(String(format: "%@ is still there %d s after launch (%@ %.1f s)", describe(step), Int(limit),
                                     late ? "gone after" : "still there after", Date().timeIntervalSince(launchedAt)))
            }
            if sinceLaunch { note(String(format: "%@ gone %.1f s after launch", describe(step), Date().timeIntervalSince(launchedAt))) }
        case "assertExists":
            let target = element(step)
            // `scroll` (up or down): a list's rows below the fold are not in the tree until they scroll in.
            if let direction = string(step, "scroll") {
                for _ in 0..<6 where !target.exists { drag(direction == "down" ? .down : .up) }
            }
            guard target.waitForExistence(timeout: number(step, "timeout") ?? 3) else { throw failure("\(describe(step)) is missing") }
        case "assertAbsent":
            let target = element(step)
            if let settle = number(step, "timeout") {
                guard target.waitForNonExistence(timeout: settle) else { throw failure("\(describe(step)) is there") }
            } else if target.exists {
                throw failure("\(describe(step)) is there")
            }
        case "assertHittable":
            let target = element(step)
            guard wait(number(step, "timeout") ?? 3, until: { target.exists && target.isHittable }) else {
                throw failure("\(describe(step)) is \(target.exists ? "not hittable" : "missing")")
            }
        case "assertVisible":
            // On screen as a person sees it: wholly inside the window and above the keyboard.
            let target = element(step)
            let visible: () -> Bool = {
                guard target.exists, !target.frame.isEmpty, self.app.frame.contains(target.frame) else { return false }
                let keyboard = self.app.keyboards.firstMatch
                return !keyboard.exists || target.frame.maxY <= keyboard.frame.minY
            }
            guard wait(number(step, "timeout") ?? 3, until: visible) else {
                throw failure("\(describe(step)) is \(target.exists ? "off screen at \(target.frame)" : "missing")")
            }
        case "assertNotHittable":
            let target = element(step)
            if target.exists && target.isHittable { throw failure("\(describe(step)) is hittable") }
        case "assertEnabled", "assertDisabled":
            let target = try find(step, hittable: false)
            let enabled = action == "assertEnabled"
            guard wait(number(step, "timeout") ?? 3, until: { target.isEnabled == enabled }) else {
                throw failure("\(describe(step)) is \(target.isEnabled ? "enabled" : "disabled")")
            }
        case "assertSelected", "assertNotSelected":
            // A checkmarked choice (Settings → Appearance) carries the selected trait, not a value.
            let target = try find(step, hittable: false)
            let selected = action == "assertSelected"
            guard wait(number(step, "timeout") ?? 3, until: { target.isSelected == selected }) else {
                throw failure("\(describe(step)) is \(target.isSelected ? "selected" : "not selected")")
            }
        case "assertValue", "assertLabel":
            let target = try find(step, hittable: false)
            let read: () -> String = { action == "assertValue" ? (target.value as? String ?? "") : target.label }
            let ok = wait(number(step, "timeout") ?? 3) {
                let value = read()
                if let equals = self.string(step, "equals"), value != equals { return false }
                if let contains = self.string(step, "contains"), !value.contains(contains) { return false }
                if let lacks = self.string(step, "lacks"), value.contains(lacks) { return false }
                return true
            }
            guard ok else { throw failure("\(describe(step)) reads \(read().debugDescription)") }
        case "assertCount":
            let type = Self.types[(step["type"] as? String) ?? "any"] ?? .any
            var query = app.descendants(matching: type)
            if let prefix = string(step, "idPrefix") { query = query.matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix)) }
            if let id = string(step, "id") { query = query.matching(identifier: id) }
            let expected = step["equals"] as? Int
            let atLeast = step["atLeast"] as? Int
            let ok = wait(number(step, "timeout") ?? 3) {
                let count = query.count
                return (expected.map { count == $0 } ?? true) && (atLeast.map { count >= $0 } ?? true)
            }
            guard ok else { throw failure("\(describe(step)) counts \(query.count)") }
        case "keyboard":
            let shown = (step["shown"] as? Bool) ?? true
            let keyboard = app.keyboards.firstMatch
            let ok = shown ? keyboard.waitForExistence(timeout: number(step, "timeout") ?? 5)
                : keyboard.waitForNonExistence(timeout: number(step, "timeout") ?? 5)
            guard ok else { throw failure("the keyboard is \(shown ? "hidden" : "still shown")") }
        case "screenshot":
            screenshot(string(step, "name") ?? "step")
        case "sleep":
            Thread.sleep(forTimeInterval: min(number(step, "seconds") ?? 1, 20))
        case "background":
            XCUIDevice.shared.press(.home)
            Thread.sleep(forTimeInterval: number(step, "seconds") ?? 1.5)
        case "foreground":
            try foreground()
        case "unlock":
            try unlock(timeout: number(step, "timeout") ?? 10, required: (step["required"] as? Bool) ?? true)
        case "faceID":
            // The face is shown once the system's Face ID prompt is up; a match sent before it is lost.
            let prompt = XCUIApplication(bundleIdentifier: "com.apple.springboard").staticTexts["Face ID"]
            _ = prompt.waitForExistence(timeout: number(step, "timeout") ?? 4)
            test.simulateMatchingFace()
            if prompt.exists, !prompt.waitForNonExistence(timeout: 3) { test.simulateMatchingFace() }
        case "rotate":
            switch string(step, "to") ?? "portrait" {
            case "landscapeLeft", "landscape": XCUIDevice.shared.orientation = .landscapeLeft
            case "landscapeRight": XCUIDevice.shared.orientation = .landscapeRight
            default: XCUIDevice.shared.orientation = .portrait
            }
            Thread.sleep(forTimeInterval: 1)
        case "textSize":
            try hostRequest("simui", ["contentSize": string(step, "size") ?? "large"])
        case "systemAppearance":
            try hostRequest("simui", ["appearance": string(step, "value") ?? "dark"])
        case "host":
            try host(string(step, "command") ?? "")
        case "hostCheck":
            let command = string(step, "command") ?? "hostfile"
            var payload = (step["payload"] as? [String: Any]) ?? [:]
            for (key, value) in payload { if let text = value as? String { payload[key] = substitute(text) } }
            if let args = payload["args"] as? [String] { payload["args"] = args.map(substitute) }
            let value = try hostRequest(command, payload, timeout: (number(step, "timeout") ?? 30) + 30)
            if let name = string(step, "as") { variables[name] = value }
        case "alert":
            try alert(step)
        case "terminalType":
            try terminalType(string(step, "text") ?? "")
        case "terminalSees", "terminalLacks":
            let text = string(step, "text") ?? ""
            let canvas = app.descendants(matching: .any)["terminalCanvas"].firstMatch
            guard canvas.waitForExistence(timeout: 10) else { throw failure("no terminal on screen") }
            if action == "terminalSees" {
                guard try ocr(text, in: canvas, timeout: number(step, "timeout") ?? 15) else {
                    throw failure("the terminal never showed \(text.debugDescription); it read \(lastOCR.prefix(300).debugDescription)")
                }
            } else if try ocr(text, in: canvas, timeout: 0) {
                throw failure("the terminal shows \(text.debugDescription)")
            }
        case "screenSees", "screenLacks":
            let text = string(step, "text") ?? ""
            if action == "screenSees" {
                guard try ocr(text, in: app, timeout: number(step, "timeout") ?? 10) else {
                    throw failure("the screen never showed \(text.debugDescription)")
                }
            } else if try ocr(text, in: app, timeout: 0) {
                throw failure("the screen shows \(text.debugDescription)")
            }
        case "capture":
            let target = try find(step, hittable: false)
            let name = string(step, "as") ?? "captured"
            switch string(step, "attribute") ?? "identifier" {
            case "label": variables[name] = target.label
            case "value": variables[name] = target.value as? String ?? ""
            default: variables[name] = target.identifier
            }
            if let strip = string(step, "strip") { variables[name] = variables[name]?.replacingOccurrences(of: strip, with: "") }
            note("captured \(name) = \(variables[name] ?? "")")
        case "invariants":
            try checkInvariants()
        case "repeat":
            let times = (step["times"] as? Int) ?? 1
            let steps = (step["steps"] as? [[String: Any]]) ?? []
            let outer = currentStep
            for round in 0..<times {
                variables["round"] = String(round)
                try run(steps, path: "\(outer) [\(round + 1)/\(times)] ")
            }
        case "helper":
            try helper(string(step, "name") ?? "", step)
        default:
            throw failure("unknown step \(action)")
        }
    }

    // MARK: Host

    /// Stops, starts, pauses or resumes the host process (or `cut` for the forwarder) through the harness.
    func host(_ command: String) throws {
        let folder = URL(fileURLWithPath: try XCTUnwrap(fixture.control, "Run through integration/check-ios-product.py"))
        let done = folder.appendingPathComponent(command + ".done")
        try? FileManager.default.removeItem(at: done)
        try Data().write(to: folder.appendingPathComponent(command + ".request"))
        guard wait(60, interval: 0.1, until: { FileManager.default.fileExists(atPath: done.path) }) else {
            throw failure("the harness did not answer \(command)")
        }
        switch command {
        case "stop": hostRunning = false; hostPaused = false
        case "start": hostRunning = true; hostPaused = false
        case "pause": hostPaused = true
        case "resume": hostPaused = false
        default: break
        }
        note("host \(command)")
    }

    /// Asks the harness's `command` with a JSON payload (written whole, then renamed, so the harness never reads
    /// half of it) and fails with its answer unless that is "ok".
    @discardableResult
    func hostRequest(_ command: String, _ payload: [String: Any], timeout: TimeInterval = 90) throws -> String {
        let folder = URL(fileURLWithPath: try XCTUnwrap(fixture.control, "Run through integration/check-ios-product.py"))
        let done = folder.appendingPathComponent(command + ".done")
        try? FileManager.default.removeItem(at: done)
        let staging = folder.appendingPathComponent(".\(command).staging")
        try JSONSerialization.data(withJSONObject: payload).write(to: staging)
        try FileManager.default.moveItem(at: staging, to: folder.appendingPathComponent(command + ".request"))
        guard wait(timeout, interval: 0.1, until: { FileManager.default.fileExists(atPath: done.path) }) else {
            throw failure("the harness did not answer \(command)")
        }
        let answer = ((try? String(contentsOf: done, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard answer == "ok" || answer.hasPrefix("ok:") else { throw failure("host check \(command) \(payload): \(answer)") }
        note("host \(command) \(answer.count > 40 ? "ok" : answer)")
        // "ok:<value>" answers a value (a pairing code).
        return answer.hasPrefix("ok:") ? String(answer.dropFirst(3)) : answer
    }

    // MARK: Alerts

    /// Taps `button` on an alert, the app's or the system's (a permission prompt); `optional` alerts may not come.
    func alert(_ step: [String: Any]) throws {
        let button = string(step, "button") ?? "OK"
        let optional = (step["optional"] as? Bool) == true
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deadline = Date().addingTimeInterval(number(step, "timeout") ?? (optional ? 3 : 10))
        repeat {
            for source in [springboard, app] {
                let candidates = [source.alerts.buttons[button], source.sheets.buttons[button],
                                  source.buttons.matching(NSPredicate(format: "label == %@", button)).firstMatch]
                if let target = candidates.first(where: { $0.exists && $0.isHittable }) {
                    target.tap()
                    note("alert: tapped \(button)")
                    return
                }
            }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        if !optional { throw failure("no alert offered \(button)") }
    }

    // MARK: Terminal

    /// Focuses the terminal in front (a touch focuses its renderer) and types `text`; `\n` is Return.
    func terminalType(_ text: String) throws {
        let canvas = app.descendants(matching: .any)["terminalCanvas"].firstMatch
        guard canvas.waitForExistence(timeout: 15) else { throw failure("no terminal on screen") }
        if !app.keyboards.firstMatch.exists {
            guard wait(10, until: { canvas.isHittable }) else { throw failure("the terminal cannot be touched") }
            canvas.tap()
            guard app.keyboards.firstMatch.waitForExistence(timeout: 6) else { throw failure("touching the terminal showed no keyboard") }
        }
        app.typeText(text)
    }

    /// Whether `text` shows in `element`'s screenshot, read by Vision, within `timeout`.
    func ocr(_ text: String, in element: XCUIElement, timeout: TimeInterval) throws -> Bool {
        // Monospaced text reads ambiguously (l, 1, I and |; o and 0; a period beside a letter): compare in one
        // spelling of each.
        func folded(_ value: String) -> String {
            String(value.lowercased().filter { !$0.isWhitespace && $0 != "." && $0 != "," }.map { character -> Character in
                switch character {
                case "1", "i", "|", "!": "l"
                case "0": "o"
                default: character
                }
            })
        }
        let expected = folded(text)
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            let shot = element.screenshot()
            try VNImageRequestHandler(cgImage: XCTUnwrap(shot.image.cgImage)).perform([request])
            let read = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            if folded(read).contains(expected) { return true }
            if Date() >= deadline {
                // What was read, for the failure: the region's picture and its text.
                lastOCR = read
                let attachment = XCTAttachment(screenshot: shot)
                attachment.name = String(format: "%03d-ocr-region", shots)
                attachment.lifetime = .keepAlways
                test.add(attachment)
                return false
            }
            Thread.sleep(forTimeInterval: 1)
        } while true
    }

    // MARK: Navigation helpers
    //
    // Every drawer, task-switcher, surface-menu and Settings interaction of the scripts, the walk and the matrix
    // goes through these, so the iPhone drawer and Settings redesign changes them here.

    var drawerToggle: XCUIElement { app.buttons["workspaceDrawerToggle"] }
    var header: XCUIElement { app.buttons["workspaceSwitcher"] }
    var settingsToggle: XCUIElement { app.buttons["headerSettings"] }

    var drawerShown: Bool { test.phoneDrawerShown(app) }

    var settingsShown: Bool { app.otherElements["settingsDrawer"].exists }

    func openDrawer() throws {
        if settingsShown { try closeSettings() }
        if !drawerShown { drawerToggle.tap() }
        guard wait(5, until: { self.drawerShown }) else { throw failure("the workspace drawer did not open") }
    }

    /// The drawer is a panel grown out of its button: a tap outside it closes it, as a person does.
    func closeDrawer() throws {
        guard drawerShown else { return }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.96)).tap()
        guard wait(5, until: { !self.drawerShown }) else { throw failure("the workspace drawer did not close") }
    }

    /// Opens the drawer on one of its three sections (2026-10-06): its Workspace tree (`workspaces`, or `manage`: the
    /// tree holds the Workspaces screen's management), or the workspace in use's `files` or `git`. `resume` is Resume
    /// Work, a sheet since the drawer lost its page, opened from Home's Resume box (Search History).
    func drawerPane(_ pane: String) throws {
        if pane == "resume" {
            if drawerShown { try closeDrawer() }
            test.openPhoneResumeWork(app)
            return
        }
        guard ["workspaces", "manage", "files", "git"].contains(pane) else { throw failure("the drawer has no \(pane) section") }
        try openDrawer()
        if pane == "files" || pane == "git" { test.openPhoneWorkspacePage(app, pane) } else { test.openPhoneDrawer(app) }
    }

    func openSettings() throws {
        if drawerShown { try closeDrawer() }
        test.openSettings(app)
    }

    func closeSettings() throws {
        guard settingsShown else { return }
        test.closeSettings(app)
    }

    func settingsPage(_ title: String) throws {
        try openSettings()
        test.openSettingsPage(app, title)
    }

    func goHome() throws {
        if drawerShown { try closeDrawer() }
        if settingsShown { try closeSettings() }
        test.openSidebarItem(app, "sidebarHome")
        guard app.buttons["homeNewChat"].waitForExistence(timeout: 8) else { throw failure("Home did not come") }
    }

    /// Opens the header's task menu (the task in front's own controls); false when it is disabled (Home).
    @discardableResult
    func openTaskSwitcher() throws -> Bool {
        guard header.waitForExistence(timeout: 8) else { throw failure("no header") }
        guard header.isEnabled else { return false }
        header.tap()
        guard app.descendants(matching: .any)["workspaceTaskPopover"].firstMatch.waitForExistence(timeout: 5) else {
            throw failure("the task menu did not open")
        }
        return true
    }

    /// Chooses the task whose drawer row's label contains `title`, or Home (the workspace in use's row, 2026-10-06):
    /// tasks switch only in the drawer (owner's decision, 2026-10-05).
    func chooseTask(_ title: String) throws {
        if title == "Home" {
            dismissTaskSwitcher()
            try openDrawer()
            test.showPhoneHome(app)
            guard wait(5, until: { !self.drawerShown }) else { throw failure("choosing Home did not close the drawer") }
            return
        }
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "workspacePickerTab-", title)).firstMatch
        try chooseInDrawer(row, title)
    }

    /// The current task's identifier (`workspacePickerTab-<id>`), read from the drawer's selected row.
    func currentTaskIdentifier() throws -> String {
        try drawerPane("workspaces")
        let current = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "workspacePickerTab-"))
            .allElementsBoundByIndex.first { $0.isSelected }
        guard let current else { throw failure("the drawer marks no current task") }
        let identifier = current.identifier
        try closeDrawer()
        return identifier
    }

    /// Chooses the task with this identifier in the drawer.
    func chooseTask(identifier: String) throws {
        try chooseInDrawer(app.buttons[identifier], identifier)
    }

    private func chooseInDrawer(_ row: XCUIElement, _ name: String) throws {
        dismissTaskSwitcher()
        try drawerPane("workspaces")
        // The task may be in a closed group (Chats, another workspace).
        if !row.waitForExistence(timeout: 2) { test.findInDrawerGroups(app, row) }
        test.revealInDrawer(app, row)
        guard row.waitForExistence(timeout: 5) else { throw failure("the drawer lists no \(name)") }
        row.tap()
        guard wait(5, until: { !self.drawerShown }) else { throw failure("choosing \(name) did not close the drawer") }
    }

    func dismissTaskSwitcher() {
        let popover = app.descendants(matching: .any)["workspaceTaskPopover"].firstMatch
        guard popover.exists else { return }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)).tap()
        _ = popover.waitForNonExistence(timeout: 5)
    }

    /// The current task's own actions (a terminal's keyboard, Paste, Keys, Reconnect and End; a chat's model,
    /// Pin, Export and Delete; an editor's Save…): at the top of the header's task menu, Close Task last of them.
    func openSurfaceMenu() throws {
        if drawerShown { try closeDrawer() }
        if settingsShown { try closeSettings() }
        guard try openTaskSwitcher() else { throw failure("the header has no task menu on Home alone") }
        guard app.descendants(matching: .any)["workspaceTaskActions"].firstMatch.waitForExistence(timeout: 5) else {
            throw failure("the task menu shows no actions for the task in front")
        }
    }

    func surfaceAction(_ identifier: String, label: String? = nil) throws {
        try openSurfaceMenu()
        var item = app.buttons[identifier].firstMatch
        if !item.waitForExistence(timeout: 4), let label {
            item = app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
        }
        // At the largest text sizes the task's actions can run past the popover's fold.
        test.revealInTaskMenu(app, item)
        guard item.waitForExistence(timeout: 4) else { throw failure("the task's menu has no \(identifier)") }
        item.tap()
    }

    /// Closes the task whose drawer row contains `title` with the row's swipe and Close; the current task (nil)
    /// with Close Task, the last of its actions in the task menu.
    func closeTask(_ title: String?) throws {
        guard let title else {
            try surfaceAction("closeCurrentTab", label: "Close Task")
            return
        }
        try drawerPane("workspaces")
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "workspacePickerTab-")).allElementsBoundByIndex
        guard let row = rows.first(where: { $0.label.contains(title) }) else {
            throw failure("the drawer has no task \(title)")
        }
        let id = row.identifier.replacingOccurrences(of: "workspacePickerTab-", with: "")
        row.swipeLeft()
        let close = app.buttons["closeDrawerTask-" + id]
        guard close.waitForExistence(timeout: 5) else { throw failure("swiping showed no Close") }
        close.tap()
    }

    /// Opens a Home box (chat, terminal, workspace, resume) and chooses `choice` in it, from Home.
    func homeChoice(_ box: String, _ choice: String?) throws {
        try goHome()
        let identifiers = ["chat": "homeNewChat", "terminal": "homeNewTerminal", "workspace": "openWorkspace", "resume": "homeRecentWork"]
        let button = app.buttons[identifiers[box] ?? box]
        guard button.waitForExistence(timeout: 8) else { throw failure("Home has no \(box)") }
        button.tap()
        guard app.descendants(matching: .any)["homeExpandedActionBox"].firstMatch.waitForExistence(timeout: 5) else { throw failure("the \(box) box did not open") }
        guard let choice else { return }
        let row = app.buttons[choice]
        // The box's choices are a lazy list: a row further down (Resume's last, Workspaces…) joins the tree once the
        // list scrolls to it.
        let openBox = app.descendants(matching: .any)["homeExpandedActionBox"].firstMatch
        var swipes = 0
        while !(row.waitForExistence(timeout: swipes == 0 ? 10 : 1) && row.isHittable) && swipes < 8 {
            openBox.swipeUp()
            swipes += 1
        }
        guard row.exists else { throw failure("the \(box) box has no \(choice)") }
        row.tap()
    }

    func newTerminal(_ program: String = "shell") throws {
        try homeChoice("terminal", "homeTerminalProgram-\(program)")
        guard app.descendants(matching: .any)["terminalCanvas"].firstMatch.waitForExistence(timeout: 25) else {
            throw failure("the new \(program) terminal did not show")
        }
    }

    func newPlainChat() throws {
        try homeChoice("chat", "homeNewChatStandalone")
        guard app.descendants(matching: .any)["chatDraft"].firstMatch.waitForExistence(timeout: 20) else {
            throw failure("the new chat has no composer")
        }
    }

    func newAgentChat(_ provider: String = "opencode") throws {
        try homeChoice("chat", "homeNewChatProvider-\(provider)")
        guard app.descendants(matching: .any)["chatDraft"].firstMatch.waitForExistence(timeout: 25) else {
            throw failure("the new \(provider) chat did not show")
        }
    }

    /// Opens the fixture workspace (or `id`) with its row in the drawer, which shows its Home.
    func openWorkspace(_ id: String = "fixture") throws {
        try drawerPane("workspaces")
        guard test.drawerWorkspaceRow(app, id).waitForExistence(timeout: 10) else { throw failure("the drawer lists no \(id)") }
        test.choosePhoneWorkspace(app, id)
        try goHome()
    }

    /// Opens `path` from the drawer's Files pane in the editor.
    func openFile(_ path: String) throws {
        try drawerPane("files")
        let row = app.buttons["drawerFile-\(path)"]
        guard row.waitForExistence(timeout: 15) else { throw failure("Files lists no \(path)") }
        // The row shows the file read-only first; Open in Workspace opens the editor (2026-10-06).
        test.openFileFromRow(app, row)
        guard app.textViews["fileEditor"].waitForExistence(timeout: 12) else { throw failure("\(path) did not open in the editor") }
    }

    /// Chooses the app's appearance in Settings and puts Settings away.
    func setAppearance(_ name: String) throws {
        try openSettings()
        test.setAppearance(app, name)
        try closeSettings()
    }

    func helper(_ name: String, _ step: [String: Any]) throws {
        let argument = string(step, "argument")
        switch name {
        case "openDrawer": try openDrawer()
        case "closeDrawer": try closeDrawer()
        case "drawerPane": try drawerPane(argument ?? "workspaces")
        case "openSettings": try openSettings()
        case "closeSettings": try closeSettings()
        case "settingsPage": try settingsPage(argument ?? "General")
        case "goHome": try goHome()
        case "taskSwitcher": try openTaskSwitcher()
        case "dismissTaskSwitcher": dismissTaskSwitcher()
        case "chooseTask": try chooseTask(argument ?? "Home")
        case "chooseTaskID": try chooseTask(identifier: argument ?? "")
        case "captureCurrentTask":
            let name = string(step, "as") ?? "task"
            variables[name] = try currentTaskIdentifier()
            note("captured \(name) = \(variables[name] ?? "")")
        case "surfaceMenu": try openSurfaceMenu()
        case "surfaceAction": try surfaceAction(argument ?? "", label: string(step, "label"))
        case "closeTask": try closeTask(argument)
        case "homeChoice": try homeChoice(argument ?? "chat", string(step, "choice"))
        case "newTerminal": try newTerminal(argument ?? "shell")
        case "newPlainChat": try newPlainChat()
        case "newAgentChat": try newAgentChat(argument ?? "opencode")
        case "openWorkspace": try openWorkspace(argument ?? "fixture")
        case "openFile": try openFile(argument ?? "hello.txt")
        case "setAppearance": try setAppearance(argument ?? "Dark")
        case "chooseFixtureModel": test.chooseFixtureModel(app)
        case "hideChatKeyboard": test.hideKeyboard(app)
        // Resume Work opens with its search focused, which swaps its toolbar (title, Close) for the search bar.
        case "endResumeSearch": try endResumeSearch()
        default: throw failure("unknown helper \(name)")
        }
    }

    /// Ends Resume Work's search as a person does: the search's close button beside the field when it is in
    /// sight, otherwise the keyboard's Search key and a drag on the results to put the keyboard away first
    /// (B-11: on iPhone the field and its close button sit under the keyboard). Tapping where the close button
    /// is under the keyboard would press the keyboard's dictation key instead.
    private func endResumeSearch() throws {
        let field = app.searchFields["Chats, Files and Tabs"]
        guard field.waitForExistence(timeout: 5) else { throw failure("Resume Work has no search field") }
        let close = app.buttons.matching(NSPredicate(format: "label ==[c] %@", "close")).firstMatch
        let keyboard = app.keyboards.firstMatch
        let inSight: (XCUIElement) -> Bool = { element in
            element.exists && element.isHittable && (!keyboard.exists || element.frame.maxY <= keyboard.frame.minY)
        }
        if !inSight(close), keyboard.exists {
            let search = keyboard.buttons["search"]
            if search.exists { search.tap() }
            if keyboard.exists { app.swipeDown() }
            _ = wait(3) { !keyboard.exists }
        }
        let notNow = app.buttons["Not Now"]
        if notNow.exists { notNow.tap() }
        guard wait(3, until: { inSight(close) }) else { throw failure("Resume Work's search close button is out of reach") }
        close.tap()
        // Resume Work is a sheet with Close (on iPhone since 2026-10-06; its Back button was the drawer page's).
        let back = app.navigationBars.buttons["BackButton"].firstMatch
        guard wait(5, until: { back.exists || self.app.buttons["resumeWorkClose"].exists }) else {
            throw failure("ending the search did not bring back Resume Work's way out")
        }
    }

    // MARK: Invariants

    /// The surfaces that can be in front, by the elements that show them.
    static let surfaceMarkers: [(String, [String])] = [
        ("home", ["homeActionArea"]),
        // Every empty chat shows its composer under the landing.
        ("chat", ["chatDraft", "chatUnavailable", "chatLoading"]),
        ("terminal", ["terminalCanvas", "terminalRetryConnection", "terminalCloseEnded"]),
        ("editor", ["fileEditor", "editorLoading"]),
        ("files", ["filesList", "filesTable"]),
        ("git", ["gitList"]),
        ("browser", ["browserAddress", "browserPorts"])
    ]

    func surfacesInFront() -> [String] {
        Self.surfaceMarkers.compactMap { kind, identifiers in
            identifiers.contains { identifier in
                let element = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
                return element.exists && element.isHittable
            } ? kind : nil
        }
    }

    /// A surface whose marker is laid out across the window but squeezed to no height, with its frame.
    func squeezedSurface() -> String? {
        for (kind, identifiers) in Self.surfaceMarkers {
            for identifier in identifiers {
                let element = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
                guard element.exists else { continue }
                let frame = element.frame
                if frame.width > 0, frame.height < 1, app.frame.contains(CGPoint(x: frame.midX, y: frame.minY)) {
                    return "\(kind) (\(identifier) at \(frame))"
                }
            }
        }
        return nil
    }

    /// What is presented over the surfaces: the task switcher, a panel, a Home box, an alert or a sheet.
    func presentations() -> [String] {
        var shown: [String] = []
        if app.descendants(matching: .any)["workspaceTaskPopover"].firstMatch.exists { shown.append("task switcher") }
        if drawerShown { shown.append("drawer") }
        if settingsShown { shown.append("settings") }
        if app.descendants(matching: .any)["homeExpandedActionBox"].firstMatch.exists { shown.append("home box") }
        // Home's open box and the header's panels (the drawer, Settings) are modal for VoiceOver, so XCUITest reports
        // them as alerts: not counted twice.
        let alerts = test.systemAlerts(app).allElementsBoundByIndex
            .filter { alert in !["workspaceExplorer", "settingsDrawer"].contains { alert.descendants(matching: .any)[$0].exists } }
        if !alerts.isEmpty { shown.append("alert") }
        if app.sheets.count > 0 { shown.append("dialog") }
        // A modal sheet (Workspaces, Resume Work, a diff, Pair another host, a share sheet) has no element type
        // of its own; it covers the header.
        if shown.isEmpty, header.exists, !header.isHittable, !app.staticTexts["Pair with your Mac"].exists {
            shown.append("sheet")
        }
        return shown
    }

    /// The app's invariants after a step: running in front; no cover stuck past 10 s; the header (or pairing)
    /// present; at most one presentation; exactly one surface in front when nothing is presented.
    func checkInvariants() throws {
        guard app.state == .runningForeground else {
            throw failure("the app is not running in front (state \(app.state.rawValue)): it crashed or left")
        }
        for cover in ["appLockScreen", "hostLoadingScreen"] {
            let element = app.otherElements[cover]
            guard element.exists else { continue }
            if cover == "appLockScreen" { test.simulateMatchingFace() }
            // A hung host (paused: it takes connections and never answers) lifts the opening onto the offline
            // state once the route race finds no answering address (B-14), so no cover stays past 10 s.
            guard element.waitForNonExistence(timeout: 10) else {
                throw failure("\(cover) still covers the app after 10 s\(cover == "hostLoadingScreen" && hostPaused ? " with the host hung (B-14)" : "")")
            }
        }
        if app.staticTexts["Pair with your Mac"].exists { return }
        // B-12: in landscape with the keyboard up and no panel open, the header makes way for the surface (as Notes and
        // Mail do) and comes back with the keyboard gone, which the next step's check sees (run final-walks: every
        // "header is missing" was this state, 874 × 402 with the keyboard up).
        let headerMakesWay = !header.exists && XCUIDevice.shared.orientation.isLandscape
            && app.keyboards.firstMatch.exists && presentations().isEmpty
        guard headerMakesWay || header.waitForExistence(timeout: 5) else { throw failure("the header is missing") }
        let presented = presentations()
        if presented.count > 1 { throw failure("more than one presentation at once: \(presented)") }
        if presented.isEmpty {
            var front: [String] = []
            let settled = wait(6) {
                front = self.surfacesInFront()
                return front.count == 1
            }
            if !settled, front.isEmpty, let squeezed = squeezedSurface() {
                // In front but left no room (landscape with the keyboard up): a finding, and the walk goes on.
                finding("\(squeezed) is in front but has no room to show its content")
            } else if !settled {
                throw failure(front.isEmpty ? "no surface is in front" : "several surfaces are in front: \(front)")
            }
            guard headerMakesWay || header.isHittable else { throw failure("the header cannot be touched") }
        } else if surfacesInFront().count > 1 {
            throw failure("several surfaces answer touches under \(presented)")
        }
    }
}
