import Foundation
import AgentLandCore
import AgentLandDesign
import AgentLandNotifications
import AgentLandRemoteAccess

/// Where the remote-access tunnel stands for the selected host (Settings → Connection and the offline
/// banner).
enum TunnelState: Equatable {
    /// Not tried: an address answers, or the host offers no tunnel.
    case idle
    /// The endpoint is dialing the Mac and asking for health through the bridge.
    case connecting
    /// The tunnel carries the connection.
    case connected
    /// The tunnel carried the connection and was closed for the background: the connection is down until
    /// a route answers (the tunnel is dialed again, or an address wins).
    case reconnecting
    /// The last try failed; the tunnel is tried again on its schedule.
    case retrying(RemoteAccessTunnelFailure)
    /// The Mac does not admit this device's node ID (403): not dialed until a connection at home or over
    /// Tailscale.
    case notAdmitted
    /// A newer address record names another node ID: the Mac has a new key.
    case newMacKey
    /// There is nothing to dial: remote access is off, or on without an address or relay.
    case noRoute
}

/// One route race's part in the tunnel: which addresses have failed, and the address record fetched
/// once they all have.
@MainActor final class TunnelRace {
    enum RecordState { case waiting, fetching, done }

    let id = UUID()
    let addressCount: Int
    private(set) var failedAddresses: Set<Int> = []
    var recordState = RecordState.waiting
    var record: RemoteAccessAddressRecord?
    /// The tunnel is not tried again in this race (a refusal, or nothing to dial).
    var tunnelDone = false

    init(addressCount: Int) { self.addressCount = addressCount }

    /// Notes a failed address; true when every address has now failed at least once.
    func addressFailed(_ index: Int) -> Bool {
        guard index < addressCount else { return false }
        failedAddresses.insert(index)
        return failedAddresses.count == addressCount
    }
}

extension AppModel {
    // MARK: The kept entry and registration

    /// Keeps `listed` as the host's remote-access entry ("What a device keeps"): the entry the host lists
    /// replaces the kept one; a host that lists none (or a read that failed) leaves it. Only a host paired
    /// with a fingerprint keeps one. Over an address (at home or over Tailscale, never through the tunnel)
    /// the device registers its node ID when the host does not have it, and the tunnel becomes a
    /// candidate again after a refusal.
    func learnRemoteAccess(_ listed: RemoteAccessCapabilities?, hostID: String, client: APIClient) {
        guard let index = hosts.firstIndex(where: { $0.id == hostID }), hosts[index].certificateSHA256 != nil else { return }
        let kept = RemoteAccessCapabilities.kept(saved: hosts[index].remoteAccess, listed: listed)
        if kept != hosts[index].remoteAccess { updateHost(hostID) { $0.remoteAccess = kept } }
        guard let listed, client.routing?.route.address != nil, let key = remoteAccess.nodeKeys.deviceKey() else { return }
        // At home or over Tailscale the device has just learned the Mac's node ID from the Mac itself.
        if tunnelState == .newMacKey { tunnelState = .idle }
        if listed.needsRegistration(of: key.nodeID) {
            register(key, hostID: hostID, client: client)
        } else if hosts[index].tunnelRefused {
            admitTunnelAgain(hostID)
        }
    }

    /// The host has this device's node ID again: the tunnel is a candidate again.
    private func admitTunnelAgain(_ hostID: String) {
        updateHost(hostID) { $0.tunnelRefused = false }
        if tunnelState == .notAdmitted { tunnelState = .idle }
    }

    /// `POST /v1/remote-access/device` with this device's node ID and a proof bound to its device ID.
    private func register(_ key: DeviceNodeKey, hostID: String, client: APIClient) {
        guard registration == nil, let host = hosts.first(where: { $0.id == hostID }),
              let claim = key.claim(.register, binding: host.deviceID) else { return }
        registration = Task { [weak self] in
            let registered = try? await client.registerIrohNode(claim)
            guard let self else { return }
            self.registration = nil
            guard self.client === client, registered == key.nodeID else { return }
            self.updateHost(hostID) { $0.remoteAccess?.deviceNodeID = key.nodeID }
            self.admitTunnelAgain(hostID)
        }
    }

    /// The claim a pairing sends when the invitation carries `remoteAccess` version 1 (the pairing code
    /// exactly as sent); nil without a key.
    func pairingClaim(code: String) -> IrohNodeClaim? {
        remoteAccess.nodeKeys.deviceKey()?.claim(.pair, binding: code)
    }

