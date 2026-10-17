import Foundation
import SwiftUI
import Security
import LocalAuthentication
import Network
import AgentLandCore
import AgentLandDesign
import AgentLandNotifications
import AgentLandWorkspace

@MainActor protocol AppAuthenticating: AnyObject {
    func authenticate(reason: String) async throws -> Bool
    func invalidate()
}

@MainActor private final class LocalAppAuthenticator: AppAuthenticating {
    private let context = LAContext()

    func authenticate(reason: String) async throws -> Bool {
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else {
            throw AppAuthenticationError.unavailable
        }
        return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
    }

    func invalidate() {
        context.invalidate()
    }
}

private enum AppAuthenticationError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        "Set a device passcode to use app lock."
    }
}

struct SavedHost: Codable, Identifiable, Hashable {
    var id: String { address + "|" + deviceID }
    /// Where this device paired: the host's identity here, and its name is the one the certificate
    /// is validated for on every route.
    let address: String
    let deviceID: String
    var name: String
    var mode: ConnectionMode
    var certificateSHA256: String?
    /// The host's other ways in (docs/HOST-API.md, "Routes"): from the QR code, and learned on every
    /// connection. Used only for a host paired with a certificate fingerprint.
    var routes: [HostRoute]
    /// The address that answered last; the next connection tries it first. Never the tunnel.
    var lastEndpoint: HostEndpoint?
    /// The host's `capabilities.remoteAccess` as it last listed it (docs/HOST-API.md "Remote access
    /// (iroh)", What a device keeps): kept when the host lists none, replaced by each entry it lists. Only
    /// for a host paired with a certificate fingerprint.
    var remoteAccess: RemoteAccessCapabilities?
    /// The Mac refused this device's node ID through the tunnel (its gate's 403, or
    /// `tunnel_device_mismatch`): the tunnel is not dialed until the device connects at home or over
    /// Tailscale.
    var tunnelRefused: Bool

    init(address: String, deviceID: String, name: String, mode: ConnectionMode, certificateSHA256: String?,
         routes: [HostRoute] = [], lastEndpoint: HostEndpoint? = nil, remoteAccess: RemoteAccessCapabilities? = nil,
         tunnelRefused: Bool = false) {
        self.address = address; self.deviceID = deviceID; self.name = name; self.mode = mode
        self.certificateSHA256 = certificateSHA256; self.routes = routes; self.lastEndpoint = lastEndpoint
        self.remoteAccess = remoteAccess; self.tunnelRefused = tunnelRefused
    }

    enum CodingKeys: String, CodingKey { case address, deviceID, name, mode, certificateSHA256, routes, lastEndpoint, remoteAccess, tunnelRefused }
    /// Hosts saved before routes or remote access, and routes or an entry this version cannot read, still
    /// load: only those are left out.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        address = try container.decode(String.self, forKey: .address)
        deviceID = try container.decode(String.self, forKey: .deviceID)
        name = try container.decode(String.self, forKey: .name)
        mode = try container.decode(ConnectionMode.self, forKey: .mode)
        certificateSHA256 = try container.decodeIfPresent(String.self, forKey: .certificateSHA256)
        routes = HostRoute.decodeList(from: container, forKey: .routes) ?? []
        lastEndpoint = (try? container.decodeIfPresent(HostEndpoint.self, forKey: .lastEndpoint)) ?? nil
        remoteAccess = RemoteAccessCapabilities.decodeSupported(from: container, forKey: .remoteAccess)
        tunnelRefused = (try? container.decodeIfPresent(Bool.self, forKey: .tunnelRefused)) ?? false
    }

    /// Whether a Tailscale route is known for this host.
    var knowsTailscaleRoute: Bool { certificateSHA256 != nil && routes.contains(where: \.isTailscale) }

    /// Whether `other` is this host's address in another form: the same host name, whatever its case or a
    /// trailing dot, the same port (443 when none is given) and the same path.
    func sameAddress(as other: String) -> Bool {
        func parts(_ address: String) -> (host: String, port: Int, path: String)? {
            guard let url = (try? ServerAddress(validating: address))?.url,
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  var host = components.host?.lowercased(), !host.isEmpty else { return nil }
            if host.hasSuffix(".") { host.removeLast() }
            return (host, components.port ?? 443, components.path)
        }
        guard let mine = parts(address), let theirs = parts(other) else { return false }
        return mine == theirs
    }
}

/// What this device currently knows about its connection to the selected host.
/// `checking` is optimistic: surfaces load normally until a failure is proven.
enum HostConnection: Equatable {
    case checking
    case online
    case offline(HostOfflineReason)
}

enum HostOfflineReason: Equatable {
    /// The host announced a graceful shutdown (the Mac app quit or disconnected).
    case hostStopped
    /// Requests fail or the host went silent: the Mac slept, left the network or crashed.
    case unreachable
    /// This device has no network path at all.
    case noNetwork
    /// The host rejects this device's credential; it was revoked or the host was reset.
    case notPaired
}

final class DeviceTokenStore {
    func get(_ id: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: ProductIdentity.keychainService, kSecAttrAccount as String: id, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    func put(_ token: String, for id: String) -> Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: ProductIdentity.keychainService, kSecAttrAccount as String: id]
        let data = Data(token.utf8)
        let updated = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated == errSecSuccess { return true }
        guard updated == errSecItemNotFound else { return false }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
    func delete(_ id: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: ProductIdentity.keychainService, kSecAttrAccount as String: id]
        SecItemDelete(query as CFDictionary)
    }
}

