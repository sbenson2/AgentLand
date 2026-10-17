import Foundation
import Observation
import AgentLandCore

// MARK: Rendering

/// A page's state as its web view reports it.
struct BrowserPageState: Equatable {
    var url: URL?
    var title: String
    var isLoading: Bool
    var progress: Double
    var canGoBack: Bool
    var canGoForward: Bool
}

/// The web view behind a browser tab. On iPhone and iPad it is a `WKWebView`
/// (`WebKitBrowserRenderer`); tests use their own.
@MainActor protocol BrowserRenderer: AnyObject {
    func load(_ request: URLRequest)
    func goBack()
    func goForward()
    func reload()
    func stopLoading()
    /// The back-forward list and scroll position, to restore after the web view is unloaded.
    var interactionState: Any? { get }
    func restore(_ interactionState: Any)
    /// Stops and detaches the web view; the renderer is not used again.
    func tearDown()
}

/// Makes a tab's web views. It owns the tab's non-persistent website data store, so the preview
/// cookie outlives a web view that was unloaded and made again.
@MainActor protocol BrowserRendererFactory: AnyObject {
    func makeRenderer(events: any BrowserRendererEvents) -> any BrowserRenderer
    /// Stores `cookie` in the tab's own data store, before the page that needs it loads.
    func setCookie(_ cookie: HTTPCookie) async
}

/// What a renderer asks and tells its session. Every report names the renderer, so a web view the
/// session already unloaded cannot change it.
@MainActor protocol BrowserRendererEvents: AnyObject {
    var navigationPolicy: BrowserNavigationPolicy { get }
    /// The paired certificate check, used for the preview origin only.
    var previewTrust: PinnedTrustEvaluator? { get }
    func renderer(_ renderer: any BrowserRenderer, changed page: BrowserPageState)
    func renderer(_ renderer: any BrowserRenderer, committed url: URL?)
    func renderer(_ renderer: any BrowserRenderer, finished url: URL?)
    func renderer(_ renderer: any BrowserRenderer, failed error: Error)
    func renderer(_ renderer: any BrowserRenderer, refused refusal: BrowserRefusal, isMainFrame: Bool)
    func renderer(_ renderer: any BrowserRenderer, previewRefused code: String, status: Int)
    func rendererRejectedPreviewCertificate(_ renderer: any BrowserRenderer)
    func rendererContentProcessEnded(_ renderer: any BrowserRenderer)
}

// MARK: Problems

/// Something the browser tab says instead of, or over, its page.
public enum BrowserProblem: Hashable, Sendable {
    /// The host runs no preview listener (no `preview` capability, or 403 `preview_disabled`).
    case previewDisabled
    /// Nothing listens on the port (404 `port_not_listening`, or the proxy's `upstream_unavailable`).
    case portClosed(Int)
    case portNotAllowed(Int)
    /// The preview session ended (idle 30 minutes, 12 hours, a host restart); Reconnect opens a new one.
    case previewEnded
    case previewLimit
    /// Creating the preview may have reached the host; nothing was retried.
    case previewUnconfirmed
    /// The preview listener did not present the paired certificate.
    case certificateMismatch
    case hostUnavailable(String?)
    case refused(BrowserRefusal)
    /// Another refusal from the host or its proxy, in the host's words.
    case previewFailed(String)
    case pageFailed(String)

    public enum Action: Hashable, Sendable {
        case retry
        /// A new preview session for the same port.
        case reconnect
        /// Back to the start page's list of ports.
        case choosePort
    }

    public var title: String {
        switch self {
        case .previewDisabled: "Web Previews Are Off"
        case let .portClosed(port): "Nothing on Port \(port)"
        case let .portNotAllowed(port): "Port \(port) Isn’t Available"
        case .previewEnded: "This Preview Ended"
        case .previewLimit: "Too Many Previews"
        case .previewUnconfirmed: "Preview Not Confirmed"
        case .certificateMismatch: "Certificate Doesn’t Match"
        case .hostUnavailable: "Can’t Reach the Host"
        case .refused: "Can’t Open This"
        case .previewFailed: "Can’t Open the Preview"
        case .pageFailed: "Can’t Open the Page"
        }
    }

