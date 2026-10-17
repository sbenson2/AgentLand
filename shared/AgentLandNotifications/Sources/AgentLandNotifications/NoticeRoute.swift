import Foundation

/// A saved host a notice can lead to: the app's ID for it and the
/// `NoticeHostID` of the certificate fingerprint it pinned when it paired.
public struct NoticeRouteHost: Equatable, Sendable {
    public let id: String
    /// Nil for a host saved without a pinned fingerprint: no notice can name it.
    public let noticeHostID: String?

    public init(id: String, certificateSHA256: String?) {
        self.id = id
        noticeHostID = certificateSHA256.flatMap(NoticeHostID.make(certificateSHA256:))
    }
}

/// What the app shows now, as far as a tapped notice is concerned.
public struct NoticeRouteState: Equatable, Sendable {
    public var hosts: [NoticeRouteHost]
    public var selectedHostID: String?
    /// Unlocked, in the foreground and not pairing.
    public var unlocked: Bool
    /// The opening cover shows (a host was selected, or the app came back from the background).
    public var covered: Bool
    /// The selected host's projects were answered, or failed to load.
    public var projectsResolved: Bool
    /// The selected host's projects; nil when they could not be loaded (the host is offline or needs
    /// pairing again), in which case a chat still opens and shows its own state.
    public var projectIDs: Set<String>?

    public init(hosts: [NoticeRouteHost], selectedHostID: String?, unlocked: Bool, covered: Bool,
                projectsResolved: Bool, projectIDs: Set<String>?) {
        self.hosts = hosts
        self.selectedHostID = selectedHostID
        self.unlocked = unlocked
        self.covered = covered
        self.projectsResolved = projectsResolved
        self.projectIDs = projectIDs
    }
}

/// Where a tapped notice opens in the workspace.
public enum NoticeRouteTarget: Equatable, Sendable {
    /// The chat: its reply, or its pending approval or question, which the chat shows at its end.
    case chat(projectID: String, sessionID: String)
    /// The project's workspace (the test notice).
    case workspace(projectID: String)
}

/// What the app does next for a tapped notice.
public enum NoticeRouteStep: Equatable, Sendable {
    /// Fetch the record (`link.recordName`), then call `recordFetched(_:)`.
    case fetchRecord
    /// Hold the notice until something changes: unlocking, the opening cover clearing, projects loading.
    case wait
    /// Switch to this saved host through the normal selection path; its opening cover goes up.
    case selectHost(String)
    case open(NoticeRouteTarget)
    /// No saved host has the notice's host ID: show a short notice.
    case unknownHost
    /// The host no longer lists the notice's project: show a short notice.
    case projectMissing
    /// Nothing more to open: the notice names no project.
    case done
}

/// A tapped notice on its way to the screen it names.
///
/// 1. A push that left values out (`isComplete` false) fetches its record once.
/// 2. It waits until the app is unlocked and the opening cover has cleared.
/// 3. A notice of another saved host switches host (`selectHost`); from then on it no longer waits
///    for a cover, so it opens behind the new host's cover once its projects answer.
/// 4. It opens the chat or the workspace, or reports an unknown host or project.
///
/// `Codable`, so the app could keep it across a relaunch; the app keeps it in memory.
public struct NoticeRoute: Equatable, Sendable, Codable {
    public private(set) var link: NoticeDeepLink
    /// The record was fetched, or fetching it failed; either way it is not fetched again.
    public private(set) var recordChecked = false
    /// It has waited for an unlocked, uncovered app.
    public private(set) var released = false

    public init(link: NoticeDeepLink) { self.link = link }

    /// The next step in `state`. Any step past waiting and fetching releases the notice.
    public mutating func next(in state: NoticeRouteState) -> NoticeRouteStep {
        let step = Self.step(link: link, recordChecked: recordChecked, released: released, state: state)
        if step != .wait && step != .fetchRecord { released = true }
        return step
    }

    /// The fetch finished: `complete` is the link read from the record, or nil when the record is gone
    /// or could not be read (the push's own values are used then).
    public mutating func recordFetched(_ complete: NoticeDeepLink?) {
        recordChecked = true
        if let complete, complete.hostID == link.hostID { link = complete }
    }

    static func step(link: NoticeDeepLink, recordChecked: Bool, released: Bool, state: NoticeRouteState) -> NoticeRouteStep {
        if !link.isComplete && !recordChecked { return .fetchRecord }
        guard state.unlocked else { return .wait }
        if !released && state.covered { return .wait }
        let matches = state.hosts.filter { $0.noticeHostID == link.hostID }
        guard let host = matches.first(where: { $0.id == state.selectedHostID }) ?? matches.first else { return .unknownHost }
        if host.id != state.selectedHostID { return .selectHost(host.id) }
        guard state.projectsResolved else { return .wait }
        guard let projectID = link.projectID else { return .done }
        if let projects = state.projectIDs, !projects.contains(projectID) { return .projectMissing }
        switch link.destination {
        case let .chat(sessionID), let .pendingInteraction(sessionID):
            return .open(.chat(projectID: projectID, sessionID: sessionID))
        case .project:
            // Opening a workspace needs the host's project list.
            return state.projectIDs == nil ? .done : .open(.workspace(projectID: projectID))
        }
    }
}

/// The chat on screen, for deciding whether a notice that arrives in the foreground shows its alert.
public struct NoticeVisibleChat: Equatable, Sendable {
    /// `NoticeHostID` of the selected host.
    public var hostID: String
    public var sessionID: String

    public init(hostID: String, sessionID: String) {
        self.hostID = hostID
        self.sessionID = sessionID
    }
}

public extension NoticeDeepLink {
    /// Whether iOS shows this notice while the app is in front: not when it is about the chat on
    /// screen, since the chat shows the same thing.
    func showsAlert(whileShowing chat: NoticeVisibleChat?) -> Bool {
        guard let chat, let sessionID else { return true }
        return chat.hostID != hostID || chat.sessionID != sessionID
    }
}
