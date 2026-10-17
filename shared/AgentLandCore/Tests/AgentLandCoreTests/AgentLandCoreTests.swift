import Foundation
import XCTest
@testable import AgentLandCore

final class AgentLandCoreTests: XCTestCase {
    func testPresenceUsesAuthenticatedBooleanPayload() async throws {
        let transport = RecordingTransport(result: .success((Data("{\"accepted\":true}".utf8), response(url: "https://host.example/v1/device/presence", status: 200))))
        let client = APIClient(address: try ServerAddress(validating: "https://host.example"), token: "device-token", transport: transport)
        try await client.setPresence(active: true)
        let sent = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.url?.path, "/v1/device/presence")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer device-token")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: try XCTUnwrap(sent.httpBody)) as? [String: Bool], ["active": true])
    }

    /// Hosts that list `presence: ["views"]` take the chat the device shows as `view` (docs/HOST-API.md
    /// "Presence and notices"); both IDs must be 1–256 bytes, or the host refuses the whole heartbeat.
    func testPresenceCarriesTheChatOnScreenAsView() async throws {
        let transport = RecordingTransport(result: .success((Data("{\"accepted\":true}".utf8), response(url: "https://host.example/v1/device/presence", status: 200))))
        let client = APIClient(address: try ServerAddress(validating: "https://host.example"), token: "device-token", transport: transport)
        try await client.setPresence(active: true, view: PresenceView(projectID: "p1", sessionID: "claude:s1"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(transport.requests.first?.httpBody)) as? [String: Any])
        XCTAssertEqual(body as NSDictionary, ["active": true, "view": ["projectId": "p1", "sessionId": "claude:s1"]] as NSDictionary)

        XCTAssertNotNil(PresenceView(projectID: String(repeating: "p", count: 256), sessionID: "s"))
        XCTAssertNil(PresenceView(projectID: String(repeating: "p", count: 257), sessionID: "s"))
        XCTAssertNil(PresenceView(projectID: "p", sessionID: ""))
        XCTAssertNil(PresenceView(projectID: "", sessionID: "s"))

        let listed = try ProtocolDecoder.decode(CapabilitiesResponse.self, from: Data(#"{"interactions":true,"terminal":true,"presence":["views"]}"#.utf8))
        XCTAssertTrue(listed.supportsPresenceViews)
        let older = try ProtocolDecoder.decode(CapabilitiesResponse.self, from: Data(#"{"interactions":true,"terminal":true}"#.utf8))
        XCTAssertFalse(older.supportsPresenceViews, "Hosts that list nothing refuse the member")
        let odd = try ProtocolDecoder.decode(CapabilitiesResponse.self, from: Data(#"{"interactions":true,"terminal":true,"presence":{"views":true}}"#.utf8))
        XCTAssertFalse(odd.supportsPresenceViews)
        XCTAssertEqual(try ProtocolDecoder.decode(CapabilitiesResponse.self, from: JSONEncoder().encode(listed)), listed)
    }
    func testHTTPSAddressRetainsRelayPrefixAndRejectsInsecureOrCredentialBearingURLs() throws {
        let address = try ServerAddress(validating: "https://relay.example/hosts/alpha")
        XCTAssertEqual(address.url.absoluteString, "https://relay.example/hosts/alpha")
        XCTAssertThrowsError(try ServerAddress(validating: "http://host.example")) { XCTAssertEqual($0 as? AddressError, .requiresHTTPS) }
        XCTAssertThrowsError(try ServerAddress(validating: "https://token@host.example")) { XCTAssertEqual($0 as? AddressError, .invalid) }
        XCTAssertThrowsError(try ServerAddress(validating: "https://host.example/?token=secret")) { XCTAssertEqual($0 as? AddressError, .invalid) }
    }

    func testHealthUsesTheDocumentedUnauthenticatedRoute() async throws {
        let response = response(url: "https://host.example/v1/health", status: 200)
        let transport = RecordingTransport(result: .success((Data("{\"status\":\"ok\",\"protocolVersion\":1}".utf8), response)))
        let client = APIClient(address: try ServerAddress(validating: "https://host.example"), token: "secret", transport: transport)

        let health = try await client.health()

        XCTAssertEqual(health.status, "ok")
        XCTAssertEqual(health.protocolVersion, 1)
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(transport.requests[0].url?.path, "/v1/health")
        XCTAssertNil(transport.requests[0].value(forHTTPHeaderField: "Authorization"))
    }

    func testPairAndProjectsUseDocumentedPathsAndBearerAuthentication() async throws {
        let pairTransport = RecordingTransport(result: .success((Data("{\"token\":\"device-token\",\"deviceId\":\"device-1\"}".utf8), response(url: "https://host.example/v1/pair", status: 200))))
        let pairingClient = APIClient(address: try ServerAddress(validating: "https://host.example"), token: "unused", transport: pairTransport)
        let pairing = try await pairingClient.pair(code: "pair-code", deviceName: "My iPhone")
        XCTAssertEqual(pairing.deviceID, "device-1")
        XCTAssertNil(pairTransport.requests[0].value(forHTTPHeaderField: "Authorization"))
        let pairingPayload = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(pairTransport.requests[0].httpBody)) as? [String: String])
        XCTAssertEqual(pairingPayload, ["code": "pair-code", "deviceName": "My iPhone"])

        let projectsTransport = RecordingTransport(result: .success((Data("{\"projects\":[{\"id\":\"app\",\"name\":\"AgentLand\"}]}".utf8), response(url: "https://host.example/v1/projects", status: 200))))
        let projectsClient = APIClient(address: try ServerAddress(validating: "https://host.example"), token: "device-token", transport: projectsTransport)
        let projects = try await projectsClient.projects()
        XCTAssertEqual(projects, [Project(id: "app", name: "AgentLand")])
        XCTAssertEqual(projectsTransport.requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer device-token")
    }

    func testGitExplorerUsesAuthenticatedScopedRoutes() async throws {
        let transport = RecordingTransport(result: .success((Data("{\"branch\":\"main\",\"changes\":[{\"path\":\"README.md\",\"status\":\" M\"}]}".utf8), response(url: "https://host.example/v1/git/status", status: 200))))
        let client = APIClient(address: try ServerAddress(validating: "https://host.example"), token: "device-token", transport: transport)
        let status = try await client.gitStatus(projectID: "p1", repository: "AgentLand")
        XCTAssertEqual(status.branch, "main")
        XCTAssertEqual(status.changes.first?.path, "README.md")
        let sent = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(sent.url?.path, "/v1/git/status")
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(sent.url), resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "path" })?.value, "AgentLand")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer device-token")
    }

    func testCLISessionCreationSelectsMacAgentAndLegacySessionsRemainOpenCode() async throws {
        let transport = RecordingTransport(result: .success((Data("{\"id\":\"claude:one\",\"title\":\"Claude task\",\"projectId\":\"p1\",\"provider\":\"claude\"}".utf8), response(url: "https://host.example/v1/sessions", status: 201))))
        let client = APIClient(address: try ServerAddress(validating: "https://host.example"), token: "device-token", transport: transport)
        let session = try await client.createSession(projectID: "p1", title: "Claude task", provider: "claude")
        XCTAssertEqual(session.provider, "claude")
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(transport.requests.first?.httpBody)) as? [String: String])
        XCTAssertEqual(payload["provider"], "claude")
        let legacy = try JSONDecoder().decode(Session.self, from: Data("{\"id\":\"old\",\"title\":\"Old\",\"projectId\":\"p1\"}".utf8))
        XCTAssertEqual(legacy.provider, "opencode")
    }

    func testRedirectResponseDoesNotBecomeASecondCredentialedRequest() async throws {
        let redirect = response(url: "https://host.example/v1/projects", status: 302, headers: ["Location": "https://attacker.example/collect"])
        let transport = RecordingTransport(result: .success((Data(), redirect)))
        let client = APIClient(address: try ServerAddress(validating: "https://host.example"), token: "device-token", transport: transport)

        do {
            _ = try await client.projects()
            XCTFail("A redirect must not be accepted")
        } catch let error as ClientError {
            XCTAssertEqual(error, .unexpectedStatus(302))
        }
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(transport.requests[0].url?.host, "host.example")
        XCTAssertEqual(transport.requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer device-token")
    }

    func testUncertainMessageMutationIsNotRetried() async throws {
        let transport = RecordingTransport(result: .failure(URLError(.networkConnectionLost)))
        let client = APIClient(address: try ServerAddress(validating: "https://host.example"), token: "device-token", transport: transport)

        let outcome = await client.sendMessage(projectID: "project", sessionID: "session", text: "draft")
        XCTAssertEqual(outcome, .uncertain)
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(transport.requests[0].httpMethod, "POST")
        XCTAssertEqual(transport.requests[0].url?.path, "/v1/messages")
    }

    func testTerminalInputUsesBase64AndDoesNotRetryUncertainDelivery() async throws {
        let transport = RecordingTransport(result: .failure(URLError(.timedOut)))
        let client = APIClient(address: try ServerAddress(validating: "https://host.example"), token: "device-token", transport: transport)

        let outcome = await client.sendTerminalInput(projectID: "project", terminalID: "terminal", data: Data("ls\n".utf8))
        XCTAssertEqual(outcome, .uncertain)
        XCTAssertEqual(transport.requests.count, 1)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(transport.requests[0].httpBody)) as? [String: String])
        XCTAssertEqual(payload["data"], "bHMK")
        XCTAssertEqual(payload["terminalId"], "terminal")
    }

    func testIdentityUsesOnlyAgentLandNamespaces() {
        XCTAssertEqual(ProductIdentity.displayName, "AgentLand")
        XCTAssertEqual(ProductIdentity.bundleIdentifier, "dev.agentland.client")
        XCTAssertEqual(ProductIdentity.keychainService, "dev.agentland.client.device-token")
        XCTAssertEqual(ProductIdentity.connectionsDefaultsKey, "agentland.connections.v1")
        XCTAssertEqual(ProductIdentity.selectedConnectionDefaultsKey, "agentland.selected-connection.v1")
        XCTAssertEqual(ProductIdentity.tabsDefaultsPrefix, "agentland.tabs.")
    }

    func testFileSaveConflictKeepsRevisionAndDoesNotRetry() async throws {
        let conflict = response(url: "https://host.example/v1/file", status: 409)
        let transport = RecordingTransport(result: .success((Data("{\"error\":{\"code\":\"file_conflict\",\"message\":\"Changed\"}}".utf8), conflict)))
        let client = APIClient(address: try ServerAddress(validating: "https://host.example"), token: "token", transport: transport)
        let result = await client.saveFile(projectID: "p", path: "src/main.swift", content: "edit", revision: "old-sha")
        XCTAssertEqual(result, .failure(.conflict))
        XCTAssertEqual(transport.requests.count, 1)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(transport.requests[0].httpBody)) as? [String: String])
        XCTAssertEqual(payload["revision"], "old-sha")
        XCTAssertEqual(payload["path"], "src/main.swift")
    }

    func testWorkspaceTabsAndDraftsAreScopedToConnection() throws {
        let suite = "agentland-test-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WorkspacePersistence(defaults: defaults)
        let first = ConnectionIdentity(host: "https://one.example", deviceID: "device-1")
        let second = ConnectionIdentity(host: "https://two.example", deviceID: "device-2")
        var tab = WorkspaceTab(kind: .editor, projectID: "p", resourceID: "file.txt", title: "file.txt", draft: "edited")
        tab.editorDirty = true
        tab.editorBaseRevision = "original-sha"
        store.save([tab], for: first)
        XCTAssertEqual(store.load(for: first), [tab])
        XCTAssertTrue(store.load(for: second).isEmpty)
        store.save([], for: first)
        XCTAssertTrue(store.load(for: first).isEmpty)
    }

    func testWorkspaceStateRestoresSelectedTabPerConnection() throws {
        let suite = "agentland-test-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WorkspacePersistence(defaults: defaults)
        let first = ConnectionIdentity(host: "https://one.example", deviceID: "device-1")
        let second = ConnectionIdentity(host: "https://two.example", deviceID: "device-2")
        let chat = WorkspaceTab(kind: .chat, projectID: "p", resourceID: "chat", title: "Chat")
        let files = WorkspaceTab(kind: .files, projectID: "p", title: "Files")

        store.save([chat, files], selectedTabID: files.id, for: first)

        XCTAssertEqual(store.loadState(for: first), WorkspaceState(tabs: [chat, files], selectedTabID: files.id))
        XCTAssertEqual(store.loadState(for: second), WorkspaceState())
    }

    func testTwoHomeTabsRemainDistinctAndRestoreSelection() throws {
        let suite = "agentland-home-tabs-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let homeKind = try XCTUnwrap(WorkspaceTabKind(rawValue: "home"))
        let first = WorkspaceTab(kind: homeKind, projectID: "p", title: "Home 2")
        let second = WorkspaceTab(kind: homeKind, projectID: "p", title: "Home 3")
        let identity = ConnectionIdentity(host: "https://one.example", deviceID: "device")

        WorkspacePersistence(defaults: defaults).save([first, second], selectedTabID: second.id, for: identity)
        let restored = WorkspacePersistence(defaults: defaults).loadState(for: identity)

        XCTAssertEqual(restored.tabs.map(\.id), [first.id, second.id])
        XCTAssertEqual(restored.selectedTabID, second.id)
    }

    func testLegacyWorkspaceArrayRestoresFirstTabSelection() throws {
        let suite = "agentland-test-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let identity = ConnectionIdentity(host: "https://one.example", deviceID: "device-1")
        let first = WorkspaceTab(kind: .chat, projectID: "p", resourceID: "chat", title: "Chat")
        let second = WorkspaceTab(kind: .files, projectID: "p", title: "Files")
        let key = ProductIdentity.tabsDefaultsPrefix + "workspace." + Data(identity.storageKey.utf8).base64EncodedString()
        defaults.set(try JSONEncoder().encode([first, second]), forKey: key)

        let restored = WorkspacePersistence(defaults: defaults).loadState(for: identity)

        XCTAssertEqual(restored.tabs, [first, second])
        XCTAssertEqual(restored.selectedTabID, first.id)
    }

    func testOldWorkspaceTabDecodesWithoutNewEditorFields() throws {
        let data = Data("{\"id\":\"00000000-0000-0000-0000-000000000001\",\"kind\":\"chat\",\"projectID\":\"p\",\"resourceID\":\"s\",\"title\":\"Session\",\"draft\":\"hello\"}".utf8)
        let tab = try JSONDecoder().decode(WorkspaceTab.self, from: data)
        XCTAssertFalse(tab.editorDirty)
        XCTAssertNil(tab.editorBaseRevision)
        XCTAssertEqual(tab.draft, "hello")
    }

    func testRestoredEditorDraftDoesNotAdoptNewRemoteRevision() {
        var tab = WorkspaceTab(kind: .editor, projectID: "p", resourceID: "file.txt", title: "file.txt", draft: "local edit")
        tab.editorDirty = true
        tab.editorBaseRevision = "before-edit"
        XCTAssertEqual(EditorRevisionPolicy.saveRevision(for: tab, remoteRevision: "newer-on-host"), "before-edit")
        XCTAssertTrue(EditorRevisionPolicy.remoteChanged(since: tab, remoteRevision: "newer-on-host"))
        tab.editorBaseRevision = nil
        XCTAssertEqual(EditorRevisionPolicy.saveRevision(for: tab, remoteRevision: "newer-on-host"), "")
        XCTAssertTrue(EditorRevisionPolicy.remoteChanged(since: tab, remoteRevision: "newer-on-host"))
    }

    func testTerminalPasteChunksPreserveUTF8ScalarBoundariesAndSizeLimit() throws {
        let input = Data(String(repeating: "é", count: 20_000).utf8)
        let chunks = try TerminalInputChunker.chunks(input)
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks.reduce(Data(), +), input)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 32_768 && String(data: $0, encoding: .utf8) != nil })
        XCTAssertThrowsError(try TerminalInputChunker.chunks(Data(repeating: 65, count: 262_145))) { XCTAssertEqual($0 as? TerminalInputChunkError, .tooLarge) }
        XCTAssertThrowsError(try TerminalInputChunker.chunks(Data([0xff]))) { XCTAssertEqual($0 as? TerminalInputChunkError, .invalidUTF8) }
    }

    private func response(url: String, status: Int, headers: [String: String]? = nil) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: url)!, statusCode: status, httpVersion: nil, headerFields: headers)!
    }
}

private final class RecordingTransport: APITransport, @unchecked Sendable {
    private let result: Result<(Data, HTTPURLResponse), Error>
    private let lock = NSLock()
    private var storage: [URLRequest] = []

    init(result: Result<(Data, HTTPURLResponse), Error>) { self.result = result }
    var requests: [URLRequest] { lock.withLock { storage } }

    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { storage.append(request) }
        return try result.get()
    }
}
