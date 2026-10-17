#if os(iOS)
import SwiftUI
import UIKit
import AgentLandCore
import AgentLandBranding
import AgentLandDesign

/// The iPhone's bottom tabs; session ownership remains in WorkspaceModel.
enum PhoneTabDestination: String, CaseIterable {
    case chat, terminal, workspace, settings
}

/// A session pushed on its tab's own navigation stack: chats on Chat, terminals on Terminal, editors and browser tabs on
/// Workspace (native-full side build, 2026-10-16). The shell keeps the session on top of the visible tab's stack and
/// `WorkspaceModel.selectedTabID` the same; the stack's root is Home (`selectedTabID == nil`).
struct PhoneSessionRoute: Hashable {
    let tabID: UUID
}

/// The session on top of the Workspace tab's stack, and the stack's depth while it is on top.
struct PhoneStackedSession: Equatable {
    let tabID: UUID
    let depth: Int
}

/// What the iPhone shell follows to keep its stacks and the selection together: the host, the tab in front (and its
/// kind, which a closed tab no longer has) and the open tabs.
struct PhoneSelectionState: Equatable {
    let host: String?
    let selected: UUID?
    let selectedKind: WorkspaceTabKind?
    let tabs: [UUID]
    let workspace: String?
}

/// Workspace's Files or Git page, pushed on the Workspace tab's stack.
struct PhoneToolsRoute: Hashable {
    let section: WorkspacePhoneNavigation.DrawerSection
}

/// Where a session's page is pushed on iPhone.
extension PhoneTabDestination {
    static func hosting(_ kind: WorkspaceTabKind) -> PhoneTabDestination {
        switch kind {
        case .chat, .home: .chat
        case .terminal: .terminal
        case .files, .git, .editor, .browser: .workspace
        }
    }
}

/// Chat's agents (Claude Code and Codex chats in the workspace) stay separate from the programs Terminal launches.
struct PhoneLaunchChoice: Identifiable, Equatable {
    enum Action: Equatable {
        case chat(AgentProvider)
        case terminal(TerminalProgram)
    }

    let id: String
    let title: String
    let action: Action

    static func offered(in destination: PhoneTabDestination, providers: [PlainChatProvider],
                        programs: [TerminalProgram]) -> [Self] {
        switch destination {
        case .chat:
            return [AgentProvider.claude, .codex].compactMap { provider in
                guard providers.contains(where: { $0.id == provider.id }) else { return nil }
                return Self(id: provider.id, title: provider.chatDisplayName, action: .chat(provider))
            }
        case .terminal:
            return [TerminalProgram.claude, .codex].compactMap { program in
                guard programs.contains(where: { $0.id == program.id }) else { return nil }
                return Self(id: program.id, title: program.displayName, action: .terminal(program))
            }
        case .workspace, .settings: return []
        }
    }
}

struct PhoneLaunchButtons: View {
    @Environment(WorkspaceModel.self) private var model
    @Environment(\.workspaceShell) private var shell
    @Environment(\.dynamicTypeSize) private var typeSize
    let destination: PhoneTabDestination

    private var choices: [PhoneLaunchChoice] {
        PhoneLaunchChoice.offered(in: destination, providers: model.plainChatProviders,
                                     programs: TerminalProgram.offered(by: model.capabilities))
    }

    var body: some View {
        Group {
            if choices.isEmpty {
                Text("Claude Code and Codex are unavailable on this Mac.")
                    .foregroundStyle(AgentLandColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 64)
            } else {
                GlassControlGroup(spacing: 12) {
                    ActionCapsuleGrid(columns: typeSize.isAccessibilitySize ? 1 : 2, spacing: 12) {
                        ForEach(choices) { choice in
                            Button {
                                switch choice.action {
                                case let .chat(provider): shell.newPlainChat(provider)
                                case let .terminal(program): shell.newTerminal(program)
                                }
                            } label: {
                                Label {
                                    Text(choice.title)
                                } icon: {
                                    model.agents.icons.menuImage(for: choice.id,
                                        fallback: destination == .chat ? "bubble.left.and.bubble.right" : "terminal")
                                        .resizable().scaledToFit().frame(width: 22, height: 22)
                                }
                                .frame(maxWidth: .infinity, minHeight: 64)
                                .contentShape(Capsule())
                            }
                            .buttonStyle(.plain).glassControl(in: Capsule())
                            .disabled(model.creating || model.locked)
                            .accessibilityIdentifier((destination == .chat ? "phoneChatProvider-" : "phoneTerminalProgram-") + choice.id)
                            .accessibilityHint(destination == .chat ? "Starts a chat in this workspace." : "Starts a terminal session.")
                        }
                    }
                }
            }
        }
        .task(id: "\(model.agents.icons.canLoad)|\(choices.map(\.id).joined(separator: ","))") {
            for choice in choices { await model.agents.icons.load(choice.id) }
        }
    }
}

