import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import AgentLandCore
import AgentLandDesign
#if os(iOS)
import UIKit
#endif

/// A Files tab: the folder's path and sort, and its items: a list on iPhone (and in compact width), a
/// table with name, size and (when the host names it) date modified on iPad. In the iPhone drawer the page's
/// navigation bar names the folder and its title menu lists the folders above it (FI-1). Rows open on tap and carry
/// Rename, Move…, Copy Path, Share and Move to Trash in their context menu, swipe actions (iPhone) and
/// VoiceOver actions. The search finds names under the folder, or lines of text files on hosts that
/// search contents; a line opens the editor at it. New Folder and uploads from Files and Photos come
/// from the title menu. Every change goes through the tab's `FilesSession`, which re-reads the folder.
///
/// This view makes the title menu, and its body reads nothing that the listing, its notices, uploads
/// or search change. SwiftUI makes a menu again whenever the view that builds it updates, also while
/// the menu is open, and a tap on an item at that moment does nothing: the Trash's confirmation going
/// away by itself did that to Upload Test File in `testFileOperations`. `FilesSurface` shows the rest.
struct FilesTabView: View {
    /// Where the Files surface shows: as the tab in front, under the shell's title and title menu, or as the iPhone
    /// drawer's Files section, whose navigation bar holds the same menu.
    enum Placement { case surface, drawer }

    @Environment(WorkspaceModel.self) private var workspace
    let tab: WorkspaceTab
    var placement: Placement = .surface
    @State private var showsFileImporter = false
    @State private var showsPhotoPicker = false
    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var sharing: FileShareItem?

    private var session: FilesSession { workspace.filesSession(for: tab) }

    var body: some View {
        let session = self.session
        FilesSurface(tab: tab, session: session, placement: placement, shareFile: { entry in Task { await share(entry, session: session) } })
            .fileImporter(isPresented: $showsFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                switch result {
                case let .success(urls): session.uploads.addFiles(urls)
                case let .failure(error): session.notice = FilesNotice("Couldn’t open the files", message: error.localizedDescription, tone: .error)
                }
            }
            .photosPicker(isPresented: $showsPhotoPicker, selection: $photoSelection, matching: .images, photoLibrary: .shared())
            .onChange(of: photoSelection) { _, items in
                guard !items.isEmpty else { return }
                photoSelection = []
                Task { await addPhotos(items, to: session) }
            }
            .sheet(item: $sharing) { item in
                FileShareSheet(item: item)
            }
            .onChange(of: workspace.locked) { _, locked in
                // Nothing stays over the lock; the surface closes the tab's own questions.
                guard locked else { return }
                showsFileImporter = false
                showsPhotoPicker = false
                sharing = nil
            }
            .modifier(FilesTitleMenu(placement: placement, title: tab.title) { titleMenu(session) })
            .modifier(FilesDrawerTitle(placement: placement, session: session))
    }

    // MARK: Title menu

    /// The listing's actions: new files and folders, uploads, hidden files, the sort order and Refresh.
    @ViewBuilder private func titleMenu(_ session: FilesSession) -> some View {
        Button("New File", systemImage: "doc.badge.plus") { session.beginNewFile() }
            .accessibilityIdentifier("fileNewFile")
        if session.supports(.mkdir) {
            Button("New Folder", systemImage: "folder.badge.plus") { session.beginNewFolder() }
                .accessibilityIdentifier("fileNewFolder")
        }
        if session.supports(.upload) {
            Section {
                Button("Upload from Files", systemImage: "doc.badge.arrow.up") { showsFileImporter = true }
                    .accessibilityIdentifier("fileUploadFiles")
                Button("Upload from Photos", systemImage: "photo.badge.arrow.down") { showsPhotoPicker = true }
                    .accessibilityIdentifier("fileUploadPhotos")
                if workspaceUITestHooks {
                    Button("Upload Test File", systemImage: "arrow.up.doc") { uploadTestFile(session) }
                        .accessibilityIdentifier("debugUploadTestFile")
                }
            }
        }
        // The menu's own controls (FI-15): a toggle for hidden files, the sort order as a picker with its direction.
        Section {
            Toggle("Show Hidden Files", systemImage: "eye", isOn: Bindable(session).showHidden)
            FileSortChoices(session: session, submenu: true)
        }
        Section {
            Button("Refresh", systemImage: "arrow.clockwise") { Task { await session.refreshVisibleTree() } }
        }
    }

    // MARK: Uploads and sharing

    /// Loads picked photos with their file names where Photos gives one; each is re-encoded before it
    /// goes up, so its location never leaves the device.
    private func addPhotos(_ items: [PhotosPickerItem], to session: FilesSession) async {
        for item in items {
            do {
                guard let picked = try await item.loadTransferable(type: PickedPhoto.self) else { continue }
                let type = UTType(filenameExtension: picked.url.pathExtension) ?? item.supportedContentTypes.first
                // The queue owns the picked copy from here and removes it once re-encoded.
                session.uploads.addPhoto(at: picked.url, type: type)
            } catch {
                session.notice = FilesNotice("A photo couldn’t be read", message: error.localizedDescription, tone: .error)
            }
        }
    }

    /// UI tests upload through the same queue as a picked file, without the system picker.
    private func uploadTestFile(_ session: FilesSession) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "AgentLandUITestUpload-\(UUID().uuidString)")
        let file = folder.appending(path: "upload-proof.txt")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("Uploaded by the AgentLand file operations test.\n".utf8).write(to: file)
            session.uploads.addFiles([file])
        } catch {
            session.notice = FilesNotice("The test file wasn’t made", message: error.localizedDescription, tone: .error)
        }
    }

    /// Shares a text file (the host serves UTF-8 text up to 1 MB): its contents are read and handed to
    /// the share sheet as a file with its own name.
    private func share(_ entry: FileEntry, session: FilesSession) async {
        guard let client = workspace.client, workspace.reachable else {
            session.notice = FilesNotice("You’re offline, so nothing can be shared.", tone: .warning)
            return
        }
        let hostID = workspace.hostID
        do {
            let document = try await client.file(projectID: session.projectID, path: entry.path)
            guard workspace.isCurrent(hostID: hostID, tabID: tab.id) else { return }
            let folder = FileManager.default.temporaryDirectory.appending(path: "AgentLandShare-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appending(path: entry.name)
            try Data(document.content.utf8).write(to: file, options: .completeFileProtection)
            sharing = FileShareItem(url: file)
        } catch {
            guard workspace.isCurrent(hostID: hostID, tabID: tab.id) else { return }
            session.notice = FilesNotice("“\(entry.name)” can’t be shared from here",
                                         message: "Only text files up to 1 MB can be shared from this device. \(error.localizedDescription)",
                                         tone: .warning)
        }
    }
}

