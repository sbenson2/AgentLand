import SwiftUI
import AgentLandChat
import AgentLandCore
import AgentLandDesign
#if canImport(UIKit)
import UIKit
#endif

/// Where the browser navigates.
enum ArchiveRoute: Hashable {
    case chat(String)
    case log(ArchivedTerminalLog)
}

/// The archive: Chats (Pinned, Today, Yesterday, This Week, then by month) and
/// Terminals, with search chips for agent, workspace and date. Search asks the
/// host when it can be reached and this device's copy otherwise, and says
/// which. Pin and Delete are in each row's swipe actions and context menu;
/// Delete asks first and leaves this device only once the host confirms.
public struct ArchiveBrowser: View {
    @State private var model: ArchiveBrowserModel
    private let terminalCache: TerminalLogCache?
    private let attachmentCache: AttachmentCache?
    private let actions: ArchiveActions
    private let onDone: (() -> Void)?
    private let title: String
    private let showsScopePicker: Bool
    @State private var path: [ArchiveRoute] = []
    @State private var continuing: ArchivedChat?

    /// `onDone` adds a Done button, for a browser shown as a sheet.
    public init(model: ArchiveBrowserModel, terminalCache: TerminalLogCache?, attachmentCache: AttachmentCache? = nil,
                actions: ArchiveActions = ArchiveActions(), onDone: (() -> Void)? = nil,
                title: String = "Archive", showsScopePicker: Bool = true) {
        _model = State(initialValue: model)
        self.terminalCache = terminalCache
        self.attachmentCache = attachmentCache
        self.actions = actions
        self.onDone = onDone
        self.title = title
        self.showsScopePicker = showsScopePicker
    }

