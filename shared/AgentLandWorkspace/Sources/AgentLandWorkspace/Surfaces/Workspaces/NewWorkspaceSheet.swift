import SwiftUI
import AgentLandCore
import AgentLandDesign

/// New Workspace…: a name, the folder to make it in (chosen with the folder browser; Developer in the
/// home folder when there is one) and whether it starts as a Git repository. Create makes the folder on
/// the host, adds it and hands its workspace to `created`.
struct NewWorkspaceSheet: View {
    @Environment(WorkspaceModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// Opens the new workspace.
    let created: (String) -> Void
    /// Home's folder picker supplies the folder being browsed; other entry points use the default.
    var initialLocation: FolderListing? = nil

    @State private var name = ""
    @State private var git = true
    /// The folder the new one is made in, as the host lists it.
    @State private var location: FolderListing?
    @State private var locationIssue: String?
    @State private var problem: String?
    @FocusState private var nameFocused: Bool
    @State private var askedNameFocus = false

    private var manager: WorkspaceManager { model.workspaces }
    private var nameProblem: String? { name.isEmpty ? nil : WorkspaceNaming.problem(folder: name) }
    private var canCreate: Bool {
        WorkspaceNaming.folderName(name) != nil && location != nil && !manager.adding && manager.canChange
    }

    var body: some View {
        NavigationStack {
            AgentLandForm {
                #if os(macOS)
                if let problem {
                    Section {
                        InlineNotice(problem, tone: .error, onDismiss: { self.problem = nil },
                                     identifiers: .init(text: "newWorkspaceProblem", dismiss: "newWorkspaceProblemDismiss"))
                    }
                    .listRowBackground(Color.clear)
                }
                #endif
                Section {
                    TextField("Name", text: $name)
                        .agentLandFont(.body)
                        .workspaceNoAutocapitalization()
                        .autocorrectionDisabled()
                        .focused($nameFocused)
                        .onAppear {
                            // The Form builds its rows lazily, after the sheet appears: focus the field once it
                            // exists, and only the first time (not on returning from the location chooser).
                            guard !askedNameFocus else { return }
                            askedNameFocus = true
                            DispatchQueue.main.async { nameFocused = true }
                        }
                        .submitLabel(.done)
                        .onSubmit(create)
                        .accessibilityIdentifier("newWorkspaceName")
                } header: {
                    Text("Name")
                } footer: {
                    if let nameProblem {
                        Text(nameProblem).newWorkspaceFooter(problem: true)
                            .accessibilityIdentifier("newWorkspaceNameProblem")
                    } else {
                        Text("Also the new folder’s name.").newWorkspaceFooter()
                    }
                }
                .listRowFill(.surface)
                Section {
                    // A navigation row with the system's disclosure indicator; the chooser pops itself once a folder
                    // is chosen (WS-4).
                    NavigationLink {
                        LocationChooser(start: location?.path) { listing in
                            location = listing
                            locationIssue = nil
                        }
                    } label: {
                        Label {
                            Text(location?.displayPath ?? (locationIssue == nil ? "Loading…" : "Choose a Folder"))
                                .agentLandFont(.body)
                                .foregroundStyle(AgentLandColor.text)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } icon: {
                            Image(systemName: "folder").accessibilityHidden(true)
                        }
                    }
                    .accessibilityLabel("Location")
                    .accessibilityValue(location?.displayPath ?? "Not chosen")
                    .accessibilityHint("Choose the folder the new one is made in.")
                    .accessibilityIdentifier("newWorkspaceLocation")
                } header: {
                    Text("Location")
                } footer: {
                    if let locationIssue {
                        Text(locationIssue).newWorkspaceFooter(problem: true)
                    } else if let location, let folder = WorkspaceNaming.folderName(name) {
                        Text("Makes \(location.displayPath == "~" ? "~" : location.displayPath)/\(folder) on \(model.hostName).")
                            .newWorkspaceFooter()
                    }
                }
                .listRowFill(.surface)
                Section {
                    Toggle("Git repository", isOn: $git)
                        .agentLandFont(.body)
                        .foregroundStyle(AgentLandColor.text)
                        .accessibilityIdentifier("newWorkspaceGit")
                } footer: {
                    Text(git ? "Starts a Git repository on the main branch in the new folder." : "The new folder starts empty.")
                        .newWorkspaceFooter()
                }
                .listRowFill(.surface)
            }
            .formStyle(.grouped)
            .listPageBackground()
            #if os(iOS)
            // A make the host refused is the system's alert (WS-5); the Mac shows it in the form.
            .alert("Couldn’t Make Workspace", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(problem ?? "")
            }
            #endif
            .navigationTitle("New Workspace")
            .workspaceInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.accessibilityIdentifier("newWorkspaceCancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    if manager.adding {
                        ProgressView().controlSize(.small).accessibilityLabel("Creating")
                    } else {
                        Button("Create", action: create)
                            .disabled(!canCreate)
                            .accessibilityIdentifier("newWorkspaceCreate")
                    }
                }
            }
        }
        .task { await loadDefaultLocation() }
    }

    /// Developer in the home folder when there is one, else the home folder.
    private func loadDefaultLocation() async {
        if location == nil, let initialLocation {
            location = initialLocation
            return
        }
        guard location == nil, let client = model.client else {
            if model.client == nil { locationIssue = "\(model.hostName) isn’t connected." }
            return
        }
        let hostID = model.hostID
        do {
            let home = try await client.folders()
            guard model.hostID == hostID, location == nil else { return }
            manager.learnHome(from: home)
            let preferred = WorkspaceManager.defaultFolder(in: home)
            if preferred == home.path {
                location = home
            } else {
                let developer = try await client.folders(path: preferred)
                guard model.hostID == hostID, location == nil else { return }
                location = developer
            }
        } catch {
            guard model.hostID == hostID, !(error is CancellationError) else { return }
            locationIssue = "Couldn’t read the folders on \(model.hostName): \(error.localizedDescription)"
        }
    }

    private func create() {
        guard canCreate, let location else { return }
        problem = nil
        let parent = location.path
        let requested = name
        let wantsGit = git
        Task {
            switch await manager.create(parentDirectory: parent, name: requested, git: wantsGit) {
            case let .open(id): created(id)
            case let .problem(message): problem = message
            case .unconfirmed, .dropped: dismiss()
            }
        }
    }
}

private extension View {
    /// A form footer's text: the system's own footer style on iPhone and iPad (WS-9), a problem in red; AgentLand's
    /// metadata style on the Mac.
    @ViewBuilder func newWorkspaceFooter(problem: Bool = false) -> some View {
        #if os(iOS)
        if problem { foregroundStyle(AgentLandColor.danger) } else { self }
        #else
        agentLandFont(.metadata).foregroundStyle(problem ? AgentLandColor.danger : AgentLandColor.textSecondary)
        #endif
    }
}

/// New Workspace's location chooser, pushed from its Location row: the folder browser, which goes back once a folder is
/// chosen.
private struct LocationChooser: View {
    @Environment(\.dismiss) private var dismiss
    let start: String?
    let chosen: (FolderListing) -> Void

    var body: some View {
        FolderBrowserView(mode: .choose, start: start, cancel: nil, choose: { listing in
            chosen(listing)
            dismiss()
        })
    }
}
