import AgentLandDesktopCore
import Foundation
import XCTest

/// What the Mac reports after each mapping attempt, and when it tries again.
final class RemoteAccessMappingPlanTests: XCTestCase {
    private let home = RemoteAccessMappingPlan.Router(gateway: "192.168.1.1", hardwareAddress: "a0:b1:c2:d3:e4:f5")
    private let mapped = ["198.20.0.7:38842"]
    private let lease: TimeInterval = 7200
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    /// One timed-out exchange right after a wake used to report no addresses, which replaced every
    /// device's kept entry and the iCloud record. On the router the last mapping was made through,
    /// while its lease lasts, the report keeps its addresses, and the app tries again on a backoff.
    func testAnAttemptThatFailsKeepsTheLastAddressesOnTheSameRouter() {
        var plan = RemoteAccessMappingPlan()
        XCTAssertNil(plan.retryDelay(now: start))
        XCTAssertEqual(plan.mapped(mapped, router: home, lifetime: lease, now: start), mapped)
        XCTAssertNil(plan.retryDelay(now: start))
        var delays: [TimeInterval] = []
        for _ in 0..<8 {
            XCTAssertEqual(plan.failed(.noAnswer, router: home, now: start.addingTimeInterval(60)), mapped)
            delays.append(plan.retryDelay(now: start.addingTimeInterval(60)) ?? -1)
        }
        XCTAssertEqual(delays, [15, 30, 60, 120, 300, 600, 600, 600])
        // A later attempt that maps reports what the router granted now.
        XCTAssertEqual(plan.mapped(["198.20.0.7:40001"], router: home, lifetime: lease, now: start.addingTimeInterval(90)), ["198.20.0.7:40001"])
        XCTAssertNil(plan.retryDelay(now: start.addingTimeInterval(90)))
        XCTAssertEqual(plan.failed(.noAnswer, router: home, now: start.addingTimeInterval(120)), ["198.20.0.7:40001"])
    }

    /// The addresses used to be kept for ever on any router with the same gateway address: after the
    /// router stopped mapping (NAT-PMP turned off), the Mac reported, and wrote to iCloud, an address
    /// whose mapping had ended, and never showed the relay advice. They are kept only until the
    /// lease of the last grant or renewal would have ended, and the attempt that follows the backoff
    /// comes no later than that.
    func testTheLastAddressesEndWithTheirLease() {
        var plan = RemoteAccessMappingPlan()
        _ = plan.mapped(mapped, router: home, lifetime: lease, now: start)
        // Nine failures on the schedule (15 s … 10 min) are well inside the lease.
        var now = start
        for _ in 0..<9 {
            now = now.addingTimeInterval(plan.retryDelay(now: now) ?? 0)
            XCTAssertEqual(plan.failed(.noAnswer, router: home, now: now), mapped)
        }
        // The next attempt comes when the lease ends, not up to 10 minutes later.
        let beforeTheEnd = start.addingTimeInterval(lease - 100)
        XCTAssertEqual(plan.failed(.noAnswer, router: home, now: beforeTheEnd), mapped)
        XCTAssertEqual(plan.retryDelay(now: beforeTheEnd), 100)
        XCTAssertEqual(plan.failed(.noAnswer, router: home, now: start.addingTimeInterval(lease)), [])
        XCTAssertNil(plan.lastMapping)
        XCTAssertEqual(plan.retryDelay(now: start.addingTimeInterval(lease)), 600)

        // A renewal (PortMapper's `.mapped`) starts the lease again.
        var renewed = RemoteAccessMappingPlan()
        _ = renewed.mapped(mapped, router: home, lifetime: lease, now: start)
        _ = renewed.mapped(mapped, router: home, lifetime: lease, now: start.addingTimeInterval(3600))
        XCTAssertEqual(renewed.failed(.noAnswer, router: home, now: start.addingTimeInterval(lease + 100)), mapped)
        // A router's longer lease is believed for 2 hours at most, and a clock that went back past the
        // grant leaves the mapping's age unknown.
        var long = RemoteAccessMappingPlan()
        _ = long.mapped(mapped, router: home, lifetime: 86_400, now: start)
        XCTAssertEqual(long.failed(.noAnswer, router: home, now: start.addingTimeInterval(RemoteAccessMappingPlan.maximumLease)), [])
        var backwards = RemoteAccessMappingPlan()
        _ = backwards.mapped(mapped, router: home, lifetime: lease, now: start)
        XCTAssertEqual(backwards.failed(.noAnswer, router: home, now: start.addingTimeInterval(-3600)), [])
    }