    public var body: some View {
        NavigationStack(path: $path) {
            list
                .navigationTitle(title)
                .toolbar {
                    if showsScopePicker {
                        ToolbarItem(placement: .principal) {
                            Picker("Show", selection: $model.scope) {
                                ForEach(ArchiveScope.allCases) { Text($0.label).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .fixedSize()
                            .accessibilityIdentifier("archiveScope")
                        }
                    }
                    if let onDone {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done", action: onDone).accessibilityIdentifier("archiveDone")
                        }
                    }
                }
                .searchable(text: $model.searchText, tokens: $model.tokens, suggestedTokens: .constant(model.suggestedTokens),
                            prompt: model.scope == .chats ? "Search Chats" : "Search Terminals") { token in
                    Label(token.label, systemImage: token.systemImage)
                }
                .navigationDestination(for: ArchiveRoute.self) { route in destination(route) }
                .task { await model.follow() }
                .task(id: searchKey) {
                    // Wait for typing to pause before asking the host.
                    do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                    await model.search()
                }
                .sheet(item: $continuing) { chat in
                    ContinueChatSheet(model: ContinueChatModel(chat: chat, store: model.store, environment: model.environment,
                                                               workspaceName: model.exportedWorkspace(chat.projectID))) { result in
                        actions.continued?(result)
                    }
                    .agentLandSheetPage()
                }
        }
    }

    private var searchKey: String {
        "\(model.scope.rawValue)|\(model.searchText)|\(model.tokens.map(\.id).joined(separator: ","))"
    }

    // MARK: Lists

    private var list: some View {
        List {
            if let notice = model.notice {
                Section {
                    InlineNotice(notice, tone: .warning, onDismiss: { model.dismissNotice() })
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }
            switch model.scope {
            case .chats: chatSections.surfaceRows()
            case .terminals: logSection.surfaceRows()
            }
            if let caption = model.syncCaption {
                Section {} footer: {
                    Text(caption)
                        .agentLandFont(.metadata)
                        .foregroundStyle(AgentLandColor.textSecondary)
                        .accessibilityIdentifier("archiveSyncStatus")
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .listPageBackground()
        .overlay { emptyState }
        .accessibilityIdentifier("archiveList")
    }

    @ViewBuilder private var chatSections: some View {
        if model.query.hasText {
            if !model.titleMatches.isEmpty {
                Section {
                    ForEach(model.titleMatches) { chatRow($0) }
                } header: {
                    Text("Chats")
                }
            }
            Section {
                ForEach(model.hits) { hitRow($0) }
                if model.searching {
                    ProgressView().frame(maxWidth: .infinity).agentLandRowHeight()
                } else if model.canLoadMoreHits {
                    Button("More Results") { Task { await model.loadMoreHits() } }
                        .agentLandRowHeight()
                        .onAppear { Task { await model.loadMoreHits() } }
                }
            } header: {
                Text(hitsHeader).accessibilityIdentifier("archiveSearchSource")
            }
        } else {
            ForEach(model.groups) { group in
                Section {
                    ForEach(group.chats) { chatRow($0) }
                } header: {
                    Text(group.title)
                }
            }
        }
    }

    @ViewBuilder private var logSection: some View {
        let logs = model.visibleLogs
        if !logs.isEmpty {
            Section {
                ForEach(logs) { log in
                    logLink(log)
                    .contextMenu {
                        Button("Delete…", systemImage: "trash", role: .destructive) { model.requestDelete(log) }
                            .disabled(!model.canDelete || log.isRunning)
                    }
                    // Its Delete asks beside this row (owner, 2026-10-08).
                    .confirmationDialog(logDeleteTitle, isPresented: logDeleteDialog(log), titleVisibility: .visible,
                                        presenting: model.pendingLogDelete) { log in
                        Button("Delete", role: .destructive) { Task { await model.confirmDelete(log, cache: terminalCache) } }
                        Button("Cancel", role: .cancel) {}
                    } message: { _ in
                        Text("Its recorded output is deleted from \(model.environment.hostName) and from this device.")
                    }
                }
            } header: {
                Text("Newest First")
            }
        }
    }

    @ViewBuilder private var emptyState: some View {
        if model.loaded {
            switch model.scope {
            case .chats:
                if model.query.hasText {
                    if model.titleMatches.isEmpty, model.hits.isEmpty, !model.searching { ContentUnavailable.search(text: model.searchText) }
                } else if model.chats.isEmpty {
                    if model.query.hasFilters {
                        ContentUnavailable("No Matching Chats", systemImage: "line.3.horizontal.decrease.circle", description: "Remove a filter to see more.")
                    } else {
                        ContentUnavailable("No Archived Chats", systemImage: "archivebox",
                                           description: "Chats appear here once \(model.environment.hostName) archives them.")
                    }
                }
            case .terminals:
                if model.visibleLogs.isEmpty {
                    if model.searchText.isEmpty && model.tokens.isEmpty {
                        ContentUnavailable("No Terminal Logs", systemImage: "terminal",
                                           description: "Terminal output recorded on \(model.environment.hostName) appears here.")
                    } else {
                        ContentUnavailable.search(text: model.searchText)
                    }
                }
            }
        }
    }

    private var hitsHeader: String {
        switch model.hitsSource {
        case let .host(name)?: "Messages · Searched on \(name)"
        case .device?: model.environment.online ? "Messages · Searched on \(Self.deviceName)" : "Messages · Searched on \(Self.deviceName), offline"
        case nil: "Messages"
        }
    }

    @MainActor static var deviceName: String {
        #if canImport(UIKit)
        "this " + UIDevice.current.model
        #else
        "this Mac"
        #endif
    }

    // MARK: Rows

    @ViewBuilder private func logLink(_ log: ArchivedTerminalLog) -> some View {
        if let open = actions.openTerminalLog {
            Button { open(log) } label: { ArchiveLogRow(log: log, workspace: model.workspaceName(log.projectID)) }
        } else {
            NavigationLink(value: ArchiveRoute.log(log)) { ArchiveLogRow(log: log, workspace: model.workspaceName(log.projectID)) }
        }
    }

    private func showArchivedChat(_ id: String) {
        if let show = actions.showArchivedChat { show(id) }
        else { path.append(.chat(id)) }
    }

    private func chatRow(_ chat: ArchivedChat) -> some View {
        rowLink(chat) {
            ArchiveChatRow(chat: chat, workspace: model.workspaceName(chat.projectID), plain: model.environment.isChatsSpace(chat.projectID),
                           time: ChatLibrary.rowTime(chat.updatedAt, calendar: .current))
        }
        .swipeActions(edge: .leading) {
            Button {
                Task { await model.setPinned(!chat.pinned, for: chat) }
            } label: {
                Label(chat.pinned ? "Unpin" : "Pin", systemImage: chat.pinned ? "pin.slash" : "pin")
            }
            .tint(AgentLandColor.tint.color)
        }
        .swipeActions(edge: .trailing) {
            if model.canDelete {
                // Not the destructive role, which would take the row away under its question.
                Button { model.requestDelete(chat) } label: { Label("Delete", systemImage: "trash") }
                    .tint(.red)
            }
        }
        .contextMenu { chatMenu(chat) }
        // Its Delete asks beside this row (owner, 2026-10-08): a confirmation points at what it acts on.
        .confirmationDialog(deleteTitle, isPresented: deleteDialog(chat), titleVisibility: .visible, presenting: model.pendingDelete) { chat in
            Button("Delete", role: .destructive) { Task { await model.confirmDelete(chat, attachments: attachmentCache) } }
            Button("Cancel", role: .cancel) {}
        } message: { chat in
            Text(ChatDeleteCopy.message(hostName: model.environment.hostName, plainChat: model.environment.isChatsSpace(chat.projectID)))
        }
    }

    private func hitRow(_ hit: ArchiveSearchHit) -> some View {
        Button {
            if let chat = model.chats.first(where: { $0.id == hit.chatID }), actions.openChat?(chat) == true { return }
            showArchivedChat(hit.chatID)
        } label: {
            ArchiveHitRow(hit: hit, workspace: model.workspaceName(hit.projectID))
        }
        .buttonStyle(.plain)
    }

    /// A chat opens in a chat tab when the app can, otherwise as the archive's copy.
    @ViewBuilder private func rowLink<Label: View>(_ chat: ArchivedChat, @ViewBuilder label: () -> Label) -> some View {
        if let openChat = actions.openChat {
            Button {
                if !openChat(chat) { showArchivedChat(chat.id) }
            } label: {
                label()
            }
            .buttonStyle(.plain)
        } else {
            NavigationLink(value: ArchiveRoute.chat(chat.id)) { label() }
        }
    }

    @ViewBuilder private func chatMenu(_ chat: ArchivedChat) -> some View {
        Button("Show Archived Copy", systemImage: "archivebox") { showArchivedChat(chat.id) }
        Button(chat.pinned ? "Unpin" : "Pin", systemImage: chat.pinned ? "pin.slash" : "pin") {
            Task { await model.setPinned(!chat.pinned, for: chat) }
        }
        if actions.continued != nil {
            Button("Continue with…", systemImage: "arrow.triangle.swap") { continuing = chat }
                .disabled(!model.environment.online)
        }
        Menu {
            ShareLink(item: export(chat, .markdown), preview: SharePreview(chat.displayTitle + ".md")) { Label("Markdown", systemImage: "doc.richtext") }
            ShareLink(item: export(chat, .json), preview: SharePreview(chat.displayTitle + ".json")) { Label("JSON", systemImage: "curlybraces") }
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
        Divider()
        Button("Delete…", systemImage: "trash", role: .destructive) { model.requestDelete(chat) }
            .disabled(!model.canDelete)
    }

    private func export(_ chat: ArchivedChat, _ format: ArchiveExportFormat) -> ArchiveChatExport {
        ArchiveChatExport(chat: chat, format: format, client: model.environment.online ? model.environment.client : nil, store: model.store,
                          workspace: model.exportedWorkspace(chat.projectID))
    }

    // MARK: Destinations and dialogs

    @ViewBuilder private func destination(_ route: ArchiveRoute) -> some View {
        switch route {
        case let .chat(id):
            ArchivedChatView(model: ArchivedChatModel(chatID: id, store: model.store, environment: model.environment, attachments: attachmentCache),
                             actions: actions)
        case let .log(log):
            if let terminalCache {
                TerminalLogViewer(log: log, cache: terminalCache, fetcher: model.environment.online ? model.environment.client : nil,
                                  reachable: model.environment.online)
            } else {
                ContentUnavailable("Output Unavailable", systemImage: "terminal", description: "Terminal output can’t be saved on this device.")
            }
        }
    }

    private var deleteTitle: String { "Delete “\(model.pendingDelete?.displayTitle ?? "")”?" }
    private var logDeleteTitle: String { "Delete “\(model.pendingLogDelete?.displayTitle ?? "")”?" }

    /// Whether this chat's row asks its Delete: only the row of the chat asked about presents it.
    private func deleteDialog(_ chat: ArchivedChat) -> Binding<Bool> {
        Binding(get: { model.pendingDelete?.id == chat.id }, set: { if !$0, model.pendingDelete?.id == chat.id { model.pendingDelete = nil } })
    }

    private func logDeleteDialog(_ log: ArchivedTerminalLog) -> Binding<Bool> {
        Binding(get: { model.pendingLogDelete?.id == log.id }, set: { if !$0, model.pendingLogDelete?.id == log.id { model.pendingLogDelete = nil } })
    }
}

/// Title, agent and workspace, and the last activity. A plain chat's names its space alone: which agent runs it
/// is the host's business.
struct ArchiveChatRow: View {
    let chat: ArchivedChat
    let workspace: String
    var plain = false
    let time: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: AgentLandSpacing.small) {
            VStack(alignment: .leading, spacing: AgentLandSpacing.xxxSmall) {
                HStack(spacing: AgentLandSpacing.xxSmall) {
                    if chat.pinned {
                        Image(systemName: "pin.fill")
                            .foregroundStyle(AgentLandColor.glyphTertiary)
                            .accessibilityLabel("Pinned")
                    }
                    Text(chat.displayTitle)
                        .agentLandFont(.body)
                        .foregroundStyle(AgentLandColor.text)
                        .lineLimit(1)
                }
                Text(plain ? workspace : "\(chat.agent.displayName) · \(workspace)")
                    .agentLandFont(.metadata)
                    .foregroundStyle(AgentLandColor.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: AgentLandSpacing.xSmall)
            Text(time)
                .agentLandFont(.metadata)
                .foregroundStyle(AgentLandColor.textSecondary)
        }
        .agentLandRowHeight(.twoLine)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("archiveChatRow")
    }
}

/// A matching message: its chat's title, the snippet with matches emphasized,
/// who wrote it and when.
struct ArchiveHitRow: View {
    let hit: ArchiveSearchHit
    let workspace: String

    var body: some View {
        VStack(alignment: .leading, spacing: AgentLandSpacing.xxSmall) {
            HStack(alignment: .firstTextBaseline) {
                Text(hit.displayTitle)
                    .agentLandFont(.bodyEmphasized)
                    .foregroundStyle(AgentLandColor.text)
                    .lineLimit(1)
                Spacer(minLength: AgentLandSpacing.xSmall)
                if let date = hit.createdAt {
                    Text(ChatLibrary.rowTime(date))
                        .agentLandFont(.metadata)
                        .foregroundStyle(AgentLandColor.textSecondary)
                }
            }
            Text(ArchiveSnippet.attributedString(hit.snippet, matchColor: AgentLandColor.text.color))
                .agentLandFont(.secondary)
                .foregroundStyle(AgentLandColor.textSecondary)
                .lineLimit(3)
            Text(detail)
                .agentLandFont(.metadata)
                .foregroundStyle(AgentLandColor.textSecondary)
                .lineLimit(1)
        }
        .agentLandRowHeight(.twoLine)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("archiveSearchResult")
    }

    /// "You · Claude Code · my-app" or "Claude Code · my-app".
    private var detail: String {
        let agent = hit.provider.map { AgentProvider(id: $0).displayName }
        var parts = [hit.role == .user ? "You" : agent ?? "Reply"]
        if hit.role == .user, let agent { parts.append(agent) }
        parts.append(workspace)
        return parts.joined(separator: " · ")
    }
}

/// A terminal log: title, program, workspace and size; running logs are marked.
struct ArchiveLogRow: View {
    let log: ArchivedTerminalLog
    let workspace: String

    var body: some View {
        HStack(spacing: AgentLandSpacing.small) {
            Image(systemName: "terminal")
                .foregroundStyle(AgentLandColor.glyphTertiary)
                .agentLandIconFrame()
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: AgentLandSpacing.xxxSmall) {
                Text(log.displayTitle)
                    .agentLandFont(.body)
                    .foregroundStyle(AgentLandColor.text)
                    .lineLimit(1)
                Text("\(log.programName) · \(workspace) · \(TerminalLogViewer.bytes(log.bytes))")
                    .agentLandFont(.metadata)
                    .foregroundStyle(AgentLandColor.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: AgentLandSpacing.xSmall)
            if log.isRunning {
                StatusDot(.working, label: "Running")
            } else {
                Text(ChatLibrary.rowTime(log.startedAt))
                    .agentLandFont(.metadata)
                    .foregroundStyle(AgentLandColor.textSecondary)
            }
        }
        .agentLandRowHeight(.twoLine)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("archiveLogRow")
    }
}
