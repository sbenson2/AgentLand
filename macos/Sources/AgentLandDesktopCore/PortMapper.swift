import Foundation
import Darwin

/// A mapping the router granted.
public struct PortMapping: Sendable, Equatable {
    public let request: PortMappingRequest
    /// The external port the router granted; it can differ from the one asked for.
    public let externalPort: UInt16
    /// The router's external address, when it said (PCP always does; NAT-PMP after an address query).
    public let externalAddress: IPv4Address?
    /// Seconds the router keeps the mapping without a renewal.
    public let lifetime: UInt32
    public let method: PortMapper.Method
}

public enum PortMappingEvent: Sendable, Equatable {
    /// A mapping was made or renewed.
    case mapped(PortMapping)
    /// A renewal or a mapping made again was granted another external port.
    case externalPortChanged(PortMappingRequest, from: UInt16, to: UInt16)
    /// The router's epoch went back: it restarted and lost its mappings, which are being made again.
    case gatewayRestarted
    case renewalFailed(PortMappingRequest, PortMappingError)
    /// Renewals kept failing until the router's lifetime ran out; they are still retried.
    case expired(PortMappingRequest)
    /// The router confirmed the delete (lifetime 0).
    case removed(PortMappingRequest)
    /// The router did not confirm the delete, so the mapping may last until `expiresAt`. Its record
    /// is kept, and `removeLeftovers()` deletes it later.
    case removalUnconfirmed(PortMappingRequest, expiresAt: Date)
}

