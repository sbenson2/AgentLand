import SwiftUI
import AgentLandCore
import AgentLandChat
import AgentLandArchive
import AgentLandDesign

/// What a sidebar row shows in the detail column when it is selected.
enum SidebarItem: Hashable {
    case home
    case files
    case git
    case tab(UUID)
    /// A chat of the library, by its ID on the host.
    case chat(String)
    /// A terminal running on the host, by its ID.
    case terminal(String)
}

/// The sidebar: the workspace switcher; Home; the chat library (plain chats first, whatever workspace is
/// open, then the workspace's agent chats; each Pinned, Today, Yesterday, This Week, then by month, with
/// running chats and chats waiting for the person marked); Files, Git with its
/// change count, the host's terminals and the archive, and the open tabs. Its search covers
/// chats, files, tabs, terminals and workspaces. Entries appear only for what the host offers.
struct WorkspaceSidebar: View {
    @Environment(WorkspaceModel.self) private var model
    @Environment(\.workspaceShell) private var shell
    @WorkspaceHorizontalSizeClass private var sizeClass
    @Binding var selection: SidebarItem?
    @Bindable var search: WorkspaceSearchModel
    @Binding var searchPresented: Bool
    let connection: ConnectionStatus
    let retryConnection: (() -> Void)?
    /// The app's row at the top (the Mac's status of its own host), if it has one.
    var header: AnyView? = nil
    /// The iPhone's drawer shows the sidebar on Liquid Glass, so the list draws no background of its own.
    var onGlass = false
    /// Resume Work reuses the searchable chat, terminal and open-tab lists without workspace management,
    /// creation destinations, or Settings.
    var resumeOnly = false
    /// Opens a chat the host no longer has live, read-only.
    let showArchivedChat: (String) -> Void
    @AppStorage("agentland.sidebar.chatsExpanded") private var chatsExpanded = true
    @AppStorage("agentland.sidebar.terminalsExpanded") private var terminalsExpanded = true
    @AppStorage("agentland.sidebar.tabsExpanded") private var tabsExpanded = true

    private var sidebar: WorkspaceSidebarModel { model.sidebar }

    @State private var voiceOverElements = ""

    var body: some View {
        List(selection: $selection) {
            if let header, !resumeOnly {
                Section { header.selectionDisabled() }
            }
            if search.isActive {
                searchResults
            } else if resumeOnly {
                chats
                terminals
                openTabs
            } else {
                workspaceSwitcher
                destinations
                chats
                terminals
                openTabs
            }
        }
        .listStyle(.sidebar)
        #if os(macOS)
        // A macOS sidebar draws a Button as a tinted, bordered control; the action rows (Archive,
        // New Chat, New Terminal, Terminal Logs, Settings) are rows like Home and Files.
        .buttonStyle(SidebarRowButtonStyle())
        .scrollContentBackground(.hidden)
        .background(onGlass ? AnyShapeStyle(Color.clear) : AnyShapeStyle(AgentLandColor.canvas))
        #else
        // Paper or slate behind the list on iPhone and iPad (the sheet's raised tone in Resume Work), unless glass is
        // behind the list (2026-10-07).
        .modifier(SidebarPage(onGlass: onGlass))
        #endif
        .navigationTitle(resumeOnly ? "Resume Work" : "AgentLand")
        .task { if resumeOnly { await sidebar.refreshResumeTerminals() } }
        .workspaceInlineNavigationTitle()
        // No focus binding on the field (`searchFocused`): while the collapsed iPhone split view shows the
        // detail, it made SwiftUI rebuild the sidebar every few milliseconds, which held up the opening.
        .searchable(text: $search.query, isPresented: $searchPresented, placement: searchPlacement, prompt: "Chats, Files and Tabs")
        .workspaceNoAutocapitalization()
        .autocorrectionDisabled()
        .refreshable { await refreshNow() }
        .task(id: searchKey) {
            // Wait for typing to pause before walking folders or asking the host.
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            await search.search()
        }
        #if os(iOS)
        // A pin or delete that did not happen, or may have (it says so): the system's alert, which OK puts away (RW-3).
        .alert(sidebar.notice ?? "", isPresented: Binding(get: { sidebar.notice != nil }, set: { if !$0 { sidebar.notice = nil } })) {
            Button("OK", role: .cancel) {}
        }
        #endif
        .overlay(alignment: .top) {
            // On iPhone the sidebar covers the detail's banner, so the banner shows over it too.
            if sizeClass == .compact || onGlass, !model.presentationPending {
                ConnectionStatusBanner(status: connection, retry: retryConnection, identifier: "connectionBanner",
                                       retryIdentifier: "connectionRetry")
                    .frame(maxWidth: 520)
                    .padding(.horizontal, AgentLandSpacing.small)
                    .padding(.top, AgentLandSpacing.xSmall)
            }
        }
        .agentLandHaptic(.warning, trigger: sidebar.notice) { _, notice in notice != nil }
        .overlay(alignment: .topLeading) { voiceOverList }
        .task(id: model.presentationPending) { await listVoiceOverElements() }
    }

