import Foundation
import XCTest
@testable import AgentLandCore

final class GitManagementClientTests: XCTestCase {
    private func client() throws -> APIClient {
        APIClient(address: try ServerAddress(validating: "https://mac.example:9841"), token: "device-token", transport: ArchiveStubTransport())
    }

    func testManagementMutationSendsScopedNamesAndNeverRetriesTimeout() async throws {
        ArchiveStubProtocol.install { request, body in
            XCTAssertEqual(request.url?.path, "/v1/git/branch")
            let value = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(body)) as? [String: Any])
            XCTAssertEqual(value["projectId"] as? String, "p")
            XCTAssertEqual(value["path"] as? String, "repo")
            XCTAssertEqual(value["name"] as? String, "feature/tree")
            XCTAssertEqual(value["action"] as? String, "create")
            return (504, Data(#"{"error":{"code":"git_timeout","message":"Check status","outcome":"unknown"}}"#.utf8))
        }
        let outcome = await (try client()).gitBranch(projectID: "p", repository: "repo", action: .create, name: "feature/tree")
        XCTAssertEqual(outcome, .uncertain(timedOut: true))
        XCTAssertEqual(ArchiveStubProtocol.requests.count, 1)
    }

    func testHistoryPagingAndStashModelsDecode() async throws {
        ArchiveStubProtocol.install { request, _ in
            XCTAssertEqual(request.url?.path, "/v1/git/history")
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertEqual(items.first { $0.name == "cursor" }?.value, "30")
            return (200, Data(#"{"commits":[{"hash":"abcdef","subject":"Change","author":"Ada","timestamp":42}],"nextCursor":"60"}"#.utf8))
        }
        let page = try await (try client()).gitHistory(projectID: "p", repository: ".", cursor: "30")
        XCTAssertEqual(page.commits.first?.subject, "Change")
        XCTAssertEqual(page.nextCursor, "60")
        let older = try ProtocolDecoder.decode(CapabilitiesResponse.self, from: Data(#"{"chatFeatures":[],"chatProviders":[],"interactions":false,"terminal":false,"terminalPrograms":[]}"#.utf8))
        XCTAssertFalse(older.supportsGit(.branches))
        XCTAssertFalse(older.supportsGit(.stashes))
    }

    func testDiscardRequiresExplicitConfirmationInBody() async throws {
        ArchiveStubProtocol.install { request, body in
            XCTAssertEqual(request.url?.path, "/v1/git/discard")
            let value = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(body)) as? [String: Any])
            XCTAssertEqual(value["confirmed"] as? Bool, true)
            XCTAssertEqual(value["files"] as? [String], ["a.swift"])
            return (200, Data(#"{"changed":true}"#.utf8))
        }
        let outcome = await (try client()).gitDiscard(projectID: "p", repository: ".", files: ["a.swift"], confirmed: true)
        XCTAssertEqual(outcome, .done(GitManagementReceipt(changed: true)))
    }

    func testUnspecifiedFailureKeepsUnknownOutcomeDistinctFromTimeout() async throws {
        ArchiveStubProtocol.install { _, _ in
            (409, Data(#"{"error":{"code":"git_remote_failed","message":"Not confirmed","outcome":"unknown"}}"#.utf8))
        }
        let outcome = await (try client()).gitRemote(projectID: "p", repository: ".", action: .push, remote: "origin")
        XCTAssertEqual(outcome, .uncertain(timedOut: false))
        XCTAssertEqual(ArchiveStubProtocol.requests.count, 1)
    }
}
