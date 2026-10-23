import SwiftUI
import AgentLandCore
import AgentLandChat
import AgentLandArchive
import AgentLandBranding
import AgentLandDesign

/// A sheet the workspace shows over itself.
private enum WorkspaceSheet: Identifiable, Hashable {
    case navigator, picker, resume
    case createWorkspace, homeWorkspacePicker
    case archive(terminals: Bool)
    /// A chat the host no longer has live, read from the archive.
    case archivedChat(String)
    case terminalLog(ArchivedTerminalLog)

    var id: String {
        switch self {
        case .navigator: "navigator"
        case .picker: "picker"
        case .resume: "resume"
        case .createWorkspace: "create-workspace"
        case .homeWorkspacePicker: "home-workspace-picker"
        case let .archive(terminals): terminals ? "archive-terminals" : "archive"
        case let .archivedChat(id): "archived-" + id
        case let .terminalLog(log): "terminal-log-" + log.id
        }
    }
}

/// Where the ⌘+ and ⌘− text size step is saved (see `WorkspaceView.textSizeStep`).
private let textSizeStepKey: String = {
    #if os(iOS)
    "agentland.appTextSizeStep"
    #else
    "agentland.textSizeStep"
    #endif
}()

struct WorkspaceSettingsDrawerMetrics {
    static func height(available: CGFloat) -> CGFloat { max(0, available * 0.8) }
    static func width(available: CGFloat) -> CGFloat { min(640, max(0, available)) }
}

/// Applies a dismissed workspace choice after the shell clears its sheet state.
@MainActor func finishWorkspaceChoice(model: WorkspaceModel, covered: Bool, pickerCancelled: Bool,
                                     action: (@MainActor () -> Void)?) {
    // Cancellation must reset the observed resume intent even when no workspace has been chosen.
    if pickerCancelled { model.pendingSessionResume = nil; return }
    guard !model.locked, !covered, model.currentProject != nil else { return }
    if let action { action() }
}