    /// Changes one saved host, and the selected copy of it, and saves the list.
    func updateHost(_ hostID: String, _ change: (inout SavedHost) -> Void) {
        guard let index = hosts.firstIndex(where: { $0.id == hostID }) else { return }
        change(&hosts[index])
        persistHosts()
        if selectedHost?.id == hostID { selectedHost = hosts[index] }
    }

    // MARK: The tunnel in the race

    /// Whether the tunnel is a candidate of this race: a host paired with a fingerprint whose kept entry
    /// offers it or has the Mac's node ID (the address record may still), not refused since the last
    /// connection at home, and a build whose tunnel is on.
    func tunnelIsCandidate(_ host: SavedHost?) -> Bool {
        guard let host, host.certificateSHA256 != nil, !host.tunnelRefused, let entry = host.remoteAccess,
              entry.offersTunnel || entry.fetchesAddressRecord else { return false }
        return tunnelAvailable
    }

    /// The phone can make its tunnel (the key is in the Keychain and the build's tunnel is on).
    private var tunnelAvailable: Bool {
        guard let key = remoteAccess.nodeKeys.deviceKey() else { return false }
        return phoneTunnel(key) != nil
    }

    private func phoneTunnel(_ key: DeviceNodeKey) -> (any RemoteAccessTunnelConnecting)? {
        if let tunnel { return tunnel }
        tunnel = remoteAccess.makeTunnel(key)
        return tunnel
    }

    /// An address of the race failed; once every one has, the address record is fetched (once per race,
    /// at most every 30 s) when the kept entry has the Mac's node ID.
    func addressFailed(_ index: Int, in race: TunnelRace) {
        guard race.addressFailed(index), race.recordState == .waiting else { return }
        guard let host = selectedHost, host.remoteAccess?.fetchesAddressRecord == true,
              let hostID = host.certificateSHA256.flatMap(NoticeHostID.make(certificateSHA256:)) else {
            race.recordState = .done
            return
        }
        guard recordSchedule.mayFetch(race: race.id) else {
            // Fetched less than 30 s ago: what it said then still counts.
            race.record = lastRecord?.hostID == host.id ? lastRecord?.record : nil
            race.recordState = .done
            return
        }
        race.recordState = .fetching
        let fetcher = remoteAccess.addressRecords
        let savedID = host.id
        Task { [weak self] in
            let record = await untilCancelled(within: .seconds(8)) { await fetcher.record(hostID: hostID) } ?? nil
            guard let self else { return }
            self.lastRecord = (savedID, record)
            race.record = record
            race.recordState = .done
        }
    }

    /// When the tunnel is tried again in `race` after a failure: at once (its probe waits for the tunnel's
    /// own schedule), or never in this race after a refusal or with nothing to dial.
    func tunnelRetryDelay(_ race: TunnelRace) -> Duration? {
        race.tunnelDone ? nil : .zero
    }

    /// The tunnel's probe ("The phone's routes"): wait for the tunnel's schedule, take the route the kept
    /// entry and a newer address record give, start the endpoint, dial, start the bridge and ask
    /// `GET /v1/health` through it, within `tunnelProbeTimeout`.
    func probeTunnel(_ routing: RoutedTransport, race: TunnelRace, stamp: UUID) async -> Bool {
        func current() -> Bool { !Task.isCancelled && pulseStamp == stamp && client?.routing === routing }
        if let notBefore = tunnelNotBefore, notBefore > .now {
            try? await Task.sleep(until: notBefore, clock: .continuous)
        }
        guard current(), let hostID = selectedHost?.id else { return false }
        var route = selectedHost?.remoteAccess?.tunnelRoute(record: race.record) ?? .none
        if case .dial = route {} else if selectedHost?.remoteAccess?.fetchesAddressRecord == true {
            // The kept entry offers nothing to dial: the record may, once every address has failed.
            while race.recordState != .done, current() { try? await Task.sleep(for: .milliseconds(25)) }
            guard current() else { return false }
            route = selectedHost?.remoteAccess?.tunnelRoute(record: race.record) ?? .none
        }
        switch route {
        case .none:
            race.tunnelDone = true
            if tunnelState != .notAdmitted { tunnelState = .noRoute }
            // Nothing to dial in this race: the endpoint and bridge of an earlier try or connection stop.
            closeTunnel()
            return false
        case .newMacKey:
            race.tunnelDone = true
            tunnelState = .newMacKey
            closeTunnel()
            return false
        case .dial:
            break
        }
        guard let key = remoteAccess.nodeKeys.deviceKey(), let tunnel = phoneTunnel(key) else {
            race.tunnelDone = true
            return false
        }
        tunnelState = .connecting
        let started = ContinuousClock.now
        let timeout = tunnelProbeTimeout
        let target = routing.primary
        let dial = route
        guard let opened = await untilCancelled(within: timeout + .seconds(1), { await tunnel.open(dial, target: target, timeout: timeout) }),
              current(), selectedHost?.id == hostID else { return false }
        switch opened {
        case let .failure(failure):
            return tunnelFailed(failure, race: race, hostID: hostID)
        case let .success(bridge):
            routing.attachTunnel(bridge)
            let left = max(0.5, (timeout - (ContinuousClock.now - started)).seconds)
            let answered = await routing.probeTunnel(timeout: left)
            guard current() else { return false }
            if answered {
                tunnelBackoff.reset()
                tunnelNotBefore = nil
                tunnelState = .connected
                return true
            }
            let failure = await untilCancelled(within: .seconds(1)) { await tunnel.failure() } ?? nil
            guard current() else { return false }
            return tunnelFailed(failure ?? .noAnswer, race: race, hostID: hostID)
        }
    }

