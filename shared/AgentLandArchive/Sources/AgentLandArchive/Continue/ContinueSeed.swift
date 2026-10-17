import Foundation
import AgentLandCore

/// The context a continued chat starts with, computed on this device with the
/// host's rules (docs/HOST-API.md, "Continue with another model"): a header,
/// the source's first user message, then its newest messages that fit the
/// budget, oldest first, with a marker where messages are left out. Tool calls
/// become one line each; reasoning, notices, rewound messages and an earlier
/// seed are left out. The Continue sheet shows its size before the host builds
/// the real seed; on hosts without Continue it becomes the transcript the new
/// chat starts from.
public struct ContinueSeed: Equatable, Sendable {
    /// The host's cap on a seed, in UTF-8 bytes.
    public static let maximumBytes = 384 << 10
    static let seedMessageID = "agentland-seed"

    public var header: String
    /// Message blocks, and the left-out marker, in order.
    public var blocks: [String]
    public var footer: String
    public var included: Int
    public var omitted: Int

    public var isEmpty: Bool { included == 0 }

    /// The seed as the host sends it ahead of the first message.
    public var text: String {
        isEmpty ? "" : ([header] + blocks + [footer]).joined(separator: "\n\n")
    }

    /// Characters as the host counts them (Unicode scalars).
    public var characters: Int { text.unicodeScalars.count }

    /// A rough token count: about four characters per token.
    public var estimatedTokens: Int { (characters + 3) / 4 }

    /// The same messages as a Markdown file.
    public func markdown(title: String, agent: String, model: String?, workspace: String?) -> String {
        var about = "Earlier chat with " + agent
        if let model, !model.isEmpty { about += " (\(model))" }
        if let workspace, !workspace.isEmpty { about += " in " + workspace }
        about += ". It holds the first user message and the most recent messages; tool calls are summarized in one line each and reasoning is left out."
        return (["# " + title, "_" + about + "_"] + blocks).joined(separator: "\n\n") + "\n"
    }

    /// Builds the seed from `messages` (oldest first), stopping after `cutoff`
    /// when given. `budget` is in characters, 1 000–200 000.
    public static func build(chat: ArchivedChat, messages: [ArchivedMessage], through cutoff: String? = nil,
                             budget: Int = ChatContinueRequest.defaultContextChars) -> ContinueSeed {
        let budget = min(max(budget, ChatContinueRequest.contextCharsRange.lowerBound), ChatContinueRequest.contextCharsRange.upperBound)
        let source = chat.title.isEmpty ? "Untitled chat" : chat.title.clipped(toBytes: 200)
        let labels = [chat.provider] + (chat.model.map { [$0] } ?? [])
        let held = cutoff == nil ? "the most recent messages" : "the most recent messages up to a point the user chose (later messages are left out)"
        let header = "Context from an earlier chat, \"\(source)\" (\(labels.joined(separator: ", "))), continued here with another model. "
            + "It holds the first user message and \(held); tool calls are summarized in one line each and reasoning is left out."
        let footer = "End of the earlier chat. The new message follows."
        let markerLimit = "[9999999 messages in between are left out.]"
        let reserve = Entry(header).chars + Entry(footer).chars + Entry(markerLimit).chars
        let reserveBytes = header.utf8.count + footer.utf8.count + markerLimit.utf8.count + 6
        let budgetChars = budget - reserve, budgetBytes = maximumBytes - reserveBytes

        var first: Entry?
        var newest: [Entry] = []
        var sumChars = 0, sumBytes = 0, eligible = 0
        for archived in messages {
            let reachedCutoff = archived.id == cutoff
            if !archived.hidden, archived.id != seedMessageID {
                let text = render(archived.message)
                if !text.isEmpty {
                    eligible += 1
                    let entry = Entry(text).clipped(chars: budgetChars, bytes: budgetBytes)
                    if first == nil, archived.message.role == .user {
                        first = entry
                    } else {
                        newest.append(entry)
                        sumChars += entry.chars
                        sumBytes += entry.bytes
                        // Older entries the newer ones already crowd out can go.
                        while newest.count > 1, sumChars - newest[0].chars >= budgetChars || sumBytes - newest[0].bytes >= budgetBytes {
                            sumChars -= newest[0].chars
                            sumBytes -= newest[0].bytes
                            newest.removeFirst()
                        }
                    }
                }
            }
            if reachedCutoff { break }
        }
        guard eligible > 0 else { return ContinueSeed(header: header, blocks: [], footer: footer, included: 0, omitted: 0) }

        var leftChars = budgetChars, leftBytes = budgetBytes
        var blocks: [String] = []
        var included = 0
        if let first {
            let kept = first.clipped(chars: leftChars, bytes: leftBytes)
            blocks.append(kept.text)
            leftChars -= kept.chars
            leftBytes -= kept.bytes
            included += 1
        }
        var latest: [String] = []
        for entry in newest.reversed() {
            if entry.chars <= leftChars, entry.bytes <= leftBytes {
                latest.append(entry.text)
                leftChars -= entry.chars
                leftBytes -= entry.bytes
                continue
            }
            // The newest message alone is too large: keep its start.
            if latest.isEmpty, leftChars >= 200, leftBytes >= 200 { latest.append(entry.clipped(chars: leftChars, bytes: leftBytes).text) }
            break
        }
        latest.reverse()
        included += latest.count
        let omitted = eligible - included
        if omitted > 0 { blocks.append("[\(omitted) messages in between are left out.]") }
        blocks += latest
        return ContinueSeed(header: header, blocks: blocks, footer: footer, included: included, omitted: omitted)
    }

