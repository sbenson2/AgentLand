import SwiftUI
import Observation

/// Where the transcript is scrolled, in the terms the view acts on. SwiftUI calls a scroll-geometry action whenever its
/// value changes: as distances, that was every point of scrolling and every passing position of a layout pass, and each
/// call wrote state that evaluated the conversation again. As this, only where the view acts differently.
struct ChatScrollPlace: Equatable {
    /// Within 24 pt of the end: the person scrolling there follows the chat again.
    let atEnd: Bool
    /// More than the view's height from the end: Jump to Latest shows.
    let screenAway: Bool
    /// The view shows more than 1 pt past the end of content taller than it: it grew, as when the keyboard goes away.
    let pastEnd: Bool

    /// `visibleMaxY` is the bottom of the visible rect in content coordinates; the end is the content's height and the
    /// bottom inset (the composer, and the keyboard) below it.
    init(contentHeight: CGFloat, topInset: CGFloat, bottomInset: CGFloat, visibleMaxY: CGFloat, containerHeight: CGFloat) {
        let end = contentHeight + bottomInset
        let distance = max(0, end - visibleMaxY)
        atEnd = distance <= 24
        screenAway = distance > max(containerHeight, 1)
        pastEnd = contentHeight + topInset + bottomInset > containerHeight && visibleMaxY - end > 1
    }

    init(_ geometry: ScrollGeometry) {
        self.init(contentHeight: geometry.contentSize.height, topInset: geometry.contentInsets.top,
                  bottomInset: geometry.contentInsets.bottom, visibleMaxY: geometry.visibleRect.maxY,
                  containerHeight: geometry.containerSize.height)
    }
}

/// What the transcript's layout reports, held out of SwiftUI's state. The lazy transcript places its rows at passing
/// positions while it measures them (a reply taller than the screen moves the rows around it by hundreds of points),
/// and state written for each report evaluated the conversation again, which placed the rows again: on the Mac that
/// took most of a second per step of a growing window and left a following chat short of its end. Frames land here;
/// which cards are in view is decided once per turn of the main run loop, after the layout, from the latest reports,
/// and published only when it changed; and the rows report whether they are on screen, for the row at the top.
@MainActor @Observable final class ChatTranscriptGeometry {
    /// The approval and question cards whose buttons are in view: the card's bottom edge above the composer, and at
    /// least 88 pt (or the whole card, when it is shorter) below the top of the transcript.
    private(set) var visibleCards: Set<String> = []
    /// The transcript's frame, from under the header down (global coordinates).
    @ObservationIgnored var transcriptFrame: CGRect = .zero { didSet { if transcriptFrame != oldValue { decideLater() } } }
    /// The top of the composer (global coordinates).
    @ObservationIgnored var composerTop: CGFloat = .infinity { didSet { if composerTop != oldValue { decideLater() } } }
    /// The transcript's scroll place, as its latest change left it.
    @ObservationIgnored var place: ChatScrollPlace?
    @ObservationIgnored private var cards: [String: CGRect] = [:]
    @ObservationIgnored private var visibleRows: Set<String> = []
    @ObservationIgnored private var deciding = false
    @ObservationIgnored private var settling = false
    @ObservationIgnored private var afterLayoutWork: (@MainActor (ChatScrollPlace?) -> Void)?

    /// A card's frame (global coordinates), as the layout placed it.
    func cardMoved(_ id: String, to frame: CGRect) {
        cards[id] = frame
        decideLater()
    }

    /// A card left the screen (answered, or scrolled far enough for the lazy transcript to let its row go).
    func cardGone(_ id: String) {
        if cards.removeValue(forKey: id) != nil { decideLater() }
    }

    /// A row came on screen or left it (`onScrollVisibilityChange`).
    func rowVisibility(_ id: String, visible: Bool) {
        if visible { visibleRows.insert(id) } else { visibleRows.remove(id) }
    }

    /// The row at the top of the view: the first row of `order` (the transcript's rows, top to bottom) on screen.
    func firstVisibleRow(in order: [String]) -> String? {
        order.first { visibleRows.contains($0) }
    }

    /// Runs `work` once the layout is done, with the place it ended at (the settle on the latest row): asked for any
    /// number of times during a layout pass, it runs once, the latest `work` asked for.
    func afterLayout(_ work: @escaping @MainActor (ChatScrollPlace?) -> Void) {
        afterLayoutWork = work
        guard !settling else { return }
        settling = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            settling = false
            let work = afterLayoutWork
            afterLayoutWork = nil
            work?(place)
        }
    }

    /// The part of the screen between the header and the composer.
    private var viewport: CGRect {
        var frame = transcriptFrame
        frame.size.height = max(0, min(frame.maxY, composerTop) - frame.minY)
        return frame
    }

    private func decideLater() {
        guard !deciding else { return }
        deciding = true
        Task { @MainActor [weak self] in self?.decide() }
    }

    private func decide() {
        deciding = false
        let viewport = viewport
        let visible = Set(cards.filter { _, frame in
            frame.maxY <= viewport.maxY + 1 && frame.maxY >= viewport.minY + min(frame.height, 88)
        }.keys)
        if visible != visibleCards { visibleCards = visible }
    }
}
