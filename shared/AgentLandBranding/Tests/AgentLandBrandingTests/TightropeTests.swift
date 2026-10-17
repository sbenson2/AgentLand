import CoreGraphics
import XCTest
@testable import AgentLandBranding

/// The tightrope act: on about one reveal (Home load) in three the PixelLab rig is the stage from the first frame,
/// and every clown crosses the rope four times, juggling, its wheel rolling as far as it pedals and sometimes
/// rolling back in the middle, the rope giving under it and the rider swaying.
final class TightropeTests: XCTestCase {
    private typealias C = AgentLandCircusChoreography
    private let horizon = 7200.0

    private func ropeActs(seed: UInt64 = 7) -> (C, [C.Appearance]) {
        let show = C(reveal: 12.34, seed: seed, forcesRope: true)
        return (show, show.appearances(through: horizon).filter { $0.act != .ring })
    }

    func testTheRigIsPackagedInTheRidersTones() throws {
        let image = try XCTUnwrap(AgentLandTightropeArt.image)
        XCTAssertEqual(image.width, 152)
        XCTAssertEqual(image.height, 96)
        XCTAssertNotNil(AgentLandTightropeArt.nightImage, "Every pixel is one of the day tones, so it recolours")
        let rig = try XCTUnwrap(AgentLandTightropeArt.geometry)
        XCTAssertEqual(rig.ropeRow, 14)
        XCTAssertEqual(rig.ropeFreeStart, 29)
        XCTAssertEqual(rig.ropeFreeEnd, 122)
        let layout = AgentLandTightropeArt.layout
        XCTAssertEqual(layout.frame.midX, 168, accuracy: 1e-9, "Centred on the tent")
        XCTAssertEqual(layout.frame.width, 152 * 2.625, accuracy: 1e-9, "The tent's pixel size")
        XCTAssertLessThanOrEqual(layout.frame.width, AgentLandCircusLoading.stageSize.width, "Inside the work surfaces' stage")
        XCTAssertEqual(layout.frame.minY + CGFloat(rig.ground + 1) * 2.625, AgentLandTightropeArt.floorY, accuracy: 1e-9)
        XCTAssertEqual(layout.ropeTop, layout.riderY + (94 - 48) * 0.75, accuracy: 1e-9)
        XCTAssertEqual(layout.anchors.lowerBound, layout.frame.minX + 29 * 2.625, accuracy: 1e-9)
        XCTAssertEqual(layout.anchors.upperBound, layout.frame.minX + 123 * 2.625, accuracy: 1e-9)
        // The poles keep every pixel of the rig but the free run, which the scene draws bent.
        let rigPixels = try XCTUnwrap(AgentLandClownArtwork.rgbaBytes(image))
        let poles = try XCTUnwrap(AgentLandClownArtwork.rgbaBytes(try XCTUnwrap(AgentLandTightropeArt.poles)))
        XCTAssertNotNil(AgentLandTightropeArt.nightPoles)
        for y in 0..<96 {
            for x in 0..<152 {
                let offset = (y * 152 + x) * 4
                if y == 14 && (29...122).contains(x) {
                    XCTAssertEqual(rigPixels[offset + 3], 255, "The rig's rope at \(x)")
                    XCTAssertEqual(poles[offset + 3], 0, "No rope in the poles at \(x)")
                } else {
                    XCTAssertEqual(Array(poles[offset..<offset + 4]), Array(rigPixels[offset..<offset + 4]), "(\(x), \(y))")
                }
            }
        }
    }

