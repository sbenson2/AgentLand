import Foundation
import AgentLandCore
import AgentLandChat

/// Names only rendered output, never keystrokes (`TerminalContextNamer`). One pending job per terminal: output that
/// settled for 5 s is read, and the model asked again only when the screen's newest request changed, or at most every
/// 30 s while its meaningful output changes (`TerminalNamingSchedule`); unavailable models, and names the screen does
/// not support, give way to a conservative excerpt of a typed task or a known command.
@MainActor final class TerminalNaming {
    private weak var session: TerminalSession?
    private weak var workspace: WorkspaceModel?
    private var worker: Task<Void, Never>?
    private var pending = false
    private var schedule = TerminalNamingSchedule()

    init(session: TerminalSession, workspace: WorkspaceModel?) {
        self.session = session; self.workspace = workspace
    }

    func stop() { pending = false; worker?.cancel(); worker = nil }

    func outputDrawn() {
        guard allowed else { return }
        pending = true
        guard worker == nil else { return }
        worker = Task { [weak self] in
            defer { self?.worker = nil }
            while let self, self.pending, !Task.isCancelled {
                self.pending = false
                do { try await Task.sleep(for: .seconds(TerminalNamingSchedule.debounce)) } catch { return }
                // Output changed sooner than the model may be asked again: the screen is read once more then.
                if let wait = await self.name() {
                    do { try await Task.sleep(for: .seconds(wait)) } catch { return }
                    self.pending = true
                }
            }
        }
    }

    private var allowed: Bool {
        session?.active == true && workspace?.naming.inForeground == true
            && workspace?.reachable == true && workspace?.locked == false
            && workspace?.capabilities?.terminalFeatures.contains("title") == true
            && workspace?.naming.lowPowerMode() == false
    }

    /// Names the terminal when its schedule says so. The seconds until the screen is worth reading again when its
    /// output changed too soon, else nil.
    private func name() async -> TimeInterval? {
        guard allowed, let session, let workspace, let client = workspace.client,
              let snapshot = session.namingSnapshot() else { return nil }
        let screen = TerminalScreen(lines: snapshot.lines)
        switch schedule.due(screen, now: snapshot.at) {
        case .no: return nil
        case let .after(seconds): return seconds
        case .now: schedule.asked(screen, at: snapshot.at)
        }
        // The name it has of its own, which the model keeps while it fits: not its program's name or creation label,
        // and not a title the host says its program set (a folder's name, a passing status), which no model name has
        // to stay close to.
        let shown = workspace.terminalTabTitle(session.tabID).flatMap { TerminalTitle.clean($0, label: session.label) }
        let current = workspace.terminalNameSources[session.terminalID] == .program ? nil : shown
        let namer = TerminalContextNamer(namer: workspace.naming.namer)
        let model = Task.detached(priority: .utility) { await namer.name(for: screen, current: current) }
        let title = await withTaskCancellationHandler { await model.value } onCancel: { model.cancel() }
        // The name it shows already: sending it would change nothing.
        guard !Task.isCancelled, allowed, workspace.client === client, let title,
              !TerminalNameRules.sameName(title, shown) else { return nil }
        let outcome = await client.nameTerminal(projectID: session.projectID, terminalID: session.terminalID,
                                                title: title, basedOn: snapshot.cursor)
        guard !Task.isCancelled, allowed, workspace.client === client, outcome == .accepted else { return nil }
        session.contextTitleAnswered(title, readAt: snapshot.at)
        return nil
    }
}
