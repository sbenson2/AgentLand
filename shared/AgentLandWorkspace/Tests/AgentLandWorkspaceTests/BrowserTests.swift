import XCTest
import AgentLandCore
@testable import AgentLandWorkspace

/// A web view that records what the session asks of it and lets the test play WebKit's part.
@MainActor final class FakeRenderer: BrowserRenderer {
    let number: Int
    weak var events: (any BrowserRendererEvents)?
    var loads: [URLRequest] = []
    var restored: [String] = []
    var reloads = 0
    var tornDown = false

    init(number: Int, events: any BrowserRendererEvents) {
        self.number = number
        self.events = events
    }

    func load(_ request: URLRequest) { loads.append(request) }
    func goBack() {}
    func goForward() {}
    func reload() { reloads += 1 }
    func stopLoading() {}
    var interactionState: Any? { "history of renderer \(number)" }
    func restore(_ interactionState: Any) { restored.append(interactionState as? String ?? "") }
    func tearDown() { tornDown = true }

    /// WebKit committed `url` and finished loading it.
    func show(_ url: URL, title: String = "") {
        events?.renderer(self, changed: BrowserPageState(url: url, title: title, isLoading: false, progress: 1, canGoBack: false, canGoForward: false))
        events?.renderer(self, committed: url)
        events?.renderer(self, finished: url)
    }
}

@MainActor final class FakeRendererFactory: BrowserRendererFactory {
    private(set) var made: [FakeRenderer] = []
    private(set) var cookies: [HTTPCookie] = []
    private static var count = 0

    func makeRenderer(events: any BrowserRendererEvents) -> any BrowserRenderer {
        Self.count += 1
        let renderer = FakeRenderer(number: Self.count, events: events)
        made.append(renderer)
        return renderer
    }

    func setCookie(_ cookie: HTTPCookie) async { cookies.append(cookie) }
}

@MainActor final class BrowserTests: XCTestCase {
    private let identity = ConnectionIdentity(host: "https://studio.local:9841", deviceID: "device-a")
    private let hostID = "https://studio.local:9841|device-a"
    private var suites: [String] = []
    nonisolated private static let secret = "rT0p4Z8wq3HkLx2VnB7cYs1mEa9DfGj5Uo6Ii4Pl0Qw"

    override func tearDown() async throws {
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        suites = []
    }

