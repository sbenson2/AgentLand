import SwiftUI
import AgentLandCore
import AgentLandDesign

/// The repository page of the iPhone drawer's Git section, the native way (native-iOS batch 9): a sidebar list whose
/// sections fold (the changes and History open from the start, the others closed), pull to refresh, the commit bar
/// across its foot above the keyboard (`GitCommitBar`'s band), New Branch as an alert and Stash Changes as a sheet. A
/// file stages and unstages with its swipe, its context menu or VoiceOver's action; a commit or a stash pushes its page
/// in the drawer (`GitSavedChangePage`). The workspace owns its session; this view owns only its sections' folding and
/// its questions, sheets and alerts.
struct GitManagementTree: View {
    @Environment(WorkspaceModel.self) private var workspace
    @Environment(\.dynamicTypeSize) private var typeSize
    let tab: WorkspaceTab
    @State private var confirmation: GitTreeConfirmation?
    @State private var workingDiff: GitDiffRequest?
    @State private var expanded: [String: Bool] = [:]
    @State private var namingBranch = false
    @State private var stashing = false

    private var session: GitSession { workspace.gitSession(for: tab) }

    var body: some View {
        let session = self.session
        content(session)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Its page: the drawer panel's own platter in the drawer, the canvas elsewhere (2026-10-07).
            .groupedPageBackground()
            // The commit bar stays in sight above the keyboard, at the page's foot (GI-3): the drawer ends above the
            // keyboard, and a field inside the list went out of sight as it took focus (run b6).
            .safeAreaBar(edge: .bottom, spacing: 0) {
                if session.status != nil, session.supports(.commit) { GitCommitBar(session: session, band: true) }
            }
            // A change's refusal is the system's alert on iPhone and iPad, in sight wherever the person scrolled to make
            // it (a branch switch far down the list was refused out of sight, B-20); on the Mac it floats over the top.
            .overlay(alignment: .top) { GitNoticePresenter(session: session) }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    // Never disabled while a read runs: that read may have started before the change the person is
                    // refreshing for (a stash drop's own read, run b9b2), so a tap starts a fresh one in its place, as
                    // pull to refresh does.
                    Button { Task { await session.load() } } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .accessibilityLabel("Refresh Git")
                    .accessibilityIdentifier("gitTreeRefresh")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("gitTree")
            .task(id: workspace.tabRefreshGeneration[tab.id]) { await session.loadIfNeeded() }
            .onChange(of: workspace.connectionEpoch) { _, _ in
                if session.loadIssue != nil || session.managementIssue != nil { Task { await session.load() } }
            }
            .onChange(of: workspace.presentationTicket, initial: true) { _, _ in session.reportPresentationIfReady() }
            .onChange(of: workspace.locked) { _, locked in
                if locked { dismissPresentations(session) }
            }
            .onChange(of: session.repository?.path) { _, _ in
                workingDiff = nil; confirmation = nil; namingBranch = false; stashing = false
                // A commit's page belongs to the repository it was read from.
                workspace.phoneNavigation.drawerPath.removeAll { page in
                    if case .savedChange = page { return true }
                    return false
                }
            }
            .sheet(item: $workingDiff) { request in GitDiffSheet(session: session, request: request).agentLandSheetPage() }
            .sheet(isPresented: $stashing) { GitStashSheet(session: session).agentLandSheetPage() }
            .alert("New Branch", isPresented: $namingBranch) {
                TextField("Name", text: Bindable(session).newBranchName)
                    .workspaceNoAutocapitalization()
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("gitNewBranchName")
                Button("Create") {
                    let name = session.newBranchName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { return }
                    Task { await session.createBranch(name) }
                }
                .accessibilityIdentifier("gitCreateBranch")
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The branch starts at the current commit. To work on it, choose it in Branches.")
            }
    }

    /// Nothing stays over the lock: the page's questions, sheets and alerts close.
    private func dismissPresentations(_ session: GitSession) {
        workingDiff = nil; session.savedDiff = nil; confirmation = nil; namingBranch = false; stashing = false
    }

    // MARK: Content

    /// The repository's list; until it has a status, why not (no repository, a read that failed) or its loading.
    @ViewBuilder private func content(_ session: GitSession) -> some View {
        if session.status != nil {
            list(session)
        } else if session.repositories.isEmpty, !session.loading, session.loadIssue == nil {
            ContentUnavailable("No Git Repository", systemImage: "arrow.triangle.branch",
                               description: "This workspace has no Git repository in its folder or a folder directly inside it.")
        } else if let issue = session.loadIssue, !session.loading {
            ContentUnavailable("Couldn’t Read Git", systemImage: "exclamationmark.triangle", description: issue,
                               actionTitle: "Try Again") { Task { await session.load() } }
        } else {
            ProgressView().accessibilityLabel("Reading Git")
        }
    }