/// The Files title menu's place: the shell's title for the tab in front, the navigation bar's trailing menu on the
/// drawer's page. Either way it keeps the `fileActions` identifier.
private struct FilesTitleMenu<Items: View>: ViewModifier {
    let placement: FilesTabView.Placement
    let title: String
    @ViewBuilder let items: () -> Items

    func body(content: Content) -> some View {
        switch placement {
        case .surface:
            content.surfaceTitle(title, systemImage: "folder", identifier: "fileActions", menu: items)
        case .drawer:
            content.toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu(content: items) { Label("Files Actions", systemImage: "ellipsis") }
                        .menuOrder(.fixed)
                        .accessibilityIdentifier("fileActions")
                }
            }
        }
    }
}

/// On the iPhone drawer's page, its navigation bar's title: the folder shown (the workspace's name at its top), with
/// the folders above it in the title menu (FI-1). A view of its own, so that only a new folder makes it again.
private struct FilesDrawerTitle: ViewModifier {
    @Environment(WorkspaceModel.self) private var workspace
    let placement: FilesTabView.Placement
    let session: FilesSession

    func body(content: Content) -> some View {
        if placement == .drawer {
            if session.path.isEmpty {
                content.navigationTitle(projectName)
            } else {
                content
                    .navigationTitle(FilesSession.name(of: session.path))
                    .toolbarTitleMenu {
                        // The nearest folder first, the workspace's own folder last, as a path menu lists them.
                        ForEach(session.breadcrumbs.dropLast().reversed()) { crumb in
                            Button(crumb.name, systemImage: "folder") { session.navigate(to: crumb.path) }
                                .accessibilityIdentifier("fileBreadcrumb-\(crumb.path)")
                        }
                        Button(projectName, systemImage: "folder") { session.navigate(to: "") }
                            .accessibilityIdentifier("fileBreadcrumbRoot")
                    }
            }
        } else {
            content
        }
    }

    private var projectName: String {
        workspace.projects.first(where: { $0.id == session.projectID })?.name ?? "Files"
    }
}

/// The Files tab under its title: the folder bar (not on the drawer's page), the listing or the search's results, the
/// notices and uploads over them, the tab's questions, and the tasks that list the folder and run the search. The
/// notice, the uploads, the haptics and the sort menu are views of their own, so that a confirmation
/// going away by itself or an upload's progress does not update the list and make its menus again.
private struct FilesSurface: View {
    @Environment(WorkspaceModel.self) private var workspace
    @Environment(\.dynamicTypeSize) private var typeSize
    @WorkspaceHorizontalSizeClass private var sizeClass
    let tab: WorkspaceTab
    let session: FilesSession
    let placement: FilesTabView.Placement
    let shareFile: (FileEntry) -> Void
    @Environment(\.filesInspectFile) private var inspectFile
    @State private var handledFindRequest: Int?

    var body: some View {
        let search = session.search
        VStack(spacing: 0) {
            // The drawer's page has none: its navigation bar names the folder and its menus hold the rest (FI-1).
            if placement == .surface { filesToolbar(session) }
            // The folder couldn't be read again while its rows still show: a line in place above them (FI-8). With no
            // rows, the content says it instead.
            if let issue = session.issue, !session.entries.isEmpty, !session.search.isActive {
                FilesIssueLine(issue: issue) { Task { await session.refreshVisibleTree() } }
            }
            content(session)
        }
        // Its page: the canvas on a full screen, the drawer panel's own platter in the drawer (2026-10-07).
        .groupedPageBackground()
        .background { FilesFeedback(session: session) }
        .overlay(alignment: .top) { FilesNoticeOverlay(session: session) }
        .safeAreaBar(edge: .bottom, spacing: 0) { FileUploadsInset(session: session) }
        .searchable(text: Bindable(search).text, isPresented: Bindable(search).isPresented, placement: searchPlacement,
                    prompt: search.effectiveScope == .contents ? "Search file contents" : "Search file names")
        .modifier(FileSearchScopes(search: search))
        .task(id: search.key) {
            // Wait for typing to pause before walking folders or asking the host.
            guard search.isActive else { search.clear(); return }
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            await search.run()
        }
        .task(id: session.loadIdentity) { await session.loadIfNeeded() }
        .refreshable { await session.refreshVisibleTree() }
        .onChange(of: workspace.connectionEpoch) { _, _ in
            // Reload a listing that failed while the host was unreachable.
            if session.issue != nil { Task { await session.refreshVisibleTree() } }
        }
        .onChange(of: workspace.presentationTicket, initial: true) { _, _ in
            session.reportPresentationIfReady()
        }
        .onChange(of: workspace.findRequest, initial: true) { _, request in
            // Find (⌘F) brings up the search. A request made before this view existed is not its.
            defer { handledFindRequest = request }
            guard let handled = handledFindRequest, handled != request, workspace.selectedTabID == tab.id else { return }
            search.isPresented = true
        }
        .onChange(of: workspace.locked) { _, locked in
            // Nothing stays over the lock: the tab's questions and sheets close; typed names are dropped.
            if locked { dismissPresentations(session) }
        }
        .modifier(FilesDialogs(session: session, hostName: workspace.hostName))
    }

    // MARK: Content