/// Asks the router for port mappings with PCP (RFC 6887), or NAT-PMP (RFC 6886) when the router
/// only speaks that, and keeps them: short lifetimes renewed at half-life, the router's epoch
/// checked so a restart (which loses every mapping) is noticed and the mappings are made again,
/// and every mapping deleted with lifetime 0 on `unmap` and `stop`, so none stays behind.
///
/// Every mapping is recorded in `Configuration.recordsFile` (0600, in a 0700 folder) from before
/// each request that makes or renews it is sent until the router confirms its delete or its
/// lifetime ends, with PCP's mapping nonce: a PCP router accepts a delete or renewal only with the
/// nonce the mapping was made with (RFC 6887 §11.3). So a run that ends without deleting (a crash,
/// a force quit, a delete the router never answered) leaves what the next run needs:
/// `removeLeftovers()` deletes those mappings, and `map` takes one over with its saved nonce.
/// `.removed` means the router confirmed a delete; otherwise the event is `.removalUnconfirmed`,
/// and `stop`/`unmap` say so. `stop` and `unmap` wait for requests already in flight, so a renewal
/// cannot make a mapping again after they return.
///
/// A mapping is known by its transport and internal port, as the router knows it; the external
/// port is only asked for, so a mapping granted another one is still the same mapping.
///
/// One mapper at a time owns the records: from its first `map` or `removeLeftovers` until it holds
/// nothing (after `stop`, or the last `unmap`), it holds an exclusive lock (flock) on
/// `port-mappings.lock` beside the records file and is the only one that reads them for decisions
/// or writes them. Another mapper — another copy of AgentLand, or in this app a new mapper made
/// after a network change while the old one is still stopping — gets `.ownedElsewhere`, sends
/// nothing and changes no record, so it never deletes or takes over mappings a live mapper keeps.
/// The next owner reads the file again, so what an earlier owner recorded (for any router) stays.
///
/// The router's address is always given explicitly (`DefaultGateway.ipv4()` finds the real one);
/// tests point it at a fake router on loopback. Requests go from a UDP socket connected to the
/// router, so the kernel drops datagrams from anywhere else.
public actor PortMapper {
    public enum Method: String, Sendable, Equatable, Codable { case pcp, natPMP }

    public struct Configuration: Sendable {
        public let gateway: IPv4Address
        /// The router's link-layer (MAC) address when known (`DefaultGateway.hardwareAddress(of:)`).
        /// Records are kept per router: another router at the same gateway address (a replaced router,
        /// another network with the same default) never reads, takes over, overwrites or deletes the
        /// records of this one's mappings, and a record whose router is not known matches any router
        /// at its gateway address.
        public var routerHardwareAddress: String?
        /// Where the mappings in progress are recorded; nil keeps no record (then a crash can leave a
        /// mapping that only its lifetime removes). The app uses `PortMapper.defaultRecordsFile()`.
        /// Its lock is the file beside it with the extension `lock`.
        public let recordsFile: URL?
        public var serverPort: UInt16 = 5351
        /// Asked for on every mapping and renewal; the router may grant less.
        public var requestedLifetime: UInt32 = 7200
        /// How long each transmission waits for an answer before the next one (RFC 6886 starts at 250 ms and doubles).
        public var attemptTimeouts: [TimeInterval] = [0.25, 0.5, 1, 2]
        /// Deletes wait less, so Quit is never held up long.
        public var releaseTimeouts: [TimeInterval] = [0.25, 0.5]
        /// How often the router's epoch is read between renewals, to notice a restart.
        public var epochCheckInterval: TimeInterval = 300
        /// How soon a failed renewal is tried again.
        public var renewalRetryInterval: TimeInterval = 60

        /// Only a loopback or private (RFC 1918) address: the router of this Mac's own network.
        public init(gateway: String, recordsFile: URL?) throws {
            guard let address = IPv4Address(gateway), address.isLoopback || address.isPrivate else {
                throw PortMappingError.invalidGateway(gateway)
            }
            self.gateway = address
            self.recordsFile = recordsFile
        }
    }

    /// `~/Library/Application Support/AgentLand/RemoteAccess/port-mappings.json`.
    public static func defaultRecordsFile() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentLand/RemoteAccess/port-mappings.json")
    }

    private struct Held {
        let request: PortMappingRequest
        /// PCP's mapping nonce, kept for renewals and the delete.
        let nonce: [UInt8]
        /// Tells this hold from a later one of the same request.
        let token = UUID()
        var mapping: PortMapping?
        var expiresAt: TimeInterval = 0
        var dueAt: TimeInterval = .infinity

        init(request: PortMappingRequest, nonce: [UInt8], mapping: PortMapping? = nil) {
            self.request = request
            self.nonce = nonce
            self.mapping = mapping
        }
    }

    public nonisolated let events: AsyncStream<PortMappingEvent>
    private let continuation: AsyncStream<PortMappingEvent>.Continuation
    private let configuration: Configuration
    private let exchange: GatewayExchange
    private var held: [PortMappingRequest: Held] = [:]
    private var records: PortMappingRecords
    public private(set) var method: Method?
    private var epoch = EpochTracker()
    private var nextEpochCheck: TimeInterval = .infinity
    private var lastExternalAddress: IPv4Address?
    private var loop: Task<Void, Never>?
    private var runningDue = false
    private var stopping = false
    private var inFlight = 0
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    /// The descriptor holding the records' lock, or -1.
    private var lockDescriptor: Int32 = -1

    public init(configuration: Configuration) {
        self.configuration = configuration
        exchange = GatewayExchange(gateway: configuration.gateway, port: configuration.serverPort)
        // Read again when the lock is taken; with a file, nothing is decided from this copy before.
        records = PortMappingRecords(url: configuration.recordsFile)
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(64))
    }

    deinit {
        loop?.cancel()
        continuation.finish()
        if lockDescriptor >= 0 { Darwin.close(lockDescriptor) }
    }

    /// The records' lock: `port-mappings.lock` beside `port-mappings.json`.
    public nonisolated var lockFile: URL? {
        configuration.recordsFile.map { $0.deletingPathExtension().appendingPathExtension("lock") }
    }

    public var mappings: [PortMapping] {
        held.values.compactMap(\.mapping).sorted { ($0.request.transport.rawValue, $0.request.internalPort) < ($1.request.transport.rawValue, $1.request.internalPort) }
    }

    /// The mappings recorded as possibly present on this router and not held by this mapper: what an
    /// earlier run left, or deletes the router did not confirm. Empty while another mapper owns the
    /// records: what they list are that mapper's.
    public var leftovers: [PortMappingRequest] {
        guard (try? acquireOwnership()) != nil else { return [] }
        defer { releaseOwnershipIfIdle() }
        let heldKeys = heldKeys
        return records.entries(router: router, now: Date())
            .filter { $0.key.map { !heldKeys.contains($0) } ?? false }.compactMap(\.request)
    }

    /// Makes the mapping and keeps it renewed until `unmap` or `stop`. A mapping an earlier run left
    /// on this router is taken over with its saved nonce. Throws `.ownedElsewhere`, sending nothing,
    /// while another mapper owns the records.
    public func map(_ request: PortMappingRequest) async throws -> PortMapping {
        guard !stopping else { throw CancellationError() }
        if let existing = held[request]?.mapping { return existing }
        // The router knows one mapping per transport and internal port.
        if held.keys.contains(where: { $0 != request && $0.mappingKey == request.mappingKey }) {
            throw PortMappingError.invalidRequest("\(request) is already mapped with another external port.")
        }
        beginOperation()
        defer { endOperation() }
        try acquireOwnership()
        let saved = records.entry(router: router, key: request.mappingKey, now: Date())
        let nonce: [UInt8]
        if let savedNonce = saved?.nonceBytes {
            nonce = savedNonce
        } else {
            var fresh = [UInt8](repeating: 0, count: 12)
            guard SecRandomCopyBytes(kSecRandomDefault, fresh.count, &fresh) == errSecSuccess else {
                throw PortMappingError.socket("no random nonce")
            }
            nonce = fresh
        }
        // Recorded before the request goes out: the router may make the mapping even if its answer never arrives.
        try record(request, nonce: nonce, method: saved?.method.flatMap(Method.init(rawValue:)),
                   externalPort: saved?.externalPort ?? request.externalPort, lifetime: configuration.requestedLifetime)
        let entry = Held(request: request, nonce: nonce)
        held[request] = entry
        do {
            let mapping = try await send(entry, lifetime: configuration.requestedLifetime,
                                         suggestedPort: request.externalPort, suggestedAddress: nil)
            guard held[request]?.token == entry.token else {
                // Unmapped while the router answered: take it back.
                await release(Held(request: request, nonce: nonce, mapping: mapping))
                throw CancellationError()
            }
            accept(mapping)
            // Stopping: `stop` deletes it with the others once this returns.
            if stopping { throw CancellationError() }
            if !nextEpochCheck.isFinite { nextEpochCheck = Self.now() + configuration.epochCheckInterval }
            reschedule()
            return mapping
        } catch {
            if held[request]?.token == entry.token, held[request]?.mapping == nil { held[request] = nil }
            // An answer that refuses made nothing on the router; without an answer it may have.
            if saved == nil, held[request] == nil, Self.routerAnswered(error) { forget(request) }
            throw error
        }
    }

    /// Deletes one mapping on the router and stops renewing it, after any request for it already in
    /// flight. False when the router did not confirm the delete (the mapping stays recorded).
    @discardableResult
    public func unmap(_ request: PortMappingRequest) async -> Bool {
        await drained()
        guard let entry = held.removeValue(forKey: request) else { return true }
        // The records stay this mapper's until the delete is settled.
        beginOperation()
        defer { endOperation() }
        if held.isEmpty { nextEpochCheck = .infinity }
        reschedule()
        return entry.mapping == nil ? true : await release(entry)
    }

    /// Stops renewing, waits for requests already in flight, and deletes every mapping on the router
    /// (lifetime 0). Each delete waits at most the release timeouts, so Quit is not held up by a
    /// router that went away. Returns the mappings whose delete the router did not confirm. The
    /// records' lock is released once it returns.
    @discardableResult
    public func stop() async -> [PortMappingRequest] {
        stopping = true
        loop?.cancel()
        loop = nil
        await drained()
        beginOperation()
        defer {
            stopping = false
            endOperation()
        }
        let entries = held.values.sorted { ($0.request.transport.rawValue, $0.request.internalPort) < ($1.request.transport.rawValue, $1.request.internalPort) }
        held.removeAll()
        nextEpochCheck = .infinity
        var unconfirmed: [PortMappingRequest] = []
        for entry in entries where entry.mapping != nil {
            if !(await release(entry)) { unconfirmed.append(entry.request) }
        }
        return unconfirmed
    }

    /// Stops renewing and lets go of every mapping without deleting it, after requests already in
    /// flight: another router answers at the gateway address now (the Mac joined another network whose
    /// router has the same address), so a delete would reach that router, which may confirm it for a
    /// mapping it never had. The records stay, with this router's link-layer address, so a mapper for
    /// this router deletes them (`removeLeftovers()`) or takes them over (`map`) the next time the Mac
    /// is on it, and until then they last only as long as their lifetime. The records' lock is
    /// released once it returns.
    public func abandon() async {
        stopping = true
        loop?.cancel()
        loop = nil
        await drained()
        beginOperation()
        defer {
            stopping = false
            endOperation()
        }
        held.removeAll()
        nextEpochCheck = .infinity
    }

    /// Deletes the mappings recorded for this router that this mapper does not hold, with their saved
    /// nonces: what an earlier run left (it crashed or was force quit) and deletes the router did
    /// not confirm. The app is to run it at launch, whether or not remote access is on. Returns the
    /// ones whose delete was not confirmed; they stay recorded until their lifetime ends. Throws
    /// `.ownedElsewhere`, deleting nothing, while another mapper owns the records.
    @discardableResult
    public func removeLeftovers() async throws -> [PortMappingRequest] {
        if stopping { await drained() }
        beginOperation()
        defer { endOperation() }
        try acquireOwnership()
        try? records.pruneExpired(now: Date())
        var unconfirmed: [PortMappingRequest] = []
        for saved in records.entries(router: router, now: Date()) {
            guard let request = saved.request, !heldKeys.contains(request.mappingKey), let nonce = saved.nonceBytes else { continue }
            let method = saved.method.flatMap(Method.init(rawValue:))
            if await delete(request, nonce: nonce, method: method, externalPort: saved.externalPort, externalAddress: nil) {
                // A `map` of the same mapping that began meanwhile keeps its record.
                if !heldKeys.contains(request.mappingKey) { forget(request) }
                continuation.yield(.removed(request))
            } else {
                unconfirmed.append(request)
                continuation.yield(.removalUnconfirmed(request, expiresAt: saved.expiresAt))
            }
        }
        return unconfirmed
    }

    /// The router's external address: a PCP router's last MAP answer (a PCP-only router does not
    /// answer NAT-PMP's query), otherwise NAT-PMP's address query.
    public func externalAddress() async throws -> IPv4Address {
        if method == .pcp, let lastExternalAddress { return lastExternalAddress }
        do {
            let answer = try await exchange.perform(timeouts: configuration.attemptTimeouts,
                request: { _ in NATPMPWire.externalAddressRequest() },
                accept: { try NATPMPWire.parseExternalAddress($0) })
            if method == .natPMP { observeEpoch(answer.epoch, method: .natPMP, answering: nil) }
            lastExternalAddress = answer.address
            return answer.address
        } catch PortMappingError.unsupportedVersion {
            if let lastExternalAddress { return lastExternalAddress }
            throw PortMappingError.unsupportedVersion
        }
    }

    // MARK: - Requests

    /// PCP first; NAT-PMP when the router answers PCP with NAT-PMP's unsupported version, or does
    /// not answer PCP at all, before a method is settled.
    private func send(_ entry: Held, lifetime: UInt32, suggestedPort: UInt16, suggestedAddress: IPv4Address?) async throws -> PortMapping {
        if method != .natPMP {
            do {
                let (mapping, serverEpoch) = try await pcpMap(entry.request, nonce: entry.nonce, lifetime: lifetime, suggestedPort: suggestedPort,
                                                              suggestedAddress: suggestedAddress, timeouts: configuration.attemptTimeouts)
                settle(.pcp)
                observeEpoch(serverEpoch, method: .pcp, answering: entry.request)
                return mapping
            } catch let error as PortMappingError where method == nil && (error == .unsupportedVersion || error == .noResponse) {
                // Not settled on PCP yet: try NAT-PMP.
            }
        }
        let answer = try await natPMPMap(entry.request, suggestedPort: suggestedPort, lifetime: lifetime, timeouts: configuration.attemptTimeouts)
        settle(.natPMP)
        observeEpoch(answer.epoch, method: .natPMP, answering: entry.request)
        if lastExternalAddress == nil { _ = try? await externalAddress() }
        return PortMapping(request: entry.request, externalPort: answer.externalPort, externalAddress: lastExternalAddress,
                           lifetime: answer.lifetime, method: .natPMP)
    }

    private func pcpMap(_ request: PortMappingRequest, nonce: [UInt8], lifetime: UInt32, suggestedPort: UInt16,
                        suggestedAddress: IPv4Address?, timeouts: [TimeInterval]) async throws -> (PortMapping, UInt32) {
        let answer = try await exchange.perform(timeouts: timeouts,
            request: { client in
                PCPWire.mapRequest(nonce: nonce, transport: request.transport, internalPort: request.internalPort,
                                   suggestedExternalPort: suggestedPort, suggestedExternalAddress: suggestedAddress ?? .any,
                                   lifetime: lifetime, client: client)
            },
            accept: { try PCPWire.parseMap($0, nonce: nonce, transport: request.transport, internalPort: request.internalPort) })
        if let address = answer.externalAddress, address != .any { lastExternalAddress = address }
        return (PortMapping(request: request, externalPort: answer.externalPort, externalAddress: answer.externalAddress,
                            lifetime: answer.lifetime, method: .pcp), answer.epoch)
    }

    private func natPMPMap(_ request: PortMappingRequest, suggestedPort: UInt16, lifetime: UInt32,
                           timeouts: [TimeInterval]) async throws -> NATPMPWire.Mapping {
        try await exchange.perform(timeouts: timeouts,
            request: { _ in NATPMPWire.mapRequest(request.transport, internalPort: request.internalPort,
                                                  suggestedExternalPort: suggestedPort, lifetime: lifetime) },
            accept: { try NATPMPWire.parseMap($0, transport: request.transport, internalPort: request.internalPort) })
    }

    /// Lifetime 0 on the router within the release timeouts; `.removed` only when the router
    /// confirms, `.removalUnconfirmed` (the record kept) otherwise.
    @discardableResult
    private func release(_ entry: Held) async -> Bool {
        guard let mapping = entry.mapping else { return true }
        let request = entry.request
        if await delete(request, nonce: entry.nonce, method: mapping.method, externalPort: mapping.externalPort,
                        externalAddress: mapping.externalAddress) {
            forget(request)
            continuation.yield(.removed(request))
            return true
        }
        let expiresAt = records.entry(router: router, key: request.mappingKey, now: Date())?.expiresAt
            ?? Date().addingTimeInterval(TimeInterval(mapping.lifetime))
        continuation.yield(.removalUnconfirmed(request, expiresAt: expiresAt))
        return false
    }

    /// True when the router answered the delete with success. Without a known method, PCP first,
    /// then NAT-PMP.
    private func delete(_ request: PortMappingRequest, nonce: [UInt8], method known: Method?, externalPort: UInt16,
                        externalAddress: IPv4Address?) async -> Bool {
        let timeouts = configuration.releaseTimeouts
        if known != .natPMP {
            do {
                _ = try await pcpMap(request, nonce: nonce, lifetime: 0, suggestedPort: externalPort,
                                     suggestedAddress: externalAddress, timeouts: timeouts)
                return true
            } catch let error as PortMappingError where known == nil && (error == .unsupportedVersion || error == .noResponse) {
                // Not known to be PCP: try NAT-PMP.
            } catch {
                return false
            }
        }
        return (try? await natPMPMap(request, suggestedPort: 0, lifetime: 0, timeouts: timeouts)) != nil
    }

    private func settle(_ value: Method) {
        if method != value { epoch = EpochTracker() }
        method = value
    }

    private func accept(_ mapping: PortMapping) {
        let request = mapping.request
        guard var entry = held[request] else { return }
        let previous = entry.mapping
        let now = Self.now()
        entry.mapping = mapping
        entry.expiresAt = now + TimeInterval(mapping.lifetime)
        // Renew at half-life; never sooner than a second, whatever the router granted.
        entry.dueAt = now + max(1, TimeInterval(mapping.lifetime) / 2)
        held[request] = entry
        // The answer came: no retransmission follows, so the granted lifetime from now is the most it lasts.
        try? record(request, nonce: entry.nonce, method: mapping.method, externalPort: mapping.externalPort,
                    lifetime: mapping.lifetime, retransmitting: false)
        continuation.yield(.mapped(mapping))
        if let previous, previous.externalPort != mapping.externalPort {
            continuation.yield(.externalPortChanged(request, from: previous.externalPort, to: mapping.externalPort))
        }
    }

    /// A router whose epoch went back has restarted and forgotten its mappings: make the others
    /// again now (the one this answer is for was just made).
    private func observeEpoch(_ value: UInt32, method: Method, answering request: PortMappingRequest?) {
        guard epoch.observe(value, at: Self.now(), method: method) else { return }
        continuation.yield(.gatewayRestarted)
        let now = Self.now()
        for key in held.keys where key != request && held[key]?.mapping != nil { held[key]?.dueAt = now }
        reschedule()
    }

    // MARK: - Records

    /// Keeps the record at least until the mapping could end: `lifetime` from now, plus, before a
    /// request goes out, the time its retransmissions take (each one the router applies starts the
    /// lifetime again; PCP's and then NAT-PMP's while the method is not settled), in whole seconds
    /// rounded up, as the file keeps them. Called only while this mapper owns the records.
    private func record(_ request: PortMappingRequest, nonce: [UInt8], method: Method?, externalPort: UInt16,
                        lifetime: UInt32, retransmitting: Bool = true) throws {
        let window = retransmitting ? 2 * configuration.attemptTimeouts.reduce(0, +) : 0
        let expiresAt = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 + TimeInterval(lifetime) + window).rounded(.up))
        let previous = records.entry(router: router, key: request.mappingKey, now: Date())
        do {
            try records.save(PortMappingRecord(router: router, request: request, nonce: nonce,
                method: method?.rawValue ?? previous?.method, externalPort: externalPort,
                expiresAt: max(expiresAt, previous?.expiresAt ?? expiresAt)))
        } catch {
            throw PortMappingError.records(error.localizedDescription)
        }
    }

    private func forget(_ request: PortMappingRequest) {
        try? records.remove(router: router, key: request.mappingKey)
    }

    /// The router the records of this mapper belong to.
    private var router: MappingRouter {
        MappingRouter(gateway: configuration.gateway, hardwareAddress: configuration.routerHardwareAddress)
    }

    private var heldKeys: Set<MappingKey> { Set(held.keys.map(\.mappingKey)) }

    // MARK: - Ownership

    /// Takes the records' lock (flock, non-blocking) and reads the records again: another mapper may
    /// have changed them since. Nothing to take without a records file.
    private func acquireOwnership() throws {
        guard lockDescriptor < 0, let lockFile else { return }
        do {
            try PortMappingRecords.prepareFolder(lockFile.deletingLastPathComponent())
        } catch {
            throw PortMappingError.records(error.localizedDescription)
        }
        let descriptor = Darwin.open(lockFile.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw PortMappingError.records("the records' lock could not be opened: \(String(cString: strerror(errno)))") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let failure = errno
            Darwin.close(descriptor)
            throw failure == EWOULDBLOCK ? PortMappingError.ownedElsewhere : PortMappingError.records("the records' lock could not be taken")
        }
        lockDescriptor = descriptor
        records = PortMappingRecords(url: configuration.recordsFile)
    }

    /// Lets another mapper own the records once this one holds no mapping and has no request, stop
    /// or delete in progress. What stays recorded is then a leftover for whoever owns them next.
    private func releaseOwnershipIfIdle() {
        guard held.isEmpty, inFlight == 0, lockDescriptor >= 0 else { return }
        flock(lockDescriptor, LOCK_UN)
        Darwin.close(lockDescriptor)
        lockDescriptor = -1
    }

    private static func routerAnswered(_ error: Error) -> Bool {
        switch error as? PortMappingError {
        case .refused, .notAuthorized, .unsupportedVersion, .malformedResponse: true
        default: false
        }
    }

    // MARK: - Requests in flight

    private func beginOperation() { inFlight += 1 }

    private func endOperation() {
        inFlight -= 1
        guard inFlight == 0 else { return }
        releaseOwnershipIfIdle()
        let waiters = drainWaiters
        drainWaiters = []
        waiters.forEach { $0.resume() }
    }

    /// Returns once no map, renewal, stop, unmap or leftover delete is in flight.
    private func drained() async {
        while inFlight > 0 {
            await withCheckedContinuation { drainWaiters.append($0) }
        }
    }

    // MARK: - Renewals

    private func reschedule() {
        guard !runningDue else { return } // runDue schedules again when it ends
        loop?.cancel()
        let deadline = min(held.values.map(\.dueAt).min() ?? .infinity, nextEpochCheck)
        guard !stopping, deadline.isFinite else { loop = nil; return }
        let delay = max(0, deadline - Self.now())
        loop = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            await self?.runDue()
        }
    }

    private func runDue() async {
        guard !runningDue, !stopping else { return }
        runningDue = true
        defer {
            runningDue = false
            reschedule()
        }
        while !stopping {
            var worked = false
            if nextEpochCheck <= Self.now() {
                worked = true
                nextEpochCheck = Self.now() + configuration.epochCheckInterval
                await checkEpoch()
            }
            let due = held.values.filter { $0.dueAt <= Self.now() }.map(\.request)
            for request in due where !stopping {
                worked = true
                await renew(request)
            }
            if !worked { return }
        }
    }

    private func renew(_ request: PortMappingRequest) async {
        guard !stopping, let entry = held[request] else { return }
        beginOperation()
        defer { endOperation() }
        let suggestedPort = entry.mapping?.externalPort ?? request.externalPort
        do {
            // Recorded before the request goes out, as `map` does: the router may apply the renewal
            // even if its answer is lost or this app ends first. Without a record, nothing is sent,
            // and the mapping ends with the lifetime already recorded.
            try record(request, nonce: entry.nonce, method: entry.mapping?.method ?? method, externalPort: suggestedPort,
                       lifetime: configuration.requestedLifetime)
            let mapping = try await send(entry, lifetime: configuration.requestedLifetime,
                                         suggestedPort: suggestedPort,
                                         suggestedAddress: entry.mapping?.externalAddress)
            guard held[request]?.token == entry.token else {
                await release(Held(request: request, nonce: entry.nonce, mapping: mapping))
                return
            }
            accept(mapping)
        } catch {
            guard var current = held[request], current.token == entry.token else { return }
            let now = Self.now()
            if current.mapping != nil, now >= current.expiresAt {
                current.mapping = nil
                continuation.yield(.expired(request))
            }
            current.dueAt = now + max(1, configuration.renewalRetryInterval)
            held[request] = current
            continuation.yield(.renewalFailed(request, error as? PortMappingError ?? .socket(error.localizedDescription)))
        }
    }

    /// Reads the router's epoch between renewals (PCP ANNOUNCE, NAT-PMP's address query).
    private func checkEpoch() async {
        guard let method else { return }
        switch method {
        case .pcp:
            if let answer = try? await exchange.perform(timeouts: configuration.attemptTimeouts,
                request: { PCPWire.announceRequest(client: $0) }, accept: { try PCPWire.parseAnnounce($0) }) {
                observeEpoch(answer.epoch, method: .pcp, answering: nil)
            }
        case .natPMP:
            _ = try? await externalAddress()
        }
    }

    /// Seconds on a clock that keeps counting while the Mac sleeps, like the router's epoch.
    static func now() -> TimeInterval { TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000 }
}

