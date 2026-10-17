import SwiftUI
import AgentLandCore
import AgentLandDesign
#if os(iOS)
import UIKit
#endif

/// The Files tab's questions that are not about one row: rename, new file and new folder names, a taken name (Keep
/// Both) and the Move sheet, all system alerts and sheets. Move to Trash and a permanent delete are each row's
/// (`FileDeleteDialogs`), an upload's taken name its upload's row's (`FileUploadConflictDialog`).
struct FilesDialogs: ViewModifier {
    @Bindable var session: FilesSession
    let hostName: String

    func body(content: Content) -> some View {
        content
            .alert("Rename", isPresented: renameShown, presenting: session.renaming) { entry in
                TextField("Name", text: $session.renameText)
                    .workspaceNoAutocapitalization()
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("fileRenameField")
                Button("Rename") { let name = session.renameText; Task { await session.rename(entry, to: name) } }
                    .accessibilityIdentifier("fileRenameConfirm")
                Button("Cancel", role: .cancel) { session.cancelRename() }
            } message: { entry in
                Text("Enter a new name for “\(entry.name)”.")
            }
            // A new file's name, the native way (FI-6): Create opens its editor, which makes the file on its first save.
            .alert("New File", isPresented: $session.showNewFile) {
                TextField("File name", text: $session.newFileName)
                    .workspaceNoAutocapitalization()
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("fileNewFileField")
                Button("Create") { session.openNewFile() }
                    .accessibilityIdentifier("fileNewFileConfirm")
                Button("Cancel", role: .cancel) { session.cancelNewFile() }
            } message: {
                Text(session.path.isEmpty ? "The file is made in the workspace folder when you save it."
                                          : "The file is made in “\(FilesSession.name(of: session.path))” when you save it.")
            }
            .alert("New Folder", isPresented: $session.creatingFolder) {
                TextField("Name", text: $session.newFolderName)
                    .workspaceNoAutocapitalization()
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("fileNewFolderField")
                Button("Create") { let name = session.newFolderName; Task { await session.makeFolder(named: name) } }
                    .accessibilityIdentifier("fileNewFolderConfirm")
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(session.path.isEmpty ? "The folder is made in the workspace folder." : "The folder is made in “\(FilesSession.name(of: session.path))”.")
            }
            .alert(conflictTitle, isPresented: conflictShown, presenting: session.nameConflict) { conflict in
                if conflict.suggestedName != nil {
                    Button("Keep Both") { Task { await session.keepBoth(conflict) } }
                        .accessibilityIdentifier("fileKeepBoth")
                }
                Button("Cancel", role: .cancel) { session.nameConflict = nil }
            } message: { conflict in
                if let suggested = conflict.suggestedName {
                    Text("An item named “\(conflict.name)” is already there. Keep Both names this one “\(suggested)”.")
                } else {
                    Text("An item named “\(conflict.name)” is already there. Choose another name.")
                }
            }
            .sheet(item: $session.moving) { entry in
                FileMoveSheet(session: session, entry: entry)
                    .agentLandSheetPage()
            }
    }

    private var renameShown: Binding<Bool> {
        Binding(get: { session.renaming != nil }, set: { if !$0 { session.renaming = nil } })
    }
    private var conflictTitle: String { "“\(session.nameConflict?.name ?? "")” Already Exists" }
    private var conflictShown: Binding<Bool> {
        Binding(get: { session.nameConflict != nil }, set: { if !$0 { session.nameConflict = nil } })
    }
}

/// Move to Trash and a permanent delete that names its path, on the item's row so each points at it (owner,
/// 2026-10-08; `DialogAnchor`). Only the row of the item asked about presents them.
struct FileDeleteDialogs: ViewModifier {
    @Environment(WorkspaceModel.self) private var workspace
    let entry: FileEntry
    @Bindable var session: FilesSession

    func body(content: Content) -> some View {
        content
            .confirmationDialog(trashTitle, isPresented: trashShown, titleVisibility: .visible, presenting: session.pendingTrash) { entry in
                Button("Move to Trash", role: .destructive) { Task { await session.confirmTrash(entry) } }
                    .accessibilityIdentifier("fileConfirmTrash")
                Button("Cancel", role: .cancel) { session.pendingTrash = nil }
            } message: { entry in
                Text("It goes to the Trash on \(workspace.hostName). Finder’s Put Back can’t return it there; drag it back instead.")
            }
            .confirmationDialog(deleteTitle, isPresented: deleteShown, titleVisibility: .visible, presenting: session.pendingPermanentDelete) { entry in
                Button("Delete Permanently", role: .destructive) { Task { await session.confirmPermanentDelete(entry) } }
                    .accessibilityIdentifier("fileConfirmDelete")
                Button("Cancel", role: .cancel) { session.pendingPermanentDelete = nil }
            } message: { entry in
                // The host needs the exact path to delete for good; the question names it.
                Text("“\(entry.path)” can’t go to the Trash on \(workspace.hostName), so it will be deleted immediately. This can’t be undone.")
            }
    }

