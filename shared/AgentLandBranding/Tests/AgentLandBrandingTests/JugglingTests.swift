import CoreGraphics
import XCTest
@testable import AgentLandBranding

final class JugglingTests: XCTestCase {
    private struct ThrowSignature: Equatable {
        let slot: Int, tint: Int
        let start: Double, throwTime: Double, catchTime: Double, end: Double
        let spin: CGFloat, heldAngle: CGFloat, dx: CGFloat, dy: CGFloat
        let dropped: Bool
        init(_ span: AgentLandJuggling.Span) {
            slot = span.slot; tint = span.tint; start = span.start; throwTime = span.throwTime
            catchTime = span.catchTime; end = span.end; spin = span.spinRate
            heldAngle = span.heldAngle; dx = span.velocity.dx; dy = span.velocity.dy; dropped = span.dropped
        }
    }
    private let rig = AgentLandJuggling.Rig(
        rightPalm: (0..<72).map { CGPoint(x: 37 + CGFloat($0 % 6), y: 58) },
        leftPalm: (0..<72).map { CGPoint(x: 58 - CGFloat($0 % 6), y: 58) })

    private func performance(seed: UInt64) -> AgentLandJuggling.Performance {
        AgentLandJuggling(rig: rig, seed: seed).performance(in: .init(start: 0, stop: 90, seed: seed))
    }

    func testTheSameSeedReproducesThePerformanceAndDifferentSeedsVaryIt() {
        let a = performance(seed: 41), b = performance(seed: 41), c = performance(seed: 42)
        XCTAssertEqual(a.spans.map(ThrowSignature.init), b.spans.map(ThrowSignature.init))
        XCTAssertEqual(a.stretches, b.stretches)
        XCTAssertNotEqual(a.spans.map(ThrowSignature.init), c.spans.map(ThrowSignature.init))
    }

    func testStretchesAreTwelveToThirtyBeatsAndAlternateThreeAndFour() {
        let stretches = performance(seed: 7).stretches
        XCTAssertGreaterThan(stretches.count, 2)
        for stretch in stretches {
            XCTAssertTrue((3...4).contains(stretch.balls))
            XCTAssertTrue((12...30).contains(stretch.endBeat - stretch.startBeat))
        }
        for pair in zip(stretches, stretches.dropFirst()) { XCTAssertNotEqual(pair.0.balls, pair.1.balls) }
    }

    func testWindowStartsEmptyAndFinishesWithEveryBallPutAway() {
        let juggling = AgentLandJuggling(rig: rig, seed: 9)
        let window = AgentLandJuggling.Window(start: 14, stop: 47, seed: 9)
        XCTAssertTrue(juggling.balls(at: window.start, window: window).isEmpty)
        let last = juggling.lastCatch(in: window)
        XCTAssertGreaterThanOrEqual(last, window.stop)
        XCTAssertTrue(juggling.balls(at: last + 0.001, window: window).isEmpty)
    }

    func testMissesAreSpacedAndRecoverWithinTwoBeats() {
        let juggling = AgentLandJuggling(rig: rig, seed: 3)
        let window = AgentLandJuggling.Window(start: 0, stop: 90, seed: 3)
        let performance = juggling.performance(in: window)
        let misses = performance.spans.filter(\.dropped)
        XCTAssertFalse(misses.isEmpty)
        for pair in zip(misses, misses.dropFirst()) {
            XCTAssertGreaterThanOrEqual(pair.1.catchTime - pair.0.catchTime, 40 * juggling.beat - 1e-6)
        }
        XCTAssertTrue(misses.allSatisfy { $0.catchTime >= window.start + 12 * juggling.beat })
        let pockets = Dictionary(grouping: performance.spans, by: \.slot).values.compactMap { $0.min { $0.start < $1.start } }
        for miss in misses where miss.catchTime + 2 * juggling.beat < window.stop {
            let replacement = pockets.filter { $0.start >= miss.catchTime }.min { $0.start < $1.start }
            if (replacement?.start ?? .infinity) > miss.catchTime + 2 * juggling.beat + 1e-6 {
                print("Delayed replacement: seed 3, window 0...90, miss slot \(miss.slot), catch \(miss.catchTime)")
                for span in performance.spans where span.throwTime >= miss.catchTime - 0.5 && span.throwTime <= miss.catchTime + 1 {
                    print("slot \(span.slot), held \(span.start), throw \(span.throwTime), catch \(span.catchTime), dropped \(span.dropped)")
                }
            }
            XCTAssertLessThanOrEqual(replacement?.start ?? .infinity, miss.catchTime + 2 * juggling.beat + 1e-6)
        }
    }

