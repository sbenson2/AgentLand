import SwiftUI
import AgentLandCore
import AgentLandDesign

/// What a file row can do. The same actions go in its context menu, its swipe actions and its VoiceOver
/// actions; those the host doesn't offer are left out.
struct FileRowActions {
    let canRename: Bool
    let canMove: Bool
    let canDelete: Bool
    /// Deleting moves to the Trash (hosts with one); otherwise it deletes for good after a confirmation.
    let trashes: Bool
    let open: (FileEntry) -> Void
    let rename: (FileEntry) -> Void
    let move: (FileEntry) -> Void
    let copyPath: (FileEntry) -> Void
    let share: (FileEntry) -> Void
    let delete: (FileEntry) -> Void

    var deleteTitle: String { trashes ? "Move to Trash" : "Delete…" }
}

/// A row's actions as menu items: Open, Rename, Move…, Copy Path, Share (files) and Move to Trash.
struct FileActionsMenu: View {
    let entry: FileEntry
    let actions: FileRowActions

    var body: some View {
        Button(entry.isDirectory ? "Open Folder" : "Open", systemImage: "arrow.right") { actions.open(entry) }
        if actions.canRename {
            Button("Rename", systemImage: "pencil") { actions.rename(entry) }
                .accessibilityIdentifier("fileRename")
        }
        if actions.canMove {
            Button("Move…", systemImage: "folder") { actions.move(entry) }
                .accessibilityIdentifier("fileMove")
        }
        Button("Copy Path", systemImage: "doc.on.doc") { actions.copyPath(entry) }
            .accessibilityIdentifier("fileCopyPath")
        if !entry.isDirectory {
            Button("Share…", systemImage: "square.and.arrow.up") { actions.share(entry) }
                .accessibilityIdentifier("fileShare")
        }
        if actions.canDelete {
            Divider()
            Button(role: .destructive) { actions.delete(entry) } label: { Label(actions.deleteTitle, systemImage: "trash") }
                .accessibilityIdentifier("fileTrash")
        }
    }
}

extension View {
    /// VoiceOver's actions for a file row: what its swipes and menus offer.
    func fileAccessibilityActions(_ entry: FileEntry, _ actions: FileRowActions) -> some View {
        self
            .accessibilityAction(named: "Rename") { if actions.canRename { actions.rename(entry) } }
            .accessibilityAction(named: "Move") { if actions.canMove { actions.move(entry) } }
            .accessibilityAction(named: "Copy Path") { actions.copyPath(entry) }
            .accessibilityAction(named: "Share") { if !entry.isDirectory { actions.share(entry) } }
            .accessibilityAction(named: actions.deleteTitle.replacingOccurrences(of: "…", with: "")) { if actions.canDelete { actions.delete(entry) } }
    }
}

private struct FilesRowIdentifierPrefixKey: EnvironmentKey {
    static let defaultValue = "file-"
}

private struct FilesInspectFileKey: EnvironmentKey {
    static let defaultValue: (@MainActor (FileEntry) -> Void)? = nil
}

extension EnvironmentValues {
    /// What a file row's identifier starts with: `file-` in the Files tab, `drawerFile-` in the iPhone drawer's Files section.
    var filesRowIdentifierPrefix: String {
        get { self[FilesRowIdentifierPrefixKey.self] }
        set { self[FilesRowIdentifierPrefixKey.self] = newValue }
    }
    /// Opening a file shows it read-only first, where set: the iPhone drawer's Files section pushes its inspector
    /// (owner's request, 2026-10-06: "click to inspect a file and open it in workspace"). Nil opens the editor, as the
    /// Files tab on iPad and the Mac does. Folders always expand or open in place.
    var filesInspectFile: (@MainActor (FileEntry) -> Void)? {
        get { self[FilesInspectFileKey.self] }
        set { self[FilesInspectFileKey.self] = newValue }
    }
}

