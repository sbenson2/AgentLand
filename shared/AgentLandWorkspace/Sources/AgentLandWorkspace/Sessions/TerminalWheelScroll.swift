import CoreGraphics
import Foundation

/// Turns a vertical touch drag into mouse-wheel steps for a terminal program that reads the wheel
/// (it turned on mouse reporting, as OpenCode does): one step per row of travel, with the remainder
/// kept for the next movement and at most `maximumStepsPerMove` at once. A drag down shows earlier
/// lines, which is the wheel turning up.
struct TerminalWheelScroll: Equatable {
    enum Direction: Equatable { case up, down }

    /// Steps sent for one movement at most; a faster drag drops the rest rather than falling behind.
    static let maximumStepsPerMove = 8
    /// A release slower than this (points per second) stops at once; a faster one coasts.
    static let minimumCoastSpeed: CGFloat = 200
    /// Coasting stops below this speed.
    static let stopSpeed: CGFloat = 60
    /// The coast slows by this factor every millisecond, like a scroll view's normal deceleration.
    static let decelerationPerMillisecond: CGFloat = 0.998

    private(set) var remainder: CGFloat = 0

    /// The wheel steps for `travel` points of vertical movement (positive is down), or nil while the
    /// movement since the last step is less than a row.
    mutating func steps(forTravel travel: CGFloat, rowHeight: CGFloat) -> (direction: Direction, count: Int)? {
        guard rowHeight > 0, travel.isFinite else { return nil }
        remainder += travel
        let rows = Int(remainder / rowHeight)
        guard rows != 0 else { return nil }
        remainder -= CGFloat(rows) * rowHeight
        return (rows > 0 ? .up : .down, min(abs(rows), Self.maximumStepsPerMove))
    }

    mutating func reset() { remainder = 0 }

    /// The coasting speed after `elapsed` seconds at `speed`, or nil once the coast has stopped.
    static func coast(_ speed: CGFloat, elapsed: TimeInterval) -> CGFloat? {
        guard speed.isFinite, elapsed > 0 else { return nil }
        let next = speed * pow(decelerationPerMillisecond, CGFloat(elapsed * 1000))
        return abs(next) < stopSpeed ? nil : next
    }
}
