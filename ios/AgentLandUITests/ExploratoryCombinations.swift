import XCTest
import UIKit

/// SplitMix64: one seed gives the same sequence of choices on every run.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

/// `testRandomWalk`: about sixty seeded steps among the actions on screen (the drawer, the task switcher,
/// Settings, Home's boxes, new chats and terminals, typing, switching tasks, going back, the lock, the
/// background, relaunches, rotation, appearance, and the host stopped, started, paused and resumed), with the
/// app's invariants checked after every step. Everything typed into a terminal while the host is up must reach
/// its shell: each line goes into `walk-<seed>.txt` in the project, which the harness reads at the end.
final class RandomWalk {
    struct Action {
        let name: String
        let weight: Int
        let run: () throws -> Void
    }

    let session: TesterSession
    let seed: UInt64
    let steps: Int
    private var generator: SeededGenerator
    private var typed: [String] = []
    private var offlineSteps = 0
    private var app: XCUIApplication { session.app }
    private var proof: String { "walk-\(seed).txt" }

    init(session: TesterSession, seed: UInt64, steps: Int) {
        self.session = session
        self.seed = seed
        self.steps = steps
        generator = SeededGenerator(seed: seed)
    }

    private func pick<T>(_ items: [T]) -> T { items[Int(generator.next() % UInt64(items.count))] }

    private func chance(_ percent: UInt64) -> Bool { generator.next() % 100 < percent }

    func run() throws {
        // A third of the walks follow the system's appearance (so flipping it changes the app), half lock.
        let appearance = ["light", "dark", "system"][Int(seed % 3)]
        let locked = seed % 2 == 1
        session.note("WALK seed=\(seed) steps=\(steps) appearance=\(appearance) lock=\(locked)")
        try session.launch(["appearance": appearance, "lock": locked, "pair": true])
        try session.openWorkspace()
        try session.checkInvariants()
        session.screenshot("walk-start")
        for step in 1...steps {
            let actions = available()
            let total = actions.reduce(0) { $0 + $1.weight }
            var roll = Int(generator.next() % UInt64(total))
            let action = actions.first { action in
                roll -= action.weight
                return roll < 0
            } ?? actions[0]
            session.begin("walk \(seed) step \(step): \(action.name)")
            try action.run()
            offlineSteps = session.hostRunning && !session.hostPaused ? 0 : offlineSteps + 1
            try session.checkInvariants()
            if step % 10 == 0 { session.screenshot("walk-step-\(step)") }
        }
        session.begin("walk \(seed) end")
        if session.hostPaused { try session.host("resume") }
        if !session.hostRunning { try session.host("start") }
        session.screenshot("walk-end")
        for line in typed {
            try session.hostRequest("hostfile", ["path": "project:\(proof)", "contains": line, "timeout": 20])
        }
        session.note("WALK seed=\(seed) done: \(typed.count) terminal lines reached the shell")
    }

    // MARK: What can be done now

