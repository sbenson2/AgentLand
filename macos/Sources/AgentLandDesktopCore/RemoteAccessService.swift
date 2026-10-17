import Foundation
import AgentLandCore
import AgentLandIroh
import AgentLandNotifications

/// The host's two local-only remote access routes, through the Mac's local session.
public protocol RemoteAccessHostSession: Sendable {
    /// `GET /v1/remote-access/peers`.
    func peers(after version: String?, wait: TimeInterval?) async throws -> RemoteAccessPeers
    /// `POST /v1/remote-access/endpoint`.
    func report(_ report: RemoteAccessEndpointReport) async throws -> RemoteAccessCapabilities
}

/// The routes over the host's HTTPS listener with the local session (`HostController.sessionClient`).
public struct APIClientRemoteAccessSession: RemoteAccessHostSession {
    public let client: APIClient
    public init(_ client: APIClient) { self.client = client }
    public func peers(after version: String?, wait: TimeInterval?) async throws -> RemoteAccessPeers {
        try await client.remoteAccessPeers(after: version, wait: wait)
    }
    public func report(_ report: RemoteAccessEndpointReport) async throws -> RemoteAccessCapabilities {
        try await client.reportRemoteAccessEndpoint(report)
    }
}

public enum RemoteAccessEndpointError: LocalizedError, Equatable {
    /// Another program holds the endpoint's UDP port.
    case portInUse(UInt16)

    public var errorDescription: String? {
        switch self {
        case let .portInUse(port): "Another program is using UDP port \(port)."
        }
    }
}

