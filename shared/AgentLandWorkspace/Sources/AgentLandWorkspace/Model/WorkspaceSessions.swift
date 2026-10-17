import Foundation
import AgentLandCore
import AgentLandChat

/// The live state of one open tab, kept by the workspace rather than by its view: a chat's stream, a
/// terminal's renderer and I/O, an editor's draft, a file browser's listing. Views look their session
/// up, so a surface can be torn down and built again (a tab switch, a lock, a split view's detail
/// column) without losing it.
@MainActor public protocol WorkspaceSession: AnyObject {
    /// Stops the session's work and releases what it holds. Called once: when its tab closes or the
    /// workspace changes host. It never ends remote work such as a terminal's process.
    func end()
}

/// What a session was made for. A lookup whose tab now names another host or resource ends the old
/// session and makes a new one.
public struct WorkspaceSessionKey: Hashable, Sendable {
    public let tabID: UUID
    public let kind: WorkspaceTabKind
    public let hostID: String
    public let projectID: String
    public let resourceID: String

    public init(tabID: UUID, kind: WorkspaceTabKind, hostID: String, projectID: String, resourceID: String) {
        self.tabID = tabID
        self.kind = kind
        self.hostID = hostID
        self.projectID = projectID
        self.resourceID = resourceID
    }
}

/// Every open tab's session, keyed by tab ID. Sessions are made on first lookup and live until their
/// tab closes or the host changes.
///
/// Views look sessions up while they render, so the registry is deliberately not observable: making a
/// session must not count as a change to the views that asked for it.
@MainActor public final class WorkspaceSessionRegistry {
    private struct Entry {
        let key: WorkspaceSessionKey
        let session: any WorkspaceSession
    }

    private var entries: [UUID: Entry] = [:]

    public init() {}

    /// The number of live sessions.
    public var count: Int { entries.count }
    /// The tabs that have a live session.
    public var tabIDs: Set<UUID> { Set(entries.keys) }

    /// The session for `key`, made with `make` the first time. A session made for a different host,
    /// resource or type ends and is replaced.
    public func session<Session: WorkspaceSession>(for key: WorkspaceSessionKey, make: () -> Session) -> Session {
        if let entry = entries[key.tabID], entry.key == key, let session = entry.session as? Session {
            return session
        }
        entries.removeValue(forKey: key.tabID)?.session.end()
        let session = make()
        entries[key.tabID] = Entry(key: key, session: session)
        return session
    }

    /// The live session of `tabID`, if its view made one.
    public func existing(_ tabID: UUID) -> (any WorkspaceSession)? { entries[tabID]?.session }

    /// Ends and forgets the session of `tabID`.
    public func end(_ tabID: UUID) {
        entries.removeValue(forKey: tabID)?.session.end()
    }

    /// Ends every session, as when the workspace changes host.
    public func endAll() {
        let ending = entries.values.map(\.session)
        entries = [:]
        for session in ending { session.end() }
    }
}

extension ChatSessionStore: WorkspaceSession {
    public func end() { shutdown() }
}

extension WorkspaceModel {
    /// A browser tab's session: its page and history, its web view while it is among the most
    /// recently shown, and the preview session that opens a port on the host.
    public func browserSession(for tab: WorkspaceTab) -> BrowserSession {
        sessions.session(for: WorkspaceSessionKey(tabID: tab.id, kind: tab.kind, hostID: hostID ?? "", projectID: tab.projectID,
                                                  resourceID: tab.resourceID)) {
            BrowserSession(tab: tab, workspace: self)
        }
    }
}
