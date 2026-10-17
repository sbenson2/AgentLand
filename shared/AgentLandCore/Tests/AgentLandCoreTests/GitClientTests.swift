import Foundation
import XCTest
@testable import AgentLandCore

/// The Git routes (docs/HOST-API.md, "Git") through a real `URLSession` answered by the stub protocol.
final class GitClientTests: XCTestCase {
    private func client() throws -> APIClient {
        APIClient(address: try ServerAddress(validating: "https://mac.example:9841"), token: "device-token", transport: ArchiveStubTransport())
    }

    private func json(_ data: Data?) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(data)) as? [String: Any])
    }

    private func query(_ request: URLRequest) -> [String: String] {
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
    }

    func testStatusReadsTheIndexAndWorktreeColumns() throws {
        let body = #"{"branch":"main","changes":[{"path":"a.swift","status":"MM","index":"M","worktree":"M","conflicted":false,"untracked":false},{"path":"new/","status":"??","index":"?","worktree":"?","conflicted":false,"untracked":true},{"path":"b.swift","status":"R ","index":"R","worktree":"","conflicted":false,"untracked":false,"originalPath":"old.swift"},{"path":"c.swift","status":"UU","index":"U","worktree":"U","conflicted":true,"untracked":false}]}"#
        let status = try ProtocolDecoder.decode(GitStatusResponse.self, from: Data(body.utf8))
        XCTAssertEqual(status.branch, "main")
        XCTAssertEqual(status.changes.map(\.index), ["M", "?", "R", "U"])
        XCTAssertEqual(status.changes.map(\.worktree), ["M", "?", "", "U"])
        XCTAssertEqual(status.changes.map(\.untracked), [false, true, false, false])
        XCTAssertEqual(status.changes.map(\.conflicted), [false, false, false, true])
        XCTAssertEqual(status.changes[2].originalPath, "old.swift")

        // Hosts before the columns: they come from the two-letter status.
        let older = #"{"branch":"main","changes":[{"path":"a","status":" M"},{"path":"b","status":"A "},{"path":"c","status":"??"},{"path":"d","status":"AA"}]}"#
        let legacy = try ProtocolDecoder.decode(GitStatusResponse.self, from: Data(older.utf8))
        XCTAssertEqual(legacy.changes.map(\.index), ["", "A", "?", "A"])
        XCTAssertEqual(legacy.changes.map(\.worktree), ["M", "", "?", "A"])
        XCTAssertEqual(legacy.changes.map(\.untracked), [false, false, true, false])
        XCTAssertEqual(legacy.changes.map(\.conflicted), [false, false, false, true])
    }

    func testDiffAsksForTheStagedOrUnstagedChangesOnlyWhenChosen() async throws {
        let api = try client()
        ArchiveStubProtocol.install { request, _ in
            XCTAssertEqual(request.url?.path, "/v1/git/diff")
            return (200, Data(#"{"path":"a.swift","diff":"@@ -1 +1 @@\n-old\n+new\n"}"#.utf8))
        }
        let head = try await api.gitDiff(projectID: "p", repository: ".", file: "a.swift", base: .head)
        XCTAssertEqual(head, GitDiffResponse(path: "a.swift", diff: "@@ -1 +1 @@\n-old\n+new\n"))
        XCTAssertEqual(query(try XCTUnwrap(ArchiveStubProtocol.requests.last?.request)), ["projectId": "p", "path": ".", "file": "a.swift"])
        _ = try await api.gitDiff(projectID: "p", repository: ".", file: "a.swift", base: .staged)
        XCTAssertEqual(query(try XCTUnwrap(ArchiveStubProtocol.requests.last?.request))["staged"], "1")
        XCTAssertNil(query(try XCTUnwrap(ArchiveStubProtocol.requests.last?.request))["against"])
        _ = try await api.gitDiff(projectID: "p", repository: "app", file: "a.swift", base: .index)
        let unstaged = query(try XCTUnwrap(ArchiveStubProtocol.requests.last?.request))
        XCTAssertEqual(unstaged["against"], "index")
        XCTAssertNil(unstaged["staged"])
        XCTAssertEqual(unstaged["path"], "app")
    }

    func testIdentityNamesItsSource() async throws {
        ArchiveStubProtocol.install { request, _ in
            XCTAssertEqual(request.url?.path, "/v1/git/identity")
            return (200, Data(#"{"name":"Test Person","email":"test@example.com","source":"repository"}"#.utf8))
        }
        let identity = try await (try client()).gitIdentity(projectID: "p", repository: ".")
        XCTAssertEqual(identity, GitIdentity(name: "Test Person", email: "test@example.com", source: .repository))
        XCTAssertTrue(identity.isComplete)
        XCTAssertEqual(identity.formatted, "Test Person <test@example.com>")
        XCTAssertEqual(query(try XCTUnwrap(ArchiveStubProtocol.requests.last?.request)), ["projectId": "p", "path": "."])

        let missing = try ProtocolDecoder.decode(GitIdentity.self, from: Data(#"{"name":"Test Person","email":"","source":"none"}"#.utf8))
        XCTAssertFalse(missing.isComplete)
        let unknown = try ProtocolDecoder.decode(GitIdentity.self, from: Data(#"{"name":"A","email":"a@b","source":"system"}"#.utf8))
        XCTAssertEqual(unknown.source, .none, "A source this version doesn't know claims nothing")
    }

    func testStageAndUnstageSendTheRepositoryAndItsPaths() async throws {
        let api = try client()
        ArchiveStubProtocol.install { request, _ in
            XCTAssertEqual(request.url?.path, "/v1/git/stage")
            return (200, Data(#"{"staged":2}"#.utf8))
        }
        let staged = await api.gitStage(projectID: "p", repository: ".", files: ["a.swift", "new/"])
        XCTAssertEqual(staged, .done(2))
        let stageBody = try json(ArchiveStubProtocol.requests.last?.body)
        XCTAssertEqual(stageBody["projectId"] as? String, "p")
        XCTAssertEqual(stageBody["path"] as? String, ".")
        XCTAssertEqual(stageBody["files"] as? [String], ["a.swift", "new/"])

        ArchiveStubProtocol.install { request, _ in
            XCTAssertEqual(request.url?.path, "/v1/git/unstage")
            return (200, Data(#"{"unstaged":2}"#.utf8))
        }
        let unstaged = await api.gitUnstage(projectID: "p", repository: "app", files: ["b.swift", "old.swift"])
        XCTAssertEqual(unstaged, .done(2))
        XCTAssertEqual(try json(ArchiveStubProtocol.requests.last?.body)["files"] as? [String], ["b.swift", "old.swift"])
    }

    func testCommitSendsTheShownIdentityAndReportsSkippedHooks() async throws {
        let api = try client()
        ArchiveStubProtocol.install { request, _ in
            XCTAssertEqual(request.url?.path, "/v1/git/commit")
            return (200, Data(#"{"commit":"4f2a9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b","hooksSkipped":true}"#.utf8))
        }
        let identity = GitIdentity(name: "Test Person", email: "test@example.com", source: .repository)
        let committed = await api.gitCommit(projectID: "p", repository: ".", message: "Add the fixture\n\n# kept", author: identity)
        guard case let .done(receipt) = committed else { return XCTFail("\(committed)") }
        XCTAssertEqual(receipt.shortHash, "4f2a9c0")
        XCTAssertTrue(receipt.hooksSkipped)
        let body = try json(ArchiveStubProtocol.requests.last?.body)
        XCTAssertEqual(body["message"] as? String, "Add the fixture\n\n# kept")
        XCTAssertEqual(body["author"] as? [String: String], ["name": "Test Person", "email": "test@example.com"])

        _ = await api.gitCommit(projectID: "p", repository: ".", message: "No author")
        XCTAssertNil(try json(ArchiveStubProtocol.requests.last?.body)["author"], "Without an identity the host resolves its own")
    }

    func testRefusalsMapToTheirCodesAndTimeoutsStayUncertain() async throws {
        let api = try client()
        let cases: [(Int, String, GitRefusal)] = [
            (409, "git_busy", .busy), (409, "git_index_locked", .indexLocked), (409, "git_nothing_to_commit", .nothingToCommit),
            (409, "git_identity_missing", .identityMissing), (409, "git_conflict", .conflict),
            (409, "git_filter_unsupported", .filterUnsupported), (409, "git_signing_required", .signingRequired),
            (400, "git_path_invalid", .pathInvalid), (500, "git_failed", .failed),
            (404, "git_repository_not_found", .other(code: "git_repository_not_found", message: "Choose a Git repository inside this workspace"))
        ]
        for (status, code, refusal) in cases {
            let message = refusal == .other(code: "git_repository_not_found", message: "Choose a Git repository inside this workspace")
                ? "Choose a Git repository inside this workspace" : "Refused"
            ArchiveStubProtocol.install { _, _ in (status, Data(#"{"error":{"code":"\#(code)","message":"\#(message)"}}"#.utf8)) }
            let outcome = await api.gitCommit(projectID: "p", repository: ".", message: "m")
            XCTAssertEqual(outcome, .refused(refusal), code)
        }
        ArchiveStubProtocol.install { _, _ in
            (504, Data(#"{"error":{"code":"git_timeout","message":"Git did not finish in time.","outcome":"unknown"}}"#.utf8))
        }
        let timedOut = await api.gitStage(projectID: "p", repository: ".", files: ["a"])
        XCTAssertEqual(timedOut, .uncertain(timedOut: true))
        ArchiveStubProtocol.install { _, _ in throw URLError(.networkConnectionLost) }
        let lost = await api.gitCommit(projectID: "p", repository: ".", message: "m")
        XCTAssertEqual(lost, .uncertain(timedOut: false))
        ArchiveStubProtocol.install { _, _ in throw URLError(.cannotConnectToHost) }
        let unreachable = await api.gitUnstage(projectID: "p", repository: ".", files: ["a"])
        XCTAssertEqual(unreachable, .failed(.unreachable))
        ArchiveStubProtocol.install { _, _ in (400, Data(#"{"error":{"code":"invalid_request","message":"Write a commit message of at most 16 KiB"}}"#.utf8)) }
        let invalid = await api.gitCommit(projectID: "p", repository: ".", message: " ")
        XCTAssertEqual(invalid, .failed(.server(code: "invalid_request", message: "Write a commit message of at most 16 KiB")))
    }
}
