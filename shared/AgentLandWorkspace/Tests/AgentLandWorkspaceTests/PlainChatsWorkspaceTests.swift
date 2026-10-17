import XCTest
import AgentLandCore
import AgentLandChat
@testable import AgentLandArchive
@testable import AgentLandWorkspace

/// Chat in the workspace (owner, 2026-10-12): a new chat is a Claude Code or Codex chat in the selected workspace
/// (`capabilities.workspaceChats`), listed, searched and resumed with that workspace. The Chats space is no workspace:
/// its older chats stay in the tab list whatever workspace is open, showing one never changes the workspace in use, and
/// the library, search and "is it live" read the Chats space too.
@MainActor final class PlainChatsWorkspaceTests: XCTestCase {
    private let identity = ConnectionIdentity(host: "https://studio.local:9841", deviceID: "device-a")
    private let hostID = "https://studio.local:9841|device-a"
    private var suites: [String] = []

    override func tearDown() async throws {
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        suites = []
    }

    private func defaults(_ name: String = #function) throws -> UserDefaults {
        let suite = "plain-chats-\(name)-\(UUID())"
        suites.append(suite)
        return try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    nonisolated static let plainCapabilities = #"{"interactions":true,"terminal":true,"chatFeatures":["events","parts"],"archive":{"version":1,"features":["sync"]},"plainChats":{"projectId":"chats","tools":["websearch","fetch","memory"],"searchProvider":"exa"},"workspaceChats":{"version":1,"providers":[{"id":"claude","name":"Claude Code","tools":[],"features":["events"]},{"id":"codex","name":"Codex","tools":[],"features":["events"]}],"unavailableProviders":[]}}"#
    /// Between the Chats-space providers and `workspaceChats`: Claude Code and Codex in the Chats space only.
    nonisolated static let chatsSpaceProvidersCapabilities = #"{"interactions":true,"terminal":true,"plainChats":{"projectId":"chats","providers":[{"id":"claude","name":"Claude Code","tools":[],"features":[]},{"id":"codex","name":"Codex","tools":[],"features":[]}]}}"#
    nonisolated static let olderCapabilities = #"{"interactions":true,"terminal":true,"chatFeatures":["events","parts"]}"#

    /// A host with two workspaces, and Chat (`workspaceChats`) and a Chats space unless `capabilities` says otherwise. A new
    /// chat's ID names its agent, as the host's do.
    private func host(capabilities: String = PlainChatsWorkspaceTests.plainCapabilities) -> ScriptedHost {
        let host = ScriptedHost()
        host.on("/v1/capabilities") { _ in (200, capabilities) }
        host.on("/v1/projects") { _ in (200, #"{"projects":[{"id":"a","name":"App"},{"id":"b","name":"Blog"}]}"#) }
        host.on("/v1/sessions") { request in
            if request.httpMethod == "POST" {
                let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
                let project = body?["projectId"] as? String ?? ""
                let provider = body?["provider"] as? String ?? "opencode"
                let id = provider == "opencode" ? "ses_new" : provider + ":new"
                return (201, #"{"id":"\#(id)","title":"New chat","projectId":"\#(project)","provider":"\#(provider)"}"#)
            }
            return (200, #"{"sessions":[]}"#)
        }
        return host
    }

    private func attached(_ host: ScriptedHost, defaults: UserDefaults) async throws -> WorkspaceModel {
        let model = WorkspaceModel(defaults: defaults)
        model.attach(hostID: hostID, identity: identity,
                     client: APIClient(address: try ServerAddress(validating: "https://studio.local:9841"), token: "token", transport: host))
        await model.refreshProjects()
        return model
    }

    func testProviderDefaultsKeepLegacyOpenCodeModel() async throws {
        let saved = try defaults()
        saved.set("openai/old-model", forKey: WorkspaceModel.plainChatModelKey + identity.storageKey)
        let model = try await attached(host(), defaults: saved)
        XCTAssertEqual(model.plainChatDefaultModel(for: .opencode), "openai/old-model")
        model.setPlainChatDefaultProvider(.claude)
        XCTAssertNil(model.plainChatDefaultModel)
        model.setPlainChatDefaultModel("claude/sonnet")
        model.setPlainChatDefaultProvider(.opencode)
        XCTAssertEqual(model.plainChatDefaultModel, "openai/old-model")
        model.setPlainChatDefaultProvider(.claude)
        XCTAssertEqual(model.plainChatDefaultModel, "claude/sonnet")
    }

    /// An agent the host does not offer for Chat is refused with an issue; a new chat with none asked for uses the host's
    /// only one.
    func testAnUnavailableProviderIsRefusedWithAnIssue() async throws {
        let capabilities = #"{"interactions":true,"terminal":true,"workspaceChats":{"version":1,"providers":[{"id":"claude","name":"Claude Code","tools":[],"features":[]}],"unavailableProviders":[{"id":"codex","name":"Codex","tools":[],"features":[]}]}}"#
        let model = try await attached(host(capabilities: capabilities), defaults: defaults())
        model.selectProject("a")
        model.setPlainChatDefaultProvider(.codex)
        model.newPlainChat(provider: .codex)
        XCTAssertFalse(model.creating)
        XCTAssertEqual(model.creationIssue, "Choose an available Chat provider. Codex is unavailable on this Mac.")
        XCTAssertEqual(model.plainChatUnavailableProviders.map(\.id), ["codex"])
        XCTAssertEqual(model.newPlainChatProvider, .claude, "The host's only agent")
    }

    /// Chat runs on the Mac's subscriptions (2026-10-12): with no choice saved, a new chat starts with Claude when the
    /// host offers it, else the host's first provider; a saved OpenCode, from before OpenCode left Chat, counts as no
    /// choice.
    func testNewChatsDefaultToClaudeThenTheHostsFirstProvider() async throws {
        let both = #"{"interactions":true,"terminal":true,"workspaceChats":{"version":1,"providers":[{"id":"codex","name":"Codex","tools":[],"features":[]},{"id":"claude","name":"Claude Code","tools":[],"features":[]}]}}"#
        let unchosen = try await attached(host(capabilities: both), defaults: defaults())
        XCTAssertEqual(unchosen.plainChatDefaultProvider, .claude)
        XCTAssertEqual(unchosen.newPlainChatProvider, .claude)

        let codexOnly = #"{"interactions":true,"terminal":true,"plainChats":{"projectId":"chats","providers":[{"id":"opencode","name":"OpenCode","tools":[],"features":[]}]},"workspaceChats":{"version":1,"providers":[{"id":"codex","name":"Codex","tools":[],"features":[]}]}}"#
        let savedOpenCode = try defaults()
        savedOpenCode.set("opencode", forKey: WorkspaceModel.plainChatModelKey + identity.storageKey + ".provider")
        let model = try await attached(host(capabilities: codexOnly), defaults: savedOpenCode)
        XCTAssertEqual(model.newPlainChatProvider, .codex, "Without Claude, the host's first provider")
        model.selectProject("a")
        model.newPlainChat()
        XCTAssertNil(model.creationIssue)
        await waitUntil { !model.creating }
        XCTAssertEqual(model.plainChatDefaultProvider, .codex, "The provider used is saved as the choice")

        let chosen = try defaults()
        chosen.set("codex", forKey: WorkspaceModel.plainChatModelKey + identity.storageKey + ".provider")
        let chosenModel = try await attached(host(capabilities: both), defaults: chosen)
        XCTAssertEqual(chosenModel.newPlainChatProvider, .codex, "A saved choice wins")
    }

    /// Settings' sign-ins: each offered provider's sign-in, then the ones Chat cannot use with what to do.
    func testSettingsListTheSignInsChatRunsOn() throws {
        let capability = try ProtocolDecoder.decode(WorkspaceChatsCapability.self, from: Data(#"""
            {"version":1,"providers":[{"id":"claude","name":"Claude Code","tools":[],"features":[],
              "auth":{"kind":"subscription","label":"Claude subscription"}}],
             "unavailableProviders":[{"id":"codex","name":"Codex","tools":[],"features":[],
              "auth":{"kind":"signedOut","label":"Not signed in","reason":"subscription_required",
                      "message":"Codex isn’t signed in. Sign in to Codex with your ChatGPT subscription (codex login)."}}]}
            """#.utf8))
        let signIns = PlainChatSignIns(capability)
        XCTAssertEqual(signIns.rows.map(\.id), ["claude", "codex"])
        XCTAssertEqual(signIns.rows.map(\.value), ["Claude subscription", "Not signed in"])
        XCTAssertEqual(signIns.rows.map(\.available), [true, false])
        XCTAssertNil(signIns.rows[0].detail)
        XCTAssertEqual(signIns.rows[1].detail, "Codex isn’t signed in. Sign in to Codex with your ChatGPT subscription (codex login).")
        XCTAssertTrue(PlainChatSignIns(nil as WorkspaceChatsCapability?).rows.isEmpty)
        XCTAssertTrue(PlainChatSignIns(WorkspaceChatsCapability(providers: [PlainChatProvider(id: "claude", name: "Claude Code")])).rows.isEmpty,
                      "A provider without a sign-in (an older host's) is left out")
    }

    /// A Codex in a version Chat does not support (2026-10-16, `version_unsupported`): Settings shows the host's label
    /// and words, never a sign-in, and nothing offers it.
    func testSettingsSayWhyAVersionIsNotSupported() throws {
        let capability = try ProtocolDecoder.decode(WorkspaceChatsCapability.self, from: Data(#"""
            {"version":1,"providers":[],
             "unavailableProviders":[{"id":"codex","name":"Codex","tools":[],"features":[],
              "auth":{"kind":"unknown","label":"Version not supported","reason":"version_unsupported",
                      "message":"AgentLand’s Chat doesn’t support Codex 1.0.0 yet. Use Codex in Terminal."}}]}
            """#.utf8))
        XCTAssertEqual(capability.unavailableProviders.first?.auth?.reason, "version_unsupported")
        XCTAssertFalse(capability.offers(.codex))
        let signIns = PlainChatSignIns(capability)
        XCTAssertEqual(signIns.rows.map(\.value), ["Version not supported"])
        XCTAssertEqual(signIns.rows.map(\.available), [false])
        XCTAssertEqual(signIns.rows.first?.detail, "AgentLand’s Chat doesn’t support Codex 1.0.0 yet. Use Codex in Terminal.")
    }

    func testNewSessionsWaitForASelectedWorkspace() async throws {
        let host = host()
        let model = try await attached(host, defaults: defaults())
        model.newPlainChat()
        model.create(.terminal)
        XCTAssertFalse(model.creating)
        XCTAssertTrue(host.requests("/v1/sessions").isEmpty)
        XCTAssertTrue(host.requests("/v1/terminals").isEmpty)
        model.selectProject("a")
        model.newPlainChat()
        await waitUntil { !model.creating }
        XCTAssertEqual(model.currentTab?.projectID, "a", "Chat runs in the selected workspace")
        XCTAssertEqual(model.selectedProjectID, "a")
    }

    func testCreatedSessionsWaitForTheirSurfaceAfterTheCreationRequestFinishes() async throws {
        for kind in [WorkspaceTabKind.chat, .terminal] {
            let host = host()
            host.on("/v1/terminals") { _ in
                (201, #"{"id":"t_new","title":"Shell","projectId":"a","status":"running"}"#)
            }
            let model = try await attached(host, defaults: defaults())
            XCTAssertTrue(model.completePresentation(try XCTUnwrap(model.presentationTicket)))
            model.selectProject("a")
            if kind == .chat { model.newPlainChat() } else { model.create(.terminal) }
            XCTAssertTrue(model.sessionOpening)
            await waitUntil { !model.creating }
            let tab = try XCTUnwrap(model.currentTab)
            XCTAssertEqual(tab.kind, kind)
            XCTAssertFalse(model.presentationPending, "Session creation must not restart the app's opening cover")
            XCTAssertTrue(model.sessionOpening, "Finishing the request must not expose Home")
            let ticket = try XCTUnwrap(model.presentationRequest(for: tab.id),
                                      "Keep the session covered between creation and its first resolved content")
            model.reportPresentationReady(.init(hostID: hostID, tabID: tab.id))
            XCTAssertEqual(model.presentationRequest(for: tab.id), ticket, "Ignore stale readiness callbacks")
            model.reportPresentationReady(ticket)
            XCTAssertNil(model.presentationRequest(for: tab.id))
            XCTAssertFalse(model.sessionOpening)
        }
    }

    func testSessionOpeningDoesNotStayCoveredAfterLeavingOrLosingTheHost() async throws {
        for departure in ["tab", "detach", "offline", "background"] {
            let model = try await attached(host(), defaults: defaults())
            XCTAssertTrue(model.completePresentation(try XCTUnwrap(model.presentationTicket)))
            model.selectProject("a")
            model.newPlainChat()
            await waitUntil { !model.creating }
            let tab = try XCTUnwrap(model.currentTab)
            let ticket = try XCTUnwrap(model.presentationRequest(for: tab.id))
            switch departure {
            case "tab": model.selectedTabID = nil
            case "detach": model.detach()
            case "offline":
                model.reachable = false
                model.resolvePresentationOffline()
            default:
                model.beginPresentation()
                let appTicket = try XCTUnwrap(model.presentationRequest(for: tab.id))
                model.reportPresentationReady(appTicket)
                XCTAssertTrue(model.completePresentation(appTicket))
            }
            XCTAssertFalse(model.sessionOpening, departure)
            model.reportPresentationReady(ticket)
            XCTAssertFalse(model.sessionOpening, "A late report cannot revive the cover")
        }
    }

    func testFailedCreationUncoversItsErrorWithoutWaitingForASurface() async throws {
        let host = host()
        host.on("/v1/sessions") { _ in (503, #"{"error":{"code":"unavailable","message":"Unavailable"}}"#) }
        let model = try await attached(host, defaults: defaults())
        XCTAssertTrue(model.completePresentation(try XCTUnwrap(model.presentationTicket)))
        model.selectProject("a")
        model.newPlainChat()
        await waitUntil { !model.creating }
        XCTAssertNotNil(model.creationIssue)
        XCTAssertFalse(model.sessionOpening)
        XCTAssertNil(model.currentTab)
    }

    func testNewTerminalStaysCoveredUntilItsInitialOutputAndLayoutAreReady() async throws {
        let host = host()
        host.on("/v1/terminals") { _ in
            (201, #"{"id":"t_new","title":"Shell","projectId":"a","status":"running"}"#)
        }
        let output = Data("ready\r\n".utf8).base64EncodedString()
        // The terminal keeps running: the read after its first output waits, as the host's long-poll does. (An
        // exited terminal shows its ended state instead, which needs no drawn output.)
        host.on("/v1/terminal/output") { request in
            if ScriptedHost.query(request)["cursor"] == "0" { return (200, #"{"data":"\#(output)","cursor":7,"reset":false,"status":"running"}"#) }
            try await Task.sleep(for: .seconds(10))
            return (200, #"{"data":"","cursor":7,"reset":false,"status":"running"}"#)
        }
        let model = try await attached(host, defaults: defaults())
        XCTAssertTrue(model.completePresentation(try XCTUnwrap(model.presentationTicket)))
        model.selectProject("a")
        model.create(.terminal)
        await waitUntil { !model.creating }
        let session = model.terminalSession(for: try XCTUnwrap(model.currentTab))
        let reading = Task { await session.poll(view: UUID(), viewActive: true) }
        defer { reading.cancel() }
        await waitUntil { !session.packets.isEmpty }
        XCTAssertTrue(model.sessionOpening, "Receiving output is not yet drawing it")
        session.rendererDidLayout(session.rendererID)
        XCTAssertTrue(model.sessionOpening, "Layout alone cannot expose an empty terminal")
        let packet = try XCTUnwrap(session.packets.first)
        session.fed(packet.id)
        XCTAssertFalse(model.sessionOpening, "The initial frame now has its content")
    }

    private func plainTab(_ id: String = "ses_plain", title: String = "Tides") -> WorkspaceTab {
        WorkspaceTab(kind: .chat, projectID: PlainChatsCapability.chatsProjectID, resourceID: id, title: title)
    }

    // MARK: Tabs

    /// The tab list keeps the plain chats whatever workspace is open, and showing one keeps the workspace in use.
    func testPlainChatsStayListedAndShowingOneKeepsTheWorkspace() throws {
        let model = WorkspaceModel(defaults: try defaults())
        model.attach(hostID: hostID, identity: identity, client: nil)
        model.projects = [Project(id: "a", name: "App"), Project(id: "b", name: "Blog")]
        model.openWorkspace("a")
        let files = try XCTUnwrap(model.currentTab)
        let plain = plainTab()
        model.open(plain)
        XCTAssertTrue(model.isPlainChat(plain))
        XCTAssertFalse(model.isPlainChat(files))
        XCTAssertEqual(model.selectedTabID, plain.id)
        XCTAssertEqual(model.selectedProjectID, "a", "Showing a plain chat leaves the workspace in use as it was")
        XCTAssertEqual(model.workspaceTabs.map(\.id), [files.id, plain.id])

        model.openWorkspace("b")
        let blogFiles = try XCTUnwrap(model.currentTab)
        XCTAssertEqual(blogFiles.projectID, "b")
        XCTAssertEqual(model.workspaceTabs.map(\.id), [plain.id, blogFiles.id], "The plain chat is listed in every workspace")
        model.selectedTabID = plain.id
        XCTAssertEqual(model.selectedProjectID, "b")
        XCTAssertEqual(model.tabOrder, [nil, plain.id, blogFiles.id], "⌘1–9 and ⌃⇥ step through it")
        model.selectTab(number: 3)
        XCTAssertEqual(model.selectedTabID, blogFiles.id)

        // Reordering puts the listed tabs back into their slots; the other workspace's tab keeps its own.
        model.moveWorkspaceTabs(fromOffsets: [1], toOffset: 0)
        XCTAssertEqual(model.workspaceTabs.map(\.id), [blogFiles.id, plain.id])
        XCTAssertEqual(model.tabs.first?.id, files.id)

        // Close Other Tabs covers the plain chats too.
        model.closeOtherTabs(keeping: blogFiles.id)
        XCTAssertEqual(model.workspaceTabs.map(\.id), [blogFiles.id])
        XCTAssertTrue(model.tabs.contains { $0.id == files.id }, "Another workspace's tabs stay")

        // Closing a workspace leaves the plain chats open.
        let again = plainTab("ses_again")
        model.open(again)
        model.closeWorkspace("b")
        XCTAssertNil(model.selectedProjectID)
        XCTAssertEqual(model.workspaceTabs.map(\.id), [again.id], "With no workspace open the plain chats are still listed")
        XCTAssertEqual(model.selectedTabID, again.id)
    }

    func testAPlainChatInFrontIsRestoredWithTheWorkspaceItWasShownOver() throws {
        let defaults = try defaults()
        let model = WorkspaceModel(defaults: defaults)
        model.attach(hostID: hostID, identity: identity, client: nil)
        model.projects = [Project(id: "a", name: "App")]
        model.openWorkspace("a")
        let plain = plainTab()
        model.open(plain)

        let restored = WorkspaceModel(defaults: defaults)
        restored.attach(hostID: hostID, identity: identity, client: nil)
        XCTAssertEqual(restored.selectedTabID, plain.id)
        XCTAssertEqual(restored.selectedProjectID, "a", "Never the Chats space")
        XCTAssertEqual(restored.workspaceTabs.map(\.kind), [.files, .chat])
    }

    /// A closed plain chat gives way to the last tab listed; a workspace's tab, as before, to its workspace's last.
    func testClosingAPlainChatShowsTheLastTabListed() throws {
        let model = WorkspaceModel(defaults: try defaults())
        model.projects = [Project(id: "a", name: "App")]
        model.openWorkspace("a")
        let files = try XCTUnwrap(model.currentTab)
        let first = plainTab("ses_1")
        let terminal = WorkspaceTab(kind: .terminal, projectID: "a", resourceID: "pty", title: "Terminal")
        let second = plainTab("ses_2")
        for tab in [first, terminal, second] { model.open(tab) }
        model.close(second.id)
        XCTAssertEqual(model.selectedTabID, terminal.id)
        model.selectedTabID = first.id
        model.close(first.id)
        XCTAssertEqual(model.selectedTabID, terminal.id)
        model.close(terminal.id)
        XCTAssertEqual(model.selectedTabID, files.id)
    }

    // MARK: New plain chats

    func testANewChatIsAClaudeCodeOrCodexChatInTheSelectedWorkspace() async throws {
        let host = host()
        let model = try await attached(host, defaults: try defaults())
        XCTAssertTrue(model.offersPlainChats)
        XCTAssertEqual(model.plainChatProviders.map(\.id), ["claude", "codex", "opencode"],
                       "The fixture's Chats space lists OpenCode, as a host run with --opencode-chat does")
        XCTAssertNil(model.selectedProjectID)
        model.selectProject("a")
        model.newPlainChat()
        await waitUntil("the new chat") { model.currentTab?.resourceID == "claude:new" }
        let body = try XCTUnwrap(host.bodies("/v1/sessions").last)
        XCTAssertEqual(body["projectId"] as? String, "a", "In the selected workspace's folder, never the Chats space")
        XCTAssertEqual(body["provider"] as? String, "claude")
        XCTAssertEqual(body["title"] as? String, "Claude Code chat")
        XCTAssertNil(body["mode"], "The host starts it in Ask")
        let tab = try XCTUnwrap(model.currentTab)
        XCTAssertEqual(tab.projectID, "a")
        XCTAssertFalse(model.isPlainChat(tab))
        XCTAssertTrue(model.isWorkspaceChat(tab))
        XCTAssertEqual(model.workspaceTabs.map(\.id), [tab.id], "Listed with its workspace")
        XCTAssertEqual(model.workspaceID(for: tab), "a")
        XCTAssertNil(model.chatWorkspaceIDs[tab.resourceID], "A workspace chat needs no saved association")
        XCTAssertEqual(model.selectedProjectID, "a")
        XCTAssertNil(model.creationIssue)
        XCTAssertNotNil(model.chatStore(for: tab).callbacks.openTerminal, "Open in Terminal opens in the chat's workspace")

        model.selectedTabID = nil
        model.newPlainChat(provider: .codex)
        await waitUntil("the Codex chat") { model.currentTab?.resourceID == "codex:new" }
        XCTAssertEqual(host.bodies("/v1/sessions").last?["provider"] as? String, "codex")
        XCTAssertEqual(model.plainChatDefaultProvider, .codex, "The agent used is saved as the choice")
        model.selectProject("b")
        XCTAssertTrue(model.workspaceTabs.isEmpty, "Another workspace lists its own chats")
    }

    /// Claude Code and Codex never start in the Chats space, and a host without `workspaceChats` offers no Chat: no
    /// Chats-space fallback. OpenCode starts there only while the host lists it (`--opencode-chat`).
    func testChatNeedsWorkspaceChatsAndNeverUsesTheChatsSpace() async throws {
        let newHost = host(capabilities: #"{"interactions":true,"terminal":true,"plainChats":{"projectId":"chats","providers":[]},"workspaceChats":{"version":1,"providers":[{"id":"claude","name":"Claude Code","tools":[],"features":[]}]}}"#)
        let current = try await attached(newHost, defaults: try defaults("current"))
        XCTAssertEqual(current.plainChatProviders.map(\.id), ["claude"], "Without --opencode-chat, Claude Code and Codex alone")
        current.selectProject("a")
        current.newPlainChat(provider: .opencode)
        XCTAssertFalse(current.creating)

        let offering = host()
        let model = try await attached(offering, defaults: try defaults())
        model.selectProject("a")
        model.newPlainChat(provider: .opencode)
        await waitUntil("the OpenCode chat") { model.currentTab?.resourceID == "ses_new" }
        XCTAssertEqual(offering.bodies("/v1/sessions").last?["projectId"] as? String, "chats", "OpenCode's chats stay in the Chats space")
        let opencode = try XCTUnwrap(model.currentTab)
        XCTAssertTrue(model.isPlainChat(opencode))
        XCTAssertEqual(model.workspaceID(for: opencode), "a", "Associated with the workspace in use, as before")
        model.selectedTabID = nil
        let posts = offering.requests("/v1/sessions").filter { $0.httpMethod == "POST" }.count
        model.create(.chat, projectID: "chats", provider: .claude)
        model.create(.chat, projectID: "a", provider: .opencode)
        model.create(.terminal, projectID: "chats")
        XCTAssertFalse(model.creating)
        XCTAssertEqual(offering.requests("/v1/sessions").filter { $0.httpMethod == "POST" }.count, posts)
        XCTAssertTrue(offering.requests("/v1/terminals").isEmpty)

        for (name, capabilities) in [("older", Self.olderCapabilities), ("chats-space", Self.chatsSpaceProvidersCapabilities)] {
            let older = host(capabilities: capabilities)
            let olderModel = try await attached(older, defaults: try defaults(name))
            XCTAssertFalse(olderModel.offersPlainChats, name)
            olderModel.selectProject("a")
            olderModel.newPlainChat()
            olderModel.newPlainChat(provider: .claude)
            XCTAssertFalse(olderModel.creating, name)
            XCTAssertTrue(older.requests("/v1/sessions").filter { $0.httpMethod == "POST" }.isEmpty, "\(name): a host without workspaceChats is asked for none")
        }
    }

    /// A workspace chat whose workspace was changed while it was made is dropped, like a terminal: nothing opens over
    /// the other workspace.
    func testAWorkspaceChatMadeWhileTheWorkspaceChangesDoesNotOpenElsewhere() async throws {
        let host = host()
        let gate = Gate()
        host.on("/v1/sessions") { request in
            await gate.wait()
            return (201, #"{"id":"claude:new","title":"Claude Code chat","projectId":"a","provider":"claude"}"#)
        }
        let model = try await attached(host, defaults: try defaults())
        model.openWorkspace("a")
        model.openHomeTab()
        let home = try XCTUnwrap(model.currentTab)
        model.newPlainChat()
        await waitUntil("the request") { !host.requests("/v1/sessions").isEmpty }
        model.selectProject("b")
        await gate.open()
        await waitUntil("the creation to end") { !model.creating }
        XCTAssertNil(model.chatTab(sessionID: "claude:new"))
        XCTAssertTrue(model.tabs.contains { $0.id == home.id }, "The other workspace's Home tab stays")
        XCTAssertEqual(model.selectedProjectID, "b")
    }

    func testAPlainChatsDraftOpensInANewPlainChat() async throws {
        let host = host()
        let model = try await attached(host, defaults: try defaults())
        model.openDraft(ContinueDraft(projectID: "chats", sourceChatID: "ses_old", provider: "opencode", model: "anthropic/sonnet",
                                      mode: nil, effort: nil, title: "Tides (continued)", text: "Continue from where it ends.",
                                      attachment: nil))
        await waitUntil("the draft's chat") { model.currentTab?.resourceID == "ses_new" }
        let body = try XCTUnwrap(host.bodies("/v1/sessions").last)
        XCTAssertEqual(body["projectId"] as? String, "chats")
        let tab = try XCTUnwrap(model.currentTab)
        XCTAssertEqual(tab.chatModelID, "anthropic/sonnet")
        XCTAssertEqual(model.chatStore(for: tab).draft, "Continue from where it ends.", "In the composer, never sent")
        XCTAssertTrue(host.requests("/v1/messages").isEmpty)
        model.chatStore(for: tab).shutdown()

        // Another agent's draft is no plain chat's.
        model.openDraft(ContinueDraft(projectID: "chats", sourceChatID: "ses_old", provider: "claude", model: nil, mode: nil, effort: nil,
                                      title: "x", text: "y", attachment: nil))
        XCTAssertFalse(model.creating)
        // A Claude Code draft opens in its workspace.
        model.selectedTabID = nil
        model.openDraft(ContinueDraft(projectID: "a", sourceChatID: "claude:old", provider: "claude", model: nil, mode: nil, effort: nil,
                                      title: "Fix login (continued)", text: "Carry on.", attachment: nil))
        await waitUntil("the workspace draft's chat") { model.currentTab?.resourceID == "claude:new" }
        XCTAssertEqual(host.bodies("/v1/sessions").last?["projectId"] as? String, "a")
        XCTAssertEqual(model.chatStore(for: try XCTUnwrap(model.currentTab)).draft, "Carry on.")
    }

    // MARK: The library

    /// A copy with two plain chats, a Claude Code chat of each workspace and an OpenCode one of the first, and a message
    /// in each space.
    private func archive() async throws -> WorkspaceArchive {
        let store = try ArchiveStore.inMemory(hostKey: hostID)
        func chat(_ id: String, _ project: String, _ title: String, _ time: String) -> ArchiveChangeItem {
            .chat(ArchiveChatRecord(id: id, projectID: project, provider: ChatSessionStore.provider(forSession: id).id, title: title,
                                    createdAt: time, updatedAt: time))
        }
        func message(_ id: String, chat: String, _ text: String) -> ArchiveChangeItem {
            .message(ArchiveMessageRecord(message: ConversationMessage(id: id, chatID: chat, turnID: id, role: .user, ord: 1,
                                                                        createdAt: "2026-09-27T10:00:00.000Z",
                                                                        parts: [ConversationPart(id: id + "p", kind: .text, text: text)])))
        }
        let items = [chat("ses_plain_1", "chats", "Tides in Lisbon", "2026-09-27T09:00:00.000Z"),
                     chat("ses_plain_2", "chats", "New chat", "2026-09-27T11:00:00.000Z"),
                     message("m1", chat: "ses_plain_2", "What should I cook tonight?"),
                     message("m2", chat: "ses_plain_1", "Tides for the harbour weekend"),
                     chat("claude:app", "a", "Fix the login loop", "2026-09-27T10:00:00.000Z"),
                     message("m3", chat: "claude:app", "The harbour widget loops on login"),
                     chat("ses_app", "a", "An OpenCode chat", "2026-09-27T10:30:00.000Z"),
                     message("m4", chat: "ses_app", "The harbour OpenCode chat"),
                     chat("codex:blog", "b", "Draft the post", "2026-09-27T12:00:00.000Z")]
        try await store.apply(ArchiveChangesPage(epoch: "e1", changes: items.enumerated().map { ArchiveChange(seq: Int64($0.offset + 1), item: $0.element) },
                                                 cursor: "e1.\(items.count)"))
        return WorkspaceArchive(store: store, terminalLogs: nil, attachments: nil, client: nil)
    }

    func testTheLibraryListsPlainChatsFirstWithOrWithoutAWorkspace() async throws {
        let model = try await attached(host(), defaults: try defaults())
        let archive = try await archive()
        model.openArchive({ archive })
        await waitUntil("the copy to attach") { model.archive === archive }
        defer { archive.close() }

        let noWorkspace = Task { await model.sidebar.followArchive(projectID: nil) }
        await waitUntil("the plain chats") { model.sidebar.plainChats.count == 2 }
        noWorkspace.cancel()
        XCTAssertEqual(model.sidebar.plainChats.map(\.id), ["ses_plain_2", "ses_plain_1"], "Most recent first")
        XCTAssertEqual(model.sidebar.archivedChats, [], "No workspace, no agent chats")
        XCTAssertEqual(model.sidebar.title(for: model.sidebar.plainChats[0]), "What should I cook tonight?", "A default title goes by its prompt")
        XCTAssertEqual(model.sidebar.plainLibraryGroups.flatMap(\.chats).map(\.id), ["ses_plain_2", "ses_plain_1"])

        model.selectProject("a")
        let inApp = Task { await model.sidebar.followArchive(projectID: "a") }
        await waitUntil("the workspace's chats") { model.sidebar.archivedChats.count == 1 }
        inApp.cancel()
        XCTAssertEqual(model.sidebar.allChats.map(\.id), ["ses_plain_2", "ses_plain_1", "claude:app"], "Its Claude Code chat joins the library")
        XCTAssertEqual(model.sidebar.libraryChats.map(\.id), ["ses_plain_2", "claude:app", "ses_plain_1"], "Most recent first, together")
        XCTAssertEqual(model.sidebar.chatLibraryGroups.flatMap(\.chats).map(\.id), ["ses_plain_2", "claude:app", "ses_plain_1"])
        XCTAssertTrue(model.sidebar.listsChat("claude:app"))
        XCTAssertEqual(model.sidebar.chat("ses_plain_1")?.projectID, "chats")
        XCTAssertFalse(model.sidebar.hasMoreLibraryChats)
        XCTAssertEqual(model.sidebar.deleteMessage(for: try XCTUnwrap(model.sidebar.chat("ses_plain_1"))),
                       "It’s deleted from the archive on your Mac and from this device.")
        XCTAssertNil(model.sidebar.chat("ses_app"), "Other agents' workspace chats stay out of the library")
        XCTAssertNil(model.sidebar.chat("codex:blog"), "Another workspace's chats stay out")
    }

    /// Which chats are live comes from the Chats space's sessions for plain chats, the workspace's for the others.
    func testIsLiveReadsTheChatsSpacesSessions() async throws {
        let host = host()
        host.on("/v1/sessions") { request in
            let project = ScriptedHost.query(request)["projectId"]
            if project == "chats" { return (200, #"{"sessions":[{"id":"ses_plain_1","title":"Tides in Lisbon","projectId":"chats"}]}"#) }
            return (200, #"{"sessions":[{"id":"claude:app","title":"Fix the login loop","projectId":"a","provider":"claude"},{"id":"ses_app","title":"OpenCode","projectId":"a"}]}"#)
        }
        let model = try await attached(host, defaults: try defaults())
        XCTAssertTrue(model.sidebar.isLive("ses_plain_1"), "Unknown until read: live")
        await model.sidebar.refreshSessions()
        XCTAssertEqual(model.sidebar.plainLiveSessions?.map(\.id), ["ses_plain_1"], "Read with no workspace open")
        XCTAssertNil(model.sidebar.liveSessions)
        XCTAssertTrue(model.sidebar.isLive("ses_plain_1"))
        XCTAssertFalse(model.sidebar.isLive("ses_plain_gone", projectID: "chats"), "Gone from the Chats space")
        XCTAssertTrue(model.sidebar.isLive("claude:app", projectID: "a"), "Another workspace's chat is unknown: live")

        model.selectProject("a")
        await model.sidebar.refreshSessions()
        XCTAssertEqual(model.sidebar.liveSessions?.map(\.id), ["claude:app"], "The workspace's Claude Code and Codex chats only")
        XCTAssertTrue(model.sidebar.isLive("claude:app", projectID: "a"))
        XCTAssertFalse(model.sidebar.isLive("claude:gone", projectID: "a"))
        XCTAssertEqual(model.sidebar.liveLibrarySessions?.map(\.id), ["claude:app", "ses_plain_1"])
        XCTAssertEqual(host.requests("/v1/sessions").compactMap { ScriptedHost.query($0)["projectId"] }.filter { $0 == "chats" }.count, 2)

        // A host that stops offering plain chats is not asked; its plain chats count as live again.
        let older = self.host(capabilities: Self.olderCapabilities)
        let olderModel = try await attached(older, defaults: try defaults("older"))
        await olderModel.sidebar.refreshSessions()
        XCTAssertNil(olderModel.sidebar.plainLiveSessions)
        XCTAssertTrue(older.requests("/v1/sessions").allSatisfy { ScriptedHost.query($0)["projectId"] != "chats" })
        XCTAssertTrue(olderModel.sidebar.isLive("ses_plain_1", projectID: "chats"))
    }

    // MARK: Search

    func testSearchFindsPlainChatsBesideTheWorkspaces() async throws {
        let model = try await attached(host(), defaults: try defaults())
        let archive = try await archive()
        model.openArchive({ archive })
        await waitUntil("the copy to attach") { model.archive === archive }
        defer { archive.close() }
        let search = WorkspaceSearchModel()
        search.workspace = model

        model.selectProject("a")
        search.query = "harbour"
        await search.search()
        XCTAssertEqual(Set(search.messageHits.map(\.chatID)), ["ses_plain_1", "claude:app"],
                       "The Chats space's and the workspace's Claude Code chats; its OpenCode chat stays out")
        XCTAssertEqual(search.messageHits.first?.projectID, "chats", "The two lists take turns, the Chats space's first")

        search.query = "cook"
        await search.search()
        XCTAssertEqual(search.messageHits.map(\.chatID), ["ses_plain_2"])

        model.selectProject("b")
        search.query = "login"
        await search.search()
        XCTAssertEqual(search.messageHits.map(\.chatID), [], "Another workspace's chats stay out")
        model.selectProject("a")
        await search.search()
        XCTAssertEqual(search.messageHits.map(\.chatID), ["claude:app"])
    }

    func testTwoRankedListsAlternate() {
        XCTAssertEqual(WorkspaceSearchModel.alternate([1, 2, 3], [10, 20], limit: 10), [1, 10, 2, 20, 3])
        XCTAssertEqual(WorkspaceSearchModel.alternate([1, 2, 3], [10, 20], limit: 3), [1, 10, 2])
        XCTAssertEqual(WorkspaceSearchModel.alternate([], [10, 20], limit: 5), [10, 20])
        XCTAssertEqual(WorkspaceSearchModel.alternate([1], [], limit: 5), [1])
    }

    // MARK: The empty plain chat

    /// The tent sits at the opening cover's anchor with the question under it; with the keyboard up it shrinks to
    /// fit, and gives way to the question alone when it would be too small.
    func testLandingTitleAndQuipFitAboveTheUnchangedComposer() throws {
        let artwork = AgentLandArtworkLayout(windowFrame: CGRect(x: 0, y: 0, width: 402, height: 874), referenceDate: .distantPast)
        let title = CGSize(width: 378, height: 78)
        for height in [CGFloat(650), 380, 180] {
            let layout = PlainChatLandingLayout(frame: CGRect(x: 0, y: 100, width: 402, height: height),
                                                artwork: artwork, prompt: CGSize(width: 354, height: 56), titleSize: title)
            XCTAssertLessThanOrEqual(layout.promptCenter.y + 28, height - PlainChatLandingLayout.margin)
            if let heading = layout.titleFrame, let scale = layout.tentScale {
                XCTAssertLessThan(heading.maxY, layout.tentCenter.y - PlainChatLandingLayout.aboveCentre * scale)
            }
            if height == 180 { XCTAssertNil(layout.titleFrame, "The quip takes priority above a tall keyboard") }
        }
    }

    func testTheLandingKeepsTheAnchorAndGivesWayAboveTheKeyboard() {
        let window = CGRect(x: 0, y: 0, width: 402, height: 874)
        let artwork = AgentLandArtworkLayout(windowFrame: window, referenceDate: .distantPast)
        let prompt = CGSize(width: 240, height: 34)
        // The landing's frame: under the navigation bar, over the composer.
        let open = PlainChatLandingLayout(frame: CGRect(x: 0, y: 100, width: 402, height: 650), artwork: artwork, prompt: prompt)
        XCTAssertEqual(open.tentScale, artwork.scale)
        XCTAssertEqual(open.tentCenter, artwork.center(in: CGRect(x: 0, y: 100, width: 402, height: 650)),
                       "At the opening cover's anchor, so the tent does not move when the cover lifts")
        XCTAssertGreaterThan(open.promptCenter.y, open.tentCenter.y)

        let keyboard = PlainChatLandingLayout(frame: CGRect(x: 0, y: 100, width: 402, height: 300), artwork: artwork, prompt: prompt)
        let scale = try? XCTUnwrap(keyboard.tentScale)
        XCTAssertLessThan(scale ?? 1, artwork.scale, "Smaller above the keyboard")
        XCTAssertLessThanOrEqual(keyboard.promptCenter.y + prompt.height / 2, 300 - PlainChatLandingLayout.margin + 0.5,
                                 "The question stays above the composer")
        XCTAssertGreaterThanOrEqual(keyboard.tentCenter.y - PlainChatLandingLayout.aboveCentre * (scale ?? 0), PlainChatLandingLayout.margin - 0.5)

        let tiny = PlainChatLandingLayout(frame: CGRect(x: 0, y: 100, width: 402, height: 90), artwork: artwork, prompt: prompt)
        XCTAssertNil(tiny.tentScale, "Too small for the tent: the question alone")
        XCTAssertEqual(tiny.promptCenter.y, 45)
    }
}
