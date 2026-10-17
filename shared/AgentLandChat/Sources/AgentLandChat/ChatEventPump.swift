import Foundation
import AgentLandCore

/// Reads one chat event stream, decodes its lines off the main thread and
/// hands them on in batches at most `interval` apart (30 per second by
/// default), so a fast reply costs one layout pass per frame. Consecutive
/// deltas of one part join into a single event on the way.
public actor ChatEventPump {
    public enum Output: Sendable {
        case events([ChatEventEnvelope])
        /// The stream ended without an error (the host closed it).
        case finished
        case failed(any Error)
    }

    public nonisolated let outputs: AsyncStream<Output>
    private let continuation: AsyncStream<Output>.Continuation
    private let interval: Duration
    private let clock = ContinuousClock()
    private var pending: [ChatEventEnvelope] = []
    private var lastFlush: ContinuousClock.Instant?
    private var flushScheduled = false
    private var reader: Task<Void, Never>?
    private var closed = false
    /// Lines that could not be decoded; skipped, and counted for tests.
    public private(set) var skippedLines = 0

    public init(interval: Duration = .milliseconds(33)) {
        self.interval = interval
        (outputs, continuation) = AsyncStream.makeStream(of: Output.self)
    }

    /// Starts reading. Call once per pump.
    public func start(_ lines: AsyncThrowingStream<String, Error>) {
        guard reader == nil, !closed else { return }
        reader = Task { await self.read(lines) }
    }

    /// Stops reading; the stream's connection is cancelled with it.
    public func stop() {
        reader?.cancel()
        close()
    }

    private func read(_ lines: AsyncThrowingStream<String, Error>) async {
        do {
            for try await line in lines {
                if Task.isCancelled { break }
                guard !line.isEmpty else { continue }
                guard let envelope = try? ChatEventEnvelope.decode(line: line) else {
                    skippedLines += 1
                    continue
                }
                receive(envelope)
            }
            flush()
            if !closed { continuation.yield(.finished) }
        } catch {
            flush()
            if !closed { continuation.yield(.failed(error)) }
        }
        close()
    }

    private func receive(_ envelope: ChatEventEnvelope) {
        enqueue(envelope)
        switch envelope.event {
        case .ready, .snapshot, .end, .stopping, .unauthorized:
            // State changes a person waits on, and stream control, go at once.
            flush()
            return
        default:
            break
        }
        let now = clock.now
        if let lastFlush, now - lastFlush < interval {
            guard !flushScheduled else { return }
            flushScheduled = true
            let deadline = lastFlush + interval
            Task { [clock] in
                try? await clock.sleep(until: deadline)
                self.scheduledFlush()
            }
        } else {
            flush()
        }
    }

    private func scheduledFlush() {
        flushScheduled = false
        flush()
    }

    private func enqueue(_ envelope: ChatEventEnvelope) {
        if case let .partDelta(next) = envelope.event, let last = pending.last, case let .partDelta(previous) = last.event,
           previous.messageID == next.messageID, previous.partID == next.partID, previous.field == next.field,
           previous.offset + previous.delta.utf8.count == next.offset {
            var merged = previous
            merged.delta += next.delta
            pending[pending.count - 1] = ChatEventEnvelope(seq: envelope.seq, event: .partDelta(merged))
            return
        }
        pending.append(envelope)
    }

    private func flush() {
        guard !pending.isEmpty, !closed else { return }
        continuation.yield(.events(pending))
        pending = []
        lastFlush = clock.now
    }

    private func close() {
        guard !closed else { return }
        closed = true
        continuation.finish()
    }
}
