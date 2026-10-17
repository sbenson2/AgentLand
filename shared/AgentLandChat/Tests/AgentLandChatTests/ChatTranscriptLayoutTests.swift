import SwiftUI
import XCTest
import Observation
import AgentLandCore
@testable import AgentLandChat

/// What the transcript's layout reports reaches its state only as decisions, once they settle. The lazy transcript
/// places rows at passing positions while it measures them; state written for each of those re-evaluated the
/// conversation, which placed the rows again (with a reply taller than the screen, for seconds on the Mac).
@MainActor final class ChatTranscriptGeometryTests: XCTestCase {
    /// A scroll place as the view acts on it, for a transcript of `content` pt in a view of 700 pt whose composer takes
    /// the bottom 100: `visibleMaxY` is the visible rect's bottom, in content coordinates.
    private func place(content: CGFloat = 2000, visibleMaxY: CGFloat) -> ChatScrollPlace {
        ChatScrollPlace(contentHeight: content, topInset: 0, bottomInset: 100, visibleMaxY: visibleMaxY, containerHeight: 700)
    }

    /// SwiftUI calls the scroll action when the place changes. Points of scrolling, and the passing positions of a
    /// layout pass, change it only where the view acts differently: its end, a screen from it, past it.
    func testTheScrollPlaceChangesOnlyWhereTheViewActsDifferently() {
        // The end is at 2100 (content and the composer's inset). A layout pass moving the view by fractions of a point,
        // and scrolling within 24 pt of the end, are one place: one call of the action.
        let settled = [2100, 2099.5, 2090.25, 2080, 2076].map { place(visibleMaxY: $0) }
        XCTAssertTrue(settled.allSatisfy { $0 == settled[0] })
        XCTAssertTrue(settled[0].atEnd)
        XCTAssertFalse(place(visibleMaxY: 2075).atEnd, "25 pt from the end: scrolling there no longer follows")
        XCTAssertFalse(place(visibleMaxY: 1401).screenAway, "699 pt from the end: within a screen")
        XCTAssertTrue(place(visibleMaxY: 1399).screenAway, "701 pt from the end: Jump to Latest")
        XCTAssertFalse(place(visibleMaxY: 2101).pastEnd, "1 pt past the end: not yet")
        XCTAssertTrue(place(visibleMaxY: 2102).pastEnd, "2 pt past the end: the view grew past it")
        XCTAssertFalse(place(content: 300, visibleMaxY: 800).pastEnd, "Content shorter than the view is never past its end")
    }

    /// A card is in view when its bottom edge, with its buttons, is above the composer and at least 88 pt (or the whole
    /// card, when it is shorter) below the top of the transcript.
    func testACardIsInViewWithItsButtonsAboveTheComposer() async {
        let geometry = ChatTranscriptGeometry()
        geometry.transcriptFrame = CGRect(x: 0, y: 100, width: 400, height: 700)
        geometry.composerTop = 700
        geometry.cardMoved("above-composer", to: CGRect(x: 0, y: 500, width: 400, height: 200))
        geometry.cardMoved("under-composer", to: CGRect(x: 0, y: 520, width: 400, height: 200))
        geometry.cardMoved("under-header", to: CGRect(x: 0, y: -100, width: 400, height: 287))
        geometry.cardMoved("short-below-header", to: CGRect(x: 0, y: 100, width: 400, height: 60))
        await Task.yield()
        XCTAssertEqual(geometry.visibleCards, ["above-composer", "short-below-header"])
        geometry.cardGone("above-composer")
        await Task.yield()
        XCTAssertEqual(geometry.visibleCards, ["short-below-header"], "A card that left the screen is not in view")
    }

    /// The passing positions of a layout pass never reach the view: the cards in view are decided after the layout, from
    /// the latest reports, and published once.
    func testCardReportsWithinALayoutPassArePublishedOnceAfterIt() async {
        let geometry = ChatTranscriptGeometry()
        geometry.transcriptFrame = CGRect(x: 0, y: 100, width: 400, height: 700)
        geometry.composerTop = 700
        let published = Count()
        withObservationTracking { _ = geometry.visibleCards } onChange: { published.add() }
        for y in [353.0, -466, 576, 387, 57, 387] {
            geometry.cardMoved("per_1", to: CGRect(x: 0, y: y, width: 400, height: 120))
        }
        XCTAssertEqual(geometry.visibleCards, [], "Nothing is published during the layout")
        await Task.yield()
        XCTAssertEqual(geometry.visibleCards, ["per_1"], "Its latest place, 387 to 507, is in view")
        XCTAssertEqual(published.value, 1)
    }

