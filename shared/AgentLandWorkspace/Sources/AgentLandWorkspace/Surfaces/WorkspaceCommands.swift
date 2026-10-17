import SwiftUI
import AgentLandCore

/// What the workspace in the focused window can do from the keyboard and the menu bar. The shell
/// publishes it with `focusedSceneValue`; `WorkspaceCommands` reads it. A nil action is not available
/// now (its menu item is disabled).
public struct WorkspaceCommandActions {
    /// A general-purpose conversation; unavailable when the host lacks Chat.
    public var newChat: (@MainActor () -> Void)?
    /// Retained for source compatibility; never populated by the app.
    public var newChatWith: (@MainActor () -> Void)?
    /// Whether general-purpose Chat is available.
    public var offersPlainChats = false
    public var newHomeTab: (@MainActor () -> Void)?
    public var newTerminal: (@MainActor () -> Void)?
    public var closeTab: (@MainActor () -> Void)?
    public var selectTab: (@MainActor (Int) -> Void)?
    public var tabCount = 0
    public var nextTab: (@MainActor () -> Void)?
    public var previousTab: (@MainActor () -> Void)?
    public var find: (@MainActor () -> Void)?
    public var search: (@MainActor () -> Void)?
    public var reload: (@MainActor () -> Void)?
    public var regenerate: (@MainActor () -> Void)?
    public var stop: (@MainActor () -> Void)?
    public var send: (@MainActor () -> Void)?
    /// Commits what is staged, from the Git surface's commit bar.
    public var commit: (@MainActor () -> Void)?
    public var save: (@MainActor () -> Void)?
    public var toggleSidebar: (@MainActor () -> Void)?
    public var textBigger: (@MainActor () -> Void)?
    public var textSmaller: (@MainActor () -> Void)?
    public var textActualSize: (@MainActor () -> Void)?
    public var settings: (@MainActor () -> Void)?

    public init() {}
}

/// What the shell gives the commands besides the model: its own actions and state.
struct WorkspaceCommandShell {
    /// Runs the action once a workspace is open, asking for one first when none is.
    var withWorkspace: @MainActor (_ action: @escaping @MainActor () -> Void) -> Void = { $0() }
    var create: @MainActor (_ kind: WorkspaceTabKind, _ program: TerminalProgram, _ provider: AgentProvider) -> Void = { _, _, _ in }
    /// Starts a plain chat, which needs no workspace.
    var newPlainChat: @MainActor () -> Void = {}
    /// Legacy shell hook, no longer invoked.
    var chooseProvider: @MainActor () -> Void = {}
    var focusSearch: @MainActor () -> Void = {}
    var showSettings: @MainActor () -> Void = {}
    var stepTextSize: @MainActor (_ delta: Int) -> Void = { _ in }
    var resetTextSize: @MainActor () -> Void = {}
    /// Steps from the system's text size (⌘+ and ⌘−).
    var textSizeStep = 0
    /// A sheet or a question covers the surfaces.
    var obscured = false
}

extension WorkspaceCommandActions {
    /// The commands for `model`'s surface in front: creation needs the host's workspaces (a plain chat none),
    /// Close Tab a tab, Save an editor with changes, Send, Stop and Regenerate a chat that can, Commit a Git
    /// surface with something staged and no diff open.
    @MainActor static func make(model: WorkspaceModel, shell: WorkspaceCommandShell) -> WorkspaceCommandActions {
        var actions = WorkspaceCommandActions()
        let hasProjects = !model.projects.isEmpty && !model.creating
        actions.offersPlainChats = model.offersPlainChats
        if model.offersPlainChats, !model.creating {
            actions.newChat = { shell.newPlainChat() }
        }
        if hasProjects {
            actions.newHomeTab = { shell.withWorkspace(model.openHomeTab) }
            if model.capabilities?.terminal == true {
                actions.newTerminal = { shell.create(.terminal, .shell, .opencode) }
            }
        }
        let tab = model.currentTab
        if let tab { actions.closeTab = { model.close(tab.id) } }
        actions.tabCount = model.tabOrder.count
        actions.selectTab = { number in model.selectTab(number: number) }
        if model.tabOrder.count > 1 {
            actions.nextTab = { model.selectAdjacentTab(forward: true) }
            actions.previousTab = { model.selectAdjacentTab(forward: false) }
        }
        actions.search = { shell.focusSearch() }
        actions.settings = { shell.showSettings() }
        actions.textBigger = { shell.stepTextSize(1) }
        actions.textSmaller = { shell.stepTextSize(-1) }
        if shell.textSizeStep != 0 { actions.textActualSize = { shell.resetTextSize() } }
        if let tab {
            actions.reload = { model.reloadTab(tab.id) }
        } else {
            actions.reload = { Task { await model.refreshProjects() } }
        }
        guard let tab else { return actions }
        switch tab.kind {
        case .files:
            actions.find = { model.requestFind() }
        case .editor:
            actions.find = { model.requestFind() }
            if let session = model.sessions.existing(tab.id) as? EditorSession, session.canSave {
                actions.save = { Task { await session.save() } }
            }
        case .chat:
            if model.supportsTab(tab), let store = model.existingChatStore(tab.id), !shell.obscured {
                if store.isWorking {
                    actions.stop = { Task { await store.stop() } }
                } else if store.sendEnabled && store.interactions.isEmpty {
                    // A pending question card answers with ⌘↩ itself.
                    actions.send = { Task { await store.send() } }
                }
                if store.canRunAgain { actions.regenerate = { model.requestRunAgain() } }
            }
        case .git:
            if let session = model.sessions.existing(tab.id) as? GitSession, session.canCommit, session.diff == nil, !shell.obscured {
                actions.commit = { Task { await session.commit() } }
            }
        case .home, .terminal, .browser:
            break
        }
        return actions
    }
}

