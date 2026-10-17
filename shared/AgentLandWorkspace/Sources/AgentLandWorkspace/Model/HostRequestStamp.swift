import Foundation
import AgentLandCore

/// What a request was made for: the attached host and its client connection. Its answer counts only while
/// both are still the workspace's (the Settings panes of the host's agents and providers).
struct HostRequestStamp {
    let hostID: String?
    let client: APIClient
}

extension WorkspaceModel {
    /// The host and connection a request goes to now, when a client is attached.
    func requestStamp() -> HostRequestStamp? {
        guard let client else { return nil }
        return HostRequestStamp(hostID: hostID, client: client)
    }

    /// Whether the host and connection are still the ones `stamp` was made for.
    func isCurrent(_ stamp: HostRequestStamp) -> Bool {
        hostID == stamp.hostID && client === stamp.client
    }

    /// Changes whenever a pane's reads start over: another host or connection, the host answering again,
    /// a new connection epoch.
    public var paneReadKey: String {
        let client = client.map { String(describing: ObjectIdentifier($0)) } ?? "none"
        return "\(hostID ?? "")|\(client)|\(reachable)|\(connectionEpoch)"
    }
}

/// A request that ended because its task was cancelled (the view that asked went away), which is not a
/// failure to report: URLSession reports it as `URLError.cancelled`.
func isCancellation(_ error: Error) -> Bool {
    error is CancellationError || (error as? URLError)?.code == .cancelled
}
