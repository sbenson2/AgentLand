import Foundation
import AgentLandCore

/// What a tool call does, from the provider's own tool name. OpenCode,
/// Claude Code and Codex name the same kinds of work differently.
public enum ChatToolKind: String, CaseIterable, Sendable {
    case read, edit, command, search, web, plan, subagent, question, other

    public init(toolName: String) {
        var name = toolName.lowercased()
        // MCP tools arrive as "server/tool" or "mcp__server__tool".
        if let last = name.split(whereSeparator: { $0 == "/" }).last { name = String(last) }
        if name.hasPrefix("mcp__"), let last = name.components(separatedBy: "__").last { name = last }
        name = name.replacingOccurrences(of: "-", with: "_")
        switch name {
        case "read", "view", "cat", "viewimage", "read_file", "readfile", "notebookread", "open":
            self = .read
        case "edit", "write", "patch", "multiedit", "apply_patch", "applypatch", "str_replace", "str_replace_editor",
             "create", "notebookedit", "filechange", "file_change", "edit_file", "write_file":
            self = .edit
        case "bash", "shell", "command", "exec", "run", "terminal", "local_shell", "execute", "commandexecution":
            self = .command
        case "grep", "glob", "search", "find", "list", "ls", "codesearch", "rg", "file_search":
            self = .search
        case "webfetch", "fetch", "websearch", "web_search", "web", "web_fetch", "browse":
            self = .web
        case "todowrite", "todoread", "todo", "plan", "update_plan", "exitplanmode", "todo_write":
            self = .plan
        case "task", "agent", "subagent", "spawn", "spawn_agent":
            self = .subagent
        case "question", "askuserquestion", "ask", "request_user_input", "ask_user":
            self = .question
        default:
            self = .other
        }
    }

    /// SF Symbol for the kind; state is shown separately, never by color alone.
    public var symbol: String {
        switch self {
        case .read: "doc.text"
        case .edit: "pencil"
        case .command: "apple.terminal"
        case .search: "magnifyingglass"
        case .web: "globe"
        case .plan: "checklist"
        case .subagent: "person.2"
        case .question: "questionmark.bubble"
        case .other: "wrench.and.screwdriver"
        }
    }
}

/// A tool call's state as the transcript shows it.
public enum ChatToolState: Equatable, Sendable {
    case preparing, running, waitingForApproval, waitingForAnswer, succeeded, failed, denied, interrupted

    public var symbol: String? {
        switch self {
        case .preparing, .running: nil // a spinner
        case .waitingForApproval: "hand.raised"
        case .waitingForAnswer: "questionmark.circle"
        case .succeeded: "checkmark"
        case .failed: "exclamationmark.triangle"
        case .denied: "nosign"
        case .interrupted: "pause.circle"
        }
    }

    /// The text that pairs with the symbol.
    public var label: String {
        switch self {
        case .preparing: "Preparing"
        case .running: "Running"
        case .waitingForApproval: "Waiting for approval"
        case .waitingForAnswer: "Waiting for your answer"
        case .succeeded: "Done"
        case .failed: "Failed"
        case .denied: "Denied"
        case .interrupted: "Interrupted"
        }
    }

    public var isActive: Bool { self == .preparing || self == .running }
}

/// A humanized tool row: the kind's symbol, a verb phrase and the target.
public struct ChatToolSummary: Equatable, Sendable {
    public let kind: ChatToolKind
    public let name: String
    /// The file, command, pattern or address the call works on, if known.
    public let target: String?
    public let state: ChatToolState

    public init(_ tool: ConversationTool, interrupted: Bool = false, waiting: ChatToolState? = nil) {
        kind = ChatToolKind(toolName: tool.name)
        name = tool.name
        target = ChatToolSummary.target(for: kind, tool: tool)
        if let waiting {
            state = waiting
        } else {
            switch tool.status {
            case .pending: state = interrupted ? .interrupted : .preparing
            case .running: state = interrupted ? .interrupted : .running
            case .completed: state = .succeeded
            case .error: state = ChatToolSummary.isDenial(tool.error) ? .denied : .failed
            }
        }
    }

    /// "Read `LoginView.swift`", "Running `npm test`…", "Searched for "redirect"".
    public var phrase: String {
        let active = state.isActive || state == .waitingForApproval || state == .waitingForAnswer
        let quoted = target.map { "`\($0)`" }
        func phrase(_ present: String, _ past: String, _ object: String?) -> String {
            let verb = active ? present : past
            let text = object.map { "\(verb) \($0)" } ?? verb
            return active && state.isActive ? text + "…" : text
        }
        switch kind {
        case .read: return phrase("Reading", "Read", quoted ?? "a file")
        case .edit: return phrase("Editing", "Edited", quoted ?? "a file")
        case .command: return phrase("Running", "Ran", quoted ?? "a command")
        case .search: return phrase("Searching", "Searched", target.map { "for “\($0)”" })
        case .web: return phrase("Fetching", "Fetched", quoted)
        case .plan: return phrase("Updating plan", "Updated plan", nil)
        case .subagent: return phrase("Delegating", "Delegated", target.map { "“\($0)”" })
        case .question: return phrase("Asking", "Asked", "a question")
        case .other: return phrase("Using", "Used", "`\(name)`")
        }
    }

