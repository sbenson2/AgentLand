import Foundation
import AgentLandCore
import AgentLandChat

// Terminal names from what the screen shows (docs/HOST-API.md "Contextual terminal names"; owner, 2026-10-16: "the
// task names need to be better about what is actually happeing in the terminal context wise"). Pure and nonisolated:
// the apps' `TerminalNaming` reads a terminal's rendered rows into them, and the Mac can name any terminal from text
// rendered from its output the same way. Nothing here reads keystrokes; only the name goes to the host.

/// A terminal's rendered screen as naming reads it: the requests the person typed into its program, then its
/// meaningful output, with the program's chrome stripped (box borders, spinner and status lines, "esc to interrupt",
/// timers, token counters, key hints, welcome boilerplate, the input box being typed in, blank lines) and every line
/// that looks like a secret left out. Two screens that differ only in chrome are equal.
public nonisolated struct TerminalScreen: Hashable, Sendable {
    /// A line typed at a prompt, as the screen echoes it. `shell`: at a shell's prompt (`$ `, `% `, `user@host … % `),
    /// whose arguments never become a name; otherwise at a coding agent's (`❯ `, `› `, `> `).
    public struct Request: Hashable, Sendable {
        public let text: String
        public let shell: Bool
    }

    /// The requests on screen, oldest first.
    public let requests: [Request]
    /// The meaningful output, oldest first: each line's white space collapsed, its timers and hints removed.
    public let output: [String]

    /// Requests and output lines the model reads at most, and the characters of each part.
    static let requestsRead = 4
    static let requestCharacters = 200
    static let outputLinesRead = 30
    static let outputCharacters = 2_400

    /// `lines`: the rendered rows, top to bottom, as the renderer drew them (escape sequences already applied).
    public init(lines: [String]) {
        enum Row { case prompt(Request?), output(String) }
        var rows: [Row] = []
        for raw in lines {
            let line = Self.unboxed(raw)
            if let prompt = Self.prompt(in: line) {
                rows.append(.prompt(prompt))
            } else if !Self.isChrome(line) {
                let text = Self.normalized(line)
                if !text.isEmpty, !Self.looksSecret(text, typed: false) { rows.append(.output(text)) }
            }
        }
        // The last prompt with no output after it is the input box the person is typing in (or its placeholder):
        // not a request until it is sent.
        if let last = rows.lastIndex(where: { if case .prompt = $0 { true } else { false } }),
           !rows[last...].contains(where: { if case .output = $0 { true } else { false } }) {
            rows.remove(at: last)
        }
        requests = rows.compactMap { if case let .prompt(request?) = $0 { request } else { nil } }
        output = rows.compactMap { if case let .output(text) = $0 { text } else { nil } }
    }

    public init(text: String) {
        self.init(lines: text.components(separatedBy: .newlines))
    }

    /// The newest request, if any.
    public var latestRequest: String? { requests.last?.text }

    /// Nothing to name: no request, and too little output to say what happens (a fresh program's screen, a prompt).
    public var isIdle: Bool {
        requests.isEmpty && (output.count < 3 || output.flatMap(Self.contentWords).count < 10)
    }

    /// What the model reads: the newest requests, the recent output, then the current name (nil: none yet). Bounded
    /// well inside `ChatNamingInput`'s 4,000 characters, so the current name is never cut off.
    public func namingText(current: String?) -> String {
        let typed = requests.suffix(Self.requestsRead).map { "- " + String($0.text.prefix(Self.requestCharacters)) }
        var shown = output.suffix(Self.outputLinesRead).joined(separator: "\n")
        if shown.count > Self.outputCharacters { shown = String(shown.suffix(Self.outputCharacters)) }
        return """
            Requests the person typed, oldest first:
            \(typed.isEmpty ? "none" : typed.joined(separator: "\n"))

            Recent output:
            \(shown.isEmpty ? "none" : shown)

            Current name: \(current ?? "none")
            """
    }

    /// Every word of the requests and output, lower-cased: what a name must share a word with (`TerminalNameRules`).
    var vocabulary: Set<String> {
        Set((requests.map(\.text) + output).flatMap(Self.words))
    }

    // MARK: Reading a row

    /// Box-drawing and block characters (U+2500–U+259F): TUI borders and rules.
    private static func isBox(_ scalar: Unicode.Scalar) -> Bool { (0x2500...0x259F).contains(scalar.value) }

    /// The row without the borders and white space around it: "│ > fix the tab bar │" is "> fix the tab bar".
    static func unboxed(_ raw: String) -> String {
        var scalars = Substring(raw).unicodeScalars
        while let first = scalars.first, isBox(first) || first.properties.isWhitespace { scalars.removeFirst() }
        while let last = scalars.last, isBox(last) || last.properties.isWhitespace { scalars.removeLast() }
        return String(scalars)
    }

    /// A coding agent's prompt markers (Claude Code's "❯ " and "> ", Codex's "› ") and a shell's bare ones.
    private static let agentMarkers = ["❯", "›", ">"]
    private static let shellMarkers = ["$", "%"]
    /// A shell's prompt before its marker: "user@host dir % ", "mini:~/app% ", "~ % ", "bash-5.2$ ", "(venv) …".
    private static let shellPrompt =
        #"^(\([^)]*\) )?([\w.-]+@[\w.-]+([: ][^\s]*)?|[\w.-]*[:~/][\w~/.:-]*|[\w.-]+-\d[\w.]*) ?[$%#>]( |$)"#

    /// A prompt row's request: nil when the row is no prompt, `.some(nil)` for a prompt that holds no request (empty,
    /// a placeholder, or a line that looks like a secret).
    static func prompt(in line: String) -> Request?? {
        var typed: String?
        var shell = false
        for marker in agentMarkers + shellMarkers where line == marker || line.hasPrefix(marker + " ") {
            typed = String(line.dropFirst(marker.count))
            shell = shellMarkers.contains(marker)
            break
        }
        if typed == nil, let range = line.range(of: shellPrompt, options: .regularExpression) {
            typed = String(line[range.upperBound...])
            shell = true
        }
        guard let typed else { return nil }
        let text = typed.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !text.isEmpty, !isPlaceholder(text), !looksSecret(text, typed: true) else { return .some(nil) }
        return .some(Request(text: text, shell: shell))
    }

    /// The suggestions an empty input box shows: Claude Code's `Try "…"`, Codex's examples.
    private static let placeholders: Set<String> = [
        "explain this codebase", "summarize recent commits", "implement {feature}", "find and fix a bug in @filename",
        "write tests for @filename", "improve documentation in @filename", "run /review on my current changes",
        "use /skills to list available skills", "ask codex to do anything",
    ]

    private static func isPlaceholder(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.hasPrefix("try \"") || lower.contains("@filename") || lower.contains("{feature}") || placeholders.contains(lower)
    }

    /// Words that mark a line as one that may hold a secret; a typed line with "=" may set one too.
    private static let secretMarkers = ["password", "passwd", "token", "secret", "api_key", "api-key", "apikey", "bearer", "private key"]

    static func looksSecret(_ text: String, typed: Bool) -> Bool {
        let lower = text.lowercased()
        return secretMarkers.contains(where: lower.contains) || (typed && lower.contains("="))
    }

    /// Status lines and key hints programs draw around the work.
    private static let chromeMarkers = [
        "esc to interrupt", "esc to cancel", "ctrl+c to", "ctrl-c to", "for shortcuts", "shift+tab", "context left",
        "auto-compact", "accept edits on", "bypass permissions on", "plan mode on", "⏎ send", "⇧⏎ newline", "⌃j newline",
        "⌃t transcript", "ctrl+t transcript", "⌃c quit", "welcome to", "tips for getting started", "to get started",
        "/help for help", "openai codex",
    ]
    /// A program's session details: "cwd: ~/app", "model: gpt-5 high".
    private static let detailPrefixes = ["cwd:", "model:", "directory:", "workdir:", "approval:", "sandbox:", "account:", "session:"]
    /// Elapsed timers and token counters: "12s", "1m 30s", "00:12", "↑ 1.2k tokens".
    private static let counter = #"\d+(\.\d+)?\s*[km]?\s*tokens?\b|\b\d+[hms]\b|\b\d{1,2}:\d{2}(:\d{2})?\b"#
    /// A parenthesized timer, counter or hint inside a line: "(12s · ↑ 1.2k tokens)", "(ctrl+r to expand)".
    private static let statusGroup = #"(?i)\s*\([^()]*(\d+(\.\d+)?\s*[hms]\b|tokens?|esc to|ctrl[+-]|shift\+tab)[^()]*\)"#

    /// A row that says nothing about the work. `line` is already `unboxed`.
    static func isChrome(_ line: String) -> Bool {
        guard line.unicodeScalars.contains(where: isLetterOrDigit) else { return true }
        let lower = line.lowercased()
        if chromeMarkers.contains(where: lower.contains) || detailPrefixes.contains(where: { lower.hasPrefix($0) }) { return true }
        // A slash command's help: "/init - create an AGENTS.md file", "/model to change".
        if lower.range(of: #"^/[a-z-]+\s+(-|–|—|for|to)\s"#, options: .regularExpression) != nil { return true }
        // Only timers and counters.
        let uncounted = lower.replacingOccurrences(of: counter, with: "", options: .regularExpression)
        guard uncounted.unicodeScalars.contains(where: isLetterOrDigit) else { return true }
        // A spinner's status: a glyph, then a word or a few ending in "…" ("✻ Thinking…", "⠋ Working", "· Pondering…").
        guard let first = line.unicodeScalars.first, !isLetterOrDigit(first) else { return false }
        let status = String(line.unicodeScalars.drop { !isLetterOrDigit($0) })
            .replacingOccurrences(of: statusGroup, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let words = status.split(whereSeparator: \.isWhitespace)
        let trailing = status.hasSuffix("…") || status.hasSuffix("...")
        return (words.count == 1 && (trailing || status.allSatisfy { $0.isLetter })) || (trailing && words.count <= 4)
    }

    /// The row's text with white space collapsed and its parenthesized timers, counters and hints removed, so a timer
    /// ticking is not a change.
    static func normalized(_ line: String) -> String {
        line.replacingOccurrences(of: statusGroup, with: "", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func isLetterOrDigit(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isAlphabetic || scalar.properties.numericType == .decimal
    }

    /// `text`'s words, lower-cased.
    static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// Words of at least three letters that say something on their own (not `TerminalNameRules.genericWords`).
    static func contentWords(_ text: String) -> [String] {
        words(text).filter { $0.filter(\.isLetter).count >= 3 && !TerminalNameRules.genericWords.contains($0) }
    }
}

/// The checks a terminal's name passes, and the rules' own name when the model gives none that passes.
public nonisolated enum TerminalNameRules {
    /// Words that say nothing about a terminal's work: a chat's (`ChatNameRules.genericWords`), and the terminal's own.
    static let genericWords = ChatNameRules.genericWords.union(["terminal", "terminals", "shell", "screen", "output", "untitled"])

    /// A name the screen supports: one of its content words (three or more letters, not generic) is a word of the
    /// screen's requests or output, ignoring case, or shares its start with one for a simple inflection ("fixing" and
    /// "fix", "tests" and "test"). "JSON format task" on a screen without "json" or "format" is not.
    public static func grounded(_ name: String, in screen: TerminalScreen) -> Bool {
        let seen = screen.vocabulary
        return TerminalScreen.contentWords(name).contains { word in
            seen.contains(word) || seen.contains { related(word, $0) }
        }
    }

    /// One word is the other with up to four more characters at its end ("fix", "fixes", "fixing").
    static func related(_ a: String, _ b: String) -> Bool {
        let (short, long) = a.count <= b.count ? (a, b) : (b, a)
        return short.count >= 3 && long.hasPrefix(short) && long.count - short.count <= 4
    }

    /// The same name as `current`, ignoring case, punctuation and spacing: sending it would change nothing.
    public static func sameName(_ name: String, _ current: String?) -> Bool {
        guard let current else { return false }
        return TerminalScreen.words(name) == TerminalScreen.words(current)
    }

    /// Typed requests that only answer the program ("yes", "keep going", "ok do it"): no task of their own.
    private static let replies: Set<String> = [
        "yes", "yeah", "yep", "no", "nope", "ok", "okay", "sure", "thanks", "thank", "you", "continue", "proceed", "go",
        "ahead", "keep", "going", "on", "please", "do", "it", "that", "this", "sounds", "good", "great", "perfect", "nice",
        "cool", "done", "y", "n", "lgtm", "right", "fine", "again", "now", "the", "same", "and", "all",
    ]
    /// Words a request opens with that are no part of its task.
    private static let openers: Set<String> = ["please", "now", "can", "you", "could", "would", "lets", "let's", "ok", "okay", "so"]
    /// Shell commands whose purpose the rules can name (their arguments never become a name).
    private static let commands = [
        ("go test", "Run Go tests"), ("swift test", "Run Swift tests"), ("npm test", "Run JavaScript tests"),
        ("pnpm test", "Run JavaScript tests"), ("swift build", "Build Swift app"), ("xcodebuild", "Build and check Xcode project"),
        ("git diff", "Review Git changes"), ("git status", "Review Git status"), ("git commit", "Commit Git changes"),
    ]
    /// A name the rules make is at most this many words.
    static let fallbackWords = 6

    /// Used when the model is unavailable or its name was rejected. The newest request first: a shell command the
    /// rules know names its purpose; a request typed to a coding agent of three or more words (not only replies) is
    /// the name, cut to six words. Otherwise nil: the terminal keeps its name.
    public static func fallback(_ screen: TerminalScreen) -> String? {
        for request in screen.requests.reversed() {
            let lower = request.text.lowercased()
            if let command = commands.first(where: { lower == $0.0 || lower.hasPrefix($0.0 + " ") }) { return command.1 }
            guard !request.shell else { continue }
            var words = request.text.split(whereSeparator: \.isWhitespace).map(String.init)
            while let first = words.first, openers.contains(first.lowercased()) { words.removeFirst() }
            guard words.count >= 3, !words.allSatisfy({ replies.contains(TerminalScreen.words($0).joined()) }),
                  let first = words.first, first.first?.isLetter == true else { continue }
            var task = Array(words.prefix(fallbackWords))
            var title = task.joined(separator: " ")
            while title.unicodeScalars.count > ChatNameRules.lengths.upperBound, task.count > 1 {
                task.removeLast()
                title = task.joined(separator: " ")
            }
            if let cleaned = ChatNameRules.clean(title) { return cleaned.prefix(1).uppercased() + cleaned.dropFirst() }
        }
        return nil
    }

    /// `fallback` of a screen given as text, one row a line.
    static func fallback(_ output: String) -> String? { fallback(TerminalScreen(text: output)) }
}

/// When a terminal's screen is worth naming again, one schedule per terminal: when its newest request changed, else at
/// most every 30 s while its meaningful output changes. An idle screen, or one that only redrew its chrome, never is.
public nonisolated struct TerminalNamingSchedule: Sendable {
    public enum Due: Equatable, Sendable {
        case now
        /// Its output changed sooner than the interval allows: ask again after this many seconds.
        case after(TimeInterval)
        /// Nothing new to name.
        case no
    }

    /// How long output settles before the screen is read (after a new request too).
    public static let debounce: TimeInterval = 5
    /// How often changed output alone asks the model again.
    public static let outputInterval: TimeInterval = 30

    private var asked: TerminalScreen?
    private var askedAt: Date?

    public init() {}

    public func due(_ screen: TerminalScreen, now: Date) -> Due {
        guard !screen.isIdle, screen != asked else { return .no }
        guard let asked, let askedAt else { return .now }
        if let latest = screen.latestRequest, latest != asked.latestRequest { return .now }
        let wait = Self.outputInterval - now.timeIntervalSince(askedAt)
        return wait > 0 ? .after(wait) : .now
    }

    /// The screen was named (or found nothing to name) at `date`.
    public mutating func asked(_ screen: TerminalScreen, at date: Date) {
        asked = screen
        askedAt = date
    }
}

/// Names a terminal from its rendered screen: the one entry point for naming a terminal. The on-device model (through
/// a `ChatNamer`, under a terminal's own instructions) reads the screen's requests, output and the current name; a
/// name the screen does not support (`TerminalNameRules.grounded`) is rejected, and then, as when the model is
/// unavailable, the rules' fallback names it. Nil sends nothing: an idle screen, no name, or the current name again
/// (ignoring case and punctuation).
public nonisolated struct TerminalContextNamer: Sendable {
    public let namer: any ChatNamer

    public init(namer: any ChatNamer) { self.namer = namer }

    /// `lines`: the rendered rows, top to bottom. `current`: the terminal's name now, nil while it has none of its own
    /// (only its program's or its creation label).
    public func name(lines: [String], current: String?) async -> String? {
        await name(for: TerminalScreen(lines: lines), current: current)
    }

    public func name(for screen: TerminalScreen, current: String?) async -> String? {
        guard !screen.isIdle else { return nil }
        if namer.isAvailable {
            let input = ChatNamingInput(prompt: screen.namingText(current: current), reply: "", newestMessageID: "",
                                        context: .terminal)
            if let generated = await namer.name(for: input), let name = ChatNameRules.clean(generated) {
                // The model kept the name: it still fits.
                if TerminalNameRules.sameName(name, current) { return nil }
                if TerminalNameRules.grounded(name, in: screen) { return name }
            }
        }
        guard let fallback = TerminalNameRules.fallback(screen), !TerminalNameRules.sameName(fallback, current) else { return nil }
        return fallback
    }
}