    @ViewBuilder private func content(_ session: FilesSession) -> some View {
        if session.search.isActive {
            FilesSearchResults(session: session, actions: rowActions(session))
        } else if session.loading && session.entries.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let issue = session.issue, session.entries.isEmpty {
            ContentUnavailable("Couldn’t Read Folder", systemImage: "exclamationmark.triangle", description: issue,
                               descriptionIdentifier: "filesIssue") {
                Button("Try Again") { Task { await session.refreshVisibleTree() } }
                    .buttonStyle(.agentLandPrimary)
                    .accessibilityIdentifier("filesRetry")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if session.entries.isEmpty {
            ContentUnavailable("No Files", systemImage: "folder", description: "This folder is empty.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if sizeClass == .regular {
            FilesTable(session: session, actions: rowActions(session))
        } else {
            FilesList(session: session, actions: rowActions(session))
        }
    }

    /// What a row can do, for its menus, swipes and VoiceOver actions.
    private func rowActions(_ session: FilesSession) -> FileRowActions {
        FileRowActions(
            canRename: session.supports(.move),
            canMove: session.supports(.move),
            canDelete: session.canDelete,
            trashes: session.supports(.trash),
            open: { entry in
                if !entry.isDirectory, let inspectFile { inspectFile(entry) } else { session.open(entry) }
            },
            rename: { session.beginRename($0) },
            move: { session.beginMove($0) },
            copyPath: { WorkspacePlatform.copy($0.path) },
            share: shareFile,
            delete: { session.requestDelete($0) })
    }

    private func dismissPresentations(_ session: FilesSession) {
        session.cancelNewFile()
        session.pendingTrash = nil
        session.pendingPermanentDelete = nil
        session.nameConflict = nil
        session.cancelRename()
        session.creatingFolder = false
        session.moving = nil
        session.uploads.conflict = nil
        session.search.isPresented = false
    }

    // MARK: Toolbar

    /// The folder path and the list's actions. At accessibility text sizes the path gets its own row
    /// and the actions go on the row under it, so neither crowds the other out.
    private func filesToolbar(_ session: FilesSession) -> some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 0) {
                    breadcrumb(session)
                    HStack(spacing: AgentLandSpacing.xxSmall) {
                        Spacer(minLength: 0)
                        filesActions(session)
                    }
                }
            } else {
                HStack(spacing: AgentLandSpacing.xxSmall) {
                    breadcrumb(session)
                    filesActions(session)
                }
            }
        }
        .padding(.leading, AgentLandSpacing.xSmall)
        .padding(.trailing, AgentLandSpacing.xxSmall)
        .frame(minHeight: 48)
        .background(AgentLandColor.surface)
        .workspaceHairline()
    }

    @ViewBuilder private func filesActions(_ session: FilesSession) -> some View {
        Button {
            Task { await session.refreshVisibleTree() }
        } label: {
            WorkspaceIconLabel(systemImage: "arrow.clockwise")
        }
        .buttonStyle(.plain)
        .workspaceHover(Circle())
        .accessibilityLabel("Refresh")

        FilesSortMenu(session: session)
    }

    private func breadcrumb(_ session: FilesSession) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Button { session.navigate(to: "") } label: {
                    Label(projectName, systemImage: "folder")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Project folder")
                .accessibilityIdentifier("fileBreadcrumbRoot")

                ForEach(session.breadcrumbs) { crumb in
                    Text("/")
                        .font(.subheadline.monospaced())
                        .foregroundStyle(AgentLandColor.glyphTertiary)
                        .accessibilityHidden(true)

                    Button { session.navigate(to: crumb.path) } label: {
                        Text(crumb.name)
                            .font(.subheadline)
                            .lineLimit(1)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("fileBreadcrumb-\(crumb.path)")
                }
            }
            .foregroundStyle(AgentLandColor.text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var projectName: String {
        workspace.projects.first(where: { $0.id == tab.projectID })?.name ?? "Project"
    }

    /// Where the system places it: on iPhone, the drawer's page too has it at the bottom, as iOS 26 draws search (owner,
    /// 2026-10-08; it takes a tap at the largest text size, run bottomax1). In the navigation bar a system overlay over
    /// the list's first rows took their taps (run trace1).
    private var searchPlacement: SearchFieldPlacement { .automatic }
}

/// The last change's result, the native way (`noticePresentation`): on iPhone and iPad a warning or an error in the
/// system's alert and a success only heard by VoiceOver (the list and the haptic show it); on the Mac over the top of
/// the list, a confirmation going away by itself after 5 s. A view of its own, so a notice does not make the list again.
private struct FilesNoticeOverlay: View {
    let session: FilesSession

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .noticePresentation(session.notice.map { NoticeContent(id: $0.id, $0.title, message: $0.message, tone: tone($0.tone)) },
                                identifiers: .init(text: "filesNotice", dismiss: "filesNoticeDismiss"),
                                dismiss: { session.notice = nil })
    }

    private func tone(_ tone: FilesNotice.Tone) -> InlineNotice.Tone {
        switch tone {
        case .success: .success
        case .warning: .warning
        case .error: .error
        }
    }
}

/// A read that failed while the content still shows, status in place over it: the reason in secondary text with the
/// warning symbol, and the button that reads it again. The folder's (FI-8: Try Again) and the editor's (FI-10: Reload).
private struct FilesIssueLine: View {
    let issue: String
    var actionTitle = "Try Again"
    var identifiers = (text: "filesIssue", action: "filesRetry")
    let retry: () -> Void

    var body: some View {
        HStack(spacing: AgentLandSpacing.small) {
            Label {
                Text(issue).foregroundStyle(AgentLandColor.textSecondary).accessibilityIdentifier(identifiers.text)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(AgentLandColor.warning)
            }
            .font(.footnote)
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: retry) { Text(actionTitle).minimumTapTarget() }
                .buttonStyle(.bordered)
                .accessibilityIdentifier(identifiers.action)
        }
        .padding(.horizontal, AgentLandSpacing.medium)
        .padding(.vertical, AgentLandSpacing.xxSmall)
    }
}

/// The haptics for a new sort order, a change the host confirmed and a notice that needs attention.
private struct FilesFeedback: View {
    let session: FilesSession

    private struct SortChoice: Equatable {
        let field: FileSortField
        let ascending: Bool
    }

    var body: some View {
        Color.clear
            .agentLandHaptic(.selection, trigger: SortChoice(field: session.sortField, ascending: session.sortAscending))
            .agentLandHaptic(.success, trigger: session.confirmedChanges)
            .agentLandHaptic(.warning, trigger: session.notice) { _, notice in notice.map { $0.tone != .success } ?? false }
    }
}

/// The uploads' bar under the list, while the tab has uploads.
private struct FileUploadsInset: View {
    let session: FilesSession