    private func available() -> [Action] {
        let presented = session.presentations()
        var actions: [Action] = []
        let online = session.hostRunning && !session.hostPaused
        if presented.contains("alert") || presented.contains("dialog") {
            return [Action(name: "answer the dialog safely", weight: 1) { [self] in
                for label in ["Keep Editing", "Cancel", "OK", "Not Now", "Don’t Allow", "Don't Allow"] {
                    let button = app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
                    if button.exists && button.isHittable { button.tap(); return }
                }
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
            }]
        }
        if presented.contains("sheet") {
            return [Action(name: "put the sheet away", weight: 1) { [self] in
                for label in ["Done", "Close", "Cancel"] {
                    let button = app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
                    if button.exists && button.isHittable { button.tap(); return }
                }
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12))
                    .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)))
            }]
        }
        if presented.contains("task switcher") {
            // The task menu holds only the task's own controls (2026-10-05); tasks switch in the drawer.
            return [Action(name: "dismiss the task menu", weight: 1) { [self] in session.dismissTaskSwitcher() }]
        }
        if presented.contains("home box") {
            let safe = ["homeNewChatStandalone", "homeNewChatProvider-opencode", "homeTerminalProgram-shell"]
            return [
                Action(name: "choose in the Home box", weight: 3) { [self] in
                    let choices = safe.map { app.buttons[$0] }.filter { $0.exists && $0.isHittable }
                        + app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ OR identifier BEGINSWITH %@",
                                                         "homeResumeChat-", "homeResumeTerminal-"))
                            .allElementsBoundByIndex.filter { $0.isHittable }
                    if let choice = choices.isEmpty ? nil : pick(choices) {
                        choice.tap()
                        Thread.sleep(forTimeInterval: 1)
                    } else {
                        app.buttons["homeActionBoxClose"].tap()
                    }
                },
                Action(name: "close the Home box with ×", weight: 1) { [self] in app.buttons["homeActionBoxClose"].tap() },
                Action(name: "tap outside the Home box", weight: 1) { [self] in
                    app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
                }
            ]
        }
        if presented.contains("drawer") {
            actions += [
                Action(name: "drawer: Workspaces", weight: 1) { [self] in try session.drawerPane("workspaces") },
                Action(name: "drawer: Files", weight: 1) { [self] in try session.drawerPane("files") },
                Action(name: "drawer: Git", weight: 1) { [self] in try session.drawerPane("git") },
                Action(name: "close the drawer", weight: 2) { [self] in try session.closeDrawer() }
            ]
            let tasks = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "workspacePickerTab-")).allElementsBoundByIndex
                .filter { $0.isHittable }
            if !tasks.isEmpty {
                actions.append(Action(name: "drawer: choose a task", weight: 3) { [self] in pick(tasks).tap() })
                if tasks.count > 2 {
                    actions.append(Action(name: "drawer: swipe a task closed", weight: 1) { [self] in
                        let row = pick(tasks)
                        let id = row.identifier.replacingOccurrences(of: "workspacePickerTab-", with: "")
                        row.swipeLeft()
                        let close = app.buttons["closeDrawerTask-" + id]
                        if close.waitForExistence(timeout: 3) { close.tap() }
                    })
                }
            }
            // The workspace's row shows its Home (2026-10-06); its chevron opens or closes its tasks.
            let workspace = session.test.drawerWorkspaceRow(app, "fixture")
            if workspace.exists && workspace.isHittable {
                actions.append(Action(name: "drawer: the workspace's Home", weight: 2) { workspace.tap() })
            }
            let chevron = session.test.drawerWorkspaceExpander(app, "fixture")
            if chevron.exists && chevron.isHittable {
                actions.append(Action(name: "drawer: open or close the workspace's tasks", weight: 1) { chevron.tap() })
            }
            let sections = ["workspace", "files", "git"].map { session.test.drawerSectionSegment(app, $0) }
                .filter { $0.exists && $0.isHittable && !$0.isSelected }
            if !sections.isEmpty {
                actions.append(Action(name: "drawer: choose a section", weight: 2) { [self] in pick(sections).tap() })
            }
            let file = app.buttons["drawerFile-hello.txt"]
            if file.exists && file.isHittable {
                actions.append(Action(name: "drawer: inspect hello.txt", weight: 2) { file.tap() })
            }
            let openFile = app.buttons["fileInspectorOpen"]
            if openFile.exists && openFile.isHittable {
                actions.append(Action(name: "drawer: open the inspected file", weight: 2) { openFile.tap() })
            }
        } else if presented.contains("settings") {
            let back = app.navigationBars.buttons["BackButton"].firstMatch
            if back.exists && back.isHittable {
                actions.append(Action(name: "Settings: back", weight: 2) { back.tap() })
            } else {
                let pages = ["Connection", "Appearance", "Chat", "Terminal", "Privacy & Security", "About AgentLand"]
                    .map { app.buttons[$0] }.filter { $0.exists && $0.isHittable }
                if !pages.isEmpty {
                    actions.append(Action(name: "Settings: open a page", weight: 3) { [self] in pick(pages).tap() })
                }
            }
            actions.append(Action(name: "close Settings", weight: 2) { [self] in try session.closeSettings() })
        } else {
            actions += [
                Action(name: "open the drawer", weight: 3) { [self] in try session.openDrawer() },
                Action(name: "open Settings", weight: 1) { [self] in try session.openSettings() }
            ]
            if session.header.exists && session.header.isEnabled {
                actions.append(Action(name: "open the task menu", weight: 1) { [self] in _ = try session.openTaskSwitcher() })
            }
            let front = session.surfacesInFront()
            if front == ["home"] {
                for (name, identifier) in [("Chat", "homeNewChat"), ("Terminal", "homeNewTerminal"), ("Resume", "homeRecentWork"),
                                           ("Workspace", "openWorkspace")] {
                    let button = app.buttons[identifier]
                    if button.exists && button.isHittable {
                        actions.append(Action(name: "Home: open the \(name) box", weight: name == "Workspace" ? 1 : 3) { button.tap() })
                    }
                }
            }
            if front == ["terminal"] {
                let canvas = app.descendants(matching: .any)["terminalCanvas"].firstMatch
                let healthy = canvas.exists && !app.buttons["terminalRetryConnection"].exists
                    && !app.buttons["terminalCloseEnded"].exists && !app.otherElements["terminalNotice"].exists
                    && !app.descendants(matching: .any)["terminalNotice"].firstMatch.exists
                if healthy {
                    actions.append(Action(name: "terminal: type a line", weight: 4) { [self] in
                        let line = "W\(seed)S\(typed.count + 1)X\(UInt32.random(in: 1000...9999, using: &generator))"
                        let banner = app.descendants(matching: .any)["connectionBanner"].firstMatch
                        let expectArrival = online && !banner.exists
                        try session.terminalType("echo \(line) >> \(proof)\n")
                        if expectArrival { typed.append(line) }
                        session.note("typed \(line)\(expectArrival ? "" : " (host not reachable: not expected)")")
                    })
                }
                if app.buttons["terminalResumeTyping"].exists {
                    // Typing while the host was away may have reached it; a person checks the output and resumes.
                    actions.append(Action(name: "terminal: resume typing", weight: 3) { [self] in
                        let resume = app.buttons["terminalResumeTyping"]
                        if resume.exists && resume.isHittable { resume.tap() }
                    })
                }
                if app.keyboards.firstMatch.exists {
                    actions.append(Action(name: "terminal: hide the keyboard", weight: 1) { [self] in
                        let hide = app.buttons["terminalHideKeyboard"]
                        if hide.exists && hide.isHittable { hide.tap() }
                    })
                }
            }
            if front == ["chat"] {
                actions.append(Action(name: "chat: type a draft", weight: 2) { [self] in
                    let draft = app.descendants(matching: .any)["chatDraft"].firstMatch
                    if draft.isHittable { draft.tap(); draft.typeText(" walk\(seed)") }
                })
                if online {
                    actions.append(Action(name: "chat: send a message", weight: 1) { [self] in
                        let draft = app.descendants(matching: .any)["chatDraft"].firstMatch
                        guard draft.isHittable else { return }
                        draft.tap()
                        draft.typeText(" hello")
                        let send = app.buttons["chatSend"]
                        if send.waitForExistence(timeout: 3) && send.isEnabled { send.tap() }
                    })
                }
            }
            if front == ["editor"] {
                actions.append(Action(name: "editor: type", weight: 2) { [self] in
                    let editor = app.textViews["fileEditor"]
                    if editor.isHittable { editor.tap(); editor.typeText("w\(seed) ") }
                })
            }
            let back = app.navigationBars.buttons["BackButton"].firstMatch
            if back.exists && back.isHittable {
                actions.append(Action(name: "go back", weight: 1) { back.tap() })
            }
        }
        // Interruptions, whatever is on screen.
        actions += [
            Action(name: "background and return", weight: 1) { [self] in
                XCUIDevice.shared.press(.home)
                Thread.sleep(forTimeInterval: 1.5)
                try session.foreground()
            },
            Action(name: "terminate and relaunch", weight: 1) { [self] in try session.relaunch() },
            Action(name: "rotate", weight: 1) {
                XCUIDevice.shared.orientation = XCUIDevice.shared.orientation == .portrait ? .landscapeLeft : .portrait
                Thread.sleep(forTimeInterval: 1)
            },
            Action(name: "flip the system appearance", weight: 1) { [self] in
                try session.hostRequest("simui", ["appearance": chance(50) ? "dark" : "light"])
            }
        ]
        if !session.hostRunning {
            actions.append(Action(name: "host: start", weight: offlineSteps >= 3 ? 50 : 3) { [self] in try session.host("start") })
        } else if session.hostPaused {
            actions.append(Action(name: "host: resume", weight: offlineSteps >= 3 ? 50 : 3) { [self] in try session.host("resume") })
        } else {
            actions += [
                Action(name: "host: stop", weight: 1) { [self] in
                    try session.host("stop")
                    let banner = app.descendants(matching: .any)["connectionBanner"].firstMatch
                    if !banner.waitForExistence(timeout: 20) && !app.staticTexts["Pair with your Mac"].exists {
                        session.finding("the host stopped and no offline banner came within 20 s")
                    }
                },
                Action(name: "host: pause", weight: 1) { [self] in try session.host("pause") }
            ]
        }
        return actions
    }
}

