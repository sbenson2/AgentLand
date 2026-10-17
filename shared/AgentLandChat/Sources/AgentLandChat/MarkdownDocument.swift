import Foundation

/// Block structure of an agent reply. Inline formatting inside each block is
/// rendered separately; unfinished fences (a reply still streaming) stay code.
public enum MarkdownBlock: Hashable, Sendable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case code(language: String, code: String, closed: Bool)
    case quote([MarkdownBlock])
    case list([MarkdownListItem])
    case table(MarkdownTable)
    case rule
}

public struct MarkdownListItem: Hashable, Sendable {
    public enum Marker: Hashable, Sendable { case bullet, number(Int), task(done: Bool) }
    public let marker: Marker
    public let level: Int
    public let text: String
    public init(marker: Marker, level: Int, text: String) { self.marker = marker; self.level = level; self.text = text }
}

public struct MarkdownTable: Hashable, Sendable {
    public enum Alignment: Hashable, Sendable { case leading, center, trailing }
    public let header: [String]
    public let alignments: [Alignment]
    public let rows: [[String]]
    public init(header: [String], alignments: [Alignment], rows: [[String]]) { self.header = header; self.alignments = alignments; self.rows = rows }
}

public enum MarkdownDocument {
    private final class Parsed: NSObject { let blocks: [MarkdownBlock]; init(_ blocks: [MarkdownBlock]) { self.blocks = blocks } }
    // NSCache is internally synchronized. Transcripts refresh every second, so
    // unchanged messages must not be parsed again.
    nonisolated(unsafe) private static let cache: NSCache<NSString, Parsed> = {
        let cache = NSCache<NSString, Parsed>()
        cache.totalCostLimit = 8 << 20
        return cache
    }()

    public static func blocks(from source: String) -> [MarkdownBlock] {
        let key = source as NSString
        if let hit = cache.object(forKey: key) { return hit.blocks }
        let blocks = parse(source)
        cache.setObject(Parsed(blocks), forKey: key, cost: source.utf8.count)
        return blocks
    }

    public static func parse(_ source: String) -> [MarkdownBlock] {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return parse(lines: normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
    }

    static func parse(lines: [String]) -> [MarkdownBlock] {
        parseBlocks(lines: lines).map(\.block)
    }

    /// Blocks with the index of the line each one starts on. The parser only
    /// looks forward, and a block's end depends at most on the first line of
    /// the block after it; `MarkdownStreamParser` relies on both.
    static func parseBlocks(lines: [String]) -> [(block: MarkdownBlock, start: Int)] {
        var blocks: [(block: MarkdownBlock, start: Int)] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let start = index
            if isBlank(line) { index += 1; continue }
            if let fence = Fence(line) {
                var body: [String] = []
                var closed = false
                index += 1
                while index < lines.count {
                    if fence.isClosed(by: lines[index]) { closed = true; index += 1; break }
                    body.append(fence.removingIndent(lines[index]))
                    index += 1
                }
                blocks.append((.code(language: fence.language, code: body.joined(separator: "\n"), closed: closed), start))
                continue
            }
            if let heading = heading(line) { blocks.append((heading, start)); index += 1; continue }
            if isRule(line) { blocks.append((.rule, start)); index += 1; continue }
            if let (table, next) = table(lines, at: index) { blocks.append((.table(table), start)); index = next; continue }
            if quoteContent(line) != nil {
                var inner: [String] = []
                while index < lines.count, let content = quoteContent(lines[index]) { inner.append(content); index += 1 }
                blocks.append((.quote(parse(lines: inner)), start))
                continue
            }
            if listItem(line) != nil {
                var items: [MarkdownListItem] = []
                while index < lines.count {
                    let current = lines[index]
                    if let item = listItem(current) { items.append(item); index += 1; continue }
                    if isBlank(current) {
                        // A blank line continues the list only when another item follows it.
                        var next = index + 1
                        while next < lines.count, isBlank(lines[next]) { next += 1 }
                        if next < lines.count, listItem(lines[next]) != nil { index = next; continue }
                        break
                    }
                    if indentation(current) >= 2, !startsBlock(lines, at: index), let last = items.popLast() {
                        let continued = last.text + "\n" + current.trimmingCharacters(in: .whitespaces)
                        items.append(MarkdownListItem(marker: last.marker, level: last.level, text: continued))
                        index += 1
                        continue
                    }
                    break
                }
                blocks.append((.list(items), start))
                continue
            }
            var paragraph = [line.trimmingCharacters(in: .whitespaces)]
            index += 1
            while index < lines.count, !isBlank(lines[index]), !startsBlock(lines, at: index) {
                paragraph.append(lines[index].trimmingCharacters(in: .whitespaces))
                index += 1
            }
            blocks.append((.paragraph(paragraph.joined(separator: "\n")), start))
        }
        return blocks
    }

