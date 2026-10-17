import CoreGraphics
import ImageIO
import XCTest
@testable import AgentLandBranding

/// The work surfaces' performance: out of the doorway at the reveal, round the ring juggling, back in after
/// 40–90 s, the next design 4–10 s later, about one in three on the tightrope instead; seeded and a pure
/// function of the circus clock.
final class ChoreographyTests: XCTestCase {
    private typealias C = AgentLandCircusChoreography
    private let reveal = 12.34
    private let horizon = 3600.0

    private func performance(seed: UInt64 = 7) -> C { C(reveal: reveal, seed: seed) }

    func testTheSameSeedGivesTheSamePerformance() {
        let first = performance(seed: 42).appearances(through: horizon)
        let second = performance(seed: 42).appearances(through: horizon)
        XCTAssertEqual(first, second)
        XCTAssertNotEqual(first.map(\.design), performance(seed: 43).appearances(through: horizon).map(\.design))
    }

    /// The reveal moment seeds the performance: the same moment, however it is made, gives the same design
    /// order; other moments, even a millisecond apart, give other orders.
    func testTheRevealMomentSeedsTheDesignOrder() {
        func order(_ reveal: Date) -> [Int] {
            C(reveal: 0, seed: C.seed(for: reveal)).appearances(through: 1_800).map(\.design)
        }
        let moment = Date(timeIntervalSinceReferenceDate: 780_000_000.25)
        let base = order(moment)
        XCTAssertGreaterThan(base.count, 15)
        XCTAssertEqual(order(Date(timeIntervalSinceReferenceDate: 780_000_000.25)), base, "The same moment, the same order")
        XCTAssertEqual(order(Date(timeIntervalSince1970: moment.timeIntervalSince1970)), base)
        let others = (1...20).map { order(moment.addingTimeInterval(Double($0) / 1000)) }
        XCTAssertEqual(Set(others + [base]).count, 21, "Every other moment gives another order")
        XCTAssertNotEqual(C.seed(for: moment), C.seed(for: moment.addingTimeInterval(0.001)))
    }

    /// A reveal long before the performance is built replays at most about 12 hours: a `.distantPast` reveal
    /// is quick, the stage keeps it under the caller's reveal, and the same reveal gives the same state.
    @MainActor
    func testAVeryOldRevealIsQuickAndStable() throws {
        let stage = CircusStage()
        let reference = Date(timeIntervalSinceReferenceDate: 780_000_000)
        let now = reference.addingTimeInterval(5_000)
        let designs = AgentLandClownArtwork.designs // decoded once per process (prepareArtwork); not the schedule's cost
        let start = Date()
        let show = stage.choreography(reveal: .distantPast, referenceDate: reference, designs: designs, now: now)
        let state = show.state(at: 5_000)
        let appearance = try XCTUnwrap(show.appearance(at: 5_000))
        let took = Date().timeIntervalSince(start)
        print("A .distantPast reveal: built and caught up in \(took * 1000) ms, \(show.appearances(through: 5_000).count) performances")
        XCTAssertLessThan(took, 0.05, "Built and caught up well under 50 ms")
        XCTAssertGreaterThanOrEqual(show.reveal, 5_000 - C.catchUpLimit)
        XCTAssertLessThan(show.reveal, 5_000 - C.catchUpLimit + C.catchUpStep)
        XCTAssertLessThan(appearance.emerge, 5_000 + 110)
        // Every frame asks the stage again: the same performance, whatever the time.
        let later = stage.choreography(reveal: .distantPast, referenceDate: reference, designs: designs,
                                       now: now.addingTimeInterval(7_200))
        XCTAssertTrue(later === show, "Keyed on the caller's reveal, not on the bounded one")
        XCTAssertEqual(show.state(at: 5_000), state)
        XCTAssertEqual(show.appearance(at: 5_000), appearance)
        // Built again within the hour, it replays the same performance.
        let rebuilt = C(reveal: Date.distantPast.timeIntervalSince(reference), seed: show.seed, now: 5_010)
        XCTAssertEqual(rebuilt.reveal, show.reveal)
        XCTAssertEqual(rebuilt.state(at: 5_000), state)
        // A recent reveal is untouched.
        XCTAssertEqual(C(reveal: 4_000, seed: 1, now: 5_000).reveal, 4_000)
        XCTAssertEqual(C.bounded(reveal: -.infinity, now: 5_000), 5_000 - C.catchUpLimit)
        XCTAssertEqual(C.seed(for: .distantPast), C.seed(for: .distantPast))
        XCTAssertEqual(C.seed(for: Date(timeIntervalSinceReferenceDate: .infinity)), C.seed(for: Date(timeIntervalSinceReferenceDate: .infinity)))
    }