/// `testInterruptionMatrix`: one surface brought to the front, then each interruption in turn, with the surface,
/// its content and its input checked afterwards (input refused visibly while the host is away).
final class InterruptionMatrix {
    static let interruptions = ["background", "relaunch", "hostStop", "hostPause", "appearance", "largestText", "rotate", "lock"]
    static let surfaces = ["home", "plainChat", "agentChat", "terminal", "editor", "files", "git", "settings"]

    let session: TesterSession
    let surface: String
    private var taskID: String?
    private var cell = 0
    private var app: XCUIApplication { session.app }
    private var reply: String { session.fixture.chatReply ?? "" }

    init(session: TesterSession, surface: String) {
        self.session = session
        self.surface = surface
    }

    func run(_ interruptions: [String]) throws {
        guard Self.surfaces.contains(surface) else { throw session.failure("unknown surface \(surface)") }
        // The app follows the system's appearance here, so the appearance interruption changes it.
        try session.launch(["appearance": "system", "pair": true])
        try session.hostRequest("simui", ["appearance": "light", "contentSize": "large"])
        try session.openWorkspace()
        try prepare()
        for interruption in interruptions {
            cell += 1
            session.begin("\(surface) × \(interruption)")
            let token = "M\(cell)\(interruption.prefix(4).uppercased())"
            do {
                try bringToFront()
                try mark(token)
                session.screenshot("\(surface)-\(interruption)-before")
                try apply(interruption, token: token)
                try verify(token, after: interruption)
                session.screenshot("\(surface)-\(interruption)-after")
                session.note("PASS \(surface) × \(interruption)")
            } catch let failure as TesterSession.StepFailure {
                session.finding(failure.message)
            }
            try restore()
        }
    }