/// A size in words for rows and cells ("12 KB"); folders show none.
func fileSizeText(_ entry: FileEntry) -> String {
    ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file)
}

// MARK: iPhone list

/// The folder as a list, as the Files app's list view draws it: a folder's leading disclosure expands it in place and
/// its row opens it; a file's row opens it (in the iPhone drawer it pushes the file's inspector, a navigation link with
/// the system's chevron, FI-3). Swipes, the context menu and VoiceOver's actions carry each row's actions.
struct FilesList: View {
    let session: FilesSession
    let actions: FileRowActions
    @Environment(\.filesInspectFile) private var inspectFile
    @ScaledMetric(relativeTo: .body) private var indent: CGFloat = 16

    var body: some View {
        List {
            ForEach(session.flattenedEntries) { item in
                FileListRow(entry: item.entry, expanded: session.expanded.contains(item.entry.path),
                            busy: session.changing.contains(item.entry.path), inspector: inspectorPage(item.entry),
                            toggle: { session.toggle(item.entry) }, actions: actions)
                    .listRowInsets(EdgeInsets(top: 0, leading: CGFloat(item.depth) * indent, bottom: 0, trailing: AgentLandSpacing.small))
                    .macListRowBackground(.canvas, separator: true)
                    // Not a destructive role: the row stays until the person confirms in the dialog.
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if actions.canDelete {
                            Button { actions.delete(item.entry) } label: { Label(actions.trashes ? "Trash" : "Delete", systemImage: "trash") }
                                .tint(.red)
                        }
                        if actions.canRename {
                            Button { actions.rename(item.entry) } label: { Label("Rename", systemImage: "pencil") }
                                .tint(.gray)
                        }
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        if actions.canMove {
                            Button { actions.move(item.entry) } label: { Label("Move", systemImage: "folder") }
                                .tint(.accentColor)
                        }
                    }
                    .contextMenu { FileActionsMenu(entry: item.entry, actions: actions) }
                    // Its Move to Trash or Delete asks beside this row (owner, 2026-10-08).
                    .modifier(FileDeleteDialogs(entry: item.entry, session: session))
            }
        }
        .listStyle(.plain)
        .hidesListPageBackground()
        .accessibilityIdentifier("filesList")
    }

    /// The inspector page a file's row pushes in the iPhone drawer; elsewhere a file's row opens its editor.
    private func inspectorPage(_ entry: FileEntry) -> WorkspacePhoneNavigation.DrawerPage? {
        inspectFile == nil || entry.isDirectory ? nil : .file(projectID: session.projectID, path: entry.path)
    }
}

