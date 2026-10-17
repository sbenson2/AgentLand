import AppKit
import Foundation
import Network
import AgentLandCore
import AgentLandDesktopCore
import AgentLandNotifications

/// Remote access for the Mac's windows: the two switches, saved in the app's preferences, and the
/// service's status. `HostController` owns it, tells it when its host starts and stops, and shuts it
/// down on Quit; no view owns the service. It does nothing until the app activates it at launch, so a
/// `HostController` made in tests never touches the Keychain, the router or iCloud.
@MainActor
final class RemoteAccessController: ObservableObject {
    nonisolated static let storageKey = "dev.agentland.desktop.remoteAccess.v1"
    /// How long Quit waits for the mapping's delete and the endpoint to close.
    static let shutdownLimit: Duration = .seconds(10)

    @Published private(set) var status: RemoteAccessService.Status
    /// The host's tunnel socket; nil when its path does not fit a Unix socket (then no remote access).
    let tunnelSocketPath: String?

    private let preferences: UserDefaults
    private let service: RemoteAccessService?
    private(set) var activated = false
    /// Calls to the service that have not returned: a switch turned off whose mapping delete and
    /// endpoint close are still under way, the launch's cleanup, a host start or stop, a network
    /// change. Quit waits for them (`needsShutdown`), as the service's `shutdown()` runs after them.
    private(set) var callsInProgress = 0
    private var appliedStatus = 0
    private var pathMonitor: NWPathMonitor?
    private var lastPath: String?
    private let wakeObserver = ObserverToken()

    init(statePath: String, preferences: UserDefaults,
         makeService: ((RemoteAccessService.Settings, String, @escaping @Sendable (RemoteAccessService.Settings) -> Void,
                        @escaping @Sendable (RemoteAccessService.Status) -> Void) -> RemoteAccessService)? = nil) {
        self.preferences = preferences
        tunnelSocketPath = HostCommandBuilder.tunnelSocketPath(statePath: statePath)
        let settings = Self.readSettings(preferences)
        var initial = RemoteAccessService.Status()
        initial.enabled = settings.enabled
        initial.fallback = settings.fallback
        status = initial
        guard let socketPath = tunnelSocketPath else {
            service = nil
            return
        }
        let store = SettingsStore(preferences: preferences)
        let save: @Sendable (RemoteAccessService.Settings) -> Void = { settings in store.save(settings) }
        // Statuses arrive in order; the main actor applies only the newest it has seen.
        let sequence = StatusSequence()
        let target = StatusTarget()
        let publish: @Sendable (RemoteAccessService.Status) -> Void = { status in
            let number = sequence.next()
            Task { @MainActor in target.controller?.apply(status, number: number) }
        }
        service = makeService?(settings, socketPath, save, publish)
            ?? RemoteAccessService(settings: settings,
                                   dependencies: .init(socketPath: socketPath,
                                                       recordDatabase: CloudKitRemoteAccessAddressDatabase.make()),
                                   save: save, onStatus: publish)
        target.controller = self
    }

    private func apply(_ newStatus: RemoteAccessService.Status, number: Int) {
        guard number > appliedStatus else { return }
        appliedStatus = number
        status = newStatus
    }

    var isAvailable: Bool { service != nil }
    /// Quit has something to undo: the endpoint and the router mapping run while the switch is on, and
    /// a call still under way may be deleting the mapping (the switch just turned off) or making one.
    var needsShutdown: Bool { activated && (status.enabled || callsInProgress > 0) }

    // MARK: The app's lifecycle