    // MARK: Surfaces

    private func prepare() throws {
        switch surface {
        case "plainChat":
            try session.newPlainChat()
            session.test.chooseFixtureModel(app)
            try send("Matrix hello")
        case "agentChat":
            try session.newAgentChat("opencode")
            try send("Matrix hello")
        case "terminal":
            try session.newTerminal("shell")
        case "editor":
            try session.openFile("hello.txt")
        default:
            break
        }
        if ["plainChat", "agentChat", "terminal", "editor"].contains(surface) { taskID = try currentTaskID() }
    }

    private func send(_ text: String) throws {
        let draft = app.descendants(matching: .any)["chatDraft"].firstMatch
        guard draft.waitForExistence(timeout: 15) else { throw session.failure("the chat has no composer") }
        draft.tap()
        draft.typeText(text)
        let send = app.buttons["chatSend"]
        guard send.waitForExistence(timeout: 5) else { throw session.failure("no Send") }
        send.tap()
        guard app.staticTexts[reply].waitForExistence(timeout: 45) else { throw session.failure("the fixture model's reply never showed") }
    }

    private func currentTaskID() throws -> String {
        try session.drawerPane("workspaces")
        let current = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "workspacePickerTab-"))
            .allElementsBoundByIndex.first { $0.isSelected }
        guard let current else { throw session.failure("the drawer marks no current task") }
        let id = current.identifier
        try session.closeDrawer()
        return id
    }

    private var surfaceElement: XCUIElement {
        let identifier: String
        switch surface {
        case "home": identifier = "homeActionArea"
        case "plainChat", "agentChat": identifier = "chatDraft"
        case "terminal": identifier = "terminalCanvas"
        case "editor": identifier = "fileEditor"
        case "files": identifier = "drawerFile-hello.txt"
        case "git": identifier = "gitTree"
        default: identifier = "settingsDrawer"
        }
        return app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func bringToFront() throws {
        switch surface {
        case "home":
            try session.goHome()
        case "files":
            try session.drawerPane("files")
        case "git":
            try session.drawerPane("git")
        case "settings":
            if !session.settingsShown { try session.settingsPage("Appearance") }
        default:
            if !(surfaceElement.exists && surfaceElement.isHittable && session.presentations().isEmpty) {
                guard let taskID else { throw session.failure("the surface's task was never made") }
                try session.drawerPane("workspaces")
                let row = app.buttons[taskID]
                // Its group may be closed (Chats, or a group closed by an earlier step).
                if !row.waitForExistence(timeout: 2) { session.test.findInDrawerGroups(app, row) }
                guard row.waitForExistence(timeout: 8) else { throw session.failure("the drawer no longer lists the surface's task") }
                row.tap()
            }
            // A terminal the host ended (a host restart ends its shells) is closed and a new one made, so the
            // next interruption starts from a working shell.
            if surface == "terminal", app.buttons["terminalCloseEnded"].waitForExistence(timeout: 2) {
                session.note("the terminal ended: a new one for the next cells")
                app.buttons["terminalCloseEnded"].tap()
                try prepare()
            } else if surface == "terminal", app.buttons["terminalRetryConnection"].exists {
                app.buttons["terminalRetryConnection"].tap()
            }
        }
        guard session.wait(15, until: { self.surfaceElement.exists }) else { throw session.failure("the \(surface) did not come to the front") }
    }

    /// Something only this cell put there, to find again after the interruption.
    private func mark(_ token: String) throws {
        switch surface {
        case "plainChat", "agentChat":
            let draft = surfaceElement
            draft.tap()
            draft.typeText(" draft\(token)")
        case "terminal":
            resumeTypingIfAsked("before marking")
            try session.terminalType("echo before\(token)\n")
            guard try session.ocr("before\(token)", in: surfaceElement, timeout: 15) else {
                throw session.failure("the terminal never echoed before\(token)")
            }
        case "editor":
            let editor = app.textViews["fileEditor"]
            editor.tap()
            editor.typeText("draft\(token) ")
        default:
            break
        }
    }

    // MARK: Interruptions

    private func apply(_ interruption: String, token: String) throws {
        session.note("interruption \(interruption)")
        switch interruption {
        case "background":
            XCUIDevice.shared.press(.home)
            Thread.sleep(forTimeInterval: 3)
            try session.foreground()
        case "relaunch":
            // As a person quits it: to the app switcher (the app leaves the foreground and saves its drafts),
            // then swiped away. A kill straight from the foreground can lose the last half second of typing,
            // by design (drafts save 0.5 s after the last key, and at once on leaving the foreground).
            XCUIDevice.shared.press(.home)
            Thread.sleep(forTimeInterval: 1)
            try session.relaunch()
        case "lock":
            XCUIDevice.shared.press(.home)
            Thread.sleep(forTimeInterval: 1)
            // The app lock on: launched with it, then a trip to the background must lock it again.
            var options: [String: Any] = ["appearance": "system", "lock": true]
            options["animations"] = false
            try session.launch(options)
            XCUIDevice.shared.press(.home)
            Thread.sleep(forTimeInterval: 2)
            // Back in front (activate can leave the app in the background), still locked: the lock must cover
            // the app on its return, and a matching face takes it away.
            try session.foreground(unlocking: false)
            try session.unlock(timeout: 10, required: true)
        case "hostStop":
            try session.host("stop")
            try checkOffline(token)
            try session.host("start")
            try waitOnline()
        case "hostPause":
            try session.host("pause")
            Thread.sleep(forTimeInterval: 25)
            session.screenshot("\(surface)-paused")
            try session.host("resume")
            try waitOnline()
        case "appearance":
            try session.hostRequest("simui", ["appearance": "dark"])
            Thread.sleep(forTimeInterval: 2)
        case "largestText":
            try session.hostRequest("simui", ["contentSize": "accessibility-extra-extra-extra-large"])
            Thread.sleep(forTimeInterval: 3)
            session.screenshot("\(surface)-largest-text")
        case "rotate":
            XCUIDevice.shared.orientation = .landscapeLeft
            Thread.sleep(forTimeInterval: 2)
            session.screenshot("\(surface)-landscape")
        default:
            throw session.failure("unknown interruption \(interruption)")
        }
    }

    /// While the host is stopped: the banner says so, and input is refused where the surface takes any.
    private func checkOffline(_ token: String) throws {
        let banner = app.descendants(matching: .any)["connectionBanner"].firstMatch
        guard banner.waitForExistence(timeout: 25) else { throw session.failure("no offline banner within 25 s of the host stopping") }
        session.screenshot("\(surface)-offline")
        switch surface {
        case "terminal":
            try session.terminalType("x")
            let notice = app.descendants(matching: .any)["terminalNotice"].firstMatch
            guard notice.waitForExistence(timeout: 5) else { throw session.failure("typing offline showed no refusal") }
        case "plainChat", "agentChat":
            let send = app.buttons["chatSend"]
            if send.exists && send.isEnabled && send.isHittable {
                send.tap()
                let refused = session.wait(6) {
                    ["chatNotice", "chatOfflineNote", "chatNotSent"].contains { self.app.descendants(matching: .any)[$0].firstMatch.exists }
                }
                guard refused else { throw session.failure("sending offline showed no refusal") }
            } else {
                let note = app.descendants(matching: .any)["chatOfflineNote"].firstMatch
                guard note.exists || !send.isEnabled else { throw session.failure("the composer neither refuses nor says it is offline") }
            }
        default:
            break
        }
        session.screenshot("\(surface)-offline-input")
    }

    private func waitOnline() throws {
        let banner = app.descendants(matching: .any)["connectionBanner"].firstMatch
        guard session.wait(45, until: { !banner.exists }) else { throw session.failure("still offline 45 s after the host came back") }
    }

    // MARK: Checks

    private func verify(_ token: String, after interruption: String) throws {
        try session.checkInvariants()
        let panel = ["files", "git", "settings"].contains(surface)
        if panel && !surfaceElement.exists {
            // A panel need not survive a relaunch or the lock; Home is then in front.
            session.note("the \(surface) panel closed after \(interruption); in front: \(session.surfacesInFront())")
            guard session.surfacesInFront() == ["home"] else { throw session.failure("the panel closed and Home is not in front") }
            return
        }
        if surface == "terminal", interruption == "hostStop" || interruption == "hostPause",
           app.buttons["terminalCloseEnded"].exists || app.buttons["terminalRetryConnection"].exists {
            // A host restart may end the shell (never promised to survive one); the terminal says so plainly.
            session.note("the terminal shows \(app.buttons["terminalCloseEnded"].exists ? "Terminal ended" : "Terminal disconnected") after \(interruption)")
            return
        }
        guard session.wait(15, until: { self.surfaceElement.exists && (panel || self.surfaceElement.isHittable) }) else {
            throw session.failure("the \(surface) is not in front after \(interruption); in front: \(session.surfacesInFront()), presented: \(session.presentations())")
        }
        switch surface {
        case "plainChat", "agentChat":
            let draft = surfaceElement
            guard session.wait(8, until: { (draft.value as? String ?? "").contains("draft\(token)") }) else {
                throw session.failure("the draft lost draft\(token): \((draft.value as? String ?? "").debugDescription)")
            }
            guard app.staticTexts[reply].waitForExistence(timeout: 10) else { throw session.failure("the transcript lost the reply") }
            draft.tap()
            draft.typeText(" after")
            guard session.wait(5, until: { (draft.value as? String ?? "").contains("after") }) else {
                throw session.failure("the composer took no typing")
            }
            clearDraft()
        case "terminal":
            let canvas = surfaceElement
            let ended = app.buttons["terminalCloseEnded"].exists || app.buttons["terminalRetryConnection"].exists
            if ended {
                session.note("the terminal shows \(app.buttons["terminalCloseEnded"].exists ? "Terminal ended" : "Terminal disconnected") after \(interruption)")
                if interruption != "hostStop" { throw session.failure("the terminal ended or disconnected after \(interruption)") }
                return
            }
            resumeTypingIfAsked("after \(interruption)")
            if interruption != "hostStop", try !session.ocr("before\(token)", in: canvas, timeout: 10) {
                throw session.failure("the terminal lost its output before\(token)")
            }
            try session.terminalType("echo after\(token) >> matrix-terminal.txt\n")
            try session.hostRequest("hostfile", ["path": "project:matrix-terminal.txt", "contains": "after\(token)", "timeout": 20])
        case "editor":
            let editor = surfaceElement
            guard (editor.value as? String ?? "").contains("draft\(token)") else {
                throw session.failure("the editor lost its draft draft\(token)")
            }
            editor.tap()
            editor.typeText("x")
        case "home":
            app.buttons["homeNewTerminal"].tap()
            guard app.buttons["homeTerminalProgram-shell"].waitForExistence(timeout: 5) else { throw session.failure("Home's Terminal box did not open") }
            app.buttons["homeActionBoxClose"].tap()
        default:
            break
        }
    }

    /// Typing that may or may not have reached the host (it was paused or stopped) blocks the terminal's input
    /// until the person has checked the output and chosen Resume typing; a tester does the same.
    private func resumeTypingIfAsked(_ when: String) {
        let resume = app.buttons["terminalResumeTyping"]
        guard resume.waitForExistence(timeout: 3) else { return }
        session.note("the terminal asks to check its output before typing again (\(when)); the tester resumes typing")
        session.screenshot("\(surface)-resume-typing")
        // B-13: the notice sits at the bottom, under the rows it asks the person to check and above the key bar.
        let notice = app.descendants(matching: .any)["terminalNotice"].firstMatch
        let rows = app.textViews["terminalCanvas"].firstMatch
        if notice.exists, rows.exists, notice.frame.minY < rows.frame.maxY - 1 {
            session.finding("the terminal's notice covers its rows (notice \(notice.frame), rows \(rows.frame))")
        }
        let keyBar = app.descendants(matching: .any)["terminalKeyBar"].firstMatch
        if notice.exists, keyBar.exists, notice.frame.maxY > keyBar.frame.minY + 1 {
            session.finding("the terminal's notice is under the key bar (notice \(notice.frame), key bar \(keyBar.frame))")
        }
        resume.tap()
        _ = session.wait(5) { !resume.exists }
    }

    private func clearDraft() {
        let draft = surfaceElement
        let length = (draft.value as? String)?.count ?? 0
        if length > 0 { draft.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: length)) }
    }

    private func restore() throws {
        if session.hostPaused { try session.host("resume") }
        if !session.hostRunning { try session.host("start") }
        XCUIDevice.shared.orientation = .portrait
        try session.hostRequest("simui", ["appearance": "light", "contentSize": "large"])
        if session.lockEnabled { try session.launch(["appearance": "system", "lock": false]) }
        if app.keyboards.firstMatch.exists {
            let hide = app.buttons["terminalHideKeyboard"]
            if hide.exists && hide.isHittable { hide.tap() }
        }
    }
}
