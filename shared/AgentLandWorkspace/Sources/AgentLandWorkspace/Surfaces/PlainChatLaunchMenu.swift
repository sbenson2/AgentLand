import SwiftUI
import AgentLandCore

/// Chat's provider choices stay anchored to its launch control in the system menu.
/// Without a workspace, the shell asks for one before offering the providers.
struct PlainChatLaunchMenu<Label: View>: View {
    @Environment(WorkspaceModel.self) private var workspace
    @Environment(\.workspaceShell) private var shell
    @ViewBuilder let label: () -> Label

    var body: some View {
        Group {
            if workspace.currentProject != nil, workspace.plainChatProviders.count > 1 {
                Menu {
                    PlainChatProviderChoices(choose: shell.newPlainChat)
                } label: {
                    label()
                }
            } else {
                Button(action: shell.startNewChat, label: label)
            }
        }
        .disabled(!workspace.offersPlainChats || workspace.creating)
        .task(id: workspace.plainChatProviders.map(\.id)) {
            for provider in workspace.plainChatProviders { await workspace.agents.icons.load(provider.id) }
        }
    }
}

/// Shared with the system dialog used after a workspace choice or a keyboard command.
struct PlainChatProviderChoices: View {
    @Environment(WorkspaceModel.self) private var workspace
    let choose: (AgentProvider) -> Void

    var body: some View {
        ForEach(workspace.plainChatProviders) { provider in
            Button {
                choose(AgentProvider(id: provider.id))
            } label: {
                Text(provider.name)
                workspace.agents.icons.menuImage(for: provider.id, fallback: "bubble.left.and.bubble.right")
            }
            .accessibilityIdentifier("chatProvider-" + provider.id)
        }
    }
}
