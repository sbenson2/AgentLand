import Foundation
import XCTest
@testable import AgentLandCore

/// The vault (docs/HOST-API.md "Vault"): `capabilities.vault`, `GET /v1/vault` and its settings and rebuild with their
/// refusals, through a real `URLSession` answered by the stub protocol, so methods and bodies are the ones production
/// sends.
final class VaultClientTests: XCTestCase {
    private func client() throws -> APIClient {
        APIClient(address: try ServerAddress(validating: "https://mac.example:9841"), token: "local-token", transport: ArchiveStubTransport())
    }

    private func json(_ data: Data?) throws -> NSDictionary {
        try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(data)) as? NSDictionary)
    }

    private static func refusal(_ code: String, _ message: String = "Refused") -> Data {
        Data(#"{"error":{"code":"\#(code)","message":"\#(message)"}}"#.utf8)
    }

    /// The status as the host answers it while it writes the first notes.
    static let writing = #"""
    {"enabled": true, "folder": "/Users/owner/AgentLand Vault", "defaultFolder": "/Users/owner/AgentLand Vault",
     "terminals": true, "state": "writing", "notes": 120, "bytes": 1534000, "pending": 220, "skipped": 2,
     "backfill": {"done": 120, "total": 340}, "lastWriteAt": "2026-10-12T12:00:00.000Z",
     "obsidianVault": "/Users/owner/Notes"}
    """#

    // MARK: Capabilities

    func testTheCapabilityIsReadOnlyAtVersionOne() throws {
        func vault(_ entry: String) throws -> VaultCapabilities? {
            try ProtocolDecoder.decode(CapabilitiesResponse.self, from: Data(#"{"interactions":true,"terminal":true\#(entry)}"#.utf8)).vault
        }
        XCTAssertEqual(try vault(#","vault":{"version":1}"#), VaultCapabilities(version: 1))
        XCTAssertEqual(try vault(#","vault":{"version":1,"later":true}"#)?.version, 1, "Members this version does not know are ignored")
        XCTAssertNil(try vault(""), "A host without a vault, or a paired device's session, lists none")
        XCTAssertNil(try vault(#","vault":{"version":2}"#), "Another version offers nothing")
        XCTAssertNil(try vault(#","vault":{}"#))
        XCTAssertNil(try vault(#","vault":true"#), "An entry this version cannot read offers nothing")
        XCTAssertNil(try vault(#","vault":null"#))
        XCTAssertNil(CapabilitiesResponse(interactions: true, terminal: true).vault)
        XCTAssertEqual(CapabilitiesResponse(interactions: true, terminal: true, vault: VaultCapabilities()).vault?.version, 1)

        // The entry survives the app's own copy of the capabilities.
        let kept = CapabilitiesResponse(interactions: true, terminal: true, vault: VaultCapabilities())
        let read = try ProtocolDecoder.decode(CapabilitiesResponse.self, from: try JSONEncoder().encode(kept))
        XCTAssertEqual(read.vault, VaultCapabilities())
    }

    // MARK: Reading

    func testTheStatusReadsTheContractsFields() async throws {
        ArchiveStubProtocol.install { request, _ in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/v1/vault")
            XCTAssertNil(request.url?.query)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer local-token")
            return (200, Data(Self.writing.utf8))
        }
        let status = try await (try client()).vault()
        XCTAssertEqual(status, VaultStatus(enabled: true, folder: "/Users/owner/AgentLand Vault", defaultFolder: "/Users/owner/AgentLand Vault",
                                           terminals: true, state: .writing, notes: 120, bytes: 1_534_000, pending: 220, skipped: 2,
                                           backfill: VaultBackfill(done: 120, total: 340),
                                           lastWriteAt: ChatTime.date("2026-10-12T12:00:00.000Z"), obsidianVault: "/Users/owner/Notes"))
        XCTAssertTrue(status.backfill.isRunning)
        XCTAssertNil(status.reason)

        ArchiveStubProtocol.install { _, _ in
            (200, Data(#"""
            {"enabled": true, "folder": "/Volumes/Gone/Vault", "defaultFolder": "/Users/owner/AgentLand Vault", "terminals": false,
             "state": "paused", "reason": "folder_missing", "message": "The vault's folder is missing", "notes": 0, "bytes": 0,
             "pending": 0, "skipped": 0, "backfill": {"done": 0, "total": 0}}
            """#.utf8))
        }
        let paused = try await (try client()).vault()
        XCTAssertEqual(paused.state, .paused)
        XCTAssertEqual(paused.reason, .folderMissing)
        XCTAssertEqual(paused.message, "The vault's folder is missing")
        XCTAssertFalse(paused.terminals)
        XCTAssertNil(paused.lastWriteAt)
        XCTAssertNil(paused.obsidianVault)
        XCTAssertFalse(paused.backfill.isRunning)
    }

    func testEveryStateAndReasonIsReadAndUnknownOnesAreUnknown() async throws {
        let states: [(String, VaultState)] = [("off", .off), ("writing", .writing), ("current", .current), ("paused", .paused),
                                              ("resting", .unknown), ("", .unknown)]
        for (wire, state) in states {
            let status = try ProtocolDecoder.decode(VaultStatus.self, from: Data(#"{"enabled":true,"state":"\#(wire)"}"#.utf8))
            XCTAssertEqual(status.state, state, wire)
        }
        let reasons: [(String, VaultPauseReason)] = [("folder_missing", .folderMissing), ("permission", .permission), ("low_space", .lowSpace),
                                                     ("other_archive", .otherArchive), ("error", .error), ("melted", .unknown)]
        for (wire, reason) in reasons {
            let status = try ProtocolDecoder.decode(VaultStatus.self, from: Data(#"{"enabled":true,"state":"paused","reason":"\#(wire)"}"#.utf8))
            XCTAssertEqual(status.reason, reason, wire)
        }
    }

    func testFieldsItCannotReadAreLeftAtTheirDefaults() throws {
        let status = try ProtocolDecoder.decode(VaultStatus.self, from: Data(#"""
        {"enabled": false, "later": {"x": 1}, "folder": 7, "defaultFolder": "/Users/owner/AgentLand Vault", "terminals": "yes",
         "state": 3, "reason": 9, "message": "  ", "notes": -4, "bytes": "big", "pending": 1.5, "skipped": null,
         "backfill": {"done": 9, "total": -1}, "lastWriteAt": "yesterday", "obsidianVault": ""}
        """#.utf8))
        XCTAssertEqual(status, VaultStatus(enabled: false, folder: "", defaultFolder: "/Users/owner/AgentLand Vault", terminals: true,
                                           state: .unknown, notes: 0, bytes: 0, pending: 0, skipped: 0, backfill: VaultBackfill(done: 9, total: 0)))
        XCTAssertNil(status.message, "Blank words are no message")
        XCTAssertNil(status.obsidianVault)
        XCTAssertFalse(status.backfill.isRunning)

        let minimal = try ProtocolDecoder.decode(VaultStatus.self, from: Data(#"{"enabled":false}"#.utf8))
        XCTAssertEqual(minimal, VaultStatus(enabled: false), "Terminals get notes unless the host says otherwise")
        XCTAssertTrue(minimal.terminals)
        XCTAssertEqual(minimal.state, .unknown)
    }

    func testAStatusWithoutEnabledCannotBeRead() async throws {
        for body in [#"{"state":"off"}"#, #"{"enabled":"on","state":"off"}"#, #"[]"#] {
            ArchiveStubProtocol.install { _, _ in (200, Data(body.utf8)) }
            do {
                _ = try await (try client()).vault()
                XCTFail("Not an answer this version can read: \(body)")
            } catch {
                XCTAssertEqual(error as? ClientError, .decoding, body)
            }
        }
    }

    func testAHostWithoutAVaultSaysSo() async throws {
        ArchiveStubProtocol.install { _, _ in (503, Self.refusal("vault_unavailable", "This host keeps no archive, so it has no vault")) }
        do {
            _ = try await (try client()).vault()
            XCTFail("503 throws")
        } catch let error as ClientError {
            XCTAssertTrue(error.isVaultUnavailable)
        }
        XCTAssertFalse(ClientError.server(code: "local_only", message: "Only this Mac").isVaultUnavailable)
        XCTAssertFalse(ClientError.unexpectedStatus(503).isVaultUnavailable)
    }

    // MARK: Changes

    func testChangesSendOnlyWhatChangesAndAnswerTheStatus() async throws {
        let api = try client()
        ArchiveStubProtocol.install { request, _ in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            return (200, Data(Self.writing.utf8))
        }
        let on = await api.setVault(enabled: true)
        guard case let .changed(status) = on else { return XCTFail("200 answers the status") }
        XCTAssertEqual(status.state, .writing)
        var sent = try XCTUnwrap(ArchiveStubProtocol.requests.last)
        XCTAssertEqual(sent.request.httpMethod, "POST")
        XCTAssertEqual(sent.request.url?.path, "/v1/vault/settings")
        XCTAssertEqual(try json(sent.body), ["enabled": true])

        _ = await api.setVault(folder: "/Users/owner/Notes/AgentLand")
        XCTAssertEqual(try json(ArchiveStubProtocol.requests.last?.body), ["folder": "/Users/owner/Notes/AgentLand"])
        _ = await api.setVault(folder: "")
        XCTAssertEqual(try json(ArchiveStubProtocol.requests.last?.body), ["folder": ""], "An empty folder is the default")
        _ = await api.setVault(terminals: false)
        XCTAssertEqual(try json(ArchiveStubProtocol.requests.last?.body), ["terminals": false])
        _ = await api.setVault(enabled: true, folder: "/Users/owner/Vault", terminals: true, adopt: true)
        XCTAssertEqual(try json(ArchiveStubProtocol.requests.last?.body),
                       ["enabled": true, "folder": "/Users/owner/Vault", "terminals": true, "adopt": true])
        _ = await api.setVault(adopt: true)
        XCTAssertEqual(try json(ArchiveStubProtocol.requests.last?.body), ["adopt": true])

        ArchiveStubProtocol.install { _, _ in (200, Data(Self.writing.utf8)) }
        let rebuilt = await api.rebuildVault()
        XCTAssertEqual(rebuilt, .changed(try ProtocolDecoder.decode(VaultStatus.self, from: Data(Self.writing.utf8))))
        sent = try XCTUnwrap(ArchiveStubProtocol.requests.last)
        XCTAssertEqual(sent.request.httpMethod, "POST")
        XCTAssertEqual(sent.request.url?.path, "/v1/vault/rebuild")
        XCTAssertTrue(sent.body?.isEmpty ?? true, "A rebuild sends no body")

        // A change without anything to change is never sent (the host would refuse it).
        ArchiveStubProtocol.install { _, _ in XCTFail("Nothing to change is never sent"); return (200, Data()) }
        let nothing = await api.setVault()
        XCTAssertEqual(nothing, .failed(.invalidResponse))
        let adoptFalse = await api.setVault(adopt: false)
        XCTAssertEqual(adoptFalse, .failed(.invalidResponse), "adopt goes out only when true")
    }

    func testRefusalsAreNamedByTheirCodeAndStatus() async throws {
        let api = try client()
        let cases: [(Int, String, VaultRefusal)] = [
            (400, "invalid_folder", .invalidFolder), (409, "folder_unwritable", .folderUnwritable), (409, "vault_off", .off),
            (503, "vault_unavailable", .unavailable), (403, "local_only", .localOnly),
        ]
        for (status, code, reason) in cases {
            XCTAssertEqual(reason.status, status)
            ArchiveStubProtocol.install { _, _ in (status, Self.refusal(code, "Words for \(code).")) }
            let changed = await api.setVault(folder: "/Users/owner/Vault")
            XCTAssertEqual(changed, .refused(reason, message: "Words for \(code)."), code)
            let rebuilt = await api.rebuildVault()
            XCTAssertEqual(rebuilt, .refused(reason, message: "Words for \(code)."), code)
        }

        // A known code with another status is not that refusal.
        ArchiveStubProtocol.install { _, _ in (400, Self.refusal("vault_off", "Odd.")) }
        var outcome = await api.rebuildVault()
        XCTAssertEqual(outcome, .failed(.server(code: "vault_off", message: "Odd.")))
        // A request the host could not take changed nothing.
        ArchiveStubProtocol.install { _, _ in (400, Self.refusal("invalid_request", "Send enabled, folder, terminals or adopt")) }
        outcome = await api.setVault(terminals: true)
        XCTAssertEqual(outcome, .failed(.server(code: "invalid_request", message: "Send enabled, folder, terminals or adopt")))
        // `vault_error` may come after the settings were saved and the writer restarted: not confirmed either way.
        ArchiveStubProtocol.install { _, _ in (500, Self.refusal(VaultErrorCode.storage, "The vault's settings or records could not be read or saved")) }
        outcome = await api.setVault(enabled: true)
        XCTAssertEqual(outcome, .uncertain)
        outcome = await api.rebuildVault()
        XCTAssertEqual(outcome, .uncertain)
        ArchiveStubProtocol.install { _, _ in (502, Data()) }
        outcome = await api.setVault(enabled: false)
        XCTAssertEqual(outcome, .uncertain)
    }

    func testLostAnswersAreUncertainAndUndeliveredRequestsFail() async throws {
        let api = try client()
        ArchiveStubProtocol.install { _, _ in throw URLError(.networkConnectionLost) }
        var outcome = await api.setVault(enabled: true)
        XCTAssertEqual(outcome, .uncertain, "A lost connection may have delivered it")
        ArchiveStubProtocol.install { _, _ in throw URLError(.timedOut) }
        outcome = await api.rebuildVault()
        XCTAssertEqual(outcome, .uncertain)
        ArchiveStubProtocol.install { _, _ in throw URLError(.cannotConnectToHost) }
        outcome = await api.setVault(terminals: false)
        XCTAssertEqual(outcome, .failed(.unreachable), "Provably not sent")

        // The host made the change, but its answer cannot be read: what it keeps now is unknown.
        ArchiveStubProtocol.install { _, _ in (200, Data("done".utf8)) }
        outcome = await api.setVault(enabled: false)
        XCTAssertEqual(outcome, .uncertain)
        ArchiveStubProtocol.install { _, _ in (200, Data(#"{"state":"off"}"#.utf8)) }
        outcome = await api.rebuildVault()
        XCTAssertEqual(outcome, .uncertain)
    }
}