    /// At launch: deletes what an earlier run left on the router (and a record left while the switch
    /// is off), starts remote access when the switch is on, and follows network changes and wakes.
    func activate() {
        guard !activated, service != nil else { return }
        activated = true
        call { await $0.activate() }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let signature = Self.signature(of: path)
            Task { @MainActor in self?.pathChanged(signature) }
        }
        monitor.start(queue: DispatchQueue(label: "dev.agentland.remote-access.path"))
        pathMonitor = monitor
        wakeObserver.token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.networkChanged() }
        }
    }

    /// The host started with its tunnel socket and this local session.
    func hostStarted(client: APIClient, hostID: String?) {
        guard activated else { return }
        let session = APIClientRemoteAccessSession(client)
        call { await $0.hostStarted(session, hostID: hostID) }
    }

    func hostStopped() {
        guard activated else { return }
        call { await $0.hostStopped() }
    }

    /// Whether the host's connection mode carries the tunnel (trusted HTTPS). While it does not, the
    /// endpoint and the mapping stay off whatever the switch says. Every call goes to the service, which
    /// ignores a repeat: `status` is only the last status published, and one published before the
    /// service took an earlier call still has the old value, so comparing with it could drop the call
    /// that undoes that one (development HTTP and straight back).
    func setTunnelServed(_ served: Bool) {
        guard service != nil else { return }
        status.tunnelServed = served
        call { await $0.setTunnelServed(served) }
    }

    /// Runs one call to the service, counted until it returns. The operation runs on the main actor up
    /// to its call to the service, so calls reach the service's queue in the order they are made.
    private func call(_ operation: @escaping @MainActor (RemoteAccessService) async -> Void) {
        guard let service else { return }
        callsInProgress += 1
        Task {
            await operation(service)
            callsInProgress -= 1
        }
    }

    /// Quit: removes the mapping and closes the endpoint, without a report; waits at most
    /// `shutdownLimit`.
    func shutdown() async {
        pathMonitor?.cancel()
        pathMonitor = nil
        guard activated, let service else { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await service.shutdown() }
            group.addTask { try? await Task.sleep(for: Self.shutdownLimit) }
            await group.next()
            group.cancelAll()
        }
    }

    // MARK: The switches

    /// "Reach this Mac from anywhere".
    func setEnabled(_ on: Bool) {
        guard service != nil else { return }
        status.enabled = on
        call { await $0.setEnabled(on) }
    }

    /// "Use a public relay if a direct connection fails".
    func setFallback(_ on: Bool) {
        guard service != nil else { return }
        status.fallback = on
        call { await $0.setFallback(on) }
    }

    // MARK: Network

    private func pathChanged(_ signature: String) {
        defer { lastPath = signature }
        guard let lastPath, lastPath != signature else { return }
        networkChanged()
    }

    private func networkChanged() {
        guard activated else { return }
        call { await $0.networkChanged() }
    }

    /// What tells one network from another: whether it is up, its gateways and its interfaces.
    nonisolated static func signature(of path: NWPath) -> String {
        let gateways = path.gateways.map { "\($0)" }.sorted().joined(separator: ",")
        let interfaces = path.availableInterfaces.map(\.name).sorted().joined(separator: ",")
        return "\(path.status) \(gateways) \(interfaces)"
    }

    // MARK: Preferences

    static func readSettings(_ preferences: UserDefaults) -> RemoteAccessService.Settings {
        guard let data = preferences.data(forKey: storageKey),
              let settings = try? JSONDecoder().decode(RemoteAccessService.Settings.self, from: data) else {
            return RemoteAccessService.Settings()
        }
        return settings
    }

    /// Saves the service's settings in the app's preferences.
    private final class SettingsStore: @unchecked Sendable {
        private let preferences: UserDefaults
        init(preferences: UserDefaults) { self.preferences = preferences }
        func save(_ settings: RemoteAccessService.Settings) {
            if let data = try? JSONEncoder().encode(settings) {
                preferences.set(data, forKey: RemoteAccessController.storageKey)
            }
        }
    }

    /// The controller the service's statuses go to, set once it exists.
    private final class StatusTarget: @unchecked Sendable {
        weak var controller: RemoteAccessController?
    }

    /// Numbers the statuses in the order the service publishes them.
    private final class StatusSequence: @unchecked Sendable {
        private let lock = NSLock()
        private var last = 0
        func next() -> Int { lock.withLock { last += 1; return last } }
    }

    /// Removes the wake observer with the controller.
    private final class ObserverToken: @unchecked Sendable {
        var token: (any NSObjectProtocol)?
        deinit { if let token { NSWorkspace.shared.notificationCenter.removeObserver(token) } }
    }
}
