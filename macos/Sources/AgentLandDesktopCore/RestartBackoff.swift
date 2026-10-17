import Foundation

/// How often an owned child process that exits on its own is started again.
///
/// Every unexpected exit, and every restart attempt that fails, is one failure.
/// The first restart waits `delays[0]`, the next `delays[1]` and so on (the last
/// delay repeats), so a child that keeps exiting is never restarted in a tight
/// loop. When more than `limit` failures fall within `window`, the owner stops
/// trying and shows the error; failures older than the window no longer count,
/// so a child that crashes once a day is restarted every time.
public struct RestartBackoff: Sendable, Equatable {
    public enum Decision: Sendable, Equatable {
        /// Start the child again after this many seconds.
        case retry(after: TimeInterval)
        /// Too many failures in the window: stop and show the error.
        case giveUp(failures: Int)
    }

    public let delays: [TimeInterval]
    public let limit: Int
    public let window: TimeInterval
    public private(set) var failures: [Date] = []

    /// Defaults: 1, 2, 4, 8 and then 16 s before the first five attempts; the
    /// sixth failure within 10 minutes stops the restarts.
    public init(delays: [TimeInterval] = [1, 2, 4, 8, 16], limit: Int = 5, window: TimeInterval = 600) {
        precondition(!delays.isEmpty && delays.allSatisfy { $0 > 0 }, "restart delays must be positive")
        precondition(limit >= 1 && window > 0, "a restart limit needs a positive count and window")
        self.delays = delays
        self.limit = limit
        self.window = window
    }

    public mutating func recordFailure(at date: Date = Date()) -> Decision {
        failures = failures.filter { date.timeIntervalSince($0) < window && $0 <= date } + [date]
        if failures.count > limit { return .giveUp(failures: failures.count) }
        return .retry(after: delays[min(failures.count - 1, delays.count - 1)])
    }

    /// An explicit Connect or Disconnect starts counting afresh.
    public mutating func reset() { failures = [] }

    /// "10 minutes", "90 seconds": the window as the error message says it.
    public var windowDescription: String {
        let seconds = Int(window.rounded())
        if seconds >= 120, seconds % 60 == 0 { return "\(seconds / 60) minutes" }
        return seconds == 1 ? "1 second" : "\(seconds) seconds"
    }
}