    /// About one reveal in three is on the tightrope, every performance of it; the others never are. The stage is
    /// the reveal's, so Home and the landing, which share it, show the same one.
    func testAboutOneRevealInThreeIsOnTheTightrope() throws {
        let reveal = 12.34
        var roped = 0
        let seeds = UInt64(1)...300
        for seed in seeds {
            let show = C(reveal: reveal, seed: seed)
            XCTAssertEqual(C(reveal: reveal, seed: seed).tightrope, show.tightrope, "The reveal's own draw")
            let appearances = show.appearances(through: 500)
            XCTAssertGreaterThan(appearances.count, 3)
            XCTAssertTrue(appearances.allSatisfy { ($0.act != .ring) == show.tightrope }, "One stage for the whole reveal")
            if show.tightrope {
                roped += 1
                XCTAssertGreaterThanOrEqual(try XCTUnwrap(appearances.first).join, reveal + C.ropeEntranceDelay - 1e-9,
                                            "The first clown keeps its entrance pause")
                // The rig stays between clowns: the rope is empty, the tent never comes back.
                for (one, next) in zip(appearances, appearances.dropFirst()) {
                    for time in stride(from: one.back, to: next.join, by: 0.5) {
                        XCTAssertNil(show.state(at: time))
                    }
                }
            }
        }
        XCTAssertEqual(Double(roped) / Double(seeds.count), 1.0 / 3, accuracy: 0.08, "\(roped) of \(seeds.count)")
        let acts = ropeActs().1
        XCTAssertTrue(acts.contains { $0.act == .rope(turning: true) })
        XCTAssertTrue(acts.contains { $0.act == .rope(turning: false) })
    }

    /// `-AgentLandCircusAct tightrope` puts every reveal on the rope.
    func testTheLaunchArgumentPutsEveryRevealOnTheRope() throws {
        XCTAssertFalse(C.launchForcesRope, "Tests are not launched with it")
        for seed in UInt64(1)...20 {
            let show = C(reveal: 12.34, seed: seed, forcesRope: true)
            XCTAssertTrue(show.tightrope)
            let appearances = show.appearances(through: 600)
            XCTAssertTrue(appearances.allSatisfy { $0.act != .ring })
            XCTAssertEqual(try XCTUnwrap(appearances.first).join, 12.34 + C.ropeEntranceDelay, accuracy: AgentLandClownMotion.beat,
                           "The first comes out after its entrance pause")
        }
    }

    /// The legs a moment falls in.
    private func leg(of act: C.Appearance, at time: Double) -> C.Appearance.RopeLeg? {
        let frame = C.ropeFrame(at: time)
        return act.ropeLegs.last { Double($0.start) <= frame }
    }

    private func wheel(_ state: C.State) -> CGFloat { state.center.x + (state.facingLeft ? C.ropeHubOffset : -C.ropeHubOffset) }

