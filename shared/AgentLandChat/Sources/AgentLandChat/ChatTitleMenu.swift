import SwiftUI
#if os(iOS)
import UIKit
#endif

extension View {
    /// Send (⌘↩), Stop (⌘.) and Run Again (⇧⌘R) on the chat's own controls, where the app has no menu
    /// of chat commands: the Mac and iPhone. On iPad the workspace's commands in the menu bar carry
    /// them; the same shortcut on both reaches neither.
    @MainActor func chatCommandShortcut(_ key: KeyEquivalent, modifiers: EventModifiers) -> some View {
        #if os(iOS)
        let own = UIDevice.current.userInterfaceIdiom != .pad
        #else
        let own = true
        #endif
        return keyboardShortcut(own ? KeyboardShortcut(key, modifiers: modifiers) : nil)
    }
}
import AgentLandCore
import AgentLandDesign

/// The chat's own actions for an app that shows the chat's title in its navigation bar, as a title
/// menu: Copy Chat, Save as Markdown…, Continue with Another Model… and Refresh. The app adds what it
/// owns around them (Pin, Delete). The model, its thinking and the mode live in the composer's pill alone
/// (owner, 2026-10-25: one home each).
public struct ChatTitleMenuItems: View {
    let store: ChatSessionStore
    let title: String
    let workspace: String?
    let continueWithAnotherModel: () -> Void

    public init(store: ChatSessionStore, title: String, workspace: String?,
                continueWithAnotherModel: @escaping () -> Void) {
        self.store = store
        self.title = title
        self.workspace = workspace
        self.continueWithAnotherModel = continueWithAnotherModel
    }

    public var body: some View {
        Section {
            Button("Copy Chat", systemImage: "doc.on.doc") {
                ChatClipboard.copy(store.markdownExport(workspace: workspace))
                AccessibilityNotification.Announcement("Chat copied").post()
            }
            .accessibilityIdentifier("chatCopyChat")
            ShareLink(item: ChatMarkdownFile(title: store.info?.title ?? title, text: store.markdownExport(workspace: workspace)),
                      preview: SharePreview(store.info?.title ?? title)) {
                Label("Save as Markdown…", systemImage: "square.and.arrow.down")
            }
            .accessibilityIdentifier("chatSaveMarkdown")
            if store.canContinue {
                // A read-only Chats-space chat continues in the workspace in use.
                Button(store.continueTitle, systemImage: "arrow.triangle.swap", action: continueWithAnotherModel)
                    .disabled(!store.hasContent || !store.reachable || (store.isReadOnly && store.continueWorkspace == nil))
                    .accessibilityIdentifier("chatContinue")
            }
            Button("Refresh", systemImage: "arrow.clockwise") { store.refreshStatus() }
                .accessibilityIdentifier("chatRefresh")
        }
    }
}

public extension ChatSessionStore {
    /// Continue's title: "Continue with Another Model…", or for a read-only chat "Continue in my-app…".
    var continueTitle: String {
        guard isReadOnly else { return "Continue with Another Model…" }
        return continueWorkspace.map { "Continue in \($0.name)…" } ?? "Continue in a Workspace…"
    }

    /// What Run Again does to this chat, for its confirmation.
    var runAgainConfirmation: String {
        hostRegenerates
            ? "The latest reply is replaced by a new one."
            : ChatRewindCopy.message(provider: provider, restoresFiles: rewindRestoresFiles)
    }

    /// The subtitle under the chat's title: an agent chat's agent and workspace ("Claude Code · my-app"); a plain
    /// chat's model ("Claude Sonnet 4.5"), since it belongs to no workspace and which agent answers is the host's.
    func subtitle(workspace: String?) -> String {
        guard !isPlainChat else { return modelName ?? "" }
        return [provider.displayName, workspace].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// The header's value: the subtitle, and "working" while the chat works ("Claude Code · my-app, working").
    func subtitleValue(workspace: String?) -> String {
        [subtitle(workspace: workspace), isWorking ? "working" : ""].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// The chosen model by name, as the host lists it; until its list is read, or when it lacks the model, the
    /// model's ID without its provider ("anthropic/claude-sonnet-4-5" is "claude-sonnet-4-5").
    var modelName: String? {
        if let name = selectedModel?.name.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        let id = selectedModelID.isEmpty ? info?.model ?? "" : selectedModelID
        guard let last = id.split(separator: "/").last?.trimmingCharacters(in: .whitespacesAndNewlines), !last.isEmpty else { return nil }
        return last
    }
}
