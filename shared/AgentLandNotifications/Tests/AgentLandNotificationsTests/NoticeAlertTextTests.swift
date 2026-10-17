import Foundation
import XCTest
@testable import AgentLandNotifications

final class NoticeAlertTextTests: XCTestCase {
    func testEveryKindHasItsTitleInTheCatalog() {
        let titles = Dictionary(uniqueKeysWithValues: NoticeKind.allCases.map { ($0, $0.title) })
        XCTAssertEqual(titles, [
            .turnFinished: "Reply ready",
            .turnFailed: "Reply failed",
            .approvalNeeded: "Needs your approval",
            .questionNeeded: "Question for you"
        ])
        XCTAssertEqual(NoticeKind.turnFinished.titleLocalizationKey, "notice.title.chat.turn.finished")
        XCTAssertEqual(NoticeKind.questionNeeded.titleLocalizationKey, "notice.title.chat.question.needed")
        XCTAssertEqual(NoticeAlertText.localized(NoticeAlertText.bodyLocalizationKey), "%@")
        XCTAssertEqual(NoticeAlertText.testTitle, "Test from AgentLand")
        XCTAssertEqual(NoticeAlertText.appLocalizationKeys.count, 5)
        for key in NoticeAlertText.appLocalizationKeys {
            XCTAssertNotEqual(NoticeAlertText.localized(key), key, "\(key) is missing from Localizable.xcstrings")
        }
    }

    func testBodyIsTitleAndProjectOrTheProjectAlone() {
        XCTAssertEqual(NoticeAlertText.body(title: "Fix the login", projectName: "AgentLand"), "Fix the login · AgentLand")
        XCTAssertEqual(NoticeAlertText.body(title: nil, projectName: "AgentLand"), "AgentLand")
        XCTAssertEqual(NoticeAlertText.body(title: "  ", projectName: "AgentLand"), "AgentLand")
        XCTAssertEqual(NoticeAlertText.body(title: "Nightly tests", projectName: ""), "Nightly tests")
        XCTAssertEqual(NoticeAlertText.body(title: "Two\nlines", projectName: "A\tB"), "Two lines · A B")
    }

    func testBodyStaysWithinWhatCloudKitCopiesIntoAPush() {
        let title = String(repeating: "word ", count: 60)
        let project = String(repeating: "p", count: 80)
        let body = NoticeAlertText.body(title: title, projectName: project)
        XCTAssertLessThanOrEqual(body.utf16.count, NoticeAlertText.pushValueLimit)
        XCTAssertTrue(body.hasSuffix(" · " + String(repeating: "p", count: 39) + "…"), body)
        XCTAssertTrue(body.hasPrefix("word word"))
        XCTAssertTrue(body.contains("… · "), "the title is cut with an ellipsis")

        // Emoji and other characters of two UTF-16 units are never split.
        let emoji = String(repeating: "🎪", count: 80)
        let cut = NoticeAlertText.body(title: emoji, projectName: "AgentLand")
        XCTAssertLessThanOrEqual(cut.utf16.count, NoticeAlertText.pushValueLimit)
        XCTAssertTrue(cut.hasSuffix("🎪… · AgentLand"), cut)
        XCTAssertEqual(NoticeAlertText.body(title: nil, projectName: emoji).utf16.count, NoticeAlertText.projectNameLimit - 1)
    }

    func testTruncationKeepsShortTextAndTrimsBeforeTheEllipsis() {
        XCTAssertEqual(NoticeAlertText.truncated("short", limit: 10), "short")
        XCTAssertEqual(NoticeAlertText.truncated("exactly10!", limit: 10), "exactly10!")
        XCTAssertEqual(NoticeAlertText.truncated("abcd efghij", limit: 6), "abcd…")
        XCTAssertEqual(NoticeAlertText.truncated("abc", limit: 1), "…")
        XCTAssertEqual(NoticeAlertText.truncated("abc", limit: 0), "")
        XCTAssertEqual(NoticeAlertText.singleLine(" a \r\n\u{7}b  c "), "a b c")
    }

    func testAppBundleCheckFindsMissingKeys() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("notice-strings-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let english = directory.appendingPathComponent("en.lproj")
        try FileManager.default.createDirectory(at: english, withIntermediateDirectories: true)
        var strings = NoticeAlertText.appLocalizationKeys.dropLast(2).map { "\"\($0)\" = \"\(NoticeAlertText.localized($0))\";" }
        strings.append("\"\(NoticeKind.questionNeeded.titleLocalizationKey)\" = \"Something else\";")
        try strings.joined(separator: "\n").write(to: english.appendingPathComponent("Localizable.strings"), atomically: true, encoding: .utf8)
        let bundle = try XCTUnwrap(Bundle(url: directory))
        XCTAssertEqual(NoticeAlertText.keysMissingOrDifferent(in: bundle),
                       [NoticeKind.questionNeeded.titleLocalizationKey, NoticeAlertText.bodyLocalizationKey])
    }
}
