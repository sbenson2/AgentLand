import XCTest
import AgentLandCore
@testable import AgentLandWorkspace

/// A draft whose file changed on the Mac (B-2): the person's edits are kept until they choose, and only a
/// confirmed choice replaces either side — the Mac's version (the draft goes) or theirs (saved over the Mac's
/// current file). Nothing is overwritten on its own.
@MainActor final class EditorConflictTests: XCTestCase {
    private let identity = ConnectionIdentity(host: "https://studio.local:9841", deviceID: "device-a")
    private let hostID = "https://studio.local:9841|device-a"
    private var suites: [String] = []

    override func tearDown() async throws {
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        suites = []
    }

    /// The host's file: its text and revision, changed by "the Mac" between requests; saves answer a
    /// conflict unless they name the current revision.
    private final class HostFile: @unchecked Sendable {
        private let lock = NSLock()
        private var text = "first\n"
        private var rev = "r1"
        var content: String { lock.withLock { text } }
        var revision: String { lock.withLock { rev } }
        func changeOnMac(_ newText: String) { lock.withLock { text = newText; rev = "r" + String(Int(rev.dropFirst())! + 1) } }
        func answerRead() -> (Int, String) {
            lock.withLock { (200, Self.document(text, rev)) }
        }
        func answerSave(_ body: [String: Any]) -> (Int, String) {
            lock.withLock {
                guard body["revision"] as? String == rev else {
                    return (409, #"{"error":{"code":"file_conflict","message":"The file changed"}}"#)
                }
                text = body["content"] as? String ?? ""
                rev = "r" + String(Int(rev.dropFirst())! + 1)
                return (200, Self.document(text, rev))
            }
        }
        static func document(_ text: String, _ revision: String) -> String {
            let content = String(data: try! JSONEncoder().encode(text), encoding: .utf8)!
            return #"{"path":"notes.md","content":\#(content),"revision":"\#(revision)"}"#
        }
    }