/// What a router knows a mapping by (with the client's address): its transport and internal port.
/// The external port is only asked for and may not be granted, so it is not part of it.
struct MappingKey: Hashable, Sendable {
    let transport: MappedTransport
    let internalPort: UInt16
}

extension PortMappingRequest {
    var mappingKey: MappingKey { MappingKey(transport: transport, internalPort: internalPort) }
}

/// A router as the records know it: its gateway address and, when known, its link-layer address.
struct MappingRouter: Equatable, Sendable {
    let gateway: IPv4Address
    let hardwareAddress: String?

    /// Whether a record made through `gateway` and `hardwareAddress` belongs to this router: the same
    /// gateway address and, when both link-layer addresses are known, the same one.
    func holds(gateway other: String, hardwareAddress theirs: String?) -> Bool {
        guard other == gateway.description else { return false }
        guard let mine = hardwareAddress, let theirs else { return true }
        return mine.lowercased() == theirs.lowercased()
    }
}

/// A mapping that may exist on a router, as recorded between runs.
struct PortMappingRecord: Codable, Equatable, Sendable {
    var gateway: String
    /// The router's link-layer address when it was known (nil in records written before it was kept).
    var hardwareAddress: String?
    var transport: String
    var internalPort: UInt16
    /// The external port the request asked for (nil in records written before it was kept: then
    /// `externalPort`).
    var requestedPort: UInt16?
    /// The external port the router granted, or the one asked for until it answers.
    var externalPort: UInt16
    /// PCP's 12-byte mapping nonce, in hex.
    var nonce: String
    /// "pcp" or "natPMP" once the router answered; nil before.
    var method: String?
    var expiresAt: Date