    func testVisibleBallsNeverShareTints() {
        let juggling = AgentLandJuggling(rig: rig, seed: 21)
        let window = AgentLandJuggling.Window(start: 0, stop: 100, seed: 21)
        for time in stride(from: window.start, to: window.stop, by: 1.0 / 60.0) {
            let balls = juggling.balls(at: time, window: window)
            let ground = juggling.groundBalls(at: time, window: window, place: { _ in .init(center: .zero, facingLeft: false, behind: false) })
            let tints = balls.map(\.tint) + ground.map(\.tint)
            XCTAssertEqual(Set(tints).count, tints.count)
        }
    }

    func testAContinuingBallKeepsItsSlotTintAndHeldAngleAcrossACatch() {
        let juggling = AgentLandJuggling(rig: rig, seed: 31)
        let spans = juggling.performance(in: .init(start: 0, stop: 100, seed: 31)).spans
        var found = false
        for group in Dictionary(grouping: spans, by: \.slot).values {
            for pair in zip(group.sorted { $0.start < $1.start }, group.sorted { $0.start < $1.start }.dropFirst()) {
                guard pair.1.start <= pair.0.catchTime + 2 * juggling.beat + 1e-6 else { continue }
                found = true
                XCTAssertEqual(pair.0.tint, pair.1.tint)
                XCTAssertEqual(pair.0.slot, pair.1.slot)
                XCTAssertEqual(pair.1.start, pair.0.catchTime, accuracy: 1e-6)
                XCTAssertEqual(juggling.angle(pair.0, at: pair.0.catchTime), pair.1.heldAngle, accuracy: 1e-6)
            }
        }
        XCTAssertTrue(found, "The seeded performance contains a continuing ball")
    }

    func testHeldBallsFreezeSpinAndFlightsAdvanceIt() {
        let juggling = AgentLandJuggling(rig: rig, seed: 5)
        let window = AgentLandJuggling.Window(start: 0, stop: 100, seed: 5)
        for span in juggling.performance(in: window).spans {
            XCTAssertEqual(AgentLandJuggling.spinFrame(angle: juggling.angle(span, at: span.start)),
                           AgentLandJuggling.spinFrame(angle: juggling.angle(span, at: min(span.throwTime, span.start + 0.1))))
            if span.velocity.dx != 0 {
                XCTAssertTrue((1.0...2.4).contains(abs(span.spinRate)))
                XCTAssertEqual(span.spinRate.sign, span.velocity.dx.sign)
                XCTAssertNotEqual(juggling.angle(span, at: span.throwTime), juggling.angle(span, at: span.throwTime + 0.2))
            }
        }
    }

    func testSpinRoundsAfterMultiplyingTurnsByEight() {
        XCTAssertEqual(AgentLandJuggling.spinFrame(angle: 0.125 * 2 * .pi), 1)
        XCTAssertEqual(AgentLandJuggling.spinFrame(angle: -0.125 * 2 * .pi), 7)
        XCTAssertEqual(AgentLandJuggling.spinFrame(angle: 1.0 * 2 * .pi), 0)
    }

    func testActiveCountRemainsThreeOrFourOutsideStartupAndBriefRecovery() {
        for seed in 0..<8 {
            let juggling = AgentLandJuggling(rig: rig, seed: UInt64(seed))
            let window = AgentLandJuggling.Window(start: 5.123, stop: 55.123, seed: UInt64(seed))
            let misses = juggling.performance(in: window).spans.filter(\.dropped)
            for time in stride(from: window.start + 4 * juggling.beat, to: window.stop - 4 * juggling.beat, by: 1.0 / 60) {
                let count = juggling.balls(at: time, window: window).filter { !$0.isDropped }.count
                XCTAssertLessThanOrEqual(count, 4, "seed \(seed), time \(time)")
                let recovering = misses.contains { time >= $0.catchTime && time <= $0.catchTime + 2 * juggling.beat }
                if !recovering { XCTAssertGreaterThanOrEqual(count, 3, "seed \(seed), time \(time)") }
            }
        }
    }

    func testEveryPocketBallHasTheHalfBeatLeadIncludingReplacements() {
        let juggling = AgentLandJuggling(rig: rig, seed: 3)
        let spans = juggling.performance(in: .init(start: 5.123, stop: 100, seed: 3)).spans
        let pockets = Dictionary(grouping: spans, by: \.slot).values.compactMap { $0.min { $0.start < $1.start } }
        XCTAssertGreaterThan(pockets.count, 4)
        for pocket in pockets { XCTAssertEqual(pocket.throwTime - pocket.start, 0.5 * juggling.beat, accuracy: 1e-6) }
    }

    func testReturnPlanningBoundContainsEverySeededCatchAndDrop() {
        for design in AgentLandClownArtwork.designs {
            for seed in 0..<10 {
                let window = AgentLandJuggling.Window(start: 3.123, stop: 50.456, seed: UInt64(seed))
                XCTAssertLessThanOrEqual(design.juggling.lastCatch(in: window), design.juggling.runOutLimit(in: window))
            }
        }
    }
}