@MainActor @Observable final class AppModel {
    var hosts: [SavedHost] = []
    var selectedHost: SavedHost?
    /// The selected host's workspace: tabs, sessions and the opening ticket. It lives as long as the
    /// app model; changing host re-attaches it.
    let workspace: WorkspaceModel
    var error: String?
    var busy = false
    /// The Mac a scanned pairing code is pairing with, while `pair(invitation:)` runs.
    var pairingHostName: String?
    private(set) var lockEnabled = false
    /// The lock covers the workspace. The workspace keeps the value so its surfaces see it; only
    /// the app model changes it.
    private(set) var locked: Bool {
        get { workspace.locked }
        set { workspace.locked = newValue }
    }
    private(set) var isAuthenticating = false
    private(set) var authenticationMessage: String?
    /// Settings' Require device unlock is being turned on: Face ID or the passcode confirms it in place first.
    private(set) var confirmingLock = false
    /// Why device unlock did not turn on (it stays off); nil after a success or a cancel.
    private(set) var lockSettingMessage: String?
    @ObservationIgnored private var lockConfirmationID: UUID?
    @ObservationIgnored private var lockConfirmer: (any AppAuthenticating)?
    var presentationTicket: WorkspacePresentationTicket? { workspace.presentationTicket }
    var presentationPending: Bool { workspace.presentationPending }
    var presentationReady: Bool { workspace.presentationReady }
    var loadingProjects: Bool { workspace.loadingProjects }
    private(set) var connection: HostConnection = .checking {
        didSet {
            workspace.reachable = hostReachable
            // A host that answers on no address (the route race's 4 s probes, or the pulse's idle limit)
            // resolves the opening now: the workspace shows the offline banner and each surface's offline
            // state instead of the cover waiting out 20 s request timeouts (B-14). Retrying goes on.
            if !hostReachable { workspace.resolvePresentationOffline() }
            if connection != oldValue { updateArchiveSync() }
        }
    }
    /// Increments each time the host becomes reachable again after an outage,
    /// so retained surfaces resume polling and reload what failed meanwhile.
    var connectionEpoch: Int { workspace.connectionEpoch }
    var hostReachable: Bool { if case .offline = connection { false } else { true } }
    var client: APIClient? {
        get { workspace.client }
        set { workspace.client = newValue }
    }
    /// Push through the owner's iCloud: the permission, the account's subscriptions and the tip.
    let notifications: NotificationsModel
    /// A short notice over the workspace: a tapped notification that cannot open, or the tip's outcome.
    var appNotice: AppNotice?
    /// A tapped notification on its way to what it names (AppModel+Notices).
    @ObservationIgnored var pendingNotice: NoticeRoute?
    @ObservationIgnored var noticeFetch: Task<Void, Never>?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let authenticatorFactory: @MainActor () -> any AppAuthenticating
    /// Opens a host's copy on this device, its file work off the main actor; tests pass their own.
    @ObservationIgnored private let archiveOpener: @MainActor (ConnectionIdentity, APIClient?) async -> WorkspaceArchive?
    /// Deletes a forgotten host's copy on this device (its database and caches); tests pass their own.
    @ObservationIgnored private let deviceCopyRemover: (ConnectionIdentity) async throws -> Void
    /// The last forget's file work, for tests to wait on.
    @ObservationIgnored private(set) var forgetting: Task<Void, Never>?
    /// The scene became active while the opening covered the workspace; notifications check the
    /// permission once it has cleared.
    @ObservationIgnored private var noticesWaitForOpening = false
    @ObservationIgnored private let tokens = DeviceTokenStore()
    @ObservationIgnored private(set) var scenePhase: ScenePhase = .inactive
    @ObservationIgnored private var authenticationArmed = true
    @ObservationIgnored private var authenticationID: UUID?
    @ObservationIgnored private var authenticator: (any AppAuthenticating)?
    @ObservationIgnored private var authenticationTask: Task<Void, Never>?
    @ObservationIgnored private var presenceTask: Task<Void, Never>?
    @ObservationIgnored private var presenceStopTask: Task<Void, Never>?
    /// The heartbeat's wait for its next beat; a change of the chat on screen ends it early.
    @ObservationIgnored private var presenceWait: Task<Void, Error>?
    /// The chat the last heartbeat reported (nil: none), to tell when the chat on screen changed.
    @ObservationIgnored private var presenceSentView: PresenceView?
    /// How often the heartbeat goes out, and how long a change of the chat on screen waits before it is
    /// reported, so switching through several chats sends one heartbeat rather than one for each.
    @ObservationIgnored var presenceInterval: Duration = .seconds(15)
    @ObservationIgnored var presenceCoalescing: Duration = .milliseconds(500)
    @ObservationIgnored private var pulseTask: Task<Void, Never>?
    @ObservationIgnored private(set) var pulseStamp = UUID()
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    @ObservationIgnored private var networkAvailable = true
    @ObservationIgnored private var networkRoute: String?
    /// Where requests go now, for a host known at more than one address or through the tunnel
    /// (Settings shows it).
    private(set) var activeRoute: RouteCandidate?
    /// The address requests go to now; nil through the tunnel.
    var activeEndpoint: HostEndpoint? { activeRoute?.address }

    // Remote access (AppModel+RemoteAccess, docs/HOST-API.md "Remote access (iroh)").
    @ObservationIgnored let remoteAccess: RemoteAccessServices
    /// The phone's tunnel, made the first time the race tries it; closed in the background.
    @ObservationIgnored var tunnel: (any RemoteAccessTunnelConnecting)?
    /// Where the tunnel stands for the selected host.
    var tunnelState: TunnelState = .idle
    @ObservationIgnored var tunnelBackoff = RemoteAccessTunnelBackoff()
    /// The tunnel is not dialed again before this (its own schedule after a failure).
    @ObservationIgnored var tunnelNotBefore: ContinuousClock.Instant?
    /// How long the tunnel's probe has: a dial through a relay can take several seconds longer than an
    /// address's 4 s.
    @ObservationIgnored var tunnelProbeTimeout: Duration = .seconds(10)
    /// While the tunnel carries the connection, the addresses are raced again this often.
    @ObservationIgnored var homewardInterval: Duration = .seconds(60)
    @ObservationIgnored var homewardTask: Task<Void, Never>?
    /// A network path change asks the tunnel's homeward race to run now.
    @ObservationIgnored var homewardNow = false
    @ObservationIgnored var recordSchedule = RemoteAccessRecordSchedule()
    /// The address record the last fetch found (memory only; never saved as the host's entry).
    @ObservationIgnored var lastRecord: (hostID: String, record: RemoteAccessAddressRecord?)?
    @ObservationIgnored var registration: Task<Void, Never>?
    /// The app came back to the foreground: capabilities are read again once the pulse answers.
    @ObservationIgnored private var capabilitiesOnForeground = false
    /// The scene went to the background since it was last active. iOS comes back through `.inactive`
    /// (background, inactive, active), so the phase just before `.active` never tells a return.
    @ObservationIgnored private var wasInBackground = false
    /// How long the address that answered last has before the next is tried too, how long each
    /// address has to answer, and when an address that failed is tried again while the others are
    /// still being tried (docs/HOST-API.md, "Routes").
    @ObservationIgnored var routeStagger: Duration = .milliseconds(250)
    @ObservationIgnored var routeProbeTimeout: TimeInterval = 4
    @ObservationIgnored var routeRetryDelays: [Duration] = [.milliseconds(500), .seconds(1), .seconds(1), .seconds(2)]
    /// The monitor whose route race is running: surface failures meanwhile do not start it over.
    @ObservationIgnored private var racingStamp: UUID?
    /// The route the current connection epoch belongs to (an address, or the tunnel whatever its bridge's
    /// port). Reaching the host on another one starts a new epoch, even when the monitor that moved there
    /// was stopped before the pulse answered.
    @ObservationIgnored private var epochEndpoint: RouteCandidate?