    /// Group summaries count by kind: "Read 4 files · Edited 2 · Ran 3 commands".
    public static func groupSummary(_ tools: [ChatToolSummary], reasoning: Int = 0) -> String {
        var counts: [ChatToolKind: Int] = [:]
        for tool in tools { counts[tool.kind, default: 0] += 1 }
        var parts: [String] = []
        for kind in ChatToolKind.allCases {
            guard let count = counts[kind], count > 0 else { continue }
            switch kind {
            case .read: parts.append(count == 1 ? "Read 1 file" : "Read \(count) files")
            case .edit: parts.append("Edited \(count)")
            case .command: parts.append(count == 1 ? "Ran 1 command" : "Ran \(count) commands")
            case .search: parts.append(count == 1 ? "Searched once" : "Searched \(count) times")
            case .web: parts.append(count == 1 ? "Fetched 1 page" : "Fetched \(count) pages")
            case .plan: parts.append("Updated plan")
            case .subagent: parts.append(count == 1 ? "Delegated 1 task" : "Delegated \(count) tasks")
            case .question: parts.append(count == 1 ? "Asked 1 question" : "Asked \(count) questions")
            case .other: parts.append(count == 1 ? "Used 1 tool" : "Used \(count) tools")
            }
        }
        if parts.isEmpty, reasoning > 0 { parts.append("Reasoned") }
        let failed = tools.filter { $0.state == .failed || $0.state == .denied }.count
        if failed > 0 { parts.append("\(failed) failed") }
        return parts.joined(separator: " · ")
    }

    static func isDenial(_ error: String) -> Bool {
        let lowered = error.lowercased()
        return lowered.contains("rejected") || lowered.contains("denied") || lowered.contains("declined")
    }

    static func target(for kind: ChatToolKind, tool: ConversationTool) -> String? {
        let object = (try? JSONSerialization.jsonObject(with: Data(tool.input.utf8))) as? [String: Any]
        func string(_ keys: [String]) -> String? {
            guard let object else { return nil }
            for key in keys {
                if let value = object[key] as? String, !value.trimmingCharacters(in: .whitespaces).isEmpty { return value }
                if let value = object[key] as? [String], !value.isEmpty { return value.joined(separator: " ") }
            }
            return nil
        }
        let title = tool.title.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .read, .edit:
            let path = string(["filePath", "file_path", "path", "file", "filename", "notebook_path"])
                ?? (title.isEmpty ? nil : title) ?? (object == nil && !tool.input.isEmpty ? tool.input : nil)
            return path.map { shorten(fileName($0.components(separatedBy: "\n").first ?? $0), limit: 60) }
        case .command:
            let command = string(["command", "cmd", "script"]) ?? (object == nil && !tool.input.isEmpty ? tool.input : nil)
                ?? (title.isEmpty ? nil : title)
            return command.map { shorten(firstLine($0), limit: 60) }
        case .search:
            return (string(["pattern", "query", "regex", "glob", "q"]) ?? (title.isEmpty ? nil : title)).map { shorten(firstLine($0), limit: 60) }
        case .web:
            return (string(["url", "query", "q"]) ?? (title.isEmpty ? nil : title)).map { shorten(firstLine($0), limit: 60) }
        case .subagent:
            return (string(["description", "prompt", "task"]) ?? (title.isEmpty ? nil : title)).map { shorten(firstLine($0), limit: 60) }
        case .plan, .question, .other:
            return nil
        }
    }

    static func fileName(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        return trimmed.split(separator: "/").last.map(String.init) ?? trimmed
    }

    static func firstLine(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? text
    }

    static func shorten(_ text: String, limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }
}

/// Reasoning time from part timestamps, or the duration a legacy host reported.
public enum ChatDurations {
    public static func seconds(start: String?, end: String?, legacyMilliseconds: Int?) -> TimeInterval? {
        if let legacyMilliseconds, legacyMilliseconds > 0 { return TimeInterval(legacyMilliseconds) / 1000 }
        guard let start = ChatTime.date(start), let end = ChatTime.date(end) else { return nil }
        return max(0, end.timeIntervalSince(start))
    }

    /// "< 1 s", "12 s", "3 min 4 s".
    public static func finished(_ seconds: TimeInterval) -> String {
        if seconds < 1 { return "< 1 s" }
        let whole = Int(seconds.rounded())
        if whole < 60 { return "\(whole) s" }
        let minutes = whole / 60, rest = whole % 60
        return rest == 0 ? "\(minutes) min" : "\(minutes) min \(rest) s"
    }

    /// "0:07", "12:03" for a live timer.
    public static func elapsed(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}