    init(router: MappingRouter, request: PortMappingRequest, nonce: [UInt8], method: String?, externalPort: UInt16, expiresAt: Date) {
        gateway = router.gateway.description
        hardwareAddress = router.hardwareAddress
        transport = request.transport.rawValue
        internalPort = request.internalPort
        requestedPort = request.externalPort
        self.externalPort = externalPort
        self.nonce = nonce.map { String(format: "%02x", $0) }.joined()
        self.method = method
        self.expiresAt = expiresAt
    }

    /// The request as it was made: with the external port asked for, not the one granted.
    var request: PortMappingRequest? {
        MappedTransport(rawValue: transport).flatMap {
            try? PortMappingRequest($0, internalPort: internalPort, externalPort: requestedPort ?? externalPort)
        }
    }

    var key: MappingKey? { MappedTransport(rawValue: transport).map { MappingKey(transport: $0, internalPort: internalPort) } }

    var nonceBytes: [UInt8]? {
        let digits = Array(nonce.utf8)
        guard digits.count == 24 else { return nil }
        var bytes: [UInt8] = []
        for index in stride(from: 0, to: 24, by: 2) {
            guard let byte = UInt8(String(decoding: digits[index..<index + 2], as: UTF8.self), radix: 16) else { return nil }
            bytes.append(byte)
        }
        return bytes
    }