extension FocusedValues {
    /// The focused window's workspace commands.
    @Entry public var workspaceCommands: WorkspaceCommandActions?
}

/// The workspace's commands in the iPadOS and Mac menu bars, with their keyboard shortcuts. The
/// terminal passes ⌘-combinations other than C, V and A up to them.
///
/// Settings… (⌘,) routes the focused workspace to Home and opens its shared drawer. ⌘W closes the tab
/// in front, or the window when no tab is (the permanent Home); ⇧⌘W closes the window on Mac.
public struct WorkspaceCommands: Commands {
    @FocusedValue(\.workspaceCommands) private var actions

    public init() {}

    public var body: some Commands {
        CommandGroup(replacing: .newItem) {
            item("New Chat", actions?.newChat).keyboardShortcut("n", modifiers: .command)
            item("New Home Tab", actions?.newHomeTab).keyboardShortcut("t", modifiers: .command)
            item("New Terminal", actions?.newTerminal).keyboardShortcut("t", modifiers: [.command, .option])
            Divider()
            #if os(macOS)
            Button(actions?.closeTab == nil ? "Close" : "Close Tab") {
                if let close = actions?.closeTab { close() } else { WorkspacePlatform.closeKeyWindow() }
            }
            .keyboardShortcut("w", modifiers: .command)
            Button("Close Window") { WorkspacePlatform.closeKeyWindow() }
                .keyboardShortcut("w", modifiers: [.command, .shift])
            #else
            item("Close Tab", actions?.closeTab).keyboardShortcut("w", modifiers: .command)
            #endif
        }
        CommandGroup(replacing: .saveItem) {
            item("Save", actions?.save).keyboardShortcut("s", modifiers: .command)
        }
        #if os(macOS)
        CommandGroup(replacing: .appSettings) {
            item("Settings…", actions?.settings).keyboardShortcut(",", modifiers: .command)
        }
        #endif
        CommandGroup(after: .pasteboard) {
            Divider()
            item("Find", actions?.find).keyboardShortcut("f", modifiers: .command)
            item("Search Workspace", actions?.search).keyboardShortcut("f", modifiers: [.command, .shift])
        }
        CommandGroup(before: .toolbar) {
            item("Reload", actions?.reload).keyboardShortcut("r", modifiers: .command)
            Divider()
            item("Bigger Text", actions?.textBigger).keyboardShortcut("+", modifiers: .command)
            item("Smaller Text", actions?.textSmaller).keyboardShortcut("-", modifiers: .command)
            item("Actual Size", actions?.textActualSize).keyboardShortcut("0", modifiers: .command)
            Divider()
        }
        CommandMenu("Chat") {
            // ⌘↩ is Commit's while the Git surface can commit: one shortcut on two items reaches neither.
            item("Send", actions?.send).keyboardShortcut(actions?.commit == nil ? KeyboardShortcut(.return, modifiers: .command) : nil)
            item("Stop", actions?.stop).keyboardShortcut(".", modifiers: .command)
            item("Regenerate", actions?.regenerate).keyboardShortcut("r", modifiers: [.command, .shift])
        }
        CommandMenu("Git") {
            item("Commit", actions?.commit).keyboardShortcut(actions?.commit == nil ? nil : KeyboardShortcut(.return, modifiers: .command))
        }
        CommandMenu("Tabs") {
            item("Next Tab", actions?.nextTab).keyboardShortcut(.tab, modifiers: .control)
            item("Previous Tab", actions?.previousTab).keyboardShortcut(.tab, modifiers: [.control, .shift])
            Divider()
            ForEach(1...9, id: \.self) { number in
                Button(number == 9 ? "Last Tab" : number == 1 ? "Home" : "Tab \(number)") { actions?.selectTab?(number) }
                    .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: .command)
                    .disabled(actions?.selectTab == nil || (number != 9 && number > (actions?.tabCount ?? 0)))
            }
        }
    }

    private func item(_ title: String, _ action: (@MainActor () -> Void)?) -> some View {
        Button(title) { action?() }.disabled(action == nil)
    }
}
