import SwiftUI
import AgentLandCore
import AgentLandDesign

#if os(iOS)
/// One native list page in Home's Mac folder picker. Each pushed page retains its own listing,
/// so Back restores the previous folder and the system preserves its scroll position.
struct HomePhoneFolderBrowser: View {
    @Environment(WorkspaceModel.self) private var model
    let start: String?
    let name: String
    let open: (String) -> Void
    let create: (FolderListing) -> Void
    let close: () -> Void

    @State private var browser: FolderBrowserModel?
    @State private var problem: String?

    private var manager: WorkspaceManager { model.workspaces }
    private var listing: FolderListing? { browser?.listing }
    private var shownWorkspace: String? { listing.flatMap { manager.workspaceID(at: $0.path) } }
    private var canOpen: Bool {
        guard let listing, listing.displayPath != "~", browser?.loading == false, !manager.adding else { return false }
        return shownWorkspace != nil || (manager.canAdd && manager.canChange)
    }

    var body: some View {
        List {
            if let listing {
                Section {
                    ForEach(listing.folders) { folder in
                        NavigationLink(value: folder) { folderLabel(folder) }
                            .disabled(manager.adding)
                            .listRowFill(.surface, separator: true)
                            .accessibilityLabel(folder.name)
                            .accessibilityValue([folder.workspaceID != nil ? "Already a workspace" : nil,
                                                 folder.gitRepository ? "Git repository" : nil]
                                .compactMap { $0 }.joined(separator: ", "))
                            .accessibilityIdentifier("homeFolder-\(folder.name)")
                    }
                } footer: {
                    if listing.truncated { Text("Showing the first 2,000 folders.") }
                }
            }
        }
        .listStyle(.plain)
        .listPageBackground()
        .overlay { status }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close", systemImage: "xmark", action: close)
                    .labelStyle(.iconOnly)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("homeWorkspacePickerClose")
            }
            ToolbarItem(placement: .confirmationAction) {
                if manager.adding {
                    ProgressView().accessibilityLabel("Opening Workspace")
                } else {
                    Button("Open", systemImage: "checkmark", action: openShown)
                        .labelStyle(.titleAndIcon)
                        .disabled(!canOpen)
                        .accessibilityHint(shownWorkspace == nil ? "Adds this folder as a workspace and opens it." : "Opens this workspace.")
                        .accessibilityIdentifier("homeFolderOpen")
                }
            }
            if manager.canCreate {
                ToolbarItemGroup(placement: .bottomBar) {
                    Button("Create Workspace", systemImage: "folder.badge.plus") {
                        if let listing { create(listing) }
                    }
                        .labelStyle(.titleAndIcon)
                        .disabled(!manager.canChange || listing == nil || manager.adding)
                        .accessibilityIdentifier("homeWorkspaceCreate")
                    Spacer()
                }
            }
        }
        .alert("Couldn’t Open Workspace", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(problem ?? "")
        }
        .task {
            let browser = self.browser ?? FolderBrowserModel(workspaces: manager)
            self.browser = browser
            guard browser.listing == nil else { return }
            await browser.open(start)
        }
        .accessibilityIdentifier("homeFolderPage")
    }

    private func folderLabel(_ folder: FolderEntry) -> some View {
        Label {
            VStack(alignment: .leading, spacing: AgentLandSpacing.xxSmall) {
                Text(folder.name).foregroundStyle(AgentLandColor.text)
                if folder.workspaceID != nil {
                    Text("Already a workspace")
                        .font(.subheadline)
                        .foregroundStyle(AgentLandColor.textSecondary)
                }
                if folder.gitRepository {
                    Text("Git repository")
                        .font(.subheadline)
                        .foregroundStyle(AgentLandColor.textSecondary)
                }
            }
        } icon: {
            Image(systemName: "folder").foregroundStyle(.tint)
        }
    }

    @ViewBuilder private var status: some View {
        if let issue = browser?.issue {
            ContentUnavailableView {
                Label("Couldn’t Load Folders", systemImage: "exclamationmark.triangle")
            } description: {
                Text(issue)
            } actions: {
                Button("Try Again", systemImage: "arrow.clockwise") { Task { await browser?.open(start) } }
                    .accessibilityIdentifier("homeFolderRetry")
            }
        } else if listing == nil {
            ProgressView().accessibilityLabel("Loading Folders")
        } else if listing?.folders.isEmpty == true {
            ContentUnavailableView("No Folders", systemImage: "folder")
        }
    }

    private func openShown() {
        guard canOpen, let listing else { return }
        if let id = shownWorkspace { open(id); return }
        Task {
            switch await manager.add(directory: listing.path) {
            case let .open(id): open(id)
            case let .problem(message): problem = message
            case .unconfirmed:
                problem = "\(model.hostName) didn’t confirm the new workspace. Check Workspaces in Settings before trying again."
            case .dropped: break
            }
        }
    }
}
#endif