    func presentationRequest(for tabID: UUID) -> WorkspacePresentationTicket? {
        workspace.presentationRequest(for: tabID)
    }

    func reportPresentationReady(_ ticket: WorkspacePresentationTicket) {
        workspace.reportPresentationReady(ticket)
    }

    /// Content readiness starts the final layout pass. Only its matching frame
    /// acknowledgement can remove the opening cover; Face ID remains separate.
    func completePresentation(_ ticket: WorkspacePresentationTicket) {
        guard !locked, !busy, scenePhase == .active, workspace.completePresentation(ticket) else { return }
        // What waited for the cover to clear: the archive's sync, the notification check, a tapped notice.
        updateArchiveSync()
        checkNoticesAfterOpening()
        advanceNotice()
    }

    init(
        defaults: UserDefaults = .standard,
        authenticatorFactory: @escaping @MainActor () -> any AppAuthenticating = { LocalAppAuthenticator() },
        notifications: NotificationsModel? = nil,
        archiveOpener: @escaping @MainActor (ConnectionIdentity, APIClient?) async -> WorkspaceArchive? = { await WorkspaceArchive.open(for: $0, client: $1) },
        deviceCopyRemover: @escaping (ConnectionIdentity) async throws -> Void = { try await WorkspaceArchive.removeDeviceCopy(for: $0) },
        remoteAccess: RemoteAccessServices? = nil
    ) {
        self.defaults = defaults
        self.authenticatorFactory = authenticatorFactory
        self.notifications = notifications ?? Self.makeNotifications(defaults: defaults)
        self.archiveOpener = archiveOpener
        self.deviceCopyRemover = deviceCopyRemover
        self.remoteAccess = remoteAccess ?? .live()
        workspace = WorkspaceModel(defaults: defaults)
        hosts = (defaults.data(forKey: ProductIdentity.connectionsDefaultsKey).flatMap { try? JSONDecoder().decode([SavedHost].self, from: $0) }) ?? []
        lockEnabled = defaults.bool(forKey: "agentland.lock.enabled")
        locked = lockEnabled
        workspace.onConnectionFailure = { [weak self] in self?.noteConnectionFailure() }
        if let id = defaults.string(forKey: ProductIdentity.selectedConnectionDefaultsKey), let host = hosts.first(where: { $0.id == id }) { select(host) }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            let route = path.availableInterfaces.map(\.name).joined(separator: ",")
            Task { @MainActor [weak self] in self?.networkPathChanged(available: available, route: route) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "dev.agentland.client.network"))
        watchSelectedChatTurn()
        watchPresenceView()
    }

    deinit { pathMonitor.cancel() }
    var identity: ConnectionIdentity? { selectedHost.map { ConnectionIdentity(host: $0.address, deviceID: $0.deviceID) } }
    func persistHosts() {
        if let data = try? JSONEncoder().encode(hosts) { defaults.set(data, forKey: ProductIdentity.connectionsDefaultsKey) }
    }
    func select(_ host: SavedHost) {
        stopPresence()
        stopConnectionMonitor()
        closeTunnel()
        // A refusal kept with the host (a relaunch, another host and back) still says why the tunnel is
        // not tried until a connection at home or over Tailscale.
        tunnelState = host.tunnelRefused ? .notAdmitted : .idle
        restartTunnelSchedule()
        connection = .checking
        selectedHost = host
        defaults.set(host.id, forKey: ProductIdentity.selectedConnectionDefaultsKey)
        error = nil
        let identity = ConnectionIdentity(host: host.address, deviceID: host.deviceID)
        var client: APIClient?
        if let address = try? ServerAddress(validating: host.address), let token = tokens.get(host.id) {
            client = APIClient(address: address, token: token, transport: Self.transport(for: host, address: address))
        }
        activeRoute = client?.routing?.route
        epochEndpoint = activeRoute
        // Establishes the cover synchronously: no frame of the restored tab's empty or loading surface
        // escapes before the project load begins. Only a workspace this device opened is current;
        // nothing is assumed from the host's project list.
        workspace.hostName = host.name
        workspace.attach(hostID: host.id, identity: identity, client: client,
                         issue: client == nil ? "This host needs to be paired again." : nil)
        guard let client else { return }
        // The host's copy on this device opens off the main actor behind the cover, and every chat of
        // this host reads it first; its sync waits for the opening to clear (updateArchiveSync).
        let opener = archiveOpener
        workspace.openArchive({ await opener(identity, client) }, opened: { [weak self] archive in
            guard let self else { return }
            archive.update(client: self.client, capabilities: self.workspace.capabilities)
            self.updateArchiveSync()
        })
        startPresenceIfNeeded()
        startConnectionMonitor()
        Task {
            await refreshProjects()
            // A tapped notice that switched to this host opens once its projects answer.
            advanceNotice()
        }
    }
    /// A host paired with a certificate fingerprint is reached at any address it is known by (its
    /// routes), starting with the one that answered last; each keeps the paired pin and validates the
    /// certificate for the paired name. A host paired without a fingerprint keeps its one address.
    static func transport(for host: SavedHost, address: ServerAddress) -> any APITransport {
        if let primary = HostEndpoint(address: address) {
            let known = HostEndpoint.candidates(primary: primary, routes: host.routes)
            let start = host.lastEndpoint.flatMap { known.contains($0) ? $0 : nil }
            if let routed = RoutedTransport(address: address, certificateSHA256: host.certificateSHA256, endpoint: start) { return routed }
        }
        return URLSessionTransport(expectedHost: address.url.host, certificateSHA256: host.certificateSHA256)
    }

    func disconnect() {
        stopPresence()
        stopConnectionMonitor()
        closeTunnel()
        tunnelState = .idle
        connection = .checking
        activeRoute = nil
        epochEndpoint = nil
        selectedHost = nil
        workspace.detach()
        defaults.removeObject(forKey: ProductIdentity.selectedConnectionDefaultsKey)
        error = nil
    }
    /// Forgets a saved host on this device (Settings → Connection → Forget…): its credential leaves the Keychain,
    /// the host leaves the saved list, its saved workspace and tabs (drafts included) go, and so does this device's
    /// copy of its chats and terminal logs, once the copy has closed. The selected host is disconnected first,
    /// which returns to pairing. The host has no route for a device to revoke itself (docs/HOST-API.md), so the
    /// Mac still lists this device until it is revoked there.
    func forget(_ host: SavedHost) {
        if selectedHost?.id == host.id { disconnect() }
        tokens.delete(host.id)
        let identity = ConnectionIdentity(host: host.address, deviceID: host.deviceID)
        workspace.forgetSavedState(for: identity)
        hosts.removeAll { $0.id == host.id }
        persistHosts()
        let closing = workspace.archiveClosing, remove = deviceCopyRemover, previous = forgetting
        forgetting = Task {
            await previous?.value
            await closing?.value
            // Best effort: the caches are purgeable anyway, and a database left behind is never opened again
            // without pairing with that host again.
            try? await remove(identity)
        }
    }

    /// Settings → Privacy & Security: empties this device's copy of the selected host's chats and terminal logs and
    /// copies them again from the host. Tabs and drafts stay. Returns why it failed, or nil.
    func clearDeviceCopy() async -> String? {
        do {
            try await workspace.clearDeviceCopy()
            return nil
        } catch {
            return error.localizedDescription
        }
    }
    /// Pairs at `raw`. A QR code's `routes` are kept with the host; when the address itself provably
    /// did not reach the host (so the single-use code was not spent), they are tried in turn, each
    /// with the scanned certificate fingerprint and name. With `remoteAccess` (the invitation carries
    /// `remoteAccess` version 1) the device gives its iroh node ID with a proof bound to the code;
    /// otherwise it registers it later, at home or over Tailscale. A host this device already paired
    /// with (`previousPairing`) gets that pairing's token too, so it pairs again over the same record
    /// (docs/HOST-API.md, "Pairing again"; owner, 2026-10-17); the saved row then takes the new token
    /// and keeps its tabs, workspace and device copy (`savingPairing`).
    func pair(address raw: String, code: String, name: String, mode: ConnectionMode, certificateSHA256: String,
              routes: [HostRoute] = [], remoteAccess: Bool = false) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            let address = try ServerAddress(validating: raw)
            let suppliedPin = certificateSHA256.trimmingCharacters(in: .whitespacesAndNewlines)
            let pin = suppliedPin.lowercased().filter { $0 != ":" && !$0.isWhitespace }
            guard pin.isEmpty || (pin.count == 64 && pin.allSatisfy(\.isHexDigit)) else { error = "Enter the 64-digit SHA-256 certificate fingerprint shown by the host."; return }
            let draft = SavedHost(address: address.url.absoluteString, deviceID: "", name: name.isEmpty ? address.url.host ?? "Host" : name,
                                  mode: mode, certificateSHA256: pin.isEmpty ? nil : pin, routes: pin.isEmpty ? [] : routes)
            let client = APIClient(address: address, token: "", transport: Self.transport(for: draft, address: address))
            let endpoints: [HostEndpoint?] = client.routing.map { routing in
                HostEndpoint.candidates(primary: routing.primary, routes: draft.routes).map(Optional.some)
            } ?? [nil]
            let pairingCode = code.trimmingCharacters(in: .whitespacesAndNewlines), deviceName = UIDevice.current.name
            let node = remoteAccess ? pairingClaim(code: pairingCode) : nil
            let previous = Self.previousPairing(in: hosts, address: draft.address, certificateSHA256: draft.certificateSHA256,
                                                selectedID: selectedHost?.id) { tokens.get($0.id) != nil }
            let previousToken = previous.flatMap { tokens.get($0.id) }
            let pairing = try await Self.pairing(over: endpoints) { endpoint in
                if let endpoint { client.routing?.use(endpoint) }
                return try await client.pair(code: pairingCode, deviceName: deviceName, node: node, previousToken: previousToken)
            }
            let reached = client.routing.flatMap { $0.endpoint == $0.primary ? nil : $0.endpoint }
            let paired = SavedHost(address: draft.address, deviceID: pairing.deviceID, name: draft.name, mode: mode,
                                   certificateSHA256: draft.certificateSHA256, routes: draft.routes, lastEndpoint: reached)
            let saved = Self.savingPairing(paired, previous: previous, in: hosts)
            // The same Keychain item as the row's old token when the host paired again: it is overwritten.
            guard tokens.put(pairing.token, for: saved.host.id) else { error = "The pairing succeeded, but this device could not securely save its credential."; return }
            hosts = saved.hosts; persistHosts(); select(saved.host)
        } catch { self.error = error.localizedDescription }
    }
    /// Pairs at the first of `endpoints` that reaches the host. The next address is tried only when
    /// the request provably never reached a host: refused, not found, or a TLS check that turned the
    /// address away before anything was sent (another server there), so the single-use code cannot
    /// have been spent. The paired address's own error is reported unless a later address reached the
    /// host and it refused.
    static func pairing(over endpoints: [HostEndpoint?],
                        attempt: (HostEndpoint?) async throws -> PairResponse) async throws -> PairResponse {
        var failure: Error?
        for endpoint in endpoints {
            do {
                return try await attempt(endpoint)
            } catch {
                let turnedAway = (error as? URLError)?.code == .cancelled && !Task.isCancelled
                let undelivered = ClientError.isUndelivered(error) || turnedAway
                if failure == nil || !undelivered { failure = error }
                if !undelivered { break }
            }
        }
        throw failure ?? ClientError.unreachable
    }

    func refreshProjects() async {
        let hostID = selectedHost?.id
        await workspace.refreshProjects()
        // The engine follows the host's changes only when its capabilities list archive sync.
        workspace.archive?.update(client: client, capabilities: workspace.capabilities)
        updateArchiveSync()
        if let hostID, selectedHost?.id == hostID {
            learnRoutes(workspace.capabilities?.routes, hostID: hostID)
            if let client { learnRemoteAccess(workspace.capabilities?.remoteAccess, hostID: hostID, client: client) }
        }
    }

    // MARK: Routes

    /// Keeps the routes the host lists (docs/HOST-API.md, "Routes") with the saved host, so a device
    /// paired before them, or at home, knows the way in when it is away. Only a host paired with a
    /// fingerprint uses them.
    func learnRoutes(_ advertised: [HostRoute]?, hostID: String) {
        guard let advertised, let index = hosts.firstIndex(where: { $0.id == hostID }),
              hosts[index].certificateSHA256 != nil else { return }
        let merged = HostRoute.merged(saved: hosts[index].routes, advertised: advertised)
        guard merged != hosts[index].routes else { return }
        hosts[index].routes = merged
        persistHosts()
        if selectedHost?.id == hostID { selectedHost?.routes = merged }
    }

    /// Remembers the address that answered, so the next connection tries it first.
    private func rememberEndpoint(_ endpoint: HostEndpoint, hostID: String) {
        guard let index = hosts.firstIndex(where: { $0.id == hostID }) else { return }
        let remembered: HostEndpoint? = endpoint == client?.routing?.primary ? nil : endpoint
        guard hosts[index].lastEndpoint != remembered else { return }
        hosts[index].lastEndpoint = remembered
        persistHosts()
        if selectedHost?.id == hostID { selectedHost?.lastEndpoint = remembered }
    }

    /// The addresses to try for the selected host: the one in use first, then the paired address and
    /// every route's.
    private func routeCandidates(_ routing: RoutedTransport) -> [HostEndpoint] {
        HostEndpoint.candidates(primary: routing.primary, routes: selectedHost?.routes ?? [], preferred: routing.endpoint)
    }

    /// The device archive syncs only in the foreground, unlocked, with the host reachable, and once the
    /// opening has cleared, so nothing competes with the selected surface while the cover is up.
    private func updateArchiveSync() {
        workspace.archive?.setRunning(scenePhase == .active && !locked && hostReachable && client != nil && !presentationPending)
    }

    /// Notifications read the permission and register for pushes once it is allowed (never asking) on
    /// each activation, after the opening has cleared.
    private func checkNoticesAfterOpening() {
        guard noticesWaitForOpening, scenePhase == .active, !presentationPending else { return }
        noticesWaitForOpening = false
        Task { await notifications.sceneBecameActive() }
    }
    /// Settings → Privacy & Security → Require device unlock. Turning it on asks Face ID or the passcode to confirm
    /// it in place (B-17, owner-approved 2026-10-05): the app is not locked and Settings stays open; only a success
    /// turns it on, and a cancel or failure leaves it off. The prompt's `.inactive` transition starts no second
    /// prompt (the lock is still off), a background transition cancels it, and a result that arrives after that
    /// is dropped. Turning it off needs no confirmation.
    func enableLock(_ enabled: Bool) {
        guard enabled else {
            cancelLockConfirmation()
            guard lockEnabled else { return }
            lockEnabled = false
            defaults.set(false, forKey: "agentland.lock.enabled")
            authenticationMessage = nil
            authenticationArmed = true
            locked = false
            cancelAuthentication()
            startPresenceIfNeeded()
            advanceNotice()
            updateArchiveSync()
            return
        }
        guard !lockEnabled, !confirmingLock else { return }
        lockSettingMessage = nil
        confirmingLock = true
        let id = UUID()
        let authenticator = authenticatorFactory()
        lockConfirmationID = id
        lockConfirmer = authenticator
        Task { [weak self] in
            let result: Result<Bool, Error>
            do {
                result = .success(try await authenticator.authenticate(reason: "Turn on device unlock for AgentLand"))
            } catch {
                result = .failure(error)
            }
            // A confirmation the background or turning it off cancelled changes nothing.
            guard let self, self.lockConfirmationID == id else { return }
            self.lockConfirmationID = nil
            self.lockConfirmer = nil
            self.confirmingLock = false
            switch result {
            case .success(true):
                self.lockEnabled = true
                self.defaults.set(true, forKey: "agentland.lock.enabled")
                self.authenticationMessage = nil
                // The person just proved who they are: the app stays unlocked, and the next return from the
                // background asks again.
                self.authenticationArmed = true
            case .success(false):
                self.lockSettingMessage = "Device unlock wasn’t confirmed, so it stays off."
            case .failure(let error):
                self.lockSettingMessage = Self.lockSettingMessage(for: error)
            }
        }
    }

    /// Stops a confirmation of turning device unlock on; its result is ignored and the switch stays off.
    private func cancelLockConfirmation() {
        guard lockConfirmationID != nil else { return }
        lockConfirmationID = nil
        lockConfirmer?.invalidate()
        lockConfirmer = nil
        confirmingLock = false
    }

    /// Nothing to say after a cancel; otherwise why device unlock stays off.
    private static func lockSettingMessage(for error: Error) -> String? {
        let error = error as NSError
        let cancellationCodes = [LAError.Code.userCancel, .appCancel, .systemCancel].map(\.rawValue)
        if error.domain == LAError.errorDomain, cancellationCodes.contains(error.code) { return nil }
        return error.localizedDescription
    }

    func clearLockSettingMessage() { lockSettingMessage = nil }

    func handleScenePhase(_ phase: ScenePhase) {
        scenePhase = phase
        switch phase {
        case .active:
            if wasInBackground {
                // Capabilities are read again on every return to the foreground, and the tunnel's
                // schedule starts over (docs/HOST-API.md "Remote access (iroh)").
                wasInBackground = false
                capabilitiesOnForeground = true
                restartTunnelSchedule()
            }
            beginAuthenticationIfNeeded()
            startPresenceIfNeeded()
            startConnectionMonitor()
            updateArchiveSync()
            noticesWaitForOpening = true
            checkNoticesAfterOpening()
            advanceNotice()
            // A foreground period for chat naming; it waits for the lock and the copy's sync by itself.
            workspace.naming.foregroundBegan()
        case .background:
            wasInBackground = true
            workspace.naming.backgroundBegan()
            stopPresence()
            stopConnectionMonitor()
            // The phone's endpoint runs only in the foreground; it binds again with the same key. When it
            // carried the connection, the connection is down from here on: until a route answers again
            // nothing is sent into a tunnel that is gone, and the banner says it is reconnecting.
            if activeRoute == .tunnel {
                if tunnelState == .connected || tunnelState == .connecting { tunnelState = .reconnecting }
                if hostReachable { connection = .offline(.unreachable) }
            }
            closeTunnel()
            // Turning device unlock on is confirmed in the foreground only: the background cancels it.
            cancelLockConfirmation()
            if lockEnabled { locked = true }
            updateArchiveSync()
            workspace.beginPresentation()
            authenticationArmed = true
            authenticationMessage = nil
            cancelAuthentication()
        case .inactive:
            presenceTask?.cancel()
            presenceTask = nil
        @unknown default:
            break
        }
    }

    // MARK: Host connection

    /// The connection as the workspace's banner shows it: nothing while online or checking, what is
    /// wrong and what happens next while offline.
    var connectionStatus: ConnectionStatus {
        guard case let .offline(reason) = connection else { return .online }
        let host = selectedHost?.name ?? "the host"
        switch reason {
        case .noNetwork:
            return .offline(title: "No network connection",
                            detail: "Your work is safe on the Mac. AgentLand reconnects when this device is back online.",
                            systemImage: "wifi.slash")
        case .hostStopped:
            return .offline(title: "AgentLand stopped on \(host)",
                            detail: "Terminals and chats keep their place. Reconnecting when the Mac app starts again…",
                            systemImage: "desktopcomputer.trianglebadge.exclamationmark")
        case .unreachable where client?.routing != nil && tunnelOfflineStatus(host: host) != nil:
            // No address answered and the tunnel was tried: what it met says what to do
            // (docs/HOST-API.md "The two apps", Refusals).
            return tunnelOfflineStatus(host: host) ?? .online
        case .unreachable:
            return .offline(title: "Can’t reach \(host)", detail: unreachableAdvice + " Reconnecting…", systemImage: "wifi.exclamationmark")
        case .notPaired:
            return .offline(title: "Not paired with \(host)",
                            detail: "The host no longer accepts this device. Pair again from Settings.",
                            systemImage: "lock.slash")
        }
    }

    /// What the banner says when no address answers: to check Tailscale when a Tailscale route is known
    /// (it did not answer either), otherwise that the Mac may be asleep or elsewhere.
    var unreachableAdvice: String {
        selectedHost?.knowsTailscaleRoute == true && client?.routing != nil
            ? "Away from home, AgentLand connects through Tailscale — check that Tailscale is on."
            : "The Mac may be asleep or on another network."
    }

    /// Retrying helps unless the device itself has no network.
    var canRetryConnection: Bool { connection != .offline(.noNetwork) }

    /// Checks the connection now instead of waiting for the next backoff step.
    func retryConnection() {
        stopConnectionMonitor()
        startConnectionMonitor()
    }

    /// The banner's Retry: every route is tried at once, the tunnel too (its schedule starts over), as
    /// the person asked for; the automatic retries keep the tunnel's schedule.
    func retryNow() {
        restartTunnelSchedule()
        retryConnection()
    }

    /// A surface saw a transport failure. The pulse decides whether the host is
    /// actually gone; this only makes it look sooner than its idle limit. While
    /// the monitor is choosing an address it is already looking, so a failure
    /// then (a surface still reading the old address) never starts it over.
    func noteConnectionFailure() {
        guard hostReachable, pulseTask != nil, !routeRaceRunning else { return }
        retryConnection()
    }

    /// The current monitor is racing the host's addresses.
    var routeRaceRunning: Bool { racingStamp != nil && racingStamp == pulseStamp }

    private func startConnectionMonitor() {
        guard scenePhase == .active, let client, pulseTask == nil else { return }
        let stamp = UUID()
        pulseStamp = stamp
        pulseTask = Task { [weak self] in await self?.monitorConnection(client: client, stamp: stamp) }
    }

    private func stopConnectionMonitor() {
        pulseTask?.cancel()
        pulseTask = nil
        homewardTask?.cancel()
        homewardTask = nil
        pulseStamp = UUID()
    }

    private func networkPathChanged(available: Bool, route: String) {
        let regained = available && !networkAvailable
        let rerouted = networkRoute != nil && networkRoute != route
        networkAvailable = available
        networkRoute = route
        guard client != nil else { return }
        if regained || rerouted { restartTunnelSchedule() }
        if !available {
            stopConnectionMonitor()
            connection = .offline(.noNetwork)
        } else if rerouted, !regained, pulseTask != nil, activeRoute == .tunnel, homewardTask != nil {
            // The tunnel carries the connection: race the addresses again (without the tunnel) and move
            // to the first that answers; the tunnel itself follows the new path.
            homewardNow = true
        } else if regained || (rerouted && pulseTask != nil) {
            // A new interface (Wi-Fi to cellular, VPN up/down) can strand the
            // existing connection. Reopen the pulse on the current path now.
            retryConnection()
        }
    }

    private func monitorConnection(client: APIClient, stamp: UUID) async {
        var failures = 0
        var legacy = false
        // A host known at more than one address picks one before the pulse: the one in use (the last
        // that answered) first, the others a moment later or at once when it fails. Again after any
        // failure; the monitor also starts afresh when the network path changes.
        var chooseRoute = client.routing != nil
        let hostID = selectedHost?.id
        func current() -> Bool { !Task.isCancelled && pulseStamp == stamp && self.client === client }
        while current() {
            guard networkAvailable else { connection = .offline(.noNetwork); return }
            var outcome: HostOfflineReason?
            if chooseRoute, let routing = client.routing {
                chooseRoute = false
                let addresses = routeCandidates(routing)
                // The remote-access tunnel is a candidate of its own kind, always the last: tried 250 ms
                // after the last address starts, or at once when they have all failed, on its own
                // schedule (docs/HOST-API.md "The two apps", The phone's routes).
                let candidates = addresses.map(RouteCandidate.address) + (tunnelIsCandidate(selectedHost) ? [.tunnel] : [])
                if candidates.count > 1 {
                    // The race goes on until an address answers (or this monitor stops): each one that
                    // fails is tried again on the retry schedule, so a hung address holds up nothing and
                    // a Mac that comes back is found within about two seconds. As soon as the address in
                    // use fails the host shows as unreachable (typing is refused), while the others are
                    // still tried.
                    let timeout = routeProbeTimeout
                    let retries = routeRetryDelays
                    let race = TunnelRace(addressCount: addresses.count)
                    racingStamp = stamp
                    let winner = await RouteRace.first(candidates, stagger: routeStagger, retryDelay: { @MainActor [weak self] index, failures in
                        guard index < race.addressCount else { return self?.tunnelRetryDelay(race) }
                        return retries.isEmpty ? nil : retries[min(failures - 1, retries.count - 1)]
                    }, failed: { @MainActor [weak self] index in
                        guard let self, self.pulseStamp == stamp, self.client === client else { return }
                        if index < race.addressCount { self.addressFailed(index, in: race) }
                        guard index == 0 else { return }
                        // After an announced stop, keep saying the Mac app stopped.
                        if self.connection != .offline(.hostStopped) { self.connection = .offline(.unreachable) }
                    }) { [weak self] candidate in
                        switch candidate {
                        case let .address(endpoint): return await routing.probe(endpoint, timeout: timeout)
                        case .tunnel: return await self?.probeTunnel(routing, race: race, stamp: stamp) ?? false
                        }
                    }
                    if racingStamp == stamp { racingStamp = nil }
                    guard current() else { return }
                    switch winner {
                    case let .address(endpoint)?:
                        routing.use(endpoint)
                        activeRoute = .address(endpoint)
                        if let hostID { rememberEndpoint(endpoint, hostID: hostID) }
                        // Home again (or on Tailscale): the phone's endpoint stops.
                        if tunnelState != .notAdmitted && tunnelState != .newMacKey { tunnelState = .idle }
                        closeTunnel()
                    case .tunnel?:
                        routing.useTunnel()
                        activeRoute = .tunnel
                        startHomeward(routing, stamp: stamp)
                    case nil:
                        outcome = .unreachable
                    }
                } else if routing.route == .tunnel, let only = addresses.first {
                    // The tunnel is no longer a candidate (refused): back to the one address.
                    routing.use(only)
                    activeRoute = .address(only)
                    if tunnelState == .reconnecting { tunnelState = .idle }
                    closeTunnel()
                }
            }
            if outcome == nil {
                do {
                    if legacy {
                        // Hosts without a pulse still answer health quickly.
                        _ = try await client.health(timeout: 4)
                        guard current() else { return }
                        markOnline(client)
                        failures = 0
                        try await Task.sleep(for: .seconds(3))
                        continue
                    }
                    for try await event in try await client.pulse() {
                        guard current() else { return }
                        switch event {
                        case .ready, .beat:
                            markOnline(client)
                            failures = 0
                        case .stopping:
                            outcome = .hostStopped
                        case .end:
                            break
                        case let .remoteAccess(revision):
                            // Remote access changed on the Mac: read it again.
                            if revision != selectedHost?.remoteAccess?.revision { readCapabilities(client) }
                        case let .plainChats(revision):
                            // Plain chats came, went or changed their tools: the workspace reads the host's
                            // capabilities again when this is another revision than the one it read.
                            workspace.notePlainChatsRevision(revision)
                        }
                        if outcome != nil { break }
                    }
                } catch is CancellationError {
                    return
                } catch let error as ClientError {
                    if case let .server(code, _) = error, code == "not_found" { legacy = true; continue }
                    if case let .server(code, _) = error, code == "unauthorized" { outcome = .notPaired }
                    else if case let .server(code, _) = error, code == "tunnel_device_mismatch", client.routing?.route == .tunnel,
                            let hostID {
                        // Another device record holds this device's node ID: the Mac does not admit it
                        // for this saved host until it connects at home and registers.
                        refuseTunnel(hostID: hostID)
                        outcome = .unreachable
                    } else { outcome = .unreachable }
                } catch let error as URLError where error.code == .unsupportedURL {
                    legacy = true
                    continue
                } catch {
                    outcome = networkAvailable ? .unreachable : .noNetwork
                }
            }
            guard current() else { return }
            guard let outcome else { continue } // The host ended this stream on schedule.
            chooseRoute = client.routing != nil && outcome != .notPaired
            // After an announced stop, refused connections are expected; keep
            // telling the person the Mac app stopped rather than "can't reach".
            if connection != .offline(.hostStopped) || outcome != .unreachable { connection = .offline(outcome) }
            failures += 1
            // Short and capped: a refused or silent attempt costs nothing, and a
            // Mac that comes back should be picked up within about two seconds.
            let delays: [Double] = [0.5, 1, 1, 2]
            do { try await Task.sleep(for: .seconds(delays[min(failures - 1, delays.count - 1)])) } catch { return }
        }
    }

    /// The pulse answered. After an outage, or on another route than the current epoch's (also when
    /// the monitor that moved there stopped before the pulse answered), surfaces resume from their
    /// cursors and reload what failed (a new connection epoch), and the host's routes and remote access
    /// are read again. A move between the tunnel and an address reads the projects and capabilities
    /// again too: through the tunnel the host leaves out `preview`.
    private func markOnline(_ client: APIClient) {
        guard self.client === client else { return }
        let endpoint = client.routing?.route
        if epochEndpoint == nil { epochEndpoint = endpoint }
        let moved = endpoint != epochEndpoint
        if connection == .online, !moved {
            if capabilitiesOnForeground { readCapabilities(client) }
            return
        }
        let recovered = connection != .checking || moved
        connection = .online
        guard recovered else {
            if capabilitiesOnForeground { readCapabilities(client) }
            return
        }
        let throughTunnelChanged = (epochEndpoint == .tunnel) != (endpoint == .tunnel)
        epochEndpoint = endpoint
        workspace.connectionEpoch &+= 1
        workspace.archive?.resume(connectionEpoch: workspace.connectionEpoch)
        if workspace.hostIssue != nil || workspace.projects.isEmpty || throughTunnelChanged {
            capabilitiesOnForeground = false
            Task { await refreshProjects() }
        } else if client.routing != nil {
            readCapabilities(client)
        }
    }

    /// Reads capabilities for what the device keeps of them: the routes and remote access.
    func readCapabilities(_ client: APIClient) {
        capabilitiesOnForeground = false
        guard client.routing != nil, let hostID = selectedHost?.id else { return }
        Task { [weak self] in
            let capabilities = try? await client.capabilities()
            guard let self, self.client === client, self.selectedHost?.id == hostID else { return }
            self.learnRoutes(capabilities?.routes, hostID: hostID)
            self.learnRemoteAccess(capabilities?.remoteAccess, hostID: hostID, client: client)
        }
    }

    // MARK: Presence

    /// The chat on screen, as the presence heartbeat reports it (docs/HOST-API.md "Presence and notices"):
    /// the selected tab of an active, unlocked app when it is a chat with its workspace and chat known, for
    /// hosts that list `presence: ["views"]`. The host leaves out notices for it and counts the Mac as in use.
    var presenceView: PresenceView? {
        guard scenePhase == .active, !locked, workspace.capabilities?.supportsPresenceViews == true,
              let tab = workspace.currentTab, tab.kind == .chat else { return nil }
        return PresenceView(projectID: tab.projectID, sessionID: tab.resourceID)
    }

    /// Follows the chat on screen: when it changes while the heartbeat runs, the next heartbeat goes at once.
    /// Every observed input is read whatever the scene phase, which is not observed (its changes start and
    /// stop the heartbeat themselves): `presenceView` stops reading at the first condition that fails.
    func watchPresenceView() {
        _ = withObservationTracking {
            (workspace.currentTab, workspace.locked, workspace.capabilities?.supportsPresenceViews)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.watchPresenceView() }
        }
        presenceViewChanged()
    }

    /// Ends the heartbeat's wait when the chat on screen is not the one it last reported; the next heartbeat
    /// then goes after `presenceCoalescing`, with the chat on screen at that moment.
    private func presenceViewChanged() {
        guard presenceTask != nil, presenceView != presenceSentView else { return }
        presenceWait?.cancel()
    }

    private func startPresenceIfNeeded() {
        guard scenePhase == .active, !locked, let client, presenceTask == nil else { return }
        let pendingStop = presenceStopTask
        presenceTask = Task { [weak self] in
            await pendingStop?.value
            while !Task.isCancelled {
                guard let self else { return }
                // One heartbeat at a time, so a later view never arrives before an earlier one.
                let view = self.presenceView
                self.presenceSentView = view
                do { try await client.setPresence(active: true, view: view) } catch { /* Expiry handles an unreachable host. */ }
                guard await self.waitForNextHeartbeat() else { return }
            }
        }
    }

    /// Waits for the next heartbeat: `presenceInterval`, or `presenceCoalescing` once the chat on screen
    /// differs from the one last reported (also when it changed while that heartbeat was on its way), so a
    /// run of switches is reported once. False when the heartbeat stopped.
    private func waitForNextHeartbeat() async -> Bool {
        if presenceView == presenceSentView {
            let wait = Task { [presenceInterval] in try await Task.sleep(for: presenceInterval) }
            presenceWait = wait
            let result = await withTaskCancellationHandler { await wait.result } onCancel: { wait.cancel() }
            if presenceWait == wait { presenceWait = nil }
            guard !Task.isCancelled else { return false }
            if case .success = result { return true }
        }
        do { try await Task.sleep(for: presenceCoalescing) } catch { return false }
        return true
    }

    private func stopPresence() {
        presenceTask?.cancel()
        presenceTask = nil
        guard let client else { return }
        let previousStop = presenceStopTask
        presenceStopTask = Task {
            await previousStop?.value
            try? await client.setPresence(active: false)
        }
    }

    private func beginAuthenticationIfNeeded() {
        guard scenePhase == .active, lockEnabled, locked, authenticationArmed, authenticationID == nil else { return }
        authenticationArmed = false
        authenticationMessage = nil
        isAuthenticating = true
        let id = UUID()
        let authenticator = authenticatorFactory()
        authenticationID = id
        self.authenticator = authenticator
        authenticationTask = Task { [weak self] in
            let result: Result<Bool, Error>
            do {
                result = .success(try await authenticator.authenticate(reason: "Unlock AgentLand"))
            } catch {
                result = .failure(error)
            }
            guard let self, self.authenticationID == id, self.lockEnabled else { return }
            self.authenticationID = nil
            self.authenticator = nil
            self.authenticationTask = nil
            self.isAuthenticating = false
            switch result {
            case .success(true):
                self.locked = false
                self.authenticationMessage = nil
                self.startPresenceIfNeeded()
                self.updateArchiveSync()
                self.advanceNotice()
            case .success(false):
                self.authenticationMessage = "Authentication did not complete. Leave and return to AgentLand to try again."
            case .failure(let error):
                self.authenticationMessage = Self.authenticationMessage(for: error)
            }
        }
    }

    private func cancelAuthentication() {
        authenticationID = nil
        isAuthenticating = false
        authenticator?.invalidate()
        authenticator = nil
        authenticationTask?.cancel()
        authenticationTask = nil
    }

    private static func authenticationMessage(for error: Error) -> String {
        let error = error as NSError
        let cancellationCodes = [LAError.Code.userCancel, .appCancel, .systemCancel].map(\.rawValue)
        if error.domain == LAError.errorDomain, cancellationCodes.contains(error.code) {
            return "Authentication was canceled. Leave and return to AgentLand to try again."
        }
        return error.localizedDescription
    }
}
