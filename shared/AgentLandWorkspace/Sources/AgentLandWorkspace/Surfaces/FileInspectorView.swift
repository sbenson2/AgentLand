import SwiftUI
import AgentLandCore
import AgentLandDesign

/// A file of the iPhone drawer's Files section, read-only (owner's request, 2026-10-06: "click to inspect a file and
/// open it in workspace"): its text as the host serves it to the editor (`GET /v1/file`), monospaced, scrollable and
/// selectable, and Open in Workspace, which opens it in its editor tab and closes the drawer. A file the host serves no
/// text for (over 1 MiB, or not UTF-8) or one over `FileInspectorPreview.limit` shows "Can't Preview This File".
struct FileInspectorView: View {
    @Environment(WorkspaceModel.self) private var model
    let projectID: String
    let path: String
    @State private var preview: FileInspectorPreview = .loading
    /// Bumped by Try Again and by a connection coming back after a failure: the file is read again.
    @State private var attempt = 0

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The page it is pushed on: the drawer panel's own platter (paper and slate, 2026-10-07; FI-16).
            .groupedPageBackground()
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("fileInspector")
            .toolbar {
                ToolbarItem(placement: openPlacement) {
                    Button("Open in Workspace") { model.openFile(projectID: projectID, path: path) }
                        .accessibilityIdentifier("fileInspectorOpen")
                }
            }
            .task(id: attempt) { await load() }
            .onChange(of: model.connectionEpoch) { _, _ in
                if case .failed = preview { attempt += 1 }
            }
    }

    /// The bottom bar on iPhone, where the whole title fits beside nothing else; the Mac has no drawer.
    private var openPlacement: ToolbarItemPlacement {
        #if os(iOS)
        .bottomBar
        #else
        .primaryAction
        #endif
    }

    @ViewBuilder private var content: some View {
        switch preview {
        case .loading:
            ProgressView { Text("Reading the File").agentLandFont(.secondary) }
                .foregroundStyle(AgentLandColor.textSecondary)
        case let .text(text):
            ScrollView {
                Text(verbatim: text)
                    .agentLandFont(.code)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(AgentLandSpacing.medium)
                    .accessibilityIdentifier("fileInspectorText")
            }
        case .unpreviewable:
            ContentUnavailable("Can’t Preview This File", systemImage: "doc.questionmark",
                               description: "Only text files up to \(FileInspectorPreview.limitText) show here. Open it in the workspace instead.")
        case let .failed(message):
            ContentUnavailable("Couldn’t Read the File", systemImage: "exclamationmark.triangle", description: message) {
                Button("Try Again") { attempt += 1 }
                    .accessibilityIdentifier("fileInspectorRetry")
            }
        }
    }

    private func load() async {
        guard let client = model.client else {
            preview = .failed("The host is unavailable.")
            return
        }
        let hostID = model.hostID
        preview = .loading
        do {
            let document = try await client.file(projectID: projectID, path: path)
            guard !Task.isCancelled, model.hostID == hostID else { return }
            preview = FileInspectorPreview(content: document.content)
        } catch {
            guard !Task.isCancelled, model.hostID == hostID else { return }
            preview = FileInspectorPreview(error: error)
        }
    }
}

/// What the file inspector shows for the host's answer.
enum FileInspectorPreview: Equatable {
    case loading
    case text(String)
    /// Too large, or not text: the editor opens it if anything does.
    case unpreviewable
    case failed(String)

    /// The most text shown, in UTF-8 bytes: SwiftUI lays out one selectable text at once, so a larger file is left to
    /// the editor.
    static let limit = 256 * 1024
    static var limitText: String { ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file) }

    init(content: String) {
        self = content.utf8.count > Self.limit ? .unpreviewable : .text(content)
    }

    /// The host refuses text over 1 MiB (`file_too_large`) and anything but UTF-8 text (`unsupported_file`); any other
    /// error is a failure worth trying again.
    init(error: Error) {
        if case let ClientError.server(code, _) = error, code == "file_too_large" || code == "unsupported_file" {
            self = .unpreviewable
        } else {
            self = .failed(error.localizedDescription)
        }
    }
}