/// Remote access on the Mac (docs/HOST-API.md "Remote access (iroh)"). It belongs to
/// `HostController`'s lifecycle, never to a view, and runs from `activate()` (the app's launch) to
/// `shutdown()` (Quit):
/// - "Reach this Mac from anywhere" (`setEnabled`, off by default) runs the Mac endpoint
///   (`IrohMacEndpoint` on UDP 38842), maps that port on the router (`RemoteAccessMapping`) and
///   reports `enabled: true` once the mapping attempt has finished; off reports `enabled: false`,
///   removes the mapping, deletes the address record and closes the endpoint. The endpoint and the
///   mapping follow the switch, not the host: Disconnect and a host restart leave them running (a
///   stream then ends with code 2).
/// - "Use a public relay if a direct connection fails" (`setFallback`, off by default) runs the
///   endpoint with n0's relays until it has a home relay, then with that one relay only, kept in the
///   settings; it picks again when turned off and on, or when the kept relay has been unreachable for
///   10 minutes.
/// - While the host runs with its tunnel socket (`hostStarted`), it keeps the gate on the host's peer
///   list (`RemoteAccessPeerFeed`) and reports after every host start (with the node ID, whether or not
///   the switch is on) and whenever what devices read changes; a report with `enabled: true` whose
///   revision changed is written to the owner's iCloud (`RemoteAccessAddressRecordWriter`).
/// - At launch it deletes the mappings an earlier run left (`removeLeftovers()`), whether or not the
///   switch is on, and while the switch is off any address record it may have left.
/// - The endpoint's key is read from the Keychain once and kept in memory until Quit. Until the Keychain
///   gives it, the endpoint does not start and nothing is mapped; it is read again after
///   `keyRetryDelays`, at once after a network change or a wake, when a switch changes and at a host
///   start. Whichever read gives it, the endpoint then starts at once.
/// - Quit removes the mapping and closes the endpoint without a report, so devices keep their way back.
public actor RemoteAccessService {
    /// The kept relay unreachable this long (`watchHomeRelay` has not listed it): the endpoint picks
    /// again.
    public static let relayPickAgainAfter: TimeInterval = 600
    /// Seconds before the endpoint's key is read again after the Keychain did not give it (the last
    /// repeats). Slower than a bind's: each read can bring back the access prompt the owner denied.
    public static let keyRetryDelays: [TimeInterval] = [600, 3600]

    /// What the app keeps in its preferences.
    public struct Settings: Codable, Equatable, Sendable {
        public var enabled = false
        public var fallback = false
        /// The one n0 relay the fallback uses, once picked.
        public var pinnedRelay: String?
        public var plan = RemoteAccessMappingPlan()
        /// The host whose address record this Mac may have written and not yet deleted.
        public var recordHostID: String?

        public init() {}
    }

    public struct Status: Equatable, Sendable {
        public enum Endpoint: Equatable, Sendable {
            case off
            case starting
            case running
            /// Another program holds UDP 38842: no mapping, and a report without addresses or relay.
            case portInUse
            case failed(String)
        }

        public enum Relay: Equatable, Sendable {
            case off
            /// With n0's relays until the endpoint has a home relay.
            case picking
            case using(String)
            /// The kept relay has not been reachable since this date.
            case unreachable(String, since: Date)
        }

        public var enabled = false
        public var fallback = false
        /// The host's connection mode carries the tunnel (trusted HTTPS). While it does not (local
        /// development HTTP), the switch keeps its setting but nothing runs: no endpoint, no mapping.
        public var tunnelServed = true
        public var endpoint: Endpoint = .off
        public var mapping = RemoteAccessMapping.Outcome()
        public var relay: Relay = .off
        public var nodeID: IrohNodeID?
        /// The host's tunnel socket is served and its local session is up.
        public var hostSession = false
        /// The host's answer to the last report of this session.
        public var reported: RemoteAccessCapabilities?
        public var reportProblem: String?
        /// Whether this Mac may write the address record (CloudKit available).
        public var recordAvailable = false
        public var record = RemoteAccessAddressRecordWriter.Status()

        public init() {}
    }

    public struct Dependencies: Sendable {
        public var port: UInt16
        public var socketPath: String
        public var keyStore: any RemoteAccessKeyStoring
        public var bindEndpoint: RemoteAccessEndpointBinder
        public var makeMapping: @Sendable (RemoteAccessMappingPlan,
                                           @escaping @Sendable (RemoteAccessMapping.Outcome, RemoteAccessMappingPlan) -> Void) -> RemoteAccessMapping
        public var recordDatabase: (any RemoteAccessAddressDatabase)?
        public var clock: any NoticeRelayClock
        /// How long the kept relay may be unreachable before the endpoint picks again.
        public var relayUnreachableLimit: TimeInterval = RemoteAccessService.relayPickAgainAfter
        /// Seconds before each new bind after one that failed (the last repeats).
        public var bindRetryDelays: [TimeInterval] = RemoteAccessMappingPlan.retryDelays
        /// Seconds before each new read of the endpoint's key after one the Keychain refused (the last
        /// repeats).
        public var keyRetryDelays: [TimeInterval] = RemoteAccessService.keyRetryDelays

        public init(port: UInt16 = RemoteAccessPorts.endpointUDP, socketPath: String,
                    keyStore: any RemoteAccessKeyStoring = KeychainRemoteAccessKeyStore(),
                    bindEndpoint: @escaping RemoteAccessEndpointBinder = { try await IrohMacEndpoint.bindReportingPortInUse($0, events: $1) },
                    makeMapping: (@Sendable (RemoteAccessMappingPlan,
                                            @escaping @Sendable (RemoteAccessMapping.Outcome, RemoteAccessMappingPlan) -> Void) -> RemoteAccessMapping)? = nil,
                    recordDatabase: (any RemoteAccessAddressDatabase)?,
                    clock: any NoticeRelayClock = SystemNoticeRelayClock()) {
            self.port = port
            self.socketPath = socketPath
            self.keyStore = keyStore
            self.bindEndpoint = bindEndpoint
            let request = try! RemoteAccessPorts.endpointMapping(port: port)
            self.makeMapping = makeMapping ?? { plan, onChange in
                RemoteAccessMapping(request: request, plan: plan, clock: clock, onChange: onChange)
            }
            self.recordDatabase = recordDatabase
            self.clock = clock
        }
    }

    private enum Event: Sendable {
        case mapping(RemoteAccessMapping.Outcome, RemoteAccessMappingPlan)
        case endpoint(RemoteAccessEndpointEvent, generation: Int)
        case record(RemoteAccessAddressRecordWriter.Status)
    }

    private let dependencies: Dependencies
    private let save: @Sendable (Settings) -> Void
    private let onStatus: @Sendable (Status) -> Void
    private let mapping: RemoteAccessMapping
    private let writer: RemoteAccessAddressRecordWriter?
    private let events: AsyncStream<Event>
    private let eventSink: AsyncStream<Event>.Continuation

    public private(set) var settings: Settings
    public private(set) var status = Status()
    private var eventTask: Task<Void, Never>?
    private var operations: Task<Void, Never>?
    private var activated = false
    private var shutDown = false

    /// The endpoint's key and its node ID, read from the Keychain the first time it gives them and kept in
    /// memory until Quit: an endpoint that starts again (the fallback, a relay picked) and a host start
    /// never ask the Keychain again (an ad-hoc build keeps the key in the login Keychain, which can ask
    /// the owner for access at every read).
    private var key: (secret: Data, nodeID: IrohNodeID)?
    private var keyFailures = 0
    private var endpoint: (any RemoteAccessEndpointRunning)?
    private var endpointGeneration = 0
    private var bindTask: Task<Void, Never>?
    private var bindRetryTask: Task<Void, Never>?
    private var bindFailures = 0
    private var mappingRunning = false
    private var relayWatchdog: Task<Void, Never>?

    private var session: (id: UUID, value: any RemoteAccessHostSession, hostID: String?)?
    private var feedTask: Task<Void, Never>?
    private var feedKey: (UUID, ObjectIdentifier)?
    private var lastSent: RemoteAccessEndpointReport?
    private var reportTask: Task<Void, Never>?
    private var reportRetryTask: Task<Void, Never>?
    private var reportFailures = 0

    public init(settings: Settings, dependencies: Dependencies,
                save: @escaping @Sendable (Settings) -> Void = { _ in },
                onStatus: @escaping @Sendable (Status) -> Void = { _ in }) {
        self.settings = settings
        self.dependencies = dependencies
        self.save = save
        self.onStatus = onStatus
        let (events, sink) = AsyncStream<Event>.makeStream()
        self.events = events
        eventSink = sink
        mapping = dependencies.makeMapping(settings.plan) { outcome, plan in sink.yield(.mapping(outcome, plan)) }
        writer = dependencies.recordDatabase.map { database in
            RemoteAccessAddressRecordWriter(database: database, clock: dependencies.clock) { sink.yield(.record($0)) }
        }
        status.enabled = settings.enabled
        status.fallback = settings.fallback
        status.recordAvailable = writer != nil
    }

    // MARK: The app's calls

    /// At launch: deletes what an earlier run left on the router, deletes a record left while the
    /// switch is off, and starts the endpoint when the switch is on.
    public func activate() async {
        await enqueue { await $0.activateNow() }
    }

    /// "Reach this Mac from anywhere".
    public func setEnabled(_ on: Bool) async {
        await enqueue { await $0.applyEnabled(on) }
    }

    /// "Use a public relay if a direct connection fails".
    public func setFallback(_ on: Bool) async {
        await enqueue { await $0.applyFallback(on) }
    }

    /// Whether the host's connection mode carries the tunnel: trusted HTTPS does, local development
    /// HTTP does not (the host has no tunnel socket there). While it does not, the endpoint is closed
    /// and the mapping deleted, whatever the switch says; the switch keeps its setting.
    public func setTunnelServed(_ served: Bool) async {
        await enqueue { await $0.applyTunnelServed(served) }
    }

    /// The host started with its tunnel socket: `session` is its new local session, `hostID` the
    /// record name of its certificate (`NoticeHostID`).
    public func hostStarted(_ session: any RemoteAccessHostSession, hostID: String?) async {
        await enqueue { await $0.applyHostStarted(session, hostID: hostID) }
    }

    /// The host stopped (Disconnect, a restart, Quit).
    public func hostStopped() async {
        await enqueue { await $0.applyHostStopped() }
    }

    /// The network changed or the Mac woke: map again at once (and bind again, when the port was in
    /// use).
    public func networkChanged() async {
        await enqueue { await $0.applyNetworkChanged() }
    }

    /// Quit: removes the mapping and closes the endpoint, without a report.
    public func shutdown() async {
        await enqueue { await $0.shutdownNow() }
    }

    /// Serializes the operations above: each starts once the one before has ended.
    private func enqueue(_ operation: @escaping @Sendable (RemoteAccessService) async -> Void) async {
        startEventLoop()
        let previous = operations
        let task = Task { await previous?.value; await operation(self) }
        operations = task
        await task.value
    }

    private func startEventLoop() {
        guard eventTask == nil else { return }
        let events = events
        eventTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                await self.handle(event)
            }
        }
    }

    // MARK: Operations

    private func activateNow() async {
        guard !activated, !shutDown else { return }
        activated = true
        // Whether or not the switch is on: what a crash or force quit left on this router goes.
        _ = try? await mapping.removeLeftovers()
        if !settings.enabled, let hostID = settings.recordHostID {
            await writer?.delete(hostID: hostID)
        }
        // The endpoint's start reads the key; otherwise it is read here for the node ID the reports carry.
        if running {
            await startEndpoint()
        } else {
            await readKeyForReports()
        }
        publish()
    }

    /// The endpoint's key, from memory once the Keychain has given it.
    private func readKey() throws -> (secret: Data, nodeID: IrohNodeID) {
        if let key { return key }
        let secret = try dependencies.keyStore.secretKey()
        let read = (secret: secret, nodeID: try IrohNodeID(secretKey: secret))
        key = read
        keyFailures = 0
        return read
    }

    /// Reads the key for the node ID the reports carry, outside the endpoint's start (a launch with the
    /// switch off, a host start), until the Keychain has given it. When it gives it while the switch is on
    /// and no endpoint runs (the start could not read it: the owner denied the prompt and then allowed the
    /// one this read brought up), the endpoint starts now instead of at the key's next timed read, 10
    /// minutes or an hour away.
    private func readKeyForReports() async {
        guard key == nil, let read = try? readKey() else { return }
        status.nodeID = read.nodeID
        if running, activated, endpoint == nil { await startEndpoint() }
    }

    /// The switch is on and the host's connection mode carries the tunnel: the endpoint and the mapping
    /// run.
    private var running: Bool { settings.enabled && status.tunnelServed }

    private func applyEnabled(_ on: Bool) async {
        guard !shutDown, on != settings.enabled else { return }
        settings.enabled = on
        status.enabled = on
        persist()
        if on {
            guard activated, running else { publish(); return }
            await startEndpoint()
            publish()
            return
        }
        // Off: report it first, then remove the mapping, delete the record and close the endpoint.
        reconcileReport()
        await stopRunning()
        if let hostID = settings.recordHostID ?? session?.hostID {
            await writer?.delete(hostID: hostID)
        }
        publish()
    }

    /// Removes the mapping (forgetting the last one) and closes the endpoint: the switch went off, or
    /// the host's connection mode no longer carries the tunnel.
    private func stopRunning() async {
        endpointGeneration += 1
        bindTask?.cancel()
        bindRetryTask?.cancel()
        relayWatchdog?.cancel()
        relayWatchdog = nil
        bindFailures = 0
        keyFailures = 0
        status.mapping = RemoteAccessMapping.Outcome()
        if mappingRunning {
            mappingRunning = false
            await mapping.stopAndForget()
        } else {
            settings.plan = RemoteAccessMappingPlan()
            persist()
        }
        await closeEndpoint()
        status.relay = .off
    }

    private func applyTunnelServed(_ served: Bool) async {
        guard !shutDown, served != status.tunnelServed else { return }
        status.tunnelServed = served
        if served {
            if activated, running { await startEndpoint() }
        } else if settings.enabled {
            // No report: the switch is still on, and devices keep the last one until the tunnel is
            // served again (then the endpoint reports as after any start).
            await stopRunning()
        }
        reconcileReport()
        publish()
    }

    private func applyFallback(_ on: Bool) async {
        guard !shutDown, on != settings.fallback else { return }
        settings.fallback = on
        settings.pinnedRelay = nil
        status.fallback = on
        persist()
        if running, activated {
            await restartEndpoint()
        } else {
            status.relay = .off
        }
        reconcileReport()
        publish()
    }

    private func applyHostStarted(_ value: any RemoteAccessHostSession, hostID: String?) async {
        guard !shutDown else { return }
        cancelReports()
        session = (UUID(), value, hostID)
        status.hostSession = true
        status.reported = nil
        status.reportProblem = nil
        // Before the reports: an endpoint this read starts reports once its mapping attempt has finished.
        await readKeyForReports()
        reconcileFeed()
        reconcileReport()
        publish()
    }

    private func applyHostStopped() async {
        cancelReports()
        session = nil
        status.hostSession = false
        status.reported = nil
        reconcileFeed()
        publish()
    }

    private func applyNetworkChanged() async {
        guard !shutDown, running, activated else { return }
        switch status.endpoint {
        case .portInUse, .failed:
            bindFailures = 0
            keyFailures = 0
            await startEndpoint()
        default:
            if mappingRunning { await mapping.networkChanged() }
        }
        publish()
    }

    private func shutdownNow() async {
        guard !shutDown else { return }
        shutDown = true
        endpointGeneration += 1
        bindTask?.cancel()
        bindRetryTask?.cancel()
        relayWatchdog?.cancel()
        cancelReports()
        session = nil
        reconcileFeed()
        if mappingRunning {
            mappingRunning = false
            await mapping.stop()
        }
        await closeEndpoint()
        await writer?.stop()
        eventSink.finish()
    }

    // MARK: The endpoint

    /// Binds the endpoint with the relay the settings choose (the result arrives in `bound`).
    private func startEndpoint() async {
        guard running, activated, !shutDown else { return }
        endpointGeneration += 1
        let generation = endpointGeneration
        bindTask?.cancel()
        bindRetryTask?.cancel()
        if !mappingRunning { status.mapping = RemoteAccessMapping.Outcome() }
        status.endpoint = .starting
        let secretKey: Data
        do {
            let key = try readKey()
            secretKey = key.secret
            status.nodeID = key.nodeID
        } catch {
            // Only before the Keychain first gave the key, so no endpoint ran and nothing is mapped. As a
            // bind that failed, but read again on a slower schedule: each read can bring back the access
            // prompt the owner denied.
            status.endpoint = .failed(Self.describe(error))
            await releaseMapping()
            scheduleStartRetry(delays: dependencies.keyRetryDelays, failures: &keyFailures)
            reconcileFeed()
            reconcileReport()
            publish()
            return
        }
        let relay: RemoteAccessRelayChoice = !settings.fallback ? .none : settings.pinnedRelay.map { .pinned($0) } ?? .pick
        switch relay {
        case .none: status.relay = .off
        case .pick: status.relay = .picking
        case let .pinned(url): status.relay = .using(url)
        }
        let configuration = RemoteAccessEndpointConfiguration(secretKey: secretKey, port: dependencies.port, relay: relay,
                                                              socketPath: dependencies.socketPath)
        let bind = dependencies.bindEndpoint
        let sink = eventSink
        bindTask = Task {
            let result: Result<any RemoteAccessEndpointRunning, any Error>
            do {
                result = .success(try await bind(configuration) { sink.yield(.endpoint($0, generation: generation)) })
            } catch {
                result = .failure(error)
            }
            await self.bound(result, generation: generation)
        }
        publish()
    }

    private func bound(_ result: Result<any RemoteAccessEndpointRunning, any Error>, generation: Int) async {
        guard generation == endpointGeneration, running, !shutDown else {
            if case let .success(stale) = result { await stale.close() }
            return
        }
        bindTask = nil
        switch result {
        case let .success(running):
            endpoint = running
            bindFailures = 0
            status.endpoint = .running
            status.nodeID = running.nodeID
            await running.setExternalAddresses(status.mapping.directAddresses)
            if !mappingRunning {
                mappingRunning = true
                await mapping.start()
            }
        case let .failure(error):
            if let failure = error as? RemoteAccessEndpointError, case .portInUse = failure {
                status.endpoint = .portInUse
            } else {
                status.endpoint = .failed(Self.describe(error))
            }
            await releaseMapping()
            scheduleStartRetry(delays: dependencies.bindRetryDelays, failures: &bindFailures)
        }
        reconcileFeed()
        reconcileReport()
        publish()
    }

    /// Never map a port this endpoint does not hold: it would forward to another program.
    private func releaseMapping() async {
        guard mappingRunning else { return }
        mappingRunning = false
        await mapping.stop()
        status.mapping = RemoteAccessMapping.Outcome()
    }

    /// Starts the endpoint again after the next of `delays` (the last repeats), `failures` counting the
    /// starts that failed so far.
    private func scheduleStartRetry(delays: [TimeInterval], failures: inout Int) {
        guard !delays.isEmpty else { return }
        let delay = delays[min(failures, delays.count - 1)]
        failures += 1
        let clock = dependencies.clock
        let generation = endpointGeneration
        bindRetryTask = Task {
            do { try await clock.sleep(for: .milliseconds(Int64(delay * 1000))) } catch { return }
            await self.enqueue { await $0.retryStart(generation: generation) }
        }
    }

    private func retryStart(generation: Int) async {
        guard generation == endpointGeneration, endpoint == nil, running else { return }
        await startEndpoint()
    }

    /// Closes the endpoint and starts it again with the relay the settings choose now; the mapping
    /// holds the same port meanwhile.
    private func restartEndpoint() async {
        await closeEndpoint()
        await startEndpoint()
    }

    private func closeEndpoint() async {
        endpointGeneration += 1
        bindTask?.cancel()
        bindTask = nil
        let old = endpoint
        endpoint = nil
        status.endpoint = .off
        reconcileFeed()
        await old?.close()
    }

    private func endpointEvent(_ event: RemoteAccessEndpointEvent, generation: Int) async {
        guard generation == endpointGeneration, running, settings.fallback, !shutDown else { return }
        switch event {
        case let .homeRelays(urls):
            guard let pinned = settings.pinnedRelay else {
                // Picking: the first home relay becomes the one relay from now on.
                guard let picked = urls.first(where: RemoteAccessCapabilities.isRelayURL) else { return }
                settings.pinnedRelay = picked
                persist()
                await enqueueDetached { await $0.restartIfPinned(picked) }
                return
            }
            if urls.contains(pinned) {
                relayWatchdog?.cancel()
                relayWatchdog = nil
                status.relay = .using(pinned)
            } else if relayWatchdog == nil {
                let since = dependencies.clock.now()
                status.relay = .unreachable(pinned, since: since)
                let clock = dependencies.clock
                let limit = dependencies.relayUnreachableLimit
                relayWatchdog = Task {
                    do { try await clock.sleep(for: .milliseconds(Int64(limit * 1000))) } catch { return }
                    await self.enqueue { await $0.relayUnreachable(pinned, generation: generation) }
                }
            }
            publish()
        }
    }

    /// Runs an operation after the current one without waiting for it (from event handlers, which the
    /// current operation may itself be waiting for).
    private func enqueueDetached(_ operation: @escaping @Sendable (RemoteAccessService) async -> Void) async {
        Task { await self.enqueue(operation) }
    }

    private func restartIfPinned(_ picked: String) async {
        guard running, settings.fallback, settings.pinnedRelay == picked, !shutDown else { return }
        await restartEndpoint()
        reconcileReport()
        publish()
    }

    private func relayUnreachable(_ pinned: String, generation: Int) async {
        relayWatchdog = nil
        guard generation == endpointGeneration, running, settings.fallback, settings.pinnedRelay == pinned else { return }
        settings.pinnedRelay = nil
        persist()
        await restartEndpoint()
        reconcileReport()
        publish()
    }

    // MARK: Events

    private func handle(_ event: Event) async {
        switch event {
        case let .mapping(outcome, plan):
            settings.plan = plan
            persist()
            guard mappingRunning || outcome.state == .idle else { return }
            status.mapping = outcome
            await endpoint?.setExternalAddresses(outcome.directAddresses)
            reconcileReport()
            publish()
        case let .endpoint(event, generation):
            await endpointEvent(event, generation: generation)
        case let .record(recordStatus):
            status.record = recordStatus
            if case let .delete(hostID)? = recordStatus.done, !settings.enabled, settings.recordHostID == hostID {
                settings.recordHostID = nil
                persist()
            }
            publish()
        }
    }

    // MARK: Peers

    /// One peer feed per endpoint and host session: a new endpoint (whose gate has no list) or a new
    /// session starts it again, so its first request is answered at once.
    private func reconcileFeed() {
        let key: (UUID, ObjectIdentifier)? = session.flatMap { session in endpoint.map { (session.id, ObjectIdentifier($0)) } }
        if let key, let feedKey, key == feedKey { return }
        feedTask?.cancel()
        feedTask = nil
        feedKey = key
        guard let session, let endpoint else { return }
        let host = session.value
        let clock = dependencies.clock
        feedTask = Task {
            await RemoteAccessPeerFeed.run(fetch: { try await host.peers(after: $0, wait: $1) },
                                           apply: { await endpoint.setAllowed($0.allowedKeys) }, clock: clock)
        }
    }

    // MARK: Reports

    /// The report devices should see now; nil while it must wait (the endpoint is starting, or the
    /// mapping attempt of this start or network has not finished).
    func desiredReport() -> RemoteAccessEndpointReport? {
        guard settings.enabled else { return .off(nodeID: status.nodeID) }
        guard let nodeID = status.nodeID else { return nil }
        switch status.endpoint {
        case .portInUse, .failed:
            return .on(nodeID: nodeID, udpPort: dependencies.port)
        case .running:
            guard status.mapping.settled else { return nil }
            return .on(nodeID: nodeID, udpPort: dependencies.port, directAddresses: status.mapping.directAddresses,
                       fallbackRelay: settings.fallback, relayURL: settings.fallback ? settings.pinnedRelay : nil)
        case .off, .starting:
            return nil
        }
    }

    private func reconcileReport() {
        guard let session, !shutDown, reportTask == nil else { return }
        guard let report = desiredReport(), report != lastSent else { return }
        reportRetryTask?.cancel()
        reportRetryTask = nil
        let sessionID = session.id
        let host = session.value
        reportTask = Task {
            do {
                let answer = try await host.report(report)
                await self.reported(report, answer: answer, sessionID: sessionID)
            } catch {
                self.reportFailed(error, sessionID: sessionID)
            }
        }
    }

    private func reported(_ report: RemoteAccessEndpointReport, answer: RemoteAccessCapabilities, sessionID: UUID) async {
        guard let session, session.id == sessionID else { return }
        reportTask = nil
        lastSent = report
        reportFailures = 0
        status.reported = answer
        status.reportProblem = nil
        // The address record follows reports with the switch on, never one that is off by now.
        if report.enabled, settings.enabled, let writer, let hostID = session.hostID,
           let contents = RemoteAccessAddressRecordContents(hostID: hostID, answer: answer) {
            if settings.recordHostID != hostID {
                settings.recordHostID = hostID
                persist()
            }
            await writer.write(contents)
        }
        reconcileReport()
        publish()
    }

    private func reportFailed(_ error: any Error, sessionID: UUID) {
        guard let session, session.id == sessionID else { return }
        reportTask = nil
        reportFailures += 1
        status.reportProblem = Self.describe(error)
        publish()
        // A host without the tunnel socket does not take reports; another start may.
        if case let .server(code, _)? = error as? ClientError, code == "remote_access_unavailable" { return }
        let delay = min(pow(2, Double(min(reportFailures - 1, 5))), 30)
        let clock = dependencies.clock
        reportRetryTask = Task {
            do { try await clock.sleep(for: .milliseconds(Int64(delay * 1000))) } catch { return }
            self.retryReport(sessionID: sessionID)
        }
    }

    private func retryReport(sessionID: UUID) {
        guard session?.id == sessionID else { return }
        reportRetryTask = nil
        reconcileReport()
    }

    private func cancelReports() {
        reportTask?.cancel()
        reportTask = nil
        reportRetryTask?.cancel()
        reportRetryTask = nil
        lastSent = nil
        reportFailures = 0
    }

    // MARK: Status

    private func publish() { onStatus(status) }
    private func persist() { save(settings) }

    static func describe(_ error: any Error) -> String {
        redact((error as? LocalizedError)?.errorDescription ?? error.localizedDescription, limit: 300)
    }
}

extension IrohMacEndpoint {
    /// `bind`, with a port another program holds as `RemoteAccessEndpointError.portInUse`.
    public static func bindReportingPortInUse(_ configuration: RemoteAccessEndpointConfiguration,
                                              events: @escaping @Sendable (RemoteAccessEndpointEvent) -> Void) async throws -> any RemoteAccessEndpointRunning {
        do {
            return try await bind(configuration, events: events)
        } catch let error as IrohError where error.kind() == .bind {
            throw RemoteAccessEndpointError.portInUse(configuration.port)
        }
    }
}
