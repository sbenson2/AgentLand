import SwiftUI
import AgentLandCore
import AgentLandBranding
import AgentLandChat
import AgentLandArchive
import AgentLandDesign

/// The iPhone, iPad and Mac host for the shared `ChatScreen`. The chat's state
/// lives in a store the workspace owns; this view passes it the connection
/// and lifecycle, gives it the empty-chat tent landing, puts the chat's title and
/// actions in the navigation bar, and reports opening readiness once the chat
/// has content (or an actionable error) for the current refresh generation.
struct ChatTabView: View {
    @Environment(WorkspaceModel.self) private var workspace
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.workspaceObscured) private var workspaceObscured
    /// The saved appearance, as the workspace shows it; the Mac's empty-chat landing overrides it.
    @Environment(\.colorScheme) private var colorScheme
    let tab: WorkspaceTab
    @State private var showsContinue = false
    @State private var confirmingRunAgain = false
    @State private var handledRunAgainRequest: Int?
    /// This view's name in the workspace's list of views that show the tab.
    @State private var viewID = UUID()

    /// Selected, scene active and unlocked: the only state in which the chat
    /// keeps a stream open. A sheet over the workspace does not stop it.
    private var active: Bool { workspace.selectedTabID == tab.id && !workspace.locked && scenePhase == .active }
    /// Input also waits for the opening cover and anything covering the workspace.
    private var inputActive: Bool { active && !workspace.presentationPending && !workspaceObscured }
    private var refreshToken: UUID? { workspace.tabRefreshGeneration[tab.id] }

    private struct EnvironmentKey: Equatable {
        let client: ObjectIdentifier?
        let capabilities: CapabilitiesResponse?
        let reachable: Bool
        let epoch: Int
        let active: Bool
        let refresh: UUID?
        let workspaceIDs: Set<String>
        let continueWorkspace: ChatWorkspace?
    }

    private var environmentKey: EnvironmentKey {
        EnvironmentKey(client: workspace.client.map(ObjectIdentifier.init), capabilities: workspace.capabilities, reachable: workspace.reachable,
                       epoch: workspace.connectionEpoch, active: active, refresh: refreshToken, workspaceIDs: workspace.workspaceIDs,
                       continueWorkspace: continueWorkspace)
    }

    /// Where a read-only Chats-space chat continues (its Continue in <workspace>): the workspace in use, nil while none is.
    private var continueWorkspace: ChatWorkspace? {
        workspace.currentProject.map { ChatWorkspace(id: $0.id, name: $0.name) }
    }

    var body: some View {
        let store = workspace.chatStore(for: tab)
        let title = store.displayTitle(fallback: tab.title)
        ChatScreen(store: store, inputEnabled: inputActive) {
            // Every empty chat, a plain chat or an agent's, opens like the plain chat: the tent and "What’s on your
            // mind?" over the composer (owner, 2026-10-07).
            PlainChatLanding(animated: inputActive)
        }
        // The chat's header lives in the navigation bar: its title and, as the value, its agent and
        // workspace ("Claude Code · my-app") or a plain chat's model; the title menu holds the chat's actions.
        .surfaceTitle(title, systemImage: "bubble.left.and.bubble.right", identifier: "chatHeader",
                      value: store.subtitleValue(workspace: workspaceName)) {
            titleMenu(store, title: title)
        }
        .sheet(isPresented: $showsContinue) {
            ChatContinueSheet(store: store, providers: store.continueProviders)
                .agentLandSheetPage()
        }
        // Run Again from the title menu or ⇧⌘R: its question points at the title menu (`DialogAnchor`); the reply's own
        // Run Again asks beside the reply (ChatScreen).
        .overlay(alignment: DialogAnchor.titleMenu) {
            DialogAnchor()
                .confirmationDialog("Run the latest prompt again?", isPresented: $confirmingRunAgain, titleVisibility: .visible) {
                    Button("Run Again") { Task { await store.runAgain() } }
                        .accessibilityIdentifier("chatConfirmRunAgain")
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(store.runAgainConfirmation)
                }
        }
        .onChange(of: environmentKey, initial: true) { _, _ in store.update(environment) }
        .onChange(of: workspace.presentationRequest(for: tab.id), initial: true) { _, _ in reportPresentationIfReady(store) }
        .onChange(of: store.isResolved(for: refreshToken), initial: true) { _, _ in reportPresentationIfReady(store) }
        // The tab carries the chat's title (the host's, or the first prompt line while the host still has a
        // default one): the workspace follows the store's name, whether or not this view shows it.
        .onChange(of: workspace.runAgainRequest, initial: true) { _, request in
            // Regenerate (⇧⌘R) asks first, like the reply's Run Again. A request made before this
            // view existed is not this view's.
            defer { handledRunAgainRequest = request }
            guard let handled = handledRunAgainRequest, handled != request, inputActive, store.canRunAgain else { return }
            confirmingRunAgain = true
        }
        .onChange(of: workspace.selectedTabID) { _, selected in if selected != tab.id { store.flushDraft() } }
        .onChange(of: workspaceObscured) { _, obscured in if obscured { store.flushDraft() } }
        .onChange(of: scenePhase) { _, phase in if phase != .active { store.flushDraft() } }
        .onAppear {
            workspace.surfaceView(viewID, of: tab.id, shown: true)
            store.update(environment)
        }
        .onDisappear {
            store.flushDraft()
            // A view built again in place may already show this chat; the stream stays open for it.
            guard !workspace.surfaceView(viewID, of: tab.id, shown: false) else { return }
            var leaving = environment
            leaving.active = false
            store.update(leaving)
        }
        #if os(macOS)
        // On the Mac the empty-chat landing stays dark on slate, as it was before the HIG pass: the chat and
        // its bar take the dark appearance while the landing shows. The values change in place, so the chat
        // keeps its identity and the composer its text and focus.
        .environment(\.colorScheme, store.showsLanding ? .dark : colorScheme)
        #endif
        // On iPhone and iPad the landing follows the appearance (owner's answer Q7, "Follow appearance", carried
        // out 2026-10-07): paper in Light, slate in Dark, and the shell continues it behind its header.
        .preference(key: ArtBackdropKey.self, value: store.showsLanding)
    }

    private var environment: ChatSessionStore.Environment {
        ChatSessionStore.Environment(client: workspace.client, capabilities: workspace.capabilities, reachable: workspace.reachable,
                                     connectionEpoch: workspace.connectionEpoch, active: active, refreshGeneration: refreshToken,
                                     workspaceIDs: workspace.workspaceIDs, continueWorkspace: continueWorkspace)
    }

    private var workspaceName: String? { workspace.projects.first { $0.id == tab.projectID }?.name }

    /// Content readiness for the current ticket and refresh generation; the
    /// root still waits for a display frame before uncovering.
    private func reportPresentationIfReady(_ store: ChatSessionStore) {
        guard store.isResolved(for: refreshToken), let ticket = workspace.presentationRequest(for: tab.id) else { return }
        workspace.reportPresentationReady(ticket)
    }

    // MARK: Title menu

    /// The chat's actions (the chat package's), then what the archive
    /// adds: Pin, Export as JSON and Delete.
    @ViewBuilder private func titleMenu(_ store: ChatSessionStore, title: String) -> some View {
        // Continue's sheet comes up once the iPhone's drawer, whose pill menu chose it, has gone.
        ChatTitleMenuItems(store: store, title: title, workspace: workspaceName,
                           continueWithAnotherModel: { [workspace] in workspace.phoneNavigation.afterPanels { showsContinue = true } })
        if workspace.sidebar.usesArchive, let archive = workspace.archive {
            let record = archivedRecord(title: title, provider: store.provider)
            Section {
                Button(record.pinned ? "Unpin" : "Pin", systemImage: record.pinned ? "pin.slash" : "pin") {
                    Task { await workspace.sidebar.setPinned(!record.pinned, chatID: record.id) }
                }
                .accessibilityIdentifier("chatPin")
                if workspace.capabilities?.supportsArchive(.export) == true {
                    ShareLink(item: ArchiveChatExport(chat: record, format: .json, client: workspace.reachable ? workspace.client : nil,
                                                      store: archive.store, workspace: workspaceName),
                              preview: SharePreview(title + ".json")) {
                        Label("Export as JSON…", systemImage: "curlybraces")
                    }
                    .accessibilityIdentifier("chatExportJSON")
                }
                Button("Delete…", systemImage: "trash", role: .destructive) { workspace.sidebar.requestDelete(record) }
                    .disabled(!workspace.sidebar.canDelete)
                    .accessibilityIdentifier("chatDelete")
            }
        }
    }

    /// This chat as the archive knows it (a plain chat or the workspace's), or as the tab knows it before the
    /// archive has it.
    private func archivedRecord(title: String, provider: AgentProvider) -> ArchivedChat {
        workspace.sidebar.chat(tab.resourceID)
            ?? ArchivedChat(id: tab.resourceID, projectID: tab.projectID, provider: provider.id, title: title,
                            createdAt: Date(), updatedAt: Date())
    }
}
