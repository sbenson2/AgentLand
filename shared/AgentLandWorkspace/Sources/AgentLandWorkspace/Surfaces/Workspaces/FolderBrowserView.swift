import SwiftUI
import AgentLandCore
import AgentLandDesign

/// The folders of the Mac user's home folder (`GET /v1/folders`), one folder at a time: its places to
/// start from (the home folder, Developer, Desktop, Documents and the workspaces' folders) in the
/// Locations menu, a breadcrumb back up, its sub-folders (never files) with "Already a workspace" and
/// Git marked, and Show Hidden Folders. Add Folder adds the folder shown (Add Here); New Workspace
/// chooses it as the place for the new folder (Choose).
struct FolderBrowserView: View {
    enum Mode: Equatable {
        /// Add Folder…: Add Here makes the folder shown a workspace.
        case add
        /// New Workspace's location: Choose hands back the folder shown.
        case choose
    }

    @Environment(WorkspaceModel.self) private var model
    let mode: Mode
    /// The folder to show first; nil for the default (Developer when the home folder has one).
    let start: String?
    /// Cancel; nil when the browser was pushed and goes back instead.
    let cancel: (() -> Void)?
    /// Add: how adding ended. Choose: `.open` is not used; `choose` hands back the folder.
    var finish: (WorkspaceAddResult) -> Void = { _ in }
    var choose: (FolderListing) -> Void = { _ in }

    @State private var browser: FolderBrowserModel?
    @State private var problem: String?

    private var manager: WorkspaceManager { model.workspaces }
    private var listing: FolderListing? { browser?.listing }

