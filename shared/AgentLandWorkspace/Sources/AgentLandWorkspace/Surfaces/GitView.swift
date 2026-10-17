import SwiftUI
import AgentLandCore
import AgentLandDesign
#if os(iOS)
import UIKit
#endif

/// The Git surface: the chosen repository's branch and its changes in Merge Conflicts, Staged Changes
/// and Changes, each file's status in words. Swipes, the context menu and VoiceOver actions stage and
/// unstage; Stage All and Unstage All sit in the section headers. A tap shows the file's diff. The
/// commit bar floats over the list: the message, who the commit is made as, and Commit (⌘↩).
struct GitSurface: View {
    @Environment(WorkspaceModel.self) private var workspace
    @Environment(\.dynamicTypeSize) private var typeSize
    let tab: WorkspaceTab

    private var session: GitSession { workspace.gitSession(for: tab) }

    var body: some View {
        let session = self.session
        content(session)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AgentLandColor.canvas)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if session.status != nil, session.supports(.commit) {
                    GitCommitBar(session: session)
                }
            }
            .overlay(alignment: .top) { GitNoticePresenter(session: session, successDuration: .seconds(6)) }
            .task(id: workspace.tabRefreshGeneration[tab.id]) { await session.loadIfNeeded() }
            .onChange(of: workspace.connectionEpoch) { _, _ in
                // Read again what failed while the host was unreachable.
                if session.loadIssue != nil { Task { await session.load() } }
            }
            .onChange(of: workspace.presentationTicket, initial: true) { _, _ in
                session.reportPresentationIfReady()
            }
            .onChange(of: workspace.locked) { _, locked in
                if locked { session.diff = nil }
            }
            .sheet(item: Bindable(session).diff) { request in
                GitDiffSheet(session: session, request: request)
                    .agentLandSheetPage()
            }
            .agentLandHaptic(.success, trigger: session.commits)
            .agentLandHaptic(.warning, trigger: session.notice) { _, notice in notice.map { $0.tone != .success } ?? false }
            .surfaceTitle(tab.title, systemImage: "arrow.triangle.branch", identifier: "gitActions",
                          value: session.status?.branch) { titleMenu(session) }
    }

    // MARK: Content

    @ViewBuilder private func content(_ session: GitSession) -> some View {
        if session.repositories.isEmpty {
            if session.loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let issue = session.loadIssue {
                ContentUnavailable("Git Unavailable", systemImage: "exclamationmark.triangle", description: issue,
                                   actionTitle: "Try Again") { Task { await session.load() } }
            } else {
                ContentUnavailable("No Git Repositories", systemImage: "arrow.triangle.branch",
                                   description: "This workspace has no Git repository in its folder or in a folder directly inside it.")
            }
        } else if session.status == nil {
            if let issue = session.loadIssue {
                ContentUnavailable("Git Unavailable", systemImage: "exclamationmark.triangle", description: issue,
                                   actionTitle: "Try Again") { Task { await session.refreshStatus() } }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            changesList(session)
        }
    }

    private func changesList(_ session: GitSession) -> some View {
        List {
            Section {
                repositoryHeader(session)
                    .listRowBackground(Rectangle().fill(AgentLandColor.canvas))
            }
            if let issue = session.loadIssue {
                InlineNotice("Couldn’t read the status", message: issue, tone: .warning, actionTitle: "Try Again",
                             action: { Task { await session.refreshStatus() } }, identifiers: .init(text: "gitIssue", action: "gitRetry"))
                    .listRowBackground(Rectangle().fill(AgentLandColor.canvas))
                    .listRowSeparator(.hidden)
            }
            if session.isClean {
                ContentUnavailable("No Changes", systemImage: "checkmark.circle",
                                   description: "The files match the last commit on \(session.status?.branch ?? "this branch").")
                    .listRowBackground(Rectangle().fill(AgentLandColor.canvas))
                    .listRowSeparator(.hidden)
            }
            rowsSection("Merge Conflicts", rows: session.conflictRows, session: session, bulk: nil)
            rowsSection("Staged Changes", rows: session.stagedRows, session: session,
                        bulk: session.canUnstage ? ("Unstage All", "gitUnstageAll", { Task { await session.unstageAll() } }) : nil)
            rowsSection("Changes", rows: session.changeRows, session: session,
                        bulk: session.canStage ? ("Stage All", "gitStageAll", { Task { await session.stageAll() } }) : nil)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable { await session.refreshStatus() }
        .environment(\.defaultMinListRowHeight, 48)
        .accessibilityIdentifier("gitList")
    }

    /// The branch, and the repository when the workspace has more than one (a menu that switches).
    @ViewBuilder private func repositoryHeader(_ session: GitSession) -> some View {
        let branch = Label(session.status?.branch ?? "", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
            .agentLandFont(.secondary)
            .foregroundStyle(AgentLandColor.textSecondary)
            .accessibilityLabel("Branch \(session.status?.branch ?? "")")
            .accessibilityIdentifier("gitBranch")
        if session.repositories.count > 1 {
            let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: AgentLandSpacing.xxSmall))
                                                      : AnyLayout(HStackLayout(spacing: AgentLandSpacing.small))
            layout {
                Menu {
                    repositoryPicker(session)
                } label: {
                    HStack(spacing: AgentLandSpacing.xxSmall) {
                        Image(systemName: "shippingbox").accessibilityHidden(true)
                        Text(session.repository?.name ?? "Repository").lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down").font(.caption.weight(.semibold))
                            .foregroundStyle(AgentLandColor.glyphTertiary).accessibilityHidden(true)
                    }
                    .agentLandFont(.bodyEmphasized)
                    .foregroundStyle(AgentLandColor.text)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel("Repository")
                .accessibilityValue(session.repository?.name ?? "")
                .accessibilityIdentifier("gitRepositoryPicker")
                if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }
                branch
            }
        } else {
            branch.frame(minHeight: 44, alignment: .leading)
        }
    }

    @ViewBuilder private func repositoryPicker(_ session: GitSession) -> some View {
        Picker("Repository", selection: Binding(get: { session.repository?.path ?? "" }, set: { path in
            if let chosen = session.repositories.first(where: { $0.path == path }) { Task { await session.select(chosen) } }
        })) {
            ForEach(session.repositories) { repository in
                Label(repository.name, systemImage: "shippingbox").tag(repository.path)
            }
        }
    }

    @ViewBuilder private func rowsSection(_ title: String, rows: [GitSession.Row], session: GitSession,
                                          bulk: (title: String, id: String, action: () -> Void)?) -> some View {
        if !rows.isEmpty {
            Section {
                ForEach(rows) { row in
                    GitChangeRow(row: row, busy: session.busyPaths.contains(row.path), session: session)
                        .listRowBackground(Rectangle().fill(AgentLandColor.canvas))
                        .listRowSeparatorTint(AgentLandColor.separator.color)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) { swipe(row, session: session) }
                        .contextMenu { menu(row, session: session) }
                }
            } header: {
                HStack {
                    Text(title)
                        .font(AgentLandTypeRole.metadata.font.weight(.semibold))
                        .foregroundStyle(AgentLandColor.textSecondary)
                        .accessibilityAddTraits(.isHeader)
                    Text("\(rows.count)")
                        .font(AgentLandTypeRole.metadata.font.monospacedDigit())
                        .foregroundStyle(AgentLandColor.textSecondary)
                        .accessibilityLabel(rows.count == 1 ? "1 file" : "\(rows.count) files")
                    Spacer()
                    if let bulk {
                        // The hit pad inside the label, so the button is one element (`.minimumTapTarget()` on the
                        // button made XCUITest see an untappable Other with its identifier first, 0ca9400).
                        Button(action: bulk.action) { Text(bulk.title).minimumTapTarget() }
                            .agentLandFont(.metadata)
                            .foregroundStyle(AgentLandColor.tint)
                            .disabled(!session.reachable || !session.busyPaths.isEmpty)
                            .accessibilityIdentifier(bulk.id)
                    }
                }
                .textCase(nil)
            }
        }
    }

    @ViewBuilder private func swipe(_ row: GitSession.Row, session: GitSession) -> some View {
        switch row.area {
        case .staged where session.canUnstage:
            Button { Task { await session.unstage([row]) } } label: { Label("Unstage", systemImage: "minus.circle") }
                .tint(AgentLandColor.textSecondary.color)
        case .changes where session.canStage:
            Button { Task { await session.stage([row]) } } label: { Label("Stage", systemImage: "plus.circle") }
                .tint(AgentLandColor.tint.color)
        case .conflicts where session.canStage:
            Button { Task { await session.stage([row]) } } label: { Label("Mark Resolved", systemImage: "checkmark.circle") }
                .tint(AgentLandColor.tint.color)
        default:
            EmptyView()
        }
    }

    @ViewBuilder private func menu(_ row: GitSession.Row, session: GitSession) -> some View {
        Button("Show Diff", systemImage: "text.alignleft") { session.showDiff(row) }
        // Stage and Unstage run once the menu has gone (`MenuAction`): the change disables the lifted row at once.
        switch row.area {
        case .staged where session.canUnstage:
            Button("Unstage", systemImage: "minus.circle") { MenuAction.afterDismissal { await session.unstage([row]) } }
        case .changes where session.canStage:
            Button("Stage", systemImage: "plus.circle") { MenuAction.afterDismissal { await session.stage([row]) } }
        case .conflicts where session.canStage:
            Button("Mark Resolved", systemImage: "checkmark.circle") { MenuAction.afterDismissal { await session.stage([row]) } }
        default:
            EmptyView()
        }
        Button("Copy Path", systemImage: "doc.on.doc") { WorkspacePlatform.copy(row.path) }
        if !row.isFolder && !(row.letter == "D") {
            Button("Open File", systemImage: "doc.text") { workspace.openFile(projectID: session.projectID, path: projectPath(row, session)) }
        }
    }

    private func projectPath(_ row: GitSession.Row, _ session: GitSession) -> String {
        guard let repository = session.repository, repository.path != "." else { return row.path }
        return repository.path + "/" + row.path
    }

    // MARK: Title menu

    @ViewBuilder private func titleMenu(_ session: GitSession) -> some View {
        if session.repositories.count > 1 {
            Menu("Repository", systemImage: "shippingbox") { repositoryPicker(session) }
        }
        if session.canStage, !session.changeRows.isEmpty {
            Button("Stage All", systemImage: "plus.circle") { Task { await session.stageAll() } }
        }
        if session.canUnstage, !session.stagedRows.isEmpty {
            Button("Unstage All", systemImage: "minus.circle") { Task { await session.unstageAll() } }
        }
        Button("Refresh", systemImage: "arrow.clockwise") { Task { await session.load() } }
    }
}