    /// The search field's place: in the drawer (iPhone, and iPad in compact width) at the top, under the
    /// navigation bar and always shown, so the list never scrolls under it (the owner's request); in the
    /// iPad and Mac sidebar the system's place.
    private var searchPlacement: SearchFieldPlacement {
        #if os(iOS)
        // On iPhone (the drawer's page and the Resume Work sheet) the field stays at the top, above the keyboard; the
        // sidebar placement put it in the bottom bar, under the keyboard (B-11).
        onGlass || WorkspacePlatform.isPhone ? .navigationBarDrawer(displayMode: .always) : .sidebar
        #else
        .sidebar
        #endif
    }

    /// On iPhone the sidebar is a screen of its own, without the tab menu that lists what VoiceOver
    /// reaches; UI tests read the list here, made once the sidebar has settled on screen.
    @ViewBuilder private var voiceOverList: some View {
        if workspaceUITestHooks {
            Color.clear.frame(width: 1, height: 1)
                .accessibilityElement()
                .accessibilityLabel("VoiceOver elements in the sidebar")
                .accessibilityValue(voiceOverElements)
                .accessibilityIdentifier("debugSidebarVoiceOverElements")
        }
    }

    /// Walks what VoiceOver reaches 1.5 s after the sidebar shows, not while the opening covers it (the
    /// walk runs on the main actor).
    private func listVoiceOverElements() async {
        guard workspaceUITestHooks else { return }
        voiceOverElements = ""
        guard !model.presentationPending else { return }
        try? await Task.sleep(for: .seconds(1.5))
        guard !Task.isCancelled else { return }
        voiceOverElements = reachableAccessibilityElements().joined(separator: "\n")
    }

    private var searchKey: String {
        "\(search.query)|\(model.selectedProjectID ?? "")|\(model.client.map { String(describing: ObjectIdentifier($0)) } ?? "none")"
    }

    private func refreshNow() async {
        model.archive?.syncNow()
        search.invalidateNames()
        await sidebar.refresh()
    }

    // MARK: Sections

    /// The workspace switcher: the workspace in use; it opens the list of the host's workspaces.
    /// (A menu in a row of the selectable sidebar list does not open, so each choice is a button or a
    /// dialog.)
    private var workspaceSwitcher: some View {
        Section {
            Button(action: shell.openPicker) {
                HStack(spacing: AgentLandSpacing.xSmall) {
                    Image(systemName: "folder").foregroundStyle(AgentLandColor.tint).accessibilityHidden(true)
                    Text(model.currentProject?.name ?? "Choose Workspace")
                        .font(.headline)
                        .foregroundStyle(AgentLandColor.text)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AgentLandColor.glyphTertiary)
                        .accessibilityHidden(true)
                }
                .frame(minHeight: AgentLandTapTarget.platformMinimum)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // The Workspaces screen can add one when the host has none to list yet.
            .disabled(model.projects.isEmpty && !model.workspaces.isAvailable)
            .accessibilityLabel("Workspace")
            .accessibilityValue(model.currentProject?.name ?? "None open")
            .accessibilityHint("Shows the workspaces")
            .accessibilityIdentifier("sidebarWorkspace")
        }
    }

