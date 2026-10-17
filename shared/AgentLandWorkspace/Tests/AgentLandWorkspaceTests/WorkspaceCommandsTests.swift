import XCTest
import AgentLandCore
@testable import AgentLandWorkspace

/// Answers the project list, a file and its save.
private final class ProjectHost: APITransport, @unchecked Sendable {
    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body: String
        switch request.url?.path ?? "" {
        case "/v1/projects": body = #"{"projects":[{"id":"p","name":"Project"}]}"#
        case "/v1/capabilities": body = #"{"interactions":false,"terminal":true}"#
        case "/v1/file": body = #"{"path":"notes.txt","content":"hello\n","revision":"r1"}"#
        default: body = #"{"accepted":true}"#
        }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

/// The focused value the shell publishes for the menu bar (iPad and Mac): which commands are
/// available for the surface in front, and what they run.
@MainActor final class WorkspaceCommandsTests: XCTestCase {
    private func attachedWorkspace(_ name: String = #function) async throws -> (WorkspaceModel, UserDefaults, String) {
        let suite = "workspace-commands-\(name)-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let model = WorkspaceModel(defaults: defaults)
        let identity = ConnectionIdentity(host: "https://test.example", deviceID: "device-a")
        let client = APIClient(address: try ServerAddress(validating: "https://test.example"), token: "token", transport: ProjectHost())
        model.attach(hostID: identity.storageKey, identity: identity, client: client)
        await model.refreshProjects()
        return (model, defaults, suite)
    }

    func testHomeOffersCreationButNothingToCloseOrSave() async throws {
        let (model, defaults, suite) = try await attachedWorkspace()
        defer { defaults.removePersistentDomain(forName: suite) }
        let actions = WorkspaceCommandActions.make(model: model, shell: WorkspaceCommandShell())

        XCTAssertNil(actions.newChat, "This host only offers coding agents, not general-purpose Chat")
        XCTAssertNil(actions.newChatWith)
        XCTAssertNotNil(actions.newHomeTab)
        XCTAssertNotNil(actions.newTerminal, "the host offers terminals")
        XCTAssertNil(actions.closeTab, "the permanent Home does not close")
        XCTAssertNil(actions.save)
        XCTAssertNil(actions.find)
        XCTAssertNil(actions.send)
        XCTAssertNil(actions.commit)
        XCTAssertNil(actions.nextTab, "Home is the only tab")
        XCTAssertNotNil(actions.reload)
        XCTAssertEqual(actions.tabCount, 1)
        XCTAssertNil(actions.textActualSize, "Actual Size waits for a step away from it")
    }

    func testNothingIsCreatedWithoutTheHostsWorkspaces() throws {
        let suite = "workspace-commands-empty-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let actions = WorkspaceCommandActions.make(model: WorkspaceModel(defaults: defaults), shell: WorkspaceCommandShell())
        XCTAssertNil(actions.newChat)
        XCTAssertNil(actions.newHomeTab)
        XCTAssertNil(actions.newTerminal)
    }

    func testCommandsRunTheShellsActions() async throws {
        let (model, defaults, suite) = try await attachedWorkspace()
        defer { defaults.removePersistentDomain(forName: suite) }
        var created: [(WorkspaceTabKind, TerminalProgram)] = []
        var calls: [String] = []
        var shell = WorkspaceCommandShell()
        shell.withWorkspace = { action in calls.append("withWorkspace"); action() }
        shell.create = { kind, program, _ in created.append((kind, program)) }
        shell.chooseProvider = { calls.append("chooseProvider") }
        shell.focusSearch = { calls.append("search") }
        shell.showSettings = { calls.append("settings") }
        shell.stepTextSize = { calls.append("step \($0)") }
        shell.resetTextSize = { calls.append("reset") }
        shell.textSizeStep = 2
        let actions = WorkspaceCommandActions.make(model: model, shell: shell)

        actions.newChat?()
        actions.newTerminal?()
        actions.newChatWith?()
        actions.search?()
        actions.settings?()
        actions.textBigger?()
        actions.textSmaller?()
        actions.textActualSize?()

        XCTAssertEqual(created.map(\.0), [.terminal])
        XCTAssertEqual(created.map(\.1), [.shell])
        XCTAssertNil(actions.toggleSidebar, "the full-width shell has no sidebar command")
        XCTAssertEqual(calls, ["search", "settings",
                               "step 1", "step -1", "reset"])
    }

    func testAnEditorWithChangesOffersSaveAndClose() async throws {
        let (model, defaults, suite) = try await attachedWorkspace()
        defer { defaults.removePersistentDomain(forName: suite) }
        model.selectProject("p")
        model.openFile(projectID: "p", path: "notes.txt")
        let tab = try XCTUnwrap(model.currentTab)
        let session = model.editorSession(for: tab)
        await session.load()

        var actions = WorkspaceCommandActions.make(model: model, shell: WorkspaceCommandShell())
        XCTAssertNotNil(actions.closeTab)
        XCTAssertNotNil(actions.find)
        XCTAssertNil(actions.save, "nothing to save before an edit")
        XCTAssertEqual(actions.tabCount, 2)
        XCTAssertNotNil(actions.nextTab)

        // As the editor view does on each change.
        session.content = "hello, edited\n"
        session.scheduleDraftSave(session.content)
        actions = WorkspaceCommandActions.make(model: model, shell: WorkspaceCommandShell())
        XCTAssertNotNil(actions.save)

        actions.closeTab?()
        XCTAssertNotNil(model.pendingCloseTab, "closing an edited file asks first")
    }
}