/// The full-width workspace shell on iPhone, iPad and Mac. Only the selected surface is mounted; its live
/// session remains in the workspace registry. The centered switcher opens Home, standalone chats and every
/// workspace's retained tabs. Resume Work, workspace management and the archive use sheets.
/// Settings is one bottom drawer on all three platforms and is reachable from Home or the native command.
/// The app gives it what the workspace does not own: the host's connection as the app decides it,
/// whether the app covers the workspace (pairing another host), and its Settings.
public struct WorkspaceView<Settings: View, Notices: View>: View {
    @Environment(WorkspaceModel.self) private var model
    @WorkspaceHorizontalSizeClass private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.agentLandArtwork) private var artwork
    /// The text size before ⌘+ and ⌘−: the reader's setting, which the app follows exactly.
    @Environment(\.dynamicTypeSize) private var baseTypeSize
    /// The host's connection as the app decides it; the banner shows it while offline.
    let connection: ConnectionStatus
    /// Checks the connection now; nil when retrying cannot help (no network).
    let retryConnection: (() -> Void)?
    /// The app covers the workspace, as while pairing another host.
    let covered: Bool
    let settings: (_ close: @escaping () -> Void) -> Settings
    /// The app's own notices (a tapped notification that cannot open, a tip), with the workspace's.
    let appNotices: () -> Notices
    /// A row the app puts at the top of Settings (the Mac's status of its own host).
    let sidebarHeader: AnyView?
    /// The connection banner's button, which runs `retryConnection`.
    let retryTitle: String
    /// Bumped by the Mac menu-bar Settings item, which is outside the focused workspace command chain.
    let externalSettingsRequest: Binding<Int>?

    @Environment(\.colorScheme) private var colorScheme
    /// When a sheet last went: a popover presented while it is still going is refused.
    @State private var sheetClosedAt = Date.distantPast
    #if os(iOS)
    /// iPhone (native-full side build, 2026-10-16): the native bottom tab in front, and each tab's own navigation stack.
    /// Chat and Terminal push their sessions; Workspace pushes Files, Git and their pages, and editors and browser tabs;
    /// Settings pushes its pages. The session on top of the tab in front is `model.selectedTabID`; a stack at its root
    /// is Home (nil).
    @State private var phoneTab: PhoneTabDestination = .chat
    @State private var phoneChatPath: [PhoneSessionRoute] = []
    @State private var phoneTerminalPath: [PhoneSessionRoute] = []
    @State private var phoneWorkspacePath = NavigationPath()
    /// The session on top of the Workspace stack and the stack's depth with it on top; nil while none is on top.
    @State private var phoneWorkspaceSession: PhoneStackedSession?
    @State private var phoneSettingsPath = NavigationPath()
    /// A session's page on its way out after Back: it keeps its surface until it has gone, as a cross-fade kept the
    /// outgoing surface before.
    @State private var phonePoppingID: UUID?
    #endif
    @State private var settingsPresented = false
    @State private var sheet: WorkspaceSheet?
    @State private var dismissedSheet: WorkspaceSheet?
    /// A Home action waiting for the person to choose a workspace first.
    @State private var afterWorkspaceChoice: (@MainActor () -> Void)?
    @State private var afterWorkspaceDismissal: (@MainActor () -> Void)?
    @State private var choosingProgram = false
    @State private var choosingChatProvider = false
    @State private var askingForWorkspace = false
    @State private var search = WorkspaceSearchModel()
    @State private var searchPresented = false
    /// The detail column's frame on screen; Home anchors its art to it on iPad.
    @State private var detailFrame: CGRect = .zero
    /// Bumped by the UI tests' rebuild control: every surface view is discarded and built again.
    @State private var surfaceGeneration = 0
    /// What VoiceOver can reach, listed on request by the UI tests' control.
    @State private var voiceOverElements = ""
    @State private var sheetVoiceOverElements = ""
    /// ⌘+ and ⌘− steps from `baseTypeSize`; ⌘0 goes back to it. On iPhone and iPad it is saved under its own key
    /// (a step saved before 2026-09-27 was dropped once then); the Mac keeps its saved step.
    @AppStorage(textSizeStepKey) private var textSizeStep = 0

    public init(connection: ConnectionStatus, retryConnection: (() -> Void)?, covered: Bool,
                @ViewBuilder settings: @escaping (_ close: @escaping () -> Void) -> Settings,
                @ViewBuilder notices: @escaping () -> Notices) {
        self.connection = connection
        self.retryConnection = retryConnection
        self.covered = covered
        self.settings = settings
        self.appNotices = notices
        sidebarHeader = nil
        retryTitle = "Retry"
        externalSettingsRequest = nil
    }

    #if os(macOS)
    /// The Mac's workspace window: `sidebarHeader` sits at the top of the Settings drawer and
    /// `retryTitle` names the connection banner's button.
    public init<Header: View>(connection: ConnectionStatus, retryConnection: (() -> Void)?, retryTitle: String = "Retry",
                              covered: Bool = false, externalSettingsRequest: Binding<Int>,
                              @ViewBuilder sidebarHeader: () -> Header,
                              @ViewBuilder settings: @escaping (_ close: @escaping () -> Void) -> Settings,
                              @ViewBuilder notices: @escaping () -> Notices) {
        self.connection = connection
        self.retryConnection = retryConnection
        self.covered = covered
        self.settings = settings
        self.appNotices = notices
        self.sidebarHeader = AnyView(sidebarHeader())
        self.retryTitle = retryTitle
        self.externalSettingsRequest = externalSettingsRequest
    }
    #endif

    private var phoneSettingsObscuresSession: Bool {
        #if os(iOS)
        WorkspacePlatform.isPhone && phoneTab == .settings
        #else
        false
        #endif
    }
    private var compact: Bool { sizeClass != .regular }
    /// Something covers the surfaces: a sheet, a question, or the iPhone's Settings tab, so the keyboard's Send,
    /// Stop, Regenerate and Commit do not act on the surface behind it.
    private var obscured: Bool {
        phoneSettingsObscuresSession || sheet != nil || settingsPresented || choosingProgram || choosingChatProvider || askingForWorkspace || model.pendingCloseTab != nil
            || model.sidebar.pendingDelete != nil
    }
    // Opening hides interaction/accessibility, but must not obscure the reads
    // that prepare the selected surface behind its cover.
    private var opening: Bool { model.locked || model.presentationPending || covered }
    /// What takes the whole shell out of reach: the opening, the lock and the app's cover on iPhone and
    /// iPad. The Mac shows no opening cover, so its window (This Mac's controls included) stays in reach
    /// while the host's workspaces load; its surfaces still wait for the opening before taking input.
    private var outOfReach: Bool {
        #if os(macOS)
        model.locked || covered
        #else
        opening
        #endif
    }

    public var body: some View {
        let commands = opening ? nil : commandActions
        preparedShell
        .sheet(item: $sheet, onDismiss: workspaceSheetDismissed) { sheet in
            sheetContent(sheet)
                .workspaceSheetFrame()
                .environment(model)
                // The environment `preparedShell` gives the shell does not reach a sheet presented from outside it:
                // without the shell's actions Resume Work's Terminal Logs, New Browser Tab, New Chat and Archive did
                // nothing in its sheet (B-18).
                .environment(\.workspaceShell, shellActions)
                .dynamicTypeSize(textSize)
                .overlay(alignment: .topLeading) { sheetVoiceOverList }
                .task(id: sheet.id) { await listSheetVoiceOverElements() }
                .agentLandSheetPage()
        }
        .alert(model.pendingSessionResume == nil ? "No Workspace Open" : "Choose a Workspace", isPresented: $askingForWorkspace) {
            Button("Open Workspace") { present(.picker) }
                .accessibilityIdentifier("sessionOpenWorkspace")
            Button("Cancel", role: .cancel) { afterWorkspaceChoice = nil; model.pendingSessionResume = nil }
        } message: {
            Text(model.pendingSessionResume == nil
                 ? "Would you like to open a workspace to start your chat or terminal session?"
                 : "This chat has no available workspace saved. Choose a workspace to resume it. AgentLand will remember your choice.")
        }
        .confirmationDialog("New Terminal", isPresented: $choosingProgram, titleVisibility: .visible) {
            ForEach(TerminalProgram.offered(by: model.capabilities)) { program in
                Button(program.displayName) { create(.terminal, program: program) }
                    .accessibilityIdentifier("newTerminalWith-\(program.id)")
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Chat provider", isPresented: $choosingChatProvider, titleVisibility: .visible) {
            PlainChatProviderChoices { startNewChat(provider: $0) }
            Button("Cancel", role: .cancel) {}
        }
        .focusedSceneValue(\.workspaceCommands, commands)
        #if os(iOS)
        // Workspace shortcuts that must win over the focus system and focused settings fields.
        .background {
            WorkspaceTabKeys(next: commands?.nextTab, previous: commands?.previousTab,
                             escape: escapeOverlay)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        #endif
        // The request count, not the target: asking again for the same session asks again.
        .onChange(of: model.sessionResumeRequest, initial: true) { _, _ in
            guard model.pendingSessionResume != nil else { return }
            model.phoneNavigation.afterPanels {
                afterSheet {
                    afterWorkspaceChoice = {
                        if let id = model.selectedProjectID { model.completeSessionResume(in: id) }
                    }
                    askingForWorkspace = true
                }
            }
        }
        .onChange(of: model.resumedArchive, initial: true) { _, target in
            guard let target else { return }
            model.resumedArchive = nil
            switch target {
            case let .archivedChat(id, _): present(.archivedChat(id))
            case let .terminalLog(log): present(.terminalLog(log))
            case .tab: break
            }
        }
        .onChange(of: model.locked) { _, locked in
            // Nothing stays over the lock cover: sheets and questions go, the surfaces stay.
            if locked { dismissAll() }
        }
        .onChange(of: covered) { _, covered in if covered { dismissAll() } }
        .onChange(of: externalSettingsRequest?.wrappedValue ?? 0, initial: true) { _, request in
            if request > 0 {
                showSettings(routeHome: true)
                externalSettingsRequest?.wrappedValue = 0
            }
        }
        .onChange(of: model.pendingCloseTab?.id) { _, id in if id != nil { resignKeyboard() } }
        .onChange(of: sheet) { old, new in
            if old != nil, new == nil { sheetClosedAt = Date(); dismissedSheet = old }
            if old == .resume, new == nil {
                searchPresented = false
                search.query = ""
            }
        }
        .onChange(of: model.selectedProjectID) { _, _ in search.reset() }
        .onAppear { search.workspace = model }
        .modifier(CircusArtworkPreparation())
        .agentLandHaptic(.selection, trigger: model.selectedTabID)
        .agentLandHaptic(.warning, trigger: model.creationIssue) { _, issue in issue != nil }
    }

    /// The full-width shell with its lists loading and what it gives the surfaces.
    private var preparedShell: some View {
        shell
        // Resume Work's lists load with the shell, whether or not its sheet has been built yet.
        .modifier(WorkspaceSidebarLoading())
        .environment(\.workspaceShell, shellActions)
        .environment(\.workspaceObscured, obscured)
        .environment(\.workspaceMenuObscured, obscured)
        .dynamicTypeSize(textSize)
        .accessibilityElement(children: .contain)
        .allowsHitTesting(!outOfReach && !settingsPresented)
        .accessibilityHidden(outOfReach || settingsPresented)
        .overlay { settingsDrawer }
        .animation(AgentLandMotion.smooth.animation(reduceMotion: reduceMotion), value: settingsPresented)
    }

    /// The shell's questions about a tab or a chat (`WorkspaceTabConfirmations`) on a point under the title menu;
    /// the Resume Work library's rows ask their own Delete.
    private var tabConfirmationAnchor: some View {
        DialogAnchor()
            .modifier(WorkspaceTabConfirmations(enabled: true, deleteRowsShown: sheet == .resume))
    }

    // MARK: Columns

    @ViewBuilder private var shell: some View {
        #if os(iOS)
        if WorkspacePlatform.isPhone { phoneShell } else { detailColumn }
        #else
        detailColumn
        #endif
    }

    private var detailColumn: some View {
        NavigationStack {
            surface
                .id(SurfaceIdentity(tabID: model.selectedTabID, generation: surfaceGeneration))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(AgentLandColor.canvas)
                // The questions no row asks point at the actions menu they come from (`DialogAnchor`).
                .overlay(alignment: DialogAnchor.titleMenu) { tabConfirmationAnchor }
                .modifier(WorkspaceToolbar())
                // Recovery notices take part in layout so Home and work surfaces begin below them.
                .safeAreaInset(edge: .top, spacing: 0) { notices }
                .overlay(alignment: .topLeading) { voiceOverList }
                .disabled(showSessionOpening)
                .accessibilityHidden(showSessionOpening)
                .overlay { if showSessionOpening { creatingIndicator } }
        }
        // Home and the empty chat centre their art in the full-width detail column. On iPhone its frame
        // is not kept: each change would build the shell again.
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            if !compact, frame != detailFrame { detailFrame = frame }
        }
        .environment(\.agentLandArtwork, detailArtwork)
    }

    #if os(iOS)
    // MARK: iPhone tabs

    /// iPhone (native-full side build, 2026-10-16): four native tabs, each with its own navigation stack and the system's
    /// bars. Chat and Terminal show Home (the art and that tab's launchers) under the workspace's name, which opens the
    /// task switcher (`PhoneTaskSwitcher`: every open workspace and its terminals and chats, owner, 2026-10-22);
    /// a session is a page pushed on its tab's stack. Workspace pushes Files, Git and their pages, and editors and
    /// browser tabs; Settings pushes its pages. The tab bar shows on every screen but an open
    /// chat's or terminal's page (owner, 2026-10-16: "i dont want the bottom nativigation to appear on the chat or
    /// terminal tab").
    private var phoneShell: some View {
        let navigation = model.phoneNavigation
        return creationIssueAlert(
            TabView(selection: phoneTabSelection) {
                Tab("Chat", systemImage: "bubble.left.and.bubble.right.fill", value: PhoneTabDestination.chat) {
                    NavigationStack(path: phoneSessionPath(.chat)) {
                        phoneHomeRoot(.chat)
                            .navigationDestination(for: PhoneSessionRoute.self) { phoneSessionPage($0) }
                    }
                }
                Tab("Terminal", systemImage: "terminal.fill", value: PhoneTabDestination.terminal) {
                    NavigationStack(path: phoneSessionPath(.terminal)) {
                        phoneHomeRoot(.terminal)
                            .navigationDestination(for: PhoneSessionRoute.self) { phoneSessionPage($0) }
                    }
                }
                Tab("Workspace", systemImage: "folder", value: PhoneTabDestination.workspace) {
                    NavigationStack(path: phoneWorkspacePathBinding) {
                        phoneWorkspaceRoot
                            .navigationDestination(for: PhoneToolsRoute.self) { route in
                                phonePage(WorkspacePhoneExplorer(section: route.section,
                                                                 chooseWorkspace: { present(.homeWorkspacePicker) }),
                                          notices: phoneTab == .workspace && phoneWorkspaceSession == nil)
                            }
                            .navigationDestination(for: WorkspacePhoneNavigation.DrawerPage.self) { page in
                                phonePage(WorkspacePhoneDrawerPageView(page: page), notices: false)
                            }
                            .navigationDestination(for: PhoneSessionRoute.self) { phoneSessionPage($0) }
                    }
                }
                Tab("Settings", systemImage: "gearshape.fill", value: PhoneTabDestination.settings) {
                    NavigationStack(path: $phoneSettingsPath) {
                        phonePage(settings(closeSettings).environment(\.workspaceSettingsExit, nil),
                                  notices: phoneTab == .settings && phoneSettingsPath.isEmpty)
                    }
                }
            }
        )
        .background(AgentLandColor.canvas.color.ignoresSafeArea())
        // The UI tests' read of the tab in front and of what VoiceOver reaches.
        .overlay(alignment: .topLeading) { voiceOverList }
        // The questions no row asks (an editor closed from a menu, a chat's Delete) point under the title (`DialogAnchor`).
        .overlay(alignment: DialogAnchor.titleMenu) { tabConfirmationAnchor }
        .task(id: phonePageID) {
            if workspaceUITestHooks { listVoiceOverElements() }
        }
        // The task switcher closes when the page in front changes (owner, 2026-10-22).
        .onChange(of: phonePageID) { _, _ in navigation.dismissPopovers() }
        // Files and Git are Workspace's pages on iPhone: opening one (Browse files, a folder from search) shows it there (B-3).
        .onAppear {
            navigation.drawerHoldsBrowsers = true
            navigation.closePanels = nil
        }
        .onChange(of: navigation.revealRequest) { _, _ in showPhoneTools(navigation.drawerSection) }
        .onChange(of: model.hostID, initial: true) { _, _ in navigation.restore(hostKey: model.identity?.storageKey) }
        .onChange(of: phoneSelectionState, initial: true) { old, new in followPhoneSelection(from: old, to: new) }
        #if DEBUG
        // `-AgentLandPhoneDemo switch` switches to another open tab
        // 1.5 s after the opening clears and goes back 2.5 s later, for recordings on a paired simulator; `tab-<name>`
        // shows that bottom tab.
        .onChange(of: model.presentationPending, initial: true) { _, pending in
            guard !pending, let demo = Self.phoneDemo, !phoneDemoRan else { return }
            phoneDemoRan = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { runPhoneDemo(demo) }
        }
        #endif
    }

    /// The page in front: the tab and its stack's top.
    private var phonePageID: String {
        "\(phoneTab)|\(String(describing: model.selectedTabID))|\(phoneWorkspacePath.count)|\(phoneSettingsPath.count)"
    }

    /// A page of a tab: the connection's and the app's notices under its bar while it is in front, and the canvas
    /// behind it and its bars (the system's Liquid Glass and scroll-edge effect over it). A painted terminal's backdrop
    /// stands in for the canvas behind its page.
    private func phonePage<Content: View>(_ content: Content, notices shown: Bool, background: Color? = nil) -> some View {
        let fill = background ?? AgentLandColor.canvas.color
        return content
            .safeAreaInset(edge: .top, spacing: 0) { if shown { noticeContent } }
            .background { fill.ignoresSafeArea() }
            .containerBackground(fill, for: .navigation)
    }

    /// Chat's and Terminal's root: Home with that tab's launchers, under the workspace in use's name, which opens the
    /// task switcher (`PhoneTaskSwitcherTitle`, owner, 2026-10-22) with this workspace's Home checked and the UI tests'
    /// controls at its foot (Home has no ••• button). Each tab keeps its own Home; only the one in front animates.
    private func phoneHomeRoot(_ destination: PhoneTabDestination) -> some View {
        let atRoot = destination == .terminal ? phoneTerminalPath.isEmpty : phoneChatPath.isEmpty
        let inFront = phoneTab == destination && atRoot
        let opening = inFront && showSessionOpening
        let title = model.currentProject?.name ?? "AgentLand"
        return phonePage(
            HomeView(tabID: nil, tabLaunchers: AnyView(PhoneLaunchButtons(destination: destination)), visible: inFront)
                .environment(\.workspaceSurfaceTabID, nil)
                .disabled(opening)
                .accessibilityHidden(opening)
                .overlay(alignment: .topLeading) { if inFront { phoneSessionStarters } }
                // A new chat or terminal is being made: the loader in the work area, the bars in reach.
                .overlay { if opening { creatingIndicator } }
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    PhoneTaskSwitcherTitle(model: model, shell: shellActions, title: title,
                                           current: model.phoneNavigation.switcherWorkspaceID(model: model).map { .home(projectID: $0) },
                                           testControls: true)
                }
                // The stack's root says whether the tab bar shows, from the stack itself: hidden while a chat's or
                // terminal's page is on it and back as Back starts, so it comes in with Home instead of after the
                // pop with Home's launchers jumping up (owner, 2026-10-22). Hidden is asked once the opening cover has
                // gone: asked under it, for a page restored at launch, the system kept the bar ("the tab bar at the
                // bottom persist when going back to a terminal"). The root's choice outranks a pushed page's.
                .toolbarVisibility(phoneStackShowsSession(destination) && !model.presentationPending ? .hidden : .visible,
                                   for: .tabBar),
            notices: inFront)
    }

    /// A chat's or a terminal's page is on top of Chat's or Terminal's stack.
    private func phoneStackShowsSession(_ destination: PhoneTabDestination) -> Bool {
        let path = destination == .terminal ? phoneTerminalPath : phoneChatPath
        guard let top = path.last, let kind = model.tab(top.tabID)?.kind else { return false }
        return kind == .chat || kind == .terminal
    }

    /// Workspace's root: the workspace in use, other devices' terminals, Files, Git, Chat History and the workspaces.
    private var phoneWorkspaceRoot: some View {
        let inFront = phoneTab == .workspace && phoneWorkspacePath.isEmpty
        return phonePage(
            PhoneWorkspaceHome()
                .disabled(inFront && showSessionOpening)
                .overlay { if inFront && showSessionOpening { creatingIndicator } }
                .navigationTitle("Workspace")
                .navigationBarTitleDisplayMode(.large),
            notices: inFront)
    }

    /// A session's page. Only the session in front mounts its surface (its live state stays in the workspace's
    /// registry); a page on its way out after Back keeps it until it has gone. The loader covers the work area while a
    /// new session opens; the navigation bar stays in reach. A chat's or terminal's page hides the tab bar, as a pushed
    /// conversation does (its stack's root says so, `phoneHomeRoot`); Back brings it back. Editors and browser tabs keep it.
    @ViewBuilder private func phoneSessionPage(_ route: PhoneSessionRoute) -> some View {
        let tab = model.tab(route.tabID)
        let selected = model.selectedTabID == route.tabID
        let opening = selected && showSessionOpening
        phonePage(
            ZStack {
                if let tab, selected || phonePoppingID == route.tabID {
                    surface(for: tab)
                        .id(SurfaceIdentity(tabID: tab.id, generation: surfaceGeneration))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .disabled(opening)
                        .accessibilityHidden(opening)
                }
                if opening { creatingIndicator }
            }
            .onDisappear { if phonePoppingID == route.tabID { phonePoppingID = nil } },
            notices: selected, background: selected ? model.phoneChromeAppearance?.background : nil)
    }

    // MARK: iPhone stacks and the selection

    /// The tab bar's selection: another tab shows its own stack, with the session on top of it in front (Home at its
    /// root); the tab in front chosen again goes back to its root, as the system's tabs do.
    private var phoneTabSelection: Binding<PhoneTabDestination> {
        Binding(get: { phoneTab }, set: { destination in
            if destination == phoneTab { popPhoneTabToRoot(destination) } else { switchPhoneTab(destination) }
        })
    }

    private func switchPhoneTab(_ destination: PhoneTabDestination) {
        guard destination != phoneTab else { return }
        resignKeyboard()
        phoneTab = destination
        model.selectedTabID = phoneTopSession(destination)
    }

    /// The open session on top of a tab's stack; nil at its root (Home), or on Settings.
    private func phoneTopSession(_ destination: PhoneTabDestination) -> UUID? {
        let id: UUID?
        switch destination {
        case .chat: id = phoneChatPath.last?.tabID
        case .terminal: id = phoneTerminalPath.last?.tabID
        case .workspace: id = phoneWorkspaceSession.flatMap { $0.depth == phoneWorkspacePath.count ? $0.tabID : nil }
        case .settings: id = nil
        }
        return id.flatMap { model.tab($0) == nil ? nil : $0 }
    }

    private func popPhoneTabToRoot(_ destination: PhoneTabDestination) {
        switch destination {
        case .chat, .terminal: phoneSessionPath(destination).wrappedValue = []
        case .workspace: phoneWorkspacePathBinding.wrappedValue = NavigationPath()
        case .settings: phoneSettingsPath = NavigationPath()
        }
    }

    /// Chat's or Terminal's stack. Back (or the tab chosen again) takes its session's page away and shows Home; the
    /// session stays open, in the title menu.
    private func phoneSessionPath(_ destination: PhoneTabDestination) -> Binding<[PhoneSessionRoute]> {
        Binding(get: { destination == .terminal ? phoneTerminalPath : phoneChatPath }, set: { path in
            let old = destination == .terminal ? phoneTerminalPath : phoneChatPath
            if destination == .terminal { phoneTerminalPath = path } else { phoneChatPath = path }
            guard let top = old.last?.tabID, path.last?.tabID != top, model.selectedTabID == top else { return }
            phonePopping(top)
            model.selectedTabID = path.last?.tabID
        })
    }

    /// Workspace's stack: Back from an editor or a browser tab shows the page under it with the task still open.
    private var phoneWorkspacePathBinding: Binding<NavigationPath> {
        Binding(get: { phoneWorkspacePath }, set: { path in
            phoneWorkspacePath = path
            guard let session = phoneWorkspaceSession, path.count < session.depth else { return }
            phoneWorkspaceSession = nil
            if model.selectedTabID == session.tabID {
                phonePopping(session.tabID)
                model.selectedTabID = nil
            }
        })
    }

    private func phonePopping(_ id: UUID) {
        resignKeyboard()
        phonePoppingID = id
        // The page reports that it has gone; this is the fallback.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { if phonePoppingID == id { phonePoppingID = nil } }
    }

    private var phoneSelectionState: PhoneSelectionState {
        PhoneSelectionState(host: model.hostID, selected: model.selectedTabID, selectedKind: model.currentTab?.kind,
                            tabs: model.tabs.map(\.id), workspace: model.phoneNavigation.switcherWorkspaceID(model: model))
    }

    /// Keeps the stacks and the selection together: whatever selects a task (a launcher, Resume, Chat History, the
    /// title menu, a notification) pushes it on its own tab's stack and shows that tab; Home pops the tab in front.
    private func followPhoneSelection(from old: PhoneSelectionState, to new: PhoneSelectionState) {
        // The restored task at launch, or another host's, is in place at once (behind the opening cover), not pushed.
        guard old != new, old.host == new.host else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { followPhoneSelectionNow(from: old, to: new) }
            return
        }
        followPhoneSelectionNow(from: old, to: new)
    }

    private func followPhoneSelectionNow(from old: PhoneSelectionState, to new: PhoneSelectionState) {
        let navigation = model.phoneNavigation
        if old.host != new.host { resetPhoneStacks() }
        // Files and Git are Workspace's pages, never the task in front; the change this makes is followed next.
        navigation.reconcileSelection(model: model)
        guard model.selectedTabID == new.selected else { return }
        reconcilePhoneStacks()
        // The session in front closed: its page goes back to Home, not to the task the model put in its place.
        if old.host == new.host, let closed = old.selected, closed != new.selected, !new.tabs.contains(closed),
           let kind = old.selectedKind, kind != .home, kind != .files, kind != .git, new.selected != nil {
            model.selectedTabID = nil
            return
        }
        showPhoneSelection()
    }

    private func showPhoneSelection() {
        guard let tab = model.currentTab, tab.kind != .home else { popPhoneSession(); return }
        guard tab.kind != .files, tab.kind != .git else { return }
        let destination = PhoneTabDestination.hosting(tab.kind)
        if phoneTab != destination {
            resignKeyboard()
            phoneTab = destination
        }
        let route = PhoneSessionRoute(tabID: tab.id)
        switch destination {
        case .chat: if phoneChatPath != [route] { phoneChatPath = [route] }
        case .terminal: if phoneTerminalPath != [route] { phoneTerminalPath = [route] }
        case .workspace:
            if let session = phoneWorkspaceSession, session.depth == phoneWorkspacePath.count {
                if session.tabID == tab.id { return }
                phoneWorkspacePath.removeLast()
            }
            phoneWorkspacePath.append(route)
            phoneWorkspaceSession = PhoneStackedSession(tabID: tab.id, depth: phoneWorkspacePath.count)
        case .settings: break
        }
    }

    /// Home in front: the session on top of the tab in front goes; its tab stays open.
    private func popPhoneSession() {
        switch phoneTab {
        case .chat: if !phoneChatPath.isEmpty { phoneChatPath = [] }
        case .terminal: if !phoneTerminalPath.isEmpty { phoneTerminalPath = [] }
        case .workspace:
            if let session = phoneWorkspaceSession, session.depth == phoneWorkspacePath.count { phoneWorkspacePath.removeLast() }
            phoneWorkspaceSession = nil
        case .settings: break
        }
    }

    /// Drops the pages of tasks that closed, or that belong to a workspace no longer in use.
    private func reconcilePhoneStacks() {
        let navigation = model.phoneNavigation
        let working = Set(navigation.switcherWorkspaceID(model: model)
            .map { navigation.workingTasks(inWorkspace: $0, model: model).map(\.id) } ?? [])
        func keeps(_ route: PhoneSessionRoute) -> Bool {
            model.tab(route.tabID) != nil && (route.tabID == model.selectedTabID || working.contains(route.tabID))
        }
        if !phoneChatPath.allSatisfy(keeps) { phoneChatPath = phoneChatPath.filter(keeps) }
        if !phoneTerminalPath.allSatisfy(keeps) { phoneTerminalPath = phoneTerminalPath.filter(keeps) }
        if let session = phoneWorkspaceSession {
            if session.depth != phoneWorkspacePath.count {
                phoneWorkspaceSession = nil
            } else if !keeps(PhoneSessionRoute(tabID: session.tabID)) {
                phoneWorkspacePath.removeLast()
                phoneWorkspaceSession = nil
            }
        }
    }

    /// Another host: every stack starts at its root.
    private func resetPhoneStacks() {
        phoneChatPath = []
        phoneTerminalPath = []
        phoneWorkspacePath = NavigationPath()
        phoneWorkspaceSession = nil
        phoneSettingsPath = NavigationPath()
        phonePoppingID = nil
    }

    /// A workspace's row in the task switcher: its Home on the Chat or Terminal tab in front; from Workspace's pages (an
    /// editor, a browser tab) on Terminal's, as switching terminals is the app's main job (2026-10-22). No tab closes.
    private func showPhoneWorkspaceHome(_ projectID: String) {
        if phoneTab != .chat && phoneTab != .terminal {
            resignKeyboard()
            phoneTab = .terminal
        }
        model.phoneNavigation.showWorkspaceHome(projectID, model: model)
    }

    /// Browse Files and Git (an agent chat, Resume Work's search) push Workspace's Files or Git page.
    private func showPhoneTools(_ section: WorkspacePhoneNavigation.DrawerSection) {
        resignKeyboard()
        phoneTab = .workspace
        phoneWorkspaceSession = nil
        phoneWorkspacePath = NavigationPath([PhoneToolsRoute(section: section)])
        model.selectedTabID = nil
    }

    #if DEBUG
    @State private var phoneDemoRan = false
    private static var phoneDemo: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-AgentLandPhoneDemo"), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    private func runPhoneDemo(_ demo: String) {
        let back = DispatchTime.now() + 2.5
        switch demo {
        case "switch":
            let previous = model.selectedTabID
            guard let other = model.tabs.first(where: { $0.id != previous && ($0.kind == .chat || $0.kind == .terminal) }) else { return }
            model.selectedTabID = other.id
            DispatchQueue.main.asyncAfter(deadline: back) { model.selectedTabID = previous }
        case "terminal-page", "terminal-back":
            // `-AgentLandPhoneDemo terminal-page` opens a stand-in terminal tab, pushed on Terminal, for screenshots of
            // a session's page on a simulator without a paired host; `terminal-back` then goes Back as the bar's button
            // does, 2.5 s later.
            model.open(WorkspaceTab(kind: .terminal, projectID: model.selectedProjectID ?? "demo", resourceID: "demo-terminal",
                                    title: "Demo Terminal"))
            if demo == "terminal-back" {
                DispatchQueue.main.asyncAfter(deadline: back) { phoneSessionPath(.terminal).wrappedValue = [] }
            }
        case "files", "git":
            // `-AgentLandPhoneDemo files` (or git) pushes Workspace's page, as Browse Files does.
            showPhoneTools(demo == "files" ? .files : .git)
        case let tab where tab.hasPrefix("tab-"):
            // `-AgentLandPhoneDemo tab-workspace` (or tab-settings, tab-terminal) shows that tab, for screenshots.
            if let destination = PhoneTabDestination(rawValue: String(tab.dropFirst(4))) { switchPhoneTab(destination) }
        default:
            break
        }
    }
    #endif

    #endif

    private var escapeOverlay: (@MainActor @Sendable () -> Void)? {
        if WorkspacePlatform.isPhone {
            if model.phoneNavigation.popoverShown { return { model.phoneNavigation.dismissPopovers() } }
        }
        if settingsPresented { return { closeSettings() } }
        return nil
    }

    /// Settings keeps its bottom-origin drawer. iPad uses native Liquid Glass as the iPhone's panels do;
    /// the Mac retains its material and tone. Pages draw no background over the drawer's material.
    @ViewBuilder private var settingsDrawer: some View {
        if settingsPresented {
            GeometryReader { proxy in
                ZStack(alignment: .bottom) {
                    Color.black.opacity(0.22)
                        .contentShape(Rectangle())
                        .onTapGesture { closeSettings() }
                        .accessibilityHidden(true)
                    VStack(spacing: 0) {
                        HStack {
                            Spacer(minLength: 0)
                            SettingsCloseButton(action: closeSettings)
                        }
                        .padding(.horizontal, AgentLandSpacing.small)
                        .frame(minHeight: AgentLandTapTarget.platformMinimum)
                        if let sidebarHeader {
                            sidebarHeader
                                .padding(.horizontal, AgentLandSpacing.medium)
                                .padding(.bottom, AgentLandSpacing.small)
                        }
                        NavigationStack { settings(closeSettings) }
                            .environment(\.workspaceSettingsExit, .overlay(close: closeSettings))
                            .modifier(SettingsDrawerPage())
                    }
                    .foregroundStyle(AgentLandColor.text)
                    .frame(width: WorkspaceSettingsDrawerMetrics.width(available: proxy.size.width),
                           height: WorkspaceSettingsDrawerMetrics.height(available: proxy.size.height))
                    #if os(iOS)
                    .glassControl(in: UnevenRoundedRectangle(topLeadingRadius: AgentLandRadius.card,
                                                             topTrailingRadius: AgentLandRadius.card), interactive: false)
                    #else
                    .background {
                        if reduceTransparency {
                            SettingsDrawerPage.tone.color
                        } else {
                            Rectangle()
                                .fill(.ultraThinMaterial)
                                .overlay(SettingsDrawerPage.tone.color.opacity(0.78))
                        }
                    }
                    #endif
                    .clipShape(.rect(topLeadingRadius: AgentLandRadius.card,
                                     topTrailingRadius: AgentLandRadius.card))
                    .overlay(alignment: .top) {
                        Capsule().fill(AgentLandColor.separator).frame(width: 38, height: 5)
                            .padding(.top, AgentLandSpacing.xSmall)
                            .accessibilityHidden(true)
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityAddTraits(.isModal)
                    .accessibilityAction(.escape) { closeSettings() }
                    #if os(macOS)
                    .onExitCommand(perform: closeSettings)
                    #endif
                }
                .ignoresSafeArea()
            }
            .transition(reduceMotion ? .opacity : .move(edge: .bottom))
            .accessibilityIdentifier("settingsDrawer")
        }
    }

    private struct SurfaceIdentity: Hashable {
        let tabID: UUID?
        let generation: Int
    }

    /// Only the selected surface is mounted; its session keeps what it holds while it is not. It knows its tab, which
    /// the iPhone's task menu uses to take only the menu of the task in front.
    private var surface: some View { surface(for: model.currentTab) }

    /// `tab`'s surface: the tab in front's, or on iPhone a session page's on its way out after Back.
    private func surface(for tab: WorkspaceTab?) -> some View {
        mountedSurface(tab).environment(\.workspaceSurfaceTabID, tab?.id)
    }

    @ViewBuilder private func mountedSurface(_ tab: WorkspaceTab?) -> some View {
        if let tab {
            switch tab.kind {
            case .home: HomeView(tabID: tab.id)
            case .chat:
                if model.supportsTab(tab) { ChatTabView(tab: tab) }
                else { HomeView(tabID: tab.id) }
            case .terminal: TerminalTabView(tab: tab)
            case .files: FilesTabView(tab: tab)
            case .editor: EditorTabView(tab: tab)
            case .git: GitSurface(tab: tab)
            case .browser:
                BrowserSurface(tab: tab)
                    .surfaceTitle(tab.title, systemImage: "globe", identifier: "browserActions") {
                        Button("Reload", systemImage: "arrow.clockwise") { model.reloadTab(tab.id) }
                    }
            }
        } else {
            HomeView(tabID: nil)
        }
    }

    private var detailArtwork: AgentLandArtworkLayout {
        guard sizeClass == .regular, detailFrame.width > 0, detailFrame.height > 0 else { return artwork }
        return AgentLandArtworkLayout(windowFrame: detailFrame, referenceDate: artwork.referenceDate)
    }

    /// Notices reserve room at the top of the surface, under the navigation bar: the connection's state
    /// and the app's own (NO-1). A chat or terminal the host refused or may have opened is the
    /// system's alert on iPhone and iPad, which OK puts away; the Mac keeps it in the stack.
    private var notices: some View {
        #if os(iOS)
        creationIssueAlert(noticeContent)
        #else
        noticeContent
        #endif
    }

    #if os(iOS)
    /// A chat or terminal the host refused or may have opened: the system's alert, which OK puts away. iPhone attaches
    /// it once, to its tabs.
    private func creationIssueAlert<Content: View>(_ content: Content) -> some View {
        content.alert(model.creationIssue ?? "", isPresented: Binding(get: { model.creationIssue != nil && !opening },
                                                                      set: { if !$0 { model.creationIssue = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }
    #endif

    private var noticeContent: some View {
        VStack(spacing: AgentLandSpacing.xSmall) {
            if !opening {
                // Draws nothing while online. VoiceOver reads it before the surface.
                ConnectionStatusBanner(status: connection, retryTitle: retryTitle, retry: retryConnection,
                                       identifier: "connectionBanner", retryIdentifier: "connectionRetry")
            }
            #if os(macOS)
            if let issue = model.creationIssue {
                InlineNotice(issue, tone: .warning, onDismiss: { model.creationIssue = nil },
                             identifiers: .init(text: "creationIssue", dismiss: "dismissCreationIssue"))
            }
            #endif
            if !opening { appNotices() }
        }
        .frame(maxWidth: 520)
        .padding(.horizontal, AgentLandSpacing.small)
        .padding(.top, AgentLandSpacing.xSmall)
    }

    private var showSessionOpening: Bool {
        #if DEBUG
        model.sessionOpening || ProcessInfo.processInfo.arguments.contains("-AgentLandSessionOpeningPreview")
        #else
        model.sessionOpening
        #endif
    }

    /// The same morphing artwork as the app's opening cover, centred in the work
    /// area. Keeping this out of the notices inset avoids moving Home while waiting.
    private var creatingIndicator: some View {
        AgentLandCircusLoader()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AgentLandColor.artBackdrop)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Opening…")
            .accessibilityIdentifier("sessionOpeningLoader")
    }

    /// UI tests read what VoiceOver can reach here: their own element tree also lists elements SwiftUI
    /// hides from VoiceOver. They also read which tab is in front ("Current tab: <title>", with the
    /// workspace line as its value): the bar shows only the tab's title, as the system's own on iPad.
    @ViewBuilder private var voiceOverList: some View {
        if workspaceUITestHooks {
            VStack(spacing: 0) {
                Color.clear.frame(width: 1, height: 1)
                    .accessibilityElement()
                    .accessibilityLabel("VoiceOver elements")
                    .accessibilityValue(voiceOverElements)
                    .accessibilityIdentifier("debugVoiceOverElements")
                Color.clear.frame(width: 1, height: 1)
                    .accessibilityElement()
                    .accessibilityLabel("Current tab: \(model.currentTab?.title ?? "Home")")
                    .accessibilityValue(workspaceLine(model) ?? "")
                    .accessibilityIdentifier("debugCurrentTab")
            }
        }
    }

    #if os(iOS)
    /// UI-test runs only, on the iPhone's Home (Chat or Terminal destination): ⌥⌘T's shell terminal and ⌘N's chat as
    /// two clear buttons the tests tap, where Home shows nothing else. They run exactly what those commands run. The
    /// simulator dropped ⌥⌘T on iPhone five times in a row after touches (runs 1791772962 and 1791773306), so tests
    /// start sessions here.
    @ViewBuilder private var phoneSessionStarters: some View {
        if workspaceUITestHooks, model.currentTab == nil || model.currentTab?.kind == .home,
           phoneTab == .chat || phoneTab == .terminal {
            let area = Color.clear.frame(width: 40, height: 40).contentShape(Rectangle())
            HStack(spacing: 8) {
                Button { commandActions.newTerminal?() } label: { area }
                    .accessibilityLabel("New shell terminal (UI tests)")
                    // What a new terminal needs, for the tests' logs.
                    .accessibilityValue("opening \(model.sessionOpening), projects \(model.projects.count), "
                                        + "creating \(model.creating), terminal \(model.capabilities?.terminal == true), "
                                        + "workspace \(model.currentProject?.id ?? "none")")
                    .accessibilityIdentifier("debugNewShellTerminal")
                Button { commandActions.newChat?() } label: { area }
                    .accessibilityLabel("New chat (UI tests)")
                    .accessibilityIdentifier("debugNewChat")
            }
            .buttonStyle(.plain)
            // Below the header, beside Home's title, where Home has nothing to tap. Tiny ones missed every tap (4 and
            // 8 points: taps 0, runs 1791774298 and 1791774734).
            .padding(4)
        }
    }
    #endif

    /// The same list for a sheet, whose content covers the tab menu: made once the sheet has settled.
    @ViewBuilder private var sheetVoiceOverList: some View {
        if workspaceUITestHooks {
            Color.clear.frame(width: 1, height: 1)
                .accessibilityElement()
                .accessibilityLabel("VoiceOver elements in the sheet")
                .accessibilityValue(sheetVoiceOverElements)
                .accessibilityIdentifier("debugSheetVoiceOverElements")
        }
    }

    private func listSheetVoiceOverElements() async {
        guard workspaceUITestHooks else { return }
        sheetVoiceOverElements = ""
        try? await Task.sleep(for: .seconds(1.5))
        guard !Task.isCancelled else { return }
        sheetVoiceOverElements = reachableAccessibilityElements().joined(separator: "\n")
    }

    private func listVoiceOverElements() {
        Task { @MainActor in
            // After the menu has closed and the surface has settled.
            try? await Task.sleep(for: .seconds(1))
            voiceOverElements = reachableAccessibilityElements().joined(separator: "\n")
        }
    }

    // MARK: Sidebar selection

    /// The Resume Work sheet reuses the existing rich chat, terminal and archive rows.
    private var sidebarSelection: Binding<SidebarItem?> {
        Binding(get: {
            return currentSidebarItem
        }, set: { item in
            guard let item else { return }
            choose(item)
        })
    }

    private var currentSidebarItem: SidebarItem {
        guard let tab = model.currentTab else { return .home }
        switch tab.kind {
        case .files: return .files
        case .git: return .git
        case .chat where model.sidebar.listsChat(tab.resourceID):
            return .chat(tab.resourceID)
        case .terminal where model.sidebar.terminals?.contains { $0.id == tab.resourceID } == true:
            return .terminal(tab.resourceID)
        default: return .tab(tab.id)
        }
    }

    private func choose(_ item: SidebarItem) {
        let asked = model.sessionResumeRequest
        switch item {
        case .home:
            model.selectedTabID = nil
        case .files:
            withWorkspace { model.showFiles() }
        case .git:
            withWorkspace { model.showGit() }
        case let .tab(id):
            // An open tab is only selected: a Home tab in front stays.
            guard let tab = model.tab(id), model.supportsTab(tab) else { return }
            model.requestResume(.tab(tab))
        case let .chat(id):
            // Resume restores the chat’s associated workspace first. Launched from a Home tab, it takes its place.
            let archived = model.sidebar.chat(id)
            let session = model.sidebar.session(id)
            let known = archived?.projectID ?? session?.projectID
            guard let known, model.isChatShown(id, projectID: known, provider: archived?.provider ?? session?.provider) else { return }
            guard model.sidebar.isLive(id, projectID: known) else { showArchivedChat(id); return }
            let project = known
            let title = archived.map(model.sidebar.title(for:)) ?? session?.title ?? "Chat"
            model.requestResume(.tab(WorkspaceTab(kind: .chat, projectID: project, resourceID: id, title: title)),
                                replacingHome: model.launchingHomeTabID)
        case let .terminal(id):
            if let ended = model.sidebar.resumeTerminalLogs.first(where: { $0.id == id && !$0.isRunning }) {
                model.requestResume(.terminalLog(ended))
            } else if let terminal = (model.sidebar.resumeTerminals + (model.sidebar.terminals ?? [])).first(where: { $0.id == id && $0.status == .running }) {
                model.requestResume(.tab(.terminal(terminal, projectID: terminal.projectID)), replacingHome: model.launchingHomeTabID)
            } else if let log = model.sidebar.resumeTerminalLogs.first(where: { $0.id == id }) {
                model.requestResume(.terminalLog(log))
            } else {
                model.creationIssue = "This terminal is no longer running, and its saved output is not available yet."
            }
        }
        if sheet == .resume, !resumeFollowsUp(since: asked) { sheet = nil }
    }

    // MARK: Shell actions

    private var shellActions: WorkspaceShellActions {
        var actions = WorkspaceShellActions()
        actions.openNavigator = { present(.navigator) }
        actions.openPicker = { present(.picker) }
        actions.createWorkspace = { present(.createWorkspace) }
        actions.openHomeWorkspacePicker = { present(WorkspacePlatform.isPhone ? .homeWorkspacePicker : .picker) }
        actions.showSettings = { showSettings() }
        actions.showGit = { withWorkspace { model.showGit() } }
        actions.showArchive = { terminals in present(.archive(terminals: terminals)) }
        actions.focusSearch = { focusSearch() }
        actions.openRecent = { item in choose(item) }
        actions.withWorkspace = { action in withWorkspace(action) }
        actions.newTerminal = { program in create(.terminal, program: program) }
        actions.browseFiles = { withWorkspace { model.showFiles() } }
        actions.newBrowserTab = {
            withWorkspace {
                guard let project = model.selectedProjectID else { return }
                closeResumeWork()
                model.open(.browser(projectID: project))
            }
        }
        actions.startNewChat = { startNewChat() }
        actions.newPlainChat = { startNewChat(provider: $0) }
        actions.chooseNewTerminal = {
            withSessionWorkspace {
                let programs = TerminalProgram.offered(by: model.capabilities)
                if programs.count > 1 { resignKeyboard(); afterSheet { choosingProgram = true } }
                else { create(.terminal, program: programs.first ?? .shell) }
            }
        }
        actions.showDetail = {}
        actions.debugListVoiceOverElements = { listVoiceOverElements() }
        actions.debugRebuildSurfaces = { surfaceGeneration &+= 1 }
        #if os(iOS)
        actions.showPhoneWorkspaceHome = { showPhoneWorkspaceHome($0) }
        #endif
        return actions
    }

    private func present(_ value: WorkspaceSheet) {
        resignKeyboard()
        // Another sheet goes first: setting a new item while one is up left Resume Work in place and showed nothing
        // (Terminal Logs from the Resume Work sheet, B-18).
        if let current = sheet, current != value {
            sheet = nil
            searchPresented = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { present(value) }
            return
        }
        guard searchPresented else {
            sheet = value
            return
        }
        // A sheet shown while Resume Work search is active is shown by the search and does not close
        // when set to nil (iPad): the search ends first, and the sheet follows once it has gone.
        searchPresented = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            sheet = value
        }
    }

    /// Settings is reachable from Home. Native Settings commands first select the permanent Home and then
    /// open this same drawer, so every platform has one Settings presentation and one dismissal path.
    private func showSettings(routeHome: Bool = false) {
        resignKeyboard()
        sheet = nil
        if routeHome { model.selectedTabID = nil }
        if WorkspacePlatform.isPhone {
            #if os(iOS)
            switchPhoneTab(.settings)
            #endif
            return
        }
        guard routeHome || model.currentTab?.kind == .home || model.currentTab == nil else { return }
        searchPresented = false
        settingsPresented = true
    }

    private func closeSettings() {
        if WorkspacePlatform.isPhone {
            #if os(iOS)
            switchPhoneTab(.chat)
            #endif
        }
        settingsPresented = false
    }

    private func showArchivedChat(_ id: String) {
        guard model.archive != nil else { return }
        model.requestResume(.archivedChat(id, projectID: model.sidebar.chat(id)?.projectID ?? model.sidebar.session(id)?.projectID))
    }

    private func dismissAll() {
        model.phoneNavigation.dismissPopovers()
        sheet = nil
        settingsPresented = false
        choosingProgram = false
        choosingChatProvider = false
        askingForWorkspace = false
        model.sidebar.pendingDelete = nil
        model.workspaces.dismissQuestions()
        afterWorkspaceChoice = nil
        afterWorkspaceDismissal = nil
        model.pendingSessionResume = nil
        model.resumedArchive = nil
        searchPresented = false
        model.creationIssue = nil
        model.cancelClose()
    }

    /// Resume Work and ⇧⌘F open the searchable history/archive sheet.
    private func focusSearch() {
        resignKeyboard()
        settingsPresented = false
        search.query = ""
        searchPresented = true
        sheet = .resume
    }

    /// Puts the keyboard away. On iPhone every window ends editing too: a responder the responder chain's action
    /// missed kept its keyboard, which UIKit then gave back when a popover closed (B-8).
    private func resignKeyboard() {
        WorkspacePlatform.endEditing()
        #if os(iOS)
        endEditingInEveryWindow()
        #endif
    }

    /// Something made from the Resume Work sheet (a chat, a terminal, a browser tab) shows in front: the sheet goes.
    private func closeResumeWork() {
        if sheet == .resume { sheet = nil }
    }

    /// Runs `action`, which presents a question from the shell, once a sheet in front has gone.
    private func afterSheet(_ action: @escaping @MainActor () -> Void) {
        guard sheet != nil else { action(); return }
        sheet = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { action() }
    }

    /// Whether a Resume made since the request count `asked` brought a workspace question or another sheet. Those
    /// close the sheet in front themselves and wait until it has gone (`afterSheet`, `present`); closed by the caller
    /// first, it was still on its way out when they came, and the question could be dropped with the shell covered.
    private func resumeFollowsUp(since asked: Int) -> Bool {
        model.sessionResumeRequest != asked || model.resumedArchive != nil
    }

    /// Work starts in a workspace the person chose; none is assumed. Without one, the picker opens
    /// first and the requested action continues after it.
    private func withWorkspace(_ action: @escaping @MainActor () -> Void) {
        guard model.currentProject == nil else { action(); return }
        // The Workspaces screen can add one when there is none yet.
        guard !model.projects.isEmpty || model.workspaces.isAvailable else { return }
        present(.picker)
        afterWorkspaceChoice = action
    }

    /// Session launch asks before presenting the workspace picker; Cancel starts nothing.
    private func withSessionWorkspace(_ action: @escaping @MainActor () -> Void) {
        guard model.currentProject == nil else { action(); return }
        resignKeyboard()
        afterSheet {
            afterWorkspaceChoice = action
            askingForWorkspace = true
        }
    }

    private func chooseWorkspace(_ id: String) {
        let pending = afterWorkspaceChoice
        afterWorkspaceChoice = nil
        sheet = nil
        if let pending {
            model.selectProject(id)
            afterWorkspaceDismissal = pending
        } else {
            if WorkspacePlatform.isPhone {
                model.phoneNavigation.switchWorkspace(id, model: model)
                #if os(iOS)
                // The tab in front stays: Workspace keeps its list, and the workspace's tasks are in the title menus of
                // Chat and Terminal (native-full side build).
                if phoneTab == .workspace || phoneTab == .settings { model.selectedTabID = nil }
                #endif
            } else {
                model.openWorkspace(id)
            }
        }
    }

    private func workspaceSheetDismissed() {
        let pending = afterWorkspaceDismissal
        let closedPicker = dismissedSheet == .picker
        dismissedSheet = nil
        afterWorkspaceDismissal = nil
        if closedPicker, !askingForWorkspace { afterWorkspaceChoice = nil }
        finishWorkspaceChoice(model: model, covered: covered,
                              pickerCancelled: closedPicker && !askingForWorkspace && pending == nil,
                              action: pending)
    }

    private func create(_ kind: WorkspaceTabKind, program: TerminalProgram = .shell, provider: AgentProvider = .opencode) {
        guard !model.creating else { return }
        if kind == .terminal, model.currentProject == nil {
            withSessionWorkspace { create(kind, program: program, provider: provider) }
            return
        }
        resignKeyboard()
        closeResumeWork()
        model.create(kind, program: program, provider: provider)
    }

    /// Chat stays general-purpose; a selected workspace is required to start a session.
    private func startNewChat(provider: AgentProvider? = nil) {
        guard model.offersPlainChats, !model.creating, !model.locked else { return }
        withSessionWorkspace {
            resignKeyboard()
            closeResumeWork()
            if provider != nil || model.plainChatProviders.count == 1 { model.newPlainChat(provider: provider) }
            else { afterSheet { choosingChatProvider = true } }
        }
    }

    // MARK: Sheets

    @ViewBuilder private func sheetContent(_ value: WorkspaceSheet) -> some View {
        switch value {
        case .navigator:
            WorkspaceNavigationPicker(close: { sheet = nil })
        case .picker:
            // Hosts that list their workspaces' details get the Workspaces screen; others the plain picker.
            if model.workspaces.isAvailable {
                NavigationStack {
                    WorkspacesView(open: chooseWorkspace, done: { afterWorkspaceChoice = nil; sheet = nil })
                }
            } else {
                WorkspacePickerView(onClose: { afterWorkspaceChoice = nil; sheet = nil }, choose: chooseWorkspace)
            }
        case .resume:
            NavigationStack {
                WorkspaceSidebar(selection: sidebarSelection, search: search, searchPresented: $searchPresented,
                                 connection: connection, retryConnection: retryConnection,
                                 resumeOnly: true, showArchivedChat: { showArchivedChat($0) })
                    .navigationTitle("Resume Work")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { sheet = nil }.accessibilityIdentifier("resumeWorkClose")
                        }
                    }
            }
        case let .archive(terminals):
            if let archive = model.archive, terminals || model.sidebar.usesArchive {
                WorkspaceArchiveSheet(archive: archive, environment: model.archiveEnvironment(sync: archive.status), terminals: terminals,
                                      openChat: { chat in openArchivedChat(chat) }, continued: continued, onDone: { sheet = nil },
                                      chatsOnly: WorkspacePlatform.isPhone && !terminals)
            } else {
                #if os(iOS)
                if !terminals {
                    PhoneChatHistory(openChat: { id in
                        // A workspace question that follows closes this sheet itself (`resumeFollowsUp`).
                        let asked = model.sessionResumeRequest
                        choose(.chat(id))
                        if !resumeFollowsUp(since: asked) { sheet = nil }
                    }, done: { sheet = nil })
                }
                #endif
            }
        case let .archivedChat(id):
            if let archive = model.archive {
                WorkspaceArchivedChatSheet(chatID: id, archive: archive, environment: model.archiveEnvironment(sync: archive.status),
                                           continued: continued, onDone: { sheet = nil })
            }
        case let .terminalLog(log):
            NavigationStack {
                if let cache = model.archive?.terminalLogs {
                    TerminalLogViewer(log: log, cache: cache, fetcher: model.reachable ? model.client : nil, reachable: model.reachable)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) { Button("Done") { sheet = nil } }
                            if !log.isRunning {
                                ToolbarItem(placement: .primaryAction) {
                                    Button("Start Again") {
                                        let host = model.hostID
                                        afterSheet {
                                            guard model.hostID == host, !model.locked,
                                                  model.projects.contains(where: { $0.id == log.projectID }) else { return }
                                            model.selectProject(log.projectID)
                                            model.create(.terminal, program: TerminalProgram(id: log.program), projectID: log.projectID)
                                        }
                                    }
                                    .disabled(!model.reachable || !TerminalProgram.offered(by: model.capabilities).contains { $0.id == log.program })
                                    .accessibilityHint("Starts a new terminal running the same program. Previous commands are not replayed.")
                                    .accessibilityIdentifier("terminalLogStartAgain")
                                }
                            }
                        }
                } else {
                    ContentUnavailable("Output Unavailable", systemImage: "terminal", description: "Saved terminal output is not available on this device.")
                }
            }
        case .createWorkspace:
            NewWorkspaceSheet(created: chooseWorkspace)
                .environment(model)
        case .homeWorkspacePicker:
            #if os(iOS)
            HomeWorkspacePicker(choose: chooseWorkspace, close: { sheet = nil })
            #else
            WorkspacePickerView(onClose: { sheet = nil }, choose: chooseWorkspace)
            #endif
        }
    }

    /// A chat the host still has opens in its tab; otherwise the archive shows its copy. A plain chat opens
    /// without changing the workspace; a workspace chat in its workspace.
    private func openArchivedChat(_ chat: ArchivedChat) -> Bool {
        guard model.isChatShown(chat.id, projectID: chat.projectID, provider: chat.provider) else { return false }
        if model.sidebar.isLive(chat.id, projectID: chat.projectID) {
            let asked = model.sessionResumeRequest
            model.requestResume(.tab(WorkspaceTab(kind: .chat, projectID: chat.projectID, resourceID: chat.id, title: chat.displayTitle)),
                                replacingHome: model.launchingHomeTabID)
            if !resumeFollowsUp(since: asked) { sheet = nil }
        } else {
            model.requestResume(.archivedChat(chat.id, projectID: chat.projectID))
        }
        return true
    }

    /// Continue with…: the host's new chat opens; on hosts without Continue a new chat opens with the
    /// draft in its composer, never sent by itself.
    private func continued(_ result: ContinueResult) {
        switch result {
        case let .chat(session):
            let asked = model.sessionResumeRequest
            // A plain chat continued from the archive belongs to the workspace in use; a workspace chat to its own.
            if model.isChatsSpace(session.projectID), let owner = model.selectedProjectID {
                model.rememberChatWorkspace(session.id, workspaceID: owner)
            }
            model.openChat(session)
            if !resumeFollowsUp(since: asked) { sheet = nil }
        case let .draft(draft):
            sheet = nil
            if model.selectedProjectID != draft.projectID { model.selectProject(draft.projectID) }
            model.openDraft(draft)
        }
    }

    // MARK: Text size

    private var textSize: DynamicTypeSize {
        let sizes = DynamicTypeSize.allCases
        guard let base = sizes.firstIndex(of: baseTypeSize) else { return baseTypeSize }
        return sizes[min(max(base + textSizeStep, 0), sizes.count - 1)]
    }

    private func stepTextSize(_ delta: Int) {
        let sizes = DynamicTypeSize.allCases
        guard let base = sizes.firstIndex(of: baseTypeSize) else { return }
        textSizeStep = min(max(textSizeStep + delta, -base), sizes.count - 1 - base)
    }

    // MARK: Commands

    /// The keyboard and menu bar commands for the surface in front.
    private var commandActions: WorkspaceCommandActions {
        var shell = WorkspaceCommandShell()
        shell.withWorkspace = { action in withWorkspace(action) }
        shell.create = { kind, program, provider in create(kind, program: program, provider: provider) }
        shell.newPlainChat = { startNewChat() }
        shell.focusSearch = { focusSearch() }
        shell.showSettings = { showSettings(routeHome: true) }
        shell.stepTextSize = { delta in stepTextSize(delta) }
        shell.resetTextSize = { textSizeStep = 0 }
        shell.textSizeStep = textSizeStep
        shell.obscured = obscured
        return WorkspaceCommandActions.make(model: model, shell: shell)
    }
}