    @ViewBuilder private var destinations: some View {
        Section {
            SidebarLabel("Home", systemImage: "house")
                .tag(SidebarItem.home)
                .accessibilityIdentifier("sidebarHome")
            if model.currentProject != nil {
                SidebarLabel("Files", systemImage: "folder")
                    .tag(SidebarItem.files)
                    .accessibilityIdentifier("sidebarFiles")
                SidebarLabel("Git", systemImage: "arrow.triangle.branch")
                    .badge(sidebar.gitChanges ?? 0)
                    .accessibilityValue(sidebar.gitChanges.map { $0 == 1 ? "1 change" : "\($0) changes" } ?? "")
                    .tag(SidebarItem.git)
                    .accessibilityIdentifier("sidebarGit")
            }
            if sidebar.usesArchive {
                Button { shell.showArchive(false) } label: { Label("Archive", systemImage: "archivebox") }
                    .accessibilityIdentifier("sidebarArchive")
            }
        }
    }

    // MARK: Chats

    @ViewBuilder private var chats: some View {
        if sidebar.showsPlainChats { plainChats }
    }

    private var plainChats: some View {
        Section(isExpanded: $chatsExpanded) {
            if model.offersPlainChats {
                PlainChatLaunchMenu {
                    Label("New Chat", systemImage: "square.and.pencil")
                }
                .disabled(model.creating)
                .accessibilityIdentifier("sidebarNewChat")
            }
            if sidebar.usesArchive {
                ForEach(sidebar.chatLibraryGroups) { group in
                    groupHeading(group.title)
                    ForEach(group.chats) { chat in archivedRow(chat) }
                }
                if sidebar.hasMoreLibraryChats {
                    Button { shell.showArchive(false) } label: { Label("All Chats", systemImage: "ellipsis.circle") }
                        .accessibilityIdentifier("sidebarAllPlainChats")
                }
                if sidebar.archiveLoaded && sidebar.libraryChats.isEmpty && model.archive?.status?.lastSyncedAt == nil {
                    libraryLine("Your chats appear here once this device has copied them.")
                }
            } else if let sessions = sidebar.liveLibrarySessions {
                liveRows(sessions)
            }
            if let issue = sidebar.libraryIssue ?? sidebar.plainLibraryIssue, !sidebar.usesArchive { libraryLine(issue) }
            libraryNotice
        } header: {
            Text("Chats")
        }
    }

    private func groupHeading(_ title: String) -> some View {
        Text(title)
            .agentLandFont(.metadata)
            .fontWeight(.semibold)
            .foregroundStyle(AgentLandColor.textSecondary)
            .accessibilityAddTraits(.isHeader)
            .selectionDisabled()
    }

    /// The host's own list, for hosts that keep no archive this device copies.
    @ViewBuilder private func liveRows(_ sessions: [Session]) -> some View {
        if !sessions.isEmpty { groupHeading("Recent") }
        ForEach(sessions.prefix(WorkspaceSidebarModel.recentLimit)) { session in
            ChatLibraryRow(title: model.chatName(id: session.id, listed: session.title), provider: rowProvider(session.provider, projectID: session.projectID),
                           time: nil, pinned: false, state: chatState(session.id))
                .tag(SidebarItem.chat(session.id))
        }
    }

    private func libraryLine(_ text: String) -> some View {
        Text(text).agentLandFont(.metadata).foregroundStyle(AgentLandColor.textSecondary).selectionDisabled()
    }

