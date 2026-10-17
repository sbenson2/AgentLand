import SwiftUI
import AgentLandDesign
import AgentLandWorkspace
import AgentLandDesktopCore

/// The Terminals pane's words, apart from the view so the tests read them.
enum TerminalsText {
    static let notRunningTitle = "AgentLand isn't running"
    static let notRunningDetail = "Start the server to see its terminals."
    static let offTitle = "Terminal access is off"
    static let offDetail = "Turn on terminal access above to run terminals from your devices."

    /// The host's reason is its own full sentence, so it replaces this one rather than following it.
    static func unavailable(reason: String?) -> String {
        guard let reason, !reason.isEmpty else { return "AgentLand's terminal service isn't answering. Your terminals are still running." }
        return reason
    }

    /// What the "Terminals on this Mac" section holds: nothing at all while terminal access is off (the off notice
    /// says it all), the rows, "No terminals", a spinner while the first read runs, or nothing after a failed read
    /// (the notice above says why).
    enum ListContent: Equatable { case hidden, rows, empty, loading, issue }
    static func listContent(off: Bool, terminals: [HostTerminal]?, issue: String?) -> ListContent {
        if off { return .hidden }
        if let terminals { return terminals.isEmpty ? .empty : .rows }
        return issue == nil ? .loading : .issue
    }

    /// A terminal runs when the host says so; it omits `endedAt` when the end time is unknown.
    static func isRunning(_ t: HostTerminal) -> Bool { t.status == "running" }

    /// What the End… dialog says. The Mac's own terminals, and a removed device's, stop on this Mac only; a routed agent
    /// also in its Terminal window.
    static func endMessage(_ t: HostTerminal) -> String {
        // A coding agent typed in Terminal also loses its Terminal window.
        let tail = t.routed ? " and in its Terminal window" : ""
        if t.deviceRemoved || t.deviceName == "This Mac" { return "It stops on this Mac\(tail)." }
        return "It stops on this Mac\(tail) and on \(t.deviceName)."
    }

    /// "Sam’s iPhone · tower · running for 2 h", or "… · finished 3 h ago". A removed device says so. An agent typed in
    /// Terminal says that, and its workspace or that it has none: "This Mac · Terminal · No workspace · running for 2 h".
    static func caption(_ t: HostTerminal, now: Date) -> String {
        let device = t.deviceRemoved ? t.deviceName + " (removed)" : t.deviceName
        let timing: String
        if let ended = t.endedAt {
            timing = "finished \(duration(now.timeIntervalSince(ended))) ago"
        } else {
            timing = "running for \(duration(now.timeIntervalSince(t.startedAt)))"
        }
        if t.routed {
            return [device, "Terminal", t.workspace.isEmpty ? "No workspace" : t.workspace, timing]
                .filter { !$0.isEmpty }.joined(separator: " · ")
        }
        return [device, t.workspace, timing].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    static let openInTerminal = "Open in Terminal"
    static let actionFailedTitle = "Couldn’t change the terminal"
    static let openFailedTitle = "Couldn’t open it in Terminal"
    /// The pane's action error when Terminal could not open one.
    static func openFailed(_ reason: String) -> String { "Terminal couldn’t open it. \(reason)" }

    private static func duration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 1
        formatter.allowedUnits = [.day, .hour, .minute, .second]
        return formatter.string(from: max(0, seconds)) ?? "a moment"
    }
}

