import AppKit
import SwiftUI
import XCTest
import AgentLandCore
import AgentLandWorkspace
@testable import AgentLandDesktopCore
@testable import AgentLandDesktop

/// A local host whose capabilities the test sets; it serves no agent icon, and counts the capabilities reads.
private final class SignInsHost: APITransport, @unchecked Sendable {
    private let lock = NSLock()
    private var body: String
    private var reads = 0
    private var log: [String] = []
    /// The status the sign-in check answers: 204 for a host with it, 404 for an older one.
    let checkStatus: Int

    init(_ capabilities: String, checkStatus: Int = 404) {
        body = capabilities
        self.checkStatus = checkStatus
    }

    var capabilities: String {
        get { lock.withLock { body } }
        set { lock.withLock { body = newValue } }
    }
    var capabilitiesReads: Int { lock.withLock { reads } }
    /// The sign-in checks and capabilities reads, in order.
    var requests: [String] { lock.withLock { log } }

    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path ?? ""
        if path == "/v1/chat/providers/check" || path == "/v1/capabilities" {
            lock.withLock { log.append("\(request.httpMethod ?? "") \(path)") }
        }
        let (status, answer): (Int, String) = switch path {
        case "/v1/capabilities": (200, lock.withLock { reads += 1; return body })
        case "/v1/chat/providers/check" where request.httpMethod == "POST" && checkStatus == 204: (204, "")
        case "/v1/projects": (200, #"{"projects":[]}"#)
        case "/v1/agents/icon": (404, #"{"error":{"code":"not_found","message":"No icon."}}"#)
        default: (404, #"{"error":{"code":"not_found","message":"Not here."}}"#)
        }
        return (Data(answer.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

/// Setup's Claude Code and Codex step (owner, 2026-10-17: "on the mac app i have signed in via the cli agents to my
/// subscription, rather than ask for api keys the mac onboarding app needs to see this").
final class OnboardingAgentsTests: XCTestCase {
    private static func capabilities(_ workspaceChats: String?) -> String {
        guard let workspaceChats else { return #"{"interactions":true,"terminal":true}"# }
        return #"{"interactions":true,"terminal":true,"workspaceChats":"# + workspaceChats + "}"
    }

    private static func provider(_ id: String, _ auth: String) -> String {
        let name = id == "claude" ? "Claude Code" : "Codex"
        return #"{"id":"\#(id)","name":"\#(name)","tools":[],"features":[],"auth":\#(auth)}"#
    }

    private static let claudeSubscription = provider("claude", #"{"kind":"subscription","label":"Claude subscription"}"#)
    private static let codexSubscription = provider("codex", #"{"kind":"subscription","label":"ChatGPT subscription"}"#)
    private static let claudeSignedOut = provider("claude", #"""
        {"kind":"signedOut","label":"Not signed in","reason":"subscription_required",
         "message":"Claude Code isn’t signed in. Sign in to Claude Code with your Claude subscription (claude auth login)."}
        """#)
    private static let codexAPIKey = provider("codex", #"""
        {"kind":"apiKey","label":"API key","reason":"subscription_required",
         "message":"Codex is signed in with an API key, which Chat doesn’t use. Sign in to Codex with your ChatGPT subscription (codex login)."}
        """#)
    private static let codexVersion = provider("codex", #"""
        {"kind":"unknown","label":"Version not supported","reason":"version_unsupported",
         "message":"AgentLand’s Chat doesn’t support Codex 9.0.0 yet. Use Codex in Terminal."}
        """#)

    private static func chats(_ providers: [String], unavailable: [String] = []) -> String {
        #"{"version":1,"providers":[\#(providers.joined(separator: ","))],"unavailableProviders":[\#(unavailable.joined(separator: ","))]}"#
    }

    private static func decoded(_ body: String) throws -> CapabilitiesResponse {
        try ProtocolDecoder.decode(CapabilitiesResponse.self, from: Data(body.utf8))
    }

    private static func signIns(_ workspaceChats: String?) throws -> PlainChatSignIns {
        guard case let .signIns(signIns) = OnboardingAgents.content(try decoded(capabilities(workspaceChats)), reading: false) else {
            XCTFail("no sign-ins")
            return PlainChatSignIns(nil as WorkspaceChatsCapability?)
        }
        return signIns
    }

    /// A subscription: signed in, with a checkmark and nothing to do. Not signed in, an API key: the host's words and the
    /// command that signs the CLI in with its subscription. A version Chat does not support: the host's words alone.
    func testOnboardingRowsSayHowEachAgentIsSignedIn() throws {
        let both = try Self.signIns(Self.chats([Self.claudeSubscription, Self.codexSubscription]))
        XCTAssertEqual(both.rows.map(\.name), ["Claude Code", "Codex"])
        XCTAssertEqual(both.rows.map(\.status), ["Signed in with your Claude subscription", "Signed in with your ChatGPT subscription"])
        XCTAssertEqual(both.rows.map(\.available), [true, true])
        XCTAssertEqual(both.rows.map(\.signInCommand), [nil, nil])
        XCTAssertEqual(both.rows.map(\.detail), [nil, nil])

        let notSignedIn = try Self.signIns(Self.chats([], unavailable: [Self.claudeSignedOut]))
        XCTAssertEqual(notSignedIn.rows.map(\.status), ["Not signed in"])
        XCTAssertEqual(notSignedIn.rows.map(\.available), [false])
        XCTAssertEqual(notSignedIn.rows.first?.signInCommand, "claude auth login")
        XCTAssertEqual(notSignedIn.rows.first?.detail,
                       "Claude Code isn’t signed in. Sign in to Claude Code with your Claude subscription (claude auth login).")

        let apiKey = try Self.signIns(Self.chats([Self.claudeSubscription], unavailable: [Self.codexAPIKey]))
        XCTAssertEqual(apiKey.rows.map(\.id), ["claude", "codex"])
        XCTAssertEqual(apiKey.rows.map(\.status), ["Signed in with your Claude subscription", "API key"])
        XCTAssertEqual(apiKey.rows.map(\.signInCommand), [nil, "codex login"])
        XCTAssertEqual(apiKey.rows[1].detail,
                       "Codex is signed in with an API key, which Chat doesn’t use. Sign in to Codex with your ChatGPT subscription (codex login).")

        let version = try Self.signIns(Self.chats([], unavailable: [Self.codexVersion]))
        XCTAssertEqual(version.rows.map(\.status), ["Version not supported"])
        XCTAssertEqual(version.rows.first?.reason, PlainChatAuth.versionUnsupported)
        XCTAssertNil(version.rows.first?.signInCommand, "signing in again does not fix a version")
        XCTAssertEqual(version.rows.first?.detail, "AgentLand’s Chat doesn’t support Codex 9.0.0 yet. Use Codex in Terminal.")
    }

    /// Neither listed (none installed, or a host from before Chat ran them): what to install, and that Files and Terminal
    /// work without them. Nothing read yet: Checking… while a read is on its way, else that it could not be read.
    func testOnboardingSaysWhatToDoWhenNeitherIsListed() throws {
        XCTAssertEqual(OnboardingAgents.content(try Self.decoded(Self.capabilities(Self.chats([]))), reading: false), .none)
        XCTAssertEqual(OnboardingAgents.content(try Self.decoded(Self.capabilities(nil)), reading: false), .none,
                       "an older host lists no workspaceChats")
        XCTAssertEqual(PlainChatSignIns.none,
                       "Install Claude Code or Codex and sign in with your subscription to chat from your iPhone. Files and Terminal work without them.")
        XCTAssertEqual(OnboardingAgents.content(nil, reading: true), .checking)
        XCTAssertEqual(OnboardingAgents.content(nil, reading: false), .unreadable)
        XCTAssertEqual(OnboardingAgents.title, "Claude Code and Codex")
    }

    /// The step reads the host's capabilities itself when the workspace has none yet, and shows the rows they list.
    @MainActor
    func testOnboardingAgentsStepReadsTheCapabilitiesWhenNoneAreKnown() async throws {
        let fixture = try RestartFixture(withState: false)
        defer { fixture.cleanUp() }
        let host = try fixture.connectedController(backoff: RestartBackoff(delays: [30], limit: 3, window: 60))
        try await waitForCondition("the start") { host.status == .running && !host.isWorking }
        XCTAssertEqual(host.onboardingStage, .agents)

        let transport = SignInsHost(Self.capabilities(Self.chats([Self.claudeSubscription], unavailable: [Self.codexAPIKey])))
        let (model, cleanUp) = try Self.model(transport)
        defer { cleanUp() }
        XCTAssertNil(model.capabilities)
        let window = Self.window(OnboardingContent(), host: host, model: model, appearance: .aqua)
        try await waitForCondition("the step's read") { model.capabilities != nil }
        XCTAssertEqual(transport.capabilitiesReads, 1)
        XCTAssertEqual(PlainChatSignIns(model.capabilities?.workspaceChats).rows.map(\.status),
                       ["Signed in with your Claude subscription", "API key"])

        XCTAssertEqual(transport.requests, ["POST /v1/chat/providers/check", "GET /v1/capabilities"],
                       "the host is asked to check first; this one is older (404), so its capabilities are read as they are")

        // Check Again goes through the same host check (the button calls `check`).
        transport.capabilities = Self.capabilities(Self.chats([Self.claudeSubscription, Self.codexSubscription]))
        await OnboardingAgents.check(model)
        XCTAssertEqual(PlainChatSignIns(model.capabilities?.workspaceChats).rows.map(\.available), [true, true])
        window.close()
        await host.stopAndWait()
    }

    /// PNG renders of the step for the owner's look check: signed in, mixed, neither signed in and empty, light and dark, in the
    /// setup window's own content. Does nothing unless AGENTLAND_RENDER_DIR names a folder.
    @MainActor
    func testRenderOnboardingAgentsStep() async throws {
        guard let directory = ProcessInfo.processInfo.environment["AGENTLAND_RENDER_DIR"] else { throw XCTSkip("no render folder") }
        let fixture = try RestartFixture(withState: false)
        defer { fixture.cleanUp() }
        let host = try fixture.connectedController(backoff: RestartBackoff(delays: [30], limit: 3, window: 60))
        try await waitForCondition("the start") { host.status == .running && !host.isWorking }
        XCTAssertEqual(host.onboardingStage, .agents)
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)

        let cases: [(String, String?)] = [
            ("signed-in", Self.chats([Self.claudeSubscription, Self.codexSubscription])),
            ("mixed", Self.chats([Self.claudeSubscription], unavailable: [Self.codexAPIKey])),
            ("not-signed-in-and-version", Self.chats([], unavailable: [Self.claudeSignedOut, Self.codexVersion])),
            ("empty", Self.chats([])),
        ]
        for (name, chats) in cases {
            for (look, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let transport = SignInsHost(Self.capabilities(chats))
                let (model, cleanUp) = try Self.model(transport)
                defer { cleanUp() }
                model.capabilities = try Self.decoded(Self.capabilities(chats))
                try await Self.render(SetupWindowView(), host: host, model: model, appearance: appearance,
                                      to: directory + "/onboarding-agents-\(name)-\(look).png")
            }
        }
        // Sign In… (owner, 2026-10-17): one row signed in and one with Sign In…; one waiting for Terminal beside one
        // with Sign In….
        let codexSignedOut = Self.provider("codex", #"""
            {"kind":"signedOut","label":"Not signed in","reason":"subscription_required",
             "message":"Codex isn’t signed in. Sign in to Codex with your ChatGPT subscription (codex login)."}
            """#)
        let signInCases: [(String, String, [String: MacChatSignInRow.SignIn])] = [
            ("sign-in", Self.chats([Self.claudeSubscription], unavailable: [codexSignedOut]), [:]),
            ("sign-in-waiting", Self.chats([], unavailable: [Self.claudeSignedOut, Self.codexAPIKey]), ["claude": .waiting]),
        ]
        for (name, chats, states) in signInCases {
            for (look, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let transport = SignInsHost(Self.capabilities(chats))
                let (model, cleanUp) = try Self.model(transport)
                defer { cleanUp() }
                model.capabilities = try Self.decoded(Self.capabilities(chats))
                let watch = ChatSignInWatch(terminal: Self.terminal(opened: OpenedScripts()))
                watch.states = states
                try await Self.render(SetupWindowView(), host: host, model: model, watch: watch, appearance: appearance,
                                      to: directory + "/onboarding-agents-\(name)-\(look).png")
            }
        }
        await host.stopAndWait()
    }

    // MARK: Sign In…

    /// The script Sign In… opens runs the CLI's own sign-in and nothing else, from a 0700 folder, itself 0700; a provider
    /// without a sign-in command gets none, and a link where the folder goes is refused.
    @MainActor
    func testSignInScriptsRunOnlyTheCLIsOwnSignIn() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "signin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let opened = OpenedScripts()
        var terminal = Self.terminal(opened: opened)
        terminal.folder = root.appending(path: "AgentLandSignIn")

        let claude = try XCTUnwrap(try terminal.write(id: "claude"))
        XCTAssertEqual(try String(contentsOf: claude, encoding: .utf8),
                       "#!/bin/sh\nclaude auth login\necho\necho 'You can close this window and go back to AgentLand.'\n")
        XCTAssertEqual(claude.lastPathComponent, "claude-sign-in.command")
        let codex = try XCTUnwrap(try terminal.write(id: "codex"))
        XCTAssertEqual(try String(contentsOf: codex, encoding: .utf8),
                       "#!/bin/sh\ncodex login\necho\necho 'You can close this window and go back to AgentLand.'\n")
        for path in [terminal.folder.path, claude.path, codex.path] {
            let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)
            XCTAssertEqual(mode.intValue & 0o777, 0o700, path)
        }
        // Written again (Sign In… a second time), the same script.
        XCTAssertEqual(try terminal.write(id: "claude"), claude)
        XCTAssertNil(try terminal.write(id: "opencode"), "only Claude Code and Codex have a sign-in command")
        XCTAssertNil(try terminal.write(id: "../claude"))

        XCTAssertTrue(terminal.start(id: "codex"))
        XCTAssertEqual(opened.urls, [codex], "opened through the injected opener, never Terminal itself")

        let linked = root.appending(path: "Linked")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: root)
        terminal.folder = linked
        XCTAssertThrowsError(try terminal.write(id: "claude"), "a link where the folder goes")
        XCTAssertFalse(terminal.start(id: "claude"))
    }

    /// Sign In… shows only on a row that signing in fixes, and only where the Mac offers it: a row signed in with a
    /// subscription and one whose version Chat does not support have none, and draw the same with or without it.
    @MainActor
    func testSignInShowsOnlyWhereSigningInHelps() throws {
        let noFix = try Self.signIns(Self.chats([Self.claudeSubscription], unavailable: [Self.codexVersion]))
        let fixes = try Self.signIns(Self.chats([], unavailable: [Self.claudeSignedOut, Self.codexAPIKey]))
        XCTAssertEqual(noFix.rows.map { MacChatSignInRow.offersSignIn($0, offered: true) }, [false, false])
        XCTAssertEqual(fixes.rows.map { MacChatSignInRow.offersSignIn($0, offered: true) }, [true, true])
        XCTAssertEqual(fixes.rows.map { MacChatSignInRow.offersSignIn($0, offered: false) }, [false, false],
                       "iPhone's and iPad's rows, and any the Mac does not offer it on")

        let suite = "OnboardingAgentsTests.rows.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let icons = WorkspaceModel(defaults: defaults, keys: .desktop).agents.icons
        func height(_ row: PlainChatSignIns.Row, offered: Bool, state: MacChatSignInRow.SignIn = .idle) -> CGFloat {
            NSHostingView(rootView: MacChatSignInRow(row: row, icons: icons, signIn: state, startSignIn: offered ? {} : nil)
                .frame(width: 520)).fittingSize.height
        }
        for row in noFix.rows {
            XCTAssertEqual(height(row, offered: true), height(row, offered: false), "no Sign In… for \(row.id)")
        }
        for row in fixes.rows {
            XCTAssertGreaterThan(height(row, offered: true), height(row, offered: false), "Sign In… for \(row.id)")
            XCTAssertGreaterThanOrEqual(height(row, offered: true, state: .waiting), height(row, offered: true),
                                        "Sign In… stays while waiting")
        }
        XCTAssertEqual(MacChatSignInRow.waiting, "Waiting for sign-in in Terminal…")
    }

    /// The watch asks the host every few seconds and stops once the agent is signed in with a subscription, saying so
    /// to VoiceOver; after its time limit; and when the step or pane goes away. A script that could not open says so.
    @MainActor
    func testTheSignInWatchStopsOnSuccessTheLimitAndStop() async throws {
        let signedOut = try Self.signIns(Self.chats([Self.claudeSubscription], unavailable: [Self.codexAPIKey]))
        let signedIn = try Self.signIns(Self.chats([Self.claudeSubscription, Self.codexSubscription]))
        let codex = try XCTUnwrap(signedOut.rows.first { $0.id == "codex" })
        let announced = Announcements()
        let opened = OpenedScripts()
        let quick = ChatSignInWatch.Schedule(every: .seconds(3), limit: .seconds(300), sleep: { _ in await Task.yield() })

        // Signed in on the third check.
        var checks = 0
        let watch = ChatSignInWatch(terminal: Self.terminal(opened: opened), schedule: quick, announce: announced.announce)
        watch.signIn(codex) {
            checks += 1
            return checks < 3 ? signedOut : signedIn
        }
        XCTAssertEqual(watch.state("codex"), .waiting)
        XCTAssertEqual(opened.urls.map(\.lastPathComponent), ["codex-sign-in.command"])
        try await waitForCondition("the sign-in") { watch.state("codex") == .idle }
        XCTAssertEqual(checks, 3)
        XCTAssertEqual(announced.messages, ["Codex signed in"])

        // Never signed in: 300 s at one check every 3 s, then it gives up quietly.
        var limited = 0
        let patient = ChatSignInWatch(terminal: Self.terminal(opened: opened), schedule: quick, announce: announced.announce)
        patient.signIn(codex) {
            limited += 1
            return signedOut
        }
        try await waitForCondition("the time limit") { patient.state("codex") == .idle }
        XCTAssertEqual(limited, 100)
        XCTAssertEqual(announced.messages, ["Codex signed in"])

        // The step or pane goes away: the watch ends without another check.
        var stopped = 0
        let waiting = ChatSignInWatch(terminal: Self.terminal(opened: opened),
                                      schedule: .init(sleep: { _ in try await Task.sleep(for: .seconds(3600)) }),
                                      announce: announced.announce)
        waiting.signIn(codex) {
            stopped += 1
            return signedIn
        }
        XCTAssertEqual(waiting.state("codex"), .waiting)
        waiting.stop()
        XCTAssertEqual(waiting.state("codex"), .idle)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(stopped, 0)
        XCTAssertEqual(announced.messages, ["Codex signed in"])

        // Terminal could not be opened: nothing to wait for.
        let failing = ChatSignInWatch(terminal: ChatSignInTerminal(folder: Self.scratchFolder(), open: { _ in false }),
                                      schedule: quick, announce: announced.announce)
        failing.signIn(codex) { signedIn }
        XCTAssertEqual(failing.state("codex"), .couldNotOpen)
    }

    /// Check Again and the watch go through the host's check: a host with it answers 204 and its capabilities are read
    /// after it; an older host (404) is read as it is.
    @MainActor
    func testCheckAgainAsksTheHostToCheckFirst() async throws {
        for status in [204, 404] {
            let transport = SignInsHost(Self.capabilities(Self.chats([Self.claudeSubscription])), checkStatus: status)
            let (model, cleanUp) = try Self.model(transport)
            defer { cleanUp() }
            let signIns = await OnboardingAgents.check(model)
            XCTAssertEqual(transport.requests, ["POST /v1/chat/providers/check", "GET /v1/capabilities"], "\(status)")
            XCTAssertEqual(signIns.rows.map(\.available), [true], "\(status)")
        }
    }

    // MARK: Helpers

    /// Records the scripts the opener was given; nothing is opened.
    @MainActor
    private final class OpenedScripts {
        var urls: [URL] = []
    }

    /// Records VoiceOver announcements.
    @MainActor
    private final class Announcements {
        var messages: [String] = []
        var announce: @MainActor (String) -> Void { { [weak self] message in self?.messages.append(message) } }
    }

    private static func scratchFolder() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "OnboardingAgentsTests-\(UUID().uuidString)/AgentLandSignIn")
    }

    @MainActor
    private static func terminal(opened: OpenedScripts) -> ChatSignInTerminal {
        let folder = scratchFolder()
        try? FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        return ChatSignInTerminal(folder: folder, open: { url in
            opened.urls.append(url)
            return true
        })
    }

    @MainActor
    private static func model(_ transport: SignInsHost) throws -> (WorkspaceModel, () -> Void) {
        let suite = "OnboardingAgentsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let model = WorkspaceModel(defaults: defaults, keys: .desktop)
        let client = APIClient(address: try ServerAddress(validating: "https://127.0.0.1:9841"), token: "session", transport: transport)
        let identity = ConnectionIdentity(host: "onboarding-test.local", deviceID: "local-mac")
        model.attach(hostID: identity.storageKey, identity: identity, client: client)
        return (model, { defaults.removePersistentDomain(forName: suite) })
    }

    @MainActor
    private static func window(_ view: some View, host: HostController, model: WorkspaceModel,
                               watch: ChatSignInWatch? = nil, appearance: NSAppearance.Name) -> NSWindow {
        let hosting = NSHostingView(rootView: view.environmentObject(host).environment(model).environment(watch))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 640), styleMask: [.titled],
                              backing: .buffered, defer: false)
        // The test owns the window; closing it must not release it a second time.
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        return window
    }

    @MainActor
    private static func render(_ view: some View, host: HostController, model: WorkspaceModel,
                               watch: ChatSignInWatch? = nil, appearance: NSAppearance.Name, to path: String) async throws {
        let window = window(view, host: host, model: model, watch: watch, appearance: appearance)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(600))
        guard let content = window.contentView else { return XCTFail("no content") }
        content.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }
}