    private func list(_ session: GitSession) -> some View {
        List {
            repositorySection(session)
            changeSection("Conflicts", key: "conflicts", rows: session.conflictRows, session: session, bulk: nil)
            changeSection("Staged", key: "staged", rows: session.stagedRows, session: session,
                          bulk: session.canUnstage ? GitTreeBulk("Unstage All", id: "gitUnstageAll") { Task { await session.unstageAll() } } : nil)
            changeSection("Unstaged", key: "unstaged", rows: session.unstagedRows, session: session,
                          bulk: session.canStage ? GitTreeBulk("Stage All", id: "gitStageAll-unstaged") { Task { await session.stage(session.unstagedRows) } } : nil)
            changeSection("Untracked", key: "untracked", rows: session.untrackedRows, session: session,
                          bulk: session.canStage ? GitTreeBulk("Stage All", id: "gitStageAll-untracked") { Task { await session.stage(session.untrackedRows) } } : nil)
            if session.supports(.branches) { branchSections(session) }
            // History starts open: the drawer's Git section is the repository's history first (owner's request,
            // 2026-10-06: "the git (shows the git history)").
            if session.supports(.history) { historySection(session) }
            if session.supports(.remotes) { remotesSection(session) }
            if session.supports(.stashes) { stashesSection(session) }
        }
        .listStyle(.sidebar)
        .listPageBackground()
        .environment(\.defaultMinListRowHeight, 44)
        .refreshable { await session.load() }
    }

    /// Whether the section `key` is open: as the person left it, else as it starts.
    private func expansion(_ key: String, initially: Bool) -> Binding<Bool> {
        Binding(get: { expanded[key] ?? initially }, set: { expanded[key] = $0 })
    }

    // MARK: Repository