    /// Why the last pin or delete did not happen, in the library's first section on the Mac. iPhone and iPad show it in
    /// the system's alert instead (RW-3).
    @ViewBuilder private var libraryNotice: some View {
        #if os(macOS)
        if let notice = sidebar.notice {
            InlineNotice(notice, tone: .warning, onDismiss: { sidebar.notice = nil },
                         identifiers: .init(text: "sidebarNotice", dismiss: "dismissSidebarNotice"))
                .selectionDisabled()
        }
        #endif
    }

    /// The agent a row names: none for a plain chat, whose agent is the host's own business.
    private func rowProvider(_ id: String, projectID: String) -> AgentProvider? {
        model.isChatsSpace(projectID) ? nil : AgentProvider.named(id, by: model.capabilities)
    }

    private func archivedRow(_ chat: ArchivedChat) -> some View {
        ChatLibraryRow(title: model.chatName(id: chat.id, listed: sidebar.title(for: chat)), provider: rowProvider(chat.provider, projectID: chat.projectID),
                       time: ChatLibrary.rowTime(chat.updatedAt), pinned: chat.pinned, state: chatState(chat.id))
            .tag(SidebarItem.chat(chat.id))
            .swipeActions(edge: .leading) {
                Button { Task { await sidebar.setPinned(!chat.pinned, chatID: chat.id) } } label: {
                    Label(chat.pinned ? "Unpin" : "Pin", systemImage: chat.pinned ? "pin.slash" : "pin")
                }
                .tint(Self.pinSwipeTint)
            }
            .swipeActions(edge: .trailing) {
                if sidebar.canDelete {
                    // Not the destructive role, which would take the row away under its question; the row stays
                    // until the host has deleted the chat.
                    Button { sidebar.requestDelete(chat, fromRow: true) } label: { Label("Delete", systemImage: "trash") }
                        .tint(.red)
                }
            }
            .contextMenu {
                Button("Open", systemImage: "bubble.left.and.bubble.right") { selection = .chat(chat.id) }
                // Once the menu has gone (`MenuAction`): pinning turns this item into Unpin and moves the row.
                Button(chat.pinned ? "Unpin" : "Pin", systemImage: chat.pinned ? "pin.slash" : "pin") {
                    MenuAction.afterDismissal { await sidebar.setPinned(!chat.pinned, chatID: chat.id) }
                }
                Button("Show Archived Copy", systemImage: "archivebox") { showArchivedChat(chat.id) }
                Divider()
                Button("Delete…", systemImage: "trash", role: .destructive) { sidebar.requestDelete(chat, fromRow: true) }
                    .disabled(!sidebar.canDelete)
            }
            .accessibilityIdentifier("sidebarChat")
            // Its Delete's question points at this row (owner, 2026-10-08).
            .modifier(ChatDeleteConfirmation(chat: chat))
    }

    /// The pin swipe's colour: yellow on iPhone and iPad, as Messages pins (RW-5); the accent on the Mac.
    private static var pinSwipeTint: Color {
        #if os(iOS)
        .yellow
        #else
        AgentLandColor.tint.color
        #endif
    }

    /// Running, waiting for the person, or neither, from the chat's open tab.
    private func chatState(_ sessionID: String) -> ChatLibraryRow.Activity {
        guard let tab = model.chatTab(sessionID: sessionID), let store = model.existingChatStore(tab.id) else { return .idle }
        if !store.interactions.isEmpty { return .needsYou }
        return store.isWorking ? .running : .idle
    }

    // MARK: Terminals

