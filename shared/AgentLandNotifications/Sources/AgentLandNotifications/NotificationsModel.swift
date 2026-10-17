import CloudKit
import Foundation
import Observation

/// The app's notification permission as the system reports it.
public enum NoticePermission: String, Sendable, Equatable {
    /// Never asked.
    case notDetermined
    /// Off in the system's Settings, or refused when asked.
    case denied
    /// Alerts may show (authorized, provisional or ephemeral).
    case allowed
}

/// What `NotificationsModel` needs from the system. The iOS app implements it with
/// `UNUserNotificationCenter` and `UIApplication`; tests use a fake.
@MainActor public protocol NoticeSystem: AnyObject {
    /// The permission, without asking.
    func notificationPermission() async -> NoticePermission
    /// Asks for alert and sound permission; true when granted.
    func requestNotificationPermission() async throws -> Bool
    /// `UIApplication.registerForRemoteNotifications()`. It shows nothing; once this device is
    /// registered, CloudKit delivers the account's subscriptions to it.
    func registerForRemoteNotifications()
}

/// The iCloud account, as Settings shows it.
public enum NoticeAccountState: Equatable, Sendable {
    /// CloudKit is off in this build or run (`NoticeCloudKit.unavailability()`).
    case unavailable(NoticeCloudKit.Unavailable)
    /// Not checked in this run: nothing touches iCloud until notifications are used.
    case unknown
    case checking
    case status(NoticeAccountStatus)
    /// The check itself failed (offline, for example).
    case checkFailed
}

/// Why the last action did not finish.
public enum NoticeSetupProblem: Equatable, Sendable {
    /// Notifications are off for the app in the system's Settings.
    case permissionDenied
    /// CloudKit is off in this build or run.
    case unavailable(NoticeCloudKit.Unavailable)
    /// The iCloud account cannot be used now.
    case account(NoticeAccountStatus)
    /// The account check failed.
    case accountCheckFailed
    /// The account's subscriptions could not be read; the text is CloudKit's.
    case readFailed(String)
    /// Saving or deleting subscriptions failed; the text is CloudKit's.
    case saveFailed(NoticeFailure, String)
}

/// One look at the selected chat's turn, for the notifications tip.
public struct ChatTurnObservation: Equatable, Sendable {
    public var tabID: UUID
    public var working: Bool
    /// When the running turn, or the send that starts it, began, when known.
    public var startedAt: Date?

    public init(tabID: UUID, working: Bool, startedAt: Date?) {
        self.tabID = tabID
        self.working = working
        self.startedAt = startedAt
    }
}

/// Notifications on iPhone and iPad: the permission, the push registration and the account's
/// subscriptions.
///
/// - Permission is asked only in context: a Settings control or the one-time tip after a chat turn
///   that ran longer than `tipTurnDuration`. `sceneBecameActive()` never asks; it only registers
///   for remote notifications once permission is allowed.
/// - Subscriptions belong to the iCloud account, so the two groups apply to every device signed in
///   to it. Every change starts from the account's current subscriptions (another device may have
///   changed them), creates the `Notices` zone when a kind is on, and saves one
///   `NoticeSubscriptionPlan`: its subscriptions, and deletions for `subscriptionIDsToDelete`.
/// - The device remembers the `NoticeSubscriptionPlan.version` it saved and saves the account's
///   subscriptions again when that changes.
/// - iCloud is touched only when notifications are used: a Settings control or pane, the tip, a
///   version change, or a tapped notice whose push left values out.
@MainActor @Observable
public final class NotificationsModel {
    /// A turn that ran longer than this (and ended with its chat on screen) offers the tip.
    public static let tipTurnDuration: TimeInterval = 30

    /// User defaults keys.
    public enum Key {
        /// The `NoticeSubscriptionPlan.version` this device last saved; absent until it saves one.
        public static let version = "agentland.notifications.subscriptionVersion"
        /// The groups on the account when this device last read or saved them.
        public static let groups = "agentland.notifications.groups"
        /// The tip has been shown.
        public static let tipShown = "agentland.notifications.tipShown"
        /// Alerts play a sound (absent: on), as the account's subscriptions last said or as chosen here while
        /// none were subscribed.
        public static let sound = "agentland.notifications.sound"
    }