    /// The rig is already present, the clown fades in at the rope's left end and crosses four times with its
    /// wheel on the rope, rolling exactly as far as it pedals, then fades out at the left end.
    func testTheActReplacesTheTentAndCrossesTheRope() throws {
        let (show, acts) = ropeActs()
        XCTAssertGreaterThan(acts.count, 10)
        let layout = AgentLandTightropeArt.layout
        let frame = AgentLandClownMotion.frameDuration, beat = AgentLandClownMotion.beat
        let perFrame = AgentLandClownMotion.wheelSpeed * CGFloat(frame)
        let left = layout.middle - C.ropeLength / 2, right = layout.middle + C.ropeLength / 2
        for act in acts.prefix(30) {
            guard case let .rope(turning) = act.act else { continue }
            XCTAssertEqual(act.ropeRuns.count, C.ropeCrossings)
            for runs in act.ropeRuns {
                XCTAssertEqual(runs.reduce(0, +), C.ropeCrossingBeats, "Every crossing nets the rope's length: \(runs)")
                let reached = runs.indices.map { runs[...$0].reduce(0, +) }
                XCTAssertTrue(reached.allSatisfy { (0...C.ropeCrossingBeats).contains($0) }, "On the rope: \(runs)")
            }
            let beats = act.ropeRuns.joined().reduce(0) { $0 + abs($1) } + (turning ? 3 * C.ropeHopBeats : 0)
            XCTAssertEqual(act.emerge, act.join)
            XCTAssertEqual(act.back - act.join, Double(beats) * beat, accuracy: 1e-9)
            XCTAssertEqual(act.gone, act.back)
            XCTAssertNil(show.state(at: act.join - 0.01), "The rope is empty before it comes out")
            var previous: (time: Double, state: C.State)?
            for time in stride(from: act.join, to: act.back, by: 1.0 / 60) {
                let state = try XCTUnwrap(show.state(at: time)), bend = try XCTUnwrap(state.bend)
                let current = try XCTUnwrap(leg(of: act, at: time))
                XCTAssertEqual(state.layer, .front)
                XCTAssertEqual(state.facingLeft, current.facingLeft)
                XCTAssertEqual(current.facingLeft, turning && current.crossing % 2 == 1, "Turning faces its way; otherwise it faces right")
                XCTAssertEqual(bend.contact, wheel(state), accuracy: 1e-9)
                XCTAssertEqual(state.center.y + (94 - 48) * 0.75 + state.lift, layout.ropeTop + bend.drop(at: wheel(state)),
                               accuracy: 1e-9, "The wheel on the bent rope, or hopping above it")
                if !current.hop { XCTAssertEqual(state.lift, 0, accuracy: 0.5, "Only off the rope while hopping") }
                XCTAssertGreaterThanOrEqual(wheel(state), left - 1e-6)
                XCTAssertLessThanOrEqual(wheel(state), right + 1e-6)
                if let previous, leg(of: act, at: previous.time) == current {
                    // The tyre never slips: the wheel rolls as far as the pedals turn, never faster than its speed.
                    let pedalled = AgentLandClownMotion.pedalPosition(time / frame, reversals: act.reversals)
                        - AgentLandClownMotion.pedalPosition(previous.time / frame, reversals: act.reversals)
                    let rolled = wheel(state) - wheel(previous.state)
                    let carried = current.hop ? 0 : CGFloat(current.facingLeft ? -pedalled : pedalled) * perFrame
                    XCTAssertEqual(rolled, carried, accuracy: 1e-6, "In the air the wheel spins without carrying it")
                    XCTAssertLessThanOrEqual(abs(rolled) / CGFloat(time - previous.time), AgentLandClownMotion.wheelSpeed + 1e-6)
                }
                previous = (time, state)
            }
            let start = C.state(of: act, at: act.join), end = C.state(of: act, at: act.back)
            XCTAssertEqual(wheel(start), left, accuracy: 1e-9)
            XCTAssertEqual(wheel(end), left, accuracy: 1e-9, "Four crossings end at the left end")
            // Turning hops round over the end; ridden backward it eases to a stop just short of it.
            let arriving = try XCTUnwrap(act.ropeLegs.last { $0.crossing == 0 && !$0.hop })
            let leaving = try XCTUnwrap(act.ropeLegs.first { $0.crossing == 1 })
            let arrival = C.state(of: act, at: Double(arriving.end) * frame - 1e-9)
            let departure = C.state(of: act, at: Double(leaving.start) * frame + 1e-9)
            XCTAssertEqual(wheel(arrival), right, accuracy: turning ? 1e-6 : 3)
            XCTAssertEqual(wheel(departure), wheel(arrival), accuracy: turning ? 1e-6 : 3, "It turns round over the wheel")
            XCTAssertEqual(start.opacity, 0, accuracy: 1e-9)
            XCTAssertEqual(C.state(of: act, at: act.join + C.ropeFade).opacity, 1, accuracy: 1e-9)
            XCTAssertEqual(end.opacity, 0, accuracy: 1e-9)
            XCTAssertNil(show.state(at: act.back + 0.01))
            // It juggles once it has faded in and has caught every ball before it fades out.
            for time in stride(from: act.join, to: act.join + C.ropeFade, by: 1.0 / 60) {
                XCTAssertTrue(show.balls(at: time).isEmpty)
            }
            let juggled = stride(from: act.join, to: act.stop, by: 0.1).map { show.balls(at: $0).filter { !$0.isDropped }.count }
            XCTAssertTrue(juggled.contains { $0 >= 3 }, "The cascade fills on the rope")
            for time in stride(from: act.turn, to: act.back, by: 1.0 / 60) {
                XCTAssertTrue(show.balls(at: time).isEmpty, "Balls out at \(time), fading from \(act.turn)")
            }
        }
    }