    /// At the reveal (the next beat) a clown fades in inside the doorway, its wheel on the threshold.
    func testTheFirstClownComesOutOfTheDoorwayAtTheReveal() throws {
        let show = performance()
        XCTAssertNil(show.state(at: reveal - 0.01), "No clown before the reveal")
        let first = try XCTUnwrap(show.appearance(at: reveal + 1))
        XCTAssertGreaterThanOrEqual(first.emerge, reveal)
        XCTAssertLessThan(first.emerge - reveal, AgentLandClownMotion.beat, "It comes out on the next beat")
        let beats = first.emerge / AgentLandClownMotion.beat
        XCTAssertEqual(beats, beats.rounded(), accuracy: 1e-6)
        let start = try XCTUnwrap(show.state(at: first.emerge + 0.01))
        XCTAssertEqual(start.layer, .door)
        XCTAssertEqual(start.center.x, C.doorCenter.x, accuracy: 1e-9)
        XCTAssertLessThan(start.center.y, C.doorCenter.y, "It appears while moving inside the opening")
        XCTAssertGreaterThan(start.opacity, 0)
        XCTAssertLessThan(start.opacity, 0.01)
        XCTAssertEqual(try XCTUnwrap(show.state(at: first.emerge + 0.15)).opacity, 0.5, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(show.state(at: first.emerge + C.fadeDuration)).opacity, 1, accuracy: 1e-9)
        // The wheel (sprite row 94, 0.75 units a pixel) stands on the doorway's bottom edge.
        XCTAssertEqual(C.doorCenter.y + (94 - 48) * 0.75, C.threshold, accuracy: 0.01)
        XCTAssertGreaterThan(C.doorAngle, C.returnAngle, "The curls use separate clockwise tangencies")
        XCTAssertTrue(show.balls(at: first.emerge + 0.2).isEmpty, "Nothing is juggled in the doorway")
    }