/// A file or folder: a folder's disclosure, its symbol and name, and a file's size (trailing, or under the name at
/// accessibility text sizes). A file of the iPhone drawer is a navigation link to its inspector; any other row is a
/// button that opens it.
struct FileListRow: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.filesRowIdentifierPrefix) private var identifierPrefix
    let entry: FileEntry
    let expanded: Bool
    let busy: Bool
    let inspector: WorkspacePhoneNavigation.DrawerPage?
    let toggle: () -> Void
    let actions: FileRowActions

    var body: some View {
        HStack(spacing: 0) {
            if entry.isDirectory {
                // The system's disclosure: one chevron that turns down as the folder opens (FI-2).
                Button(action: toggle) {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(AgentLandColor.glyphTertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .agentLandAnimation(.snappy, value: expanded, reducedMotion: .none)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .workspaceHover(Circle())
                .accessibilityLabel(expanded ? "Collapse \(entry.name)" : "Expand \(entry.name)")
                .accessibilityIdentifier("expand-\(entry.path)")
            } else {
                Color.clear.frame(width: 44, height: 44).accessibilityHidden(true)
            }

            Group {
                if let inspector {
                    NavigationLink(value: inspector) { label }
                } else {
                    Button { actions.open(entry) } label: { label }
                        .buttonStyle(.borderless)
                        .workspaceRowHover()
                }
            }
            .accessibilityLabel(entry.name)
            .accessibilityValue(entry.isDirectory ? "Folder" : fileSizeText(entry))
            .accessibilityHint(entry.isDirectory ? "Opens the folder." : "Opens the file.")
            .fileAccessibilityActions(entry, actions)
            .accessibilityIdentifier(identifierPrefix + entry.path)
        }
        .foregroundStyle(AgentLandColor.text)
    }

    /// The symbol and name, with a file's size as the value (FI-3). VoiceOver reads the size with the name: it is the
    /// row's value, never a second stop one line of text high.
    private var label: some View {
        LabeledContent {
            HStack(spacing: AgentLandSpacing.xxSmall) {
                if busy { ProgressView().controlSize(.small).accessibilityLabel("Changing") }
                if !entry.isDirectory && !typeSize.isAccessibilitySize {
                    Text(fileSizeText(entry))
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(AgentLandColor.textSecondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .accessibilityHidden(true)
                }
            }
        } label: {
            Label {
                if typeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: AgentLandSpacing.xxxSmall) {
                        Text(entry.name).lineLimit(3)
                        if !entry.isDirectory {
                            Text(fileSizeText(entry)).font(.footnote.monospacedDigit()).foregroundStyle(AgentLandColor.textSecondary)
                        }
                    }
                } else {
                    Text(entry.name).lineLimit(1).truncationMode(.middle)
                }
            } icon: {
                Image(systemName: entry.isDirectory ? "folder" : "doc.text")
                    .foregroundStyle(entry.isDirectory ? AgentLandColor.tint : AgentLandColor.textSecondary)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(AgentLandColor.text)
        }
        .agentLandFont(.body)
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
    }
}

// MARK: iPad table

extension FilesSession.TreeItem {
    /// Items without a time sort first.
    var modifiedKey: Date { entry.modifiedAt ?? .distantPast }
}

/// The folder as a table on iPad: Name (folders expand in place), Size and, when the host names it,
/// Date Modified. A tap opens a row; its context menu carries the actions. The column headers sort.
struct FilesTable: View {
    let session: FilesSession
    let actions: FileRowActions
    @State private var selection: Set<String> = []
    @State private var sortOrder = [KeyPathComparator(\FilesSession.TreeItem.entry.name, comparator: .localizedStandard)]
    @ScaledMetric(relativeTo: .body) private var indent: CGFloat = 16

    var body: some View {
        let items = session.flattenedEntries
        Table(of: FilesSession.TreeItem.self, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", sortUsing: KeyPathComparator(\FilesSession.TreeItem.entry.name, comparator: .localizedStandard)) { item in
                nameCell(item)
            }
            TableColumn("Size", sortUsing: KeyPathComparator(\FilesSession.TreeItem.entry.size)) { item in
                Text(item.entry.isDirectory ? "—" : fileSizeText(item.entry))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(AgentLandColor.textSecondary)
                    .accessibilityLabel(item.entry.isDirectory ? "Folder" : fileSizeText(item.entry))
            }
            .width(min: 80, ideal: 110, max: 160)
            if session.hasModifiedTimes {
                TableColumn("Date Modified", sortUsing: KeyPathComparator(\FilesSession.TreeItem.modifiedKey)) { item in
                    Text(item.entry.modifiedAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—")
                        .font(.subheadline)
                        .foregroundStyle(AgentLandColor.textSecondary)
                }
                .width(min: 140, ideal: 190, max: 240)
            }
        } rows: {
            ForEach(items) { item in TableRow(item) }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let entry = entry(ids.first, in: items) { FileActionsMenu(entry: entry, actions: actions) }
        } primaryAction: { ids in
            if let entry = entry(ids.first, in: items) { actions.open(entry) }
        }
        .listPageBackground()
        .onAppear { sortOrder = [comparator(session.sortField, ascending: session.sortAscending)] }
        .onChange(of: sortOrder) { _, order in
            guard let first = order.first else { return }
            let field: FileSortField = first.keyPath == \FilesSession.TreeItem.entry.size ? .size
                : first.keyPath == \FilesSession.TreeItem.modifiedKey ? .modified : .name
            session.setSort(field, ascending: first.order == .forward)
        }
        .accessibilityIdentifier("filesTable")
    }

    private func comparator(_ field: FileSortField, ascending: Bool) -> KeyPathComparator<FilesSession.TreeItem> {
        let order: SortOrder = ascending ? .forward : .reverse
        switch field {
        case .name: return KeyPathComparator(\FilesSession.TreeItem.entry.name, comparator: .localizedStandard, order: order)
        case .size: return KeyPathComparator(\FilesSession.TreeItem.entry.size, order: order)
        case .modified: return KeyPathComparator(\FilesSession.TreeItem.modifiedKey, order: order)
        }
    }

    private func entry(_ id: String?, in items: [FilesSession.TreeItem]) -> FileEntry? {
        guard let id else { return nil }
        return items.first { $0.id == id }?.entry
    }

    private func nameCell(_ item: FilesSession.TreeItem) -> some View {
        let entry = item.entry
        let expanded = session.expanded.contains(entry.path)
        return HStack(spacing: AgentLandSpacing.xxSmall) {
            if entry.isDirectory {
                Button { session.toggle(entry) } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(AgentLandColor.glyphTertiary)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(expanded ? "Collapse \(entry.name)" : "Expand \(entry.name)")
                .accessibilityIdentifier("expand-\(entry.path)")
            } else {
                Color.clear.frame(width: 44, height: 44).accessibilityHidden(true)
            }
            Label {
                Text(entry.name).lineLimit(1).truncationMode(.middle)
            } icon: {
                Image(systemName: entry.isDirectory ? "folder" : "doc.text")
                    .foregroundStyle(entry.isDirectory ? AgentLandColor.tint : AgentLandColor.textSecondary)
            }
            .agentLandFont(.body)
            .foregroundStyle(AgentLandColor.text)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(entry.name)
            .accessibilityValue(entry.isDirectory ? "Folder" : fileSizeText(entry))
            .accessibilityAddTraits(.isButton)
            .fileAccessibilityActions(entry, actions)
            .accessibilityIdentifier("file-\(entry.path)")
            if session.changing.contains(entry.path) { ProgressView().controlSize(.small).accessibilityLabel("Changing") }
        }
        .padding(.leading, CGFloat(item.depth) * indent)
        .frame(minHeight: 44)
        // Its Move to Trash or Delete (from the table's context menu) asks beside this row (owner, 2026-10-08).
        .modifier(FileDeleteDialogs(entry: entry, session: session))
    }
}

// MARK: Search results

/// The search's results: names under the folder, or matching lines grouped by file, each opening the
/// editor at its line.
struct FilesSearchResults: View {
    @WorkspaceHorizontalSizeClass private var sizeClass
    let session: FilesSession
    let actions: FileRowActions

    var body: some View {
        let search = session.search
        List {
            if sizeClass == .regular && search.offersContents {
                // The toolbar's search field has no scope bar in regular width.
                Picker("Search In", selection: Bindable(search).scope) {
                    ForEach(FileSearchScope.allCases, id: \.self) { scope in Text(scope.title).tag(scope) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 360)
                .macListRowBackground(.canvas)
                .listRowSeparator(.hidden)
                .accessibilityIdentifier("fileSearchScope")
            }
            if let issue = search.issue {
                Text(issue)
                    .agentLandFont(.secondary)
                    .foregroundStyle(AgentLandColor.textSecondary)
                    .macListRowBackground(.canvas)
                    .accessibilityIdentifier("fileSearchIssue")
            }
            switch search.effectiveScope {
            case .names:
                Section {
                    ForEach(search.names) { entry in
                        Button { open(entry) } label: {
                            Label {
                                VStack(alignment: .leading, spacing: AgentLandSpacing.xxxSmall) {
                                    Text(entry.name).foregroundStyle(AgentLandColor.text).lineLimit(2)
                                    let folder = FilesSession.parent(of: entry.path)
                                    if !folder.isEmpty {
                                        Text(folder).agentLandFont(.metadata).foregroundStyle(AgentLandColor.textSecondary).lineLimit(1).truncationMode(.middle)
                                    }
                                }
                            } icon: {
                                Image(systemName: entry.isDirectory ? "folder" : "doc.text")
                                    .foregroundStyle(entry.isDirectory ? AgentLandColor.tint : AgentLandColor.textSecondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .macListRowBackground(.canvas)
                        .contextMenu { FileActionsMenu(entry: entry, actions: actions) }
                        .fileAccessibilityActions(entry, actions)
                        .accessibilityIdentifier("fileSearchName-\(entry.path)")
                        // Its Move to Trash or Delete asks beside this result (owner, 2026-10-08).
                        .modifier(FileDeleteDialogs(entry: entry, session: session))
                    }
                } footer: {
                    // Notes go in the section's footer, in the system's own style (FI-12).
                    if search.namesIncomplete && !search.names.isEmpty {
                        Text("Names come from the first \(FilesSearchModel.maximumFolders) folders here.")
                    }
                }
            case .contents:
                ForEach(search.contents) { result in
                    Section {
                        ForEach(result.matches, id: \.line) { match in
                            Button { session.openMatch(path: result.path, line: match.line) } label: {
                                FileMatchRow(match: match, query: search.query)
                            }
                            .buttonStyle(.plain)
                            .macListRowBackground(.canvas)
                            .accessibilityIdentifier("fileSearchMatch-\(result.path)-\(match.line)")
                        }
                    } header: {
                        // The system's section header, in its own font and colour (FI-12).
                        Text(result.path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } footer: {
                        if result.truncated {
                            Text("More lines match in this file.")
                        }
                    }
                }
                if let limit = search.limit {
                    Section {} footer: { Text(limit.explanation) }
                }
            }
            if search.names.isEmpty && search.contents.isEmpty && search.issue == nil {
                Group {
                    if search.resultsCurrent {
                        ContentUnavailable.search(text: search.query)
                    } else {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 88)
                    }
                }
                .macListRowBackground(.canvas)
                .listRowSeparator(.hidden)
            } else if search.searching {
                ProgressView().frame(maxWidth: .infinity)
                    .macListRowBackground(.canvas)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .hidesListPageBackground()
        .accessibilityIdentifier("fileSearchResults")
    }

    private func open(_ entry: FileEntry) {
        if entry.isDirectory {
            session.search.text = ""
            session.search.isPresented = false
        }
        actions.open(entry)
    }
}

/// A matching line: its number and the text around the match, the query's words in bold.
struct FileMatchRow: View {
    let match: FileSearchMatch
    let query: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: AgentLandSpacing.small) {
            Text(String(match.line))
                .font(AgentLandTypeRole.codeSmall.font.monospacedDigit())
                .foregroundStyle(AgentLandColor.textSecondary)
                .frame(minWidth: 32, alignment: .trailing)
            Text(highlighted)
                .agentLandFont(.code)
                .foregroundStyle(AgentLandColor.text)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Line \(match.line): \(trimmedPreview)")
        .accessibilityHint("Opens the file at this line.")
    }

    private var trimmedPreview: String { match.preview.trimmingCharacters(in: .whitespaces) }

    private var highlighted: AttributedString {
        var text = AttributedString(trimmedPreview)
        guard !query.isEmpty else { return text }
        var searchRange = text.startIndex..<text.endIndex
        while let found = text[searchRange].range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) {
            text[found].inlinePresentationIntent = .stronglyEmphasized
            searchRange = found.upperBound..<text.endIndex
        }
        return text
    }
}
