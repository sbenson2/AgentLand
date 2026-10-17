import Foundation

/// The direct addresses the Mac app reports after each attempt to map the endpoint's UDP port, and
/// when it tries again (docs/HOST-API.md "The Mac app reports").
///
/// Devices replace their kept entry with every report, and the app rewrites the address record in
/// iCloud after every report whose revision changed. So a report without addresses reaches every
/// device and the record, and one router that did not answer in time (common right after a wake or
/// a router restart) must not wipe what they know. Nor may a report keep an address whose mapping is
/// gone: phones would dial it, and the owner would never be told that the network needs the relay.
/// - A mapping the router grants or renews is reported with its global unicast addresses, none when
///   the router's external address is not global (another router in front, carrier-grade NAT). It
///   becomes the last mapping, with the router it was made through and the end of its lease (when
///   the router drops it unless it is renewed first).
/// - An attempt that makes no mapping reports the last mapping's addresses only while all of this
///   holds: its lease has not ended; the attempt went through the same router, known by its gateway
///   address and its link-layer address (gateway addresses alone do not tell routers apart:
///   192.168.1.1, 192.168.0.1 and 10.0.0.1 are most routers' defaults); and the router did not
///   answer (`Failure.noAnswer`). A router that answers without a mapping (`Failure.refused`) has
///   not opened the port. Otherwise the report has none.
/// - A held mapping whose renewals failed until its lease ended (`PortMappingEvent.expired`) is
///   reported with none (`expired()`); `PortMapper` keeps retrying it.
/// - While the switch is on and no mapping is held, the app tries again after `retryDelays` (the
///   last one repeats), and no later than the end of the kept mapping's lease, so the report drops
///   its addresses when the lease ends; at once when the network changes or the Mac wakes
///   (`restart()`).
///
/// The app keeps the plan in its preferences, so a launch whose attempt fails still reports the
/// last mapping while its lease lasts, and makes a new plan when the owner turns the switch off.
public struct RemoteAccessMappingPlan: Codable, Equatable, Sendable {
    /// The router an attempt went through.
    public struct Router: Codable, Equatable, Sendable {
        /// The IPv4 default route's gateway (`DefaultGateway.ipv4()`).
        public var gateway: String
        /// The gateway's link-layer (MAC) address in this Mac's ARP table
        /// (`DefaultGateway.hardwareAddress(of:)`), read after the attempt, when sending it has
        /// resolved the gateway; nil when the table has none.
        public var hardwareAddress: String?

        public init(gateway: String, hardwareAddress: String?) {
            self.gateway = gateway
            self.hardwareAddress = hardwareAddress
        }

        /// This Mac's router now; nil when there is no default route through a private address.
        public static func current() -> Router? {
            guard let gateway = DefaultGateway.ipv4() else { return nil }
            return Router(gateway: gateway.description, hardwareAddress: DefaultGateway.hardwareAddress(of: gateway))
        }

        /// The same router: the same gateway address and, when both link-layer addresses are known,
        /// the same one. Another router at the same address (a replaced router, another network with
        /// the same default) has another link-layer address; one that could not be read leaves only
        /// the lease to bound how long the last addresses are kept.
        public func isSame(as other: Router) -> Bool {
            guard gateway == other.gateway else { return false }
            guard let mine = hardwareAddress, let theirs = other.hardwareAddress else { return true }
            return mine == theirs
        }
    }

    public struct Mapping: Codable, Equatable, Sendable {
        /// The router the mapping was made through.
        public var router: Router
        /// The mapping's external `ip:port` addresses that are global unicast.
        public var directAddresses: [String]
        /// When the router last granted or renewed it.
        public var grantedAt: Date
        /// When the router drops it unless it is renewed first: `grantedAt` plus the lifetime the
        /// router granted, at most `maximumLease`.
        public var expiresAt: Date

        public init(router: Router, directAddresses: [String], grantedAt: Date, expiresAt: Date) {
            self.router = router
            self.directAddresses = directAddresses
            self.grantedAt = grantedAt
            self.expiresAt = expiresAt
        }

        /// The router may still hold it: its lease has not ended, and the clock has not gone back past
        /// when it was granted (then how long it has lasted is unknown).
        func isLive(at now: Date) -> Bool {
            now < expiresAt && now.timeIntervalSince(grantedAt) >= -RemoteAccessMappingPlan.clockSlack
        }
    }