    /// Nil until read.
    public private(set) var permission: NoticePermission?
    public private(set) var account: NoticeAccountState
    /// The groups subscribed on the account, as last read or saved.
    public private(set) var enabledGroups: Set<NoticeGroup>
    /// `enabledGroups` was read from, or saved to, iCloud in this run.
    public private(set) var groupsConfirmed = false
    /// The groups a change in progress asks for.
    public private(set) var pendingGroups: Set<NoticeGroup>?
    /// Alerts play a sound: the account's subscriptions' sound, as last read or saved. Like the groups it
    /// belongs to the iCloud account, so it applies to every device on it.
    public private(set) var soundOn: Bool
    /// The sound a change in progress asks for.
    public private(set) var pendingSound: Bool?
    public private(set) var working = false
    public private(set) var problem: NoticeSetupProblem?
    /// The system could not register this device for remote notifications.
    public private(set) var registrationError: String?
    public private(set) var tipVisible = false
    /// Why CloudKit is off in this build or run, or nil when it is on.
    public let unavailability: NoticeCloudKit.Unavailable?

    /// The groups to show: a change in progress, or the account's.
    public var displayedGroups: Set<NoticeGroup> { pendingGroups ?? enabledGroups }
    /// The sound to show: a change in progress, or the account's.
    public var displayedSound: Bool { pendingSound ?? soundOn }
    public var cloudKitAvailable: Bool { unavailability == nil }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let system: any NoticeSystem
    @ObservationIgnored private let makeDatabase: @MainActor () -> (any NoticeDatabase)?
    @ObservationIgnored private var database: (any NoticeDatabase)?
    @ObservationIgnored private var trackedTurn: (tabID: UUID, startedAt: Date)?

    /// `makeDatabase` runs only when iCloud is first needed, and only when `unavailability` is nil.
    public init(defaults: UserDefaults = .standard, system: any NoticeSystem,
                unavailability: NoticeCloudKit.Unavailable?,
                makeDatabase: @escaping @MainActor () -> (any NoticeDatabase)?) {
        self.defaults = defaults
        self.system = system
        self.unavailability = unavailability
        self.makeDatabase = makeDatabase
        account = unavailability.map(NoticeAccountState.unavailable) ?? .unknown
        enabledGroups = Set((defaults.stringArray(forKey: Key.groups) ?? []).compactMap(NoticeGroup.init(rawValue:)))
        soundOn = defaults.object(forKey: Key.sound) as? Bool ?? true
    }

    // MARK: Lifecycle

    /// The app came to the foreground: reads the permission (never asks), registers for remote
    /// notifications when it is allowed, and saves the subscriptions again when this device saved
    /// an older plan version.
    public func sceneBecameActive() async {
        let permission = await system.notificationPermission()
        self.permission = permission
        guard permission == .allowed else { return }
        system.registerForRemoteNotifications()
        guard let saved = savedVersion, saved != NoticeSubscriptionPlan.version, !working else { return }
        working = true
        defer { working = false }
        guard let database = usableDatabase(), await accountIsAvailable(database) else { return }
        guard let groups = await readGroups(database) else { return }
        await save(NoticeGroup.kinds(of: groups), sound: soundOn, to: database)
    }

    /// Settings shows notifications: the permission, the account and the account's groups.
    public func refresh() async {
        permission = await system.notificationPermission()
        guard !working else { return }
        problem = nil
        guard let database = usableDatabase(), await accountIsAvailable(database) else { return }
        _ = await readGroups(database)
    }

    /// The iCloud account changed (`CKAccountChanged`). Checked again only when this run has looked
    /// at it before.
    public func accountChanged() async {
        guard !working, case .status = account, let database = usableDatabase() else { return }
        guard await accountIsAvailable(database) else { return }
        _ = await readGroups(database)
    }

    // MARK: Permission and groups

    /// Asks for permission when it was never asked, and registers for remote notifications once it
    /// is allowed. The groups stay as they are: another device may have turned them on already.
    @discardableResult
    public func requestPermission() async -> Bool {
        guard !working else { return false }
        working = true
        defer { working = false }
        problem = nil
        guard await ensurePermission() else { return false }
        system.registerForRemoteNotifications()
        return true
    }