/// The detail column's bar holds the centered workspace switcher and the current surface's trailing
/// actions. The Mac's window toolbar can still be customized with New Chat, New Terminal, Search and
/// Reload, none of them shown by default; the menu bar has every command.
private struct WorkspaceToolbar: ViewModifier {
    @Environment(WorkspaceModel.self) private var model
    @Environment(\.workspaceShell) private var shell
    @Environment(\.workspaceObscured) private var obscured

    private var toolbarUnavailable: Bool { obscured || model.locked || model.presentationPending }

    func body(content: Content) -> some View {
        #if os(macOS)
        content.toolbar(id: "workspace") {
            ToolbarItem(id: "newChat", placement: .primaryAction, showsByDefault: false) {
                PlainChatLaunchMenu { Label("New Chat", systemImage: "square.and.pencil") }
                    .disabled(toolbarUnavailable || (model.projects.isEmpty && !model.offersPlainChats) || model.creating)
                    .accessibilityHidden(toolbarUnavailable)
                    .help("New Chat")
            }
            ToolbarItem(id: "newTerminal", placement: .primaryAction, showsByDefault: false) {
                Button(action: shell.chooseNewTerminal) { Label("New Terminal", systemImage: "terminal") }
                    .disabled(toolbarUnavailable || model.projects.isEmpty || model.creating || model.capabilities?.terminal != true)
                    .accessibilityHidden(toolbarUnavailable)
                    .help("New Terminal")
            }
            ToolbarItem(id: "search", placement: .primaryAction, showsByDefault: false) {
                Button(action: shell.focusSearch) { Label("Search", systemImage: "magnifyingglass") }
                    .disabled(toolbarUnavailable)
                    .accessibilityHidden(toolbarUnavailable)
                    .help("Search the workspace")
            }
            ToolbarItem(id: "reload", placement: .primaryAction, showsByDefault: false) {
                Button(action: reload) { Label("Reload", systemImage: "arrow.clockwise") }
                    .disabled(toolbarUnavailable)
                    .accessibilityHidden(toolbarUnavailable)
                    .help("Reload")
            }
        }
        #else
        content
        #endif
    }