    private var trashTitle: String { "Move “\(session.pendingTrash?.name ?? "")” to the Trash?" }
    private var trashShown: Binding<Bool> {
        Binding(get: { session.pendingTrash?.path == entry.path },
                set: { if !$0, session.pendingTrash?.path == entry.path { session.pendingTrash = nil } })
    }
    private var deleteTitle: String { "Delete “\(session.pendingPermanentDelete?.name ?? "")” permanently?" }
    private var deleteShown: Binding<Bool> {
        Binding(get: { session.pendingPermanentDelete?.path == entry.path },
                set: { if !$0, session.pendingPermanentDelete?.path == entry.path { session.pendingPermanentDelete = nil } })
    }
}

// MARK: Move

/// Chooses a folder of the workspace for Move…: folders open in place, Move Here moves the item.
struct FileMoveSheet: View {
    @Environment(WorkspaceModel.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    let session: FilesSession
    let entry: FileEntry
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            FileFolderPicker(session: session, entry: entry, folder: "", title: projectName, done: dismiss.callAsFunction)
                .navigationDestination(for: String.self) { folder in
                    FileFolderPicker(session: session, entry: entry, folder: folder, title: FilesSession.name(of: folder),
                                     done: dismiss.callAsFunction)
                }
        }
        .onAppear { path = initialPath }
    }

    private var projectName: String {
        workspace.projects.first { $0.id == session.projectID }?.name ?? "Workspace"
    }

    /// Starts in the folder the item is in, with its parents behind the back button.
    private var initialPath: [String] {
        let components = FilesSession.parent(of: entry.path).split(separator: "/").map(String.init)
        var paths: [String] = []
        var current = ""
        for component in components {
            current = FilesSession.join(current, component)
            paths.append(current)
        }
        return paths
    }
}

/// One folder in the Move sheet: its subfolders, and Move Here.
private struct FileFolderPicker: View {
    @Environment(WorkspaceModel.self) private var workspace
    let session: FilesSession
    let entry: FileEntry
    let folder: String
    let title: String
    let done: () -> Void
    @State private var folders: [FileEntry] = []
    @State private var loading = true
    @State private var issue: String?

    var body: some View {
        List {
            ForEach(folders) { child in
                // A folder the item can't go into (itself, or one inside it) is dimmed by `.disabled` alone (FI-13).
                NavigationLink(value: child.path) {
                    Label(child.name, systemImage: "folder")
                        .frame(minHeight: 44, alignment: .leading)
                }
                .disabled(entry.isDirectory && (child.path == entry.path || child.path.hasPrefix(entry.path + "/")))
                .macListRowBackground(.canvas)
                .accessibilityIdentifier("moveFolder-\(child.path)")
            }
        }
        .listStyle(.plain)
        .listPageBackground()
        .overlay {
            if let issue {
                ContentUnavailable("Couldn’t Read Folder", systemImage: "exclamationmark.triangle", description: issue)
            } else if loading && folders.isEmpty {
                ProgressView()
            } else if folders.isEmpty {
                ContentUnavailable("No Folders", systemImage: "folder", description: "There are no folders inside this one.")
            }
        }
        .navigationTitle(title)
        // What moves, under the title (FI-13).
        .navigationSubtitle("Moving “\(entry.name)”")
        .workspaceInlineNavigationTitle()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { session.moving = nil; done() }
                    .accessibilityIdentifier("moveCancel")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Move Here") {
                    let target = folder
                    done()
                    Task { await session.move(entry, toFolder: target) }
                }
                .disabled(!session.canMove(entry, to: folder))
                .accessibilityIdentifier("moveHere")
            }
        }
        .task { await load() }
    }

    private func load() async {
        guard let client = workspace.client else {
            loading = false
            issue = "The host is unavailable."
            return
        }
        let hostID = workspace.hostID
        do {
            let listed = try await client.files(projectID: session.projectID, path: folder)
            guard !Task.isCancelled, workspace.hostID == hostID else { return }
            folders = listed.filter { $0.isDirectory && (session.showHidden || !$0.name.hasPrefix(".")) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        } catch {
            guard !Task.isCancelled, workspace.hostID == hostID else { return }
            issue = error.localizedDescription
        }
        loading = false
    }
}