    private func editor() throws -> (WorkspaceModel, EditorSession, ScriptedHost, HostFile) {
        let host = ScriptedHost()
        let file = HostFile()
        host.on("/v1/file") { request in
            if request.httpMethod == "POST" {
                let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
                return file.answerSave(body)
            }
            return file.answerRead()
        }
        let suite = "editor-conflict-\(UUID())"
        suites.append(suite)
        let workspace = WorkspaceModel(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        workspace.attach(hostID: hostID, identity: identity,
                         client: APIClient(address: try ServerAddress(validating: "https://studio.local:9841"), token: "token", transport: host))
        workspace.projects = [Project(id: "p", name: "Project")]
        workspace.selectedProjectID = "p"
        let tab = WorkspaceTab(kind: .editor, projectID: "p", resourceID: "notes.md", title: "notes.md")
        workspace.open(tab)
        return (workspace, workspace.editorSession(for: tab), host, file)
    }


    private func saves(_ host: ScriptedHost) -> [[String: Any]] { host.bodies("/v1/file") }

    /// Opened while the host can't be reached, the editor says so at once instead of waiting out a read, and reads
    /// the file when the host is back (a new connection epoch).
    func testAnEditorOpenedOfflineLoadsWhenTheHostIsBack() async throws {
        let (workspace, session, host, _) = try editor()
        defer { withExtendedLifetime(workspace) {} }
        workspace.reachable = false

        await session.loadIfNeeded()

        XCTAssertEqual(session.issue, EditorSession.offlineLoad)
        XCTAssertTrue(session.loadFailed)
        XCTAssertFalse(session.loading)
        XCTAssertTrue(host.requests("/v1/file").isEmpty, "Nothing is sent while offline")

        await session.loadIfNeeded()
        XCTAssertTrue(host.requests("/v1/file").isEmpty, "The same epoch does not try again")

        workspace.reachable = true
        workspace.connectionEpoch += 1
        await session.loadIfNeeded()

        XCTAssertNil(session.issue)
        XCTAssertFalse(session.loadFailed)
        XCTAssertEqual(session.content, "first\n")
        XCTAssertEqual(host.requests("/v1/file").count, 1)
    }

    func testASaveThatConflictsKeepsTheDraftAndOffersTheChoices() async throws {
        let (workspace, session, host, file) = try editor()
        defer { withExtendedLifetime(workspace) {} }
        await session.load()
        session.content = "mine\n"
        file.changeOnMac("theirs\n")

        await session.save()

        XCTAssertTrue(session.conflicted)
        XCTAssertEqual(session.issue, EditorSession.conflictOnSave)
        XCTAssertFalse(session.issue?.contains("resolving the revision conflict") == true, "No promise of a resolution the app lacks")
        XCTAssertEqual(session.content, "mine\n", "The edits are kept")
        XCTAssertEqual(file.content, "theirs\n", "Nothing replaced the Mac's file")
        XCTAssertEqual(saves(host).count, 1)
    }

    /// Offline, Save is refused at once and says so in place; nothing is sent then or later, and the edits stay.
    func testASaveWhileOfflineSendsNothingAndSaysSo() async throws {
        let (workspace, session, host, file) = try editor()
        defer { withExtendedLifetime(workspace) {} }
        await session.load()
        session.content = "mine\n"
        workspace.reachable = false

        await session.save()

        XCTAssertEqual(session.issue, EditorSession.offlineSave)
        XCTAssertTrue(saves(host).isEmpty, "Offline sends nothing")
        XCTAssertEqual(session.content, "mine\n", "The edits are kept")
        XCTAssertTrue(session.canSave, "Save stays offered for when the host is back")

        workspace.reachable = true
        await session.save()
        XCTAssertNil(session.issue)
        XCTAssertEqual(file.content, "mine\n")
        XCTAssertEqual(saves(host).count, 1)
    }

    func testSaveMineAnywayReplacesTheMacsFileAgainstItsCurrentRevision() async throws {
        let (workspace, session, host, file) = try editor()
        defer { withExtendedLifetime(workspace) {} }
        await session.load()
        session.content = "mine\n"
        file.changeOnMac("theirs\n")
        await session.save()
        XCTAssertTrue(session.conflicted)

        await session.saveMineAnyway()

        XCTAssertEqual(saves(host).last?["revision"] as? String, "r2", "Saved against the Mac's current revision")
        XCTAssertEqual(file.content, "mine\n")
        XCTAssertFalse(session.conflicted)
        XCTAssertNil(session.issue)
        XCTAssertFalse(session.edited)
    }

    func testAChangeOnTheMacAfterSaveMineAnywayReadsConflictsAgain() async throws {
        let (workspace, session, host, file) = try editor()
        defer { withExtendedLifetime(workspace) {} }
        await session.load()
        session.content = "mine\n"
        file.changeOnMac("theirs\n")
        await session.save()
        // Another change lands between the read Save Mine Anyway makes and its save.
        host.on("/v1/file") { request in
            if request.httpMethod == "POST" { return (409, #"{"error":{"code":"file_conflict","message":"The file changed"}}"#) }
            return file.answerRead()
        }
        await session.saveMineAnyway()
        XCTAssertTrue(session.conflicted, "A change the person has not seen is never replaced")
        XCTAssertEqual(file.content, "theirs\n")
    }

    func testUseMacsVersionThrowsTheDraftAwayAndOpensTheMacsFile() async throws {
        let (workspace, session, host, file) = try editor()
        defer { withExtendedLifetime(workspace) {} }
        await session.load()
        session.content = "mine\n"
        session.flushDraft()
        file.changeOnMac("theirs\n")
        await session.save()
        let generation = session.documentGeneration

        await session.useHostVersion()

        XCTAssertEqual(session.content, "theirs\n")
        XCTAssertNotEqual(session.documentGeneration, generation, "The editor shows the Mac's text")
        XCTAssertFalse(session.conflicted)
        XCTAssertFalse(session.edited)
        XCTAssertEqual(workspace.tab(session.tabID)?.editorDirty, false, "The draft is gone")
        XCTAssertEqual(saves(host).count, 1, "Using the Mac's version saves nothing")
    }

    func testADraftWhoseFileChangedSinceItBeganIsAConflictWhenOpened() async throws {
        let (workspace, session, _, file) = try editor()
        defer { withExtendedLifetime(workspace) {} }
        await session.load()
        session.content = "mine\n"
        session.flushDraft()
        file.changeOnMac("theirs\n")

        await session.load()

        XCTAssertTrue(session.conflicted)
        XCTAssertEqual(session.issue, EditorSession.conflictSinceDraft)
        XCTAssertEqual(session.content, "mine\n")
        XCTAssertEqual(workspace.tab(session.tabID)?.editorDirty, true)
    }
}
