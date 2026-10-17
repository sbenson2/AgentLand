import Foundation

/// A terminal's name from what runs in it (docs/HOST-API.md, "Terminals"): the window title its program
/// sets with OSC 0 or 2, or its foreground command. Titles are cleaned by the host's rules, ported here
/// with its table of cases, so a title this device sees live reads as the host will list it. Characters
/// are Unicode scalar values, as on the host.
public enum TerminalTitle {
    /// The longest name, in characters. A longer one is cut to one less, and ends with "…".
    public static let maximumLength = 80

    /// Program names that say nothing about the work, compared ignoring case: they count as no title.
    public static let commonNames: Set<String> = [
        "opencode", "claude", "claude code", "codex", "zsh", "-zsh", "bash", "-bash", "sh", "fish", "login",
    ]

    /// `raw` as a terminal's name, in order:
    /// 1. control characters dropped, runs of white space made one space, and the ends trimmed;
    /// 2. a leading `OC | ` removed (OpenCode's TUI sets "OC | <session title>"), and a bare "OC |" is empty;
    /// 3. a leading run of characters that are neither letters nor decimal digits removed (Claude Code's
    ///    status glyphs ✳ ✻ ✶ ✢ · *, braille spinners, dashes, spaces);
    /// 4. a leading `user@host:` shell prefix removed, keeping what follows, trimmed;
    /// 5. over 80 characters: cut to 79, trailing white space removed, and "…" added.
    ///
    /// Nil when nothing is left, or only a program's own name: one of `commonNames`, or one of the
    /// terminal's own names, which `label` (the title it was created with, such as "OpenCode" or
    /// "Terminal") gives: the label, and its program's name and label.
    public static func clean(_ raw: String, label: String? = nil) -> String? {
        var title = collapsed(raw)
        if title == "OC |" { title = "" }
        if title.hasPrefix("OC | ") { title = String(title.dropFirst("OC | ".count)) }
        title = String(String.UnicodeScalarView(title.unicodeScalars.drop { !isLetterOrDigit($0) }))
        if let prefix = shellPrefixEnd(title) { title = title[prefix...].trimmingCharacters(in: .whitespaces) }
        title = capped(title)
        guard !title.isEmpty else { return nil }
        let lowered = title.lowercased()
        guard !commonNames.contains(lowered), !ownNames(label: label).contains(lowered) else { return nil }
        return title
    }

    /// A terminal's own names, lower-cased: `label`, and when it is a program's label (TerminalProgram's
    /// `terminalTitle`), that program's name and label ("Terminal": shell and Shell).
    static func ownNames(label: String?) -> Set<String> {
        guard let label = label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty else { return [] }
        var names: Set<String> = [label.lowercased()]
        if let program = TerminalProgram.known.first(where: { $0.terminalTitle.lowercased() == label.lowercased() }) {
            names.insert(program.id.lowercased())
            names.insert(program.displayName.lowercased())
        }
        return names
    }

    /// Rule 1: white space (control characters such as tab and line breaks included) marks a gap, other
    /// control characters are dropped, and each gap between kept characters is one space.
    private static func collapsed(_ raw: String) -> String {
        var out = String.UnicodeScalarView()
        var gap = false
        for scalar in raw.unicodeScalars {
            if scalar.properties.isWhitespace {
                gap = true
                continue
            }
            if scalar.properties.generalCategory == .control { continue }
            if gap, !out.isEmpty { out.append(" ") }
            gap = false
            out.append(scalar)
        }
        return String(out)
    }

    /// Rule 4: the end of a leading `user@host:` (one "@" between two non-empty parts, no white space, then
    /// the first ":"), or nil.
    private static func shellPrefixEnd(_ title: String) -> String.Index? {
        guard let colon = title.firstIndex(of: ":"), colon > title.startIndex else { return nil }
        let prefix = title[..<colon]
        guard let at = prefix.firstIndex(of: "@"), at > prefix.startIndex, prefix.index(after: at) < prefix.endIndex,
              !prefix[prefix.index(after: at)...].contains("@"), !prefix.contains(where: \.isWhitespace) else { return nil }
        return title.index(after: colon)
    }

    /// Rule 5, counted in Unicode scalar values.
    private static func capped(_ title: String) -> String {
        guard title.unicodeScalars.count > maximumLength else { return title }
        var cut = String(String.UnicodeScalarView(title.unicodeScalars.prefix(maximumLength - 1)))
        while let last = cut.unicodeScalars.last, last.properties.isWhitespace { cut.unicodeScalars.removeLast() }
        return cut + "…"
    }

    /// A Unicode letter or decimal digit.
    private static func isLetterOrDigit(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .decimalNumber: true
        default: false
        }
    }
}