    var body: some View {
        if !session.uploads.isEmpty {
            FileUploadsPanel(uploads: session.uploads, canReplace: session.supports(.trash))
        }
    }
}

/// The folder bar's sort menu.
private struct FilesSortMenu: View {
    let session: FilesSession

    var body: some View {
        Menu {
            FileSortChoices(session: session, submenu: false)
        } label: {
            WorkspaceIconLabel(systemImage: session.sortAscending ? "arrow.up.arrow.down" : "arrow.down.arrow.up")
        }
        .accessibilityLabel("Sort files")
        .accessibilityIdentifier("fileSort")
    }
}

/// The sort order the native way (FI-15): the field as a picker (Name, Size and, when the host names it, Date
/// Modified) and the direction as a toggle. In the title menu the picker is a Sort By submenu that shows the field
/// chosen; in the folder bar's sort menu its choices stand inline. The haptic follows the order (`FilesFeedback`).
private struct FileSortChoices: View {
    let session: FilesSession
    let submenu: Bool

    var body: some View {
        if submenu {
            picker.pickerStyle(.menu)
        } else {
            picker.pickerStyle(.inline)
        }
        Toggle("Ascending", systemImage: "arrow.up", isOn: Binding(
            get: { session.sortAscending },
            set: { session.setSort(session.sortField, ascending: $0) }))
    }

    private var picker: some View {
        Picker(selection: Binding(get: { session.sortField }, set: { session.setSort($0, ascending: session.sortAscending) })) {
            choice(.name)
            choice(.size)
            if session.hasModifiedTimes { choice(.modified) }
        } label: {
            Label("Sort By", systemImage: "arrow.up.arrow.down")
        }
    }

    private func choice(_ field: FileSortField) -> some View {
        Label(field.title, systemImage: field.icon).tag(field)
    }
}

/// The Names and Contents scopes, on hosts that search file contents; without it the search covers
/// names only and shows no scopes. In regular width the search field sits in the toolbar, which shows
/// no scope bar; the results list carries the choice there (`FilesSearchResults`).
private struct FileSearchScopes: ViewModifier {
    @WorkspaceHorizontalSizeClass private var sizeClass
    @Bindable var search: FilesSearchModel

    func body(content: Content) -> some View {
        if search.offersContents && sizeClass != .regular {
            content.searchScopes($search.scope, activation: .onSearchPresentation) {
                ForEach(FileSearchScope.allCases, id: \.self) { scope in
                    Text(scope.title).tag(scope)
                }
            }
        } else {
            content
        }
    }
}

/// A photo from the picker as a file, so it keeps the name Photos gives it.
private struct PickedPhoto: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            let folder = FileManager.default.temporaryDirectory.appending(path: "AgentLandPhoto-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let copy = folder.appending(path: received.file.lastPathComponent)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedPhoto(url: copy)
        }
    }
}