    func matches(router: MappingRouter, key: MappingKey) -> Bool {
        router.holds(gateway: gateway, hardwareAddress: hardwareAddress) && self.key == key
    }

    var router: MappingRouter? { IPv4Address(gateway).map { MappingRouter(gateway: $0, hardwareAddress: hardwareAddress) } }
}

/// The records file: a JSON array written atomically, 0600 in a 0700 folder, read and written only
/// by the mapper holding its lock. Without a file the records live in memory only.
struct PortMappingRecords {
    let url: URL?
    private var all: [PortMappingRecord]

    init(url: URL?) {
        self.url = url
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        all = url.flatMap { try? Data(contentsOf: $0) }.flatMap { try? decoder.decode([PortMappingRecord].self, from: $0) } ?? []
    }

    /// Records for this router whose lifetime has not ended.
    func entries(router: MappingRouter, now: Date) -> [PortMappingRecord] {
        all.filter { router.holds(gateway: $0.gateway, hardwareAddress: $0.hardwareAddress) && $0.expiresAt > now }
    }

    func entry(router: MappingRouter, key: MappingKey, now: Date) -> PortMappingRecord? {
        all.first { $0.matches(router: router, key: key) && $0.expiresAt > now }
    }

    /// Replaces this router's record of the mapping; another router's (at the same gateway address) stays.
    mutating func save(_ record: PortMappingRecord) throws {
        guard let key = record.key, let router = record.router else { return }
        all.removeAll { $0.matches(router: router, key: key) }
        all.append(record)
        try write()
    }