    /// A pass whose passing positions end where they started publishes nothing: the view is not evaluated again.
    func testALayoutPassThatEndsWhereItStartedPublishesNothing() async {
        let geometry = ChatTranscriptGeometry()
        geometry.transcriptFrame = CGRect(x: 0, y: 100, width: 400, height: 700)
        geometry.composerTop = 700
        geometry.cardMoved("per_1", to: CGRect(x: 0, y: 387, width: 400, height: 120))
        await Task.yield()
        XCTAssertEqual(geometry.visibleCards, ["per_1"])
        let published = Count()
        withObservationTracking { _ = geometry.visibleCards } onChange: { published.add() }
        for y in [576.0, -466, 387] { geometry.cardMoved("per_1", to: CGRect(x: 0, y: y, width: 400, height: 120)) }
        geometry.composerTop = 690
        geometry.composerTop = 700
        await Task.yield()
        XCTAssertEqual(published.value, 0)
    }

    /// The row at the top of the view, where a new text size puts the reader back: the first row in the transcript's order
    /// that is on screen, as the rows report their visibility (an answered card's row leaves).
    func testTheTopRowIsTheFirstVisibleOneInOrder() {
        let geometry = ChatTranscriptGeometry()
        let order = ["user-u1", "reply-u1", "user-u2", "reply-u2", "interaction-per_1"]
        XCTAssertNil(geometry.firstVisibleRow(in: order), "Nothing reported yet")
        for id in ["user-u2", "reply-u2", "reply-u1"] { geometry.rowVisibility(id, visible: true) }
        XCTAssertEqual(geometry.firstVisibleRow(in: order), "reply-u1", "The tall reply reaching the top of the view")
        geometry.rowVisibility("reply-u1", visible: false)
        XCTAssertEqual(geometry.firstVisibleRow(in: order), "user-u2")
        XCTAssertNil(geometry.firstVisibleRow(in: ["user-u1"]), "A row no longer in the transcript is not its top")
    }

    /// Work that waits for the layout (the settle on the latest row of a view that grew past the end) runs once the layout
    /// is done: once however often a pass asks for it, with the place the pass ended at, never with a passing one.
    func testWorkAfterTheLayoutRunsOnceWithThePlaceItEndedAt() async {
        let geometry = ChatTranscriptGeometry()
        let ran = Count()
        var places: [ChatScrollPlace?] = []
        geometry.place = place(visibleMaxY: 2150)
        geometry.afterLayout { _ in ran.add() }
        geometry.afterLayout { place in ran.add(); places.append(place) }
        geometry.place = place(visibleMaxY: 2100)
        XCTAssertEqual(ran.value, 0, "Not during the layout")
        await Task.yield()
        XCTAssertEqual(ran.value, 1, "Once, after it: the latest work asked for")
        XCTAssertEqual(places, [place(visibleMaxY: 2100)], "With the place the pass ended at")
    }
}

/// How many times an observed value was published.
private final class Count: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func add() { lock.withLock { count += 1 } }
}

#if os(macOS)
import AppKit