/// An editor tab: the file's path and state, Save (and on the Mac Copy and Reload), and the text with line numbers.
struct EditorTabView: View {
    @Environment(WorkspaceModel.self) private var workspace
    @WorkspaceHorizontalSizeClass private var sizeClass
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.workspaceObscured) private var workspaceObscured
    @Environment(\.workspaceMenuObscured) private var menuObscured
    @Environment(\.agentLandAnnouncer) private var announcer
    let tab: WorkspaceTab
    /// The Find request this view saw first; later ones show the text view's find bar.
    @State private var firstFindRequest: Int?
    /// The conflict's two replacing choices wait for their confirmation here.
    @State private var confirmingUseHost = false
    @State private var confirmingSaveMine = false

    private var session: EditorSession { workspace.editorSession(for: tab) }

    /// `editorActive`, but the iPhone's drawer does not count: the tab's pill there carries its title menu (owner,
    /// 2026-10-08).
    private var editorMenuActive: Bool {
        workspace.selectedTabID == tab.id && !workspace.locked && !workspace.presentationPending && scenePhase == .active
            && !menuObscured
    }

    private var editorActive: Bool {
        workspace.selectedTabID == tab.id &&
            !workspace.locked &&
            !workspace.presentationPending &&
            scenePhase == .active &&
            !workspaceObscured
    }

    var body: some View {
        let session = self.session
        VStack(spacing: 0) {
            editorToolbar(session)

            if session.conflicted {
                conflictCard(session)
                    .padding(.horizontal, AgentLandSpacing.small)
                    .padding(.vertical, AgentLandSpacing.xSmall)
            } else if let issue = session.issue {
                // Status in place over the text, as the folder's (FI-10).
                FilesIssueLine(issue: issue, actionTitle: "Reload", identifiers: (text: "editorIssue", action: "editorReload")) {
                    workspace.reloadTab(tab.id)
                }
            }

            if session.loading {
                // Named as the chat's loading state is: a hung host holds the read until its timeout, and the editor is
                // the task in front meanwhile (walk 26100706, run final-walks).
                ProgressView()
                    .accessibilityIdentifier("editorLoading")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                LineNumberEditor(text: Bindable(session).content,
                                 documentGeneration: session.documentGeneration,
                                 active: editorActive,
                                 colorScheme: colorScheme,
                                 increasedContrast: contrast == .increased,
                                 findRequest: editorActive && firstFindRequest != workspace.findRequest ? workspace.findRequest : nil,
                                 lineRequest: session.lineRequest,
                                 lineShown: { [weak session] id in session?.lineRequestShown(id) },
                                 caretMoved: { [weak session] line in session?.noteCaretLine(line) },
                                 takesInput: { [weak workspace, id = tab.id] in
                                     guard let workspace else { return false }
                                     return workspace.selectedTabID == id && !workspace.locked && !workspace.presentationPending
                                 })
            }
        }
        // The editor's own view paints the same canvas (FI-11).
        .background(AgentLandColor.canvas)
        .task(id: workspace.tabRefreshGeneration[tab.id]) { await session.loadIfNeeded() }
        .onChange(of: workspace.connectionEpoch) { _, _ in
            // Read a file that failed to load while the host was unreachable.
            if session.loadFailed { Task { await session.loadIfNeeded() } }
        }
        .onChange(of: workspace.presentationTicket, initial: true) { _, _ in
            session.reportPresentationIfReady()
        }
        .onChange(of: session.content) { _, newContent in session.scheduleDraftSave(newContent) }
        .onChange(of: workspace.selectedTabID) { _, selected in
            if selected != tab.id { session.flushDraft() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { session.flushDraft() }
        }
        .onChange(of: workspaceObscured) { _, obscured in
            if obscured { session.flushDraft() }
        }
        .onDisappear { session.flushDraft() }
        .onAppear { if firstFindRequest == nil { firstFindRequest = workspace.findRequest } }
        .agentLandHaptic(.success, trigger: session.savedCount)
        .agentLandHaptic(.warning, trigger: session.issue) { _, issue in issue != nil }
        .onChange(of: session.lineRequest?.id) { _, id in
            // A search result opened the file at a line: VoiceOver hears which.
            if id != nil, let line = session.lineRequest?.line { announcer.announce("Line \(line)") }
        }
        .surfaceTitle(tab.title, systemImage: "doc.text", identifier: "editorActions") { titleMenu(session) }
    }

    /// A save that conflicted, or a draft whose file changed on the Mac: the reason and the person's three
    /// choices as bordered buttons, the two that replace a side destructive (FI-10). Either side is replaced only by a
    /// choice confirmed in the system dialog; Copy keeps the draft. The choices stand in a row in regular width and
    /// one under another in compact width and at accessibility text sizes.
    @ViewBuilder private func conflictCard(_ session: EditorSession) -> some View {
        let layout = sizeClass == .regular && !typeSize.isAccessibilitySize
            ? AnyLayout(HStackLayout(spacing: AgentLandSpacing.xSmall))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: AgentLandSpacing.xxSmall))
        VStack(alignment: .leading, spacing: AgentLandSpacing.xSmall) {
            Label {
                VStack(alignment: .leading, spacing: AgentLandSpacing.xxxSmall) {
                    Text("The file changed on the Mac")
                        .font(.subheadline.weight(.semibold))
                    if let issue = session.issue {
                        Text(issue)
                            .font(.footnote)
                            .foregroundStyle(AgentLandColor.textSecondary)
                    }
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(AgentLandColor.warning)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("editorConflict")
            layout { conflictButtons(session) }
                .buttonStyle(.bordered)
        }
    }

    /// Each choice's hit area grows inside its label, so a tap on it is the button's and each stays one element.
    @ViewBuilder private func conflictButtons(_ session: EditorSession) -> some View {
        Button(role: .destructive) { confirmingUseHost = true } label: {
            Text("Use Mac's Version").minimumTapTarget()
        }
            .disabled(session.saving || session.loading)
            .accessibilityIdentifier("editorUseHost")
            // Each question points at the button that asked it (owner, 2026-10-08).
            .confirmationDialog("Use the Mac's version?", isPresented: $confirmingUseHost, titleVisibility: .visible) {
                Button("Use Mac's Version", role: .destructive) { Task { await session.useHostVersion() } }
                    .accessibilityIdentifier("editorConfirmUseHost")
            } message: {
                Text("Your edits to this file are thrown away and the Mac's version opens. Copy them first to keep them.")
            }
        Button(role: .destructive) { confirmingSaveMine = true } label: {
            Text("Save Mine Anyway").minimumTapTarget()
        }
            .disabled(session.saving || session.loading)
            .accessibilityIdentifier("editorSaveMine")
            .confirmationDialog("Save yours over the Mac's file?", isPresented: $confirmingSaveMine, titleVisibility: .visible) {
                Button("Save Mine Anyway", role: .destructive) { Task { await session.saveMineAnyway() } }
                    .accessibilityIdentifier("editorConfirmSaveMine")
            } message: {
                Text("Your version replaces the file on the Mac, and the changes made there are lost.")
            }
        Button { WorkspacePlatform.copy(session.content) } label: {
            Text("Copy My Edits").minimumTapTarget()
        }
            .accessibilityIdentifier("editorCopyDraft")
    }

    /// The file's actions: Save, Reload, Copy and Find.
    @ViewBuilder private func titleMenu(_ session: EditorSession) -> some View {
        Button("Save", systemImage: "square.and.arrow.down") { Task { await session.save() } }
            .disabled(!session.canSave)
        Button("Reload", systemImage: "arrow.clockwise") { workspace.reloadTab(tab.id) }
        Button("Copy File", systemImage: "doc.on.doc") { WorkspacePlatform.copy(session.content) }
        // From the tab's pill in the iPhone's drawer, Find (and its keyboard) waits for the drawer to go.
        Button("Find", systemImage: "magnifyingglass") { [workspace] in workspace.phoneNavigation.afterPanels { workspace.requestFind() } }
            .disabled(!editorMenuActive)
    }

    /// The file's name and the editor's actions. At accessibility text sizes the name gets its own row
    /// and the actions go on the row under it, so the name is not cut down to a few letters.
    private func editorToolbar(_ session: EditorSession) -> some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: AgentLandSpacing.xxSmall) { editorTitle(session) }
                        .frame(minHeight: 44)
                    HStack(spacing: AgentLandSpacing.xxSmall) {
                        Spacer(minLength: 0)
                        editorActions(session)
                    }
                }
            } else {
                HStack(spacing: AgentLandSpacing.xxSmall) {
                    editorTitle(session)
                    editorActions(session)
                }
            }
        }
        .foregroundStyle(AgentLandColor.text)
        .padding(.leading, AgentLandSpacing.small)
        .padding(.trailing, AgentLandSpacing.xxSmall)
        .frame(minHeight: 48)
        .background(AgentLandColor.surface)
        .workspaceHairline()
    }

    #if os(iOS)
    /// The path, and whether the file was edited and where the caret is, in secondary text (FI-9).
    @ViewBuilder private func editorTitle(_ session: EditorSession) -> some View {
        VStack(alignment: .leading, spacing: AgentLandSpacing.xxxSmall) {
            Text(tab.resourceID)
                .font(.footnote.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
            if session.edited || session.caretLine != nil {
                HStack(spacing: 0) {
                    if session.edited { Text("Edited") }
                    if session.edited && session.caretLine != nil { Text(" · ").accessibilityHidden(true) }
                    if let line = session.caretLine {
                        // Where the caret is, once the file opened at a line or the caret moved.
                        Text("Line \(line)")
                            .monospacedDigit()
                            .accessibilityIdentifier("editorLine")
                    }
                }
                .font(.footnote)
                .lineLimit(1)
            }
        }
        .foregroundStyle(AgentLandColor.textSecondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Save, a glass button dimmed only while there is nothing to save; Copy and Reload are the title menu's (FI-9).
    /// Its 44 pt frame is reserved, as the other glass buttons' are: a grown hit pad laid around the button (not its
    /// label) made a second "saveFile" element that XCUITest found first and could not tap (run 1791400998).
    @ViewBuilder private func editorActions(_ session: EditorSession) -> some View {
        Button { Task { await session.save() } } label: {
            Text("Save")
                .opacity(session.saving ? 0 : 1)
                .overlay { if session.saving { ProgressView() } }
        }
        .buttonStyle(.glass)
        .minimumTapTarget(.reserveSpace)
        .disabled(!session.canSave)
        .accessibilityLabel(session.saving ? "Saving…" : "Save")
        .accessibilityIdentifier("saveFile")
    }
    #else
    @ViewBuilder private func editorTitle(_ session: EditorSession) -> some View {
        Image(systemName: "doc.text")
            .foregroundStyle(AgentLandColor.textSecondary)
            .accessibilityHidden(true)
        Text(tab.resourceID)
            .agentLandFont(.codeSmall)
            .lineLimit(1)
            .truncationMode(.middle)
        Spacer(minLength: AgentLandSpacing.xxSmall)
        if let line = session.caretLine {
            // Where the caret is, once the file opened at a line or the caret moved.
            Text("Line \(line)")
                .font(AgentLandTypeRole.metadata.font.monospacedDigit())
                .foregroundStyle(AgentLandColor.textSecondary)
                .lineLimit(1)
                .fixedSize()
                .accessibilityIdentifier("editorLine")
        }
        if session.edited {
            Badge("Edited")
                .accessibilityLabel("Edited")
        }
    }

    @ViewBuilder private func editorActions(_ session: EditorSession) -> some View {
        Button {
            WorkspacePlatform.copy(session.content)
        } label: {
            WorkspaceIconLabel(systemImage: "doc.on.doc")
        }
        .buttonStyle(.plain)
        .workspaceHover(Circle())
        .accessibilityLabel("Copy file")

        Button { workspace.reloadTab(tab.id) } label: {
            WorkspaceIconLabel(systemImage: "arrow.clockwise")
        }
        .buttonStyle(.plain)
        .workspaceHover(Circle())
        .accessibilityLabel("Reload")

        Button { Task { await session.save() } } label: {
            if session.saving {
                ProgressView().minimumTapTarget(.reserveSpace)
            } else {
                WorkspaceIconLabel(systemImage: "square.and.arrow.down", color: session.canSave ? .tint : .glyphTertiary)
            }
        }
        .buttonStyle(.plain)
        .workspaceHover(Circle())
        .disabled(!session.canSave)
        .accessibilityLabel(session.saving ? "Saving…" : "Save")
        .accessibilityIdentifier("saveFile")
    }
    #endif
}

/// Where lines start in an editor's text, shared by the UIKit and AppKit editors.
enum EditorLines {
    /// Where `line` (from 1) starts in `text`.
    static func location(ofLine line: Int, in text: NSString) -> Int {
        var location = 0
        var current = 1
        while current < line && location < text.length {
            let range = text.lineRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(range)
            current += 1
        }
        return min(location, text.length)
    }

    /// The line (from 1) of the character at `location` in `text`.
    static func line(at location: Int, in text: String) -> Int {
        let utf16 = text.utf16
        let end = utf16.index(utf16.startIndex, offsetBy: min(max(location, 0), utf16.count))
        return utf16[utf16.startIndex..<end].reduce(1) { $1 == 10 ? $0 + 1 : $0 }
    }
}

#if os(iOS)
// The Mac's editor is MacLineNumberEditor.swift.

private struct LineNumberEditor: UIViewRepresentable {
    @Binding var text: String
    let documentGeneration: UUID
    let active: Bool
    let colorScheme: ColorScheme
    let increasedContrast: Bool
    /// A Find request to show the find bar for; each value is shown once.
    var findRequest: Int? = nil
    /// A line to show and put the caret on once the document is in the text view.
    var lineRequest: EditorLineRequest? = nil
    var lineShown: (UUID) -> Void = { _ in }
    var caretMoved: (Int) -> Void = { _ in }
    /// Whether the editor's tab takes input now, from the model (see `UnwrappedTextView.takesInput`).
    var takesInput: @MainActor () -> Bool = { true }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> EditorContainer {
        let view = EditorContainer()
        view.takesInput = takesInput
        context.coordinator.view = view
        view.textView.delegate = context.coordinator
        view.textView.accessibilityIdentifier = "fileEditor"
        view.applyDocument(text,
                           generation: documentGeneration,
                           preservingSelection: false)
        view.applyTheme(colorScheme, increasedContrast: increasedContrast)
        view.setActive(active)
        return view
    }

    func updateUIView(_ view: EditorContainer, context: Context) {
        context.coordinator.parent = self
        view.takesInput = takesInput
        view.applyTheme(colorScheme, increasedContrast: increasedContrast)
        view.setActive(active)
        view.applyDocument(text,
                           generation: documentGeneration,
                           preservingSelection: true)
        if let findRequest, findRequest != context.coordinator.shownFindRequest {
            context.coordinator.shownFindRequest = findRequest
            // Outside the render transaction: the find bar takes first responder.
            DispatchQueue.main.async { view.presentFind() }
        }
        if let lineRequest, lineRequest.id != context.coordinator.shownLineRequest {
            context.coordinator.shownLineRequest = lineRequest.id
            let shown = lineShown
            // After layout, outside the render transaction; the session hears it then, so a rebuilt
            // view doesn't move the caret back.
            DispatchQueue.main.async {
                view.reveal(line: lineRequest.line)
                shown(lineRequest.id)
            }
        }
    }

    static func dismantleUIView(_ view: EditorContainer, coordinator: Coordinator) {
        view.textView.resignFirstResponder()
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: LineNumberEditor
        weak var view: EditorContainer?
        var shownFindRequest: Int?
        var shownLineRequest: UUID?

        init(_ parent: LineNumberEditor) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            view?.invalidateGutter()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            // Only the person's own moves count; a document being applied also moves the selection.
            guard textView.isFirstResponder else { return }
            let line = EditorContainer.line(at: textView.selectedRange.location, in: textView.text ?? "")
            let moved = parent.caretMoved
            DispatchQueue.main.async { moved(line) }
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            view?.invalidateGutter()
        }
    }
}

/// The editor's UIKit text view with a line-number gutter. Its text follows Dynamic Type (the code
/// role: subheadline, monospaced), and the gutter widens with the numbers' size.
final class EditorContainer: UIView {
    private let gutter = LineNumberGutterView()
    /// A TextKit 1 stack (the gutter reads line positions from its layout manager) whose container
    /// never wraps: long lines scroll sideways.
    private let storage = NSTextStorage()
    let textView: UITextView
    private var currentTheme: EditorTheme?
    private var currentDocumentGeneration: UUID?
    private var currentActiveState: Bool?
    /// The wash that marks a line opened from search, for a moment.
    private weak var lineMarker: UIView?
    /// Whether the editor's tab takes input now; the text view refuses the keyboard otherwise.
    var takesInput: @MainActor () -> Bool = { true } {
        didSet { (textView as? UnwrappedTextView)?.takesInput = takesInput }
    }

    private struct EditorTheme: Equatable {
        let colorScheme: ColorScheme
        let increasedContrast: Bool
    }

    override init(frame: CGRect) {
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = UnwrappedTextContainer(size: CGSize(width: CGFloat.greatestFiniteMagnitude,
                                                            height: CGFloat.greatestFiniteMagnitude))
        layout.addTextContainer(container)
        textView = UnwrappedTextView(frame: .zero, textContainer: container)
        // UITextView turns this on when it takes the container.
        container.widthTracksTextView = false
        super.init(frame: frame)
        isAccessibilityElement = false
        backgroundColor = .clear

        gutter.isAccessibilityElement = false
        gutter.textView = textView
        addSubview(gutter)

        textView.backgroundColor = .clear
        textView.font = UIFontMetrics(forTextStyle: .subheadline)
            .scaledFont(for: .monospacedSystemFont(ofSize: 15, weight: .regular))
        textView.adjustsFontForContentSizeCategory = true
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.smartDashesType = .no
        textView.smartQuotesType = .no
        textView.smartInsertDeleteType = .no
        textView.alwaysBounceHorizontal = true
        textView.showsHorizontalScrollIndicator = true
        textView.isDirectionalLockEnabled = true
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        // ⌘F and the title menu's Find show the system find bar over the file.
        textView.isFindInteractionEnabled = true
        addSubview(textView)
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: EditorContainer, _: UITraitCollection) in
            view.setNeedsLayout()
            view.invalidateGutter()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let gutterWidth = gutter.preferredWidth
        gutter.frame = CGRect(x: 0, y: 0, width: gutterWidth, height: bounds.height)
        textView.frame = CGRect(x: gutterWidth,
                                y: 0,
                                width: max(bounds.width - gutterWidth, 0),
                                height: bounds.height)
        invalidateGutter()
    }

    func applyTheme(_ colorScheme: ColorScheme, increasedContrast: Bool = false) {
        let theme = EditorTheme(colorScheme: colorScheme, increasedContrast: increasedContrast)
        guard currentTheme != theme else { return }
        currentTheme = theme
        let traits = UITraitCollection { traits in
            traits.userInterfaceStyle = colorScheme == .dark ? .dark : .light
            traits.accessibilityContrast = increasedContrast ? .high : .normal
        }
        backgroundColor = AgentLandColor.canvas.uiColor.resolvedColor(with: traits)
        textView.textColor = AgentLandColor.text.uiColor.resolvedColor(with: traits)
        textView.tintColor = AgentLandColor.tint.uiColor.resolvedColor(with: traits)
        gutter.numberColor = AgentLandColor.textSecondary.uiColor.resolvedColor(with: traits)
        gutter.ruleColor = AgentLandColor.separator.uiColor.resolvedColor(with: traits)
        invalidateGutter()
    }

    func setActive(_ active: Bool) {
        guard currentActiveState != active else { return }
        currentActiveState = active
        textView.isEditable = active
        textView.isSelectable = true
        if !active && textView.isFirstResponder {
            textView.resignFirstResponder()
        }
    }

    @discardableResult
    func applyDocument(_ text: String,
                       generation: UUID,
                       preservingSelection: Bool) -> Bool {
        guard currentDocumentGeneration != generation else { return false }
        currentDocumentGeneration = generation
        let selection = textView.selectedRange
        let wasFirstResponder = textView.isFirstResponder
        // UIKit owns the live document between explicit load generations.
        // Binding echoes can arrive behind rapid delegate edits, so they must
        // never replace text for the current generation.
        textView.text = text

        if preservingSelection {
            let location = min(selection.location, textView.textStorage.length)
            let remaining = textView.textStorage.length - location
            textView.selectedRange = NSRange(location: location,
                                              length: min(selection.length, remaining))
            if wasFirstResponder && textView.isEditable { textView.becomeFirstResponder() }
        }
        setNeedsLayout()
        invalidateGutter()
        return true
    }

    func invalidateGutter() {
        gutter.setNeedsDisplay()
    }

    /// Shows the find bar for the file's text.
    func presentFind() {
        textView.findInteraction?.presentFindNavigator(showingReplace: false)
    }

    /// Scrolls `line` (counted from 1) into view near the top, puts the caret at its start and marks
    /// it for a moment. A line past the end shows the last one.
    func reveal(line: Int) {
        let text = (textView.text ?? "") as NSString
        let start = Self.location(ofLine: line, in: text)
        let range = text.length == 0 ? NSRange(location: 0, length: 0) : text.lineRange(for: NSRange(location: min(start, max(text.length - 1, 0)), length: 0))
        layoutIfNeeded()
        textView.layoutManager.ensureLayout(for: textView.textContainer)
        textView.selectedRange = NSRange(location: start, length: 0)
        let glyphs = textView.layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rect = textView.layoutManager.boundingRect(forGlyphRange: glyphs, in: textView.textContainer)
        let top = max(0, min(rect.minY + textView.textContainerInset.top - textView.bounds.height / 4,
                             textView.contentSize.height - textView.bounds.height + textView.adjustedContentInset.bottom))
        textView.setContentOffset(CGPoint(x: -textView.adjustedContentInset.left, y: top), animated: false)
        invalidateGutter()
        guard range.length > 0 else { return }
        // A wash behind the line for a moment, in the text view's content so it scrolls with the line.
        lineMarker?.removeFromSuperview()
        let marker = UIView(frame: CGRect(x: 0, y: rect.minY + textView.textContainerInset.top,
                                          width: max(textView.contentSize.width, textView.bounds.width), height: rect.height))
        marker.backgroundColor = (textView.tintColor ?? .tintColor).withAlphaComponent(0.18)
        marker.isUserInteractionEnabled = false
        marker.isAccessibilityElement = false
        textView.insertSubview(marker, at: 0)
        lineMarker = marker
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak marker] in
            if UIAccessibility.isReduceMotionEnabled {
                marker?.removeFromSuperview()
            } else {
                UIView.animate(withDuration: 0.4, animations: { marker?.alpha = 0 }, completion: { _ in marker?.removeFromSuperview() })
            }
        }
    }

    /// Where `line` (from 1) starts in `text`.
    static func location(ofLine line: Int, in text: NSString) -> Int {
        EditorLines.location(ofLine: line, in: text)
    }

    /// The line (from 1) of the character at `location` in `text`.
    static func line(at location: Int, in text: String) -> Int {
        EditorLines.line(at: location, in: text)
    }
}