    /// A refusal (403) stops dialing for this saved host until a connection at home; anything else is
    /// tried again on the tunnel's schedule.
    private func tunnelFailed(_ failure: RemoteAccessTunnelFailure, race: TunnelRace, hostID: String) -> Bool {
        if failure.stopsDialing {
            refuseTunnel(hostID: hostID)
            race.tunnelDone = true
        } else {
            tunnelNotBefore = .now + tunnelBackoff.failed()
            tunnelState = .retrying(failure)
        }
        return false
    }

    /// The Mac does not admit this device's node ID for `hostID` (the gate's 403, or
    /// `tunnel_device_mismatch`).
    func refuseTunnel(hostID: String) {
        updateHost(hostID) { $0.tunnelRefused = true }
        tunnelState = .notAdmitted
        closeTunnel()
    }

    /// Closes the phone's endpoint and bridge (the background, another host, an address answered). The
    /// next try binds it again with the same key.
    func closeTunnel() {
        client?.routing?.detachTunnel()
        guard let tunnel else { return }
        Task { await tunnel.close() }
    }

    /// The tunnel's schedule starts over (a network path change, a return to the foreground, another
    /// host).
    func restartTunnelSchedule() {
        tunnelBackoff.reset()
        tunnelNotBefore = nil
    }

    // MARK: Back to an address

