import SwiftUI
import AgentLandCore

public extension View {
    /// Asks before a chat first runs without asking (Claude Code's Bypass permissions, Codex's Full access; owner,
    /// 2026-10-12 ~21:10: "Confirm once per chat"), as a system confirmation on the control that chose the mode
    /// (`origin`): the composer's mode chip or Options menu, or the `DialogAnchor` under the chat's title menu. The
    /// answer acts on the choice it presented, never on what the store holds by then.
    func chatModeConfirmation(_ store: ChatSessionStore, origin: ChatModeOrigin) -> some View {
        modifier(ChatModeConfirmationModifier(store: store, origin: origin))
    }
}

private struct ChatModeConfirmationModifier: ViewModifier {
    let store: ChatSessionStore
    let origin: ChatModeOrigin
    /// The question on screen. It follows the store's after the menu that chose the mode has gone.
    @State private var presented: ChatModeQuestion?

    func body(content: Content) -> some View {
        content
            .confirmationDialog(presented?.choice.confirmation?.title ?? "",
                                isPresented: Binding(get: { presented != nil }, set: { shown in
                                    guard !shown else { return }
                                    presented = nil
                                    store.cancelModeQuestion()
                                }),
                                titleVisibility: .visible, presenting: presented) { question in
                Button(question.choice.confirmation?.action ?? question.choice.name) { store.confirmMode(question.choice) }
                    .accessibilityIdentifier("chatConfirmMode")
                Button("Cancel", role: .cancel) { store.cancelModeQuestion() }
            } message: { question in
                Text(question.choice.confirmation?.message ?? "")
            }
            .task(id: store.modeQuestion) {
                guard let question = store.modeQuestion, question.origin == origin else {
                    presented = nil
                    return
                }
                #if os(iOS)
                // The question waits for the menu it was chosen from to go (a quarter second outlasts it, as the
                // workspace's `MenuAction.afterDismissal` measured), so it never presents over a closing menu.
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                #endif
                presented = question
            }
    }
}
