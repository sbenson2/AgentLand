import XCTest
@testable import AgentLandNotifications

/// Where a tapped notice goes, step by step, with the app's state faked.
final class NoticeRouteTests: XCTestCase {
    private let homeFingerprint = String(repeating: "ab", count: 32)
    private let studioFingerprint = String(repeating: "cd", count: 32)
    private var homeHostID: String { NoticeHostID.make(certificateSHA256: homeFingerprint)! }
    private var studioHostID: String { NoticeHostID.make(certificateSHA256: studioFingerprint)! }

    private var hosts: [NoticeRouteHost] {
        [NoticeRouteHost(id: "home", certificateSHA256: homeFingerprint),
         NoticeRouteHost(id: "studio", certificateSHA256: studioFingerprint.uppercased()),
         NoticeRouteHost(id: "unpinned", certificateSHA256: nil)]
    }

    private func state(selected: String? = "home", unlocked: Bool = true, covered: Bool = false,
                       resolved: Bool = true, projects: Set<String>? = ["workspace"]) -> NoticeRouteState {
        NoticeRouteState(hosts: hosts, selectedHostID: selected, unlocked: unlocked, covered: covered,
                         projectsResolved: resolved, projectIDs: projects)
    }

    private func link(_ kind: NoticeKind, host: String? = nil, project: String? = "workspace", session: String? = "ses_1",
                      complete: Bool = true) -> NoticeDeepLink {
        let hostID = host ?? homeHostID
        var link = NoticeDeepLink(record: NoticeRecord(recordName: "\(hostID)-ntc_1", kind: kind, hostID: hostID,
                                                       projectID: project ?? "", projectName: "AgentLand", sessionID: session,
                                                       createdAt: Date()))
        link.projectID = project
        link.isComplete = complete
        return link
    }

    func testAChatNoticeWaitsForUnlockAndTheOpeningCoverThenOpensTheChat() {
        var route = NoticeRoute(link: link(.turnFinished))
        XCTAssertEqual(route.next(in: state(unlocked: false, covered: true)), .wait, "locked")
        XCTAssertEqual(route.next(in: state(unlocked: true, covered: true)), .wait, "unlocked, the opening cover still up")
        XCTAssertFalse(route.released)
        XCTAssertEqual(route.next(in: state()), .open(.chat(projectID: "workspace", sessionID: "ses_1")))
        XCTAssertTrue(route.released)
    }

    func testApprovalsQuestionsAndRepliesOpenTheirChat() {
        for kind in [NoticeKind.approvalNeeded, .questionNeeded, .turnFailed] {
            var route = NoticeRoute(link: link(kind, session: "ses_2"))
            XCTAssertEqual(route.next(in: state()), .open(.chat(projectID: "workspace", sessionID: "ses_2")), "\(kind)")
        }
        var test = NoticeRoute(link: link(.turnFinished, session: nil))
        XCTAssertEqual(test.next(in: state()), .open(.workspace(projectID: "workspace")), "the test notice opens the project")
    }

    func testAnIncompletePushFetchesItsRecordOnceEvenWhileLocked() {
        var route = NoticeRoute(link: link(.turnFinished, project: nil, session: nil, complete: false))
        XCTAssertEqual(route.next(in: state(unlocked: false)), .fetchRecord)
        XCTAssertEqual(route.next(in: state(unlocked: false)), .fetchRecord, "until the fetch finishes")
        route.recordFetched(link(.turnFinished, session: "ses_9"))
        XCTAssertTrue(route.recordChecked)
        XCTAssertEqual(route.link.sessionID, "ses_9")
        XCTAssertEqual(route.next(in: state(unlocked: false)), .wait)
        XCTAssertEqual(route.next(in: state()), .open(.chat(projectID: "workspace", sessionID: "ses_9")))

        // The record is gone: what the push had is used. Without a project there is nothing to open.
        var gone = NoticeRoute(link: link(.turnFinished, project: nil, session: nil, complete: false))
        gone.recordFetched(nil)
        XCTAssertEqual(gone.next(in: state()), .done)

        // A record of another host never replaces the link.
        var foreign = NoticeRoute(link: link(.turnFinished, complete: false))
        foreign.recordFetched(link(.turnFinished, host: studioHostID, session: "other"))
        XCTAssertEqual(foreign.link.hostID, homeHostID)
    }