    /// Turning round at an end is a hop: squashed down riding into the end, it springs up stretched and is its
    /// own shape again at the top, spins round in the air about its wheel, a quarter of its width edge-on, and
    /// lands facing the other way without a jump, squashing a little.
    func testTurningRoundIsAHopWithASpin() throws {
        let (_, acts) = ropeActs()
        let frame = AgentLandClownMotion.frameDuration
        XCTAssertTrue(acts.filter { $0.act == .rope(turning: false) }.allSatisfy { act in !act.ropeLegs.contains(where: \.hop) })
        var hops = 0
        for act in acts where act.act == .rope(turning: true) {
            let legs = act.ropeLegs.filter(\.hop)
            XCTAssertEqual(legs.count, C.ropeCrossings - 1)
            XCTAssertEqual(act.ropeTurns, legs.map(\.end), "It lands facing the other way")
            for leg in legs {
                let takeoff = Double(leg.start) * frame, landing = Double(leg.end) * frame, apex = (takeoff + landing) / 2
                XCTAssertEqual(landing - takeoff, Double(C.ropeHopBeats) * AgentLandClownMotion.beat, accuracy: 1e-9)
                let ground = C.state(of: act, at: takeoff - 0.5)
                XCTAssertEqual(ground.scale, CGSize(width: 1, height: 1), "Its own shape riding on")
                let crouched = C.state(of: act, at: takeoff - 0.02)
                XCTAssertEqual(crouched.lift, 0)
                XCTAssertLessThan(crouched.scale.height, 0.87, "Squashed down before the hop")
                XCTAssertGreaterThan(crouched.scale.width, 1, "and wider")
                let rising = C.state(of: act, at: takeoff + 0.08)
                XCTAssertGreaterThan(rising.scale.height, 1.05, "Stretched on the way up")
                XCTAssertGreaterThan(rising.lift, 0)
                let top = C.state(of: act, at: apex)
                XCTAssertEqual(top.scale.height, 1, accuracy: 1e-9, "Its own height at the top")
                XCTAssertEqual(top.lift, C.ropeHopHeight, accuracy: 1e-9)
                XCTAssertEqual(abs(top.scale.width), 0.25, accuracy: 0.01, "Edge-on halfway round, never gone")
                let wheel0 = wheel(C.state(of: act, at: takeoff))
                for time in stride(from: takeoff + 1e-4, to: landing - 1e-4, by: 1.0 / 60) {
                    let state = C.state(of: act, at: time)
                    XCTAssertEqual(wheel(state), wheel0, accuracy: 1e-9, "Over the same spot")
                    XCTAssertEqual(state.facingLeft, leg.facingLeft)
                    // It springs out of the squash in the first 0.06 s and is never squashed in the air after.
                    if time > takeoff + 0.06 { XCTAssertGreaterThanOrEqual(state.scale.height, 1 - 1e-9) }
                    XCTAssertGreaterThanOrEqual(abs(state.scale.width), 0.24, "Always visible")
                }
                // Every sprite column lands where it was drawn the instant before: no jump on landing.
                let before = C.state(of: act, at: landing - 1e-6), after = C.state(of: act, at: landing + 1e-6)
                XCTAssertNotEqual(before.facingLeft, after.facingLeft)
                XCTAssertEqual(before.lift, 0, accuracy: 1e-3)
                XCTAssertEqual(after.scale.height, 1, accuracy: 1e-3, "It meets the rope at its own height")
                let landed = C.state(of: act, at: landing + 0.05)
                XCTAssertEqual(landed.scale.height, 0.9, accuracy: 1e-9, "A small squash on landing")
                XCTAssertGreaterThan(landed.scale.width, 1)
                XCTAssertEqual(landed.lift, 0)
                XCTAssertEqual(C.state(of: act, at: landing + C.ropeLanding + 0.01).scale, CGSize(width: 1, height: 1),
                               "Its own shape again")
                XCTAssertLessThan(abs(before.lean), 0.05, "Upright on landing")
                for column in stride(from: CGFloat(10), through: 86, by: 19) {
                    func x(_ state: C.State) -> CGFloat {
                        state.center.x + (state.facingLeft ? -1 : 1) * (-7 + (column - 41) * state.scale.width) * 0.75
                    }
                    XCTAssertEqual(x(before), x(after), accuracy: 0.01)
                }
                hops += 1
            }
        }
        XCTAssertGreaterThan(hops, 10)
    }