/// Settings → Terminals: terminal access and the routing switch under it (from Advanced, 2026-10-16), then every
/// terminal on this Mac across devices in a list. Open in Terminal and End… for a running one, Clear for a finished
/// one, under the list and in its context menu. It never shows what a terminal printed.
struct TerminalsSettingsPane: View {
    @EnvironmentObject private var host: HostController
    @State private var ending: HostTerminal?
    @State private var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = host.errorMessage { SettingsErrorText(message: error) }
            Group {
                TerminalAccessToggle()
                TerminalRoutingToggle()
                    .padding(.bottom, 8)
            }
            .disabled(host.isWorking)
            terminals
        }
        // The routing switch's older-keeper note reads the Mac's terminals list, which only a follow keeps current.
        .task { await host.followRoutingKeeper() }
        .alert(host.terminalActionErrorTitle, isPresented: Binding(get: { host.terminalActionError != nil },
                                                                   set: { if !$0 { host.dismissTerminalActionError() } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(host.terminalActionError ?? "")
        }
        .confirmationDialog("End “\(ending.map(Self.title) ?? "")”?", isPresented: endShown, titleVisibility: .visible,
                            presenting: ending) { terminal in
            Button("End", role: .destructive) { Task { await host.endTerminal(terminal.id) } }
            Button("Cancel", role: .cancel) {}
        } message: { terminal in
            Text(TerminalsText.endMessage(terminal))
        }
    }

    @ViewBuilder private var terminals: some View {
        if host.status != .running {
            placeholder {
                ContentUnavailableView(TerminalsText.notRunningTitle, systemImage: "terminal",
                                       description: Text(TerminalsText.notRunningDetail))
            }
        } else {
            if let keeper = host.terminalList?.keeper, keeper.state == "unavailable", !host.terminalsOff {
                MacSettingsStateLine("Terminals aren’t available. " + TerminalsText.unavailable(reason: keeper.reason))
            }
            switch TerminalsText.listContent(off: host.terminalsOff, terminals: host.terminalList?.terminals,
                                              issue: host.terminalsIssue) {
            case .hidden:
                placeholder {
                    ContentUnavailableView(TerminalsText.offTitle, systemImage: "terminal",
                                           description: Text(TerminalsText.offDetail))
                }
            case .rows:
                list(host.terminalList?.terminals ?? [])
            case .empty:
                placeholder {
                    ContentUnavailableView("No Terminals", systemImage: "terminal",
                                           description: Text("Terminals started from your devices show here."))
                }
            case .loading:
                placeholder { ProgressView().controlSize(.small) }
            case .issue:
                placeholder {
                    ContentUnavailableView("Couldn’t Read the Terminals", systemImage: "exclamationmark.triangle",
                                           description: Text(host.terminalsIssue ?? ""))
                }
            }
            if let issue = host.terminalsIssue, host.terminalList != nil {
                // The list shown is from the last read that worked.
                MacSettingsStateLine("Couldn’t read the terminals again. \(issue)")
            }
            buttons
        }
    }

    /// What shows in the list's place, in the list's frame.
    private func placeholder<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        MacSettingsListBox(content: content)
            .frame(height: MacSettingsMetrics.listHeight)
    }

    private func list(_ terminals: [HostTerminal]) -> some View {
        List(selection: $selection) {
            ForEach(terminals) { terminal in row(terminal).tag(terminal.id) }
        }
        .listStyle(.bordered)
        .alternatingRowBackgrounds()
        .contextMenu(forSelectionType: String.self) { ids in
            if let terminal = terminal(ids.first) { actions(terminal) }
        } primaryAction: { ids in
            if let terminal = terminal(ids.first), TerminalsText.isRunning(terminal) {
                Task { await host.openInTerminal(terminal.id) }
            }
        }
        .frame(height: MacSettingsMetrics.listHeight)
    }

    /// The selected terminal's actions: Open in Terminal and End… while it runs, Clear once it has finished.
    private var buttons: some View {
        let selected = terminal(selection)
        let running = selected.map(TerminalsText.isRunning) ?? false
        return HStack(spacing: 8) {
            Spacer()
            Button("Clear") { if let selected { Task { await host.clearTerminal(selected.id) } } }
                .disabled(selected == nil || running)
                .accessibilityIdentifier("terminalsClear")
            Button("End…") { ending = selected }
                .disabled(!running)
                .accessibilityIdentifier("terminalsEnd")
            Button(TerminalsText.openInTerminal) { if let selected { Task { await host.openInTerminal(selected.id) } } }
                .disabled(!running)
                .accessibilityIdentifier("terminalsOpen")
        }
    }

    @ViewBuilder private func actions(_ terminal: HostTerminal) -> some View {
        if TerminalsText.isRunning(terminal) {
            Button(TerminalsText.openInTerminal) { Task { await host.openInTerminal(terminal.id) } }
            Divider()
            Button("End…", role: .destructive) { ending = terminal }
        } else {
            Button("Clear") { Task { await host.clearTerminal(terminal.id) } }
        }
    }

    private func terminal(_ id: String?) -> HostTerminal? {
        guard let id else { return nil }
        return host.terminalList?.terminals.first { $0.id == id }
    }

    private static func title(_ t: HostTerminal) -> String {
        if !t.title.isEmpty { return t.title }
        return t.program.isEmpty ? "Terminal" : t.program
    }

    /// The title and caption read as one element.
    private func row(_ terminal: HostTerminal) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(Self.title(terminal))
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(TerminalsText.caption(terminal, now: context.date)).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var endShown: Binding<Bool> {
        Binding(get: { ending != nil }, set: { if !$0 { ending = nil } })
    }
}

