import Foundation
import SwiftUI
import XCTest
import AgentLandCore
@testable import AgentLandArchive

final class LibraryAndSearchTests: XCTestCase {
    private func calendar(_ zone: String, firstWeekday: Int = 1) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        calendar.firstWeekday = firstWeekday
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }

    private func date(_ text: String) -> Date { ChatTime.date(text)! }

    private func chat(_ id: String, _ updated: String, pinned: Bool = false) -> ArchivedChat {
        ArchivedChat(id: id, projectID: "p1", provider: "claude", title: id, createdAt: date(updated), updatedAt: date(updated), pinned: pinned)
    }

    // MARK: Library grouping

    func testGroupsAcrossDayBoundariesAndTimeZones() {
        // Wednesday 2026-09-23 23:30 in Los Angeles is already Thursday 15:30 in Tokyo.
        let now = date("2026-09-24T06:30:00.000Z")
        let chats = [
            chat("a", "2026-09-24T06:00:00.000Z"),   // LA Sep 23 23:00 · Tokyo Sep 24 15:00
            chat("b", "2026-09-23T07:30:00.000Z"),   // LA Sep 23 00:30 · Tokyo Sep 23 16:30
            chat("c", "2026-09-23T06:59:00.000Z"),   // LA Sep 22 23:59 · Tokyo Sep 23 15:59
            chat("d", "2026-09-21T12:00:00.000Z"),   // LA Mon Sep 21 · Tokyo Mon Sep 21 21:00
            chat("e", "2026-09-20T06:00:00.000Z"),   // LA Sat Sep 19 23:00 · Tokyo Sun Sep 20 15:00
            chat("f", "2026-08-31T12:00:00.000Z"),
            chat("g", "2025-12-01T12:00:00.000Z"),
            chat("pinned", "2024-01-01T00:00:00.000Z", pinned: true),
            chat("ahead", "2026-09-24T07:00:00.000Z")  // a clock slightly ahead: still today
        ]
        let losAngeles = ChatLibrary.groups(chats, now: now, calendar: calendar("America/Los_Angeles"), locale: Locale(identifier: "en_US"))
        XCTAssertEqual(losAngeles.map(\.title), ["Pinned", "Today", "Yesterday", "This Week", "September 2026", "August 2026", "December 2025"])
        XCTAssertEqual(losAngeles.map { $0.chats.map(\.id) }, [["pinned"], ["ahead", "a", "b"], ["c"], ["d"], ["e"], ["f"], ["g"]])

        let tokyo = ChatLibrary.groups(chats, now: now, calendar: calendar("Asia/Tokyo"), locale: Locale(identifier: "en_US"))
        XCTAssertEqual(tokyo.map(\.title), ["Pinned", "Today", "Yesterday", "This Week", "August 2026", "December 2025"])
        XCTAssertEqual(tokyo.map { $0.chats.map(\.id) }, [["pinned"], ["ahead", "a"], ["b", "c"], ["d", "e"], ["f"], ["g"]])

        // A Monday week start moves Sunday's chat out of this week.
        let mondayWeeks = ChatLibrary.groups(chats, now: now, calendar: calendar("Asia/Tokyo", firstWeekday: 2), locale: Locale(identifier: "en_US"))
        XCTAssertEqual(mondayWeeks.first { $0.section == .thisWeek }?.chats.map(\.id), ["d"])
        XCTAssertEqual(mondayWeeks.first { $0.section == .month(year: 2026, month: 9) }?.chats.map(\.id), ["e"])
    }

    func testYesterdayIsACalendarDayAcrossADaylightSavingChange() {
        // US daylight saving ends on Sunday 2026-11-01; that day has 25 hours.
        let losAngeles = calendar("America/Los_Angeles")
        let now = date("2026-11-02T08:30:00.000Z")                 // Mon Nov 2 00:30 PST
        let earlyYesterday = date("2026-11-01T07:30:00.000Z")      // Sun Nov 1 00:30 PDT
        XCTAssertEqual(ChatLibrary.section(for: earlyYesterday, now: now, calendar: losAngeles), .yesterday)
        XCTAssertEqual(ChatLibrary.section(for: date("2026-11-01T06:59:00.000Z"), now: now, calendar: losAngeles), .month(year: 2026, month: 10),
                       "Saturday before a Sunday week start is last week")
        let bounds = ArchiveDateRange.yesterday.bounds(now: now, calendar: losAngeles)
        XCTAssertEqual(bounds.from, date("2026-11-01T07:00:00.000Z"), "Midnight PDT, not 24 hours before midnight PST")
        XCTAssertEqual(bounds.to, date("2026-11-02T08:00:00.000Z"))
    }

    func testRowTimesFollowMessages() {
        let tz = calendar("UTC")
        let now = date("2026-09-24T15:00:00.000Z")   // Thursday
        let locale = Locale(identifier: "en_US")
        XCTAssertEqual(ChatLibrary.rowTime(date("2026-09-24T09:05:00.000Z"), now: now, calendar: tz, locale: locale), "9:05\u{202F}AM")
        XCTAssertEqual(ChatLibrary.rowTime(date("2026-09-23T09:05:00.000Z"), now: now, calendar: tz, locale: locale), "Yesterday")
        XCTAssertEqual(ChatLibrary.rowTime(date("2026-09-21T09:05:00.000Z"), now: now, calendar: tz, locale: locale), "Monday")
        XCTAssertEqual(ChatLibrary.rowTime(date("2026-08-02T09:05:00.000Z"), now: now, calendar: tz, locale: locale), "8/2/2026")
    }

    // MARK: Snippets

    func testSnippetMarkersBecomeEmphasis() {
        let snippet = "…the session \u{2}cookie\u{3} is set\nfor the wrong  domain, so \u{2}every redirect\u{3} starts over…"
        XCTAssertEqual(ArchiveSnippet.segments(snippet), [
            .init("…the session ", isMatch: false), .init("cookie", isMatch: true),
            .init(" is set for the wrong domain, so ", isMatch: false), .init("every redirect", isMatch: true),
            .init(" starts over…", isMatch: false)
        ])
        XCTAssertEqual(ArchiveSnippet.plainText(snippet), "…the session cookie is set for the wrong domain, so every redirect starts over…")
        XCTAssertEqual(ArchiveSnippet.segments("\u{2}open"), [.init("open", isMatch: true)], "An unclosed match runs to the end")
        XCTAssertEqual(ArchiveSnippet.segments("stray\u{3} end \u{2}\u{3}"), [.init("stray end", isMatch: false)])

        let attributed = ArchiveSnippet.attributedString(snippet, matchColor: .red)
        let emphasized = attributed.runs.filter { $0.inlinePresentationIntent == .stronglyEmphasized }.map { String(attributed[$0.range].characters) }
        XCTAssertEqual(emphasized, ["cookie", "every redirect"])
        XCTAssertEqual(attributed.runs.filter { $0.foregroundColor == .red }.count, 2)
        XCTAssertFalse(String(attributed.characters).contains("\u{2}"))
    }

    // MARK: Search tokens and queries

    func testTokensMapToTheQueryAndTheHostRequest() {
        let tz = calendar("America/Los_Angeles")
        let now = date("2026-09-24T06:30:00.000Z")   // Sep 23 23:30 PDT
        let tokens: [ArchiveSearchToken] = [.provider("codex"), .workspace(id: "p1", name: "web-app"), .dateRange(.past7Days), .provider("claude")]
        let query = ArchiveSearchQuery(text: "  cookie   loop.  ", tokens: ArchiveSearchToken.normalized(tokens), now: now, calendar: tz)
        XCTAssertEqual(query.provider, "claude", "The newer chip of a kind wins")
        XCTAssertEqual(query.projectID, "p1")
        XCTAssertEqual(query.from, date("2026-09-17T07:00:00.000Z"), "Seven calendar days including today, from local midnight")
        XCTAssertNil(query.to)
        XCTAssertEqual(query.terms, ["cookie", "loop"])
        XCTAssertEqual(query.matchExpression(for: .fts5), #""cookie" "loop"*"#)
        XCTAssertEqual(query.matchExpression(for: .fts4), #""cookie" "loop*""#)
        let request = query.hostRequest(limit: 20)
        XCTAssertEqual(request?.text, "cookie loop*")
        XCTAssertEqual(request?.provider, "claude")
        XCTAssertEqual(request?.projectID, "p1")
        XCTAssertEqual(request?.from, query.from)
        XCTAssertEqual(query.chatFilter, ArchiveChatFilter(projectID: "p1", provider: "claude", from: query.from, to: nil))
        XCTAssertEqual(ArchiveSearchToken.normalized(tokens).map(\.id), ["workspace:p1", "date:past7Days", "provider:claude"])

        let today = ArchiveSearchQuery(text: "", tokens: [.dateRange(.today)], now: now, calendar: tz)
        XCTAssertEqual(today.from, date("2026-09-23T07:00:00.000Z"))
        XCTAssertFalse(today.hasText)
        XCTAssertTrue(today.hasFilters)
        XCTAssertNil(today.hostRequest(), "The host needs text; chips alone filter the library")
    }

    func testTermsAreQuotedNeverQuerySyntax() {
        XCTAssertEqual(ArchiveSearchQuery(text: #"say "hi" OR NEAR(x) -y"#).matchExpression(for: .fts5), #""say" """hi""" "OR" "NEAR(x)" "-y"*"#)
        XCTAssertEqual(ArchiveSearchQuery(text: "* ** --").matchExpression(for: .fts5), nil, "Fields without letters or digits are dropped")
        XCTAssertEqual(ArchiveSearchQuery(text: "sessi*").hostText, "sessi*")
        XCTAssertEqual(ArchiveSearchQuery(text: "crème\u{2}").terms, ["crème"], "Snippet markers never reach the index")
        XCTAssertTrue(ArchiveSearchQuery(text: "LOGIN loop").titleMatches("Fix the login loop"))
        XCTAssertFalse(ArchiveSearchQuery(text: "login cookie").titleMatches("Fix the login loop"))
        XCTAssertTrue(ArchiveSearchQuery(text: "creme").titleMatches("Crème brûlée"), "Diacritics are ignored in titles")
    }
}
