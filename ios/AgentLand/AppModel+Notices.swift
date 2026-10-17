import Foundation
import Observation
import UIKit
import UserNotifications
import AgentLandChat
import AgentLandCore
import AgentLandDesign
import AgentLandNotifications
import AgentLandWorkspace

/// A short notice of the app's: the system's alert on a failure, only heard by VoiceOver on a success (`noticePresentation`).
struct AppNotice: Equatable, Identifiable {
    let id = UUID()
    var text: String
    var tone: InlineNotice.Tone = .warning
}

/// Tapped notifications, the foreground alert decision and the tip. The route itself is
/// `NoticeRoute` (AgentLandNotifications); this runs its steps through the app's own paths: host
/// selection with its opening ticket, and the workspace's public `open` and `openWorkspace`.
extension AppModel {
    // MARK: Tapped notifications

    /// A tapped notification. It waits until the app is unlocked and the opening cover has cleared;
    /// a notification of another saved host then switches host through `select` (the opening cover
    /// goes up), and the chat or workspace it names opens behind that cover once the host's projects
    /// answer. A newer tap replaces one still waiting.
    func openNotice(_ link: NoticeDeepLink) {
        noticeFetch?.cancel()
        noticeFetch = nil
        pendingNotice = NoticeRoute(link: link)
        advanceNotice()
    }

    /// Takes a waiting notification as far as the app's state allows. The app calls it whenever that
    /// state may have changed: the scene became active, the app unlocked, an opening completed, a
    /// host's projects answered.
    func advanceNotice() {
        // Selecting a host changes the state at once; a few passes always reach a wait or an end.
        for _ in 0..<4 {
            guard var route = pendingNotice else { return }
            let step = route.next(in: noticeRouteState)
            pendingNotice = route
            switch step {
            case .wait:
                return
            case .fetchRecord:
                fetchNoticeRecord(route.link)
                return
            case let .selectHost(id):
                guard let host = hosts.first(where: { $0.id == id }) else { pendingNotice = nil; return }
                select(host)
            case let .open(target):
                pendingNotice = nil
                open(target)
                return
            case .unknownHost:
                pendingNotice = nil
                appNotice = AppNotice(text: "That notification is from a Mac this \(UIDevice.current.model) isn’t paired with.")
                return
            case .projectMissing:
                pendingNotice = nil
                appNotice = AppNotice(text: "That project is no longer on \(selectedHost?.name ?? "the Mac").")
                return
            case .done:
                pendingNotice = nil
                return
            }
        }
    }

    /// What a tapped notification needs to know about the app now. The host's Chats space is there beside its
    /// workspaces: its projects list never names it, and a plain chat's notice (`projectId` `chats`) opens the
    /// chat without a workspace.
    var noticeRouteState: NoticeRouteState {
        NoticeRouteState(hosts: hosts.map { NoticeRouteHost(id: $0.id, certificateSHA256: $0.certificateSHA256) },
                         selectedHostID: selectedHost?.id,
                         unlocked: !locked && !busy && scenePhase == .active,
                         covered: presentationPending,
                         projectsResolved: workspace.metadataResolved,
                         projectIDs: workspace.hostIssue == nil
                            ? workspace.workspaceIDs.union(workspace.chatsSpaceID.map { [$0] } ?? []) : nil)
    }

    /// Reads the record of a push that left values out; the route goes on with what it gets.
    private func fetchNoticeRecord(_ link: NoticeDeepLink) {
        guard noticeFetch == nil else { return }
        noticeFetch = Task { [weak self] in
            let complete = await self?.notifications.completeLink(link)
            guard let self, !Task.isCancelled, self.pendingNotice?.link == link else { return }
            self.noticeFetch = nil
            self.pendingNotice?.recordFetched(complete)
            self.advanceNotice()
        }
    }

    private func open(_ target: NoticeRouteTarget) {
        switch target {
        case let .chat(projectID, sessionID):
            guard workspace.isChatShown(sessionID, projectID: projectID) else { return }
            // Never in place of a Home tab: this was not launched from Home. An open tab of the chat
            // is selected instead. The chat renames its tab once the host's title loads, and shows a
            // pending approval or question at its end, where it opens. A Claude Code or Codex chat opens in
            // its workspace; an older Chats-space chat in its saved workspace, asked for once.
            workspace.requestResume(.tab(WorkspaceTab(kind: .chat, projectID: projectID, resourceID: sessionID, title: "Chat")))
        case let .workspace(projectID):
            // The Chats space is no workspace: there is nothing of it to open without a chat.
            guard !workspace.isChatsSpace(projectID) else { return }
            workspace.openWorkspace(projectID)
        }
    }

    // MARK: Foreground alerts

    /// No alert for a notice about the chat on screen; every other notice shows as usual.
    func presentationOptions(for link: NoticeDeepLink?) -> UNNotificationPresentationOptions {
        if let link, !link.showsAlert(whileShowing: visibleChat) { return [] }
        // Settings → Notifications → Sound: off, the alert in front plays none either.
        return notifications.soundOn ? [.banner, .list, .sound] : [.banner, .list]
    }

    /// The chat on screen: the selected tab of an active, unlocked, uncovered app.
    var visibleChat: NoticeVisibleChat? {
        guard scenePhase == .active, !locked, !busy, !presentationPending,
              let hostID = selectedHost?.certificateSHA256.flatMap(NoticeHostID.make(certificateSHA256:)),
              let tab = workspace.currentTab, tab.kind == .chat else { return nil }
        return NoticeVisibleChat(hostID: hostID, sessionID: tab.resourceID)
    }

    // MARK: Tip

    /// Feeds the selected chat's turn to the notifications tip whenever it changes.
    func watchSelectedChatTurn() {
        let turn = withObservationTracking { selectedChatTurn } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.watchSelectedChatTurn() }
        }
        notifications.observeChatTurn(turn)
    }

    /// The selected chat's turn: whether it works and since when. A chat whose store its view has not
    /// made yet counts as idle.
    var selectedChatTurn: ChatTurnObservation? {
        guard let tab = workspace.currentTab, tab.kind == .chat else { return nil }
        guard let store = workspace.existingChatStore(tab.id) else {
            return ChatTurnObservation(tabID: tab.id, working: false, startedAt: nil)
        }
        return ChatTurnObservation(tabID: tab.id, working: store.isWorking, startedAt: store.turnStartedAt ?? store.awaitingTurnSince)
    }

    /// The tip's Turn On: asks for permission in context and turns every group on.
    func acceptNotificationsTip() {
        Task {
            await notifications.acceptTip()
            if let problem = notifications.problem {
                appNotice = AppNotice(text: problem.message(device: UIDevice.current.model))
                notifications.clearProblem()
            } else if notifications.permission == .allowed {
                appNotice = AppNotice(text: "Notifications are on for every device on your Apple ID. Change them in Settings → Notifications.",
                                      tone: .success)
            }
        }
    }
}