    /// One message as the seed writes it; empty when it carries nothing.
    public static func render(_ message: ConversationMessage) -> String {
        var lines: [String] = []
        var files: [String] = []
        for part in message.parts {
            switch part.kind {
            case .text:
                let text = part.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { lines.append(text) }
            case .tool:
                if let tool = part.tool { lines.append(toolLine(tool)) }
            case .attachment:
                if let attachment = part.attachment { files.append(attachment.name) }
            case .patch:
                var changed = part.text.split(whereSeparator: \.isWhitespace).map(String.init)
                if changed.count > 20 { changed = Array(changed.prefix(20)) + ["and \(changed.count - 20) more"] }
                if !changed.isEmpty { lines.append("[Changed files: " + changed.joined(separator: ", ") + "]") }
            default:
                break
            }
        }
        if !files.isEmpty { lines.append("[Attachments: " + files.joined(separator: ", ") + "]") }
        if !lines.isEmpty, message.status == .aborted { lines.append("[This reply was stopped before it finished.]") }
        if let error = message.error, !error.message.isEmpty { lines.append("[This reply failed: " + oneLine(error.message, limit: 300) + "]") }
        guard !lines.isEmpty else { return "" }
        var heading = "User"
        if message.role == .assistant {
            heading = "Assistant"
            if let model = message.model, !model.isEmpty { heading += " (\(model))" }
        }
        if let date = ChatTime.date(message.createdAt) { heading += " · " + date.formatted(timeStyle) + " UTC" }
        return "### " + heading + "\n" + lines.joined(separator: "\n")
    }

    static func toolLine(_ tool: ConversationTool) -> String {
        let about = oneLine(tool.title.isEmpty ? tool.input : tool.title, limit: 160)
        var line = "[Tool " + oneLine(tool.name, limit: 60)
        if !about.isEmpty { line += ": " + about }
        return line + " (" + tool.status.rawValue + ")]"
    }

    /// White space collapsed to single spaces, at most `limit` characters.
    static func oneLine(_ text: String, limit: Int) -> String {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let scalars = flat.unicodeScalars
        guard scalars.count > limit else { return flat }
        return String(String.UnicodeScalarView(scalars.prefix(limit - 1))) + "…"
    }

    private static let timeStyle = Date.VerbatimFormatStyle(
        format: "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
        timeZone: TimeZone(identifier: "UTC")!, calendar: Calendar(identifier: .gregorian))

    /// A block with its size, counting the blank line before it.
    struct Entry: Equatable {
        let text: String
        let chars: Int
        let bytes: Int

        init(_ text: String) {
            self.text = text
            chars = text.unicodeScalars.count + 2
            bytes = text.utf8.count + 2
        }

        /// Shortened to fit, keeping its start.
        func clipped(chars limit: Int, bytes byteLimit: Int) -> Entry {
            guard chars > limit || bytes > byteLimit else { return self }
            let mark = "\n[… shortened]"
            let keepChars = limit - 2 - mark.unicodeScalars.count, keepBytes = byteLimit - 2 - mark.utf8.count
            var kept = String.UnicodeScalarView()
            var count = 0, used = 0
            for scalar in text.unicodeScalars {
                let size = UTF8.width(scalar)
                guard count < keepChars, used + size <= keepBytes else { break }
                kept.append(scalar)
                count += 1
                used += size
            }
            var prefix = String(kept)
            while let last = prefix.last, last == " " || last == "\n" { prefix.removeLast() }
            return Entry(prefix + mark)
        }
    }
}