    public var message: String {
        switch self {
        case .previewDisabled:
            "This host doesn’t run web previews, so the servers on its ports can’t open here. Public https pages still open."
        case let .portClosed(port):
            "No web server is answering on port \(port) of the host. Start it, then try again."
        case let .portNotAllowed(port):
            "AgentLand doesn’t open port \(port) in web previews."
        case .previewEnded:
            "Previews end after 30 minutes without use, after 12 hours, or when the host restarts."
        case .previewLimit:
            "The host allows eight previews per device. Close a browser tab, then try again."
        case .previewUnconfirmed:
            "The host may have opened the preview. Nothing was sent again."
        case .certificateMismatch:
            "The host’s preview listener presented a certificate that doesn’t match the one this device paired with, so nothing was loaded."
        case let .hostUnavailable(message):
            message ?? "The host isn’t reachable right now."
        case let .refused(refusal):
            refusal.message
        case let .previewFailed(message), let .pageFailed(message):
            message
        }
    }

    public var systemImage: String {
        switch self {
        case .previewDisabled: "server.rack"
        case .portClosed, .portNotAllowed: "powerplug"
        case .previewEnded, .previewUnconfirmed: "clock.arrow.circlepath"
        case .previewLimit: "square.stack.3d.up"
        case .certificateMismatch: "lock.trianglebadge.exclamationmark"
        case .hostUnavailable: "wifi.exclamationmark"
        case .refused: "hand.raised"
        case .previewFailed, .pageFailed: "exclamationmark.triangle"
        }
    }

    public var action: Action? {
        switch self {
        case .previewDisabled, .refused, .previewLimit: nil
        case .portClosed: .retry
        case .portNotAllowed: .choosePort
        case .previewEnded, .previewUnconfirmed: .reconnect
        case .certificateMismatch, .hostUnavailable, .previewFailed, .pageFailed: .retry
        }
    }

    /// The problem for a refusal of `POST /v1/preview/sessions` or `GET /v1/preview/ports`.
    init(previewError error: ClientError, port: Int?) {
        switch error {
        case .server("preview_disabled", _): self = .previewDisabled
        case .server("port_not_listening", _): self = .portClosed(port ?? 0)
        case .server("port_not_allowed", _): self = .portNotAllowed(port ?? 0)
        case .server("preview_session_limit", _): self = .previewLimit
        case let .server("host_stopping", message): self = .hostUnavailable(message)
        case .unreachable: self = .hostUnavailable(nil)
        case let .server(_, message): self = .previewFailed(message)
        default: self = .previewFailed(error.localizedDescription)
        }
    }

    /// The problem for the preview proxy's own refusal of a page (`X-AgentLand-Preview-Error`).
    init(proxyCode code: String, port: Int) {
        switch code {
        case "preview_session_required": self = .previewEnded
        case "upstream_unavailable": self = .portClosed(port)
        case "upstream_timeout": self = .previewFailed("The web server on port \(port) didn’t answer within two minutes.")
        case "host_stopping": self = .hostUnavailable("The host is stopping.")
        case "preview_busy": self = .previewFailed("Too many requests are in progress for this preview. Try again in a moment.")
        case "request_too_large": self = .previewFailed("The request is larger than a web preview accepts (64 MB).")
        case "request_timeout": self = .previewFailed("The request didn’t reach the host in time.")
        case "cross_site_rejected": self = .previewFailed("The preview refused a request from another site.")
        default: self = .previewFailed("The host’s preview refused the page (\(code)).")
        }
    }
}

// MARK: Session

/// Ends this device's preview sessions left from before the app started, once per host each launch.
/// The host counts them toward its eight per device until they idle out, and the app that opened them
/// no longer knows their IDs. The first browser tab shown after launch starts it (hosts that list
/// `revokeAll`), and every preview opened on that host waits for it, so it never ends one this launch
/// opened: once a preview was asked for there, the host is never swept again until the next launch.
@MainActor final class PreviewSessionSweep {
    static let shared = PreviewSessionSweep()