    @ViewBuilder private var terminals: some View {
        if model.capabilities?.terminal == true, model.currentProject != nil || resumeOnly {
            Section(isExpanded: $terminalsExpanded) {
                Button(action: shell.chooseNewTerminal) {
                    Label("New Terminal", systemImage: "plus.rectangle.on.rectangle")
                }
                .disabled(model.creating)
                .accessibilityIdentifier("sidebarNewTerminal")
                ForEach(resumeOnly ? sidebar.resumeTerminals : (sidebar.terminals ?? [])) { terminal in
                    Label {
                        HStack {
                            Text(model.terminalName(terminal)).lineLimit(1)
                            Spacer(minLength: AgentLandSpacing.xSmall)
                            if terminal.status != .running {
                                Text(terminal.status == .exited ? "Ended" : "Disconnected")
                                    .agentLandFont(.metadata)
                                    .foregroundStyle(AgentLandColor.textSecondary)
                            }
                        }
                    } icon: {
                        Image(systemName: "terminal").accessibilityHidden(true)
                    }
                    .accessibilityElement(children: .combine)
                    .tag(SidebarItem.terminal(terminal.id))
                    .accessibilityIdentifier("sidebarTerminal")
                }
                if let issue = sidebar.terminalsIssue {
                    Text(issue).agentLandFont(.metadata).foregroundStyle(AgentLandColor.textSecondary).selectionDisabled()
                }
                if sidebar.usesArchive, model.capabilities?.supportsArchive(.terminalLogs) == true {
                    Button { shell.showArchive(true) } label: { Label("Terminal Logs", systemImage: "clock.arrow.circlepath") }
                        .accessibilityIdentifier("sidebarTerminalLogs")
                }
            } header: {
                Text("Terminals")
            }
        }
    }

    // MARK: Open tabs

    /// Web pages open in tabs, on hosts that serve previews of their ports.
    private var offersBrowser: Bool { model.capabilities?.preview != nil && model.currentProject != nil }

