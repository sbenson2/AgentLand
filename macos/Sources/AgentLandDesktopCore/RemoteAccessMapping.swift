import Foundation
import AgentLandCore

/// The router mapping of the Mac endpoint's UDP port while "Reach this Mac from anywhere" is on
/// (docs/HOST-API.md "The Mac app reports", "The Mac switches"): one `PortMapper` for the router of
/// this Mac's network, an attempt when it starts and after a network change or a wake, retries on
/// `RemoteAccessMappingPlan`'s schedule while no mapping is held, and the addresses to report after
/// each attempt, renewal or expiry by the plan's rules. `stop()` deletes the mapping on the router.
///
/// It maps the endpoint's port only: never while the endpoint could not bind it (the app does not
/// start it then), never another port.
public actor RemoteAccessMapping {
    /// What the mapping is doing, for the report and the switch's row.
    public enum State: Equatable, Sendable {
        /// Not running (the switch is off, or the endpoint has no port).
        case idle
        /// An attempt is under way.
        case attempting
        /// The router holds the mapping (`externalAddress` is what it granted).
        case mapped
        /// The last attempt made no mapping, and why.
        case notMapped(Problem)
        /// Renewals failed until the mapping's lease ended; `PortMapper` keeps trying.
        case expired
    }

    public enum Problem: Error, Equatable, Sendable {
        /// No IPv4 default route through a private address: no router to ask.
        case noRouter
        /// How the request failed (`PortMappingError.errorDescription` says it in words).
        case failed(PortMappingError)
    }

    public struct Outcome: Equatable, Sendable {
        public var state: State = .idle
        /// The addresses to report: global unicast `ip:port`, by `RemoteAccessMappingPlan`.
        public var directAddresses: [String] = []
        /// The router's external address and the port it granted, as `ip:port`, whether or not it is
        /// global unicast; nil without a mapping.
        public var externalAddress: String?
        /// When the reported addresses are the last mapping's, kept after an attempt that made none:
        /// the end of that mapping's lease.
        public var keptUntil: Date?
        /// The attempt of this start or network has finished (mapped, refused or timed out). Reports
        /// with `enabled: true` wait for it.
        public var settled = false

        public init() {}
    }

    public typealias Router = RemoteAccessMappingPlan.Router

    public let request: PortMappingRequest
    private let gateway: @Sendable () -> String?
    private let hardwareAddress: @Sendable (String) -> String?
    private let makeMapper: @Sendable (Router) throws -> PortMapper
    private let clock: any NoticeRelayClock
    private let onChange: @Sendable (Outcome, RemoteAccessMappingPlan) -> Void

    private var plan: RemoteAccessMappingPlan
    private var mapper: PortMapper?
    private var mapperGateway: String?
    private var eventsTask: Task<Void, Never>?
    private var attemptTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var generation = 0
    private var running = false
    private var lastRouter: Router?
    public private(set) var outcome = Outcome()

    /// - Parameters:
    ///   - gateway: this Mac's router now (`DefaultGateway.ipv4()`); nil without one.
    ///   - hardwareAddress: the router's link-layer address from the ARP table
    ///     (`DefaultGateway.hardwareAddress(of:)`), read after each attempt.
    ///   - makeMapper: a mapper for a router (its address, and its link-layer address when the ARP table
    ///     has it, which keeps the records of one router apart from another's at the same address; the
    ///     app's records file; a fake router in tests).
    ///   - plan: the plan kept in the app's preferences.
    ///   - onChange: every new outcome, with the plan to keep.
    public init(request: PortMappingRequest,
                gateway: @escaping @Sendable () -> String? = { DefaultGateway.ipv4()?.description },
                hardwareAddress: @escaping @Sendable (String) -> String? = { IPv4Address($0).flatMap(DefaultGateway.hardwareAddress(of:)) },
                makeMapper: @escaping @Sendable (Router) throws -> PortMapper = RemoteAccessMapping.defaultMapper,
                plan: RemoteAccessMappingPlan = RemoteAccessMappingPlan(),
                clock: any NoticeRelayClock = SystemNoticeRelayClock(),
                onChange: @escaping @Sendable (Outcome, RemoteAccessMappingPlan) -> Void = { _, _ in }) {
        self.request = request
        self.gateway = gateway
        self.hardwareAddress = hardwareAddress
        self.makeMapper = makeMapper
        self.plan = plan
        self.clock = clock
        self.onChange = onChange
    }

    /// The app's mapper: the router at its gateway address, with the records in Application Support.
    public static func defaultMapper(router: Router) throws -> PortMapper {
        var configuration = try PortMapper.Configuration(gateway: router.gateway, recordsFile: PortMapper.defaultRecordsFile())
        configuration.routerHardwareAddress = router.hardwareAddress
        return PortMapper(configuration: configuration)
    }

    public var currentPlan: RemoteAccessMappingPlan { plan }

    /// Starts mapping: an attempt now, then renewals or retries until `stop()`.
    public func start() {
        guard !running else { return }
        running = true
        plan.restart()
        attempt(settling: true)
    }

    /// The network changed or the Mac woke: the delays start over. A mapper for another router is
    /// stopped before the new one maps; without a mapping (or on another router) an attempt runs now.
    /// When another router answers at the same gateway address (its link-layer address differs), the
    /// old mapper lets go of its mapping without a delete: the delete would reach the new router, not
    /// the one that holds the mapping. Its record stays, for the next time the Mac is on that router.
    public func networkChanged() async {
        guard running else { return }
        plan.restart()
        let current = gateway()
        let sameRouter: Bool = {
            guard let current, current == mapperGateway else { return false }
            guard let last = lastRouter, let now = hardwareAddress(current) else { return true }
            return last.isSame(as: Router(gateway: current, hardwareAddress: now))
        }()
        if sameRouter, outcome.state == .mapped { return }
        if !sameRouter { await dropMapper(deleting: current != mapperGateway) }
        guard running else { return }
        attempt(settling: true)
    }

    /// Stops renewing and deletes the mapping on the router (after any request in flight). Returns the
    /// mappings whose delete the router did not confirm (they stay recorded for `removeLeftovers`).
    @discardableResult
    public func stop() async -> [PortMappingRequest] {
        running = false
        generation += 1
        retryTask?.cancel()
        retryTask = nil
        attemptTask?.cancel()
        attemptTask = nil
        let unconfirmed = await dropMapper()
        outcome = Outcome()
        onChange(outcome, plan)
        return unconfirmed
    }

    /// The owner turned the switch off: stops, and forgets the last mapping (a new plan).
    @discardableResult
    public func stopAndForget() async -> [PortMappingRequest] {
        plan = RemoteAccessMappingPlan()
        return await stop()
    }

    /// Deletes what an earlier run left on this router (`PortMapper.removeLeftovers()`); the app runs it
    /// at every launch, whether or not the switch is on. Nothing is sent when nothing is recorded.
    @discardableResult
    public func removeLeftovers() async throws -> [PortMappingRequest] {
        guard let current = gateway() else { return [] }
        let leftoverMapper: PortMapper
        if let mapper, mapperGateway == current {
            leftoverMapper = mapper
        } else {
            leftoverMapper = try makeMapper(Router(gateway: current, hardwareAddress: hardwareAddress(current)))
        }
        return try await leftoverMapper.removeLeftovers()
    }

    // MARK: Attempts

    private func attempt(settling: Bool) {
        generation += 1
        let attemptGeneration = generation
        retryTask?.cancel()
        retryTask = nil
        // A retry keeps showing why the last attempt made no mapping; the attempt of a start or a
        // network change shows that it runs, and the report waits for it.
        if settling {
            outcome.settled = false
            if outcome.state != .mapped { outcome.state = .attempting }
            onChange(outcome, plan)
        }
        attemptTask = Task { await self.runAttempt(generation: attemptGeneration) }
    }

    private func runAttempt(generation attemptGeneration: Int) async {
        guard let current = gateway() else {
            finish(generation: attemptGeneration, result: .failure(.noRouter), router: nil)
            return
        }
        let mapper: PortMapper
        do {
            mapper = try await mapperFor(gateway: current)
        } catch {
            finish(generation: attemptGeneration, result: .failure(.failed(error as? PortMappingError ?? .invalidGateway(current))),
                   router: Router(gateway: current, hardwareAddress: nil))
            return
        }
        let result: Result<PortMapping, Problem>
        do {
            result = .success(try await mapper.map(request))
        } catch {
            guard !(error is CancellationError) else { return }
            result = .failure(.failed(error as? PortMappingError ?? .socket(error.localizedDescription)))
        }
        // Sending to the router has resolved it in the ARP table.
        finish(generation: attemptGeneration, result: result, router: Router(gateway: current, hardwareAddress: hardwareAddress(current)))
    }

    private func finish(generation attemptGeneration: Int, result: Result<PortMapping, Problem>, router: Router?) {
        guard attemptGeneration == generation, running else { return }
        attemptTask = nil
        if let router { lastRouter = router }
        switch result {
        case let .success(mapping):
            apply(mapping, router: router ?? Router(gateway: mapperGateway ?? "", hardwareAddress: nil))
        case let .failure(problem):
            let failure: RemoteAccessMappingPlan.Failure
            switch problem {
            case .noRouter: failure = .noAnswer
            case let .failed(error): failure = RemoteAccessMappingPlan.Failure(error)
            }
            let now = clock.now()
            outcome.directAddresses = plan.failed(failure, router: router, now: now)
            outcome.keptUntil = outcome.directAddresses.isEmpty ? nil : plan.lastMapping?.expiresAt
            outcome.externalAddress = nil
            outcome.state = .notMapped(problem)
            outcome.settled = true
            onChange(outcome, plan)
            scheduleRetry()
        }
    }

    /// A mapping the router granted or renewed.
    private func apply(_ mapping: PortMapping, router: Router) {
        let external = mapping.externalAddress.map { "\($0.description):\(mapping.externalPort)" }
        let dialable = external.map { RemoteAccessDirectAddress.isDialable($0) ? [$0] : [] } ?? []
        outcome.directAddresses = plan.mapped(dialable, router: router, lifetime: TimeInterval(mapping.lifetime), now: clock.now())
        outcome.externalAddress = external
        outcome.keptUntil = nil
        outcome.state = .mapped
        outcome.settled = true
        retryTask?.cancel()
        retryTask = nil
        onChange(outcome, plan)
    }

    private func scheduleRetry() {
        retryTask?.cancel()
        guard running, let delay = plan.retryDelay(now: clock.now()) else { return }
        let retryGeneration = generation
        let clock = clock
        retryTask = Task {
            do { try await clock.sleep(for: .milliseconds(Int64(delay * 1000))) } catch { return }
            self.retry(generation: retryGeneration)
        }
    }

    private func retry(generation retryGeneration: Int) {
        guard running, retryGeneration == generation, outcome.state != .mapped else { return }
        attempt(settling: false)
    }

    // MARK: The mapper

    private func mapperFor(gateway current: String) async throws -> PortMapper {
        if let mapper, mapperGateway == current { return mapper }
        // One mapper at a time owns the records: the old one lets go of its mapping first.
        await dropMapper()
        let fresh = try makeMapper(Router(gateway: current, hardwareAddress: hardwareAddress(current)))
        mapper = fresh
        mapperGateway = current
        let events = fresh.events
        eventsTask = Task { [weak self] in
            for await event in events {
                await self?.handle(event, from: fresh)
            }
        }
        return fresh
    }

    /// Stops the mapper: with `deleting`, its mapping is deleted on its router (after any request in
    /// flight); without, it is let go of and stays recorded (`PortMapper.abandon()`).
    @discardableResult
    private func dropMapper(deleting: Bool = true) async -> [PortMappingRequest] {
        guard let old = mapper else { return [] }
        mapper = nil
        mapperGateway = nil
        eventsTask?.cancel()
        eventsTask = nil
        if outcome.state == .mapped { outcome.state = .attempting }
        guard deleting else {
            await old.abandon()
            return []
        }
        return await old.stop()
    }

    private func handle(_ event: PortMappingEvent, from source: PortMapper) {
        guard running, source === mapper else { return }
        switch event {
        case let .mapped(mapping) where mapping.request.mappingKey == request.mappingKey:
            // A renewal (or the attempt's own grant): the lease starts again.
            let router = lastRouter ?? Router(gateway: mapperGateway ?? "", hardwareAddress: nil)
            apply(mapping, router: router)
        case let .expired(expired) where expired.mappingKey == request.mappingKey:
            outcome.directAddresses = plan.expired()
            outcome.externalAddress = nil
            outcome.keptUntil = nil
            outcome.state = .expired
            onChange(outcome, plan)
        default:
            break
        }
    }
}