/// The terminal-access switch. Turning it off while terminals run, or when the host can't say whether any
/// do, asks first and ends them all; with none running it turns off at once. Either way a running host
/// restarts with terminals off; with no host running only the setting changes.
private struct TerminalAccessToggle: View {
    @EnvironmentObject private var host: HostController
    @State private var running: Int?
    @State private var routed = 0
    @State private var asking = false
    @State private var offCheck: Task<Void, Never>?

    var body: some View {
        HStack {
        Toggle(MacSettings.terminals.title, isOn: Binding(
            get: { host.terminalEnabled },
            set: { on in
                offCheck?.cancel()
                guard !on, host.terminalEnabled else {
                    if on { host.turnTerminalsOn() } else { host.terminalEnabled = on }
                    return
                }
                offCheck = Task {
                    let step = await host.terminalsOffStep()
                    guard !Task.isCancelled else { return }
                    switch step {
                    case let .ask(count, routedCount):
                        running = count
                        routed = routedCount
                        asking = true
                    case .turnOff:
                        await host.turnTerminalsOffNow()
                    }
                }
            }))
            .confirmationDialog(AdvancedText.endTerminalsTitle, isPresented: $asking, titleVisibility: .visible) {
                Button(AdvancedText.endTerminals, role: .destructive) { Task { await host.turnOffTerminals() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(AdvancedText.endTerminalsMessage(running, routed: routed))
            }
            .disabled(host.endingTerminals)
            if host.endingTerminals { ProgressView().controlSize(.small) }
        }
    }
}

/// The switch that opens coding agents typed in Terminal in AgentLand (`terminals hook`), under terminal access, which
/// it needs: while that is off the switch can't change and keeps its state, paused. What it does is under its title,
/// with a note when the login shell isn't zsh; why the last change failed is the system's alert.
private struct TerminalRoutingToggle: View {
    @EnvironmentObject private var host: HostController
    /// Read once: the login shell rarely changes while the app runs.
    private static let shellNote = AdvancedText.routingShellNote(loginShell: AdvancedText.loginShell())

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Toggle(isOn: Binding(get: { host.terminalRoutingEnabled },
                                 set: { on in Task { await host.setTerminalRouting(on) } })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(MacSettings.terminalRouting.title)
                    MacSettingsFootnote(AdvancedText.routingFootnote)
                    if let note = AdvancedText.routingNote(terminalAccess: host.terminalEnabled, routing: host.terminalRoutingEnabled,
                                                           keeper: host.terminalList?.keeper) {
                        MacSettingsFootnote(note)
                    }
                    if let shellNote = Self.shellNote { MacSettingsFootnote(shellNote) }
                }
            }
            .disabled(host.terminalRoutingSwitchDisabled)
            if host.changingTerminalRouting { ProgressView().controlSize(.small) }
        }
        .alert(AdvancedText.routingIssueTitle, isPresented: Binding(get: { host.terminalRoutingIssue != nil },
                                                                    set: { if !$0 { host.dismissTerminalRoutingIssue() } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(host.terminalRoutingIssue ?? "")
        }
    }
}