// MARK: Share

/// A file on this device to share: a copy of a text file's contents under its own name.
struct FileShareItem: Identifiable {
    let url: URL
    var id: URL { url }
}

#if os(iOS)
/// The system share sheet for a file. Its copy goes once the sheet closes.
struct FileShareSheet: UIViewControllerRepresentable {
    let item: FileShareItem

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [item.url], applicationActivities: nil)
        let folder = item.url.deletingLastPathComponent()
        controller.completionWithItemsHandler = { _, _, _, _ in try? FileManager.default.removeItem(at: folder) }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#else
/// Sharing a file on the Mac: its name and the system's Share menu. Its copy goes once the sheet closes.
struct FileShareSheet: View {
    @Environment(\.dismiss) private var dismiss
    let item: FileShareItem

    var body: some View {
        VStack(alignment: .leading, spacing: AgentLandSpacing.medium) {
            Label(item.url.lastPathComponent, systemImage: "doc.text")
                .agentLandFont(.bodyEmphasized)
                .foregroundStyle(AgentLandColor.text)
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                ShareLink(item: item.url) { Label("Share…", systemImage: "square.and.arrow.up") }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(AgentLandSpacing.large)
        .frame(minWidth: 360)
        .onDisappear { try? FileManager.default.removeItem(at: item.url.deletingLastPathComponent()) }
    }
}
#endif

// MARK: Uploads

/// The uploads under way from this tab, in a bar under the list (FI-7): a band the width of the page with Clear
/// beside its heading, each upload a native progress view while it goes, and the choices a taken name, a failure or an
/// unconfirmed upload needs as borderless buttons.
struct FileUploadsPanel: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let uploads: FileUploadQueue
    let canReplace: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Uploads")
                    .font(AgentLandTypeRole.metadata.font.weight(.semibold))
                    .foregroundStyle(AgentLandColor.textSecondary)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if uploads.items.contains(where: { !$0.isActive }) {
                    // The hit pad inside the label, so the button is one element (as Save, 0ca9400).
                    Button { uploads.clearFinished() } label: { Text("Clear").minimumTapTarget() }
                        .buttonStyle(.borderless)
                        .agentLandFont(.metadata)
                        .accessibilityLabel("Clear finished uploads")
                        .accessibilityIdentifier("uploadsClear")
                }
            }
            .padding(.horizontal, AgentLandSpacing.medium)
            .padding(.top, AgentLandSpacing.xxSmall)
            // As tall as its rows; more than a few scroll.
            if uploads.items.count > (typeSize.isAccessibilitySize ? 2 : 3) {
                ScrollView { rows }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(maxHeight: typeSize.isAccessibilitySize ? 320 : 200)
            } else {
                rows
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AgentLandColor.surfaceRaised)
        .workspaceHairline(.top)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("uploadsPanel")
    }

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(uploads.items) { upload in
                FileUploadRow(upload: upload, uploads: uploads, canReplace: canReplace)
            }
        }
        .padding(.bottom, AgentLandSpacing.xxSmall)
    }
}