struct PhoneWorkspaceHome: View {
    @Environment(WorkspaceModel.self) private var model
    @Environment(\.workspaceShell) private var shell
    /// A terminal of another device outside any workspace, on its own screen.
    @State private var standalone: StandaloneTerminalRoute?

    var body: some View {
        // Native rows as the Settings app draws them: titles and symbols in the label colour, `surface`
        // rows with the separator token; Files and Git push their pages with the system's Back.
        List {
            Section("Workspace in use") {
                Button(action: shell.openHomeWorkspacePicker) {
                    ActionRowLabel(model.currentProject?.name ?? "Choose Workspace", systemImage: "folder")
                }.accessibilityIdentifier("phoneChooseWorkspace")
            }.surfaceRows()
            // "On <device>": terminals open on the owner's other devices and on the Mac (owner, 2026-10-15).
            OtherDevicesSections(showStandalone: { standalone = $0 })
            Section {
                NavigationLink(value: PhoneToolsRoute(section: .files)) { ActionRowLabel("Files", systemImage: "folder") }
                    .accessibilityIdentifier("phoneFiles")
                NavigationLink(value: PhoneToolsRoute(section: .git)) { ActionRowLabel("Git", systemImage: "arrow.triangle.branch") }
                    .accessibilityIdentifier("phoneGit")
            }.surfaceRows()
            Section {
                Button { shell.showArchive(false) } label: {
                    ActionRowLabel("Chat History", systemImage: "clock.arrow.circlepath")
                }.accessibilityIdentifier("phoneChatHistory")
            }.surfaceRows()
            Section {
                Button(action: shell.openHomeWorkspacePicker) { ActionRowLabel("Open Workspace…", systemImage: "folder") }
                Button(action: shell.openPicker) { ActionRowLabel("Manage Workspaces", systemImage: "folder.badge.gearshape") }
            }.surfaceRows()
        }
        .listStyle(.insetGrouped).listPageBackground()
        .otherDeviceIcons()
        .accessibilityIdentifier("phoneWorkspaceHome")
        // While the list shows, unlocked and active: at once, then every 4 s (and with the workspace list,
        // `WorkspaceManager.refresh`).
        .readsOtherDevices()
        // Another device's terminal is a terminal's page too: no tab bar.
        .navigationDestination(item: $standalone) { route in
            StandaloneTerminalView(route: route).toolbarVisibility(.hidden, for: .tabBar)
        }
    }
}
/// Hosts without a device archive still retain general chats in their session list.
struct PhoneChatHistory: View {
    @Environment(WorkspaceModel.self) private var model
    let openChat: (String) -> Void
    let done: () -> Void
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                if let issue = model.sidebar.plainLibraryIssue {
                    Text(issue).foregroundStyle(AgentLandColor.textSecondary)
                }
                ForEach((model.sidebar.plainLiveSessions ?? []).filter {
                    query.isEmpty || model.chatName(id: $0.id, listed: $0.title).localizedStandardContains(query)
                }) { chat in
                    Button { openChat(chat.id) } label: {
                        ActionRowLabel(model.chatName(id: chat.id, listed: chat.title), systemImage: "bubble.left.and.bubble.right")
                    }.accessibilityIdentifier("historyChat-" + chat.id)
                }
            }
            .listStyle(.insetGrouped).listPageBackground()
            .navigationTitle("Chat History").workspaceInlineNavigationTitle()
            .searchable(text: $query, prompt: "Search Chats")
            .overlay {
                if model.sidebar.plainLiveSessions?.isEmpty == true && model.sidebar.plainLibraryIssue == nil {
                    ContentUnavailableView("No Chats", systemImage: "bubble.left.and.bubble.right")
                }
            }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done", action: done) } }
            .task { await model.sidebar.refreshPlainSessions() }
            .refreshable { await model.sidebar.refreshPlainSessions() }
        }
    }
}
#endif