    private enum State {
        case sweeping(Task<Bool, Never>)
        case done
    }

    /// By workspace host ID, which names the host and this device's pairing with it.
    private var hosts: [String: State] = [:]

    /// Starts the sweep of `hostID` unless it ran or runs.
    func start(hostID: String, client: APIClient) {
        guard hosts[hostID] == nil else { return }
        let task = Task { [weak self] () -> Bool in
            let outcome = await client.revokeAllPreviewSessions()
            // Unreachable means provably not sent: nothing ended, so the next preview tries again. Any
            // other answer, even an unconfirmed one, counts: sweeping later could end a newer preview.
            let sent = outcome != .failed(.unreachable)
            self?.hosts[hostID] = sent ? .done : nil
            return sent
        }
        hosts[hostID] = .sweeping(task)
    }

    /// Waits for the sweep of `hostID`, starting it when it has not run. False when the host could
    /// not be reached, so nothing was sent; the preview is not asked for either.
    func ready(hostID: String, client: APIClient) async -> Bool {
        start(hostID: hostID, client: client)
        guard case let .sweeping(task) = hosts[hostID] else { return true }
        return await task.value
    }

    /// A preview is asked for on a host that does not sweep (no `revokeAll`): it is never swept
    /// later this launch, when a newer preview could be among its sessions.
    func skip(hostID: String) {
        if hosts[hostID] == nil { hosts[hostID] = .done }
    }
}

/// A browser tab's live state, kept by the workspace: where it points, the page's title, progress and
/// history, its web view while it is one of the three most recently shown, and the preview session
/// that opens a port on the host.
///
/// A port opens through the host's preview listener with a session cookie that this tab alone holds:
/// its secret stays in memory, in the tab's non-persistent data store, for the preview origin only,
/// and the preview session is revoked when the tab closes. Requests carry the host, client and
/// navigation they were made for; a late answer for anything else is dropped (a grant made for it is
/// revoked). The preview origin is the scheme and port the host advertises with the host name this
/// device connected to; sessions from before the app started are ended first (`PreviewSessionSweep`).
@MainActor @Observable public final class BrowserSession: WorkspaceSession, BrowserWebViewHolder, BrowserRendererEvents {
    public enum PortsState: Equatable, Sendable {
        case idle
        case loading
        case loaded([PreviewPort])
        case failed(String)
    }

    public let tabID: UUID
    public let projectID: String
    public private(set) var location: BrowserLocation
    public private(set) var title: String
    public private(set) var isLoading = false
    public private(set) var progress: Double = 0
    public private(set) var canGoBack = false
    public private(set) var canGoForward = false
    public private(set) var problem: BrowserProblem?
    public private(set) var ports: PortsState = .idle
    /// A page has shown since the location was last set.
    public private(set) var hasPage = false
    /// A preview session is being opened.
    public private(set) var connecting = false
    /// Changes whenever the web view is made or unloaded, so the view that hosts it embeds it again.
    public private(set) var rendererGeneration = 0

    @ObservationIgnored private weak var workspace: WorkspaceModel?
    @ObservationIgnored private let hostID: String?
    @ObservationIgnored private let budget: BrowserWebViewBudget
    @ObservationIgnored private let factory: (any BrowserRendererFactory)?
    @ObservationIgnored private let sweep: PreviewSessionSweep
    @ObservationIgnored private(set) var renderer: (any BrowserRenderer)?
    @ObservationIgnored private var grant: Grant?
    @ObservationIgnored private var savedState: Any?
    @ObservationIgnored private var ended = false
    @ObservationIgnored private var navigationToken = UUID()
    @ObservationIgnored private var portsToken = UUID()
    @ObservationIgnored private var renewedAutomatically = false
    @ObservationIgnored private var previewCertificateRejected = false
    @ObservationIgnored private var resolved = false
    /// The title the web view reported last; the tab takes it once a page has shown.
    @ObservationIgnored private var reportedTitle = ""