    /// About half the crossings roll back two to four beats somewhere in the middle of the rope, or rock back
    /// and forth, and then go on; the wheel really goes back the way it came.
    func testSomeCrossingsRollBackInTheMiddleOfTheRope() throws {
        let (_, acts) = ropeActs()
        let crossings = acts.flatMap(\.ropeRuns)
        let backing = crossings.filter { $0.count > 1 }
        XCTAssertEqual(Double(backing.count) / Double(crossings.count), 0.55, accuracy: 0.1, "\(backing.count) of \(crossings.count)")
        XCTAssertTrue(backing.contains { $0.count == 3 }, "Some roll back")
        XCTAssertTrue(backing.contains { $0.count == 5 }, "Some rock")
        for runs in backing {
            XCTAssertTrue((5...12).contains(runs[0]), "In the middle of the rope: \(runs)")
            XCTAssertTrue(runs.count == 3 ? (2...4).contains(-runs[1]) : runs[1...3] == [-1, 1, -1], "\(runs)")
        }
        let act = try XCTUnwrap(acts.first { $0.ropeRuns[0].count == 3 })
        let frame = AgentLandClownMotion.frameDuration, beat = AgentLandClownMotion.beat
        let backward = Double(act.ropeRuns[0][0]) * beat + act.join
        let before = C.state(of: act, at: backward - beat), after = C.state(of: act, at: backward + 2 * beat)
        XCTAssertLessThan(wheel(after), wheel(before), "Back toward the left end")
        XCTAssertTrue(act.reversals.contains(Int((backward / frame).rounded())))
    }

    /// The rope gives under the wheel, most in the middle, not at all on the platforms, and bounces; it runs
    /// unbroken from platform to platform, straight to the wheel from each side.
    func testTheRopeGivesUnderTheWheel() throws {
        let (show, acts) = ropeActs()
        let layout = AgentLandTightropeArt.layout
        var deepest: CGFloat = 0, middles: [CGFloat] = []
        for act in acts.prefix(6) {
            for time in stride(from: act.join, to: act.back, by: 1.0 / 30) {
                let state = try XCTUnwrap(show.state(at: time)), bend = try XCTUnwrap(state.bend)
                let along = C.ropeProgress(at: bend.contact)
                XCTAssertGreaterThanOrEqual(bend.depth, 0)
                deepest = max(deepest, bend.depth)
                if along == 0 || along == 1 { XCTAssertEqual(bend.drop(at: bend.contact), 0, "On a platform") }
                if abs(along - 0.5) < 0.05 { middles.append(bend.depth) }
                let columns = bend.columns()
                XCTAssertEqual(columns.first?.minX ?? 0, layout.anchors.lowerBound, accuracy: 1e-6)
                XCTAssertEqual(columns.last?.maxX ?? 0, layout.anchors.upperBound, accuracy: 1e-6)
                for (a, b) in zip(columns, columns.dropFirst()) {
                    XCTAssertEqual(a.maxX, b.minX, accuracy: 1e-6, "Unbroken")
                    XCTAssertLessThanOrEqual(abs(a.minY - b.minY), 1.5, "A smooth run, at most two rider pixels a step")
                }
                XCTAssertEqual(columns.map(\.minY).max() ?? 0, layout.ropeTop + bend.drop(at: bend.contact), accuracy: 1e-9,
                               "Lowest under the wheel")
            }
        }
        XCTAssertLessThanOrEqual(deepest, C.ropeSag * 1.5)
        let middle = middles.reduce(0, +) / CGFloat(max(1, middles.count))
        XCTAssertEqual(middle, C.ropeSag, accuracy: 1.5, "About the sag in the middle")
        XCTAssertGreaterThan((middles.max() ?? 0) - (middles.min() ?? 0), 1.5, "It bounces")
        XCTAssertEqual(AgentLandTightropeArt.Bend.straight.columns().count, 1, "At rest one straight run")
    }