// MARK: Row

/// A changed file: its status letter and words, its name and folder. Tapping shows its diff; the
/// VoiceOver actions stage or unstage it.
private struct GitChangeRow: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let row: GitSession.Row
    let busy: Bool
    let session: GitSession
    @ScaledMetric(relativeTo: .body) private var letterWidth: CGFloat = 26

    var body: some View {
        Button { session.showDiff(row) } label: {
            HStack(alignment: typeSize.isAccessibilitySize ? .top : .center, spacing: AgentLandSpacing.small) {
                Text(row.letter)
                    .font(AgentLandTypeRole.code.font.weight(.semibold))
                    .foregroundStyle(letterColor)
                    .frame(width: letterWidth, height: letterWidth)
                    .background(letterColor.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: AgentLandSpacing.xxxSmall) {
                    Text(row.name)
                        .agentLandFont(.body)
                        .foregroundStyle(AgentLandColor.text)
                        .lineLimit(typeSize.isAccessibilitySize ? 4 : 1)
                        .truncationMode(.middle)
                    Text(detail)
                        .agentLandFont(.metadata)
                        .foregroundStyle(AgentLandColor.textSecondary)
                        .lineLimit(typeSize.isAccessibilitySize ? 4 : 1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if busy { ProgressView().controlSize(.small) }
            }
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .workspaceRowHover()
        .accessibilityLabel(row.name)
        .accessibilityValue(spokenValue)
        .accessibilityHint("Shows the diff.")
        .accessibilityAction(named: actionName) { perform() }
        .accessibilityIdentifier("gitChange-\(row.area.rawValue)-\(row.path)")
    }

    /// The status in words, and the folder.
    private var detail: String {
        row.folder.isEmpty ? row.words : "\(row.words) · \(row.folder)"
    }

    private var spokenValue: String {
        let area = switch row.area {
        case .staged: "Staged"
        case .changes: "Not staged"
        case .conflicts: "Merge conflict"
        }
        return [row.words, area, row.folder.isEmpty ? nil : "in \(row.folder)"].compactMap { $0 }.joined(separator: ", ")
    }

    private var actionName: String {
        switch row.area {
        case .staged: "Unstage"
        case .changes: "Stage"
        case .conflicts: "Mark Resolved"
        }
    }

    private func perform() {
        switch row.area {
        case .staged: if session.canUnstage { Task { await session.unstage([row]) } }
        case .changes, .conflicts: if session.canStage { Task { await session.stage([row]) } }
        }
    }

    private var letterColor: AgentLandColor {
        switch row.area {
        case .conflicts: return .warning
        default:
            switch row.letter {
            case "A", "U", "?": return .success
            case "D": return .danger
            default: return .tint
            }
        }
    }
}

// MARK: Commit bar

/// The commit bar, floating over the list on Liquid Glass: the message, who the commit is made as,
/// and Commit. ⌘↩ commits (on iPad from the menu bar, elsewhere from the button). In the iPhone drawer's Git page
/// (`band`) it is a band across the page's foot on the panel's own tone, as Files' uploads are, since glass would sit
/// on the panel's glass (GI-3). At an accessibility text size the band keeps only the message and Commit: with its
/// caption it took 467 of the drawer page's 592 points at the largest size and left the list a sliver (run b9b2), so the
/// page says who commits in its Repository section and the Staged section's count says what.
struct GitCommitBar: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @Bindable var session: GitSession
    var band = false
    @FocusState private var focused: Bool

    var body: some View {
        if band {
            fields
                .padding(.horizontal, AgentLandSpacing.medium)
                .padding(.vertical, AgentLandSpacing.small)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AgentLandColor.surfaceRaised)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("gitCommitBar")
        } else {
            fields
                .padding(AgentLandSpacing.small)
                // A container of controls: its glass doesn't react to touches itself.
                .glassControl(in: RoundedRectangle(cornerRadius: AgentLandRadius.composer, style: .continuous), interactive: false)
                .padding(.horizontal, AgentLandSpacing.small)
                .padding(.bottom, AgentLandSpacing.xSmall)
                .frame(maxWidth: 720)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("gitCommitBar")
        }
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: AgentLandSpacing.xSmall) {
            TextField(text: $session.message,
                      prompt: Text("Commit message").foregroundStyle(AgentLandColor.textSecondary.color), axis: .vertical) {
                Text("Commit message")
            }
            .textFieldStyle(.plain)
            .agentLandFont(.body)
            .foregroundStyle(AgentLandColor.text)
            .lineLimit(1...(typeSize.isAccessibilitySize ? (band ? 2 : 3) : 5))
            .focused($focused)
            .disabled(session.committing)
            .accessibilityIdentifier("gitCommitMessage")
            .padding(.horizontal, AgentLandSpacing.xxSmall)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            // The whole row focuses the field, not only its line of text.
            .contentShape(Rectangle())
            .onTapGesture { if !session.committing { focused = true } }

            let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: AgentLandSpacing.xSmall))
                                                      : AnyLayout(HStackLayout(alignment: .center, spacing: AgentLandSpacing.small))
            layout {
                if !(band && typeSize.isAccessibilitySize) {
                    Text(caption)
                        .agentLandFont(.metadata)
                        .foregroundStyle(AgentLandColor.textSecondary)
                        .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("gitCommitIdentity")
                }
                Button {
                    // The keyboard goes before the commit starts: the field is disabled while it commits, and a focused
                    // field disabled during SwiftUI's update hides the keyboard from inside that update, which in the
                    // iPhone drawer's panel laid the panel out again and again without end.
                    if band { WorkspacePlatform.endEditing() }
                    focused = false
                    Task { await session.commit() }
                } label: {
                    if session.committing {
                        ProgressView().tint(AgentLandColor.onTint.color)
                    } else {
                        Text("Commit")
                    }
                }
                .buttonStyle(.agentLandPrimary)
                .disabled(!session.canCommit)
                .commitShortcut()
                .accessibilityLabel(session.committing ? "Committing" : "Commit")
                .accessibilityHint(session.commitBlocker ?? "Commits the staged changes.")
                .accessibilityIdentifier("gitCommit")
            }
        }
    }

    /// What would be committed, and who the commit is made as (or that no identity is set).
    private var caption: String {
        let staged = session.stagedRows.count
        let what = staged == 0 ? "Nothing staged" : staged == 1 ? "1 staged file" : "\(staged) staged files"
        let who = session.identity.map { $0.isComplete ? "as \($0.formatted)" : GitWords.identityMissing }
        return [what, who].compactMap { $0 }.joined(separator: " · ")
    }
}

private extension View {
    /// ⌘↩ on the Commit button where no menu bar carries it (iPhone). On iPad and Mac the menu bar's
    /// Commit has it; the same shortcut on both reaches neither.
    func commitShortcut() -> some View {
        #if os(iOS)
        let own = UIDevice.current.userInterfaceIdiom != .pad
        return keyboardShortcut(own ? KeyboardShortcut(.return, modifiers: .command) : nil)
        #else
        return keyboardShortcut(nil)
        #endif
    }
}