    /// A preview session: its secret stays here and in the tab's data store, nowhere else.
    private struct Grant {
        let value: PreviewSessionGrant
        let port: Int
        let originURL: URL
        let client: APIClient
        let expires: Date
    }

    /// At most this many tabs keep a live web view.
    public static var liveWebViewLimit: Int { BrowserWebViewBudget.shared.limit }

    init(tab: WorkspaceTab, workspace: WorkspaceModel, budget: BrowserWebViewBudget = .shared,
         factory: (any BrowserRendererFactory)? = BrowserSession.platformFactory(), sweep: PreviewSessionSweep = .shared) {
        tabID = tab.id
        projectID = tab.projectID
        // Where the tab was last (its draft), else what it was opened for.
        let last = tab.draft.isEmpty ? nil : BrowserLocation(saved: tab.draft)
        location = last ?? BrowserLocation(saved: tab.resourceID) ?? .blank
        title = tab.title
        self.workspace = workspace
        hostID = workspace.hostID
        self.budget = budget
        self.factory = factory
        self.sweep = sweep
    }

    /// The web views of iPhone and iPad; the Mac opens pages in its browser instead.
    static func platformFactory() -> (any BrowserRendererFactory)? {
        #if os(iOS)
        WebKitRendererFactory()
        #else
        nil
        #endif
    }

    /// Whether this device can show pages in the tab (the Mac opens them in its browser).
    public var showsPages: Bool { factory != nil }

    /// The host advertises web previews.
    public var previewAvailable: Bool { workspace?.capabilities?.preview != nil }

    /// The host ends all of this device's preview sessions on request (`revokeAll`).
    private var sweepsEarlierPreviews: Bool { workspace?.capabilities?.preview?.supports(.revokeAll) == true }

    /// The host's own names, which typed with a port open that port through the preview.
    public var hostNames: [String] { [workspace?.client?.address.url.host()].compactMap { $0 } }

    // MARK: Lifetime

    public func end() {
        guard !ended else { return }
        ended = true
        navigationToken = UUID()
        portsToken = UUID()
        budget.release(self)
        tearDownRenderer()
        savedState = nil
        if let grant { Self.revoke(grant) }
        grant = nil
    }

    /// The tab is in front: its web view loads, or comes back where it was if it had been unloaded.
    public func show() {
        guard !ended else { return }
        startSweep()
        if renderer != nil {
            budget.use(self)
            return
        }
        guard factory != nil, location != .blank else {
            resolve()
            return
        }
        if let state = savedState, grant != nil || location.previewPort == nil {
            savedState = nil
            liveRenderer()?.restore(state)
        } else {
            savedState = nil
            load()
        }
    }

    /// The first browser tab shown after launch starts ending this device's older previews on the host
    /// (once per host and launch). The Mac opens its ports directly and has none.
    private func startSweep() {
        guard factory != nil, sweepsEarlierPreviews, let workspace, let client = workspace.client, let hostID,
              workspace.hostID == hostID, workspace.reachable else { return }
        sweep.start(hostID: hostID, client: client)
    }

    func unloadWebView() {
        guard let renderer else { return }
        savedState = renderer.interactionState
        renderer.tearDown()
        self.renderer = nil
        isLoading = false
        progress = 0
        rendererGeneration &+= 1
    }

    private func tearDownRenderer() {
        renderer?.tearDown()
        renderer = nil
        isLoading = false
        progress = 0
        rendererGeneration &+= 1
    }

    /// The web view, made (and counted in the budget) when needed.
    @discardableResult private func liveRenderer() -> (any BrowserRenderer)? {
        guard !ended else { return nil }
        if let renderer {
            budget.use(self)
            return renderer
        }
        guard let factory else { return nil }
        let made = factory.makeRenderer(events: self)
        renderer = made
        rendererGeneration &+= 1
        budget.use(self)
        return made
    }

    // MARK: Navigation

    /// Opens what the person typed.
    public func go(to text: String) {
        switch BrowserAddress.parse(text, hostNames: hostNames) {
        case let .success(location): open(location)
        case let .failure(refusal): problem = .refused(refusal)
        }
    }