    /// The rider sways as it balances and leans hard the new way just before every reversal: back before it
    /// rolls back, forward before it rides on.
    func testTheRiderSwaysAndLeansIntoEveryReversal() throws {
        let (show, acts) = ropeActs()
        let frame = AgentLandClownMotion.frameDuration
        var leans: [Double] = [], checked = 0
        for act in acts.prefix(8) {
            for time in stride(from: act.join, to: act.back, by: 1.0 / 60) {
                let lean = try XCTUnwrap(show.state(at: time)).lean
                XCTAssertLessThanOrEqual(abs(lean), 9)
                leans.append(lean)
            }
            for (before, after) in zip(act.ropeLegs, act.ropeLegs.dropFirst()) where before.pedal != after.pedal {
                let lean = C.state(of: act, at: Double(after.start) * frame - 0.12).lean
                if after.pedal < 0 { XCTAssertLessThan(lean, -1, "Leans back before rolling back") }
                else { XCTAssertGreaterThan(lean, 1, "Leans forward before riding on") }
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 10)
        let mean = leans.reduce(0, +) / Double(leans.count)
        let spread = (leans.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(leans.count)).squareRoot()
        XCTAssertGreaterThan(spread, 1, "It sways")
        XCTAssertTrue(show.appearances(through: horizon).filter { $0.act == .ring }.allSatisfy { act in
            stride(from: act.join, to: act.turn, by: 1).allSatisfy { C.state(of: act, at: $0).lean == 0 && C.state(of: act, at: $0).bend == nil }
        }, "On the ring it neither leans nor bends a rope")
    }

    /// At every reversal (each end ridden backward, every roll back) the pedalling eases to a stop and back
    /// without skipping a frame, and every held ball sits on the palm of the frame shown, in a hand that frame
    /// draws closed.
    func testEveryReversalKeepsTheBallsInClosedHands() throws {
        let (show, acts) = ropeActs()
        let frame = AgentLandClownMotion.frameDuration
        var checked = 0, eased = 0
        // Turning acts reverse only where they roll back.
        let picked = acts.filter { $0.act == .rope(turning: false) }.prefix(2)
            + acts.filter { $0.act == .rope(turning: true) && !$0.reversals.isEmpty }.prefix(2)
        XCTAssertEqual(picked.count, 4)
        for act in picked {
            let design = AgentLandClownArtwork.designs[act.design]
            let juggling = design.juggling
            // The hands the ride frames draw closed: those holding a ball in an ordinary forward performance.
            var closed: [AgentLandJuggling.Hand: Set<Int>] = [.right: [], .left: []]
            let forward = AgentLandJuggling.Window(start: 0, stop: 60, seed: 1)
            for span in juggling.performance(in: forward).spans where span.start >= 20 && span.throwTime < 50 {
                guard let hand = span.holder else { continue }
                let frames = Int((span.start / frame).rounded())..<Int((span.throwTime / frame).rounded())
                closed[hand, default: []].formUnion(frames.map { $0 % 72 })
            }
            XCTAssertEqual(closed[.right]?.count, 24, "Two holds of 12 frames per ride loop")
            XCTAssertEqual(closed[.left]?.count, 24)
            let first = Int((act.join / frame).rounded())
            var previous = C.rideFrame(of: act, at: (Double(first) + 0.5) * frame, frameCount: 72)
            let window = act.juggling
            let spans = juggling.performance(in: window).spans
            for step in (first + 1)..<Int((act.back / frame).rounded()) {
                let time = (Double(step) + 0.5) * frame
                let shown = C.rideFrame(of: act, at: time, frameCount: 72)
                let delta = ((shown - previous) % 72 + 72) % 72
                XCTAssertTrue([0, 1, 71].contains(delta), "At most one frame forward or back at \(step)")
                let nearest = act.reversals.map { abs($0 - step) }.min() ?? .max
                if nearest > AgentLandClownMotion.reversalEasing {
                    let current = try XCTUnwrap(leg(of: act, at: Double(step) * frame))
                    XCTAssertEqual(delta, current.pedal > 0 ? 1 : 71, "Pedalling \(current.pedal) at \(step)")
                } else if delta == 0 {
                    eased += 1
                }
                previous = shown
                for span in spans where time >= span.start && time < span.throwTime {
                    guard let hand = span.holder else { continue }
                    // One frame of slack where a hold starts or ends.
                    let near = [shown, (shown + 1) % 72, (shown + 71) % 72]
                    XCTAssertTrue(near.contains { closed[hand]?.contains($0) == true },
                                  "\(hand) holds a ball at step \(step) in frame \(shown), drawn open")
                    let palm = hand == .right ? design.juggling.rig.rightPalm[shown] : design.juggling.rig.leftPalm[shown]
                    let ball = juggling.position(span, at: time, reversals: window.reversals)
                    XCTAssertEqual(ball.x, palm.x + AgentLandJuggling.palmOffset.dx, accuracy: 1e-9)
                    XCTAssertEqual(ball.y, palm.y + AgentLandJuggling.palmOffset.dy, accuracy: 1e-9)
                    checked += 1
                }
            }
            _ = show
        }
        XCTAssertGreaterThan(checked, 2000)
        XCTAssertGreaterThan(eased, 0, "The wheel pauses as it turns round")
    }

    /// A ball dropped on the rope falls past the wheel to the floor and bounces and rolls there.
    func testADropFromTheRopeFallsToTheFloor() throws {
        var checked = 0
        for seed in UInt64(1)...40 where checked < 3 {
            let (show, acts) = ropeActs(seed: seed)
            for act in acts {
                let design = AgentLandClownArtwork.designs[act.design]
                for bounce in design.juggling.performance(in: act.juggling).bounces {
                    let state = C.state(of: act, at: bounce.start)
                    let released = try XCTUnwrap(show.groundBalls(at: bounce.start + 0.01).first { $0.slot == bounce.slot })
                    XCTAssertLessThan(abs(released.point.y - (state.center.y + 44 * 0.75)), 6, "It leaves at the wheel")
                    let placed = AgentLandJuggling.placed(bounce, at: state.placement, start: bounce.start)
                    XCTAssertGreaterThan(placed.fall, 0.3)
                    XCTAssertEqual(placed.contact.y, AgentLandTightropeArt.layout.floor, accuracy: 1e-9)
                    let landed = try XCTUnwrap(show.groundBalls(at: bounce.start + placed.fall + 0.005).first { $0.slot == bounce.slot })
                    XCTAssertEqual(landed.point.y, AgentLandTightropeArt.layout.floor, accuracy: 3)
                    // It bounces on the floor, never through it, and comes back to it; a ball dropped from high in a
                    // throw may still be hopping as it fades.
                    let floor = AgentLandJuggling.snapped(CGPoint(x: 0, y: AgentLandTightropeArt.layout.floor)).y
                    let after = stride(from: bounce.start + placed.fall + 0.05, to: placed.end, by: 1.0 / 60).compactMap { time in
                        show.groundBalls(at: time).first { $0.slot == bounce.slot }
                    }
                    XCTAssertTrue(after.allSatisfy { $0.point.y <= floor + 1e-9 && AgentLandJuggling.groundSpan.contains($0.point.x) })
                    XCTAssertTrue(after.suffix(60).contains { $0.point.y == floor }, "Back on the floor at the end")
                    XCTAssertTrue(show.groundBalls(at: placed.end + 0.01).allSatisfy { $0.slot != bounce.slot })
                    checked += 1
                }
            }
        }
        XCTAssertGreaterThan(checked, 0, "Some act drops a ball")
    }
}