/// A text container as wide as the longest line. UITextView sets its container's width to its own
/// when it lays out, even with `widthTracksTextView` off, which would wrap long lines.
private final class UnwrappedTextContainer: NSTextContainer {
    override var size: CGSize {
        get { super.size }
        set { super.size = CGSize(width: CGFloat.greatestFiniteMagnitude, height: newValue.height) }
    }
}

/// A text view that scrolls sideways to the end of its longest line. UITextView keeps its content as
/// wide as itself, since it expects its lines to wrap.
private final class UnwrappedTextView: UITextView {
    /// Whether the editor's tab takes input now (selected, unlocked, opened). The model changes before the
    /// views update, so this is already false while UIKit runs the task switcher's dismissal, which asks the
    /// text view that had the keyboard to take it again; taken there and then put away, the keyboard stayed
    /// over Home with nothing focused (B-8, the editor's case).
    var takesInput: @MainActor () -> Bool = { true }

    override var canBecomeFirstResponder: Bool { super.canBecomeFirstResponder && takesInput() }

    override func becomeFirstResponder() -> Bool {
        guard canBecomeFirstResponder else {
            if isFirstResponder { _ = super.resignFirstResponder() }
            return false
        }
        return super.becomeFirstResponder()
    }

    override var contentSize: CGSize {
        get { super.contentSize }
        set {
            let lines = layoutManager.usedRect(for: textContainer).width
            let width = ceil(lines + textContainerInset.left + textContainerInset.right)
            super.contentSize = CGSize(width: max(newValue.width, width), height: newValue.height)
        }
    }
}