    @ViewBuilder private var openTabs: some View {
        if !model.workspaceTabs.isEmpty || offersBrowser {
            Section(isExpanded: $tabsExpanded) {
                if offersBrowser {
                    Button(action: shell.newBrowserTab) { Label("New Browser Tab", systemImage: "globe") }
                        .disabled(model.creating)
                        .accessibilityIdentifier("sidebarNewBrowserTab")
                }
                ForEach(model.workspaceTabs) { tab in
                    SidebarLabel(tab.title, systemImage: tabIcon(tab.kind))
                        .lineLimit(1)
                        .tag(SidebarItem.tab(tab.id))
                        .accessibilityAddTraits(tab.id == model.selectedTabID ? .isSelected : [])
                        .accessibilityIdentifier("openTab")
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { model.close(tab.id) } label: { Label("Close", systemImage: "xmark") }
                        }
                        .contextMenu {
                            Button("Close Tab", systemImage: "xmark") { model.close(tab.id) }
                            if model.workspaceTabs.count > 1 {
                                Button("Close Other Tabs", systemImage: "xmark.square") { model.closeOtherTabs(keeping: tab.id) }
                            }
                        }
                }
                .onMove { source, destination in model.moveWorkspaceTabs(fromOffsets: source, toOffset: destination) }
            } header: {
                Text("Open Tabs")
            }
        }
    }

    // MARK: Search

    @ViewBuilder private var searchResults: some View {
        let titleMatches = matchingChats
        let tabs = model.workspaceTabs.filter { search.matches($0.title) }
        let terminals = (sidebar.terminals ?? []).filter { search.matches(model.terminalName($0)) }
        let workspaces = model.projects.filter { search.matches($0.name) }
        if !titleMatches.isEmpty || !search.messageHits.isEmpty {
            Section("Chats") {
                ForEach(titleMatches) { match in
                    resultButton(match.title, systemImage: "bubble.left", detail: match.provider?.displayName) {
                        openChat(match.id, title: match.title, projectID: match.projectID)
                    }
                    .accessibilityIdentifier("searchChat")
                }
                ForEach(search.messageHits.filter { model.isChatShown($0.chatID, projectID: $0.projectID) }) { hit in
                    Button { openChat(hit.chatID, title: hit.displayTitle, projectID: hit.projectID) } label: {
                        VStack(alignment: .leading, spacing: AgentLandSpacing.xxxSmall) {
                            Text(hit.displayTitle).agentLandFont(.bodyEmphasized).foregroundStyle(AgentLandColor.text).lineLimit(1)
                            Text(ArchiveSnippet.attributedString(hit.snippet, matchColor: AgentLandColor.text.color))
                                .agentLandFont(.secondary)
                                .foregroundStyle(AgentLandColor.textSecondary)
                                .lineLimit(2)
                        }
                        .modifier(SearchResultRowFrame())
                    }
                    .modifier(SearchResultButtonStyle())
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("searchMessage")
                }
            }
        }
        if !search.fileNames.isEmpty || !search.fileContents.isEmpty || search.searchingFiles {
            Section {
                ForEach(search.fileNames) { entry in
                    resultButton(entry.name, systemImage: entry.isDirectory ? "folder" : "doc.text",
                                 detail: entry.path == entry.name ? nil : entry.path) {
                        openFile(path: entry.path, name: entry.name, isDirectory: entry.isDirectory)
                    }
                        .accessibilityIdentifier("searchFile-\(entry.path)")
                }
                ForEach(search.fileContents) { result in
                    let first = result.matches.first
                    resultButton(result.path, systemImage: "text.magnifyingglass",
                                 detail: first.map { "Line \($0.line): \($0.preview.trimmingCharacters(in: .whitespaces))" }) {
                        openFile(path: result.path, name: (result.path as NSString).lastPathComponent, isDirectory: false)
                    }
                    .accessibilityIdentifier("searchFileContent-\(result.path)")
                }
                if search.searchingFiles { ProgressView().frame(maxWidth: .infinity).selectionDisabled() }
                if let issue = search.filesIssue {
                    Text(issue).agentLandFont(.metadata).foregroundStyle(AgentLandColor.textSecondary).selectionDisabled()
                }
            } header: {
                Text("Files")
            } footer: {
                if search.namesIncomplete {
                    Text("File names come from the first \(WorkspaceSearchModel.maximumFolders) folders.")
                }
            }
        }
        if !tabs.isEmpty {
            Section("Open Tabs") {
                ForEach(tabs) { tab in
                    resultButton(tab.title, systemImage: tabIcon(tab.kind), detail: nil) { choose(.tab(tab.id)) }
                        .accessibilityIdentifier("searchTab")
                }
            }
        }
        if !terminals.isEmpty {
            Section("Terminals") {
                ForEach(terminals) { terminal in
                    resultButton(model.terminalName(terminal), systemImage: "terminal", detail: terminal.status.rawValue) { choose(.terminal(terminal.id)) }
                        .accessibilityIdentifier("searchTerminal")
                }
            }
        }
        if !workspaces.isEmpty {
            Section("Workspaces") {
                ForEach(workspaces) { project in
                    resultButton(project.name, systemImage: "folder", detail: nil) {
                        model.openWorkspace(project.id)
                        shell.showDetail()
                    }
                    .accessibilityIdentifier("searchWorkspace-\(project.id)")
                }
            }
        }
        if titleMatches.isEmpty && search.messageHits.isEmpty && search.fileNames.isEmpty && search.fileContents.isEmpty
            && tabs.isEmpty && terminals.isEmpty && workspaces.isEmpty {
            if search.resultsCurrent {
                ContentUnavailable.search(text: search.text)
                    .selectionDisabled()
            } else {
                ProgressView().frame(maxWidth: .infinity).selectionDisabled()
            }
        }
    }

    private struct ChatMatch: Identifiable {
        let id: String
        let projectID: String
        let title: String
        /// Nil for a plain chat.
        let provider: AgentProvider?
    }

    /// Chats whose title matches, plain chats first: from this device's copy, or the host's lists without one.
    private var matchingChats: [ChatMatch] {
        if sidebar.usesArchive {
            return sidebar.allChats.filter { search.matches(sidebar.title(for: $0)) }.prefix(20)
                .map { ChatMatch(id: $0.id, projectID: $0.projectID, title: sidebar.title(for: $0), provider: rowProvider($0.provider, projectID: $0.projectID)) }
        }
        return (sidebar.liveLibrarySessions ?? []).filter { search.matches($0.title) }.prefix(20)
            .map { ChatMatch(id: $0.id, projectID: $0.projectID, title: $0.title, provider: rowProvider($0.provider, projectID: $0.projectID)) }
    }

    private func resultButton(_ title: String, systemImage: String, detail: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label {
                VStack(alignment: .leading, spacing: AgentLandSpacing.xxxSmall) {
                    Text(title).foregroundStyle(AgentLandColor.text).lineLimit(1)
                    if let detail {
                        Text(detail).agentLandFont(.metadata).foregroundStyle(AgentLandColor.textSecondary).lineLimit(1)
                    }
                }
            } icon: {
                Image(systemName: systemImage)
            }
            .modifier(SearchResultRowFrame())
        }
        .modifier(SearchResultButtonStyle())
    }

    private func choose(_ item: SidebarItem) {
        hideKeyboard()
        selection = item
    }

    private func openChat(_ id: String, title: String, projectID: String) {
        hideKeyboard()
        guard sidebar.isLive(id, projectID: projectID) else { showArchivedChat(id); return }
        model.requestResume(.tab(WorkspaceTab(kind: .chat, projectID: projectID, resourceID: id, title: title)),
                            replacingHome: model.launchingHomeTabID)
        shell.showDetail()
    }

    private func openFile(path: String, name: String, isDirectory: Bool) {
        guard let project = model.selectedProjectID else { return }
        hideKeyboard()
        if isDirectory {
            model.showFiles()
            // On iPhone Files shows in the drawer and the task in front stays: the folder goes to the drawer's page.
            let files = model.currentTab?.kind == .files ? model.currentTab : model.phoneNavigation.backingTab(.files, model: model)
            if let files { model.filesSession(for: files).navigate(to: path) }
        } else {
            model.open(WorkspaceTab(kind: .editor, projectID: project, resourceID: path, title: name))
        }
        shell.showDetail()
    }

    /// The keyboard goes with a result opening; the search and its results stay.
    private func hideKeyboard() {
        WorkspacePlatform.endEditing()
    }
}

