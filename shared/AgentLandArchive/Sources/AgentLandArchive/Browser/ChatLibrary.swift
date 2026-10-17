import Foundation
import SwiftUI

/// A section of the chat library.
public enum ChatLibrarySection: Hashable, Sendable {
    case pinned, today, yesterday, thisWeek
    case month(year: Int, month: Int)
}

public struct ChatLibraryGroup: Identifiable, Hashable, Sendable {
    public let section: ChatLibrarySection
    public let title: String
    public let chats: [ArchivedChat]
    public var id: ChatLibrarySection { section }
}

/// Pinned, Today, Yesterday, This Week, then one section per month, by last
/// activity in `calendar`'s time zone. Days are calendar days, so a
/// daylight-saving change never moves "Yesterday".
public enum ChatLibrary {
    public static func groups(_ chats: [ArchivedChat], now: Date = Date(), calendar: Calendar = .current,
                              locale: Locale = .current) -> [ChatLibraryGroup] {
        let sorted = chats.sorted { $0.updatedAt != $1.updatedAt ? $0.updatedAt > $1.updatedAt : $0.id < $1.id }
        let bounds = Bounds(now: now, calendar: calendar)
        var pinned: [ArchivedChat] = []
        var buckets: [ChatLibrarySection: [ArchivedChat]] = [:]
        for chat in sorted {
            if chat.pinned {
                pinned.append(chat)
            } else {
                buckets[section(for: chat.updatedAt, bounds: bounds, calendar: calendar), default: []].append(chat)
            }
        }
        var result: [ChatLibraryGroup] = []
        if !pinned.isEmpty { result.append(ChatLibraryGroup(section: .pinned, title: title(.pinned, calendar: calendar, locale: locale), chats: pinned)) }
        let order = buckets.keys.sorted { rank($0) < rank($1) }
        for section in order {
            result.append(ChatLibraryGroup(section: section, title: title(section, calendar: calendar, locale: locale), chats: buckets[section] ?? []))
        }
        return result
    }

    public static func section(for date: Date, now: Date, calendar: Calendar) -> ChatLibrarySection {
        section(for: date, bounds: Bounds(now: now, calendar: calendar), calendar: calendar)
    }

    public static func title(_ section: ChatLibrarySection, calendar: Calendar = .current, locale: Locale = .current) -> String {
        switch section {
        case .pinned: return "Pinned"
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .thisWeek: return "This Week"
        case let .month(year, month):
            guard let date = calendar.date(from: DateComponents(year: year, month: month, day: 15)) else { return "\(year)" }
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.locale = locale
            formatter.setLocalizedDateFormatFromTemplate("MMMMyyyy")
            return formatter.string(from: date)
        }
    }

    /// A row's time, as Messages shows it: the time today, "Yesterday", the
    /// weekday this week, then the date.
    public static func rowTime(_ date: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        switch section(for: date, now: now, calendar: calendar) {
        case .today:
            return date.formatted(style)
        case .yesterday:
            return "Yesterday"
        case .thisWeek:
            style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).weekday(.wide)
            return date.formatted(style)
        default:
            style = Date.FormatStyle(date: .numeric, time: .omitted, locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            return date.formatted(style)
        }
    }

    private struct Bounds {
        let today: Date
        let yesterday: Date
        let weekStart: Date
        init(now: Date, calendar: Calendar) {
            today = calendar.startOfDay(for: now)
            yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
            weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? today
        }
    }

    private static func section(for date: Date, bounds: Bounds, calendar: Calendar) -> ChatLibrarySection {
        // A time ahead of this device's clock still counts as today.
        if date >= bounds.today { return .today }
        if date >= bounds.yesterday { return .yesterday }
        if date >= bounds.weekStart { return .thisWeek }
        let parts = calendar.dateComponents([.year, .month], from: date)
        return .month(year: parts.year ?? 0, month: parts.month ?? 0)
    }

    private static func rank(_ section: ChatLibrarySection) -> Int {
        switch section {
        case .pinned: 0
        case .today: 1
        case .yesterday: 2
        case .thisWeek: 3
        // Newer months first.
        case let .month(year, month): 4 + (9_999 - year) * 12 + (12 - month)
        }
    }
}

/// Search snippets mark each match between U+0002 and U+0003, which archived
/// text never contains. They render as emphasis.
public enum ArchiveSnippet {
    public struct Segment: Equatable, Sendable {
        public var text: String
        public var isMatch: Bool
        public init(_ text: String, isMatch: Bool) { self.text = text; self.isMatch = isMatch }
    }

    /// The snippet on one line (runs of white space become one space), split
    /// into plain and matching text. An unclosed match runs to the end.
    public static func segments(_ snippet: String) -> [Segment] {
        var segments: [Segment] = []
        var current = String.UnicodeScalarView()
        var matching = false
        var lastWasSpace = true
        func flush() {
            guard !current.isEmpty else { return }
            let text = String(current)
            if let last = segments.last, last.isMatch == matching {
                segments[segments.count - 1].text += text
            } else {
                segments.append(Segment(text, isMatch: matching))
            }
            current = String.UnicodeScalarView()
        }
        for scalar in snippet.unicodeScalars {
            switch scalar {
            case "\u{2}":
                flush()
                matching = true
            case "\u{3}":
                flush()
                matching = false
            default:
                if scalar.properties.isWhitespace || scalar == "\n" || scalar == "\r" {
                    if !lastWasSpace { current.append(" ") }
                    lastWasSpace = true
                } else {
                    current.append(scalar)
                    lastWasSpace = false
                }
            }
        }
        flush()
        if let last = segments.indices.last, segments[last].text.hasSuffix(" ") {
            segments[last].text.removeLast()
            if segments[last].text.isEmpty { segments.removeLast() }
        }
        return segments
    }

    /// Plain text without the markers.
    public static func plainText(_ snippet: String) -> String { segments(snippet).map(\.text).joined() }

    /// Matches strongly emphasized (bold), and in `matchColor` when given.
    public static func attributedString(_ snippet: String, matchColor: Color? = nil) -> AttributedString {
        var result = AttributedString()
        for segment in segments(snippet) {
            var part = AttributedString(segment.text)
            if segment.isMatch {
                part.inlinePresentationIntent = .stronglyEmphasized
                if let matchColor { part.foregroundColor = matchColor }
            }
            result += part
        }
        return result
    }
}