    /// The repository (a menu when the workspace has more than one), its branch and upstream, with what to know about
    /// them in its footer (GI-7).
    private func repositorySection(_ session: GitSession) -> some View {
        Section {
            if session.repositories.count > 1 {
                Picker("Repository", selection: Binding(get: { session.repository?.path ?? "" }, set: { path in
                    if let chosen = session.repositories.first(where: { $0.path == path }) { Task { await session.select(chosen) } }
                })) {
                    ForEach(session.repositories) { repository in Label(repository.name, systemImage: "shippingbox").tag(repository.path) }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("gitTreeRepository")
            } else {
                value("Repository", session.repository?.name ?? "Repository").accessibilityIdentifier("gitTreeRepository")
            }
            if let status = session.status {
                value("Branch", status.branch).accessibilityIdentifier("gitTreeBranch")
                if let current = session.branches.first(where: \.current) {
                    value("Upstream", current.upstream.map { "\($0) · \(current.ahead) ahead · \(current.behind) behind" } ?? "None")
                }
            }
            if session.isClean { value("Changes", "None") }
            // Who commits, when the commit bar has no room to say it (its missing identity is a footer warning).
            if commitBarIsCompact(session), let identity = session.identity, identity.isComplete {
                value("Commits As", identity.formatted).accessibilityIdentifier("gitCommitIdentity")
            }
        } footer: {
            warnings(session)
        }
    }

    /// Whether the commit bar at the page's foot shows only its message and Commit (`GitCommitBar.band` at an
    /// accessibility text size), so its caption's identity is told in this section instead.
    private func commitBarIsCompact(_ session: GitSession) -> Bool {
        typeSize.isAccessibilitySize && session.supports(.commit)
    }

    /// A fact and its value; the value in the token's secondary text, which keeps its contrast on paper and slate.
    private func value(_ title: String, _ value: String) -> some View {
        LabeledContent {
            Text(value).foregroundStyle(AgentLandColor.textSecondary)
        } label: {
            Text(title).foregroundStyle(AgentLandColor.text)
        }
    }

    /// What could not be read, a list cut short and conflicts to resolve, each with the warning symbol.
    @ViewBuilder private func warnings(_ session: GitSession) -> some View {
        let lines = [
            session.loadIssue ?? session.managementIssue,
            session.status?.truncated == true ? "Showing the first 500 changes. Stage All applies to the listed files." : nil,
            session.conflictRows.isEmpty ? nil : "Resolve conflicts on the Mac before committing.",
            commitBarIsCompact(session) && session.identity?.isComplete == false ? GitWords.identityMissing : nil
        ].compactMap { $0 }
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: AgentLandSpacing.xxSmall) {
                ForEach(lines, id: \.self) { line in
                    Label {
                        Text(line)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(AgentLandColor.warning)
                    }
                }
            }
        }
    }

    // MARK: Changes

    /// A section of changes, when it has any: its files as a tree, with its Stage All or Unstage All in the header.
    @ViewBuilder private func changeSection(_ title: String, key: String, rows: [GitSession.Row], session: GitSession,
                                            bulk: GitTreeBulk?) -> some View {
        if !rows.isEmpty {
            GitTreeSection(title, key: key, count: rows.count, expanded: expansion(key, initially: true)) {
                GitFileTreeRows(nodes: GitFileTreeNode.build(rows: rows), session: session, saved: nil,
                                showWorkingDiff: { row in
                                    guard let repository = session.repository else { return }
                                    workingDiff = GitDiffRequest(row: row, repository: repository.path)
                                }, confirmation: $confirmation)
            } bulk: {
                if let bulk {
                    // The hit pad inside the label, so the button is one element (0ca9400).
                    Button(action: bulk.action) { Text(bulk.title).minimumTapTarget() }
                        .buttonStyle(.borderless)
                        .font(.subheadline)
                        .disabled(!session.reachable || session.isMutating)
                        .accessibilityIdentifier(bulk.id)
                }
            }
        }
    }

    // MARK: Branches

    /// The local branches, a tap switching to one and a swipe deleting it (GI-5), then New Branch…; the remote
    /// branches in a section of their own.
    @ViewBuilder private func branchSections(_ session: GitSession) -> some View {
        let local = session.branches.filter { !$0.remote }
        GitTreeSection("Branches", key: "branches", count: local.count, expanded: expansion("branches", initially: false)) {
            ForEach(local) { branch in branchRow(branch, session: session) }
            Button("New Branch…", systemImage: "plus") { namingBranch = true }
                .disabled(!session.reachable || session.isMutating)
                .accessibilityIdentifier("gitNewBranch")
        }
        let remote = session.branches.filter(\.remote)
        if !remote.isEmpty {
            GitTreeSection("Remote Branches", key: "remoteBranches", count: remote.count,
                           expanded: expansion("remoteBranches", initially: false)) {
                ForEach(remote) { branch in
                    Button {
                        let name = branch.name.split(separator: "/").dropFirst().joined(separator: "/")
                        Task { await session.trackBranch(branch.name, name: name) }
                    } label: {
                        Label {
                            Text(branch.name).foregroundStyle(AgentLandColor.text).lineLimit(2)
                        } icon: {
                            Image(systemName: "arrow.down.to.line")
                        }
                    }
                    .disabled(session.isMutating || !session.reachable)
                    .accessibilityHint("Creates and switches to a local tracking branch.")
                    .accessibilityIdentifier("gitRemoteBranch-\(branch.name)")
                }
            }
        }
    }

    private func branchRow(_ branch: GitBranch, session: GitSession) -> some View {
        Button {
            guard !branch.current else { return }
            Task { await session.switchBranch(branch.name) }
        } label: {
            HStack(spacing: AgentLandSpacing.small) {
                Label {
                    Text(branch.name).foregroundStyle(AgentLandColor.text).lineLimit(2)
                } icon: {
                    Image(systemName: "arrow.triangle.branch")
                }
                Spacer(minLength: 0)
                if branch.current {
                    Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(.tint).accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .disabled(session.isMutating || !session.reachable)
        .accessibilityAddTraits(branch.current ? .isSelected : [])
        .accessibilityHint(branch.current ? "The current branch." : "Switches to this branch.")
        .accessibilityIdentifier("gitBranch-\(branch.name)")
        // Not the destructive role: the row stays until the host has deleted the branch, after the confirmation.
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !branch.current {
                Button { confirmation = .deleteBranch(branch) } label: { Label("Delete", systemImage: "trash") }
                    .tint(AgentLandColor.danger.color)
                    .accessibilityIdentifier("gitBranchDelete-\(branch.name)")
            }
        }
        .contextMenu {
            if !branch.current {
                // Once the menu has gone (`MenuAction`): switching disables this item at once.
                Button("Switch to Branch", systemImage: "arrow.triangle.branch") {
                    MenuAction.afterDismissal { await session.switchBranch(branch.name) }
                }
                    .disabled(session.isMutating || !session.reachable)
                Button("Delete Branch…", systemImage: "trash", role: .destructive) { confirmation = .deleteBranch(branch) }
            }
        }
        .accessibilityActions {
            if !branch.current {
                Button("Delete Branch") { confirmation = .deleteBranch(branch) }
            }
        }
        // Its Delete asks beside this row (owner, 2026-10-08).
        .modifier(GitConfirmationDialog(key: GitTreeConfirmation.branchKey(branch), confirmation: $confirmation, session: session))
    }

    // MARK: History, remotes and stashes

    private func historySection(_ session: GitSession) -> some View {
        GitTreeSection("History", key: "history", count: session.history.count, expanded: expansion("history", initially: true)) {
            if session.history.isEmpty { empty("No Commits Yet") }
            ForEach(session.history) { commit in
                // A commit pushes its page in the drawer: who made it, when, and the files it changed (GI-8).
                NavigationLink(value: WorkspacePhoneNavigation.DrawerPage.savedChange(tabID: tab.id, hash: commit.hash, stash: false,
                                                                                    title: commit.subject)) {
                    GitSavedChangeLabel(title: commit.subject, detail: "\(commit.shortHash) · \(commit.author)", date: commit.date)
                }
                .accessibilityIdentifier("gitHistory-\(commit.hash)")
            }
            if let cursor = session.historyCursor, !cursor.isEmpty {
                // Earlier commits come as the list reaches its end (GI-4); the row stays a button for a read that failed.
                Button {
                    Task { await session.loadMoreHistory() }
                } label: {
                    if session.loadingHistory {
                        ProgressView().frame(maxWidth: .infinity).accessibilityLabel("Loading earlier commits")
                    } else {
                        Text("Load Earlier Commits")
                    }
                }
                .disabled(session.loadingHistory)
                .onAppear { Task { await session.loadMoreHistory() } }
                .accessibilityIdentifier("gitLoadHistory")
            }
        }
    }

    /// Each remote with its address; Fetch, Pull and Push in its menu (GI-4).
    private func remotesSection(_ session: GitSession) -> some View {
        GitTreeSection("Remotes", key: "remotes", count: session.remotes.count, expanded: expansion("remotes", initially: false)) {
            if session.remotes.isEmpty { empty("No Remotes") }
            ForEach(session.remotes) { remote in
                if remote.supported {
                    Menu {
                        ForEach([GitRemoteAction.fetch, .pull, .push], id: \.rawValue) { action in
                            // Once the menu has gone (`MenuAction`): the change disables these items at once.
                            Button(action.rawValue.capitalized, systemImage: remoteSymbol(action)) {
                                MenuAction.afterDismissal { await session.remote(remote, action: action) }
                            }
                            .disabled(!session.reachable || session.isMutating)
                            .accessibilityIdentifier("gitRemote-\(action.rawValue)-\(remote.name)")
                        }
                        Divider()
                        Button("Copy URL", systemImage: "doc.on.doc") { WorkspacePlatform.copy(remote.url) }
                    } label: {
                        remoteLabel(remote.name, detail: remote.url)
                    }
                    .accessibilityHint("Fetch, pull or push.")
                    .accessibilityIdentifier("gitRemote-\(remote.name)")
                } else {
                    remoteLabel(remote.name, detail: "Manage this remote on the Mac")
                        .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func remoteLabel(_ name: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: AgentLandSpacing.xxSmall) {
            Text(name).foregroundStyle(AgentLandColor.text)
            Text(detail).font(.footnote).foregroundStyle(AgentLandColor.textSecondary).lineLimit(2).truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func remoteSymbol(_ action: GitRemoteAction) -> String {
        switch action {
        case .fetch: "arrow.down.circle"
        case .pull: "arrow.down.to.line"
        case .push: "arrow.up.circle"
        }
    }

    /// Stash Changes… (a sheet, GI-3), then each stash: a tap shows its files, a swipe or its menu applies or drops it.
    private func stashesSection(_ session: GitSession) -> some View {
        GitTreeSection("Stashes", key: "stashes", count: session.stashes.count, expanded: expansion("stashes", initially: false)) {
            Button("Stash Changes…", systemImage: "archivebox") { stashing = true }
                .disabled(!session.reachable || session.isMutating || !session.conflictRows.isEmpty || session.isClean)
                .accessibilityIdentifier("gitStashNew")
            if session.stashes.isEmpty { empty("No Stashes") }
            ForEach(session.stashes) { stash in
                NavigationLink(value: WorkspacePhoneNavigation.DrawerPage.savedChange(tabID: tab.id, hash: stash.hash, stash: true,
                                                                                    title: stash.message)) {
                    GitSavedChangeLabel(title: stash.message, detail: String(stash.hash.prefix(7)), date: stash.date)
                }
                .accessibilityIdentifier("gitStash-\(stash.hash)")
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button { confirmation = .dropStash(stash) } label: { Label("Drop", systemImage: "trash") }
                        .tint(AgentLandColor.danger.color)
                        .accessibilityIdentifier("gitStashDrop-\(stash.hash)")
                    Button { confirmation = .applyStash(stash) } label: { Label("Apply", systemImage: "arrow.uturn.backward") }
                        .tint(AgentLandColor.tint.color)
                        .accessibilityIdentifier("gitStashApply-\(stash.hash)")
                }
                .contextMenu {
                    Button("Apply Stash…", systemImage: "arrow.uturn.backward") { confirmation = .applyStash(stash) }
                    Button("Drop Stash…", systemImage: "trash", role: .destructive) { confirmation = .dropStash(stash) }
                }
                .accessibilityActions {
                    Button("Apply Stash") { confirmation = .applyStash(stash) }
                    Button("Drop Stash") { confirmation = .dropStash(stash) }
                }
                // Its Apply and Drop ask beside this row (owner, 2026-10-08).
                .modifier(GitConfirmationDialog(key: GitTreeConfirmation.stashKey(stash), confirmation: $confirmation, session: session))
            }
        }
    }

    private func empty(_ title: String) -> some View {
        Text(title).foregroundStyle(AgentLandColor.textSecondary)
    }
}

/// A section header's Stage All or Unstage All.
private struct GitTreeBulk {
    let title: String
    let id: String
    let action: () -> Void
    init(_ title: String, id: String, action: @escaping () -> Void) {
        self.title = title; self.id = id; self.action = action
    }
}

/// A section of the tree that folds from its header (the sidebar list's own disclosure): its title and count as one
/// element carrying `gitTreeSection-<key>`, and an optional button at its end.
private struct GitTreeSection<Content: View, Bulk: View>: View {
    let title: String
    let key: String
    let count: Int
    @Binding var expanded: Bool
    let content: Content
    let bulk: Bulk

    init(_ title: String, key: String, count: Int, expanded: Binding<Bool>, @ViewBuilder content: () -> Content,
         @ViewBuilder bulk: () -> Bulk) {
        self.title = title; self.key = key; self.count = count; _expanded = expanded
        self.content = content(); self.bulk = bulk()
    }

    var body: some View {
        Section(isExpanded: $expanded) {
            content
        } header: {
            HStack(spacing: AgentLandSpacing.small) {
                HStack(spacing: AgentLandSpacing.xSmall) {
                    Text(title)
                    Text(count, format: .number).monospacedDigit()
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("gitTreeSection-\(key)")
                Spacer(minLength: 0)
                bulk
            }
            .textCase(nil)
        }
    }
}

private extension GitTreeSection where Bulk == EmptyView {
    init(_ title: String, key: String, count: Int, expanded: Binding<Bool>, @ViewBuilder content: () -> Content) {
        self.init(title, key: key, count: count, expanded: expanded, content: content) { EmptyView() }
    }
}

/// A commit or a stash in the tree: its subject over its short hash, author and day.
private struct GitSavedChangeLabel: View {
    let title: String
    let detail: String
    let date: Date

    var body: some View {
        VStack(alignment: .leading, spacing: AgentLandSpacing.xxSmall) {
            Text(title).foregroundStyle(AgentLandColor.text).lineLimit(2)
            Text("\(detail) · \(date.formatted(date: .abbreviated, time: .omitted))")
                .font(.footnote).foregroundStyle(AgentLandColor.textSecondary).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A Git change's result, the native way (`noticePresentation`, GI-2): on iPhone and iPad a refusal, a failure or an
/// unconfirmed change (which says it may have run) in the system's alert, wherever the person is on the page, and a
/// success only heard by VoiceOver (the list, the commit bar and the haptic show it); on the Mac over the top of the
/// page, a confirmation going away by itself.
struct GitNoticePresenter: View {
    let session: GitSession
    var successDuration: Duration = .seconds(5)

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .noticePresentation(session.notice.map { NoticeContent(id: $0.id, $0.title, message: $0.message, tone: tone($0.tone)) },
                                identifiers: .init(text: "gitNotice", dismiss: "gitNoticeDismiss"),
                                successDuration: successDuration, dismiss: { session.notice = nil })
    }

    private func tone(_ tone: GitNotice.Tone) -> InlineNotice.Tone {
        switch tone {
        case .success: .success
        case .warning: .warning
        case .error: .error
        }
    }
}

/// Folder identity includes the area, so the same path may appear in both
/// staged and unstaged trees without sharing disclosure or row identity.
struct GitFileTreeNode: Identifiable, Hashable {
    let id: String
    let name: String
    let row: GitSession.Row?
    let children: [GitFileTreeNode]

    static func build(rows: [GitSession.Row]) -> [GitFileTreeNode] {
        func level(_ rows: [GitSession.Row], depth: Int, prefix: String) -> [GitFileTreeNode] {
            let groups = Dictionary(grouping: rows) { row in
                let parts = row.path.split(separator: "/").map(String.init)
                return parts.indices.contains(depth) ? parts[depth] : row.name
            }
            return groups.flatMap { name, members -> [GitFileTreeNode] in
                let path = prefix.isEmpty ? name : prefix + "/" + name
                let file = members.first { $0.path.split(separator: "/").count == depth + 1 }
                let children = members.filter { $0.path.split(separator: "/").count > depth + 1 }
                let base = (members.first?.area.rawValue ?? "") + "|" + path
                var result: [GitFileTreeNode] = []
                if !children.isEmpty {
                    result.append(GitFileTreeNode(id: base + "|folder", name: name, row: nil,
                                                  children: level(children, depth: depth + 1, prefix: path)))
                }
                if let file { result.append(GitFileTreeNode(id: base + "|file", name: name, row: file, children: [])) }
                return result
            }.sorted { lhs, rhs in
                if (lhs.row == nil) != (rhs.row == nil) { return lhs.row == nil }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        }
        return level(rows, depth: 0, prefix: "")
    }
}

private struct GitSavedContext { let hash: String; let stash: Bool }

/// Files of a tree, folders as the list's own disclosure. A working file's row shows its diff; its trailing swipe, its
/// context menu and VoiceOver's action stage or unstage it (GI-6), as the iPad's Git tab does. A saved file (a commit's
/// or a stash's) shows its diff from that commit.
private struct GitFileTreeRows: View {
    let nodes: [GitFileTreeNode]
    let session: GitSession
    let saved: GitSavedContext?
    let showWorkingDiff: (GitSession.Row) -> Void
    /// The page's question, which a working file's Discard asks beside its row; nil for a saved file.
    let confirmation: Binding<GitTreeConfirmation?>?
    var body: some View {
        ForEach(nodes) { node in
            if let row = node.row {
                file(row)
            } else {
                DisclosureGroup {
                    GitFileTreeRows(nodes: node.children, session: session, saved: saved, showWorkingDiff: showWorkingDiff,
                                    confirmation: confirmation)
                } label: {
                    Label {
                        Text(node.name).foregroundStyle(AgentLandColor.text)
                    } icon: {
                        Image(systemName: "folder")
                    }
                }
            }
        }
    }

    private func file(_ row: GitSession.Row) -> some View {
        Button {
            if let saved { session.showSavedDiff(commit: saved.hash, file: GitCommitFile(path: row.path, status: row.letter), stash: saved.stash) }
            else { showWorkingDiff(row) }
        } label: {
            Label {
                Text(row.name).foregroundStyle(AgentLandColor.text).lineLimit(2).truncationMode(.middle)
            } icon: {
                Image(systemName: symbol(row)).foregroundStyle(color(row))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .disabled(session.isMutating || !session.reachable)
        .accessibilityLabel(row.path).accessibilityValue(row.words)
        .accessibilityIdentifier(saved.map { "gitSavedFile-\($0.hash)-\(row.path)" } ?? "gitChange-\(row.area.rawValue)-\(row.path)")
        // No full swipe: in the drawer a long swipe would stage at once, past the button a person meant to see first.
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if saved == nil, let index = indexAction(row) {
                Button(action: index.perform) { Label(index.title, systemImage: index.symbol) }
                    .tint(index.unstages ? AgentLandColor.textSecondary.color : AgentLandColor.tint.color)
                    .accessibilityIdentifier(index.identifier)
            }
        }
        .contextMenu {
            if saved == nil, let index = indexAction(row) {
                // Once the menu has gone (`MenuAction`): the change disables its lifted row at once.
                Button(index.title, systemImage: index.symbol) { MenuAction.afterDismissal(index.perform) }
            }
            Button("Copy Path", systemImage: "doc.on.doc") { WorkspacePlatform.copy(row.path) }
            if saved == nil, row.area == .changes, !row.change.untracked, !row.isFolder, session.supports(.discard), let confirmation {
                Button("Discard unstaged changes", systemImage: "arrow.uturn.backward", role: .destructive) {
                    confirmation.wrappedValue = .discard(row)
                }
            }
        }
        .accessibilityActions {
            if saved == nil, let index = indexAction(row) {
                Button(index.title, action: index.perform)
            }
        }
        // Its Discard asks beside this row (owner, 2026-10-08).
        .modifier(GitConfirmationDialog(key: GitTreeConfirmation.discardKey(row), confirmation: confirmation, session: session))
    }

    /// Stage, Unstage or Mark Resolved for a working file, when the host offers it.
    private func indexAction(_ row: GitSession.Row) -> (title: String, symbol: String, identifier: String, unstages: Bool, perform: @MainActor () -> Void)? {
        let session = self.session
        switch row.area {
        case .staged where session.canUnstage:
            return ("Unstage", "minus.circle", "gitUnstage-\(row.path)", true, { Task { await session.unstage([row]) } })
        case .changes where session.canStage:
            return ("Stage", "plus.circle", "gitStage-\(row.path)", false, { Task { await session.stage([row]) } })
        case .conflicts where session.canStage:
            return ("Mark Resolved", "checkmark.circle", "gitStage-\(row.path)", false, { Task { await session.stage([row]) } })
        default:
            return nil
        }
    }

    /// The status as a symbol (VoiceOver reads it in words, the row's value).
    private func symbol(_ row: GitSession.Row) -> String {
        if row.area == .conflicts { return "exclamationmark.triangle.fill" }
        switch row.letter.trimmingCharacters(in: .whitespaces) {
        case "A": return "plus.circle.fill"
        case "U", "?": return "questionmark.circle.fill"
        case "D": return "minus.circle.fill"
        case "R": return "arrow.right.circle.fill"
        default: return "pencil.circle.fill"
        }
    }

    /// The system's status colours, as the iPad's Git tab colours its letters.
    private func color(_ row: GitSession.Row) -> AgentLandColor {
        if row.area == .conflicts { return .warning }
        switch row.letter.trimmingCharacters(in: .whitespaces) {
        case "A", "U", "?": return .success
        case "D": return .danger
        default: return .tint
        }
    }
}

private enum GitTreeConfirmation {
    case discard(GitSession.Row), deleteBranch(GitBranch), applyStash(GitStash), dropStash(GitStash)
    /// The row it is about, whose `GitConfirmationDialog` asks it.
    var key: String {
        switch self {
        case let .discard(row): Self.discardKey(row)
        case let .deleteBranch(branch): Self.branchKey(branch)
        case let .applyStash(stash), let .dropStash(stash): Self.stashKey(stash)
        }
    }
    static func discardKey(_ row: GitSession.Row) -> String { "file|" + row.id }
    static func branchKey(_ branch: GitBranch) -> String { "branch|" + branch.name }
    static func stashKey(_ stash: GitStash) -> String { "stash|" + stash.hash }
    var title: String {
        switch self { case .discard: "Discard unstaged changes?"; case .deleteBranch: "Delete branch?"; case .applyStash: "Apply stash?"; case .dropStash: "Drop stash?" }
    }
    var actionTitle: String {
        switch self { case .discard: "Discard"; case .deleteBranch: "Delete branch"; case .applyStash: "Apply"; case .dropStash: "Drop stash" }
    }
    var destructive: Bool { switch self { case .discard, .deleteBranch, .dropStash: true; case .applyStash: false } }
    var message: String {
        switch self {
        case let .discard(row): "Unstaged changes in \(row.path) will be lost. Staged changes will be kept."
        case let .deleteBranch(branch): "Delete \(branch.name)? Git will keep the branch if it has commits outside the current branch."
        case let .applyStash(stash): "Apply “\(stash.message)” to the current branch? The stash will be kept. Conflicts may need to be resolved on the Mac."
        case let .dropStash(stash): "“\(stash.message)” will be removed from the stash list. This cannot be undone in AgentLand."
        }
    }
    @MainActor func perform(_ session: GitSession) async {
        switch self {
        case let .discard(row): await session.discard(row)
        case let .deleteBranch(branch): await session.deleteBranch(branch.name)
        case let .applyStash(stash): await session.applyStash(stash)
        case let .dropStash(stash): await session.dropStash(stash)
        }
    }
}

/// The page's question on the row it is about (a file's Discard, a branch's Delete, a stash's Apply or Drop), so it
/// points at that row (owner, 2026-10-08; `DialogAnchor`); only that row presents it.
private struct GitConfirmationDialog: ViewModifier {
    let key: String
    let confirmation: Binding<GitTreeConfirmation?>?
    let session: GitSession

    func body(content: Content) -> some View {
        if let confirmation {
            content.confirmationDialog(confirmation.wrappedValue?.title ?? "Confirm Git change", isPresented: Binding(
                get: { confirmation.wrappedValue?.key == key },
                set: { if !$0, confirmation.wrappedValue?.key == key { confirmation.wrappedValue = nil } }
            ), presenting: confirmation.wrappedValue) { request in
                Button(request.actionTitle, role: request.destructive ? .destructive : nil) {
                    confirmation.wrappedValue = nil
                    Task { await request.perform(session) }
                }
                Button("Cancel", role: .cancel) { confirmation.wrappedValue = nil }
            } message: { request in Text(request.message) }
        } else {
            content
        }
    }
}

/// Stash Changes (GI-3): the message and whether untracked files go too, with what saving does in the footer. Save is
/// the confirmation, so it saves at once.
private struct GitStashSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var session: GitSession

    var body: some View {
        NavigationStack {
            AgentLandForm {
                Section {
                    TextField("Message (optional)", text: $session.stashMessage)
                        .accessibilityIdentifier("gitStashMessage")
                    Toggle("Include untracked files", isOn: $session.stashIncludeUntracked)
                        .accessibilityIdentifier("gitStashIncludeUntracked")
                } footer: {
                    Text(session.stashIncludeUntracked
                         ? "Staged, unstaged and untracked changes will be saved and cleared from the working files. The stash will remain available to apply."
                         : "Staged and unstaged changes will be saved and cleared from the working files. Untracked files will be kept.")
                }
            }
            .listPageBackground()
            .navigationTitle("Stash Changes")
            .workspaceInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }.accessibilityIdentifier("gitStashCancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        WorkspacePlatform.endEditing()
                        dismiss()
                        Task { await session.saveStash() }
                    }
                    .disabled(!session.canSaveStash)
                    .accessibilityIdentifier("gitStashSave")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

#if os(iOS)
/// A commit of the drawer's History, or a stash, pushed in the drawer's Git section (GI-8): which commit, who made it and
/// when, and the files it changed; a file's row shows its diff from that commit.
struct GitSavedChangePage: View {
    @Environment(WorkspaceModel.self) private var workspace
    let tab: WorkspaceTab
    let hash: String
    let stash: Bool

    var body: some View {
        let session = workspace.gitSession(for: tab)
        let key = (stash ? "stash|" : "commit|") + hash
        List {
            Section {
                value(stash ? "Stash" : "Commit", String(hash.prefix(7)))
                if !stash, let commit = session.history.first(where: { $0.hash == hash }) {
                    value("Author", commit.author)
                    value("Date", commit.date.formatted(date: .abbreviated, time: .shortened))
                } else if stash, let saved = session.stashes.first(where: { $0.hash == hash }) {
                    value("Date", saved.date.formatted(date: .abbreviated, time: .shortened))
                }
            }
            .surfaceRows()
            Section {
                if let detail = session.commitFiles[key] {
                    if detail.files.isEmpty { Text("No Changed Files").foregroundStyle(AgentLandColor.textSecondary) }
                    let rows = detail.files.map { GitSession.Row(area: .staged, change: GitChange(path: $0.path, status: $0.status + " ")) }
                    GitFileTreeRows(nodes: GitFileTreeNode.build(rows: rows), session: session, saved: GitSavedContext(hash: hash, stash: stash),
                                    showWorkingDiff: { _ in }, confirmation: nil)
                } else if let issue = session.detailIssues[key] {
                    Label {
                        Text(issue)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(AgentLandColor.warning)
                    }
                    Button("Try Again") { Task { await session.loadFiles(commit: hash, stash: stash) } }
                } else {
                    ProgressView().frame(maxWidth: .infinity).accessibilityLabel("Reading the changed files")
                }
            } header: {
                Text("Changed Files")
            } footer: {
                if session.commitFiles[key]?.truncated == true { Text("Showing the first 500 files.") }
            }
            .surfaceRows()
        }
        .listStyle(.insetGrouped)
        .listPageBackground()
        .environment(\.defaultMinListRowHeight, 44)
        .task(id: key) { await session.loadFiles(commit: hash, stash: stash) }
        .sheet(item: Bindable(session).savedDiff) { request in GitSavedDiffSheet(session: session, request: request).agentLandSheetPage() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("gitSavedChange")
    }

    private func value(_ title: String, _ value: String) -> some View {
        LabeledContent {
            Text(value).foregroundStyle(AgentLandColor.textSecondary)
        } label: {
            Text(title).foregroundStyle(AgentLandColor.text)
        }
    }
}
#endif

/// A file's diff from a commit or a stash, in a sheet with the system's close button (GI-10).
private struct GitSavedDiffSheet: View {
    @Environment(\.dismiss) private var dismiss
    let session: GitSession
    let request: GitSavedDiffRequest
    @State private var document: GitDiffDocument?
    @State private var issue: String?
    var body: some View {
        NavigationStack {
            Group {
                if let document {
                    if document.lines.isEmpty {
                        ContentUnavailable("No Differences", systemImage: "equal.circle",
                                           description: "Git shows no text changes for this file. It may be binary, or only its mode changed.")
                    } else {
                        GitDiffView(document: document)
                    }
                } else if let issue {
                    ContentUnavailable("Diff Unavailable", systemImage: "exclamationmark.triangle", description: issue,
                                       actionTitle: "Try Again") { Task { await load() } }
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(request.file)
            .workspaceInlineNavigationTitle()
            .toolbar { ToolbarItem(placement: .cancellationAction) { GitDiffCloseButton { dismiss() } } }
        }
        .task(id: request.id) { await load() }
    }

    private func load() async {
        issue = nil
        do { let response = try await session.loadSavedDiff(request); if !Task.isCancelled { document = GitDiffDocument(response.diff) } }
        catch { if !Task.isCancelled { issue = error.localizedDescription } }
    }
}