    private static func startsBlock(_ lines: [String], at index: Int) -> Bool {
        let line = lines[index]
        return Fence(line) != nil || heading(line) != nil || isRule(line) || quoteContent(line) != nil
            || listItem(line) != nil || table(lines, at: index) != nil
    }

    private static func isBlank(_ line: String) -> Bool { line.allSatisfy { $0 == " " || $0 == "\t" } }

    private static func indentation(_ line: String) -> Int {
        var width = 0
        for character in line {
            if character == " " { width += 1 } else if character == "\t" { width += 4 } else { break }
        }
        return width
    }

    /// Up to three leading spaces may precede a block marker.
    private static func unindented(_ line: String) -> Substring? {
        let spaces = line.prefix { $0 == " " }.count
        return spaces <= 3 ? line.dropFirst(spaces) : nil
    }

    private static func heading(_ line: String) -> MarkdownBlock? {
        guard let rest = unindented(line) else { return nil }
        let level = rest.prefix { $0 == "#" }.count
        guard (1...6).contains(level) else { return nil }
        let after = rest.dropFirst(level)
        guard after.isEmpty || after.first == " " || after.first == "\t" else { return nil }
        var text = after.trimmingCharacters(in: .whitespaces)
        // A closing run of '#' is decoration when a space separates it.
        if let closing = text.lastIndex(where: { $0 != "#" }), closing < text.index(before: text.endIndex), text[closing] == " " {
            text = String(text[..<closing]).trimmingCharacters(in: .whitespaces)
        } else if text.allSatisfy({ $0 == "#" }) {
            text = ""
        }
        return .heading(level: level, text: text)
    }

    private static func isRule(_ line: String) -> Bool {
        guard let rest = unindented(line) else { return false }
        let marks = rest.filter { $0 != " " && $0 != "\t" }
        guard marks.count >= 3, let first = marks.first, "-*_".contains(first) else { return false }
        return marks.allSatisfy { $0 == first }
    }

    private static func quoteContent(_ line: String) -> String? {
        guard let rest = unindented(line), rest.first == ">" else { return nil }
        var content = rest.dropFirst()
        if content.first == " " { content = content.dropFirst() }
        return String(content)
    }

    static func listItem(_ line: String) -> MarkdownListItem? {
        let level = min(indentation(line) / 2, 6)
        let rest = line.drop { $0 == " " || $0 == "\t" }
        if let first = rest.first, "-*+".contains(first) {
            let after = rest.dropFirst()
            guard after.first == " " || after.first == "\t" else { return nil }
            var text = after.drop { $0 == " " || $0 == "\t" }
            var marker = MarkdownListItem.Marker.bullet
            if text.hasPrefix("[ ]") || text.lowercased().hasPrefix("[x]"), text.count == 3 || text.dropFirst(3).first == " " {
                marker = .task(done: text.dropFirst().first != " ")
                text = text.dropFirst(3).drop { $0 == " " }
            }
            return MarkdownListItem(marker: marker, level: level, text: String(text))
        }
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 9 else { return nil }
        let after = rest.dropFirst(digits.count)
        guard let delimiter = after.first, delimiter == "." || delimiter == ")" else { return nil }
        let body = after.dropFirst()
        guard body.first == " " || body.first == "\t" else { return nil }
        return MarkdownListItem(marker: .number(Int(digits) ?? 1), level: level,
                                text: String(body.drop { $0 == " " || $0 == "\t" }))
    }