    private func workspace(_ host: ScriptedHost?, preview: Bool = true, name: String = #function) throws -> WorkspaceModel {
        let suite = "browser-tests-\(name)-\(UUID())"
        suites.append(suite)
        let workspace = WorkspaceModel(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        let client = try host.map { APIClient(address: try ServerAddress(validating: "https://studio.local:9841"), token: "device-token", transport: $0) }
        workspace.attach(hostID: hostID, identity: identity, client: client)
        workspace.projects = [Project(id: "p", name: "Project")]
        workspace.selectedProjectID = "p"
        workspace.capabilities = CapabilitiesResponse(interactions: true, terminal: true, preview: preview ? PreviewCapabilities(port: 9842) : nil)
        return workspace
    }

    private func grantingHost(delay: Gate? = nil, reached: Gate? = nil) -> ScriptedHost {
        let host = ScriptedHost()
        host.on("/v1/preview/sessions") { request in
            await reached?.open()
            await delay?.wait()
            let port = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Int])?["port"] ?? 0
            return (201, #"{"sessionId":"grant-\#(port)-\#(UUID().uuidString.prefix(4))","previewPort":9842,"cookie":{"name":"__Host-agentland-preview","value":"\#(Self.secret)","maxAgeSeconds":43200}}"#)
        }
        host.on("/v1/preview/sessions/revoke") { _ in (200, #"{"revoked":true}"#) }
        host.on("/v1/preview/ports") { _ in (200, #"{"ports":[{"port":5173,"address":"127.0.0.1","process":"node"}]}"#) }
        return host
    }

    /// A browser tab's session. Each has its own sweep unless a test shares one, as the tabs of one
    /// launch do.
    private func session(_ workspace: WorkspaceModel, _ location: BrowserLocation = .blank, factory: FakeRendererFactory,
                         budget: BrowserWebViewBudget = BrowserWebViewBudget(limit: 3),
                         sweep: PreviewSessionSweep = PreviewSessionSweep()) -> (BrowserSession, WorkspaceTab) {
        let tab = WorkspaceTab.browser(projectID: "p", location: location)
        workspace.open(tab)
        return (BrowserSession(tab: tab, workspace: workspace, budget: budget, factory: factory, sweep: sweep), tab)
    }

    /// A host that lists `revokeAll`, with its preview listener's scheme.
    private func sweepingCapabilities(scheme: String? = "https") -> CapabilitiesResponse {
        CapabilitiesResponse(interactions: true, terminal: true, preview: PreviewCapabilities(port: 9842, scheme: scheme, features: ["revokeAll"]))
    }

    /// The bodies of `{all: true}` revokes the host received.
    private func sweeps(_ host: ScriptedHost) -> Int {
        host.bodies("/v1/preview/sessions/revoke").filter { $0["all"] as? Bool == true }.count
    }

    // MARK: Addresses

    func testTypedAddresses() throws {
        let cases: [(String, Result<BrowserLocation, BrowserRefusal>)] = [
            ("5173", .success(.preview(port: 5173, path: "/"))),
            (":8000", .success(.preview(port: 8000, path: "/"))),
            ("localhost:5173/docs?page=2#top", .success(.preview(port: 5173, path: "/docs?page=2#top"))),
            ("http://127.0.0.1:8000/api", .success(.preview(port: 8000, path: "/api"))),
            ("[::1]:3000", .success(.preview(port: 3000, path: "/"))),
            ("studio.local:4000", .success(.preview(port: 4000, path: "/"))),
            ("example.com", .success(.web(try XCTUnwrap(URL(string: "https://example.com"))))),
            ("HTTPS://Example.com/Path", .success(.web(try XCTUnwrap(URL(string: "https://example.com/Path"))))),
            ("http://example.com", .failure(.insecure)),
            ("https://user:secret@example.com", .failure(.credentials)),
            ("mailto:someone@example.com", .failure(.unsupportedScheme("mailto"))),
            ("javascript:alert(1)", .failure(.unsupportedScheme("javascript"))),
            ("file:///etc/hosts", .failure(.unsupportedScheme("file"))),
            ("ftp://example.com", .failure(.unsupportedScheme("ftp"))),
            ("70000", .failure(.badPort)),
            ("hello", .failure(.notAnAddress)),
            ("two words", .failure(.notAnAddress)),
            ("   ", .failure(.notAnAddress)),
        ]
        for (text, expected) in cases {
            XCTAssertEqual(BrowserAddress.parse(text, hostNames: ["Studio.local"]), expected, text)
        }
    }

    func testSavedFormsAndWhatTheTabRemembers() throws {
        let preview = BrowserLocation.preview(port: 8888, path: "/lab?token=abc#cell")
        XCTAssertEqual(BrowserLocation(saved: preview.saved), preview)
        XCTAssertEqual(preview.remembered, "preview:8888/lab", "A token in the query is never saved")
        XCTAssertEqual(preview.displayText, "localhost:8888/lab?token=abc#cell")
        let web = BrowserLocation.web(try XCTUnwrap(URL(string: "https://example.com/callback?code=secret")))
        XCTAssertEqual(web.remembered, "https://example.com/callback")
        XCTAssertEqual(web.displayText, "example.com/callback")
        XCTAssertEqual(BrowserLocation(saved: ""), .blank)
        XCTAssertEqual(BrowserLocation(saved: "preview:5173"), .preview(port: 5173, path: "/"))
        XCTAssertNil(BrowserLocation(saved: "http://example.com"), "Plain http is never a saved location")
        XCTAssertNil(BrowserLocation(saved: "preview:0"))
        let tab = WorkspaceTab.browser(projectID: "p", location: preview)
        XCTAssertEqual(tab.kind, .browser)
        XCTAssertEqual(tab.resourceID, "preview:8888/lab")
        XCTAssertEqual(tab.title, "localhost:8888")
    }

    // MARK: Policy

    func testNavigationPolicy() throws {
        let policy = BrowserNavigationPolicy(address: try ServerAddress(validating: "https://studio.local:9841"), previewPort: 9842)
        func decide(_ text: String, main: Bool = true, authorization: Bool = false, download: Bool = false) -> BrowserNavigationPolicy.Decision {
            policy.decide(url: URL(string: text), isMainFrame: main, carriesAuthorization: authorization, isDownload: download)
        }
        XCTAssertEqual(decide("https://studio.local:9842/docs"), .allow, "The preview origin")
        XCTAssertEqual(decide("https://example.com/"), .allow, "Public https")
        XCTAssertEqual(decide("http://example.com/"), .refuse(.insecure))
        XCTAssertEqual(decide("http://studio.local:9842/", main: false), .refuse(.insecure), "Plain http in a frame too")
        XCTAssertEqual(decide("about:blank", main: false), .allow)
        XCTAssertEqual(decide("data:text/html,hi", main: false), .allow)
        XCTAssertEqual(decide("data:text/html,hi"), .refuse(.unsupportedScheme("data")))
        XCTAssertEqual(decide("javascript:void(0)"), .refuse(.unsupportedScheme("javascript")))
        XCTAssertEqual(decide("https://user:pass@example.com/"), .refuse(.credentials))
        XCTAssertEqual(decide("https://example.com/", authorization: true), .refuse(.credentials), "No bearer tokens in web requests")
        XCTAssertEqual(decide("https://example.com/file.zip", download: true), .refuse(.download))
        XCTAssertEqual(decide("https://studio.local:9841/v1/capabilities"), .refuse(.hostAPI))
        XCTAssertEqual(decide("https://studio.local:9841/v1"), .refuse(.hostAPI))
        XCTAssertEqual(decide("https://studio.local:9841/v10/other"), .allow, "Only the API's own routes")
        XCTAssertEqual(decide("https://studio.local/v1/x"), .allow, "Another port is another origin")

        let proxied = try BrowserNavigationPolicy(address: ServerAddress(validating: "https://mac.example/agentland"), previewPort: 9842)
        XCTAssertEqual(proxied.decide(url: URL(string: "https://mac.example/agentland/v1/projects"), isMainFrame: true, carriesAuthorization: false, isDownload: false),
                       .refuse(.hostAPI))
        XCTAssertEqual(proxied.decide(url: URL(string: "https://mac.example/v1/projects"), isMainFrame: true, carriesAuthorization: false, isDownload: false),
                       .allow)
    }

    func testResponsePolicy() throws {
        let policy = BrowserNavigationPolicy(address: try ServerAddress(validating: "https://studio.local:9841"), previewPort: 9842)
        func response(_ url: String, _ status: Int = 200, _ headers: [String: String] = [:]) -> HTTPURLResponse {
            HTTPURLResponse(url: URL(string: url)!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        }
        XCTAssertEqual(policy.decide(response: response("https://example.com/"), isMainFrame: true, canShowMIMEType: true), .allow)
        XCTAssertEqual(policy.decide(response: response("https://example.com/a.zip"), isMainFrame: true, canShowMIMEType: false), .refuse(.download))
        XCTAssertEqual(policy.decide(response: response("https://example.com/r", 200, ["Content-Disposition": "attachment; filename=r.csv"]),
                                     isMainFrame: true, canShowMIMEType: true), .refuse(.download))
        XCTAssertEqual(policy.decide(response: response("https://example.com/r", 200, ["Content-Disposition": "inline"]),
                                     isMainFrame: true, canShowMIMEType: true), .allow)
        let refusal = response("https://studio.local:9842/app", 401, [PreviewProxy.errorHeader: "preview_session_required"])
        XCTAssertEqual(policy.decide(response: refusal, isMainFrame: true, canShowMIMEType: true),
                       .previewError(code: "preview_session_required", status: 401))
        let spoofed = response("https://evil.example/", 401, [PreviewProxy.errorHeader: "preview_session_required"])
        XCTAssertEqual(policy.decide(response: spoofed, isMainFrame: true, canShowMIMEType: true), .allow,
                       "Only the preview origin speaks for the proxy")
    }

    /// The paired pin applies to the preview origin alone; every other page gets normal validation.
    func testCertificateChecksApplyToThePreviewOriginOnly() throws {
        let policy = BrowserNavigationPolicy(address: try ServerAddress(validating: "https://studio.local:9841"), previewPort: 9842)
        let pinned = PinnedTrustEvaluator(expectedHost: "studio.local", certificateSHA256: String(repeating: "ab", count: 32))
        let serverTrust = NSURLAuthenticationMethodServerTrust
        XCTAssertEqual(policy.respond(toChallengeFor: "studio.local", port: 9842, authenticationMethod: serverTrust, serverTrust: nil, pinned: pinned).0,
                       .cancelAuthenticationChallenge, "Without the paired certificate the preview origin is refused")
        XCTAssertEqual(policy.respond(toChallengeFor: "STUDIO.local", port: 9842, authenticationMethod: serverTrust, serverTrust: nil, pinned: pinned).0,
                       .cancelAuthenticationChallenge)
        XCTAssertEqual(policy.respond(toChallengeFor: "example.com", port: 443, authenticationMethod: serverTrust, serverTrust: nil, pinned: pinned).0,
                       .performDefaultHandling, "A public page keeps the platform's validation")
        XCTAssertEqual(policy.respond(toChallengeFor: "studio.local", port: 443, authenticationMethod: serverTrust, serverTrust: nil, pinned: pinned).0,
                       .performDefaultHandling, "The same host on another port is another origin")
        XCTAssertEqual(policy.respond(toChallengeFor: "studio.local", port: 9842, authenticationMethod: NSURLAuthenticationMethodHTTPBasic,
                                      serverTrust: nil, pinned: pinned).0,
                       .cancelAuthenticationChallenge, "The preview origin never asks for credentials")
        let unpinned = PinnedTrustEvaluator(expectedHost: "studio.local", certificateSHA256: nil)
        XCTAssertEqual(policy.respond(toChallengeFor: "studio.local", port: 9842, authenticationMethod: serverTrust, serverTrust: nil, pinned: unpinned).0,
                       .performDefaultHandling, "A host reached with a public certificate validates normally")
        XCTAssertTrue(policy.isPreview(host: "studio.local", port: 9842))
        XCTAssertFalse(BrowserNavigationPolicy(address: try ServerAddress(validating: "https://studio.local:9841"), previewPort: nil)
            .isPreview(host: "studio.local", port: 9842))
    }

    // MARK: Web view limit

    func testAtMostThreeWebViewsLiveAndTheLeastRecentUnloads() throws {
        let workspace = try workspace(nil)
        let budget = BrowserWebViewBudget(limit: 3)
        let factories = (0..<4).map { _ in FakeRendererFactory() }
        let sessions = try (0..<4).map { index in
            session(workspace, .web(try XCTUnwrap(URL(string: "https://example.com/\(index)"))), factory: factories[index], budget: budget).0
        }
        for session in sessions { session.show() }
        XCTAssertEqual(budget.live.count, 3)
        XCTAssertNil(sessions[0].renderer, "The least recently shown gave its web view up")
        XCTAssertTrue(factories[0].made[0].tornDown)
        XCTAssertEqual(factories[0].made[0].loads.map(\.url?.absoluteString), ["https://example.com/0"])
        XCTAssertEqual(sessions[0].location, .web(try XCTUnwrap(URL(string: "https://example.com/0"))), "It keeps its place")
        XCTAssertNotNil(sessions[3].renderer)

        sessions[0].show()
        XCTAssertEqual(factories[0].made.count, 2, "It loads again when shown")
        XCTAssertEqual(factories[0].made[1].restored, ["history of renderer \(factories[0].made[0].number)"], "with its history")
        XCTAssertTrue(factories[0].made[1].loads.isEmpty)
        XCTAssertNil(sessions[1].renderer, "Now the second is the least recent")
        XCTAssertEqual(budget.live.count, 3)

        sessions[2].show()
        XCTAssertEqual(budget.live.count, 3, "Showing a live one only makes it the most recent")
        sessions[3].end()
        XCTAssertEqual(budget.live.count, 2, "An ended session gives its place back")
        XCTAssertEqual(BrowserSession.liveWebViewLimit, 3)
    }

    // MARK: Previews

    func testAPortOpensWithTheCookieOnThePreviewOriginOnly() async throws {
        let host = grantingHost()
        let workspace = try workspace(host)
        let factory = FakeRendererFactory()
        let (session, tab) = session(workspace, factory: factory)
        session.show()
        session.go(to: "localhost:5173/docs?page=2")
        await waitUntil("the page loads") { factory.made.first?.loads.isEmpty == false }

        XCTAssertEqual(host.bodies("/v1/preview/sessions").first as? [String: Int], ["port": 5173])
        let cookie = try XCTUnwrap(factory.cookies.first)
        XCTAssertEqual(cookie.name, PreviewCookie.standardName)
        XCTAssertEqual(cookie.value, Self.secret)
        XCTAssertEqual(cookie.domain, "studio.local")
        XCTAssertTrue(cookie.isSecure)
        XCTAssertTrue(cookie.isHTTPOnly)
        XCTAssertEqual(cookie.sameSitePolicy, .sameSiteStrict)
        let request = try XCTUnwrap(factory.made.first?.loads.first)
        XCTAssertEqual(request.url?.absoluteString, "https://studio.local:9842/docs?page=2")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"), "The device token never goes to the page")
        XCTAssertFalse(request.url?.absoluteString.contains(Self.secret) == true, "The secret never goes in a URL")
        XCTAssertEqual(session.navigationPolicy.previewOrigin, BrowserOrigin(host: "studio.local", port: 9842))

        try XCTUnwrap(factory.made.first).show(try XCTUnwrap(URL(string: "https://studio.local:9842/docs?page=2")), title: "Docs")
        XCTAssertEqual(session.location, .preview(port: 5173, path: "/docs?page=2"))
        XCTAssertEqual(workspace.tab(tab.id)?.draft, "preview:5173/docs", "The tab remembers the page without its query")
        XCTAssertEqual(workspace.tab(tab.id)?.title, "Docs")
        XCTAssertFalse(UserDefaults(suiteName: suites[0])?.dictionaryRepresentation().description.contains(Self.secret) ?? true,
                       "The secret is never saved")

        session.end()
        await waitUntil("the preview is revoked") { !host.requests("/v1/preview/sessions/revoke").isEmpty }
        XCTAssertTrue((host.bodies("/v1/preview/sessions/revoke").first?["sessionId"] as? String)?.hasPrefix("grant-5173") == true,
                      "Closing the tab ends its preview on the host")
    }

    /// A grant that arrives after the tab closed is revoked and never loaded.
    func testALateGrantForAClosedTabIsRevoked() async throws {
        let reached = Gate(), release = Gate()
        let host = grantingHost(delay: release, reached: reached)
        let workspace = try workspace(host)
        let factory = FakeRendererFactory()
        let (session, tab) = session(workspace, .preview(port: 5173, path: "/"), factory: factory)
        session.show()
        await arrive(at: reached)
        XCTAssertTrue(session.connecting)
        workspace.close(tab.id)
        session.end()
        await release.open()
        await waitUntil("the late grant is revoked") { !host.requests("/v1/preview/sessions/revoke").isEmpty }
        XCTAssertTrue(factory.cookies.isEmpty, "Its cookie is never set")
        XCTAssertTrue(factory.made.allSatisfy(\.loads.isEmpty))
    }

    func testALateGrantAfterAHostChangeIsDropped() async throws {
        let reached = Gate(), release = Gate()
        let host = grantingHost(delay: release, reached: reached)
        let workspace = try workspace(host)
        let factory = FakeRendererFactory()
        let (session, _) = session(workspace, .preview(port: 5173, path: "/"), factory: factory)
        session.show()
        await arrive(at: reached)
        workspace.attach(hostID: "https://other.local|device-a", identity: ConnectionIdentity(host: "https://other.local", deviceID: "device-a"),
                         client: APIClient(address: try ServerAddress(validating: "https://other.local"), token: "t", transport: ScriptedHost()))
        await release.open()
        await waitUntil("the late grant is revoked") { !host.requests("/v1/preview/sessions/revoke").isEmpty }
        XCTAssertTrue(factory.cookies.isEmpty)
        XCTAssertNil(session.problem, "A late answer changes nothing, not even with an error")
    }

    func testPreviewProblemsAreClear() async throws {
        let host = ScriptedHost()
        host.on("/v1/preview/sessions") { request in
            let port = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Int])?["port"] ?? 0
            switch port {
            case 4321: return (404, #"{"error":{"code":"port_not_listening","message":"Nothing on this computer is listening on that port"}}"#)
            case 22: return (403, #"{"error":{"code":"port_not_allowed","message":"AgentLand does not open this port in web previews"}}"#)
            default: return (403, #"{"error":{"code":"preview_disabled","message":"Enable web previews explicitly on your AgentLand host"}}"#)
            }
        }
        let workspace = try workspace(host)
        let (session, _) = session(workspace, factory: FakeRendererFactory())
        session.open(.preview(port: 4321, path: "/"))
        await waitUntil("the refusal") { session.problem != nil }
        XCTAssertEqual(session.problem, .portClosed(4321))
        XCTAssertEqual(session.problem?.action, .retry)
        session.open(.preview(port: 22, path: "/"))
        await waitUntil("the refusal") { session.problem != nil }
        XCTAssertEqual(session.problem, .portNotAllowed(22))
        session.open(.preview(port: 8080, path: "/"))
        await waitUntil("the refusal") { session.problem != nil }
        XCTAssertEqual(session.problem, .previewDisabled)

        let off = try self.workspace(host, preview: false)
        let (offSession, _) = self.session(off, factory: FakeRendererFactory())
        let before = host.requests("/v1/preview/sessions").count
        offSession.go(to: "5173")
        XCTAssertEqual(offSession.problem, .previewDisabled, "Without the capability nothing is asked of the host")
        XCTAssertEqual(host.requests("/v1/preview/sessions").count, before)
        offSession.go(to: "http://example.com")
        XCTAssertEqual(offSession.problem, .refused(.insecure))

        workspace.reachable = false
        let asked = host.requests("/v1/preview/sessions").count
        session.open(.preview(port: 5173, path: "/"))
        guard case .hostUnavailable = session.problem else { return XCTFail("offline: \(String(describing: session.problem))") }
        XCTAssertEqual(host.requests("/v1/preview/sessions").count, asked, "Offline, nothing is sent or queued")
        workspace.reachable = true
        session.resumeAfterReconnect()
        await waitUntil("the retry after reconnecting") { host.requests("/v1/preview/sessions").count == asked + 1 }
    }

    func testAnEndedPreviewReconnectsOnceThenAsks() async throws {
        let host = grantingHost()
        let workspace = try workspace(host)
        let factory = FakeRendererFactory()
        let (session, _) = session(workspace, .preview(port: 5173, path: "/"), factory: factory)
        session.show()
        await waitUntil("the first load") { factory.made.first?.loads.count == 1 }
        let renderer = try XCTUnwrap(factory.made.first)
        renderer.show(try XCTUnwrap(URL(string: "https://studio.local:9842/")))

        renderer.events?.renderer(renderer, previewRefused: "preview_session_required", status: 401)
        await waitUntil("the reload with a new preview") { renderer.loads.count == 2 }
        XCTAssertEqual(host.requests("/v1/preview/sessions").count, 2, "A new preview session, once")
        XCTAssertNil(session.problem)

        renderer.events?.renderer(renderer, previewRefused: "preview_session_required", status: 401)
        XCTAssertEqual(session.problem, .previewEnded, "A second refusal waits for the person")
        XCTAssertEqual(session.problem?.action, .reconnect)
        XCTAssertEqual(host.requests("/v1/preview/sessions").count, 2)

        renderer.events?.renderer(renderer, previewRefused: "upstream_unavailable", status: 502)
        XCTAssertEqual(session.problem, .portClosed(5173))
    }

    func testAMismatchedCertificateIsSaidPlainly() async throws {
        let host = grantingHost()
        let workspace = try workspace(host)
        let factory = FakeRendererFactory()
        let (session, _) = session(workspace, .preview(port: 5173, path: "/"), factory: factory)
        session.show()
        await waitUntil("the load") { factory.made.first?.loads.isEmpty == false }
        let renderer = try XCTUnwrap(factory.made.first)
        renderer.events?.rendererRejectedPreviewCertificate(renderer)
        renderer.events?.renderer(renderer, failed: URLError(.cancelled))
        XCTAssertEqual(session.problem, .certificateMismatch)

        session.open(.web(try XCTUnwrap(URL(string: "https://example.com"))))
        renderer.events?.renderer(renderer, failed: URLError(.cancelled))
        XCTAssertNil(session.problem, "A stopped load is not a problem")
        renderer.events?.renderer(renderer, failed: URLError(.serverCertificateUntrusted))
        XCTAssertEqual(session.problem, .pageFailed(URLError(.serverCertificateUntrusted).localizedDescription))
        renderer.events?.renderer(renderer, refused: .download, isMainFrame: true)
        XCTAssertEqual(session.problem, .refused(.download))
    }

    func testAnUnloadedRendererCannotChangeTheSession() throws {
        let workspace = try workspace(nil)
        let budget = BrowserWebViewBudget(limit: 1)
        let factory = FakeRendererFactory()
        let (first, _) = session(workspace, .web(try XCTUnwrap(URL(string: "https://example.com/a"))), factory: factory, budget: budget)
        let (second, _) = session(workspace, .web(try XCTUnwrap(URL(string: "https://example.com/b"))), factory: FakeRendererFactory(), budget: budget)
        first.show()
        second.show()
        let stale = try XCTUnwrap(factory.made.first)
        XCTAssertTrue(stale.tornDown)
        stale.events?.renderer(stale, failed: URLError(.timedOut))
        XCTAssertNil(first.problem, "Reports from a web view the session gave up are ignored")
    }

    // MARK: Origin and cleanup

    /// The preview origin is the scheme and port the host advertises, with the host name this device
    /// connected to; a scheme this app does not open loads nothing.
    func testThePreviewOriginIsTheAdvertisedSchemeAndPort() async throws {
        let host = grantingHost()
        let workspace = try workspace(host)
        workspace.capabilities = CapabilitiesResponse(interactions: true, terminal: true, preview: PreviewCapabilities(port: 9842, scheme: "https"))
        let factory = FakeRendererFactory()
        let (session, _) = session(workspace, factory: factory)
        XCTAssertEqual(session.navigationPolicy.previewOrigin, BrowserOrigin(host: "studio.local", port: 9842), "Known before any preview")
        session.show()
        session.go(to: "localhost:5173/app")
        await waitUntil("the page loads") { factory.made.first?.loads.isEmpty == false }
        XCTAssertEqual(factory.made.first?.loads.first?.url?.absoluteString, "https://studio.local:9842/app")
        XCTAssertEqual(factory.cookies.first?.domain, "studio.local")

        workspace.capabilities = CapabilitiesResponse(interactions: true, terminal: true, preview: PreviewCapabilities(port: 9842, scheme: "http"))
        XCTAssertNil(session.navigationPolicy.previewOrigin, "No pinned origin for a plain-http listener")
        let plainFactory = FakeRendererFactory()
        let (plain, _) = self.session(workspace, .preview(port: 5173, path: "/"), factory: plainFactory)
        plain.show()
        await waitUntil("the refusal") { plain.problem != nil }
        XCTAssertEqual(plain.problem, .previewFailed("The host’s preview listener has an address this device can’t use."))
        await waitUntil("the unusable preview is revoked") { !host.requests("/v1/preview/sessions/revoke").isEmpty }
        XCTAssertTrue(plainFactory.cookies.isEmpty, "Its cookie is never set")
        XCTAssertTrue(plainFactory.made.allSatisfy(\.loads.isEmpty))
    }

    /// The first previews after launch wait for this device's older sessions on the host to end: one
    /// sweep for every tab, and never again this launch, so no preview of this launch is ended by it.
    func testThisLaunchsPreviewsWaitForOneSweep() async throws {
        let reached = Gate(), release = Gate()
        let host = grantingHost()
        host.on("/v1/preview/sessions/revoke") { request in
            let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]) ?? [:]
            guard body["all"] as? Bool == true else { return (200, #"{"revoked":true}"#) }
            await reached.open()
            await release.wait()
            return (200, #"{"revoked":true,"count":2}"#)
        }
        let workspace = try workspace(host)
        workspace.capabilities = sweepingCapabilities()
        let sweep = PreviewSessionSweep()
        let firstFactory = FakeRendererFactory(), secondFactory = FakeRendererFactory()
        let (first, _) = session(workspace, .preview(port: 5173, path: "/"), factory: firstFactory, sweep: sweep)
        let (second, _) = session(workspace, .preview(port: 8000, path: "/"), factory: secondFactory, sweep: sweep)
        first.show()
        second.show()
        await arrive(at: reached, "the sweep")
        XCTAssertTrue(first.connecting)
        XCTAssertTrue(host.requests("/v1/preview/sessions").isEmpty, "No preview is asked for before the older ones end")
        await release.open()
        await waitUntil("both pages load") {
            firstFactory.made.first?.loads.isEmpty == false && secondFactory.made.first?.loads.isEmpty == false
        }
        XCTAssertEqual(sweeps(host), 1, "One sweep for both tabs")
        XCTAssertEqual(host.requests("/v1/preview/sessions").count, 2)

        let (third, _) = session(workspace, .preview(port: 3000, path: "/"), factory: FakeRendererFactory(), sweep: sweep)
        third.show()
        await waitUntil("the third preview") { host.requests("/v1/preview/sessions").count == 3 }
        XCTAssertEqual(sweeps(host), 1, "Later tabs of this launch never sweep")
    }

    /// A tab that goes elsewhere while the sweep runs never asks for the preview it was waiting for.
    func testATabThatMovesOnDuringTheSweepAsksForNothing() async throws {
        let reached = Gate(), release = Gate()
        let host = grantingHost()
        host.on("/v1/preview/sessions/revoke") { _ in
            await reached.open()
            await release.wait()
            return (200, #"{"revoked":true,"count":0}"#)
        }
        let workspace = try workspace(host)
        workspace.capabilities = sweepingCapabilities()
        let factory = FakeRendererFactory()
        let (session, _) = session(workspace, .preview(port: 5173, path: "/"), factory: factory)
        session.show()
        await arrive(at: reached, "the sweep")
        session.open(.preview(port: 8000, path: "/"))
        await release.open()
        await waitUntil("the new page loads") { factory.made.first?.loads.isEmpty == false }
        XCTAssertEqual(host.bodies("/v1/preview/sessions").compactMap { $0["port"] as? Int }, [8000],
                       "Only the page the tab shows now was asked for")
    }

    /// A sweep that could not reach the host sent nothing, so nothing opens either; the next attempt
    /// sweeps again first.
    func testAnUnreachableSweepOpensNothingAndSweepsAgain() async throws {
        let host = grantingHost()
        host.on("/v1/preview/sessions/revoke") { _ in throw URLError(.cannotConnectToHost) }
        let workspace = try workspace(host)
        workspace.capabilities = sweepingCapabilities()
        let factory = FakeRendererFactory()
        let (session, _) = session(workspace, .preview(port: 5173, path: "/"), factory: factory)
        session.show()
        await waitUntil("the problem") { session.problem != nil }
        guard case .hostUnavailable = session.problem else { return XCTFail("\(String(describing: session.problem))") }
        XCTAssertFalse(session.connecting)
        XCTAssertTrue(host.requests("/v1/preview/sessions").isEmpty, "No preview while the older ones could not end")
        XCTAssertEqual(host.requests("/v1/preview/sessions/revoke").count, 1, "Showing and opening share one sweep")

        host.on("/v1/preview/sessions/revoke") { _ in (200, #"{"revoked":true,"count":0}"#) }
        session.retry()
        await waitUntil("the page loads") { factory.made.first?.loads.isEmpty == false }
        XCTAssertEqual(host.requests("/v1/preview/sessions/revoke").count, 2)
        XCTAssertEqual(host.requests("/v1/preview/sessions").count, 1)
    }

    /// Showing the first tab starts the sweep, even on the start page; the Mac, which opens its ports
    /// directly, and a host without revokeAll are never swept.
    func testTheFirstTabShownSweepsOnlyWhereItCan() async throws {
        let host = grantingHost()
        let workspace = try workspace(host)
        workspace.capabilities = sweepingCapabilities()
        let (blank, _) = session(workspace, factory: FakeRendererFactory())
        blank.show()
        await waitUntil("the sweep") { sweeps(host) == 1 }

        let macHost = grantingHost()
        let mac = try self.workspace(macHost)
        mac.capabilities = sweepingCapabilities()
        let macTab = WorkspaceTab.browser(projectID: "p")
        mac.open(macTab)
        let macSession = BrowserSession(tab: macTab, workspace: mac, budget: BrowserWebViewBudget(limit: 3), factory: nil, sweep: PreviewSessionSweep())
        macSession.show()

        let olderHost = grantingHost()
        let older = try self.workspace(olderHost)
        let sweep = PreviewSessionSweep()
        let olderFactory = FakeRendererFactory()
        let (first, _) = session(older, .preview(port: 5173, path: "/"), factory: olderFactory, sweep: sweep)
        first.show()
        await waitUntil("the preview") { olderFactory.made.first?.loads.isEmpty == false }
        // The host lists revokeAll later (it was upgraded): this launch has a preview there already.
        older.capabilities = sweepingCapabilities()
        let (second, _) = session(older, .preview(port: 8000, path: "/"), factory: FakeRendererFactory(), sweep: sweep)
        second.show()
        await waitUntil("the second preview") { olderHost.requests("/v1/preview/sessions").count == 2 }
        XCTAssertEqual(sweeps(macHost), 0, "The Mac never sweeps")
        XCTAssertEqual(sweeps(olderHost), 0, "Nothing this launch opened is swept")
    }

    // MARK: Workspace

    func testTheRegistryKeepsTheSessionUntilTheTabCloses() throws {
        let workspace = try workspace(grantingHost())
        let tab = WorkspaceTab.browser(projectID: "p", location: .preview(port: 5173, path: "/"))
        workspace.open(tab)
        let session = workspace.browserSession(for: tab)
        XCTAssertTrue(workspace.browserSession(for: tab) === session, "Looking it up again returns the same session")
        XCTAssertEqual(session.location, .preview(port: 5173, path: "/"))
        workspace.close(tab.id)
        XCTAssertNil(workspace.sessions.existing(tab.id), "Closing the tab ends it")
    }

    func testTheSelectedBrowserTabReportsReadinessWhenItsPageShows() throws {
        let workspace = try workspace(nil)
        let factory = FakeRendererFactory()
        let url = try XCTUnwrap(URL(string: "https://example.com/"))
        let (session, tab) = session(workspace, .web(url), factory: factory)
        workspace.beginPresentation()
        XCTAssertEqual(workspace.presentationTicket?.tabID, tab.id)
        session.show()
        session.reportPresentationIfReady()
        XCTAssertFalse(workspace.presentationReady, "Not before the page shows")
        try XCTUnwrap(factory.made.first).show(url, title: "Example")
        XCTAssertTrue(workspace.presentationReady)

        let (blank, blankTab) = self.session(workspace, factory: FakeRendererFactory())
        workspace.selectedTabID = blankTab.id
        workspace.beginPresentation()
        blank.show()
        XCTAssertTrue(workspace.presentationReady, "The start page is ready at once")
    }

    func testPortsListAndDropALateAnswer() async throws {
        let reached = Gate(), release = Gate()
        let host = ScriptedHost()
        host.on("/v1/preview/ports") { _ in
            await reached.open()
            await release.wait()
            return (200, #"{"ports":[{"port":5173,"address":"127.0.0.1","process":"node"}]}"#)
        }
        let workspace = try workspace(host)
        let (session, _) = session(workspace, factory: FakeRendererFactory())
        let load = Task { await session.refreshPorts() }
        await arrive(at: reached)
        XCTAssertEqual(session.ports, .loading)
        session.end()
        await release.open()
        await load.value
        XCTAssertEqual(session.ports, .loading, "An ended session takes no late answer")

        let fresh = try self.workspace(grantingHost())
        let (listing, _) = self.session(fresh, factory: FakeRendererFactory())
        await listing.refreshPorts()
        XCTAssertEqual(listing.ports, .loaded([PreviewPort(port: 5173, address: "127.0.0.1", process: "node")]))
    }
}