/// The transcript in a real AppKit window, as the Mac app hosts it, with a reply taller than the window above an
/// approval card: the lazy stack places its rows at passing positions while it measures that reply.
@MainActor final class ChatTranscriptLayoutRenderTests: XCTestCase {
    /// A chat of 60 lines, then a running command that waits on its approval.
    static func tallChat() -> String {
        let lines = (1...60).map { String(format: "Scroll line %02d", $0) }.joined(separator: "\\n")
        return #"{"seq":0,"type":"snapshot","chat":{"id":"s","title":"Tall","provider":"opencode"},"messages":["#
            + #"{"id":"u1","role":"user","turnId":"u1","ord":1,"parts":[{"id":"u1p","kind":"text","text":"Make the chat tall"}]},"#
            + #"{"id":"a1","role":"assistant","turnId":"u1","ord":2,"status":"complete","parts":[{"id":"a1x","kind":"text","text":"\#(lines)"}]},"#
            + #"{"id":"u2","role":"user","turnId":"u2","ord":3,"parts":[{"id":"u2p","kind":"text","text":"Run the proof command"}]},"#
            + #"{"id":"a2","role":"assistant","turnId":"u2","ord":4,"status":"streaming","parts":[{"id":"a2t","kind":"tool","ord":1,"tool":{"name":"bash","status":"running","input":"{\"command\":\"echo approved > proof.txt\"}"}}]}"#
            + #"],"hasMore":false,"status":{"state":"waiting"},"interactions":["#
            + #"{"id":"per_1","chatId":"s","kind":"permission","choices":["once","reject"],"permission":{"tool":"bash","title":"echo approved > proof.txt","input":"{\"command\":\"echo approved > proof.txt\"}"}}"#
            + #"],"queue":[]}"#
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews)
    }

    /// How far the transcript is from its end: its end sits at the bottom of the view, above the composer's inset.
    private func distanceFromEnd(_ scroll: NSScrollView) -> CGFloat {
        (scroll.documentView?.frame.height ?? 0) + scroll.contentInsets.bottom - scroll.contentView.bounds.maxY
    }

    /// At its end, as the chat has it: the latest row's bottom edge at the bottom of the view, with at most the
    /// transcript's 12 pt bottom padding under it (Jump to Latest scrolls to the row), never past the end.
    private let atEnd: ClosedRange<CGFloat> = -1...13

    /// The distance from the end once the transcript is at its end, or after 5 s. While the lazy stack still measures
    /// the rows it estimated, the scroll view's height is an estimate (a debug build takes seconds with 60 lines).
    private func settledDistance(_ scroll: NSScrollView) async throws -> CGFloat {
        let deadline = Date().addingTimeInterval(5)
        while !atEnd.contains(distanceFromEnd(scroll)) && Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        return distanceFromEnd(scroll)
    }

    /// A following chat stays at its end while its view grows (a window made taller; on iPhone, the keyboard going
    /// away). Before, the transcript's geometry wrote state for passing positions, which placed the rows again: each
    /// step of 34 pt took most of a second, and the chat ended 98 pt short of its end for good, its card under the
    /// composer.
    func testAFollowingChatStaysAtItsEndWhileItsViewGrows() async throws {
        let host = ScriptedHost()
        host.enqueue([#"{"seq":0,"type":"ready","cursor":"e.0","resumed":false}"#, Self.tallChat()])
        let store = ChatSessionStore(identity: .init(hostID: "mac", projectID: "p", sessionID: "s", tabID: UUID()))
        let client = APIClient(address: try ServerAddress(validating: "https://mac.example"), token: "t", transport: host)
        let capabilities = CapabilitiesResponse(interactions: true, terminal: true, chatProviders: ["opencode"],
                                                chatFeatures: ["events", "parts", "stop", "clientMessageId"])
        store.update(.init(client: client, capabilities: capabilities, reachable: true, connectionEpoch: 0, active: true, refreshGeneration: nil))
        let deadline = Date().addingTimeInterval(5)
        while !(store.hasContent && store.isResolved(for: nil)) && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(store.interactions.count, 1)

        let view = NSHostingView(rootView: ChatScreen(store: store, inputEnabled: true) { EmptyView() })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 402, height: 540), styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.contentView = view
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(300))
        let scroll = try XCTUnwrap(scrollViews(in: view).first, "the transcript's scroll view")
        let opened = try await settledDistance(scroll)
        XCTAssertTrue(atEnd.contains(opened), "The chat opens at its end: \(opened) pt from it")

        for _ in 1...10 {
            var frame = window.frame
            frame.size.height += 34
            frame.origin.y -= 34
            window.setFrame(frame, display: true)
            try await Task.sleep(for: .milliseconds(16))
        }
        let grown = try await settledDistance(scroll)
        XCTAssertTrue(atEnd.contains(grown), "The chat follows its latest row, the card, as its view grows: \(grown) pt from its end")
    }
}
#endif
