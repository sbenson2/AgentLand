#if os(iOS)
import UIKit
import WebKit
import AgentLandCore

/// A browser tab's web views on iPhone and iPad. All of a tab's web views share its own
/// non-persistent data store: nothing is written to disk, and the preview cookie stays with the tab.
@MainActor final class WebKitRendererFactory: BrowserRendererFactory {
    private let dataStore = WKWebsiteDataStore.nonPersistent()

    func makeRenderer(events: any BrowserRendererEvents) -> any BrowserRenderer {
        WebKitBrowserRenderer(dataStore: dataStore, events: events)
    }

    func setCookie(_ cookie: HTTPCookie) async {
        await dataStore.httpCookieStore.setCookie(cookie)
    }
}

/// One `WKWebView` and its delegates. Every navigation, response and certificate challenge goes
/// through the session's `BrowserNavigationPolicy`; new windows open in the same view, downloads are
/// refused, and no request of the web view ever carries the host's bearer token.
@MainActor final class WebKitBrowserRenderer: NSObject, BrowserRenderer, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    private weak var events: (any BrowserRendererEvents)?
    private var observations: [NSKeyValueObservation] = []

    init(dataStore: WKWebsiteDataStore, events: any BrowserRendererEvents) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.allowsInlineMediaPlayback = true
        configuration.dataDetectorTypes = []
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        // Link previews open pages outside this view's delegates.
        webView.allowsLinkPreview = false
        // Opaque with WebKit's own background (BR-1, AGENTS.md): a page that sets no background of its own draws on
        // the system's default, never on the app's slate, where its default black text could not be read.
        self.events = events
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.accessibilityIdentifier = "browserPage"
        observations = [
            webView.observe(\.url) { [weak self] _, _ in MainActor.assumeIsolated { self?.publish() } },
            webView.observe(\.title) { [weak self] _, _ in MainActor.assumeIsolated { self?.publish() } },
            webView.observe(\.isLoading) { [weak self] _, _ in MainActor.assumeIsolated { self?.publish() } },
            webView.observe(\.estimatedProgress) { [weak self] _, _ in MainActor.assumeIsolated { self?.publish() } },
            webView.observe(\.canGoBack) { [weak self] _, _ in MainActor.assumeIsolated { self?.publish() } },
            webView.observe(\.canGoForward) { [weak self] _, _ in MainActor.assumeIsolated { self?.publish() } },
        ]
    }

    private func publish() {
        events?.renderer(self, changed: BrowserPageState(url: webView.url, title: webView.title ?? "", isLoading: webView.isLoading,
                                                         progress: webView.estimatedProgress, canGoBack: webView.canGoBack,
                                                         canGoForward: webView.canGoForward))
    }

    // MARK: BrowserRenderer

    func load(_ request: URLRequest) { webView.load(request) }
    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload() { webView.reload() }
    func stopLoading() { webView.stopLoading() }
    var interactionState: Any? { webView.interactionState }
    func restore(_ interactionState: Any) { webView.interactionState = interactionState }

    func tearDown() {
        observations = []
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
        events = nil
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let events else { return .cancel }
        let request = navigationAction.request
        // A new window (no target frame) opens in this view, so it counts as the main frame.
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        let decision = events.navigationPolicy.decide(url: request.url, isMainFrame: isMainFrame,
                                                      carriesAuthorization: request.value(forHTTPHeaderField: "Authorization") != nil,
                                                      isDownload: navigationAction.shouldPerformDownload)
        switch decision {
        case .allow:
            return .allow
        case let .refuse(refusal):
            events.renderer(self, refused: refusal, isMainFrame: isMainFrame)
            return .cancel
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        guard let events else { return .cancel }
        switch events.navigationPolicy.decide(response: navigationResponse.response, isMainFrame: navigationResponse.isForMainFrame,
                                              canShowMIMEType: navigationResponse.canShowMIMEType) {
        case .allow:
            return .allow
        case let .refuse(refusal):
            events.renderer(self, refused: refusal, isMainFrame: navigationResponse.isForMainFrame)
            return .cancel
        case let .previewError(code, status):
            events.renderer(self, previewRefused: code, status: status)
            return .cancel
        }
    }

    func webView(_ webView: WKWebView, respondTo challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard let events else { return (.cancelAuthenticationChallenge, nil) }
        let space = challenge.protectionSpace
        let policy = events.navigationPolicy
        let answer = policy.respond(toChallengeFor: space.host, port: space.port, authenticationMethod: space.authenticationMethod,
                                    serverTrust: space.serverTrust, pinned: events.previewTrust)
        if answer.0 == .cancelAuthenticationChallenge, policy.isPreview(host: space.host, port: space.port),
           space.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            events.rendererRejectedPreviewCertificate(self)
        }
        return answer
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        events?.renderer(self, committed: webView.url)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        events?.renderer(self, finished: webView.url)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        events?.renderer(self, failed: error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        events?.renderer(self, failed: error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        events?.rendererContentProcessEnded(self)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        // Never reached while the policy refuses downloads; cancel one that gets here anyway.
        download.cancel { _ in }
        events?.renderer(self, refused: .download, isMainFrame: true)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.cancel { _ in }
        events?.renderer(self, refused: .download, isMainFrame: true)
    }

    // MARK: WKUIDelegate

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        // A link to a new window opens here, through the same policy.
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
        }
        return nil
    }
}
#endif