    /// Gateway addresses do not tell routers apart: another router at 192.168.1.1 (a replacement,
    /// another network with the same default) has another link-layer address and none of the last
    /// mapping's addresses. The last mapping stays for a return to its router while its lease lasts.
    func testAnotherRouterAtTheSameAddressGetsNone() {
        var plan = RemoteAccessMappingPlan()
        _ = plan.mapped(mapped, router: home, lifetime: lease, now: start)
        let replaced = RemoteAccessMappingPlan.Router(gateway: "192.168.1.1", hardwareAddress: "0e:00:00:00:00:01")
        XCTAssertEqual(plan.failed(.noAnswer, router: replaced, now: start.addingTimeInterval(10)), [])
        XCTAssertEqual(plan.failed(.noAnswer, router: .init(gateway: "10.0.0.1", hardwareAddress: home.hardwareAddress), now: start.addingTimeInterval(20)), [])
        XCTAssertEqual(plan.failed(.noAnswer, router: nil, now: start.addingTimeInterval(30)), [], "no router")
        XCTAssertEqual(plan.failed(.noAnswer, router: home, now: start.addingTimeInterval(40)), mapped, "back on the router of the last mapping")
        // A link-layer address that could not be read leaves the gateway address and the lease.
        XCTAssertEqual(plan.failed(.noAnswer, router: .init(gateway: "192.168.1.1", hardwareAddress: nil), now: start.addingTimeInterval(50)), mapped)
        XCTAssertTrue(home.isSame(as: .init(gateway: "192.168.1.1", hardwareAddress: nil)))
        XCTAssertFalse(home.isSame(as: replaced))
    }

    /// A router that answers without a mapping has not opened the port: the report has none (and
    /// the switch's row shows the relay advice) instead of an address nothing forwards. A router that
    /// answers "not now" (its network is not up yet after a restart) is treated as no answer.
    func testARouterThatRefusesHasNotOpenedThePort() {
        typealias Failure = RemoteAccessMappingPlan.Failure
        XCTAssertEqual(Failure(.noResponse), .noAnswer)
        XCTAssertEqual(Failure(.socket("EHOSTUNREACH")), .noAnswer)
        for temporary in [PortMappingError.refused(method: .natPMP, code: 3), .refused(method: .natPMP, code: 4),
                          .refused(method: .pcp, code: 7), .refused(method: .pcp, code: 8)] {
            XCTAssertEqual(Failure(temporary), .noAnswer, "\(temporary)")
        }
        for refusal in [PortMappingError.refused(method: .natPMP, code: 2), .refused(method: .pcp, code: 2), .refused(method: .pcp, code: 11),
                        .notAuthorized(retryAfter: 0), .unsupportedVersion, .malformedResponse] {
            XCTAssertEqual(Failure(refusal), .refused, "\(refusal)")
        }

        var plan = RemoteAccessMappingPlan()
        _ = plan.mapped(mapped, router: home, lifetime: lease, now: start)
        XCTAssertEqual(plan.failed(.refused, router: home, now: start.addingTimeInterval(10)), [])
        XCTAssertNil(plan.lastMapping)
        XCTAssertEqual(plan.failed(.noAnswer, router: home, now: start.addingTimeInterval(20)), [], "nothing is kept after a refusal")
    }

    /// PortMapper's `.expired`: a held mapping's renewals failed until its lease ended.
    func testAHeldMappingThatExpiredReportsNone() {
        var plan = RemoteAccessMappingPlan()
        _ = plan.mapped(mapped, router: home, lifetime: lease, now: start)
        XCTAssertEqual(plan.expired(), [])
        XCTAssertNil(plan.lastMapping)
        XCTAssertEqual(plan.failed(.noAnswer, router: home, now: start.addingTimeInterval(10)), [])
        // A renewal that works later is a mapping again.
        XCTAssertEqual(plan.mapped(mapped, router: home, lifetime: lease, now: start.addingTimeInterval(20)), mapped)
    }

    /// A router whose external address is not global (carrier-grade NAT) gives none, and leaves
    /// nothing to keep.
    func testNoGlobalAddressReportsNone() {
        var plan = RemoteAccessMappingPlan()
        _ = plan.mapped(mapped, router: home, lifetime: lease, now: start)
        XCTAssertEqual(plan.mapped([], router: home, lifetime: lease, now: start.addingTimeInterval(10)), [], "behind carrier-grade NAT")
        XCTAssertNil(plan.lastMapping)
        XCTAssertEqual(plan.failed(.noAnswer, router: home, now: start.addingTimeInterval(20)), [])
    }

    /// A network change or a wake tries at once and starts the delays over.
    func testRestartStartsTheDelaysOver() {
        var plan = RemoteAccessMappingPlan()
        for _ in 0..<4 { _ = plan.failed(.noAnswer, router: home, now: start) }
        XCTAssertEqual(plan.retryDelay(now: start), 120)
        plan.restart()
        XCTAssertNil(plan.retryDelay(now: start))
        _ = plan.failed(.noAnswer, router: home, now: start)
        XCTAssertEqual(plan.retryDelay(now: start), 15)
    }

    /// Kept in the app's preferences: a launch whose first attempt fails still reports the last
    /// mapping while its lease lasts, and none after it.
    func testTheLastMappingOutlivesALaunchButNotItsLease() throws {
        var plan = RemoteAccessMappingPlan()
        _ = plan.mapped(mapped, router: home, lifetime: lease, now: start)
        let saved = try JSONEncoder().encode(plan)
        var relaunched = try JSONDecoder().decode(RemoteAccessMappingPlan.self, from: saved)
        XCTAssertEqual(relaunched, plan)
        XCTAssertEqual(relaunched.failed(.noAnswer, router: home, now: start.addingTimeInterval(600)), mapped)
        var later = try JSONDecoder().decode(RemoteAccessMappingPlan.self, from: saved)
        XCTAssertEqual(later.failed(.noAnswer, router: home, now: start.addingTimeInterval(lease + 1)), [])
    }
}