    /// Opens `location` in this tab.
    public func open(_ location: BrowserLocation) {
        guard !ended else { return }
        problem = nil
        hasPage = false
        renewedAutomatically = false
        self.location = location
        remember()
        if location == .blank {
            navigationToken = UUID()
            connecting = false
            renderer?.stopLoading()
            resolve()
        } else {
            load()
        }
    }

    public func goBack() { renderer?.goBack() }
    public func goForward() { renderer?.goForward() }
    public func stopLoading() { renderer?.stopLoading() }

    public func reload() {
        if let renderer, hasPage, problem == nil {
            budget.use(self)
            renderer.reload()
        } else {
            retry()
        }
    }

    /// Loads the location again after a problem.
    public func retry() {
        problem = nil
        load()
    }

    /// A new preview session for the same port, then the page again.
    public func reconnectPreview() {
        if let grant { Self.revoke(grant) }
        grant = nil
        renewedAutomatically = false
        retry()
    }

    public func dismissProblem() { problem = nil }

    private func load() {
        guard !ended else { return }
        previewCertificateRejected = false
        switch location {
        case .blank:
            resolve()
        case let .web(url):
            navigationToken = UUID()
            connecting = false
            liveRenderer()?.load(Self.request(url))
        case let .preview(port, path):
            openPreview(port: port, path: path)
        }
    }