private final class LineNumberGutterView: UIView {
    weak var textView: UITextView?
    var numberColor: UIColor = .secondaryLabel
    var ruleColor: UIColor = .separator

    /// Line numbers follow Dynamic Type like the text beside them, a step smaller.
    private var font: UIFont {
        UIFontMetrics(forTextStyle: .footnote)
            .scaledFont(for: .monospacedSystemFont(ofSize: 12, weight: .regular), compatibleWith: traitCollection)
    }

    /// Wide enough for the largest line number at the current text size; 48 pt at the default size.
    var preferredWidth: CGFloat {
        let lines = (textView?.text ?? "").utf8.reduce(1) { count, byte in byte == 10 ? count + 1 : count }
        let digits = max(3, String(lines).count)
        let digitWidth = ("8" as NSString).size(withAttributes: [.font: font]).width
        return max(48, ceil(CGFloat(digits) * digitWidth + 26))
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ rect: CGRect) {
        guard let textView, let context = UIGraphicsGetCurrentContext() else { return }
        textView.layoutManager.ensureLayout(for: textView.textContainer)
        let font = self.font

        context.setStrokeColor(ruleColor.cgColor)
        context.setLineWidth(0.5)
        context.move(to: CGPoint(x: bounds.maxX - 0.25, y: bounds.minY))
        context.addLine(to: CGPoint(x: bounds.maxX - 0.25, y: bounds.maxY))
        context.strokePath()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: numberColor,
            .paragraphStyle: paragraph
        ]
        let source = (textView.text ?? "") as NSString
        var characterIndex = 0
        var lineNumber = 1

