import CloudKit
import Foundation
import AgentLandDesktopCore
import AgentLandNotifications

/// Push notifications on the Mac: the two settings, the iCloud account state,
/// the relay's lifetime and the test notice. `HostController` owns it and
/// tells it when its managed host starts and stops; no view owns the relay.
@MainActor
final class NotificationRelayController: ObservableObject {
    /// Whether this process may use CloudKit, and its database when it may.
    enum CloudKitAccess {
        case unavailable(NoticeCloudKit.Unavailable)
        case available(any NoticeDatabase)

        /// `CKContainer(identifier:)` is only reached when the signed app
        /// carries the iCloud container entitlement and `AGENTLAND_CLOUDKIT`
        /// is not 0.
        static func current() -> CloudKitAccess {
            if let reason = NoticeCloudKit.unavailability() { return .unavailable(reason) }
            guard let database = NoticeCloudKit.makeDatabase() else { return .unavailable(.notSignedForICloud) }
            return .available(database)
        }
    }

    enum ICloudState: Equatable {
        case unavailable(NoticeCloudKit.Unavailable)
        case checking
        case account(NoticeAccountStatus)
        case checkFailed
    }

    enum TestState: Equatable {
        case idle
        case sending
        case sent
        case failed(String)
    }

    /// "Send notifications to my iPhone and iPad" (default on).
    @Published var sendEnabled: Bool {
        didSet {
            guard sendEnabled != oldValue else { return }
            persist()
            testState = .idle
            // Turning sending on does not send what happened while it was off.
            if sendEnabled { sendingSince = now() }
            reconcile()
        }
    }
    /// "Include chat titles" (default on).
    @Published var includeTitles: Bool {
        didSet {
            guard includeTitles != oldValue else { return }
            persist()
            let include = includeTitles
            if let relay { Task { await relay.setIncludeTitles(include) } }
        }
    }
    @Published private(set) var iCloud: ICloudState
    @Published private(set) var relayStatus = NoticeRelay.Status()
    @Published private(set) var testState: TestState = .idle

    static let storageKey = "dev.agentland.desktop.notifications.v1"
    private let preferences: UserDefaults
    private let database: (any NoticeDatabase)?
    private let clock: any NoticeRelayClock
    private var host: (hostID: String, feed: any NoticeFeed)?
    private var relay: NoticeRelay?
    private var relayGeneration = 0
    private var stopping: Task<Void, Never>?
    /// When sending was last turned on in this run; earlier notices are dropped.
    private var sendingSince: Date?
    private var accountCheck = 0
    private let accountObserver = ObserverToken()

