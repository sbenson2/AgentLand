import Foundation

/// The `.command` file Open in Terminal (Settings → Terminals) gives Terminal: it replaces its shell with
/// `agentland-host terminals attach`, which shows the running terminal in that window. Each path and the ID are one
/// single-quoted word, so spaces and quotes in them stay as they are.
public enum TerminalAttachScript {
    public static func contents(binary: String, statePath: String, terminalID: String) -> String {
        "#!/bin/zsh\nexec \(quoted(binary)) terminals attach --state \(quoted(statePath)) \(quoted(terminalID))\n"
    }

    /// `text` in single quotes, each `'` in it written `'\''`.
    static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