    /// Turns a group on or off on the account. Turning one on asks for permission first when it was
    /// never asked.
    public func setGroup(_ group: NoticeGroup, enabled: Bool) async {
        await change(turningOn: enabled ? [group] : [], turningOff: enabled ? [] : [group])
    }

    /// Turns the alerts' sound on or off on the account: every notice subscription is saved again with the
    /// default sound or the silent one. It needs no permission. With nothing subscribed the choice is kept on
    /// this device and goes with the next group turned on.
    public func setSound(_ on: Bool) async {
        guard !working else { return }
        working = true
        pendingSound = on
        defer {
            working = false
            pendingSound = nil
        }
        problem = nil
        if let unavailability {
            problem = .unavailable(unavailability)
            return
        }
        guard let database = usableDatabase(), await accountIsAvailable(database) else { return }
        // Start from the account: another device may have changed its subscriptions.
        guard let current = await readGroups(database) else { return }
        guard !current.isEmpty else {
            rememberSound(on)
            return
        }
        await save(NoticeGroup.kinds(of: current), sound: on, to: database)
    }

    // MARK: Tip

    /// Feed the selected chat's turn whenever it changes (nil when no chat is selected). A turn that
    /// ran longer than `tipTurnDuration` and ended with its chat still selected offers the tip once:
    /// only while permission was never asked and CloudKit is on.
    public func observeChatTurn(_ turn: ChatTurnObservation?, at now: Date = Date()) {
        guard let turn else { trackedTurn = nil; return }
        if turn.working {
            let start = turn.startedAt ?? now
            if let tracked = trackedTurn, tracked.tabID == turn.tabID {
                trackedTurn = (turn.tabID, min(tracked.startedAt, start))
            } else {
                trackedTurn = (turn.tabID, start)
            }
            return
        }
        guard let tracked = trackedTurn, tracked.tabID == turn.tabID else { trackedTurn = nil; return }
        trackedTurn = nil
        if now.timeIntervalSince(tracked.startedAt) > Self.tipTurnDuration { offerTip() }
    }

    /// The tip's action: asks for permission and turns every group on.
    public func acceptTip() async {
        tipVisible = false
        await change(turningOn: Set(NoticeGroup.allCases), turningOff: [])
    }

    public func dismissTip() { tipVisible = false }

    /// Clears a problem the app has shown.
    public func clearProblem() { problem = nil }

    // MARK: Tapped notices

    /// The whole link from the notice's record, for a push that left values out; nil when CloudKit
    /// is off, the record is gone (the Mac deletes them after 24 hours) or it cannot be read.
    public func completeLink(_ link: NoticeDeepLink) async -> NoticeDeepLink? {
        guard let database = usableDatabase(),
              let record = try? await database.record(named: link.recordName),
              record.hostID == link.hostID else { return nil }
        return NoticeDeepLink(record: record)
    }

    // MARK: Registration

    public func registrationSucceeded() { registrationError = nil }
    public func registrationFailed(_ error: any Error) { registrationError = error.localizedDescription }

    // MARK: Internals

    private var savedVersion: Int? {
        get { defaults.object(forKey: Key.version) as? Int }
        set { defaults.set(newValue, forKey: Key.version) }
    }

    private var tipShown: Bool {
        get { defaults.bool(forKey: Key.tipShown) }
        set { defaults.set(newValue, forKey: Key.tipShown) }
    }

    private func offerTip() {
        guard !tipShown, cloudKitAvailable, permission == .notDetermined else { return }
        tipShown = true
        tipVisible = true
    }

    private func change(turningOn on: Set<NoticeGroup>, turningOff off: Set<NoticeGroup>) async {
        guard !working else { return }
        working = true
        pendingGroups = enabledGroups.union(on).subtracting(off)
        defer {
            working = false
            pendingGroups = nil
        }
        problem = nil
        // Without CloudKit nothing can reach this device: don't ask for permission for nothing.
        if let unavailability {
            problem = .unavailable(unavailability)
            return
        }
        if !on.isEmpty {
            guard await ensurePermission() else { return }
            system.registerForRemoteNotifications()
        }
        guard let database = usableDatabase() else { return }
        guard await accountIsAvailable(database) else { return }
        // Start from the account: another device may have changed its subscriptions.
        guard let current = await readGroups(database) else { return }
        await save(NoticeGroup.kinds(of: current.union(on).subtracting(off)), sound: soundOn, to: database)
    }

