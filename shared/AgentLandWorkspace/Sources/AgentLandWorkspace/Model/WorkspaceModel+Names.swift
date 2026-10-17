import Foundation
import AgentLandCore
import AgentLandChat

/// Tab names that follow recent work (docs/HOST-API.md): a terminal keeps its latest context title,
/// else its foreground command, else the label it was created with; a chat shows its current title, or
/// its first prompt while the host still calls it by a default one. Names come live from what this
/// device shows (a terminal's renderer, a chat's stream), and from the host's lists for the rest (other
/// tabs, after reconnects, other devices' changes). Every change is saved with the tabs.
extension WorkspaceModel {
    // MARK: Chats

    /// An open chat's name moved on (`ChatSessionStore.name`): its stream brought a new title, or its first
    /// prompt names it while the host's title is a default.
    func chatNamed(tabID: UUID, _ name: String) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID && $0.kind == .chat }), tabs[index].title != name else { return }
        tabs[index].title = name
        saveTabs()
    }

    /// Names the chat library read (chat ID → name; default titles left out): open chat tabs take them,
    /// except a chat that streams on this device now, whose stream is newer than any list.
    public func followChatNames(_ names: [String: String]) {
        var changed = false
        for index in tabs.indices where tabs[index].kind == .chat {
            guard let name = names[tabs[index].resourceID], !name.isEmpty, tabs[index].title != name else { continue }
            if let store = existingChatStore(tabs[index].id), store.active, store.hasContent { continue }
            tabs[index].title = name
            changed = true
        }
        if changed { saveTabs() }
    }

    /// A chat's name in the sidebar: its open tab's, which follows the chat live, else the library's.
    public func chatName(id: String, listed: String) -> String {
        chatTab(sessionID: id)?.title ?? listed
    }

    /// The host's answer to a naming (`ChatNaming`): open tabs of the chat take its title at once, unless it
    /// is a default one. The chat's stream and the library bring it as well.
    func chatTitleAnswered(chatID: String, _ answer: ChatTitleAnswer) {
        let title = answer.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let agent = AgentProvider.named(ChatSessionStore.provider(forSession: chatID).id, by: capabilities)
        guard answer.titleSource != .default, !ChatSessionStore.isDefaultTitle(title, provider: agent) else { return }
        var changed = false
        for index in tabs.indices where tabs[index].kind == .chat && tabs[index].resourceID == chatID && tabs[index].title != title {
            tabs[index].title = title
            changed = true
        }
        if changed { saveTabs() }
    }

    // MARK: Terminals

    /// A program on this device set a window title, already cleaned, or the host took this device's name for it
    /// (`TerminalSession`): its tab, or its standalone screen, shows it at once. An idle title keeps the latest
    /// context instead of discarding the task.
    func terminalTitleChanged(tabID: UUID, programTitle: String?) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID && $0.kind == .terminal }) else {
            if let programTitle { renameStandalone(tabID, programTitle) }
            return
        }
        let label = tabs[index].label
        let listed = sidebar.terminals?.first { $0.id == tabs[index].resourceID }
        let name = programTitle ?? (tabs[index].title != label ? tabs[index].title : nil) ?? listed?.contextTitle
            ?? listed?.command.flatMap { TerminalTitle.clean($0, label: label) } ?? label
        if renameTerminalTab(at: index, name) { saveTabs() }
    }

    /// The host's terminals of workspace `projectID`, as asked for at `asked`: its open terminal tabs take
    /// the names the list gives, except one whose program set a title on this device after `asked`.
    public func followTerminals(_ terminals: [RemoteTerminal], projectID: String, asked: Date) {
        var changed = false
        for index in tabs.indices where tabs[index].kind == .terminal && tabs[index].projectID == projectID {
            guard let terminal = terminals.first(where: { $0.id == tabs[index].resourceID }) else { continue }
            if let seen = (sessions.existing(tabs[index].id) as? TerminalSession)?.liveTitleAt, seen > asked { continue }
            terminalNameSources[terminal.id] = terminal.contextTitleSource
            if renameTerminalTab(at: index, terminal.displayTitle, label: terminal.title) { changed = true }
        }
        if changed { saveTabs() }
    }

    /// The other devices' terminals (and the Mac's), as "On <device>" read them at `asked` (`OtherDevicesModel`):
    /// tabs and standalone screens that follow one of them take the name the list gives, as `followTerminals` does
    /// for this device's own, so the rows, the tab and its screen say the same.
    func followSharedTerminals(_ terminals: [SharedTerminal], asked: Date) {
        var changed = false
        for terminal in terminals {
            let listed = terminal.remoteTerminal
            for index in tabs.indices where tabs[index].kind == .terminal && tabs[index].resourceID == terminal.id {
                if let seen = (sessions.existing(tabs[index].id) as? TerminalSession)?.liveTitleAt, seen > asked { continue }
                terminalNameSources[terminal.id] = terminal.contextTitleSource
                if renameTerminalTab(at: index, listed.displayTitle, label: terminal.title) { changed = true }
            }
            for (tabID, tab) in standaloneTabs where tab.resourceID == terminal.id {
                if let seen = (sessions.existing(tabID) as? TerminalSession)?.liveTitleAt, seen > asked { continue }
                terminalNameSources[terminal.id] = terminal.contextTitleSource
                renameStandalone(tabID, listed.displayTitle)
            }
        }
        if changed { saveTabs() }
    }

    /// A standalone terminal's screen names it as a tab would (`TerminalSession.shownTitle`); its tab keeps the name
    /// for when the screen opens again or the terminal moves into a workspace.
    private func renameStandalone(_ tabID: UUID, _ name: String) {
        guard var tab = standaloneTabs[tabID] else { return }
        if tab.creationLabel == nil { tab.creationLabel = tab.title }
        tab.title = name
        standaloneTabs[tabID] = tab
        if let session = sessions.existing(tabID) as? TerminalSession, session.shownTitle != name { session.shownTitle = name }
    }

    /// The name terminal tab `tabID` shows now, as a tab or on its standalone screen.
    func terminalTabTitle(_ tabID: UUID) -> String? {
        (tabs.first { $0.id == tabID } ?? standaloneTabs[tabID])?.title
    }

    /// A terminal's name in the sidebar: its open tab's, which follows the program live, else the host's.
    public func terminalName(_ terminal: RemoteTerminal) -> String {
        tabs.first { $0.kind == .terminal && $0.resourceID == terminal.id }?.title ?? terminal.displayTitle
    }

    /// Names terminal tab `index`, keeping the label it was created with; false when nothing changed.
    private func renameTerminalTab(at index: Int, _ name: String, label: String? = nil) -> Bool {
        var tab = tabs[index]
        if tab.creationLabel == nil { tab.creationLabel = label ?? tab.title }
        tab.title = name
        guard tab != tabs[index] else { return false }
        tabs[index] = tab
        return true
    }
}
