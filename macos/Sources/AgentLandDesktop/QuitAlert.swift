import AppKit
import AgentLandDesktopCore

/// The Quit question: keep running terminals, end them, or stay.
@MainActor enum QuitAlert {
    static func ask(_ count: HostRunningCount) async -> QuitTerminalsChoice {
        let alert = NSAlert()
        alert.messageText = QuitText.title
        alert.informativeText = QuitText.message(count.running, routed: count.routed)
        alert.addButton(withTitle: QuitText.keep)
        let end = alert.addButton(withTitle: QuitText.end)
        end.hasDestructiveAction = true
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\u{1b}"
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .keepRunning
        case .alertSecondButtonReturn: return .endTerminals
        default: return .cancel
        }
    }
}
