import Foundation
import AgentLandCore

/// A date filter in the search field.
public enum ArchiveDateRange: String, CaseIterable, Hashable, Sendable {
    case today, yesterday, past7Days, past30Days, pastYear

    public var label: String {
        switch self {
        case .today: "Today"
        case .yesterday: "Yesterday"
        case .past7Days: "Past 7 Days"
        case .past30Days: "Past 30 Days"
        case .pastYear: "Past Year"
        }
    }

    /// Calendar days in `calendar`'s time zone: `from` is inclusive, `to`
    /// exclusive (nil runs to now). Day arithmetic, so a daylight-saving
    /// change never moves a boundary off midnight.
    public func bounds(now: Date, calendar: Calendar) -> (from: Date, to: Date?) {
        let today = calendar.startOfDay(for: now)
        func daysBefore(_ days: Int) -> Date { calendar.date(byAdding: .day, value: -days, to: today) ?? today }
        switch self {
        case .today: return (today, nil)
        case .yesterday: return (daysBefore(1), today)
        case .past7Days: return (daysBefore(6), nil)
        case .past30Days: return (daysBefore(29), nil)
        case .pastYear: return (calendar.date(byAdding: .year, value: -1, to: today) ?? daysBefore(365), nil)
        }
    }
}

/// A filter chip in the search field. At most one of each kind applies; a
/// newer chip of a kind replaces the older one.
public enum ArchiveSearchToken: Identifiable, Hashable, Sendable {
    case provider(String)
    case workspace(id: String, name: String)
    case dateRange(ArchiveDateRange)

    public enum Kind: Hashable, Sendable { case provider, workspace, dateRange }

    public var kind: Kind {
        switch self {
        case .provider: .provider
        case .workspace: .workspace
        case .dateRange: .dateRange
        }
    }

    public var id: String {
        switch self {
        case let .provider(provider): "provider:" + provider
        case let .workspace(id, _): "workspace:" + id
        case let .dateRange(range): "date:" + range.rawValue
        }
    }

    public var label: String {
        switch self {
        case let .provider(provider): AgentProvider(id: provider).displayName
        case let .workspace(_, name): name
        case let .dateRange(range): range.label
        }
    }

    public var systemImage: String {
        switch self {
        case .provider: "cpu"
        case .workspace: "folder"
        case .dateRange: "calendar"
        }
    }

    /// Keeps the newest chip of each kind, in the order they were added.
    public static func normalized(_ tokens: [ArchiveSearchToken]) -> [ArchiveSearchToken] {
        var seen = Set<Kind>()
        return tokens.reversed().filter { seen.insert($0.kind).inserted }.reversed()
    }
}

/// What the search field asks for, as SQL for this device's copy and as a
/// request for the host. Terms are always quoted, never query syntax, and the
/// last term matches as a prefix while it is being typed.
public struct ArchiveSearchQuery: Equatable, Sendable {
    public var text: String
    public var provider: String?
    public var projectID: String?
    /// Inclusive.
    public var from: Date?
    /// Exclusive.
    public var to: Date?

    public init(text: String, provider: String? = nil, projectID: String? = nil, from: Date? = nil, to: Date? = nil) {
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.provider = provider; self.projectID = projectID; self.from = from; self.to = to
    }

    public init(text: String, tokens: [ArchiveSearchToken], now: Date = Date(), calendar: Calendar = .current) {
        self.init(text: text)
        for token in tokens {
            switch token {
            case let .provider(provider): self.provider = provider
            case let .workspace(id, _): projectID = id
            case let .dateRange(range): (from, to) = range.bounds(now: now, calendar: calendar)
            }
        }
    }

    public var hasText: Bool { !terms.isEmpty }
    public var hasFilters: Bool { provider != nil || projectID != nil || from != nil || to != nil }

    /// Fields with at least one letter or digit, without the snippet markers.
    /// The last one loses trailing punctuation and `*`: it becomes a prefix.
    public var terms: [String] {
        var fields = text.split(whereSeparator: \.isWhitespace).map { field in
            String(field.unicodeScalars.filter { $0 != "\u{2}" && $0 != "\u{3}" })
        }.filter { $0.unicodeScalars.contains(where: Self.isWordScalar) }
        if let last = fields.popLast() {
            var scalars = String.UnicodeScalarView(last.unicodeScalars)
            while let end = scalars.last, !Self.isWordScalar(end) { scalars.removeLast() }
            fields.append(String(scalars))
        }
        return fields
    }

    /// The MATCH expression: quoted terms, all required, the last a prefix.
    public func matchExpression(for index: FullTextIndex) -> String? {
        let terms = terms
        guard !terms.isEmpty else { return nil }
        return terms.enumerated().map { position, term in
            let quoted = term.replacingOccurrences(of: "\"", with: "\"\"")
            guard position == terms.count - 1 else { return "\"" + quoted + "\"" }
            // FTS5 marks a quoted string as a prefix after the quote, FTS4 inside it.
            return index == .fts5 ? "\"" + quoted + "\"*" : "\"" + quoted + "*\""
        }.joined(separator: " ")
    }

    /// `q` for the host: its own quoting applies; `*` makes the last term a prefix.
    public var hostText: String? {
        let terms = terms
        guard let last = terms.last else { return nil }
        return (terms.dropLast() + [last + "*"]).joined(separator: " ")
    }

    public func hostRequest(limit: Int = 20, cursor: String? = nil) -> ArchiveSearchRequest? {
        guard let hostText else { return nil }
        return ArchiveSearchRequest(text: hostText, projectID: projectID, provider: provider, from: from, to: to, limit: limit, cursor: cursor)
    }

    /// The chat list with the same chips (last activity in the date range).
    public var chatFilter: ArchiveChatFilter { ArchiveChatFilter(projectID: projectID, provider: provider, from: from, to: to) }

    /// Every term appears in the title, ignoring case and diacritics.
    public func titleMatches(_ title: String) -> Bool {
        let terms = terms
        return !terms.isEmpty && terms.allSatisfy { title.localizedStandardContains($0) }
    }

    private static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isAlphabetic || scalar.properties.numericType != nil || scalar.properties.generalCategory == .privateUse
    }
}