    func testAnotherSavedHostIsSelectedThenOpensBehindItsCover() {
        var route = NoticeRoute(link: link(.approvalNeeded, host: studioHostID))
        XCTAssertEqual(route.next(in: state(covered: true)), .wait)
        XCTAssertEqual(route.next(in: state()), .selectHost("studio"), "the fingerprint's case does not matter")
        // Selecting the host puts its opening cover up and loads its projects.
        XCTAssertEqual(route.next(in: state(selected: "studio", covered: true, resolved: false, projects: nil)), .wait)
        XCTAssertEqual(route.next(in: state(selected: "studio", covered: true, resolved: true)),
                       .open(.chat(projectID: "workspace", sessionID: "ses_1")),
                       "released: it opens behind the new host's cover, which then waits for the chat")
        XCTAssertEqual(route.next(in: state(selected: "studio", unlocked: false, covered: true)), .wait,
                       "locked again before it opened")
    }

    func testTheSelectedHostWinsWhenTwoSavedHostsHaveTheFingerprint() {
        let twice = hosts + [NoticeRouteHost(id: "home-again", certificateSHA256: homeFingerprint)]
        var route = NoticeRoute(link: link(.turnFinished))
        let onSecond = NoticeRouteState(hosts: twice, selectedHostID: "home-again", unlocked: true, covered: false,
                                        projectsResolved: true, projectIDs: ["workspace"])
        XCTAssertEqual(route.next(in: onSecond), .open(.chat(projectID: "workspace", sessionID: "ses_1")))
    }

    func testUnknownHostsAndProjectsAreReportedOnlyOnScreen() {
        let stranger = NoticeHostID.make(certificateSHA256: String(repeating: "ef", count: 32))!
        var route = NoticeRoute(link: link(.turnFinished, host: stranger))
        XCTAssertEqual(route.next(in: state(unlocked: false)), .wait)
        XCTAssertEqual(route.next(in: state(covered: true)), .wait)
        XCTAssertEqual(route.next(in: state()), .unknownHost)
        var none = NoticeRoute(link: link(.turnFinished))
        XCTAssertEqual(none.next(in: NoticeRouteState(hosts: [], selectedHostID: nil, unlocked: true, covered: false,
                                                      projectsResolved: false, projectIDs: nil)), .unknownHost)

        var removed = NoticeRoute(link: link(.turnFinished, project: "old"))
        XCTAssertEqual(removed.next(in: state()), .projectMissing)
    }

    func testAHostWhoseProjectsDidNotLoadStillOpensTheChat() {
        var chat = NoticeRoute(link: link(.turnFailed))
        XCTAssertEqual(chat.next(in: state(projects: nil)), .open(.chat(projectID: "workspace", sessionID: "ses_1")),
                       "the chat shows its own offline state")
        var project = NoticeRoute(link: link(.turnFinished, session: nil))
        XCTAssertEqual(project.next(in: state(projects: nil)), .done, "a workspace opens only from the host's list")
        var loading = NoticeRoute(link: link(.turnFailed))
        XCTAssertEqual(loading.next(in: state(resolved: false, projects: nil)), .wait)
    }

    func testFromThePairingScreenTheHostIsSelected() {
        var route = NoticeRoute(link: link(.turnFinished))
        XCTAssertEqual(route.next(in: state(selected: nil, projects: nil)), .selectHost("home"))
    }

    func testTheRouteSurvivesEncoding() throws {
        var route = NoticeRoute(link: link(.questionNeeded, complete: false))
        route.recordFetched(nil)
        let decoded = try JSONDecoder().decode(NoticeRoute.self, from: JSONEncoder().encode(route))
        XCTAssertEqual(decoded, route)
    }

    func testAlertsShowUnlessTheirChatIsOnScreen() {
        let onScreen = NoticeVisibleChat(hostID: homeHostID, sessionID: "ses_1")
        XCTAssertFalse(link(.turnFinished).showsAlert(whileShowing: onScreen))
        XCTAssertFalse(link(.approvalNeeded).showsAlert(whileShowing: onScreen), "the card shows in the chat")
        XCTAssertTrue(link(.turnFinished, session: "ses_2").showsAlert(whileShowing: onScreen))
        XCTAssertTrue(link(.turnFinished, host: studioHostID).showsAlert(whileShowing: onScreen), "the same chat ID on another Mac")
        XCTAssertTrue(link(.turnFinished).showsAlert(whileShowing: nil), "no chat on screen")
        XCTAssertTrue(link(.turnFinished, session: nil).showsAlert(whileShowing: onScreen), "a push without its chat")
    }
}
