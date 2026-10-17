import Foundation

/// A unified diff split into lines the diff view draws: file headers, hunk headers, added, removed and
/// unchanged lines with their old and new line numbers, and Git's notes ("\ No newline at end of
/// file", "Binary files … differ").
public struct GitDiffDocument: Equatable, Sendable {
    public struct Line: Identifiable, Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            /// `diff --git`, `index`, `new file mode`, `rename from` …
            case header
            /// `--- a/…` and `+++ b/…`.
            case fileHeader
            /// `@@ -a,b +c,d @@`.
            case hunk
            case added
            case removed
            case context
            /// `\ No newline at end of file`, `Binary files … differ`.
            case note
        }
        public let id: Int
        public let kind: Kind
        /// The line without its +, - or space marker.
        public let text: String
        public let oldNumber: Int?
        public let newNumber: Int?
    }

    public let lines: [Line]

    /// Tabs show as four spaces, so columns line up in the monospaced view.
    public init(_ diff: String) {
        var lines: [Line] = []
        var old = 0
        var new = 0
        var inHunk = false
        let raw = diff.hasSuffix("\n") ? String(diff.dropLast()) : diff
        guard !raw.isEmpty else { self.lines = []; return }
        for (index, part) in raw.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let text = String(part).replacingOccurrences(of: "\t", with: "    ")
            let line: Line
            if text.hasPrefix("@@") {
                (old, new) = Self.hunkStarts(text)
                inHunk = true
                line = Line(id: index, kind: .hunk, text: text, oldNumber: nil, newNumber: nil)
            } else if text.hasPrefix("diff --git") {
                inHunk = false
                line = Line(id: index, kind: .header, text: text, oldNumber: nil, newNumber: nil)
            } else if !inHunk && (text.hasPrefix("--- ") || text.hasPrefix("+++ ")) {
                line = Line(id: index, kind: .fileHeader, text: text, oldNumber: nil, newNumber: nil)
            } else if inHunk && text.hasPrefix("+") {
                line = Line(id: index, kind: .added, text: String(text.dropFirst()), oldNumber: nil, newNumber: new)
                new += 1
            } else if inHunk && text.hasPrefix("-") {
                line = Line(id: index, kind: .removed, text: String(text.dropFirst()), oldNumber: old, newNumber: nil)
                old += 1
            } else if inHunk && text.hasPrefix(" ") {
                line = Line(id: index, kind: .context, text: String(text.dropFirst()), oldNumber: old, newNumber: new)
                old += 1
                new += 1
            } else if text.hasPrefix("\\") || text.hasPrefix("Binary files ") {
                line = Line(id: index, kind: .note, text: text, oldNumber: nil, newNumber: nil)
            } else if inHunk && text.isEmpty {
                // Some tools drop the space of an empty unchanged line.
                line = Line(id: index, kind: .context, text: "", oldNumber: old, newNumber: new)
                old += 1
                new += 1
            } else {
                inHunk = false
                line = Line(id: index, kind: .header, text: text, oldNumber: nil, newNumber: nil)
            }
            lines.append(line)
        }
        self.lines = lines
    }

    /// The first old and new line numbers of `@@ -a,b +c,d @@`.
    static func hunkStarts(_ header: String) -> (Int, Int) {
        func start(after marker: Character) -> Int {
            guard let index = header.firstIndex(of: marker) else { return 1 }
            let digits = header[header.index(after: index)...].prefix { $0.isNumber }
            return Int(digits) ?? 1
        }
        return (start(after: "-"), start(after: "+"))
    }

    public var addedCount: Int { lines.filter { $0.kind == .added }.count }
    public var removedCount: Int { lines.filter { $0.kind == .removed }.count }
    /// The longest line, in characters, for the view's width.
    public var widestLine: Int { lines.map(\.text.count).max() ?? 0 }
    /// The largest line number, for the gutter's width.
    public var largestNumber: Int { lines.compactMap { max($0.oldNumber ?? 0, $0.newNumber ?? 0) }.max() ?? 0 }
}