    /// The outward curl crosses the threshold down-left before turning up onto the near ring. The inward
    /// curl turns back toward the opening; neither route leaves through a wall or drops down a straight line.
    func testItSpiralsOutToTheRingAndBackIntoTheDoor() throws {
        let show = performance()
        let first = try XCTUnwrap(show.appearance(at: reveal + 2))
        var outwardLowest = C.doorCenter.y
        for outward in [true, false] {
            let start = outward ? first.emerge + C.fadeDuration : first.turn
            var lateralTravel: CGFloat = 0
            for step in 1...100 {
                let time = start + C.rideDuration * Double(step) / 100 - 1e-8
                let state = try XCTUnwrap(show.state(at: time))
                XCTAssertEqual(state.layer, .door)
                XCTAssertEqual(state.opacity, 1)
                XCTAssertGreaterThanOrEqual(state.center.y, C.doorCenter.y, "Travel crosses the opening toward its foot")
                XCTAssertLessThanOrEqual(state.center.x, C.doorCenter.x + 1e-6, "The curls stay to the left of the opening")
                lateralTravel = max(lateralTravel, abs(state.center.x - C.doorCenter.x))
                if outward { outwardLowest = max(outwardLowest, state.center.y) }
                if abs(state.center.x - C.doorCenter.x) > 16 {
                    XCTAssertLessThan(state.portalEdge, state.center.y - 30, "Away from the opening the whole rider is exposed")
                }
            }
            // The ring now moves at the wheel's speed, so the curls are gentler than on the old fast ring.
            XCTAssertGreaterThan(lateralTravel, 10, "A visible turn, not a vertical drop")
        }
        XCTAssertGreaterThan(outwardLowest, C.doorPoint.y + 5, "Crosses downward, then curls up onto the ring")
        var length: CGFloat = 0
        var previous = C.state(of: first, at: first.emerge + C.fadeDuration).center
        for step in 1...400 {
            let point = C.state(of: first, at: first.emerge + C.fadeDuration + C.rideDuration * Double(step) / 400).center
            length += hypot(point.x - previous.x, point.y - previous.y)
            previous = point
        }
        XCTAssertEqual(length / CGFloat(C.rideDuration), AgentLandClownMotion.wheelSpeed,
                       accuracy: AgentLandClownMotion.wheelSpeed * 0.1, "The outward curl rides at about the wheel's speed")
        let beforeJoin = try XCTUnwrap(show.state(at: first.join - 1e-6))
        XCTAssertLessThan(beforeJoin.portalEdge, beforeJoin.center.y - 36,
                          "The full 72-point sprite clears the portal before switching to the front layer")
        let joined = try XCTUnwrap(show.state(at: first.join))
        XCTAssertEqual(joined.center.x, C.doorPoint.x, accuracy: 1e-6)
        XCTAssertEqual(joined.center.y, C.doorPoint.y, accuracy: 1e-6)
        XCTAssertEqual(joined.layer, .front)
        XCTAssertTrue(joined.facingLeft, "The near tangent is moving left")
        let lap = AgentLandClownMotion.orbitPeriod
        let behind = try XCTUnwrap(show.state(at: first.join + lap / 2))
        XCTAssertEqual(behind.layer, .behind)
        let again = try XCTUnwrap(show.state(at: first.join + lap))
        XCTAssertEqual(again.center.x, C.doorPoint.x, accuracy: 1e-6)
        XCTAssertEqual(again.center.y, C.doorPoint.y, accuracy: 1e-6)
    }

    func testTheSpiralsMatchTheRingsPositionAndVelocity() throws {
        let show = performance()
        let first = try XCTUnwrap(show.appearance(at: reveal + 2))
        let dt = 0.00001
        for time in [first.emerge + C.fadeDuration, first.join, first.turn, first.back] {
            let before = try XCTUnwrap(show.state(at: time - dt))
            let at = try XCTUnwrap(show.state(at: time))
            let after = try XCTUnwrap(show.state(at: time + dt))
            XCTAssertEqual((at.center.x - before.center.x) / dt, (after.center.x - at.center.x) / dt, accuracy: 0.02)
            XCTAssertEqual((at.center.y - before.center.y) / dt, (after.center.y - at.center.y) / dt, accuracy: 0.02)
            XCTAssertEqual(before.facingLeft, after.facingLeft)
        }
        for time in [first.emerge + C.fadeDuration, first.join, first.turn, first.back, first.gone - dt] {
            let before = C.state(of: first, at: time - dt)
            let after = C.state(of: first, at: time + dt)
            XCTAssertLessThan(hypot(after.center.x - before.center.x, after.center.y - before.center.y), 0.003)
            XCTAssertEqual(before.opacity, after.opacity, accuracy: 0.001)
        }
        for outward in [true, false] {
            let start = outward ? first.emerge + C.fadeDuration : first.turn
            for step in 1..<100 {
                let time = start + C.rideDuration * Double(step) / 100
                let before = try XCTUnwrap(show.state(at: time - dt))
                let after = try XCTUnwrap(show.state(at: time + dt))
                let state = try XCTUnwrap(show.state(at: time))
                XCTAssertEqual(state.facingLeft, after.center.x < before.center.x, "Faces its actual travel")
            }
        }
    }