    static func table(_ lines: [String], at index: Int) -> (MarkdownTable, Int)? {
        guard index + 1 < lines.count, lines[index].contains("|"), lines[index + 1].contains("|") else { return nil }
        let header = cells(lines[index])
        guard !header.isEmpty, let alignments = delimiter(lines[index + 1]), alignments.count == header.count else { return nil }
        var rows: [[String]] = []
        var next = index + 2
        while next < lines.count, !isBlank(lines[next]), lines[next].contains("|") {
            let row = cells(lines[next])
            rows.append(Array((row + Array(repeating: "", count: max(0, header.count - row.count))).prefix(header.count)))
            next += 1
        }
        return (MarkdownTable(header: header, alignments: alignments, rows: rows), next)
    }

    private static func cells(_ line: String) -> [String] {
        var row = line.trimmingCharacters(in: .whitespaces)
        if row.hasPrefix("|") { row.removeFirst() }
        if row.hasSuffix("|"), !row.hasSuffix("\\|") { row.removeLast() }
        var result: [String] = []
        var current = ""
        var iterator = row.makeIterator()
        while let character = iterator.next() {
            if character == "\\" {
                if let next = iterator.next() {
                    if next == "|" { current.append("|") } else { current.append(character); current.append(next) }
                } else { current.append(character) }
            } else if character == "|" {
                result.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        result.append(current.trimmingCharacters(in: .whitespaces))
        return result
    }

    private static func delimiter(_ line: String) -> [MarkdownTable.Alignment]? {
        var alignments: [MarkdownTable.Alignment] = []
        for cell in cells(line) {
            let dashes = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            guard !dashes.isEmpty, dashes.allSatisfy({ $0 == "-" }) else { return nil }
            switch (cell.hasPrefix(":"), cell.hasSuffix(":")) {
            case (true, true): alignments.append(.center)
            case (false, true): alignments.append(.trailing)
            default: alignments.append(.leading)
            }
        }
        return alignments
    }
}

private struct Fence {
    let character: Character
    let length: Int
    let indent: Int
    let language: String

    init?(_ line: String) {
        let indent = line.prefix { $0 == " " }.count
        guard indent <= 3 else { return nil }
        let rest = line.dropFirst(indent)
        guard let first = rest.first, first == "`" || first == "~" else { return nil }
        let length = rest.prefix { $0 == first }.count
        guard length >= 3 else { return nil }
        let info = rest.dropFirst(length).trimmingCharacters(in: .whitespaces)
        if first == "`", info.contains("`") { return nil }
        self.character = first
        self.length = length
        self.indent = indent
        self.language = info.split(separator: " ").first.map(String.init) ?? ""
    }

    func isClosed(by line: String) -> Bool {
        let spaces = line.prefix { $0 == " " }.count
        guard spaces <= 3 else { return false }
        let rest = line.dropFirst(spaces)
        let run = rest.prefix { $0 == character }.count
        return run >= length && rest.dropFirst(run).allSatisfy { $0 == " " || $0 == "\t" }
    }

    func removingIndent(_ line: String) -> String {
        String(line.dropFirst(min(indent, line.prefix { $0 == " " }.count)))
    }
}

/// Parses a reply that grows by appending, re-reading only its unfinished
/// end. Blocks before the last two are final: a block's end depends at most
/// on the first line of the next block, so later text cannot change them. An
/// open code fence at the end is extended line by line without re-reading its
/// body, so a long streaming code block stays linear too.
public final class MarkdownStreamParser {
    /// The first `stableCount` blocks are final; the rest are re-read.
    public private(set) var blocks: [MarkdownBlock] = []
    /// Lines handed to the block parser or scanned for a fence's end, over
    /// this parser's life. Tests use it to prove streaming stays linear.
    public private(set) var parsedLineCount = 0

    private var stableCount = 0
    /// The unstable tail; the last element is the unfinished line.
    private var lines: [String] = [""]
    private var fence: OpenFence?
    private var pendingCarriageReturn = false

    private struct OpenFence {
        let fence: Fence
        /// Complete body lines, joined.
        var code: String
        var hasBody: Bool
        /// Lines of `lines` already scanned (the opening line counts).
        var scanned: Int
    }

    public init(_ text: String = "") {
        if !text.isEmpty { append(text) }
    }

    /// Starts over with `text`.
    public func reset(_ text: String) {
        blocks = []
        stableCount = 0
        lines = [""]
        fence = nil
        pendingCarriageReturn = false
        append(text)
    }

    /// Replaces the unstable blocks; `final` of them become stable.
    private func replaceTail(with tail: some Collection<MarkdownBlock>, final: Int = 0) {
        blocks.removeSubrange(stableCount...)
        blocks.append(contentsOf: tail)
        stableCount += final
    }

    public func append(_ suffix: String) {
        guard !suffix.isEmpty else { return }
        var text = Substring(suffix)
        if pendingCarriageReturn, text.first == "\n" { text = text.dropFirst() }
        pendingCarriageReturn = text.last == "\r"
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let pieces = normalized.split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = pieces.first else { return }
        lines[lines.count - 1] += first
        lines.append(contentsOf: pieces.dropFirst().map(String.init))
        update()
    }

    private func update() {
        if fence != nil, extendFence() { return }
        let parsed = MarkdownDocument.parseBlocks(lines: lines)
        parsedLineCount += lines.count
        guard let last = parsed.last else {
            replaceTail(with: [])
            return
        }
        // An open fence whose opening line is complete: everything before it
        // is final, and its body grows line by line from here on.
        if case let .code(_, _, closed) = last.block, !closed, last.start < lines.count - 1,
           let opening = Fence(lines[last.start]) {
            replaceTail(with: parsed.dropLast().map(\.block), final: parsed.count - 1)
            lines.removeFirst(last.start)
            fence = OpenFence(fence: opening, code: "", hasBody: false, scanned: 1)
            if extendFence() { return }
            update()
            return
        }
        if parsed.count > 2 {
            let keep = parsed.count - 2
            lines.removeFirst(parsed[keep].start)
            replaceTail(with: parsed.map(\.block), final: keep)
        } else {
            replaceTail(with: parsed.map(\.block))
        }
    }

    /// Scans newly completed lines of an open fence. Returns false once the
    /// fence closed; the closed block is then final and the rest is parsed again.
    private func extendFence() -> Bool {
        guard var open = fence else { return false }
        let complete = lines.count - 1
        while open.scanned < complete {
            let line = lines[open.scanned]
            parsedLineCount += 1
            if open.fence.isClosed(by: line) {
                replaceTail(with: [.code(language: open.fence.language, code: open.code, closed: true)], final: 1)
                lines.removeFirst(open.scanned + 1)
                if lines.isEmpty { lines = [""] }
                fence = nil
                return false
            }
            if open.hasBody { open.code += "\n" }
            open.code += open.fence.removingIndent(line)
            open.hasBody = true
            open.scanned += 1
        }
        fence = open
        // The unfinished line is code until it completes (an empty one too,
        // as a full parse reads it); one that already reads as the closing
        // fence closes the block for now.
        var code = open.code
        let partial = lines[complete]
        let closing = !partial.isEmpty && open.fence.isClosed(by: partial)
        if !closing {
            if open.hasBody { code += "\n" }
            code += open.fence.removingIndent(partial)
        }
        replaceTail(with: [.code(language: open.fence.language, code: code, closed: closing)])
        return true
    }
}