    /// While the tunnel carries the connection, the addresses are raced again (without the tunnel) every
    /// `homewardInterval` and on every network path change; the first that answers takes over, as a
    /// recovery.
    func startHomeward(_ routing: RoutedTransport, stamp: UUID) {
        homewardTask?.cancel()
        homewardTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.homewardInterval else { return }
                let deadline = ContinuousClock.now + interval
                while ContinuousClock.now < deadline, !Task.isCancelled, self?.homewardNow == false {
                    try? await Task.sleep(for: .milliseconds(500))
                }
                guard let self, !Task.isCancelled, self.pulseStamp == stamp, routing.route == .tunnel else { return }
                self.homewardNow = false
                let addresses = HostEndpoint.candidates(primary: routing.primary, routes: self.selectedHost?.routes ?? [],
                                                        preferred: routing.endpoint)
                let timeout = self.routeProbeTimeout
                let winner = await RouteRace.first(addresses, stagger: self.routeStagger) { await routing.probe($0, timeout: timeout) }
                guard let winner, !Task.isCancelled, self.pulseStamp == stamp, routing.route == .tunnel else { continue }
                routing.use(winner)
                self.tunnelState = .idle
                self.closeTunnel()
                self.retryConnection()
                return
            }
        }
    }

    // MARK: What the banner says

    /// The offline banner's words when the tunnel was tried and says why the Mac cannot be reached; nil
    /// leaves the addresses' words.
    func tunnelOfflineStatus(host: String) -> ConnectionStatus? {
        switch tunnelState {
        case .notAdmitted:
            // Kept across launches, so it also shows at home while the Mac sleeps: the addresses' advice
            // comes first. The gate cannot tell a node ID it was never given from a device the owner
            // removed (at home that one meets 401 and pairs again), so the words name both.
            .offline(title: "Can’t reach \(host)",
                     detail: "\(unreachableAdvice) \(Self.notAdmittedAdvice(host: host))",
                     systemImage: "lock.slash")
        case .reconnecting where activeRoute == .tunnel, .connecting where activeRoute == .tunnel:
            // The tunnel carried the connection and is being made again (after the background, or after
            // its pulse broke): nothing is sent meanwhile.
            .offline(title: "Reconnecting to \(host)…",
                     detail: "Through remote access. Nothing is sent until the connection is back.",
                     systemImage: "arrow.triangle.2.circlepath")
        case .newMacKey:
            .offline(title: "Can’t reach \(host) from here",
                     detail: "Connect to \(host) at home or over Tailscale once to reach it from anywhere again.",
                     systemImage: "key.slash")
        case .retrying(.hostRefused), .retrying(.unavailable):
            .offline(title: "\(host) isn’t taking connections",
                     detail: "AgentLand on the Mac is starting, stopping or not running. Reconnecting…",
                     systemImage: "desktopcomputer.trianglebadge.exclamationmark")
        case .retrying(.noAnswer) where selectedHost?.knowsTailscaleRoute == true:
            // Nothing answered anywhere; the Tailscale advice stays the first thing to check.
            nil
        case .retrying(.noAnswer):
            .offline(title: "Can’t reach \(host)",
                     detail: "The Mac may be asleep or its address changed. Reconnecting… If this keeps up, connect to \(host) at home or over Tailscale once.",
                     systemImage: "wifi.exclamationmark")
        case .idle, .connecting, .connected, .reconnecting, .noRoute, .retrying(.notAdmitted):
            nil
        }
    }

    /// Why the tunnel is not tried for a refused host, and what brings it back.
    static func notAdmittedAdvice(host: String) -> String {
        "Remote access doesn’t let this device in: connect to \(host) at home or over Tailscale to turn it back on, or pair again if \(host) removed this device."
    }

    static let notAdmittedDescription = "Not admitted by the Mac; connect at home or over Tailscale, or pair again"

    /// Settings → Connection: what the Mac reported, in words ("Reach this Mac from anywhere").
    static func remoteAccessWords(_ entry: RemoteAccessCapabilities) -> String {
        guard entry.enabled else { return "Off" }
        let direct = !entry.directAddresses.isEmpty
        switch (direct, entry.relayURL != nil, entry.fallbackRelay) {
        case (true, true, _): return "On, with a public relay as a fallback"
        case (true, false, true): return "On; the Mac is picking a public relay as a fallback"
        case (true, false, false): return "On"
        case (false, true, _): return "On, through a public relay"
        case (false, false, true): return "On, no address from outside yet; the Mac is picking a public relay"
        case (false, false, false): return "On, no address from outside yet"
        }
    }

    /// Settings → Connection: the tunnel's state in words.
    var tunnelStateDescription: String {
        switch tunnelState {
        case .idle: "Standing by"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .reconnecting: "Reconnecting…"
        case .retrying(.hostRefused), .retrying(.unavailable): "The Mac isn’t taking connections; trying again soon"
        case .retrying: "No answer; trying again soon"
        case .notAdmitted: Self.notAdmittedDescription
        case .newMacKey: "The Mac has a new key; connect at home or over Tailscale once"
        case .noRoute: "No way in from outside yet"
        }
    }
}

/// Runs `operation` and returns its value, or nil once `timeout` passes or the calling task is cancelled
/// first. iroh's calls cannot be cancelled, so a race that ended never waits for one; a late value is
/// dropped.
func untilCancelled<T: Sendable>(within timeout: Duration, _ operation: @escaping @Sendable () async -> T) async -> T? {
    let once = FirstValue<T>()
    return await withTaskCancellationHandler {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            once.start(continuation)
            Task { once.finish(await operation()) }
            Task {
                try? await Task.sleep(for: timeout)
                once.finish(nil)
            }
        }
    } onCancel: {
        once.finish(nil)
    }
}

/// Resumes once, with the first value; a value given before the continuation waits is kept for it.
private final class FirstValue<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T?, Never>?
    private var early: T??
    private var done = false

    func start(_ continuation: CheckedContinuation<T?, Never>) {
        let value = lock.withLock { () -> T?? in
            if let early { return early }
            self.continuation = continuation
            return nil
        }
        if let value { continuation.resume(returning: value) }
    }

    func finish(_ value: T?) {
        let pending = lock.withLock { () -> CheckedContinuation<T?, Never>? in
            guard !done else { return nil }
            done = true
            guard let continuation else {
                early = .some(value)
                return nil
            }
            self.continuation = nil
            return continuation
        }
        pending?.resume(returning: value)
    }
}

private extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