    #if os(macOS)
    private func reload() {
        if let tab = model.currentTab {
            model.reloadTab(tab.id)
        } else {
            Task { await model.refreshProjects() }
        }
    }
    #endif
}

/// Escape on a hardware keyboard inside an iPhone popover closes it: the popover's own view controller is in front
/// of the shell's key commands (`WorkspaceTabKeys`), so the popover carries the cancel shortcut itself. Nothing to
/// see or reach: VoiceOver's escape is the popover's own.
private struct PhonePopoverEscape: View {
    let action: () -> Void

    var body: some View {
        Button("Close", action: action)
            .keyboardShortcut(.cancelAction)
            .frame(width: 0, height: 0)
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// An action held until an iPhone popover has gone.
private struct PendingPhoneAction {
    let id = UUID()
    let action: @MainActor () -> Void
}

/// Home's circus is decoded behind the opening cover (`AgentLandCircusLoading.prepareArtwork()`), not on the main
/// thread when the cover lifts.
private struct CircusArtworkPreparation: ViewModifier {
    func body(content: Content) -> some View {
        content.task { AgentLandCircusLoading.prepareArtwork() }
    }
}

/// A workspace without notices of the app's own.
extension WorkspaceView where Notices == EmptyView {
    public init(connection: ConnectionStatus, retryConnection: (() -> Void)?, covered: Bool,
                @ViewBuilder settings: @escaping (_ close: @escaping () -> Void) -> Settings) {
        self.init(connection: connection, retryConnection: retryConnection, covered: covered, settings: settings, notices: { EmptyView() })
    }
}

/// The Settings drawer's tone and its pages' (paper and slate, 2026-10-07): on iPad the raised paper or slate of the
/// iPhone's header panels, with no page of their own over it; on the Mac the canvas, as before.
private struct SettingsDrawerPage: ViewModifier {
    #if os(macOS)
    static let tone = AgentLandColor.canvas
    func body(content: Content) -> some View { content }
    #else
    static let tone = AgentLandColor.surfaceRaised
    func body(content: Content) -> some View { content.agentLandPanelPage() }
    #endif
}