    /// Why an attempt made no mapping.
    public enum Failure: Equatable, Sendable {
        /// Nothing answered in time (a wake, a router restarting; also a router with only UPnP, or
        /// with PCP and NAT-PMP turned off, which stays silent), or the router answered that it
        /// cannot map just now (its network is not up yet, it is out of resources).
        case noAnswer
        /// The router answered and will not map: refused, not authorized, or a request it does not
        /// take. The port is not open.
        case refused

        /// How `PortMapper.map` failed.
        public init(_ error: PortMappingError) {
            switch error {
            case let .refused(method, code):
                self = Self.temporaryCodes[method, default: []].contains(code) ? .noAnswer : .refused
            case .notAuthorized, .unsupportedVersion, .malformedResponse:
                self = .refused
            case .noResponse, .socket, .records, .ownedElsewhere, .invalidRequest, .invalidGateway:
                self = .noAnswer
            }
        }

        /// Result codes that say "not now": NAT-PMP's network failure and out of resources, PCP's
        /// NETWORK_FAILURE and NO_RESOURCES (a router that has just restarted answers them).
        static let temporaryCodes: [PortMapper.Method: Set<UInt16>] = [.natPMP: [3, 4], .pcp: [7, 8]]
    }

    /// Seconds before each attempt after one that made no mapping: 15 s, 30 s, 1, 2 and 5 minutes,
    /// then every 10 minutes.
    public static let retryDelays: [TimeInterval] = [15, 30, 60, 120, 300, 600]
    /// The longest lease the plan believes: `PortMapper`'s requested lifetime (2 hours). A router may
    /// grant more; the plan never keeps addresses longer than this after a grant or renewal.
    public static let maximumLease: TimeInterval = 7200
    /// How far the clock may go back after a grant before the mapping's age counts as unknown.
    static let clockSlack: TimeInterval = 60

    public private(set) var lastMapping: Mapping?
    /// Attempts that made no mapping since the last one that did, or since `restart()`.
    public private(set) var failedAttempts = 0

    public init(lastMapping: Mapping? = nil) {
        self.lastMapping = lastMapping
    }

    /// The router granted or renewed a mapping through `router` for `lifetime` seconds
    /// (`PortMappingEvent.mapped`); `directAddresses` are its external addresses that are global
    /// unicast (`RemoteAccessDirectAddress.isDialable`). Returns the addresses to report.
    public mutating func mapped(_ directAddresses: [String], router: Router, lifetime: TimeInterval, now: Date = Date()) -> [String] {
        failedAttempts = 0
        guard !directAddresses.isEmpty, lifetime > 0 else {
            lastMapping = nil
            return []
        }
        lastMapping = Mapping(router: router, directAddresses: directAddresses, grantedAt: now,
                              expiresAt: now.addingTimeInterval(min(lifetime, Self.maximumLease)))
        return directAddresses
    }

    /// An attempt made no mapping: `failure` says why, and `router` is the router it asked (nil when
    /// there is none). Returns the addresses to report.
    public mutating func failed(_ failure: Failure, router: Router?, now: Date = Date()) -> [String] {
        failedAttempts += 1
        guard let mapping = lastMapping else { return [] }
        guard mapping.isLive(at: now) else {
            lastMapping = nil
            return []
        }
        // Another router, or none: the last addresses are not this network's. The mapping is kept for
        // a return to its router while its lease lasts (a laptop brought back home).
        guard let router, mapping.router.isSame(as: router) else { return [] }
        guard failure == .noAnswer else {
            lastMapping = nil
            return []
        }
        return mapping.directAddresses
    }

    /// `PortMapper` reported the held mapping expired: its renewals failed until its lease ended, so
    /// the router no longer holds it. Returns the addresses to report: none. `PortMapper` keeps
    /// retrying, and a renewal that works is `mapped` again.
    public mutating func expired() -> [String] {
        lastMapping = nil
        return []
    }

    /// How long to wait before the next attempt; nil when the last attempt made a mapping or none has
    /// failed since `restart()`. Never later than the end of the kept mapping's lease, so the attempt
    /// then reports that its addresses are gone.
    public func retryDelay(now: Date = Date()) -> TimeInterval? {
        guard failedAttempts > 0 else { return nil }
        let delay = Self.retryDelays[min(failedAttempts, Self.retryDelays.count) - 1]
        guard let lastMapping, lastMapping.isLive(at: now) else { return delay }
        return min(delay, max(1, lastMapping.expiresAt.timeIntervalSince(now)))
    }

    /// The network changed or the Mac woke: the app tries at once, and the delays start over.
    public mutating func restart() {
        failedAttempts = 0
    }
}