    mutating func remove(router: MappingRouter, key: MappingKey) throws {
        let count = all.count
        all.removeAll { $0.matches(router: router, key: key) }
        if all.count != count { try write() }
    }

    mutating func pruneExpired(now: Date) throws {
        let count = all.count
        all.removeAll { $0.expiresAt <= now }
        if all.count != count { try write() }
    }

    static func prepareFolder(_ folder: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
    }

    private func write() throws {
        guard let url else { return }
        let manager = FileManager.default
        try Self.prepareFolder(url.deletingLastPathComponent())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(all).write(to: url, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// Tells a router restart from its epoch (seconds since its mappings were last lost).
struct EpochTracker: Sendable {
    private var last: (server: UInt32, client: TimeInterval)?

    /// Records the epoch the router sent at `client` time; true when it shows a restart.
    mutating func observe(_ server: UInt32, at client: TimeInterval, method: PortMapper.Method) -> Bool {
        defer { last = (server, client) }
        guard let last else { return false }
        let clientDelta = client - last.client
        let serverDelta = Double(server) - Double(last.server)
        switch method {
        case .natPMP:
            // RFC 6886 §3.6: at least 7/8 of the time that passed here, less 2 s.
            return serverDelta < clientDelta * 7 / 8 - 2
        case .pcp:
            // RFC 6887 §8.5.
            if serverDelta < -1 { return true }
            return clientDelta + 2 < serverDelta - serverDelta / 16 || serverDelta + 2 < clientDelta - clientDelta / 16
        }
    }
}

/// One request and its answer over a UDP socket connected to the router, retransmitted after each
/// timeout. Datagrams that are not the answer (another request's, a stray) are skipped.
struct GatewayExchange: Sendable {
    let gateway: IPv4Address
    let port: UInt16

    func perform<T: Sendable>(timeouts: [TimeInterval], request: @escaping @Sendable (IPv4Address) -> [UInt8],
                              accept: @escaping @Sendable ([UInt8]) throws -> T?) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result { try performBlocking(timeouts: timeouts, request: request, accept: accept) })
            }
        }
    }

    private func performBlocking<T>(timeouts: [TimeInterval], request: (IPv4Address) -> [UInt8],
                                    accept: ([UInt8]) throws -> T?) throws -> T {
        let socket = try GatewaySocket(gateway: gateway, port: port)
        defer { socket.close() }
        let packet = request(socket.localAddress)
        for timeout in timeouts {
            try socket.send(packet)
            let deadline = PortMapper.now() + timeout
            while true {
                let remaining = deadline - PortMapper.now()
                guard remaining > 0, let datagram = try socket.receive(timeout: remaining) else { break }
                if let value = try accept(datagram) { return value }
            }
        }
        throw PortMappingError.noResponse
    }
}