/// Keeps the sidebar's lists current whether or not its view exists (on iPhone it is built the first time
/// it shows). Nothing is read while the opening covers the workspace: the host's chats, terminals and Git
/// count once it has cleared, while unlocked, active and reachable, then every minute; the chat library
/// from this device's copy once it has cleared, then on every commit.
struct WorkspaceSidebarLoading: ViewModifier {
    @Environment(WorkspaceModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    private var sidebar: WorkspaceSidebarModel { model.sidebar }

    func body(content: Content) -> some View {
        content
            .task(id: loadKey) { await follow() }
            .task(id: archiveKey) {
                guard !model.presentationPending else { return }
                await sidebar.followArchive(projectID: model.selectedProjectID)
            }
    }

    /// Everything the lists are read again for: the host, the workspace, the connection, the scene, the
    /// lock and the opening, tabs opening or closing, and plain chats coming or going.
    private var loadKey: String {
        let client = model.client.map { String(describing: ObjectIdentifier($0)) } ?? "none"
        return "\(client)|\(model.selectedProjectID ?? "")|\(model.connectionEpoch)|\(model.reachable)|\(scenePhase == .active)|\(model.locked)|\(model.presentationPending)|\(model.tabs.count)|\(model.offersPlainChats)"
    }

    /// What the device's copy is read again for, the host's Chats space too: an older host's workspace list can make
    /// `chats` one of its workspaces once it arrives.
    private var archiveKey: String {
        "\(model.archive.map { String(describing: ObjectIdentifier($0)) } ?? "none")|\(model.selectedProjectID ?? "")|\(sidebar.usesArchive)|\(model.presentationPending)|\(model.chatsSpaceID ?? "")"
    }

    private func follow() async {
        guard model.reachable, !model.locked, !model.presentationPending, scenePhase == .active, model.client != nil else { return }
        while !Task.isCancelled {
            await sidebar.refresh()
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
        }
    }
}

/// A chat in the library: its agent's symbol, its title, when it was last active, and one accessory
/// at a time: waiting for the person, running, or pinned. A plain chat names no agent.
struct ChatLibraryRow: View {
    enum Activity { case idle, running, needsYou }
    let title: String
    let provider: AgentProvider?
    let time: String?
    let pinned: Bool
    let state: Activity