    var body: some View {
        List {
            #if os(iOS)
            // A listing that failed with the last one still shown: the state in place, with Try Again (WS-5). With
            // nothing listed it is the page's content instead (below); a failed add is the system's alert.
            if let issue = browser?.issue, listing != nil {
                SettingsStatusSection("Couldn’t list this folder", systemImage: "exclamationmark.triangle", message: issue,
                                      identifier: "folderBrowserIssue", actionTitle: "Try Again",
                                      actionIdentifier: "folderBrowserRetry") { Task { await browser?.reload() } }
            }
            #else
            if let problem {
                InlineNotice(problem, tone: .error, onDismiss: { self.problem = nil },
                             identifiers: .init(text: "folderBrowserProblem", dismiss: "folderBrowserProblemDismiss"))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            if let issue = browser?.issue {
                InlineNotice("Couldn’t list this folder", message: issue, tone: .error, actionTitle: "Try Again",
                             action: { Task { await browser?.reload() } }, identifiers: .init(text: "folderBrowserIssue", action: "folderBrowserRetry"))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            #endif
            #if os(iOS)
            // Show Hidden Folders as a row of the list, with what Add Here or Choose will use as its footer (WS-3); the
            // Mac keeps its bar under the list.
            Section {
                Toggle("Show Hidden Folders", isOn: showHidden)
                    .agentLandFont(.body)
                    .listRowFill(.surface, separator: true)
                    .accessibilityIdentifier("folderShowHidden")
            } footer: {
                if let hint = footerHint { Text(hint) }
            }
            #endif
            if let listing {
                Section {
                    ForEach(listing.folders) { folder in folderRow(folder) }
                    if listing.folders.isEmpty && browser?.loading != true {
                        Text("No folders inside.")
                            .agentLandFont(.secondary)
                            .foregroundStyle(AgentLandColor.textSecondary)
                            .listRowFill(.surface)
                    }
                } footer: {
                    if listing.truncated {
                        // The system's footer on iPhone and iPad (WS-9).
                        Text("Showing the first 2,000 folders.")
                            #if os(macOS)
                            .agentLandFont(.metadata)
                            .foregroundStyle(AgentLandColor.textSecondary)
                            #endif
                    }
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .listPageBackground()
        .overlay {
            if listing == nil && browser?.loading != false && browser?.issue == nil {
                ProgressView()
            } else if listing == nil, let issue = browser?.issue {
                #if os(iOS)
                ContentUnavailable("Couldn’t List This Folder", systemImage: "exclamationmark.triangle", description: issue,
                                   descriptionIdentifier: "folderBrowserIssue") {
                    Button("Try Again") { Task { await browser?.reload() } }
                        .buttonStyle(.agentLandPrimary)
                        .accessibilityIdentifier("folderBrowserRetry")
                }
                #endif
            }
        }
        #if os(iOS)
        .alert("Couldn’t Add Folder", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(problem ?? "")
        }
        #endif
        .safeAreaInset(edge: .top, spacing: 0) { pathBar }
        #if os(macOS)
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        #endif
        .navigationTitle(mode == .add ? "Add Folder" : "Choose Location")
        .workspaceInlineNavigationTitle()
        .toolbar {
            if let cancel {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: cancel).accessibilityIdentifier("folderBrowserCancel")
                }
            }
            ToolbarItem(placement: .confirmationAction) { confirmButton }
        }
        .task {
            let browser = self.browser ?? FolderBrowserModel(workspaces: manager)
            self.browser = browser
            guard browser.listing == nil else { return }
            if let start {
                await browser.open(start)
            } else {
                await browser.open(nil)
                // Start in Developer when the home folder has one.
                if let home = browser.listing, home.displayPath == "~" {
                    let preferred = WorkspaceManager.defaultFolder(in: home)
                    if preferred != home.path { await browser.open(preferred) }
                }
            }
        }
    }

    // MARK: Parts

    private func folderRow(_ folder: FolderEntry) -> some View {
        Button { Task { await browser?.open(folder.path) } } label: {
            HStack(alignment: .firstTextBaseline, spacing: AgentLandSpacing.small) {
                Image(systemName: folder.workspaceID == nil ? "folder" : "folder.fill")
                    .font(AgentLandTypeRole.body.font)
                    .foregroundStyle(AgentLandColor.tint)
                    .agentLandIconFrame(.regular)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: AgentLandSpacing.xxxSmall) {
                    Text(folder.name)
                        .agentLandFont(.body)
                        .foregroundStyle(AgentLandColor.text)
                        .multilineTextAlignment(.leading)
                    if folder.workspaceID != nil {
                        Text("Already a workspace")
                            .agentLandFont(.metadata)
                            .foregroundStyle(AgentLandColor.textSecondary)
                    }
                }
                Spacer(minLength: 0)
                if folder.gitRepository { Badge("Git") }
                Image(systemName: "chevron.right")
                    .font(AgentLandTypeRole.metadata.font.weight(.semibold))
                    .foregroundStyle(AgentLandColor.glyphTertiary)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: AgentLandTapTarget.platformMinimum, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .workspaceRowHover()
        .listRowFill(.surface, separator: true)
        // On the button itself (no element around it), so it stays a button with these.
        .accessibilityLabel(folder.name)
        .accessibilityValue([folder.workspaceID != nil ? "Already a workspace" : nil, folder.gitRepository ? "Git repository" : nil]
            .compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint("Shows the folders inside it.")
        .accessibilityIdentifier("folder-\(folder.name)")
    }

    /// The Locations menu and the breadcrumb of the folder shown.
    private var pathBar: some View {
        HStack(spacing: AgentLandSpacing.xSmall) {
            Menu {
                ForEach(listing?.roots ?? []) { root in
                    Button(rootName(root), systemImage: rootSymbol(root)) { Task { await browser?.open(root.path) } }
                }
            } label: {
                Label("Locations", systemImage: "list.bullet")
                    .labelStyle(.iconOnly)
                    .font(AgentLandTypeRole.body.font)
                    .foregroundStyle(AgentLandColor.tint)
                    .frame(minWidth: AgentLandTapTarget.platformMinimum, minHeight: AgentLandTapTarget.platformMinimum)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(listing?.roots.isEmpty ?? true)
            .accessibilityLabel("Locations")
            .accessibilityIdentifier("folderRoots")
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: AgentLandSpacing.xxSmall) {
                        let steps = browser?.breadcrumb ?? []
                        ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                            if index > 0 {
                                Image(systemName: "chevron.right")
                                    .font(AgentLandTypeRole.caption.font.weight(.semibold))
                                    .foregroundStyle(AgentLandColor.glyphTertiary)
                                    .accessibilityHidden(true)
                            }
                            breadcrumbStep(step, last: index == steps.count - 1).id(index)
                        }
                    }
                    .padding(.trailing, AgentLandSpacing.small)
                }
                .onChange(of: listing?.path) { _, _ in
                    let last = (browser?.breadcrumb.count ?? 1) - 1
                    proxy.scrollTo(max(0, last), anchor: .trailing)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Path")
        }
        .padding(.leading, AgentLandSpacing.xxSmall)
        .groupedPageBackground()
        .workspaceHairline()
    }

    @ViewBuilder private func breadcrumbStep(_ step: (name: String, path: String), last: Bool) -> some View {
        let label = step.name == "~" ? "Home" : step.name
        if last {
            Text(label)
                .agentLandFont(.bodyEmphasized)
                .foregroundStyle(AgentLandColor.text)
                .lineLimit(1)
                .frame(minHeight: AgentLandTapTarget.platformMinimum)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("folderBreadcrumbCurrent")
        } else {
            Button { Task { await browser?.open(step.path) } } label: {
                Text(label)
                    .agentLandFont(.body)
                    .lineLimit(1)
                    .frame(minHeight: AgentLandTapTarget.platformMinimum)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(AgentLandColor.tint)
            .accessibilityHint("Shows this folder.")
            .accessibilityIdentifier("folderBreadcrumb-\(label)")
        }
    }

    /// The host names the home folder's root after its folder; here it is Home.
    private func rootName(_ root: FolderRoot) -> String {
        root.path == manager.homePath ? "Home" : root.name
    }

    private func rootSymbol(_ root: FolderRoot) -> String {
        guard let home = manager.homePath else { return "folder" }
        switch root.path {
        case home: return "house"
        case home + "/Desktop": return "menubar.dock.rectangle"
        case home + "/Documents": return "doc"
        case home + "/Developer": return "hammer"
        default: return "folder"
        }
    }

    #if os(macOS)
    /// Show Hidden Folders and what Add Here or Choose will use, in a bar under the list.
    private var footer: some View {
        VStack(alignment: .leading, spacing: AgentLandSpacing.xxSmall) {
            Toggle("Show Hidden Folders", isOn: showHidden)
                .agentLandFont(.body)
                .foregroundStyle(AgentLandColor.text)
                .frame(minHeight: AgentLandTapTarget.platformMinimum)
                .accessibilityIdentifier("folderShowHidden")
            if let hint = footerHint {
                Text(hint)
                    .agentLandFont(.metadata)
                    .foregroundStyle(AgentLandColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, AgentLandSpacing.medium)
        .padding(.vertical, AgentLandSpacing.xSmall)
        .groupedPageBackground()
        .workspaceHairline(.top)
    }
    #endif

    private var footerHint: String? {
        guard let listing else { return nil }
        switch mode {
        case .add:
            if isHome(listing) { return "Choose a folder inside your home folder to add it." }
            if manager.workspaceID(at: listing.path) != nil { return "This folder is already a workspace. Add Here opens it." }
            return "Add Here makes \(listing.displayPath) a workspace."
        case .choose:
            return "The new folder is made in \(listing.displayPath)."
        }
    }

    private var showHidden: Binding<Bool> {
        Binding(get: { browser?.showHidden ?? false }, set: { value in
            browser?.showHidden = value
            Task { await browser?.reload() }
        })
    }

    private func isHome(_ listing: FolderListing) -> Bool { listing.displayPath == "~" }

    @ViewBuilder private var confirmButton: some View {
        switch mode {
        case .add:
            if manager.adding {
                ProgressView().controlSize(.small).accessibilityLabel("Adding")
            } else {
                Button("Add Here") { add() }
                    .disabled(listing.map(isHome) ?? true || !manager.canChange)
                    .accessibilityIdentifier("folderAddHere")
            }
        case .choose:
            Button("Choose") { if let listing { choose(listing) } }
                .disabled(listing == nil)
                .accessibilityIdentifier("folderChoose")
        }
    }

    private func add() {
        guard let listing else { return }
        problem = nil
        Task {
            let result = await manager.add(directory: listing.path)
            if case let .problem(message) = result {
                problem = message
            } else {
                finish(result)
            }
        }
    }
}