private final class GatewaySocket {
    private var descriptor: Int32
    let localAddress: IPv4Address

    init(gateway: IPv4Address, port: UInt16) throws {
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw PortMappingError.socket(String(cString: strerror(errno))) }
        func fail() -> PortMappingError {
            let message = String(cString: strerror(errno))
            Darwin.close(fd)
            return PortMappingError.socket(message)
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: UInt32(gateway.bytes[0]) | UInt32(gateway.bytes[1]) << 8
                                   | UInt32(gateway.bytes[2]) << 16 | UInt32(gateway.bytes[3]) << 24)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { throw fail() }
        var local = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else { throw fail() }
        let raw = local.sin_addr.s_addr
        descriptor = fd
        localAddress = IPv4Address(bytes: [UInt8(raw & 0xff), UInt8((raw >> 8) & 0xff), UInt8((raw >> 16) & 0xff), UInt8(raw >> 24)])
    }

    func send(_ packet: [UInt8]) throws {
        for _ in 0..<2 {
            let sent = packet.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress, $0.count, 0) }
            if sent == packet.count { return }
            let failure = errno
            // A refusal of an earlier datagram (nothing listening) is reported by the next call:
            // send once more, and if nothing listens at all the wait for an answer times out.
            guard sent < 0, failure == ECONNREFUSED else { throw PortMappingError.socket(String(cString: strerror(failure))) }
        }
    }

    /// The next datagram, an empty one for a refusal (nothing listening), or nil after `timeout`.
    func receive(timeout: TimeInterval) throws -> [UInt8]? {
        var poller = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        let ready = poll(&poller, 1, Int32(max(1, (timeout * 1000).rounded(.up))))
        if ready == 0 { return nil }
        if ready < 0 {
            if errno == EINTR { return [] }
            throw PortMappingError.socket(String(cString: strerror(errno)))
        }
        var buffer = [UInt8](repeating: 0, count: 1100)
        let count = buffer.withUnsafeMutableBytes { Darwin.recv(descriptor, $0.baseAddress, $0.count, 0) }
        if count < 0 {
            if errno == ECONNREFUSED || errno == EINTR { return [] }
            throw PortMappingError.socket(String(cString: strerror(errno)))
        }
        return Array(buffer.prefix(count))
    }

    func close() {
        if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 }
    }

    deinit { close() }
}
