import SwiftUI
import AgentLandCore
import AgentLandDesign
#if os(iOS)
import UIKit
#endif

public extension WorkspaceTab {
    /// A browser tab opened for `location` in `projectID`'s workspace. It keeps the location without a
    /// query or fragment, which can carry tokens.
    static func browser(projectID: String, location: BrowserLocation = .blank) -> WorkspaceTab {
        WorkspaceTab(kind: .browser, projectID: projectID, resourceID: location.remembered, title: location.fallbackTitle)
    }
}

#if os(iOS)
/// A browser tab on iPhone and iPad: an address field with a picker of the host's ports (process
/// names shown), Back, Forward, Reload or Stop, a progress bar, Open in Safari for public pages, and
/// clear problems (previews off on the host, a closed port, a certificate that doesn't match). The
/// shell offers it only when the host advertises `preview`; public https pages open either way.
public struct BrowserSurface: View {
    @Environment(WorkspaceModel.self) private var workspace
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.openURL) private var openURL
    private let tab: WorkspaceTab
    @State private var address = ""
    @FocusState private var editingAddress: Bool

    public init(tab: WorkspaceTab) {
        self.tab = tab
    }

    private var session: BrowserSession { workspace.browserSession(for: tab) }
    private var isFront: Bool { workspace.selectedTabID == tab.id }

    public var body: some View {
        let session = self.session
        VStack(spacing: 0) {
            bar(session)
            progressBar(session)
            ZStack(alignment: .top) {
                BrowserPageView(session: session, generation: session.rendererGeneration)
                    .accessibilityElement(children: .contain)
                    .accessibilityHidden(session.location == .blank || (!session.hasPage && session.problem != nil))
                page(session)
            }
            #if os(iOS)
            .safeAreaInset(edge: .top, spacing: 0) { pageNotice(session) }
            #endif
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(AgentLandColor.canvas)
        .onChange(of: isFront, initial: true) { _, front in
            if front { session.show() }
        }
        .task(id: PortsKey(front: isFront, preview: session.previewAvailable)) {
            if isFront, session.previewAvailable { await session.refreshPortsIfNeeded() }
        }
        .onChange(of: workspace.presentationTicket, initial: true) { _, _ in session.reportPresentationIfReady() }
        .onChange(of: workspace.connectionEpoch) { _, _ in session.resumeAfterReconnect() }
        .onChange(of: session.location, initial: true) { _, location in
            if !editingAddress { address = location.displayText }
        }
        .onChange(of: editingAddress) { _, editing in
            address = editing ? session.location.editableText : session.location.displayText
        }
        .agentLandHaptic(.warning, trigger: session.problem) { _, problem in problem != nil }
    }

    private struct PortsKey: Hashable {
        let front: Bool
        let preview: Bool
    }

    // MARK: Bar

    /// The address and the controls. On iPad they share one row; on iPhone Back and Forward move into
    /// the More menu (the edge swipes also go back and forward). At accessibility text sizes the
    /// address gets its own row. The bar keeps the paper/slate `surface` with its hairline; its buttons and menus are
    /// the system's borderless ones in the primary colour, dimmed by `.disabled` alone (BR-2).
    @ViewBuilder private func bar(_ session: BrowserSession) -> some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: AgentLandSpacing.xxSmall) {
                    HStack(spacing: AgentLandSpacing.xxSmall) {
                        portMenu(session)
                        addressField(session)
                    }
                    HStack(spacing: AgentLandSpacing.xxSmall) {
                        backButton(session)
                        forwardButton(session)
                        Spacer(minLength: 0)
                        reloadButton(session)
                        moreMenu(session, includesHistory: false)
                    }
                }
                .padding(.vertical, AgentLandSpacing.xxSmall)
            } else if sizeClass == .regular {
                HStack(spacing: AgentLandSpacing.xxSmall) {
                    backButton(session)
                    forwardButton(session)
                    portMenu(session)
                    addressField(session)
                    reloadButton(session)
                    moreMenu(session, includesHistory: false)
                }
            } else {
                HStack(spacing: AgentLandSpacing.xxSmall) {
                    portMenu(session)
                    addressField(session)
                    reloadButton(session)
                    moreMenu(session, includesHistory: true)
                }
            }
        }
        .buttonStyle(.borderless)
        .tint(Color.primary)
        .padding(.horizontal, AgentLandSpacing.xSmall)
        .frame(minHeight: 52)
        .background(AgentLandColor.surface)
        .workspaceHairline()
    }

    private func addressField(_ session: BrowserSession) -> some View {
        HStack(spacing: AgentLandSpacing.xSmall) {
            Image(systemName: locationSymbol(session.location))
                .font(AgentLandTypeRole.secondary.font)
                .foregroundStyle(AgentLandColor.textSecondary)
                .accessibilityHidden(true)
            TextField("Address or port", text: $address)
                .focused($editingAddress)
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .onSubmit {
                    session.go(to: address)
                    editingAddress = false
                }
                .agentLandFont(.body)
                .foregroundStyle(AgentLandColor.text)
                // The caret keeps the app's accent; the bar's buttons around it are tinted primary.
                .tint(Color.accentColor)
                .accessibilityLabel("Address")
                .accessibilityHint(locationDescription(session.location))
                .accessibilityIdentifier("browserAddress")
            if editingAddress, !address.isEmpty {
                // The text field's clear button, as UIKit draws it: the filled ×, in the tertiary label colour.
                Button { address = "" } label: { BrowserBarLabel(title: "Clear Address", systemImage: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.leading, AgentLandSpacing.small)
        .frame(maxWidth: .infinity, minHeight: 44)
        .background(AgentLandColor.canvas, in: Capsule())
        .overlay(Capsule().strokeBorder(AgentLandColor.separator, lineWidth: 1))
        .contentShape(Capsule())
        .onTapGesture { editingAddress = true }
    }

    @ViewBuilder private func portMenu(_ session: BrowserSession) -> some View {
        if session.previewAvailable {
            Menu {
                switch session.ports {
                case let .loaded(ports) where !ports.isEmpty:
                    Section("Web Servers on the Host") {
                        ForEach(ports) { port in
                            Button { session.open(.preview(port: port.port, path: "/")) } label: {
                                Label(Self.portTitle(port), systemImage: session.location.previewPort == port.port ? "checkmark" : "server.rack")
                            }
                        }
                    }
                case .loaded:
                    Text("No web servers are listening on the host.")
                case .idle, .loading:
                    Text("Looking for web servers…")
                case let .failed(message):
                    Text(message)
                }
                Button("Refresh List", systemImage: "arrow.clockwise") { Task { await session.refreshPorts() } }
            } label: {
                BrowserBarLabel(title: "Web servers on the host", systemImage: "server.rack")
            }
            .menuOrder(.fixed)
            .accessibilityIdentifier("browserPorts")
        }
    }

    private func backButton(_ session: BrowserSession) -> some View {
        Button { session.goBack() } label: { BrowserBarLabel(title: "Back", systemImage: "chevron.backward") }
            .workspaceHover(Circle())
            .disabled(!session.canGoBack)
            .accessibilityIdentifier("browserBack")
    }

    private func forwardButton(_ session: BrowserSession) -> some View {
        Button { session.goForward() } label: { BrowserBarLabel(title: "Forward", systemImage: "chevron.forward") }
            .workspaceHover(Circle())
            .disabled(!session.canGoForward)
            .accessibilityIdentifier("browserForward")
    }

    private func reloadButton(_ session: BrowserSession) -> some View {
        Button {
            if session.isLoading { session.stopLoading() } else { session.reload() }
        } label: {
            BrowserBarLabel(title: session.isLoading ? "Stop Loading" : "Reload",
                            systemImage: session.isLoading ? "xmark" : "arrow.clockwise")
        }
        .workspaceHover(Circle())
        .disabled(session.location == .blank)
        .accessibilityIdentifier("browserReload")
    }

    private func moreMenu(_ session: BrowserSession, includesHistory: Bool) -> some View {
        Menu {
            if includesHistory {
                Button("Back", systemImage: "chevron.backward") { session.goBack() }.disabled(!session.canGoBack)
                Button("Forward", systemImage: "chevron.forward") { session.goForward() }.disabled(!session.canGoForward)
                Divider()
            }
            if let url = session.location.publicURL {
                Button("Open in Safari", systemImage: "safari") { openURL(url) }
                    .accessibilityIdentifier("browserOpenInSafari")
                // The system's share sheet, whose Copy copies the address (BR-5). Only public pages: a preview's
                // address names a port on the host that means nothing elsewhere.
                ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                    .accessibilityIdentifier("browserShare")
            }
            if session.location.previewPort != nil {
                Button("Reconnect Preview", systemImage: "arrow.triangle.2.circlepath") { session.reconnectPreview() }
            }
            if session.location != .blank {
                Button("Start Page", systemImage: "square.grid.2x2") { session.open(.blank) }
            }
        } label: {
            BrowserBarLabel(title: "More", systemImage: "ellipsis")
        }
        .menuOrder(.fixed)
        .accessibilityIdentifier("browserMore")
    }

    @ViewBuilder private func progressBar(_ session: BrowserSession) -> some View {
        ProgressView(value: min(max(session.progress, 0), 1))
            .progressViewStyle(.linear)
            .opacity(session.isLoading ? 1 : 0)
            .accessibilityLabel("Loading")
            .accessibilityHidden(!session.isLoading)
            .agentLandAnimation(.snappy, value: session.isLoading)
    }

    // MARK: Page

    @ViewBuilder private func page(_ session: BrowserSession) -> some View {
        if session.location == .blank {
            BrowserStartPage(session: session, previewAvailable: session.previewAvailable)
        } else if let problem = session.problem, !session.hasPage {
            ContentUnavailable(problem.title, systemImage: problem.systemImage, description: problem.message) {
                problemActions(problem, session: session)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AgentLandColor.canvas)
        } else if let problem = session.problem {
            // With a page shown, iPhone and iPad put the problem above it (`pageNotice`), so it covers none of it.
            #if os(macOS)
            problemNotice(problem, session: session)
                .frame(maxWidth: 520)
                .padding(.horizontal, AgentLandSpacing.small)
                .padding(.top, AgentLandSpacing.xSmall)
            #endif
        } else if session.connecting, !session.hasPage, let port = session.location.previewPort {
            #if os(iOS)
            ProgressView("Opening port \(port)…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(AgentLandColor.canvas)
            #else
            ProgressView { Text("Opening port \(port)…").agentLandFont(.secondary) }
                .foregroundStyle(AgentLandColor.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(AgentLandColor.canvas)
            #endif
        }
    }

    /// A problem with the page still shown, above it in the surface's top safe area on iPhone and iPad (BR-4): the
    /// page moves down under it instead of being covered.
    @ViewBuilder private func pageNotice(_ session: BrowserSession) -> some View {
        if session.location != .blank, session.hasPage, let problem = session.problem {
            problemNotice(problem, session: session)
                .frame(maxWidth: 520)
                .padding(.horizontal, AgentLandSpacing.small)
                .padding(.vertical, AgentLandSpacing.xSmall)
        }
    }

    private func problemNotice(_ problem: BrowserProblem, session: BrowserSession) -> some View {
        InlineNotice(problem.title, message: problem.message, tone: .warning, actionTitle: actionTitle(problem.action),
                     action: problem.action.map { action in { perform(action, session: session) } },
                     onDismiss: { session.dismissProblem() },
                     identifiers: .init(text: "browserProblem", action: "browserProblemAction", dismiss: "browserProblemDismiss"))
    }

    @ViewBuilder private func problemActions(_ problem: BrowserProblem, session: BrowserSession) -> some View {
        if let action = problem.action {
            Button(actionTitle(action) ?? "Try Again") { perform(action, session: session) }
                .buttonStyle(.agentLandPrimary)
                .accessibilityIdentifier("browserProblemAction")
        }
        if session.previewAvailable, problem.action != .choosePort, session.location.previewPort != nil {
            #if os(iOS)
            // The second action under the primary one, the system's bordered button (BR-4).
            Button("Choose Another Port") { session.open(.blank) }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .minimumTapTarget(.reserveSpace)
            #else
            Button("Choose Another Port") { session.open(.blank) }
                .agentLandFont(.body)
                .foregroundStyle(AgentLandColor.tint)
                .minimumTapTarget(.reserveSpace)
            #endif
        }
    }

    private func actionTitle(_ action: BrowserProblem.Action?) -> String? {
        switch action {
        case .retry: "Try Again"
        case .reconnect: "Reconnect"
        case .choosePort: "Choose Another Port"
        case nil: nil
        }
    }

    private func perform(_ action: BrowserProblem.Action, session: BrowserSession) {
        switch action {
        case .retry: session.retry()
        case .reconnect: session.reconnectPreview()
        case .choosePort: session.open(.blank)
        }
    }

    // MARK: Words

    static func portTitle(_ port: PreviewPort) -> String {
        guard let process = port.process else { return "Port \(port.port)" }
        return "\(port.port) · \(process)"
    }

    private func locationSymbol(_ location: BrowserLocation) -> String {
        switch location {
        case .blank: "magnifyingglass"
        case .preview: "server.rack"
        case .web: "lock.fill"
        }
    }

    private func locationDescription(_ location: BrowserLocation) -> String {
        switch location {
        case .blank: "Type an https address or a port on the host."
        case let .preview(port, _): "Showing port \(port) of the host."
        case .web: "Showing a secure page."
        }
    }
}

/// The start page (BR-3): the host's web servers by port and process in an inset grouped list on the canvas, with
/// paper/slate rows, pull to refresh and a Refresh List row; the system's unavailable view when previews are off on
/// the host, when nothing listens, or when the list could not be read.
struct BrowserStartPage: View {
    let session: BrowserSession
    let previewAvailable: Bool

    var body: some View {
        Group {
            if previewAvailable {
                servers
            } else {
                ContentUnavailable("Open a Page", systemImage: "globe",
                                   description: "Type an https address. Web previews are off on this host, so its ports can’t open here.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .groupedPageBackground()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("browserStartPage")
    }

    private var servers: some View {
        List {
            switch session.ports {
            case let .loaded(ports) where !ports.isEmpty:
                Section {
                    ForEach(ports) { port in
                        Button { session.open(.preview(port: port.port, path: "/")) } label: {
                            Label {
                                Text(BrowserSurface.portTitle(port)).foregroundStyle(AgentLandColor.text)
                            } icon: {
                                Image(systemName: "server.rack").accessibilityHidden(true)
                            }
                        }
                        .accessibilityLabel(port.process.map { "Port \(port.port), \($0)" } ?? "Port \(port.port)")
                        .accessibilityHint("Opens it in this tab.")
                        .accessibilityIdentifier("browserPort-\(port.port)")
                    }
                    refreshRow
                } header: {
                    Text("Web Servers on the Host")
                } footer: {
                    Text("Choose one to open it in this tab, or type an https address or a port in the address field.")
                }
                .surfaceRows()
            case .loaded, .failed:
                EmptyView()
            case .idle, .loading:
                Section {
                    ProgressView().frame(maxWidth: .infinity)
                        .accessibilityLabel("Looking for web servers")
                } header: {
                    Text("Web Servers on the Host")
                }
                .surfaceRows()
            }
        }
        .listStyle(.insetGrouped)
        .hidesListPageBackground()
        .refreshable { await session.refreshPorts() }
        .overlay { unavailable }
    }

    private var refreshRow: some View {
        Button("Refresh List", systemImage: "arrow.clockwise") { Task { await session.refreshPorts() } }
            .accessibilityIdentifier("browserRefreshPorts")
    }

    /// Over the empty list, with its action: nothing listens on the host, or the list could not be read.
    @ViewBuilder private var unavailable: some View {
        switch session.ports {
        case let .loaded(ports) where ports.isEmpty:
            ContentUnavailable("No Web Servers", systemImage: "server.rack",
                               description: "Nothing on the host is listening for web requests right now. Start a development server, then refresh.",
                               actionTitle: "Refresh List") { Task { await session.refreshPorts() } }
        case let .failed(message):
            ContentUnavailable("Couldn’t List the Web Servers", systemImage: "exclamationmark.triangle", description: message,
                               actionTitle: "Try Again") { Task { await session.refreshPorts() } }
        default:
            EmptyView()
        }
    }
}

/// A browser bar button's symbol at body size in a 44-point target, named for VoiceOver by its title (BR-2).
private struct BrowserBarLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .labelStyle(.iconOnly)
            .font(AgentLandTypeRole.body.font)
            .agentLandIconFrame(.regular)
            .minimumTapTarget(.reserveSpace)
            .contentShape(Rectangle())
    }
}

/// Hosts a browser session's web view. The view belongs to the session; this container only shows
/// whichever web view the session has now, so a rebuilt surface shows the same page.
struct BrowserPageView: UIViewRepresentable {
    let session: BrowserSession
    /// The session's renderer generation: a change embeds the new web view (or none).
    let generation: Int

    func makeUIView(context: Context) -> BrowserPageContainer { BrowserPageContainer() }

    func updateUIView(_ container: BrowserPageContainer, context: Context) {
        container.show((session.renderer as? WebKitBrowserRenderer)?.webView)
    }

    static func dismantleUIView(_ container: BrowserPageContainer, coordinator: ()) {
        container.show(nil)
    }
}

final class BrowserPageContainer: UIView {
    private weak var current: UIView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ view: UIView?) {
        if view === current, view?.superview === self { return }
        if let current, current.superview === self { current.removeFromSuperview() }
        current = view
        guard let view else { return }
        view.frame = bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(view)
    }
}

#Preview("Start page") {
    let workspace = BrowserSamples.workspace()
    let tab = WorkspaceTab.browser(projectID: "agentland")
    workspace.open(tab)
    return BrowserSurface(tab: tab).environment(workspace)
}

#Preview("Closed port") {
    let workspace = BrowserSamples.workspace()
    let tab = WorkspaceTab.browser(projectID: "agentland", location: .preview(port: 4321, path: "/"))
    workspace.open(tab)
    return BrowserSurface(tab: tab).environment(workspace)
}

#Preview("Previews off, accessibility size") {
    let workspace = BrowserSamples.workspace()
    workspace.capabilities = CapabilitiesResponse(interactions: true, terminal: true)
    let tab = WorkspaceTab.browser(projectID: "agentland")
    workspace.open(tab)
    return BrowserSurface(tab: tab).environment(workspace).dynamicTypeSize(.accessibility2)
}
#endif

#if os(macOS)
/// The Mac's browser destination: the Mac opens pages in its own browser. It lists the host's web
/// servers with Open in Browser (straight to `http://localhost:<port>`, since this Mac is the host)
/// and opens typed https addresses the same way.
public struct BrowserSurface: View {
    @Environment(WorkspaceModel.self) private var workspace
    @Environment(\.openURL) private var openURL
    private let tab: WorkspaceTab
    @State private var address = ""
    @State private var refusal: BrowserRefusal?

    public init(tab: WorkspaceTab) {
        self.tab = tab
    }

    private var session: BrowserSession { workspace.browserSession(for: tab) }

    /// The host is this Mac, reached over loopback: its ports open directly.
    private var hostIsThisMac: Bool {
        guard let host = workspace.client?.address.url.host()?.lowercased() else { return false }
        return ["localhost", "127.0.0.1", "::1"].contains(host)
    }

    public var body: some View {
        let session = self.session
        VStack(alignment: .leading, spacing: AgentLandSpacing.medium) {
            HStack(spacing: AgentLandSpacing.xSmall) {
                TextField("Address or port", text: $address)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(openAddress)
                    .accessibilityIdentifier("browserAddress")
                Button("Open in Browser", action: openAddress)
                    .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let refusal {
                InlineNotice("Can’t open this", message: refusal.message, tone: .warning, onDismiss: { self.refusal = nil })
            }
            if hostIsThisMac, session.previewAvailable {
                WorkspaceSectionHeading("Web Servers on This Mac")
                switch session.ports {
                case let .loaded(ports) where !ports.isEmpty:
                    ForEach(ports) { port in
                        HStack {
                            Text(BrowserMacWords.portTitle(port)).agentLandFont(.body)
                            Spacer()
                            Button("Open in Browser") { open(port: port.port, path: "/") }
                        }
                        .agentLandRowHeight()
                    }
                case .loaded:
                    Text("Nothing is listening for web requests right now.").agentLandFont(.secondary)
                        .foregroundStyle(AgentLandColor.textSecondary)
                case .idle, .loading:
                    ProgressView()
                case let .failed(message):
                    Text(message).agentLandFont(.secondary).foregroundStyle(AgentLandColor.textSecondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(AgentLandSpacing.medium)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AgentLandColor.canvas)
        .task { if hostIsThisMac, session.previewAvailable { await session.refreshPortsIfNeeded() } }
        .onAppear { session.show() }
    }

    private func openAddress() {
        switch BrowserAddress.parse(address, hostNames: session.hostNames) {
        case let .success(.web(url)):
            refusal = nil
            openURL(url)
        case let .success(.preview(port, path)):
            guard hostIsThisMac else { refusal = .previewUnavailable; return }
            refusal = nil
            open(port: port, path: path)
        case .success(.blank):
            break
        case let .failure(reason):
            refusal = reason
        }
    }

    private func open(port: Int, path: String) {
        guard let url = URL(string: "http://localhost:\(port)\(path)") else { return }
        openURL(url)
    }
}

enum BrowserMacWords {
    static func portTitle(_ port: PreviewPort) -> String {
        guard let process = port.process else { return "Port \(port.port)" }
        return "\(port.port) · \(process)"
    }
}
#endif