    func testTheFadeTravelsOnlyInsideTheOpening() throws {
        let show = performance()
        let first = try XCTUnwrap(show.appearance(at: reveal + 2))
        for fadingIn in [true, false] {
            let start = fadingIn ? first.emerge : first.back
            let end = fadingIn ? first.emerge + C.fadeDuration : first.gone
            var previous = C.state(of: first, at: start)
            for step in 1...100 {
                let state = C.state(of: first, at: start + (end - start) * Double(step) / 100)
                XCTAssertEqual(state.center.x, C.doorCenter.x, accuracy: 1e-9)
                XCTAssertLessThanOrEqual(state.center.y + 34.5, C.threshold)
                XCTAssertEqual(state.layer, .door)
                if fadingIn {
                    XCTAssertGreaterThan(state.opacity, previous.opacity)
                    XCTAssertGreaterThan(state.center.y, previous.center.y)
                } else {
                    XCTAssertLessThan(state.opacity, previous.opacity)
                    XCTAssertLessThan(state.center.y, previous.center.y)
                }
                previous = state
            }
        }
    }

    /// Opt-in trajectory evidence samples the production state, rather than a second path implementation.
    func testWriteSampledSpiralPreview() throws {
        guard let directory = ProcessInfo.processInfo.environment["AGENTLAND_SPIRAL_EVIDENCE"] else {
            throw XCTSkip("Set AGENTLAND_SPIRAL_EVIDENCE to write the sampled trajectory SVG")
        }
        // A future reference keeps fixed preview times outside the old-reveal catch-up path.
        let reference = Date(timeIntervalSinceReferenceDate: 4_000_000_000)
        let revealedAt = reference.addingTimeInterval(10)
        let show = C(reveal: 10, seed: C.seed(for: revealedAt))
        let first = try XCTUnwrap(show.appearance(at: 12))
        func path(from start: Double, to end: Double) -> String {
            (0...120).map { index in
                let state = C.state(of: first, at: start + (end - start) * Double(index) / 120)
                return "\(index == 0 ? "M" : "L")\(state.center.x),\(state.center.y)"
            }.joined(separator: " ")
        }
        let pixels = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(pixels, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(AgentLandTentArt.tone), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let tent = (pixels as Data).base64EncodedString()
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="1008" height="1188" viewBox="0 0 336 396">
        <rect width="336" height="396" fill="#F4F0E8"/>
        <style>text{font:8px system-ui;fill:#27313F}.arc{fill:none;stroke-width:2;stroke-linecap:round}</style>
        <text x="12" y="18">Production trajectory · rider centre · sampled at 121 points per arc</text>
        <ellipse cx="\(AgentLandClownMotion.orbitCenter.x)" cy="\(AgentLandClownMotion.orbitCenter.y)" rx="\(AgentLandClownMotion.orbitRadii.width)" ry="\(AgentLandClownMotion.orbitRadii.height)" fill="none" stroke="#A5ADB6" stroke-dasharray="3 3"/>
        <image href="data:image/png;base64,\(tent)" x="\(AgentLandTentArt.sceneRect.minX)" y="\(AgentLandTentArt.sceneRect.minY)" width="\(AgentLandTentArt.sceneRect.width)" height="\(AgentLandTentArt.sceneRect.height)" style="image-rendering:pixelated" opacity="0.38"/>
        <path class="arc" stroke="#2369A2" d="\(path(from: first.emerge + C.fadeDuration, to: first.join))"/>
        <path class="arc" stroke="#AC542A" d="\(path(from: first.turn, to: first.back))"/>
        <path class="arc" stroke="#27313F" stroke-dasharray="1 2" d="\(path(from: first.emerge, to: first.emerge + C.fadeDuration))"/>
        <line x1="\(C.doorCenter.x - 35)" y1="\(C.threshold)" x2="\(C.doorCenter.x + 35)" y2="\(C.threshold)" stroke="#27313F" stroke-dasharray="2 2"/>
        <circle cx="\(C.doorCenter.x)" cy="\(C.doorCenter.y)" r="2.5" fill="#27313F"/>
        <circle cx="\(C.doorPoint.x)" cy="\(C.doorPoint.y)" r="2.5" fill="#2369A2"/>
        <circle cx="\(C.returnPoint.x)" cy="\(C.returnPoint.y)" r="2.5" fill="#AC542A"/>
        <text x="12" y="345" fill="#2369A2">Blue: crosses the opening down-left, curls onto the near-left ring.</text>
        <text x="12" y="359" fill="#AC542A">Rust: curls up-left from the ring, turns right into the opening.</text>
        <text x="12" y="373">Both ring tangents match velocity; fades travel 10 pt inside opening.</text>
        <text x="12" y="387">The wheel crossing the threshold exposes the rider progressively.</text>
        </svg>
        """
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try svg.write(to: folder.appendingPathComponent("spiral-trajectory.svg"), atomically: true, encoding: .utf8)
        func samples(from start: Double, to end: Double) -> [[String: Any]] {
            let count = Int(ceil((end - start) * 30))
            return (0...count).map { step in
                let time = min(end, start + Double(step) / 30)
                let state = C.state(of: first, at: time)
                return ["time": time, "x": state.center.x, "y": state.center.y,
                        "facingLeft": state.facingLeft, "layer": String(describing: state.layer),
                        "opacity": state.opacity, "portalEdge": state.portalEdge, "design": state.design,
                        "frame": AgentLandClownMotion.frameIndex(at: time)]
            }
        }
        let geometry = try XCTUnwrap(AgentLandTentArt.geometry)
        let json: [String: Any] = ["threshold": C.threshold, "doorCenter": ["x": C.doorCenter.x, "y": C.doorCenter.y],
                                  "doorBounds": ["x": AgentLandTentArt.sceneRect.minX + CGFloat(geometry.minX) * AgentLandTentArt.pointsPerPixel,
                                                 "y": AgentLandTentArt.sceneRect.minY + CGFloat(geometry.minY) * AgentLandTentArt.pointsPerPixel,
                                                 "width": CGFloat(geometry.maxX - geometry.minX + 1) * AgentLandTentArt.pointsPerPixel,
                                                 "height": CGFloat(geometry.maxY - geometry.minY + 1) * AgentLandTentArt.pointsPerPixel],
                                  "outward": samples(from: first.emerge, to: first.join + 0.7),
                                  "inward": samples(from: first.turn - 0.7, to: first.gone)]
        try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appendingPathComponent("trajectory.json"))
    }

    /// Every 40–90 s it stops throwing, finishes its catches, rides back in at the pass by the door and fades
    /// out; the doorway stays empty 4–10 s; the next design (never the same one) comes out.
    func testItGoesBackInAndTheNextDesignComesOut() throws {
        let show = performance()
        let appearances = show.appearances(through: horizon)
        XCTAssertGreaterThan(appearances.count, 30)
        let lap = AgentLandClownMotion.orbitPeriod
        for (index, appearance) in appearances.enumerated() {
            if index + 1 < appearances.count {
                let next = appearances[index + 1]
                let gap = next.emerge - appearance.gone
                XCTAssertTrue((4...(10 + AgentLandClownMotion.beat)).contains(gap), "The doorway stays empty 4-10 s: \(gap)")
                XCTAssertNotEqual(next.design, appearance.design, "Never the same design twice in a row")
                XCTAssertNil(show.state(at: appearance.gone + gap / 2))
            }
            guard appearance.act == .ring else { continue }
            XCTAssertTrue((40...90).contains(appearance.stop - appearance.join), "Stays 40-90 s: \(appearance.stop - appearance.join)")
            let laps = (appearance.turn - appearance.join - C.returnTravel) / lap
            XCTAssertEqual(laps, laps.rounded(), accuracy: 1e-6, "Leaves at the inward spiral's tangency point")
            XCTAssertLessThan(appearance.turn - appearance.stop, lap + 3, "Leaves at the first pass after its last catch")
            // Its catches are finished: from the turn on, nothing is in its hands or in the air.
            for time in stride(from: appearance.turn, to: appearance.gone, by: 1.0 / 30) {
                XCTAssertTrue(show.balls(at: time).isEmpty, "Balls out at \(time), after the turn at \(appearance.turn)")
            }
            let entering = try XCTUnwrap(show.state(at: appearance.turn + C.rideDuration / 2))
            XCTAssertEqual(entering.layer, .door)
            XCTAssertLessThan(entering.center.y, C.returnPoint.y, "Riding back toward the door")
            let fading = try XCTUnwrap(show.state(at: appearance.gone - 0.05))
            XCTAssertEqual(fading.center.x, C.doorCenter.x, accuracy: 1e-9)
            XCTAssertLessThan(fading.center.y, C.doorCenter.y, "Still moving inside as it disappears")
            XCTAssertLessThan(fading.opacity, 1)
            XCTAssertNil(show.state(at: appearance.gone + 0.01), "Gone")
        }
        XCTAssertEqual(Set(appearances.prefix(6).map(\.design)), Set(0..<6), "Every design comes out, shuffled")
    }

    /// The clown juggles only on the ring: the first ball comes out of its pocket once it has joined, and
    /// balls are only ever thrown inside its performance.
    func testItJugglesOnlyOnTheRing() throws {
        let show = performance(seed: 3)
        for appearance in show.appearances(through: 900) {
            for time in stride(from: appearance.emerge, to: appearance.join, by: 1.0 / 30) {
                XCTAssertTrue(show.balls(at: time).isEmpty, "No balls before joining the ring")
            }
            let juggled = stride(from: appearance.join, to: appearance.stop, by: 0.1).map { show.balls(at: $0).filter { !$0.isDropped }.count }
            XCTAssertTrue((3...4).contains(juggled.max() ?? 0), "A cascade stays within three or four balls")
            XCTAssertEqual(juggled.first, 0, "Empty hands at the join")
            // A ball comes out at the first catch after the join; after a missed catch only two are up for a while.
            XCTAssertTrue(juggled.prefix(15).contains { $0 >= 2 }, "Balls come out of the pocket at once")
            XCTAssertTrue(juggled.contains { $0 >= 3 }, "The cascade fills")
        }
    }

    /// Each performance juggles on its own clock, whole ride loops from the circus clock (the palms match the
    /// frames shown), placed so the ring and the juggling line up as on the circus clock's reference lap:
    /// the title's clearance, measured on that lap, holds for every performance.
    func testThePerformanceKeepsTheReferenceLapsTiming() throws {
        let show = performance(seed: 11)
        for appearance in show.appearances(through: horizon) where appearance.act == .ring {
            let loops = appearance.offset / 1.2
            XCTAssertEqual(loops, loops.rounded(), accuracy: 1e-6, "Whole ride loops")
            for time in stride(from: appearance.join, to: appearance.turn, by: 0.7) {
                let state = try XCTUnwrap(show.state(at: time))
                let reference = AgentLandClownMotion.orbitPosition(at: time + appearance.offset)
                XCTAssertEqual(state.center.x, reference.x, accuracy: 1e-6)
                XCTAssertEqual(state.center.y, reference.y, accuracy: 1e-6)
                XCTAssertEqual(state.facingLeft, AgentLandClownMotion.isFacingLeft(at: time + appearance.offset))
            }
        }
    }

    /// A dropped ball lands where the clown actually is and rolls in front of or behind the tent from there.
    func testDroppedBallsLandUnderTheClown() throws {
        let show = performance(seed: 5)
        var landings = 0
        for appearance in show.appearances(through: 1800) {
            let design = AgentLandClownArtwork.designs[appearance.design]
            for bounce in design.juggling.performance(in: appearance.juggling).bounces {
                // The landing on this performance's clock, if it falls inside it.
                let landing = bounce.start - appearance.offset
                guard landing < appearance.stop, landing > appearance.join + 3 else { continue }
                let state = try XCTUnwrap(show.state(at: landing))
                let rolling = show.groundBalls(at: landing + 0.01)
                XCTAssertFalse(rolling.isEmpty, "A missed ball is on the ground")
                XCTAssertTrue(rolling.contains { abs($0.point.y - (state.center.y + 45 * 0.75)) < 6 }, "It lands at the clown's wheel")
                XCTAssertTrue(rolling.allSatisfy { $0.front == (state.layer != .behind) })
                landings += 1
            }
        }
        XCTAssertGreaterThan(landings, 3)
    }
}
