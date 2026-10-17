import SwiftUI
import AgentLandCore
import AgentLandArchive
import AgentLandDesign

extension WorkspaceModel {
    /// What the archive screens need, from the workspace as it is now. Its chats are Chat's: the Chats space's and
    /// Claude Code and Codex chats in the workspaces (`WorkspaceModel.isChatShown`).
    func archiveEnvironment(sync: SyncEngine.Status?) -> ArchiveEnvironment {
        ArchiveEnvironment(client: client, capabilities: capabilities, reachable: reachable, hostName: hostName,
                           workspaces: Dictionary(projects.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first }),
                           sync: sync, chatAgents: [AgentProvider.claude.id, AgentProvider.codex.id])
    }
}

/// The archive browser in a sheet: every archived chat and terminal log of this host, searchable,
/// with export and Continue with…. A chat the host still has opens in a chat tab.
struct WorkspaceArchiveSheet: View {
    @Environment(WorkspaceModel.self) private var model
    let archive: WorkspaceArchive
    let openChat: @MainActor (ArchivedChat) -> Bool
    let continued: @MainActor (ContinueResult) -> Void
    let onDone: () -> Void
    private let chatsOnly: Bool
    @State private var browser: ArchiveBrowserModel

    init(archive: WorkspaceArchive, environment: ArchiveEnvironment, terminals: Bool,
         openChat: @escaping @MainActor (ArchivedChat) -> Bool, continued: @escaping @MainActor (ContinueResult) -> Void, onDone: @escaping () -> Void, chatsOnly: Bool = false) {
        self.archive = archive
        self.openChat = openChat
        self.continued = continued
        self.onDone = onDone
        self.chatsOnly = chatsOnly
        let browser = ArchiveBrowserModel(store: archive.store, environment: environment)
        browser.scope = terminals ? .terminals : .chats
        _browser = State(initialValue: browser)
    }

    private var environmentKey: String {
        "\(model.reachable)|\(model.client.map { String(describing: ObjectIdentifier($0)) } ?? "")|\(String(describing: archive.status))"
    }

    var body: some View {
        ArchiveBrowser(model: browser, terminalCache: archive.terminalLogs, attachmentCache: archive.attachments,
                       actions: ArchiveActions(openChat: openChat, continued: continued,
                                               showArchivedChat: { model.requestResume(.archivedChat($0)) },
                                               openTerminalLog: { model.requestResume(.terminalLog($0)) }), onDone: onDone, title: chatsOnly ? "Chat History" : "Archive", showsScopePicker: !chatsOnly)
            .onChange(of: environmentKey) { _, _ in browser.update(model.archiveEnvironment(sync: archive.status)) }
    }
}

/// One archived chat the host no longer has live, read-only, in a sheet: its copy on this device or
/// the host's archive, with export and Continue with….
struct WorkspaceArchivedChatSheet: View {
    @Environment(WorkspaceModel.self) private var model
    let archive: WorkspaceArchive
    let continued: @MainActor (ContinueResult) -> Void
    let onDone: () -> Void
    @State private var chat: ArchivedChatModel

    init(chatID: String, archive: WorkspaceArchive, environment: ArchiveEnvironment,
         continued: @escaping @MainActor (ContinueResult) -> Void, onDone: @escaping () -> Void) {
        self.archive = archive
        self.continued = continued
        self.onDone = onDone
        _chat = State(initialValue: ArchivedChatModel(chatID: chatID, store: archive.store, environment: environment,
                                                      attachments: archive.attachments))
    }

    var body: some View {
        NavigationStack {
            ArchivedChatView(model: chat, actions: ArchiveActions(continued: continued))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done", action: onDone).accessibilityIdentifier("archivedChatDone")
                    }
                }
        }
        .onChange(of: model.reachable) { _, _ in chat.update(model.archiveEnvironment(sync: archive.status)) }
    }
}
