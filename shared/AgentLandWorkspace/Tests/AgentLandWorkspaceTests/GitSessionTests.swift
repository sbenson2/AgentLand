import XCTest
import AgentLandCore
@testable import AgentLandWorkspace

/// The Git tab against a scripted host: rows and words, staging, the commit with the identity the
/// host reports, refusals in plain words, timeouts that are never retried, and late answers dropped.
@MainActor final class GitSessionTests: XCTestCase {
    private let identity = ConnectionIdentity(host: "https://studio.local:9841", deviceID: "device-a")
    private let hostID = "https://studio.local:9841|device-a"
    private var suites: [String] = []

    override func tearDown() async throws {
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        suites = []
    }

    private static let allGit = ["stage", "unstage", "commit", "stagedDiff", "unstagedDiff", "identity"]

    private func workspace(_ host: ScriptedHost, git: [String] = allGit, name: String = #function) throws -> WorkspaceModel {
        let suite = "git-session-\(name)-\(UUID())"
        suites.append(suite)
        let workspace = WorkspaceModel(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        workspace.attach(hostID: hostID, identity: identity,
                         client: APIClient(address: try ServerAddress(validating: "https://studio.local:9841"), token: "token", transport: host))
        workspace.projects = [Project(id: "p", name: "Project")]
        workspace.capabilities = CapabilitiesResponse(interactions: true, terminal: true, git: git)
        workspace.selectedProjectID = "p"
        return workspace
    }

    private func gitTab(_ workspace: WorkspaceModel) -> (WorkspaceTab, GitSession) {
        workspace.showGit()
        let tab = workspace.currentTab!
        return (tab, workspace.gitSession(for: tab))
    }

    nonisolated private static let status = #"{"branch":"main","changes":[{"path":"a.swift","status":"MM","index":"M","worktree":"M","conflicted":false,"untracked":false},{"path":"new.txt","status":"??","index":"?","worktree":"?","conflicted":false,"untracked":true},{"path":"docs/b.md","status":"R ","index":"R","worktree":"","conflicted":false,"untracked":false,"originalPath":"docs/old.md"},{"path":"c.swift","status":"UU","index":"U","worktree":"U","conflicted":true,"untracked":false},{"path":"gone.txt","status":" D","index":"","worktree":"D","conflicted":false,"untracked":false}]}"#

    private func scriptedRepository(_ host: ScriptedHost, status: String = GitSessionTests.status,
                                    identity: String = #"{"name":"Test Person","email":"test@example.com","source":"repository"}"#) {
        host.on("/v1/git/repositories") { _ in (200, #"{"repositories":[{"name":"Project","path":"."}]}"#) }
        host.on("/v1/git/status") { _ in (200, status) }
        host.on("/v1/git/identity") { _ in (200, identity) }
    }

    /// The iPhone shakedown's Git pane, opened while the host was away: "Could not connect to the server" stayed
    /// after the host came back, because the pane was not on screen to see the connection return and
    /// `loadIfNeeded` counted the failed read as done. A failed read is now read again once the connection epoch
    /// has moved on; with the host still away and the epoch unchanged it is not.
    func testAReadThatFailedWhileTheHostWasAwayIsReadAgainAfterItCameBack() async throws {
        let host = ScriptedHost()
        let away = Counter()
        away.increment()
        scriptedRepository(host)
        host.on("/v1/git/repositories") { _ in
            away.value > 0 ? (503, #"{"error":{"code":"host_unavailable","message":"Could not connect to the server."}}"#)
                : (200, #"{"repositories":[{"name":"Project","path":"."}]}"#)
        }
        let workspace = try workspace(host)
        let (_, session) = gitTab(workspace)
        await session.loadIfNeeded()
        XCTAssertNotNil(session.loadIssue)
        XCTAssertEqual(host.requests("/v1/git/repositories").count, 1)

        await session.loadIfNeeded()
        XCTAssertEqual(host.requests("/v1/git/repositories").count, 1, "No new read while the connection has not come back")

        away.decrement()
        workspace.connectionEpoch += 1
        await session.loadIfNeeded()
        XCTAssertEqual(host.requests("/v1/git/repositories").count, 2, "The failed read is read again after recovery")
        XCTAssertNil(session.loadIssue)
        XCTAssertEqual(session.status?.branch, "main")

        await session.loadIfNeeded()
        XCTAssertEqual(host.requests("/v1/git/repositories").count, 2, "A read that worked is not read again")
    }

    func testRowsSplitIntoConflictsStagedAndChangesWithWords() async throws {
        let host = ScriptedHost()
        scriptedRepository(host)
        let workspace = try workspace(host)
        let (_, session) = gitTab(workspace)
        await session.loadIfNeeded()

        XCTAssertEqual(session.repository?.path, ".")
        XCTAssertEqual(session.status?.branch, "main")
        XCTAssertEqual(session.conflictRows.map(\.path), ["c.swift"])
        XCTAssertEqual(session.stagedRows.map(\.path), ["a.swift", "docs/b.md"])
        XCTAssertEqual(session.changeRows.map(\.path), ["a.swift", "new.txt", "gone.txt"], "A file changed in both shows in both")
        XCTAssertEqual(session.stagedRows.map(\.words), ["Modified", "Renamed from docs/old.md"])
        XCTAssertEqual(session.changeRows.map(\.words), ["Modified", "Untracked", "Deleted"])
        XCTAssertEqual(session.conflictRows.map(\.words), ["Both modified"])
        XCTAssertEqual(session.stagedRows[1].name, "b.md")
        XCTAssertEqual(session.stagedRows[1].folder, "docs")
        XCTAssertEqual(session.identity?.formatted, "Test Person <test@example.com>")
        XCTAssertEqual(session.diffBase(for: session.stagedRows[0]), .staged)
        XCTAssertEqual(session.diffBase(for: session.changeRows[1]), .index)
        XCTAssertEqual(GitWords.status(of: GitSession.Row(area: .changes, change: GitChange(path: "build/", status: "??"))), "Untracked folder")
    }

    func testManagementSectionsOnlyLoadAdvertisedFeaturesAndRefreshAfterMutation() async throws {
        let host = ScriptedHost()
        scriptedRepository(host)
        host.on("/v1/git/branches") { _ in (200, #"{"branches":[{"name":"main","current":true,"remote":false,"ahead":1,"behind":0}]}"#) }
        host.on("/v1/git/history") { _ in (200, #"{"commits":[{"hash":"abc","subject":"Initial","author":"Ada","timestamp":10}],"nextCursor":"30"}"#) }
        host.on("/v1/git/remotes") { _ in (200, #"{"remotes":[{"name":"origin","url":"ssh://example/repo","supported":true}]}"#) }
        host.on("/v1/git/stashes") { _ in (200, #"{"stashes":[]}"#) }
        host.on("/v1/git/branch") { _ in (200, #"{"changed":true}"#) }
        let workspace = try workspace(host, git: Self.allGit + ["branches", "history", "remotes", "stashes"])
        let (_, session) = gitTab(workspace)
        await session.loadIfNeeded()
        XCTAssertEqual(session.branches.first?.name, "main")
        XCTAssertEqual(session.history.first?.subject, "Initial")
        XCTAssertEqual(session.remotes.first?.name, "origin")
        session.newBranchName = "feature/tree"
        await session.createBranch("feature/tree")
        XCTAssertEqual(host.bodies("/v1/git/branch").last?["name"] as? String, "feature/tree")
        XCTAssertEqual(host.requests("/v1/git/branches").count, 2)
        XCTAssertFalse(session.managing)
        XCTAssertEqual(session.newBranchName, "", "The field is cleared for the next branch once this one is made")

        let olderHost = ScriptedHost()
        scriptedRepository(olderHost)
        let olderWorkspace = try self.workspace(olderHost)
        let (_, olderSession) = gitTab(olderWorkspace)
        await olderSession.loadIfNeeded()
        XCTAssertTrue(olderHost.requests("/v1/git/branches").isEmpty)
        XCTAssertTrue(olderHost.requests("/v1/git/history").isEmpty)
    }

    func testFileTreeKeepsNestedFoldersAndStagedAndUnstagedIdentitySeparate() {
        let staged = GitSession.Row(area: .staged, change: GitChange(path: "Sources/App/file.swift", status: "MM"))
        let changes = GitSession.Row(area: .changes, change: staged.change)
        let tree = GitFileTreeNode.build(rows: [staged])
        XCTAssertEqual(tree.first?.name, "Sources")
        XCTAssertEqual(tree.first?.children.first?.name, "App")
        XCTAssertEqual(tree.first?.children.first?.children.first?.row, staged)
        XCTAssertNotEqual(GitFileTreeNode.build(rows: [changes]).first?.id, tree.first?.id)
    }

    func testUntrackedOnlyStashRequiresIncludeUntracked() async throws {
        let host = ScriptedHost()
        scriptedRepository(host, status: #"{"branch":"main","changes":[{"path":"new.txt","status":"??"}]}"#)
        host.on("/v1/git/stashes") { _ in (200, #"{"stashes":[]}"#) }
        host.on("/v1/git/stash") { _ in (200, #"{"changed":true}"#) }
        let workspace = try workspace(host, git: Self.allGit + ["stashes"])
        let (_, session) = gitTab(workspace)
        await session.loadIfNeeded()
        await session.saveStash()
        XCTAssertTrue(host.requests("/v1/git/stash").isEmpty)
        session.stashIncludeUntracked = true
        await session.saveStash()
        XCTAssertEqual(host.requests("/v1/git/stash").count, 1)
    }

    func testFileTreePreservesDeletedFileAndUntrackedFolderWithSamePath() {
        let deleted = GitSession.Row(area: .changes, change: GitChange(path: "old", status: " D"))
        let replacement = GitSession.Row(area: .changes, change: GitChange(path: "old/new.txt", status: "??"))
        let nodes = GitFileTreeNode.build(rows: [deleted, replacement])
        XCTAssertEqual(nodes.count, 2)
        XCTAssertEqual(nodes.first?.children.first?.row, replacement)
        XCTAssertEqual(nodes.last?.row, deleted)
        XCTAssertNotEqual(nodes.first?.id, nodes.last?.id)
    }

    func testStageAndUnstageSendRepositoryPathsAndReadTheStatusAgain() async throws {
        let host = ScriptedHost()
        scriptedRepository(host)
        host.on("/v1/git/stage") { _ in (200, #"{"staged":2}"#) }
        host.on("/v1/git/unstage") { _ in (200, #"{"unstaged":3}"#) }
        let workspace = try workspace(host)
        let (_, session) = gitTab(workspace)
        await session.loadIfNeeded()
        let reads = host.requests("/v1/git/status").count

        await session.stageAll()
        let staged = try XCTUnwrap(host.bodies("/v1/git/stage").last)
        XCTAssertEqual(staged["path"] as? String, ".")
        XCTAssertEqual(staged["files"] as? [String], ["a.swift", "new.txt", "gone.txt"], "Stage All leaves conflicts alone")
        XCTAssertEqual(session.notice?.title, "Staged 3 files")
        XCTAssertEqual(host.requests("/v1/git/status").count, reads + 1)

        await session.unstageAll()
        XCTAssertEqual(host.bodies("/v1/git/unstage").last?["files"] as? [String], ["a.swift", "docs/b.md", "docs/old.md"],
                       "Unstaging a rename takes both of its paths")
        XCTAssertTrue(session.busyPaths.isEmpty)
    }

    func testCommitIsMadeAsTheIdentityShownAndClearsTheMessage() async throws {
        let host = ScriptedHost()
        scriptedRepository(host)
        host.on("/v1/git/commit") { _ in (200, #"{"commit":"4f2a9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b","hooksSkipped":true}"#) }
        let workspace = try workspace(host)
        let (tab, session) = gitTab(workspace)
        await session.loadIfNeeded()
        // The conflict must go before a commit.
        XCTAssertEqual(session.commitBlocker, "Resolve the merge conflicts first.")
        host.on("/v1/git/status") { _ in (200, #"{"branch":"main","changes":[{"path":"a.swift","status":"M ","index":"M","worktree":"","conflicted":false,"untracked":false}]}"#) }
        await session.refreshStatus()
        XCTAssertEqual(session.commitBlocker, "Write a commit message.")
        XCTAssertFalse(session.canCommit)

        session.message = "Add the fixture"
        XCTAssertTrue(session.canCommit)
        await session.commit()
        let body = try XCTUnwrap(host.bodies("/v1/git/commit").last)
        XCTAssertEqual(body["message"] as? String, "Add the fixture")
        XCTAssertEqual(body["path"] as? String, ".")
        XCTAssertEqual(body["author"] as? [String: String], ["name": "Test Person", "email": "test@example.com"])
        XCTAssertEqual(session.notice?.title, "Committed 4f2a9c0")
        XCTAssertEqual(session.notice?.message, "Commit hooks don’t run from AgentLand.")
        XCTAssertEqual(session.commits, 1)
        XCTAssertEqual(session.message, "")
        XCTAssertEqual(session.lastCommit?.shortHash, "4f2a9c0")
        await waitUntil("the empty message to be kept with the tab") { workspace.tab(tab.id)?.draft == "" }
    }

    func testCommitBlockersAndTheMessageDraftKeptWithTheTab() async throws {
        let host = ScriptedHost()
        scriptedRepository(host, status: #"{"branch":"main","changes":[{"path":"a.swift","status":"M ","index":"M","worktree":""}]}"#,
                           identity: #"{"name":"Test Person","email":"","source":"none"}"#)
        let workspace = try workspace(host)
        let (tab, session) = gitTab(workspace)
        await session.loadIfNeeded()
        session.message = "Draft message"
        XCTAssertEqual(session.commitBlocker, GitWords.identityMissing, "No identity, no commit")
        await waitUntil("the draft to be saved") { workspace.tab(tab.id)?.draft == "Draft message" }

        workspace.reachable = false
        XCTAssertEqual(session.commitBlocker, "You’re offline.")
        workspace.reachable = true
        session.message = String(repeating: "x", count: GitSession.messageLimit + 1)
        XCTAssertNotNil(session.commitBlocker)

        // A new session for the tab starts from the kept draft.
        workspace.sessions.end(tab.id)
        workspace.updateDraft(tab.id, "Draft message")
        XCTAssertEqual(workspace.gitSession(for: try XCTUnwrap(workspace.tab(tab.id))).message, "Draft message")
    }

    func testATimeoutIsReportedNeverRetriedAndKeepsTheMessage() async throws {
        let host = ScriptedHost()
        scriptedRepository(host, status: #"{"branch":"main","changes":[{"path":"a.swift","status":"M ","index":"M","worktree":""}]}"#)
        host.on("/v1/git/commit") { _ in
            (504, #"{"error":{"code":"git_timeout","message":"Git did not finish in time.","outcome":"unknown"}}"#)
        }
        let workspace = try workspace(host)
        let (_, session) = gitTab(workspace)
        await session.loadIfNeeded()
        session.message = "Slow commit"
        await session.commit()
        XCTAssertEqual(host.requests("/v1/git/commit").count, 1, "Never sent again by itself")
        XCTAssertEqual(session.notice?.title, "Commit not confirmed")
        XCTAssertTrue(session.notice?.message?.contains("may have run — check the log") == true)
        XCTAssertEqual(session.message, "Slow commit", "The message stays for the person to decide")
        XCTAssertEqual(session.commits, 0)
    }

    func testRefusalsAreInPlainWords() async throws {
        for (code, title) in [("git_identity_missing", "No commit identity"), ("git_signing_required", "Signed commits are required"),
                              ("git_filter_unsupported", "Git filters require the Mac"), ("git_index_locked", "Git’s index is locked")] {
            let host = ScriptedHost()
            scriptedRepository(host)
            host.on("/v1/git/stage") { _ in (409, #"{"error":{"code":"\#(code)","message":"Refused"}}"#) }
            let workspace = try workspace(host, name: #function + code)
            let (_, session) = gitTab(workspace)
            await session.loadIfNeeded()
            await session.stage([try XCTUnwrap(session.changeRows.first)])
            XCTAssertEqual(session.notice?.title, title, code)
            XCTAssertEqual(session.notice?.tone, .error)
        }
    }

    func testDiffsAskForStagedOrUnstagedChangesOnlyWhereOffered() async throws {
        let host = ScriptedHost()
        scriptedRepository(host)
        host.on("/v1/git/diff") { _ in (200, #"{"path":"a.swift","diff":"@@ -1 +1 @@\n-old\n+new\n"}"#) }
        let workspace = try workspace(host)
        let (_, session) = gitTab(workspace)
        await session.loadIfNeeded()
        let staged = try XCTUnwrap(session.stagedRows.first)
        session.showDiff(staged)
        _ = try await session.loadDiff(try XCTUnwrap(session.diff))
        XCTAssertEqual(ScriptedHost.query(try XCTUnwrap(host.requests("/v1/git/diff").last))["staged"], "1")

        workspace.capabilities = CapabilitiesResponse(interactions: true, terminal: true, git: ["stage", "unstage", "commit"])
        _ = try await session.loadDiff(GitDiffRequest(row: staged, repository: "."))
        let older = ScriptedHost.query(try XCTUnwrap(host.requests("/v1/git/diff").last))
        XCTAssertNil(older["staged"], "A host without stagedDiff gets the plain diff")
        XCTAssertNil(older["against"])
    }

    func testTheGitTabReportsReadinessAndDropsALateStatus() async throws {
        let host = ScriptedHost()
        let gate = Gate()
        let arrived = Gate()
        scriptedRepository(host)
        host.on("/v1/git/status") { _ in
            await arrived.open()
            await gate.wait()
            return (200, GitSessionTests.status)
        }
        host.on("/v1/projects") { _ in (200, #"{"projects":[{"id":"p","name":"Project"}]}"#) }
        host.on("/v1/capabilities") { _ in
            (200, #"{"interactions":true,"terminal":true,"git":["stage","unstage","commit","stagedDiff","unstagedDiff","identity"]}"#)
        }
        let workspace = try workspace(host)
        await workspace.refreshProjects()
        let (tab, session) = gitTab(workspace)
        workspace.beginPresentation()
        XCTAssertEqual(workspace.presentationTicket?.tabID, tab.id)
        let load = Task { await session.loadIfNeeded() }
        await arrive(at: arrived, "the status read")
        XCTAssertFalse(workspace.presentationReady, "Not ready while the status is out")
        // Reload: the answer on its way is for the older refresh generation.
        workspace.reloadTab(tab.id)
        await gate.open()
        await load.value
        XCTAssertNil(session.status, "A late status for an older generation is dropped")
        await session.loadIfNeeded()
        XCTAssertNotNil(session.status)
        XCTAssertTrue(workspace.presentationReady)
    }

    func testDiffDocumentNumbersItsLines() {
        let diff = GitDiffDocument("""
        diff --git a/a.swift b/a.swift
        index 1234567..89abcde 100644
        --- a/a.swift
        +++ b/a.swift
        @@ -10,3 +10,4 @@ func main() {
         let a = 1
        -let b = 2
        +let b = 3
        +let c = 4
         print(a)
        \\ No newline at end of file
        """)
        XCTAssertEqual(diff.lines.map(\.kind), [.header, .header, .fileHeader, .fileHeader, .hunk, .context, .removed, .added, .added, .context, .note])
        XCTAssertEqual(diff.lines[5].oldNumber, 10)
        XCTAssertEqual(diff.lines[5].newNumber, 10)
        XCTAssertEqual(diff.lines[6].oldNumber, 11)
        XCTAssertNil(diff.lines[6].newNumber)
        XCTAssertEqual(diff.lines[7].newNumber, 11)
        XCTAssertEqual(diff.lines[8].newNumber, 12)
        XCTAssertEqual(diff.lines[9].oldNumber, 12)
        XCTAssertEqual(diff.lines[9].newNumber, 13)
        XCTAssertEqual(diff.lines[7].text, "let b = 3")
        XCTAssertEqual(diff.addedCount, 2)
        XCTAssertEqual(diff.removedCount, 1)

        let untracked = GitDiffDocument("diff --git a/n.txt b/n.txt\nnew file mode 100644\n--- /dev/null\n+++ b/n.txt\n@@ -0,0 +1,2 @@\n+one\n+\ttwo\n")
        XCTAssertEqual(untracked.lines.filter { $0.kind == .added }.map(\.newNumber), [1, 2])
        XCTAssertEqual(untracked.lines.last?.text, "    two", "Tabs show as four spaces")
        XCTAssertEqual(GitDiffDocument("").lines, [])
        XCTAssertEqual(GitDiffDocument("Binary files /dev/null and b/x.png differ\n").lines.map(\.kind), [.note])
    }

    func testTheGitTabOpensOncePerWorkspaceAndSavesWithTheTabs() throws {
        let (model, defaults, suite) = try { () throws -> (WorkspaceModel, UserDefaults, String) in
            let suite = "git-tabs-\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            return (WorkspaceModel(defaults: defaults), defaults, suite)
        }()
        defer { defaults.removePersistentDomain(forName: suite) }
        model.attach(hostID: hostID, identity: identity, client: nil)
        model.projects = [Project(id: "p", name: "Project")]
        model.selectedProjectID = "p"
        model.showGit()
        let first = try XCTUnwrap(model.currentTab)
        XCTAssertEqual(first.kind, .git)
        model.showFiles()
        model.showGit()
        XCTAssertEqual(model.currentTab?.id, first.id, "The workspace keeps one Git tab")
        let restored = WorkspaceModel(defaults: defaults)
        restored.attach(hostID: hostID, identity: identity, client: nil)
        XCTAssertTrue(restored.tabs.contains { $0.id == first.id && $0.kind == .git })
    }
}
