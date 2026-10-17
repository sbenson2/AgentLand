import Foundation
import XCTest
@testable import AgentLandCore

private actor WebLaunchTransport: APITransport {
    let launchURL: String
    var requests: [URLRequest] = []
    init(_ launchURL: String) { self.launchURL = launchURL }
    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let body: [String: Any] = request.url!.path.hasSuffix("/import") ? ["imported": true] : ["url": launchURL]
        return (try JSONSerialization.data(withJSONObject: body),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

final class LocalWebTests: XCTestCase {
    func testLaunchAcceptsOnlyLiteralLoopbackGrantURLs() async throws {
        let grant = String(repeating: "a", count: 43)
        let valid = "http://127.0.0.1:32123/#launch=" + grant
        let transport = WebLaunchTransport(valid)
        let client = APIClient(address: try ServerAddress(validating: "https://127.0.0.1:9841"), token: "native-secret", transport: transport)
        let result = try await client.localWebLaunch()
        XCTAssertEqual(result.absoluteString, valid)
        let requests = await transport.requests
        XCTAssertEqual(requests.first?.httpMethod, "POST")
        XCTAssertEqual(requests.first?.url?.path, "/v1/local-web/launch")
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer native-secret")
        for url in ["https://evil.example/#launch=" + grant, "http://localhost:32123/#launch=" + grant,
                    "http://127.0.0.1:32123/other#launch=" + grant,
                    "http://user@127.0.0.1:32123/#launch=" + grant,
                    "http://127.0.0.1:32123/?token=secret#launch=" + grant,
                    "http://127.0.0.1:32123/#launch=short", "http://127.0.0.1:32123/#launch=" + grant + "&redirect=evil"] {
            let other = APIClient(address: client.address, token: "native-secret", transport: WebLaunchTransport(url))
            do { _ = try await other.localWebLaunch(); XCTFail("Accepted an invalid launch destination") }
            catch { XCTAssertEqual(error as? ClientError, .invalidResponse) }
        }
    }

    func testLegacyExportPreservesDraftRevisionAndOriginalDefaults() async throws {
        let suite = "local-web-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let identity = ConnectionIdentity(host: "fixture.local", deviceID: "local-mac")
        var tab = WorkspaceTab(kind: .editor, projectID: "project", resourceID: "hello.txt", title: "hello.txt", draft: "unsaved")
        tab.editorDirty = true
        tab.editorBaseRevision = "original-revision"
        let original = WorkspaceState(tabs: [tab], selectedTabID: tab.id)
        let persistence = WorkspacePersistence(defaults: defaults)
        persistence.save(original, for: identity)
        let transport = WebLaunchTransport("")
        let client = APIClient(address: try ServerAddress(validating: "https://127.0.0.1:9841"), token: "fixture", transport: transport)
        try await client.importLocalWebLegacy(LocalWebLegacy(projectID: "project", workspace: persistence.loadState(for: identity)))
        let requests = await transport.requests
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(requests.first?.httpBody)) as? [String: Any])
        let legacy = try XCTUnwrap(body["legacy"] as? [String: Any])
        let tabs = try XCTUnwrap(legacy["tabs"] as? [[String: Any]])
        XCTAssertEqual(tabs.first?["draft"] as? String, "unsaved")
        XCTAssertEqual(tabs.first?["editorBaseRevision"] as? String, "original-revision")
        XCTAssertEqual(persistence.loadState(for: identity), original)
    }
}
