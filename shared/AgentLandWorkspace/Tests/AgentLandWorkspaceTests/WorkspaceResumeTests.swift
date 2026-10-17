import XCTest
import AgentLandCore
import AgentLandArchive
import AgentLandChat
@testable import AgentLandWorkspace

@MainActor final class WorkspaceResumeTests: XCTestCase {
    private var suites: [String] = []
    override func tearDown() async throws {
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    }
    private func setup(defaults: UserDefaults? = nil) async throws -> (WorkspaceModel, ScriptedHost, UserDefaults) {
        let suite = "resume-\(UUID())"
        if defaults == nil { suites.append(suite) }
        let defaults = try XCTUnwrap(defaults ?? UserDefaults(suiteName: suite))
        let host = ScriptedHost()
        host.on("/v1/capabilities") { _ in (200, #"{"interactions":true,"terminal":true,"plainChats":{"projectId":"chats","tools":[]},"workspaceChats":{"version":1,"providers":[{"id":"claude","name":"Claude Code","tools":[],"features":[]},{"id":"codex","name":"Codex","tools":[],"features":[]}]}}"#) }
        host.on("/v1/projects") { _ in (200, #"{"projects":[{"id":"a","name":"App"},{"id":"b","name":"Blog"}]}"#) }
        host.on("/v1/sessions") { request in
            let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
            let project = body?["projectId"] as? String ?? ""
            return (201, #"{"id":"claude:new","title":"Claude Code chat","projectId":"\#(project)","provider":"claude"}"#)
        }
        host.on("/v1/terminals") { request in
            let id = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "projectId" }?.value ?? ""
            return (200, #"{"terminals":[{"id":"term_\#(id)","title":"Terminal","projectId":"\#(id)","status":"running"}]}"#)
        }
        let model = WorkspaceModel(defaults: defaults)
        let identity = ConnectionIdentity(host: "https://mac.example", deviceID: "phone")
        model.attach(hostID: identity.storageKey, identity: identity,
                     client: APIClient(address: try ServerAddress(validating: identity.host), token: "test", transport: host))
        await model.refreshProjects()
        return (model, host, defaults)
    }

    func testResumeMenuShowsSavedWorkspaceAndSessionNameWithoutGuessing() async throws {
        let (model, host, _) = try await setup()
        host.on("/v1/sessions") { _ in (200, #"{"sessions":[{"id":"known","title":"Dinner plans","projectId":"chats"},{"id":"legacy","title":"Old conversation","projectId":"chats"}]}"#) }
        model.rememberChatWorkspace("known", workspaceID: "a")
        model.selectProject("b")
        await model.sidebar.refreshPlainSessions()
        await model.sidebar.refreshResumeTerminals()
        let choices = HomePhoneActions.recentChoices(model: model)
        let chat = try XCTUnwrap(choices.first { $0.id == "homeResumeChat-known" })
        XCTAssertEqual(chat.title, "Dinner plans")
        XCTAssertEqual(chat.detail, "App", "Use the saved workspace, not the current Blog workspace")
        XCTAssertEqual(choices.first { $0.id == "homeResumeChat-legacy" }?.detail, "Workspace not assigned")
        XCTAssertEqual(choices.first { $0.id == "homeResumeTerminal-term_a" }?.title, "Terminal")
        XCTAssertEqual(choices.first { $0.id == "homeResumeTerminal-term_a" }?.detail, "App")
        XCTAssertEqual(choices.first { $0.id == "homeResumeTerminal-term_b" }?.detail, "Blog")
        model.projects.removeAll { $0.id == "a" }
        XCTAssertEqual(HomePhoneActions.recentChoices(model: model).first { $0.id == "homeResumeChat-known" }?.detail,
                       "Workspace unavailable", "Keep the association when its workspace disappears")
    }

    func testNewChatKeepsOwnerAfterWorkspaceCloseAndResume() async throws {
        let (model, host, _) = try await setup()
        model.selectProject("a")
        model.newPlainChat()
        await waitUntil { !model.creating }
        let chat = try XCTUnwrap(model.currentTab)
        XCTAssertEqual(model.workspaceID(for: chat), "a")
        XCTAssertEqual(model.closeWorkspace("a").map(\.id), [chat.id])
        XCTAssertNil(model.currentProject)
        model.requestResume(.tab(chat))
        XCTAssertEqual(model.currentProject?.id, "a")
        XCTAssertEqual(model.currentTab?.resourceID, "claude:new")
        XCTAssertFalse(model.closedWorkspaceIDs.contains("a"))
        XCTAssertEqual(host.requests("/v1/sessions").count, 1, "Resume must not create another conversation")
    }

    func testAssociationSurvivesClosingTabAndRelaunch() async throws {
        let (model, _, defaults) = try await setup()
        let chat = WorkspaceTab(kind: .chat, projectID: "chats", resourceID: "saved", title: "Dinner")
        model.rememberChatWorkspace(chat.resourceID, workspaceID: "a")
        model.open(chat)
        model.close(chat.id)
        model.selectProject("b")
        let (restored, host, _) = try await setup(defaults: defaults)
        restored.requestResume(.tab(chat))
        XCTAssertEqual(restored.currentProject?.id, "a")
        XCTAssertEqual(restored.currentTab?.resourceID, "saved")
        XCTAssertTrue(host.requests("/v1/sessions").isEmpty)
    }

    func testLegacyChatAsksOnceWithoutGuessingCurrentWorkspace() async throws {
        let (model, _, _) = try await setup()
        model.selectProject("b")
        let chat = WorkspaceTab(kind: .chat, projectID: "chats", resourceID: "legacy", title: "Old chat")
        model.requestResume(.tab(chat))
        XCTAssertEqual(model.pendingSessionResume, .tab(chat))
        XCTAssertNil(model.currentTab)
        XCTAssertEqual(model.currentProject?.id, "b")
        model.completeSessionResume(in: "a")
        XCTAssertNil(model.pendingSessionResume)
        XCTAssertEqual(model.currentProject?.id, "a")
        XCTAssertEqual(model.currentTab?.resourceID, "legacy")
        model.closeWorkspace("a")
        model.requestResume(.tab(chat))
        XCTAssertNil(model.pendingSessionResume)
        XCTAssertEqual(model.currentProject?.id, "a")
    }

    func testMissingWorkspaceNeverRedirectsAChatSilently() async throws {
        let (model, _, _) = try await setup()
        let chat = WorkspaceTab(kind: .chat, projectID: "chats", resourceID: "saved", title: "Dinner")
        model.rememberChatWorkspace(chat.resourceID, workspaceID: "a")
        model.projects.removeAll { $0.id == "a" }
        model.selectProject("b")
        model.requestResume(.tab(chat))
        XCTAssertNotNil(model.pendingSessionResume)
        XCTAssertNil(model.currentTab)
        XCTAssertEqual(model.currentProject?.id, "b")
    }

    func testTerminalAndSavedOutputRestoreTheirOwnWorkspace() async throws {
        let (model, host, _) = try await setup()
        model.selectProject("b")
        let terminal = WorkspaceTab(kind: .terminal, projectID: "a", resourceID: "pty", title: "Terminal")
        model.requestResume(.tab(terminal))
        XCTAssertEqual(model.currentProject?.id, "a")
        XCTAssertEqual(model.currentTab?.resourceID, "pty")
        model.closeWorkspace("a")
        let log = ArchivedTerminalLog(id: "pty", projectID: "a", title: "Terminal", program: "shell", startedAt: Date(), status: "exited", bytes: 10)
        model.requestResume(.terminalLog(log))
        XCTAssertEqual(model.currentProject?.id, "a")
        XCTAssertEqual(model.resumedArchive, .terminalLog(log))
        XCTAssertTrue(host.requests("/v1/terminals").isEmpty, "Reading an ended terminal never starts a process")
    }

    func testKeyboardTabSelectionAlsoRequiresALegacyChatsWorkspace() async throws {
        let (model, _, _) = try await setup()
        let legacy = WorkspaceTab(kind: .chat, projectID: "chats", resourceID: "legacy", title: "Old chat")
        model.tabs = [legacy]
        model.selectedTabID = nil
        model.selectTab(number: 2)
        XCTAssertNil(model.currentTab)
        XCTAssertEqual(model.pendingSessionResume, .tab(legacy))
    }

    func testArchiveWaitsForWorkspaceAndRemembersIt() async throws {
        let (model, _, _) = try await setup()
        model.requestResume(.archivedChat("old"))
        XCTAssertEqual(model.pendingSessionResume, .archivedChat("old"))
        XCTAssertNil(model.resumedArchive)
        model.completeSessionResume(in: "a")
        XCTAssertEqual(model.currentProject?.id, "a")
        XCTAssertEqual(model.resumedArchive, .archivedChat("old"))
        model.resumedArchive = nil
        model.closeWorkspace("a")
        model.requestResume(.archivedChat("old"))
        XCTAssertEqual(model.currentProject?.id, "a")
        XCTAssertEqual(model.resumedArchive, .archivedChat("old"))
    }

    func testChangingHostDropsPendingResumeAndDoesNotReuseAssociations() async throws {
        let (model, host, _) = try await setup()
        model.rememberChatWorkspace("known", workspaceID: "a")
        model.requestResume(.archivedChat("legacy"))
        let other = ConnectionIdentity(host: "https://other.example", deviceID: "phone")
        model.attach(hostID: other.storageKey, identity: other,
                     client: APIClient(address: try ServerAddress(validating: other.host), token: "test", transport: host))
        await model.refreshProjects()
        XCTAssertNil(model.pendingSessionResume)
        XCTAssertTrue(model.chatWorkspaceIDs.isEmpty)
    }

    func testResumeFindsTerminalsOutsideTheCurrentWorkspace() async throws {
        let (model, _, _) = try await setup()
        model.selectProject("b")
        await model.sidebar.refreshResumeTerminals()
        XCTAssertEqual(Set(model.sidebar.resumeTerminals.map(\.projectID)), ["a", "b"])
        XCTAssertEqual(model.currentProject?.id, "b", "Discovery itself does not switch workspaces")
    }

    func testContinuedChatInheritsSourceWorkspaceAndPersistsIt() async throws {
        let (model, _, defaults) = try await setup()
        let source = WorkspaceTab(kind: .chat, projectID: "chats", resourceID: "source", title: "Dinner")
        model.rememberChatWorkspace(source.resourceID, workspaceID: "a")
        model.requestResume(.tab(source))
        let store = model.chatStore(for: source)
        model.selectProject("b")
        store.callbacks.openChat?(Session(id: "continued", title: "Dinner continued", projectID: "chats"))
        XCTAssertNil(model.pendingSessionResume, "A continuation already has a source workspace")
        XCTAssertEqual(model.currentTab?.resourceID, "continued")
        XCTAssertEqual(model.currentProject?.id, "a", "Use the source workspace, not the current selection")
        let (restored, _, _) = try await setup(defaults: defaults)
        XCTAssertEqual(restored.chatWorkspaceIDs["continued"], "a")
    }

    func testContinuationWithRemovedSourceWorkspaceStillAsksForAChoice() async throws {
        let (model, _, _) = try await setup()
        let source = WorkspaceTab(kind: .chat, projectID: "chats", resourceID: "source", title: "Dinner")
        model.rememberChatWorkspace(source.resourceID, workspaceID: "a")
        let store = model.chatStore(for: source)
        model.projects.removeAll { $0.id == "a" }
        model.selectProject("b")
        store.callbacks.openChat?(Session(id: "continued", title: "Dinner continued", projectID: "chats"))
        XCTAssertNotNil(model.pendingSessionResume)
        XCTAssertNil(model.chatWorkspaceIDs["continued"], "Never silently inherit the current selection")
    }

    func testWorkspaceSwitchSkipsLastAndRememberedCodingChats() async throws {
        for remembered in [false, true] {
            let (model, _, _) = try await setup()
            model.phoneNavigation.drawerHoldsBrowsers = true
            let terminal = WorkspaceTab(kind: .terminal, projectID: "a", resourceID: "pty", title: "Terminal")
            var coding = WorkspaceTab(kind: .chat, projectID: "a", resourceID: "coding", title: "Old Coding Chat")
            coding.draft = "Keep this draft"
            model.tabs = [terminal, coding]
            if remembered { model.selectedTabID = coding.id }
            model.phoneNavigation.switchWorkspace("b", model: model)
            model.phoneNavigation.switchWorkspace("a", model: model)
            XCTAssertEqual(model.currentTab?.id, terminal.id, "Skip hidden chats; remembered=\(remembered)")
            XCTAssertEqual(model.tab(coding.id)?.draft, "Keep this draft")
        }
    }

    func testWorkspaceWithOnlyHiddenCodingChatReturnsHome() async throws {
        let (model, _, _) = try await setup()
        let coding = WorkspaceTab(kind: .chat, projectID: "a", resourceID: "coding", title: "Old Coding Chat")
        model.tabs = [coding]
        model.openWorkspace("a", openFilesIfEmpty: false)
        XCTAssertNil(model.currentTab)
        XCTAssertEqual(model.tabs, [coding], "Hidden records stay saved")
    }

    func testCancellingWorkspacePickerWithoutSelectionAllowsSameArchiveResumeAgain() async throws {
        let (model, _, _) = try await setup()
        let target = WorkspaceResumeTarget.archivedChat("legacy")
        model.requestResume(target)
        XCTAssertNil(model.currentProject)
        finishWorkspaceChoice(model: model, covered: false, pickerCancelled: true, action: nil)
        XCTAssertNil(model.pendingSessionResume, "Cancellation must reset the observed intent even without a workspace")
        XCTAssertNil(model.resumedArchive)
        XCTAssertTrue(model.chatWorkspaceIDs.isEmpty)
        model.requestResume(target)
        XCTAssertEqual(model.pendingSessionResume, target)
        model.selectProject("a")
        finishWorkspaceChoice(model: model, covered: false, pickerCancelled: false) {
            model.completeSessionResume(in: "a")
        }
        XCTAssertEqual(model.resumedArchive, target)
        XCTAssertEqual(model.chatWorkspaceIDs["legacy"], "a")
    }

    /// The iPad sidebar and the navigator resume open tabs too: an open Home tab is selected, never added again.
    func testChoosingAnOpenHomeTabSelectsItWithoutAddingACopy() async throws {
        let (model, _, _) = try await setup()
        let home = WorkspaceTab(kind: .home, projectID: "a", title: "Home 2")
        let terminal = WorkspaceTab(kind: .terminal, projectID: "a", resourceID: "pty", title: "Terminal")
        model.tabs = [home, terminal]
        model.selectedTabID = terminal.id
        model.requestResume(.tab(home))
        XCTAssertEqual(model.selectedTabID, home.id)
        XCTAssertEqual(model.tabs.map(\.id), [home.id, terminal.id])
    }

    /// Switching from a Home tab in front to an open tab (sidebar, navigator, ⌘1–9, ⌃Tab) only selects it, as
    /// before Resume followed workspaces: the Home tab stays.
    func testSwitchingFromAHomeTabToAnOpenTabKeepsTheHomeTab() async throws {
        let (model, _, _) = try await setup()
        model.rememberChatWorkspace("known", workspaceID: "a")
        let home = WorkspaceTab(kind: .home, projectID: "a", title: "Home 2")
        let terminal = WorkspaceTab(kind: .terminal, projectID: "a", resourceID: "pty", title: "Terminal")
        let files = WorkspaceTab(kind: .files, projectID: "a", title: "Files")
        let editor = WorkspaceTab(kind: .editor, projectID: "a", resourceID: "notes.md", title: "notes.md")
        let chat = WorkspaceTab(kind: .chat, projectID: "chats", resourceID: "known", title: "Dinner")
        let all = [home, terminal, files, editor, chat]
        model.tabs = all
        for target in [terminal, files, editor, chat] {
            model.selectedTabID = home.id
            model.requestResume(.tab(target))
            XCTAssertEqual(model.selectedTabID, target.id, target.title)
            XCTAssertEqual(model.tabs.map(\.id), all.map(\.id), target.title)
        }
        // A copy of the row's tab (a new id, as the sidebar's session rows make) finds the open one.
        model.selectedTabID = home.id
        model.requestResume(.tab(WorkspaceTab(kind: .terminal, projectID: "a", resourceID: "pty", title: "Terminal")))
        XCTAssertEqual(model.selectedTabID, terminal.id)
        XCTAssertEqual(model.tabs.map(\.id), all.map(\.id))
        model.selectedTabID = home.id
        model.selectAdjacentTab()
        XCTAssertEqual(model.selectedTabID, terminal.id)
        model.selectedTabID = home.id
        model.selectTab(number: 6)
        XCTAssertEqual(model.selectedTabID, chat.id)
        XCTAssertEqual(model.tabs.map(\.id), all.map(\.id), "Keyboard switching keeps the Home tab")
    }

    /// A notification's chat (or any Resume not launched from Home) opens beside the Home tab in front, never in its place.
    func testResumeNotLaunchedFromHomeOpensBesideTheHomeTab() async throws {
        let (model, _, _) = try await setup()
        model.rememberChatWorkspace("known", workspaceID: "a")
        let home = WorkspaceTab(kind: .home, projectID: "a", title: "Home 2")
        model.tabs = [home]
        model.selectedTabID = home.id
        model.requestResume(.tab(WorkspaceTab(kind: .chat, projectID: "chats", resourceID: "known", title: "Chat")))
        XCTAssertEqual(model.currentTab?.resourceID, "known")
        XCTAssertEqual(model.tabs.map(\.kind), [.home, .chat])
        XCTAssertNotNil(model.tab(home.id))
    }

    /// Home's own Resume menu still launches in place of its Home tab (AGENTS.md): a session already open is shown and
    /// that Home tab goes; one waiting for a workspace choice replaces it once chosen.
    func testResumeLaunchedFromAHomeTabTakesItsPlace() async throws {
        let (model, _, _) = try await setup()
        model.rememberChatWorkspace("known", workspaceID: "a")
        let home = WorkspaceTab(kind: .home, projectID: "a", title: "Home 2")
        let terminal = WorkspaceTab(kind: .terminal, projectID: "a", resourceID: "pty", title: "Terminal")
        model.tabs = [home, terminal]
        model.selectedTabID = home.id
        model.requestResume(.tab(WorkspaceTab(kind: .chat, projectID: "chats", resourceID: "known", title: "Chat")),
                            replacingHome: model.launchingHomeTabID)
        XCTAssertEqual(model.tabs.map(\.resourceID), ["known", "pty"], "The chat takes the Home tab's place")
        XCTAssertEqual(model.currentTab?.resourceID, "known")

        model.openHomeTab()
        let second = try XCTUnwrap(model.launchingHomeTabID)
        model.requestResume(.tab(WorkspaceTab(kind: .terminal, projectID: "a", resourceID: "pty", title: "Terminal")),
                            replacingHome: model.launchingHomeTabID)
        XCTAssertEqual(model.selectedTabID, terminal.id)
        XCTAssertNil(model.tab(second), "Already open: it is shown and the Home tab that asked is removed")

        model.openHomeTab()
        let third = try XCTUnwrap(model.launchingHomeTabID)
        model.requestResume(.tab(WorkspaceTab(kind: .chat, projectID: "chats", resourceID: "legacy", title: "Old chat")),
                            replacingHome: model.launchingHomeTabID)
        XCTAssertNotNil(model.pendingSessionResume)
        model.completeSessionResume(in: "a")
        XCTAssertEqual(model.currentTab?.resourceID, "legacy")
        XCTAssertNil(model.tab(third))
        XCTAssertFalse(model.tabs.contains { $0.kind == .home })
    }

    /// Hidden coding chats are kept, with their drafts, when their workspace closes or is removed (owner, 2026-10-08).
    func testClosingOrForgettingAWorkspaceKeepsHiddenCodingChatsAndDrafts() async throws {
        let (model, _, defaults) = try await setup()
        let terminal = WorkspaceTab(kind: .terminal, projectID: "a", resourceID: "pty", title: "Terminal")
        var coding = WorkspaceTab(kind: .chat, projectID: "a", resourceID: "coding", title: "Old Coding Chat")
        coding.draft = "Keep this draft"
        model.tabs = [terminal, coding]
        model.selectedTabID = terminal.id
        XCTAssertEqual(model.closeWorkspace("a").map(\.id), [terminal.id], "Only product tabs close")
        XCTAssertEqual(model.tab(coding.id)?.draft, "Keep this draft")
        XCTAssertEqual(model.workspaces.summary(try XCTUnwrap(model.projects.first { $0.id == "a" })).openTabs, 0)
        model.forgetWorkspace("a")
        XCTAssertEqual(model.tab(coding.id)?.draft, "Keep this draft")
        XCTAssertTrue(model.workspaceTabs.isEmpty)
        let (restored, _, _) = try await setup(defaults: defaults)
        XCTAssertEqual(restored.tab(coding.id)?.draft, "Keep this draft", "Kept across a relaunch")
    }

    /// Saved output only reads what the terminal printed: it opens even when its workspace is gone, and the current
    /// workspace stays. A live terminal there is still never opened elsewhere.
    func testSavedOutputOpensWhenItsWorkspaceIsGone() async throws {
        let (model, host, _) = try await setup()
        model.projects.removeAll { $0.id == "a" }
        model.selectProject("b")
        let log = ArchivedTerminalLog(id: "pty", projectID: "a", title: "Terminal", program: "shell", startedAt: Date(), status: "exited", bytes: 10)
        model.requestResume(.terminalLog(log))
        XCTAssertEqual(model.resumedArchive, .terminalLog(log))
        XCTAssertNil(model.creationIssue)
        XCTAssertEqual(model.currentProject?.id, "b")
        model.resumedArchive = nil
        model.requestResume(.tab(WorkspaceTab(kind: .terminal, projectID: "a", resourceID: "pty", title: "Terminal")))
        XCTAssertNotNil(model.creationIssue)
        XCTAssertNil(model.currentTab)
        XCTAssertEqual(model.currentProject?.id, "b")
        XCTAssertTrue(host.requests("/v1/terminals").isEmpty)
    }

    /// Chat's workspace chats (Claude Code and Codex, 2026-10-12) resume in their own workspace and never ask for one; a
    /// saved copy whose workspace is gone still reads.
    func testWorkspaceChatsResumeInTheirOwnWorkspace() async throws {
        let (model, _, _) = try await setup()
        model.selectProject("b")
        let chat = WorkspaceTab(kind: .chat, projectID: "a", resourceID: "codex:work", title: "Ship it")
        model.requestResume(.tab(chat))
        XCTAssertNil(model.pendingSessionResume)
        XCTAssertEqual(model.currentProject?.id, "a")
        XCTAssertEqual(model.currentTab?.resourceID, "codex:work")
        XCTAssertNil(model.chatWorkspaceIDs["codex:work"], "No saved association: the chat names its workspace")

        model.requestResume(.archivedChat("claude:old", projectID: "b"))
        XCTAssertNil(model.pendingSessionResume)
        XCTAssertEqual(model.currentProject?.id, "b")
        XCTAssertEqual(model.resumedArchive, .archivedChat("claude:old", projectID: "b"))

        model.resumedArchive = nil
        model.projects.removeAll { $0.id == "b" }
        model.requestResume(.archivedChat("claude:old", projectID: "b"))
        XCTAssertNil(model.pendingSessionResume, "A workspace chat never asks for another workspace")
        XCTAssertEqual(model.resumedArchive, .archivedChat("claude:old", projectID: "b"), "Its saved copy still reads")

        model.requestResume(.tab(WorkspaceTab(kind: .chat, projectID: "b", resourceID: "claude:gone", title: "Gone")))
        XCTAssertNil(model.pendingSessionResume)
        XCTAssertEqual(model.creationIssue, "This session’s workspace is no longer available on this Mac.")
    }

    /// A read-only Chats-space chat's Continue in <workspace> opens the new chat there, as that workspace's own chat.
    func testAChatContinuedIntoAWorkspaceOpensThere() async throws {
        let (model, _, _) = try await setup()
        let legacy = WorkspaceTab(kind: .chat, projectID: "chats", resourceID: "claude:old", title: "Old")
        model.rememberChatWorkspace(legacy.resourceID, workspaceID: "a")
        model.selectProject("b")
        model.open(legacy)
        let store = model.chatStore(for: legacy)
        defer { store.shutdown() }
        store.callbacks.openChat?(Session(id: "claude:continued", title: "Old (continued)", projectID: "b", provider: "claude",
                                          parentSessionID: "claude:old"))
        XCTAssertEqual(model.currentTab?.resourceID, "claude:continued")
        XCTAssertEqual(model.currentTab?.projectID, "b")
        XCTAssertEqual(model.currentProject?.id, "b")
        XCTAssertNil(model.chatWorkspaceIDs["claude:continued"], "The legacy chat's association is not applied to it")
    }

    /// Bypass permissions or Full access, once confirmed in a chat, is kept with its tab: the chat never asks again.
    func testAConfirmedUnattendedModeIsKeptWithTheChat() async throws {
        let (model, _, defaults) = try await setup()
        let chat = WorkspaceTab(kind: .chat, projectID: "a", resourceID: "claude:work", title: "Fix")
        model.selectProject("a")
        model.open(chat)
        let store = model.chatStore(for: chat)
        XCTAssertFalse(store.unattendedModeConfirmed)
        store.callbacks.modeConfirmed?()
        store.shutdown()
        XCTAssertEqual(model.tab(chat.id)?.chatModeConfirmed, true)
        let (restored, _, _) = try await setup(defaults: defaults)
        let saved = try XCTUnwrap(restored.tab(chat.id))
        XCTAssertEqual(saved.chatModeConfirmed, true)
        let again = restored.chatStore(for: saved)
        XCTAssertTrue(again.unattendedModeConfirmed, "Passed back to the chat")
        again.shutdown()
    }

    /// Asking again for the same unassigned chat asks again: the shell observes the request count, not the target.
    func testRepeatedResumeOfTheSameChatAsksAgain() async throws {
        let (model, _, _) = try await setup()
        let target = WorkspaceResumeTarget.archivedChat("legacy")
        model.requestResume(target)
        let first = model.sessionResumeRequest
        model.requestResume(target)
        XCTAssertEqual(model.pendingSessionResume, target)
        XCTAssertEqual(model.sessionResumeRequest, first &+ 1)
        model.selectProject("a")
        model.completeSessionResume(in: "a")
        XCTAssertEqual(model.sessionResumeRequest, first &+ 1, "A resolved request asks nothing")
    }

    func testWorkspaceChoiceDoesNotLaunchWhileLockedCoveredOrUnselected() async throws {
        let (model, _, _) = try await setup()
        var launches = 0
        finishWorkspaceChoice(model: model, covered: false, pickerCancelled: false) { launches += 1 }
        model.selectProject("a")
        model.locked = true
        finishWorkspaceChoice(model: model, covered: false, pickerCancelled: false) { launches += 1 }
        model.locked = false
        finishWorkspaceChoice(model: model, covered: true, pickerCancelled: false) { launches += 1 }
        XCTAssertEqual(launches, 0)
    }
}
