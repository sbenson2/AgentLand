import Foundation
import XCTest
@testable import AgentLandCore

/// The file change routes (docs/HOST-API.md, "Files") through a real `URLSession` answered by the stub
/// protocol, so bodies, queries and headers are the ones production sends.
final class FileChangesClientTests: XCTestCase {
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

    private static func refusal(_ code: String, _ message: String, extra: String = "") -> Data {
        Data(#"{"error":{"code":"\#(code)","message":"\#(message)"\#(extra)}}"#.utf8)
    }

    // MARK: Capabilities and entries

    func testCapabilitiesListFileAndGitFeatures() throws {
        let body = #"{"interactions":true,"terminal":true,"files":["move","mkdir","upload","trash","delete","search"],"git":["stage","unstage","commit","stagedDiff","unstagedDiff","identity","branches","history","remotes","stashes","discard","untrackedFiles"]}"#
        let capabilities = try ProtocolDecoder.decode(CapabilitiesResponse.self, from: Data(body.utf8))
        XCTAssertTrue(FileFeature.allCases.allSatisfy(capabilities.supportsFiles))
        XCTAssertTrue(GitFeature.allCases.allSatisfy(capabilities.supportsGit))

        let older = try ProtocolDecoder.decode(CapabilitiesResponse.self, from: Data(#"{"interactions":true,"terminal":false}"#.utf8))
        XCTAssertFalse(FileFeature.allCases.contains(where: older.supportsFiles), "A host that lists nothing claims nothing")
        XCTAssertFalse(GitFeature.allCases.contains(where: older.supportsGit))
        let unreadable = try ProtocolDecoder.decode(CapabilitiesResponse.self, from: Data(#"{"interactions":true,"terminal":false,"git":{"stage":true}}"#.utf8))
        XCTAssertEqual(unreadable.git, [], "A git entry this version cannot read offers nothing")
    }

    func testEntriesReadAModifiedTimeOnlyWhenTheHostSendsOne() throws {
        let listing = #"{"entries":[{"name":"a.txt","path":"a.txt","isDirectory":false,"size":3},{"name":"b.txt","path":"b.txt","isDirectory":false,"size":4,"modifiedAt":"2026-09-24T10:15:30.250Z"},{"name":"c","path":"c","isDirectory":true,"size":0,"modifiedAt":17}]}"#
        let entries = try ProtocolDecoder.decode(FilesResponse.self, from: Data(listing.utf8)).entries
        XCTAssertEqual(entries.map(\.name), ["a.txt", "b.txt", "c"], "An unreadable time never costs the entry")
        XCTAssertNil(entries[0].modifiedAt)
        XCTAssertEqual(entries[1].modifiedAt?.timeIntervalSince1970 ?? 0, 1_790_244_930.25, accuracy: 0.001)
        XCTAssertNil(entries[2].modifiedAt)
        let reencoded = try ProtocolDecoder.decode(FileEntry.self, from: JSONEncoder().encode(entries[1]))
        XCTAssertEqual(reencoded, entries[1])
    }

    // MARK: Move, rename and new folders

    func testMoveSendsBothPathsAndAnswersTheEntryAtItsNewPlace() async throws {
        ArchiveStubProtocol.install { request, _ in
            XCTAssertEqual(request.url?.path, "/v1/files/move")
            return (200, Data(#"{"name":"notes.md","path":"docs/notes.md","isDirectory":false,"size":12}"#.utf8))
        }
        let outcome = await (try client()).moveFile(projectID: "p", from: "notes.md", to: "docs/notes.md")
        XCTAssertEqual(outcome, .done(FileEntry(name: "notes.md", path: "docs/notes.md", isDirectory: false, size: 12)))
        let sent = try XCTUnwrap(ArchiveStubProtocol.requests.last)
        XCTAssertEqual(sent.request.httpMethod, "POST")
        XCTAssertEqual(sent.request.value(forHTTPHeaderField: "Authorization"), "Bearer device-token")
        XCTAssertEqual(try json(sent.body) as? [String: String], ["projectId": "p", "from": "notes.md", "to": "docs/notes.md"])
    }

    func testATakenNameIsReportedWithTheHostsSuggestion() async throws {
        let api = try client()
        ArchiveStubProtocol.install { _, _ in
            (409, Self.refusal("file_exists", "An item with that name already exists; choose another name", extra: #","suggestedName":"notes 2.md""#))
        }
        let moved = await api.moveFile(projectID: "p", from: "a.md", to: "notes.md")
        XCTAssertEqual(moved, .nameTaken(suggestedName: "notes 2.md"))

        ArchiveStubProtocol.install { request, _ in
            XCTAssertEqual(request.url?.path, "/v1/files/mkdir")
            return (409, Self.refusal("file_exists", "A file or folder with that name already exists"))
        }
        let folder = await api.makeFolder(projectID: "p", path: "Sources")
        XCTAssertEqual(folder, .nameTaken(suggestedName: nil), "Without a suggestion the name is still taken")
        XCTAssertEqual(try json(ArchiveStubProtocol.requests.last?.body) as? [String: String], ["projectId": "p", "path": "Sources"])

        ArchiveStubProtocol.install { _, _ in (201, Data(#"{"name":"Sources","path":"Sources","isDirectory":true,"size":0}"#.utf8)) }
        let made = await api.makeFolder(projectID: "p", path: "Sources")
        XCTAssertEqual(made, .done(FileEntry(name: "Sources", path: "Sources", isDirectory: true, size: 0)))
    }

    func testOtherRefusalsFailAndLostAnswersAreNotConfirmed() async throws {
        let api = try client()
        for (status, code, message) in [(400, "invalid_move", "A folder can't be moved into itself"),
                                        (409, "cross_volume", "Items can't be moved to another volume here"),
                                        (404, "file_not_found", "The file no longer exists"),
                                        (400, "invalid_path", "Choose a relative path inside the project, not the project folder itself")] {
            ArchiveStubProtocol.install { _, _ in (status, Self.refusal(code, message)) }
            let outcome = await api.moveFile(projectID: "p", from: "a", to: "b")
            XCTAssertEqual(outcome, .failed(.server(code: code, message: message)), code)
        }
        ArchiveStubProtocol.install { _, _ in throw URLError(.networkConnectionLost) }
        let lost = await api.moveFile(projectID: "p", from: "a", to: "b")
        XCTAssertEqual(lost, .uncertain)
        ArchiveStubProtocol.install { _, _ in throw URLError(.cannotConnectToHost) }
        let unreachable = await api.makeFolder(projectID: "p", path: "new")
        XCTAssertEqual(unreachable, .failed(.unreachable))
        ArchiveStubProtocol.install { _, _ in (502, Data("Bad gateway".utf8)) }
        let proxy = await api.makeFolder(projectID: "p", path: "new")
        XCTAssertEqual(proxy, .uncertain, "A 5xx without the host's envelope may have been made")
    }

    // MARK: Uploads

    private func stubbedTransport() -> URLSessionTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ArchiveStubProtocol.self]
        return URLSessionTransport(expectedHost: nil, certificateSHA256: nil, validatedCertificateHost: nil, configuration: configuration)
    }

    private func temporaryFile(_ bytes: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "upload-\(UUID().uuidString).bin")
        try bytes.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testUploadStreamsTheFileWithItsLengthAndReportsProgress() async throws {
        let bytes = Data((0..<70_000).map { UInt8($0 % 251) })
        let file = try temporaryFile(bytes)
        ArchiveStubProtocol.install { request, body in
            XCTAssertEqual(request.url?.path, "/v1/files/upload")
            XCTAssertEqual(body, bytes, "The file's bytes are the body, unchanged")
            return (201, Data(#"{"name":"photo.jpg","path":"assets/photo.jpg","isDirectory":false,"size":70000}"#.utf8))
        }
        let api = APIClient(address: try ServerAddress(validating: "https://mac.example:9841"), token: "device-token", transport: stubbedTransport())
        let reports = ProgressLog()
        let outcome = await api.uploadFile(projectID: "p", path: "assets/photo.jpg", from: file) { sent, total in reports.add(sent, total) }
        XCTAssertEqual(outcome, .done(FileEntry(name: "photo.jpg", path: "assets/photo.jpg", isDirectory: false, size: 70_000)))
        let sent = try XCTUnwrap(ArchiveStubProtocol.requests.last)
        XCTAssertEqual(sent.request.httpMethod, "POST")
        XCTAssertEqual(query(sent.request), ["projectId": "p", "path": "assets/photo.jpg"])
        XCTAssertEqual(sent.request.value(forHTTPHeaderField: "Content-Type"), "application/octet-stream")
        XCTAssertEqual(sent.request.value(forHTTPHeaderField: "Authorization"), "Bearer device-token")
        XCTAssertEqual(reports.last?.sent, 70_000)
        XCTAssertEqual(reports.last?.total, 70_000, "Progress ends at the whole file")
        XCTAssertTrue(reports.all.allSatisfy { $0.sent <= $0.total })
    }

    func testUploadRefusalsAndATakenName() async throws {
        let file = try temporaryFile(Data("hello".utf8))
        let api = try client()
        ArchiveStubProtocol.install { request, body in
            XCTAssertEqual(body, Data("hello".utf8))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Length"), "5")
            return (409, Self.refusal("file_exists", "A file with that name already exists; the upload did not replace it",
                                      extra: #","suggestedName":"hello 2.txt""#))
        }
        let taken = await api.uploadFile(projectID: "p", path: "hello.txt", from: file)
        XCTAssertEqual(taken, .nameTaken(suggestedName: "hello 2.txt"))
        for (status, code, message) in [(413, "file_too_large", "Uploads are limited to 256 MiB"),
                                        (429, "upload_limit", "Wait for this device's other uploads to finish (2 at a time)"),
                                        (507, "insufficient_storage", "The Mac needs at least 1 GiB of free space left after this change"),
                                        (400, "upload_incomplete", "The upload did not complete; nothing was saved")] {
            ArchiveStubProtocol.install { _, _ in (status, Self.refusal(code, message)) }
            let outcome = await api.uploadFile(projectID: "p", path: "hello.txt", from: file)
            XCTAssertEqual(outcome, .failed(.server(code: code, message: message)), code)
        }
        ArchiveStubProtocol.install { _, _ in throw URLError(.timedOut) }
        let timedOut = await api.uploadFile(projectID: "p", path: "hello.txt", from: file)
        XCTAssertEqual(timedOut, .uncertain, "A timed-out upload may have landed; the folder is read again instead")
    }

    // MARK: Deletes

    func testDeleteGoesToTheTrashAndAPermanentDeleteRepeatsThePath() async throws {
        let api = try client()
        ArchiveStubProtocol.install { _, _ in (200, Data(#"{"path":"old/a.txt","trashed":true,"trashName":"a 2.txt"}"#.utf8)) }
        let trashed = await api.deleteFile(projectID: "p", path: "old/a.txt")
        XCTAssertEqual(trashed, .trashed(trashName: "a 2.txt"))
        XCTAssertEqual(try json(ArchiveStubProtocol.requests.last?.body) as? [String: String], ["projectId": "p", "path": "old/a.txt"],
                       "A Trash delete sends neither permanent nor confirmPath")

        ArchiveStubProtocol.install { _, _ in
            (409, Self.refusal("trash_unavailable", "This item can't be moved to the Trash; it can be deleted permanently instead",
                               extra: #","permanentDeleteAllowed":true"#))
        }
        let unavailable = await api.deleteFile(projectID: "p", path: "old/a.txt")
        XCTAssertEqual(unavailable, .trashUnavailable(permanentDeleteAllowed: true))

        ArchiveStubProtocol.install { _, _ in (200, Data(#"{"path":"old/a.txt","trashed":false}"#.utf8)) }
        let deleted = await api.deleteFile(projectID: "p", path: "old/a.txt", permanent: true)
        XCTAssertEqual(deleted, .deleted)
        let body = try json(ArchiveStubProtocol.requests.last?.body)
        XCTAssertEqual(body["permanent"] as? Bool, true)
        XCTAssertEqual(body["confirmPath"] as? String, "old/a.txt")
        XCTAssertEqual(body["path"] as? String, "old/a.txt")

        ArchiveStubProtocol.install { _, _ in (400, Self.refusal("invalid_path", "Choose a relative path inside the project, not the project folder itself")) }
        let root = await api.deleteFile(projectID: "p", path: ".")
        XCTAssertEqual(root, .failed(.server(code: "invalid_path", message: "Choose a relative path inside the project, not the project folder itself")))
        ArchiveStubProtocol.install { _, _ in throw URLError(.networkConnectionLost) }
        let lost = await api.deleteFile(projectID: "p", path: "a.txt")
        XCTAssertEqual(lost, .uncertain)
        ArchiveStubProtocol.install { _, _ in throw URLError(.cannotFindHost) }
        let unreachable = await api.deleteFile(projectID: "p", path: "a.txt")
        XCTAssertEqual(unreachable, .failed(.unreachable))
    }

    // MARK: Search

    func testSearchSendsItsOptionsOnlyWhenSet() async throws {
        let api = try client()
        ArchiveStubProtocol.install { _, _ in
            (200, Data(#"{"results":[{"path":"Sources/a.swift","matches":[{"line":12,"column":5,"preview":"let needle = 1"}],"truncated":true}],"truncatedReason":"matches"}"#.utf8))
        }
        let plain = try await api.searchFiles(projectID: "p", options: FileSearchOptions(query: "needle"))
        XCTAssertEqual(query(try XCTUnwrap(ArchiveStubProtocol.requests.last?.request)), ["projectId": "p", "q": "needle"])
        XCTAssertEqual(plain.results.first?.matches.first, FileSearchMatch(line: 12, column: 5, preview: "let needle = 1"))
        XCTAssertEqual(plain.results.first?.truncated, true)
        XCTAssertEqual(plain.limit, .matches)

        _ = try await api.searchFiles(projectID: "p", options: FileSearchOptions(query: "ne+dle", path: "Sources", regex: true,
                                                                                caseSensitive: true, include: ["*.swift", " ", "docs/*.md"]))
        XCTAssertEqual(query(try XCTUnwrap(ArchiveStubProtocol.requests.last?.request)),
                       ["projectId": "p", "q": "ne+dle", "path": "Sources", "regex": "true", "caseSensitive": "true", "include": "*.swift,docs/*.md"])
    }

    func testSearchOptionsFollowTheHostsLimits() {
        XCTAssertFalse(FileSearchOptions(query: "").isValid)
        XCTAssertTrue(FileSearchOptions(query: String(repeating: "a", count: 512)).isValid)
        XCTAssertFalse(FileSearchOptions(query: String(repeating: "a", count: 513)).isValid)
        XCTAssertFalse(FileSearchOptions(query: String(repeating: "é", count: 257)).isValid, "The limit is in bytes")
        XCTAssertFalse(FileSearchOptions(query: "two\nlines").isValid)
        XCTAssertTrue(FileSearchOptions(query: "a", include: Array(repeating: "*.md", count: 16)).isValid)
        XCTAssertFalse(FileSearchOptions(query: "a", include: Array(repeating: "*.md", count: 17)).isValid)
        XCTAssertFalse(FileSearchOptions(query: "a", include: [String(repeating: "x", count: 257)]).isValid)
        XCTAssertEqual(FileSearchLimit(rawValue: "time")?.explanation.isEmpty, false)
    }
}

/// Progress reports from the transport's thread.
final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var reports: [(sent: Int64, total: Int64)] = []
    func add(_ sent: Int64, _ total: Int64) { lock.withLock { reports.append((sent, total)) } }
    var all: [(sent: Int64, total: Int64)] { lock.withLock { reports } }
    var last: (sent: Int64, total: Int64)? { all.last }
}