/// One upload: its symbol, its name and where it stands in words (with the system's progress bar while it goes), and
/// what can be done.
private struct FileUploadRow: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let upload: FileUpload
    let uploads: FileUploadQueue
    let canReplace: Bool

    var body: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: AgentLandSpacing.xxSmall))
                                                  : AnyLayout(HStackLayout(spacing: AgentLandSpacing.xSmall))
        layout {
            Label {
                if case let .sending(fraction) = upload.state {
                    ProgressView(value: fraction) { name } currentValueLabel: { statusText }
                } else {
                    VStack(alignment: .leading, spacing: AgentLandSpacing.xxxSmall) {
                        name
                        statusText
                    }
                }
            } icon: {
                Image(systemName: symbol)
                    .foregroundStyle(symbolColor)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(upload.name), \(status)")
            .accessibilityIdentifier("upload-\(upload.name)")
            buttons
        }
        .padding(.horizontal, AgentLandSpacing.medium)
        .padding(.vertical, AgentLandSpacing.xxSmall)
        .frame(minHeight: 44)
        // A taken name's question points at this upload (owner, 2026-10-08).
        .modifier(FileUploadConflictDialog(upload: upload, uploads: uploads, canReplace: canReplace))
    }

    private var name: some View {
        Text(upload.name)
            .agentLandFont(.secondary)
            .foregroundStyle(AgentLandColor.text)
            .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
            .truncationMode(.middle)
    }

    private var statusText: some View {
        Text(status)
            .agentLandFont(.caption)
            .foregroundStyle(AgentLandColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var buttons: some View {
        HStack(spacing: 0) {
            switch upload.state {
            case .preparing, .waiting, .sending:
                iconButton("xmark.circle", label: "Cancel Upload of \(upload.name)", id: "uploadCancel") { uploads.cancel(upload.id) }
            case .nameTaken:
                Button("Choose…") { uploads.conflict = upload }
                    .buttonStyle(.borderless)
                    .agentLandFont(.secondary)
                    .minimumTapTarget(.reserveSpace)
                    .accessibilityIdentifier("uploadChoose")
            case .failed, .notConfirmed:
                iconButton("arrow.clockwise", label: "Upload \(upload.name) Again", id: "uploadAgain") { uploads.uploadAgain(upload.id) }
                iconButton("xmark", label: "Remove \(upload.name)", id: "uploadRemove") { uploads.remove(upload.id) }
            case .done, .canceled:
                iconButton("xmark", label: "Remove \(upload.name)", id: "uploadRemove") { uploads.remove(upload.id) }
            }
        }
    }

    private func iconButton(_ name: String, label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(label, systemImage: name, action: action)
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .font(AgentLandTypeRole.body.font)
            .minimumTapTarget(.reserveSpace)
            .accessibilityIdentifier(id)
    }

    private var status: String {
        switch upload.state {
        case .preparing: "Preparing…"
        case .waiting: "Waiting"
        case let .sending(fraction): "Uploading, \(Int((fraction * 100).rounded())) percent"
        case .done: "Uploaded"
        case let .nameTaken(suggested):
            suggested == nil ? "An item with this name is already there." : "An item with this name is already there. Choose Replace or Keep Both."
        case let .failed(reason): "Not uploaded. \(reason)"
        case .notConfirmed: "Not confirmed: the connection ended. The folder was read again; check it before uploading again."
        case .canceled: "Canceled"
        }
    }

    private var symbol: String {
        switch upload.state {
        case .done: "checkmark.circle.fill"
        case .nameTaken, .notConfirmed: "exclamationmark.triangle.fill"
        case .failed: "xmark.octagon.fill"
        case .canceled: "minus.circle"
        default: "arrow.up.circle"
        }
    }

    private var symbolColor: AgentLandColor {
        switch upload.state {
        case .done: .success
        case .nameTaken, .notConfirmed: .warning
        case .failed: .danger
        case .canceled: .textSecondary
        default: .tint
        }
    }
}

/// An upload's taken name (Replace or Keep Both), on its row in the uploads bar so it points at it (owner, 2026-10-08;
/// `DialogAnchor`). The bar lists every upload while there are any, so the row of the upload asked about is there.
private struct FileUploadConflictDialog: ViewModifier {
    @Environment(WorkspaceModel.self) private var workspace
    let upload: FileUpload
    let uploads: FileUploadQueue
    let canReplace: Bool

    func body(content: Content) -> some View {
        content
            .confirmationDialog("Replace “\(upload.name)”?", isPresented: shown, titleVisibility: .visible,
                                presenting: uploads.conflict) { upload in
                if canReplace {
                    Button("Replace", role: .destructive) { Task { await uploads.replace(upload.id) } }
                        .accessibilityIdentifier("uploadReplace")
                }
                if case .nameTaken(let suggested?) = upload.state {
                    Button("Keep Both (“\(suggested)”)") { uploads.keepBoth(upload.id) }
                        .accessibilityIdentifier("uploadKeepBoth")
                }
                Button("Skip", role: .cancel) { uploads.skip(upload.id) }
                    .accessibilityIdentifier("uploadSkip")
            } message: { upload in
                Text(canReplace
                     ? "“\(upload.name)” is already in this folder. Replace moves the one there to the Trash on \(workspace.hostName) first."
                     : "“\(upload.name)” is already in this folder.")
            }
    }

    private var shown: Binding<Bool> {
        Binding(get: { uploads.conflict?.id == upload.id }, set: { shown in
            // Dismissed without a choice (tapping outside a popover): the upload waits in the list.
            if !shown, uploads.conflict?.id == upload.id { uploads.conflict = nil }
        })
    }
}
