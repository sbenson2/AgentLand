import Foundation
import AgentLandCore

/// Keeps the Mac's peer gate on the host's list of paired devices' node IDs (docs/HOST-API.md "Routes
/// for the Mac app (local-only)", Peers): one `GET /v1/remote-access/peers` open at a time while the
/// endpoint runs and the host's local session lasts. The first request has no `after`, so the host
/// answers at once and the gate, which answers every connection with 503 until then, gets its first
/// list; each later one waits (`after` the version it has, `wait=20000`) and goes out again at once
/// after each answer and 1 s after an error. Each answer goes to `apply`, which gives the gate the
/// node IDs (`setAllowed`) and closes connections from node IDs no longer listed.
public enum RemoteAccessPeerFeed {
    public static let wait: TimeInterval = 20
    public static let retryDelay: Duration = .seconds(1)

    /// Runs until the task is cancelled.
    public static func run(
        fetch: @escaping @Sendable (_ after: String?, _ wait: TimeInterval?) async throws -> RemoteAccessPeers,
        apply: @escaping @Sendable (RemoteAccessPeers) async -> Void,
        clock: any NoticeRelayClock = SystemNoticeRelayClock()
    ) async {
        var version: String?
        while !Task.isCancelled {
            do {
                let answer = try await fetch(version, version == nil ? nil : wait)
                try Task.checkCancellation()
                await apply(answer)
                version = answer.version
            } catch {
                if Task.isCancelled || error is CancellationError { return }
                do { try await clock.sleep(for: retryDelay) } catch { return }
            }
        }
    }
}