    var body: some View {
        Label {
            HStack(spacing: AgentLandSpacing.xSmall) {
                Text(title).lineLimit(1)
                Spacer(minLength: AgentLandSpacing.xxSmall)
                accessory
                if let time {
                    Text(time)
                        .agentLandFont(.metadata)
                        .foregroundStyle(AgentLandColor.textSecondary)
                        .lineLimit(1)
                }
            }
        } icon: {
            Image(systemName: provider == nil || provider == .opencode ? "bubble.left.and.bubble.right" : "bubble.left.and.text.bubble.right")
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(accessibilityValue)
    }

    @ViewBuilder private var accessory: some View {
        switch state {
        case .needsYou:
            Image(systemName: "hand.raised.fill").foregroundStyle(AgentLandColor.warning).accessibilityHidden(true)
        case .running:
            ProgressView().controlSize(.small).accessibilityHidden(true)
        case .idle:
            if pinned { Image(systemName: "pin.fill").foregroundStyle(AgentLandColor.glyphTertiary).accessibilityHidden(true) }
        }
    }

    private var accessibilityValue: String {
        var parts = provider.map { [$0.displayName] } ?? []
        switch state {
        case .needsYou: parts.append("Waiting for you")
        case .running: parts.append("Running")
        case .idle: if pinned { parts.append("Pinned") }
        }
        if let time { parts.append(time) }
        return parts.joined(separator: ", ")
    }
}
/// A sidebar row's symbol and title, read as one element: its title (the symbol is decoration).
struct SidebarLabel: View {
    let title: String
    let systemImage: String

    init(_ title: String, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: systemImage).accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
    }
}

#if os(macOS)
/// A sidebar action drawn as a plain, full-width row in the text color, dimmed while pressed.
private struct SidebarRowButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(AgentLandColor.text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .opacity(!isEnabled ? 0.45 : configuration.isPressed ? 0.6 : 1)
    }
}
#endif

/// A search result's button: on iPhone and iPad the list's own row button, which highlights the row while pressed
/// (RW-4); on the Mac a plain one, as before.
private struct SearchResultButtonStyle: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        content
        #else
        content.buttonStyle(.plain)
        #endif
    }
}

/// A search result's label: the row's own height and width on iPhone and iPad; on the Mac a full-width row at least
/// the platform's target tall, tappable in its whole frame.
private struct SearchResultRowFrame: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        content
        #else
        content
            .frame(maxWidth: .infinity, minHeight: AgentLandTapTarget.platformMinimum, alignment: .leading)
            .contentShape(Rectangle())
        #endif
    }
}

#if os(iOS)
/// The sidebar list's page on iPhone and iPad: clear over glass, else the page its surroundings give it.
private struct SidebarPage: ViewModifier {
    let onGlass: Bool

    func body(content: Content) -> some View {
        if onGlass { content.scrollContentBackground(.hidden) } else { content.listPageBackground() }
    }
}
#endif
