import Foundation
import AgentLandCore

/// What an ended terminal says about when and why it ended (docs/HOST-API.md "How terminals end"). Hosts that
/// do not record it, and terminals the host no longer knows, get a plain statement instead of a guess.
enum TerminalEndText {
    /// `gone`: the host no longer has the terminal (`terminal_not_found`). `label` is the terminal's creation
    /// label ("Claude Code", "Terminal").
    static func description(_ ended: TerminalEnd?, label: String, gone: Bool, now: Date = Date(), calendar: Calendar = .current) -> String {
        let program = programName(ended?.program, label: label)
        guard let ended, let reason = ended.reason else {
            if gone { return "AgentLand on the Mac no longer has this terminal and didn’t record how it ended." }
            if let code = ended?.exitCode, code != 0 { return "\(program) ended with code \(code)." }
            return "\(program) ended."
        }
        let when = ended.at.map { " " + moment($0, now: now, calendar: calendar) } ?? ""
        switch reason {
        case .programExited:
            if let code = ended.exitCode, code != 0 { return "\(program) exited\(when) with code \(code)." }
            return "\(program) exited\(when)."
        case .backendEnded:
            // OpenCode, which runs the Mac's terminals, ended it; the program itself did not exit.
            return "OpenCode on the Mac closed it\(when)."
        case .endedByDevice:
            return "It was ended from \(ended.device ?? "a device")\(when)."
        case .workspaceRemoved:
            return "Its workspace was removed from AgentLand\(when)."
        case .hostStopped:
            return "It ended when AgentLand on the Mac stopped\(when)."
        case .hostInterrupted:
            let last = ended.at.map { " Its last output was " + moment($0, now: now, calendar: calendar) + "." } ?? ""
            return "It ended when AgentLand on the Mac quit unexpectedly.\(last)"
        case .connectionLost:
            return "AgentLand on the Mac lost its connection to it\(when)."
        case .keeperStopped:
            return "It ended when the Mac restarted or logged out, or AgentLand's terminal service stopped\(when)."
        case .endedOnMac:
            return "It was ended from AgentLand on the Mac\(when)."
        case .deviceRemoved:
            return "Its device was removed from AgentLand on the Mac\(when)."
        case .keptInTerminal:
            // A coding agent typed in Terminal.app, released to its Terminal window, where it runs on.
            return "It keeps running in Terminal on the Mac; AgentLand stopped following it\(when)."
        }
    }

    /// "at 4:41 AM" today, else "on Oct 13 at 4:41 AM".
    static func moment(_ date: Date, now: Date, calendar: Calendar) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return "at \(time)" }
        return "on \(date.formatted(.dateTime.month(.abbreviated).day())) at \(time)"
    }

    private static func programName(_ program: String?, label: String) -> String {
        if program == TerminalProgram.shell.id || (program == nil && label == TerminalProgram.shell.terminalTitle) { return "The shell" }
        if let known = TerminalProgram.known.first(where: { $0.id == program }) { return known.terminalTitle }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "The program" : trimmed
    }
}

/// What ending a terminal asks first (the terminal menu's End). A terminal another device opened, or the Mac, says
/// where it runs: ending it there stops its program for everyone who follows it. This device's own keep the question
/// they always asked.
enum TerminalEndConfirmation {
    static func title(_ tab: WorkspaceTab) -> String {
        tab.sharedFrom == nil ? "End this terminal on the host?" : "End “\(tab.title)”?"
    }

    static func message(_ origin: SharedOrigin?, hostName: String) -> String {
        guard let origin else { return "This stops the terminal session on your Mac. Unsaved work may be lost." }
        if origin.routed { return "It's running in Terminal on \(hostName). Ending it stops the program." }
        if origin.onMac { return "It's running in AgentLand on \(hostName). Ending it stops the program." }
        return "It's open on \(OtherDevicesModel.deviceLabel(origin.deviceName)). Ending it stops the program."
    }
}