    private static func request(_ url: URL) -> URLRequest {
        // The bearer token never goes into web requests: a plain request, with no credentials.
        URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 30)
    }

    private func openPreview(port: Int, path: String) {
        guard previewAvailable else {
            problem = .previewDisabled
            resolve()
            return
        }
        guard let workspace, let client = workspace.client, workspace.hostID == hostID else {
            problem = .hostUnavailable(nil)
            resolve()
            return
        }
        guard workspace.reachable else {
            // Offline: nothing is sent or queued; the page opens when the host is back.
            problem = .hostUnavailable("The host is offline. The preview opens when it’s back.")
            resolve()
            return
        }
        let token = UUID()
        navigationToken = token
        if let grant, grant.port == port, grant.client === client, grant.expires > .now {
            connecting = false
            liveRenderer()?.load(Self.request(Self.url(grant.originURL, path: path)))
            return
        }
        connecting = true
        let sweep = self.sweep, sweeps = sweepsEarlierPreviews, host = hostID
        Task { [weak self, client] in
            // Sessions from before the app started end first, so the new one never counts among them
            // and the sweep never ends it.
            if let host {
                if sweeps {
                    guard await sweep.ready(hostID: host, client: client) else {
                        self?.previewNotSent(client: client, token: token)
                        return
                    }
                } else {
                    sweep.skip(hostID: host)
                }
            }
            // A tab that closed or moved on meanwhile asks for nothing.
            guard self?.isCurrent(token, client: client) == true else { return }
            let outcome = await client.createPreviewSession(port: port)
            guard let self else {
                if case let .created(value) = outcome { Self.revoke(value, client: client) }
                return
            }
            await self.finishPreview(outcome, port: port, path: path, client: client, token: token)
        }
    }

    /// The host could not be reached to end older previews, so no preview was asked for.
    private func previewNotSent(client: APIClient, token: UUID) {
        guard isCurrent(token, client: client) else { return }
        connecting = false
        workspace?.noteConnectionFailure()
        problem = .hostUnavailable(nil)
        resolve()
    }

    private func finishPreview(_ outcome: PreviewSessionOutcome, port: Int, path: String, client: APIClient, token: UUID) async {
        guard isCurrent(token, client: client), location.previewPort == port else {
            // A preview nobody will use must not stay open on the host.
            if case let .created(value) = outcome { Self.revoke(value, client: client) }
            return
        }
        connecting = false
        switch outcome {
        case let .created(value):
            // The listener's port (the grant's, fresh from the host) and the scheme the host
            // advertises, with the host name this device connected to.
            guard let originURL = client.address.previewOrigin(port: value.previewPort, scheme: workspace?.capabilities?.preview?.scheme),
                  let cookie = value.httpCookie(for: originURL) else {
                Self.revoke(value, client: client)
                problem = .previewFailed("The host’s preview listener has an address this device can’t use.")
                resolve()
                return
            }
            if let old = grant, old.value.sessionID != value.sessionID { Self.revoke(old) }
            grant = Grant(value: value, port: port, originURL: originURL, client: client,
                          expires: .now.addingTimeInterval(TimeInterval(value.cookie.maxAgeSeconds)))
            await factory?.setCookie(cookie)
            guard isCurrent(token, client: client) else { return }
            liveRenderer()?.load(Self.request(Self.url(originURL, path: path)))
            if factory == nil { resolve() }
        case .uncertain:
            problem = .previewUnconfirmed
            resolve()
        case let .failed(error):
            if ClientError.isConnectionFailure(error) { workspace?.noteConnectionFailure() }
            problem = BrowserProblem(previewError: error, port: port)
            resolve()
        }
    }

    /// An answer still counts only for this navigation, host and client, while the tab is open.
    private func isCurrent(_ token: UUID, client: APIClient) -> Bool {
        guard !ended, token == navigationToken, let workspace else { return false }
        return workspace.hostID == hostID && workspace.client === client && workspace.isCurrent(hostID: hostID, tabID: tabID)
    }

    private static func url(_ origin: URL, path: String) -> URL {
        URL(string: path, relativeTo: origin)?.absoluteURL ?? origin
    }

    private static func revoke(_ grant: Grant) { revoke(grant.value, client: grant.client) }

    private static func revoke(_ value: PreviewSessionGrant, client: APIClient) {
        let id = value.sessionID
        Task.detached { _ = await client.revokePreviewSession(id: id) }
    }

    // MARK: Ports

    /// Lists the host's ports unless they are listed already.
    public func refreshPortsIfNeeded() async {
        switch ports {
        case .loaded, .loading: return
        case .idle, .failed: await refreshPorts()
        }
    }

    public func refreshPorts() async {
        guard previewAvailable else {
            ports = .failed(BrowserProblem.previewDisabled.message)
            return
        }
        guard let workspace, let client = workspace.client, workspace.hostID == hostID, workspace.reachable else {
            ports = .failed("The host isn’t reachable right now.")
            return
        }
        let token = UUID()
        portsToken = token
        ports = .loading
        do {
            let listed = try await client.previewPorts()
            guard !ended, token == portsToken, workspace.hostID == hostID, workspace.client === client else { return }
            ports = .loaded(listed)
        } catch {
            guard !ended, token == portsToken, workspace.hostID == hostID, workspace.client === client else { return }
            if Task.isCancelled || isCancellation(error) {
                ports = .idle
                return
            }
            if ClientError.isConnectionFailure(error) { workspace.noteConnectionFailure() }
            if let error = error as? ClientError {
                ports = .failed(BrowserProblem(previewError: error, port: nil).message)
            } else {
                ports = .failed(error.localizedDescription)
            }
        }
    }

    /// After the host is reachable again: list the ports again if that failed, and load a page that failed.
    public func resumeAfterReconnect() {
        if case .failed = ports { Task { await refreshPorts() } }
        if case .hostUnavailable = problem, !hasPage { retry() }
    }

    // MARK: Renderer events

    var navigationPolicy: BrowserNavigationPolicy {
        let address = workspace?.client?.address
        let advertised = workspace?.capabilities?.preview
        let port = grant?.value.previewPort ?? advertised?.port
        return BrowserNavigationPolicy(address: address, previewPort: port, previewScheme: advertised?.scheme)
    }

    var previewTrust: PinnedTrustEvaluator? { workspace?.client?.serverTrust }

    func renderer(_ renderer: any BrowserRenderer, changed page: BrowserPageState) {
        guard renderer === self.renderer else { return }
        isLoading = page.isLoading
        progress = page.progress
        canGoBack = page.canGoBack
        canGoForward = page.canGoForward
        if let url = page.url, let shown = locationShowing(url), shown != location {
            location = shown
        }
        reportedTitle = page.title.trimmingCharacters(in: .whitespacesAndNewlines)
        applyTitle()
    }

    /// Names the tab after its page, once a page has shown.
    private func applyTitle() {
        guard hasPage else { return }
        let newTitle = reportedTitle.isEmpty ? location.fallbackTitle : reportedTitle
        guard newTitle != title else { return }
        title = newTitle
        workspace?.rename(tabID, newTitle)
    }

    func renderer(_ renderer: any BrowserRenderer, committed url: URL?) {
        guard renderer === self.renderer else { return }
        hasPage = true
        problem = nil
        if let url, let shown = locationShowing(url) { location = shown }
        applyTitle()
        remember()
        resolve()
    }

    func renderer(_ renderer: any BrowserRenderer, finished url: URL?) {
        guard renderer === self.renderer else { return }
        renewedAutomatically = false
        remember()
        resolve()
    }

    func renderer(_ renderer: any BrowserRenderer, failed error: Error) {
        guard renderer === self.renderer else { return }
        let nsError = error as NSError
        if previewCertificateRejected {
            problem = .certificateMismatch
        } else if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
            // Stopped, or replaced by another navigation: not a problem.
        } else if nsError.domain == "WebKitErrorDomain", nsError.code == 102 {
            // Frame load interrupted by a policy decision, which already said why.
        } else if location.previewPort != nil, ClientError.isUndelivered(error) {
            problem = .hostUnavailable("The host’s preview listener didn’t answer. The host may be stopped, or its preview port blocked on this network.")
        } else {
            problem = .pageFailed(error.localizedDescription)
        }
        resolve()
    }

    func renderer(_ renderer: any BrowserRenderer, refused refusal: BrowserRefusal, isMainFrame: Bool) {
        guard renderer === self.renderer, isMainFrame else { return }
        problem = .refused(refusal)
        resolve()
    }

    func renderer(_ renderer: any BrowserRenderer, previewRefused code: String, status: Int) {
        guard renderer === self.renderer, case let .preview(port, path) = location else { return }
        if code == "preview_session_required", !renewedAutomatically {
            // The host forgot the session (idle, 12 hours, a restart): open a new one once, then reload.
            renewedAutomatically = true
            if let grant { Self.revoke(grant) }
            grant = nil
            openPreview(port: port, path: path)
            return
        }
        problem = BrowserProblem(proxyCode: code, port: port)
        resolve()
    }

    func rendererRejectedPreviewCertificate(_ renderer: any BrowserRenderer) {
        guard renderer === self.renderer else { return }
        previewCertificateRejected = true
        problem = .certificateMismatch
    }

    func rendererContentProcessEnded(_ renderer: any BrowserRenderer) {
        guard renderer === self.renderer else { return }
        // The system reclaimed the page's memory; load it again.
        renderer.reload()
    }

    /// Where `url` is, from this tab's point of view: a path of the previewed port, or a public page.
    private func locationShowing(_ url: URL) -> BrowserLocation? {
        if let grant, BrowserOrigin(grant.originURL)?.contains(url) == true {
            var path = url.path(percentEncoded: true)
            if path.isEmpty { path = "/" }
            if let query = url.query(percentEncoded: true) { path += "?" + query }
            if let fragment = url.fragment(percentEncoded: true) { path += "#" + fragment }
            return .preview(port: grant.port, path: path)
        }
        if BrowserOrigin(url) != nil { return .web(url) }
        return nil
    }

    /// Saves where the tab is (without query or fragment) with the tab, so it reopens there.
    private func remember() {
        guard !ended, let workspace, workspace.isCurrent(hostID: hostID, tabID: tabID) else { return }
        workspace.updateDraft(tabID, location.remembered)
    }

    // MARK: Opening

    private func resolve() {
        resolved = true
        reportPresentationIfReady()
    }

    /// Readiness for the current opening: the start page, a page that showed, or a problem.
    public func reportPresentationIfReady() {
        guard resolved, !ended, let workspace, let ticket = workspace.presentationRequest(for: tabID) else { return }
        workspace.reportPresentationReady(ticket)
    }
}