        if source.length == 0 {
            drawNumber(lineNumber,
                       y: textView.textContainerInset.top - textView.contentOffset.y,
                       font: font,
                       attributes: attributes)
            return
        }

        while characterIndex < source.length {
            let lineRange = source.lineRange(for: NSRange(location: characterIndex, length: 0))
            let glyphIndex = textView.layoutManager.glyphIndexForCharacter(at: characterIndex)
            let fragment = textView.layoutManager.lineFragmentRect(forGlyphAt: glyphIndex,
                                                                    effectiveRange: nil)
            let y = fragment.minY + textView.textContainerInset.top - textView.contentOffset.y
            if y + fragment.height >= rect.minY && y <= rect.maxY {
                drawNumber(lineNumber, y: y, font: font, attributes: attributes)
            }
            characterIndex = NSMaxRange(lineRange)
            lineNumber += 1
        }

        if source.character(at: source.length - 1) == 10 {
            let extra = textView.layoutManager.extraLineFragmentRect
            let y = extra.minY + textView.textContainerInset.top - textView.contentOffset.y
            drawNumber(lineNumber, y: y, font: font, attributes: attributes)
        }
    }

    private func drawNumber(_ number: Int,
                            y: CGFloat,
                            font: UIFont,
                            attributes: [NSAttributedString.Key: Any]) {
        String(number).draw(in: CGRect(x: 4,
                                       y: y,
                                       width: bounds.width - 10,
                                       height: font.lineHeight),
                            withAttributes: attributes)
    }
}
#endif
