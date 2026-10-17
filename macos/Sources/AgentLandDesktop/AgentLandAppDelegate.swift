import AppKit

@MainActor
final class AgentLandAppDelegate: NSObject, NSApplicationDelegate {
    private var host: HostController { HostController.shared }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The workspace follows the host's session from launch on, whether or not a window shows it.
        _ = DesktopWorkspace.shared
        host.load()
        host.startMonitoring()
        // Whether or not the switch is on: what an earlier run left on the router goes.
        host.remoteAccess.activate()
        // Names every terminal while Settings → General's Apple Intelligence is on.
        host.terminalNaming.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard host.requiresShutdown else { return .terminateNow }
        let host = host
        Task { [weak self, host] in
            // First: stopping the host clears the session the question needs.
            guard await host.prepareQuit(ask: QuitAlert.ask) else {
                sender.reply(toApplicationShouldTerminate: false)
                return
            }
            do {
                try await host.stopForApplicationTermination()
                sender.reply(toApplicationShouldTerminate: true)
            } catch {
                self?.host.deliberateQuit = false
                self?.host.presentTerminationError(error)
                sender.reply(toApplicationShouldTerminate: false)
            }
        }
        return .terminateLater
    }
}