    /// True when allowed; asks first when never asked. Sets `problem` when it is off.
    private func ensurePermission() async -> Bool {
        var current = await system.notificationPermission()
        if current == .notDetermined {
            _ = try? await system.requestNotificationPermission()
            current = await system.notificationPermission()
        }
        permission = current
        if current == .denied { problem = .permissionDenied }
        return current == .allowed
    }

    /// The database, or nil (with `problem` set) when CloudKit is off.
    private func usableDatabase() -> (any NoticeDatabase)? {
        if let unavailability {
            problem = .unavailable(unavailability)
            return nil
        }
        if database == nil { database = makeDatabase() }
        if database == nil { problem = .unavailable(.notSignedForICloud) }
        return database
    }

    private func accountIsAvailable(_ database: any NoticeDatabase) async -> Bool {
        account = .checking
        do {
            let status = try await database.accountStatus()
            account = .status(status)
            if status != .available { problem = .account(status) }
            return status == .available
        } catch {
            account = .checkFailed
            problem = .accountCheckFailed
            return false
        }
    }

    /// The account's groups, read from its subscriptions, and their sound; nil (with `problem` set) when
    /// they cannot be read.
    private func readGroups(_ database: any NoticeDatabase) async -> Set<NoticeGroup>? {
        do {
            return rememberAccount(try await database.subscriptions())
        } catch {
            problem = .readFailed(error.localizedDescription)
            return nil
        }
    }

    /// Remembers the groups the account's subscriptions cover and, when any are subscribed, their sound (off
    /// when every one plays the silent sound). Returns the groups.
    @discardableResult
    private func rememberAccount(_ subscriptions: [NoticeSubscriptionSummary]) -> Set<NoticeGroup> {
        let notices = subscriptions.filter { NoticeSubscriptionPlan.kind(forSubscriptionID: $0.id) != nil }
        let groups = NoticeGroup.groups(of: notices.compactMap { NoticeSubscriptionPlan.kind(forSubscriptionID: $0.id) })
        remember(groups)
        if !notices.isEmpty { rememberSound(notices.contains { NoticeSubscriptionPlan.playsSound($0.soundName) }) }
        return groups
    }

    /// Saves the plan for `kinds`: the zone first when any kind is on, then one modify operation
    /// that saves the enabled kinds' subscriptions and deletes the others. A missing zone is created
    /// again once.
    private func save(_ kinds: [NoticeKind], sound: Bool, to database: any NoticeDatabase) async {
        let plan = NoticeSubscriptionPlan(enabledKinds: kinds, sound: sound)
        do {
            if !plan.enabledKinds.isEmpty { try await database.createZone() }
            var failures = try await modify(plan, database)
            if failures.values.contains(where: { NoticeFailure($0) == .zoneMissing }) {
                try await database.createZone()
                failures = try await modify(plan, database)
            }
            if let failure = failures.min(by: { $0.key < $1.key }) {
                problem = .saveFailed(NoticeFailure(failure.value), failure.value.localizedDescription)
                // Show what the account holds now.
                if let subscriptions = try? await database.subscriptions() { rememberAccount(subscriptions) }
                return
            }
            remember(NoticeGroup.groups(of: plan.enabledKinds))
            rememberSound(sound)
            savedVersion = NoticeSubscriptionPlan.version
        } catch {
            problem = .saveFailed(NoticeFailure(error), error.localizedDescription)
            if NoticeFailure(error) == .account { _ = await accountIsAvailable(database) }
        }
    }

    private func modify(_ plan: NoticeSubscriptionPlan, _ database: any NoticeDatabase) async throws -> [CKSubscription.ID: any Error] {
        let results = try await database.modifySubscriptions(saving: plan.subscriptions(), deleting: plan.subscriptionIDsToDelete)
        return results.compactMapValues { result in
            if case let .failure(error) = result { error } else { nil }
        }
    }

    private func rememberSound(_ on: Bool) {
        soundOn = on
        defaults.set(on, forKey: Key.sound)
    }

    private func remember(_ groups: Set<NoticeGroup>) {
        enabledGroups = groups
        groupsConfirmed = true
        defaults.set(NoticeGroup.allCases.filter(groups.contains).map(\.rawValue), forKey: Key.groups)
    }
}