    init(preferences: UserDefaults = .standard, cloudKit: CloudKitAccess = .current(),
         clock: any NoticeRelayClock = SystemNoticeRelayClock()) {
        self.preferences = preferences
        self.clock = clock
        let stored = preferences.data(forKey: Self.storageKey).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }
        sendEnabled = stored?.sendEnabled ?? true
        includeTitles = stored?.includeTitles ?? true
        switch cloudKit {
        case let .unavailable(reason):
            database = nil
            iCloud = .unavailable(reason)
        case let .available(database):
            self.database = database
            iCloud = .checking
            accountObserver.token = NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.accountChanged() }
            }
            refreshAccountStatus()
        }
    }

    // MARK: Host lifecycle (HostController)

    /// The managed host answers on its HTTPS listener with this local session.
    func hostStarted(hostID: String, feed: any NoticeFeed) {
        host = (hostID, feed)
        restartRelay()
    }

    /// The host stopped or is stopping: stop relaying at once.
    func hostStopped() {
        host = nil
        reconcile()
    }

    /// For Quit: stops the relay, waiting at most about a second.
    func shutdown() async {
        host = nil
        reconcile()
        await stopping?.value
    }

    // MARK: Settings actions

    var canUseICloud: Bool { database != nil }

    func refreshAccountStatus() {
        guard let database else { return }
        accountCheck += 1
        let check = accountCheck
        if case .account = iCloud {} else { iCloud = .checking }
        Task {
            let state: ICloudState
            do { state = .account(try await database.accountStatus()) } catch { state = .checkFailed }
            if accountCheck == check { iCloud = state }
        }
    }

    /// Writes one `chat.turn.finished` notice titled "Test from AgentLand".
    func sendTestNotification(certificateSHA256: String?, projectID: String, projectName: String) {
        guard let database, sendEnabled, testState != .sending else { return }
        guard let hostID = certificateSHA256.flatMap(NoticeHostID.make(certificateSHA256:)) else {
            testState = .failed("Connect once so this Mac has its secure identity, then try again.")
            return
        }
        testState = .sending
        let date = now()
        Task {
            do {
                try await NoticeRelay.sendTestNotice(database: database, hostID: hostID, projectID: projectID.isEmpty ? "workspace" : projectID,
                                                     projectName: projectName, now: date)
                testState = .sent
            } catch let NoticeRelay.TestNoticeError.account(status) {
                iCloud = .account(status)
                testState = .failed(Self.detail(for: .account(status)) ?? "iCloud isn't available.")
            } catch {
                testState = .failed(Self.describe(problem: .iCloud(Self.describe(error))))
            }
        }
    }

    // MARK: Text for Settings

    var iCloudSummary: String {
        switch iCloud {
        case .unavailable(.notSignedForICloud): "Not available in this build"
        case .unavailable(.turnedOff): "Turned off for this run"
        case .checking: "Checking…"
        case .checkFailed: "Couldn't check"
        case .account(.available): "Available"
        case .account(.noAccount): "No account"
        case .account(.restricted): "Restricted"
        case .account(.temporarilyUnavailable): "Temporarily unavailable"
        case .account(.couldNotDetermine): "Couldn't check"
        }
    }

    var iCloudDetail: String? { Self.detail(for: iCloud) }

    var testMessage: String? {
        switch testState {
        case .idle, .sending: nil
        case .sent: "Sent. It appears on iPhone and iPad where AgentLand is allowed to send notifications."
        case let .failed(message): message
        }
    }

    /// Why notices are not going out right now, when the relay is backing off.
    var relayProblem: String? {
        guard case let .waiting(problem, _) = relayStatus.phase else { return nil }
        if case .account = problem { return nil } // the iCloud row says it
        return Self.describe(problem: problem)
    }

    /// Why the hourly cleanup failed, for example before the CloudKit schema
    /// (macos/CloudKit) is applied.
    var cleanupProblem: String? {
        relayStatus.cleanupProblem.map { "iCloud couldn't remove notices older than a day (\($0))." }
    }

    static func detail(for state: ICloudState) -> String? {
        switch state {
        case .unavailable(.notSignedForICloud): "This copy of AgentLand isn't signed for iCloud, so it can't send notifications."
        case .unavailable(.turnedOff): "Notifications are off because AGENTLAND_CLOUDKIT=0 is set."
        case .checking: nil
        case .checkFailed, .account(.couldNotDetermine): "AgentLand couldn't reach iCloud. It checks again when your account changes or you open Settings."
        case .account(.available): "Notices go to iPhone and iPad signed in to the same Apple Account."
        case .account(.noAccount): "Sign in to iCloud in System Settings to send notifications."
        case .account(.restricted): "iCloud is restricted on this Mac, for example by Screen Time or a device management profile."
        case .account(.temporarilyUnavailable): "Open System Settings, then your Apple Account, and finish signing in to iCloud."
        }
    }

    static func describe(problem: NoticeRelay.Problem) -> String {
        switch problem {
        case let .host(message): "Can't read this Mac's notices (\(message)). Trying again."
        case .hostWithoutNotices: "This Mac's host doesn't keep notices."
        case .account: "Waiting for iCloud."
        case .quotaExceeded: "Your iCloud storage is full, so notices can't be sent."
        case let .iCloud(message): "iCloud didn't take the notice (\(message)). Trying again."
        }
    }

    static func describe(_ error: any Error) -> String {
        redact((error as? LocalizedError)?.errorDescription ?? error.localizedDescription, limit: 200)
    }

    // MARK: Relay

    private func accountChanged() {
        refreshAccountStatus()
        // A new relay checks the account again at once.
        if relay != nil { restartRelay() }
    }

    private func restartRelay() {
        stopRelay()
        reconcile()
    }

    private func reconcile() {
        guard sendEnabled, let database, let host else { stopRelay(); return }
        guard relay == nil else { return }
        relayGeneration += 1
        let generation = relayGeneration
        let relay = NoticeRelay(hostID: host.hostID, feed: host.feed, database: database,
                                settings: NoticeRelay.Settings(includeTitles: includeTitles, notBefore: sendingSince), clock: clock,
                                onStatus: { [weak self] status in
                                    Task { @MainActor in
                                        guard let self, self.relayGeneration == generation else { return }
                                        self.relayStatus = status
                                    }
                                })
        self.relay = relay
        let previous = stopping
        Task {
            await previous?.value
            await relay.start()
        }
    }

    private func stopRelay() {
        guard let relay else { return }
        self.relay = nil
        relayGeneration += 1
        relayStatus = NoticeRelay.Status()
        let previous = stopping
        stopping = Task {
            await previous?.value
            await relay.stop()
        }
    }

    private func now() -> Date { clock.now() }

    private func persist() {
        if let data = try? JSONEncoder().encode(Stored(sendEnabled: sendEnabled, includeTitles: includeTitles)) {
            preferences.set(data, forKey: Self.storageKey)
        }
    }

    private struct Stored: Codable {
        let sendEnabled: Bool
        let includeTitles: Bool
    }

    /// Removes the account observer with the controller.
    private final class ObserverToken: @unchecked Sendable {
        var token: (any NSObjectProtocol)?
        deinit { if let token { NotificationCenter.default.removeObserver(token) } }
    }
}
