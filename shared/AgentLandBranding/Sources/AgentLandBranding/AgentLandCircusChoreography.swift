import CoreGraphics
import Foundation

/// The clown's performance on a work surface (Home, the empty-chat landing), a pure function of the circus
/// clock from the moment the surface is revealed. At the reveal a clown fades in inside the doorway, rides
/// out on an expanding spiral to the orbit and circles, juggling. After a seeded 40–90 s it throws
/// no more, finishes its catches, spirals inward through the doorway and disappears. The doorway stays
/// empty for a seeded 4–10 s, then the next design comes out: the designs are shuffled, never the same twice
/// in a row. The schedule is built lazily and kept, so an hour of performance is computed once.
///
/// About one reveal in three (one Home load in three) is on the tightrope instead, for every performance until
/// the next reveal: only the selected stage appears, from the first frame, and it stays. Each
/// clown fades in at the rope's left end and crosses four times, juggling, its wheel rolling exactly as far as
/// it pedals, then fades out at the left end; the rope stays empty until the next one. It either turns round
/// at each end, squashing down, hopping up stretched and spinning round in the air about its wheel, or keeps
/// facing right and rides the return crossings backward, pedalling backward. Some
/// crossings roll back a few beats in the middle of the rope, or rock back and forth, before going on; the
/// rope gives under the wheel and bounces, and the rider sways and leans into every change of direction.
/// `-AgentLandCircusAct tightrope` puts every reveal on the tightrope.
///
/// The ride frames stay on the circus clock. Each performance juggles on its own clock, the circus clock
/// moved by whole ride loops (1.2 s, so the palms still match the frames shown) and chosen so the orbit and
/// juggling line up exactly as on the circus clock's own lap. Each appearance gets a stable derived seed so
/// both Home and the landing render the same performance for the same reveal.
final class AgentLandCircusChoreography {
    /// Scene points: the clown's centre standing in the doorway, its wheel on the threshold.
    static let doorCenter = AgentLandTentArt.geometry?.doorCenter ?? CGPoint(x: 136.125, y: 240.0625)
    /// Read from the packaged opening: changing the tent keeps the wheel on its actual threshold.
    static let threshold: CGFloat = AgentLandTentArt.geometry?.threshold ?? 274.5625
    /// The doorway's near-side ring pass is the inward tangency; the outward curl joins farther left, high
    /// enough that its dip below the join shows. Separate tangencies let both arcs continue the clockwise
    /// ring without crossing a tent wall.
    static let returnAngle = acos((doorCenter.x - AgentLandClownMotion.orbitCenter.x) / AgentLandClownMotion.orbitRadii.width)
    static let doorAngle = returnAngle + 0.6
    static var doorPoint: CGPoint { AgentLandClownMotion.orbitPosition(angle: doorAngle) }
    static var returnPoint: CGPoint { AgentLandClownMotion.orbitPosition(angle: returnAngle) }
    /// A lower doorway can put the ring join closer to its threshold. Ensure the foreground edge has
    /// cleared the entire 72-point sprite, plus one sprite pixel, by that tangent rather than revealing
    /// the remaining upper pixels abruptly when `.door` becomes `.front`.
    private static let portalExposureRate: CGFloat = {
        let travel = max(0.75, doorPoint.y - doorCenter.y)
        let clearance = threshold - doorPoint.y + 36 + 0.75
        return max(72 / 34.5, clearance / travel)
    }()
    static let fadeDuration = 0.3
    static let fadeDepth: CGFloat = 10
    private static let portalSpeed: CGFloat = 40
    /// Five or more beats leave room to cross the threshold before curling onto the ellipse, at about the
    /// wheel's speed: enough whole beats to cover the straight way from the opening to the join at the wheel's
    /// speed (five for the old left-side doorway, seven for the logo tent's front doorway, farther from its
    /// join). The join's phase still puts the juggling clock a whole number of ride loops away from the circus
    /// clock.
    static let rideBeats: Int = {
        let distance = hypot(doorPoint.x - doorCenter.x, doorPoint.y - doorCenter.y)
        return max(5, Int((distance / AgentLandClownMotion.wheelSpeed / CGFloat(AgentLandClownMotion.beat)).rounded(.up)))
    }()
    static let rideDuration: Double = {
        let beat = AgentLandClownMotion.beat
        let phase = (doorAngle / AgentLandClownMotion.orbitSpeed - fadeDuration).truncatingRemainder(dividingBy: beat)
        return (phase < 0 ? phase + beat : phase) + Double(rideBeats) * beat
    }()
    static var returnTravel: Double {
        (2 * .pi + returnAngle - doorAngle) / AgentLandClownMotion.orbitSpeed
    }
    static let stays: ClosedRange<Double> = 40...90
    static let gaps: ClosedRange<Double> = 4...10
    /// The share of reveals whose performances are all on the tightrope.
    static let ropeShare = 1.0 / 3.0
    /// A brief entrance pause before the first tightrope clown; the rig is already visible.
    static let ropeEntranceDelay = 0.6
    /// The clown fades in and out over this while riding the rope's left end.
    static let ropeFade = 0.4
    static let ropeCrossings = 4
    /// One crossing nets 18 beats of riding (5.4 s at the wheel's speed), the rope's length.
    static let ropeCrossingBeats = 18
    static let ropeCrossingFrames = ropeCrossingBeats * AgentLandClownMotion.framesPerBeat
    static var ropeCrossing: Double { Double(ropeCrossingFrames) * AgentLandClownMotion.frameDuration }
    static var ropeLength: CGFloat { CGFloat(ropeCrossing) * AgentLandClownMotion.wheelSpeed }
    /// The wheel's hub is 7 sprite pixels behind the sprite's centre (column 41 of 96), so turning round on
    /// the rope pivots on the wheel rather than sliding it along.
    static let ropeHubOffset: CGFloat = 7 * 0.75
    /// Turning round at an end is a hop: two beats in the air, the wheel spinning freely, the clown spinning
    /// round about its wheel and landing facing the other way. Whole beats keep every later reversal in the
    /// middle of a hold.
    static let ropeHopBeats = 2
    /// The hop's height in scene points: a ball's gravity over the hop's airtime.
    static var ropeHopHeight: CGFloat {
        let airtime = CGFloat(Double(ropeHopBeats) * AgentLandClownMotion.beat)
        return AgentLandJuggling.gravity * 0.75 * airtime * airtime / 8
    }
    /// Before the hop the clown squashes down over this, riding on into the end; it springs up stretched and is
    /// back to its own shape at the top of the hop.
    static let ropeCrouch = 0.2
    /// After landing it squashes a little and is back to its own shape after this.
    static let ropeLanding = 0.25
    /// Ridden backward, the pedalling reverses in the middle of a hold (a beat less a third, so 12 frames
    /// past a throw): counted backward from there, the frames close each hand exactly while the
    /// juggling holds a ball in it.
    static let ropeReversalPhase = AgentLandClownMotion.framesPerBeat
        - Int((AgentLandJuggling.dwellBeats * Double(AgentLandClownMotion.framesPerBeat) / 2).rounded())
    /// How far the rope gives under the wheel in its middle, standing still; less towards the platforms, as a
    /// taut rope does under one load.
    static let ropeSag: CGFloat = 11
    /// Pin either stage for layout review: `-AgentLandCircusAct tightrope|tent`.
    static let actArgument = "-AgentLandCircusAct"
    private static let launchAct: String? = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: actArgument), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }()
    static let launchForcesRope = launchAct == "tightrope"

    enum Layer: Equatable, Sendable {
        /// In the doorway or riding through it: drawn between the doorway's fill and the tent (seen through
        /// the opening) and progressively in front as its wheel crosses the threshold.
        case door
        /// On the near half of the orbit, in front of the tent.
        case front
        /// On the far half, behind the tent's depth mask.
        case behind
    }

    enum Act: Equatable, Sendable {
        /// Out of the doorway, round the ring and back in.
        case ring
        /// Back and forth on the tightrope, which stands in for the tent. Turning, the clown hops round at
        /// each end; otherwise it faces right throughout and rides the return crossings backward.
        case rope(turning: Bool)
    }

    /// On the ring the moments are as named. On the tightrope the clown comes out (fading in) at `emerge`,
    /// which is `join`, starts fading out at `turn` and is gone at `back`, which is `gone`.
    struct Appearance: Equatable, Sendable {
        /// Index into the choreography's designs.
        let design: Int
        /// Fades in inside the doorway, on a beat.
        let emerge: Double
        /// Reaches the orbit and starts juggling.
        let join: Double
        /// Throws no more; the last ball is caught before `turn`.
        let stop: Double
        /// Leaves the orbit at the inward spiral's tangency point.
        let turn: Double
        /// Back in the doorway; continues moving inside while fading out.
        let back: Double
        /// Gone.
        let gone: Double
        /// The juggling clock minus the circus clock: whole ride loops.
        let offset: Double
        /// Stable performance seed, derived from the choreography seed and appearance index.
        var seed: UInt64 = 0
        var act: Act = .ring
        /// On the tightrope, each crossing's riding in whole beats: positive runs ride on along the crossing,
        /// negative ones roll back. Every crossing nets `ropeCrossingBeats`.
        var ropeRuns: [[Int]] = []

        /// A stretch of the tightrope act between turns and pedal reversals.
        struct RopeLeg: Equatable, Sendable {
            /// Circus-clock frames.
            let start: Int, end: Int
            let facingLeft: Bool
            /// 1 pedalling forward (the ride frames count up), -1 backward.
            let pedal: Int
            /// The crossing it is part of.
            let crossing: Int
            /// In the air, turning round: the wheel spins freely and the clown stays over the end.
            var hop = false
        }

        /// The act's legs in order, from the join to the end of the last crossing.
        var ropeLegs: [RopeLeg] {
            guard case let .rope(turning) = act else { return [] }
            var frame = Int((join / AgentLandClownMotion.frameDuration).rounded())
            var legs: [RopeLeg] = []
            for (crossing, runs) in ropeRuns.enumerated() {
                let rightward = crossing % 2 == 0
                let facingLeft = turning && !rightward
                for run in runs where run != 0 {
                    let towardRight = rightward == (run > 0)
                    let end = frame + abs(run) * AgentLandClownMotion.framesPerBeat
                    legs.append(RopeLeg(start: frame, end: end, facingLeft: facingLeft,
                                        pedal: towardRight != facingLeft ? 1 : -1, crossing: crossing))
                    frame = end
                }
                if turning, crossing < ropeRuns.count - 1, let last = legs.last {
                    let end = frame + AgentLandCircusChoreography.ropeHopBeats * AgentLandClownMotion.framesPerBeat
                    legs.append(RopeLeg(start: frame, end: end, facingLeft: facingLeft, pedal: last.pedal,
                                        crossing: crossing, hop: true))
                    frame = end
                }
            }
            return legs
        }

        /// Circus-clock frames at which the clown lands facing the other way (turning, at each end of the rope).
        var ropeTurns: [Int] {
            let legs = ropeLegs
            return zip(legs, legs.dropFirst()).filter { $0.facingLeft != $1.facingLeft }.map(\.1.start)
        }

        /// The performance, on its juggling clock. On the tightrope the first ball comes out once the
        /// clown has faded in.
        var juggling: AgentLandJuggling.Window {
            let start = act == .ring ? join : join + AgentLandCircusChoreography.ropeFade
            let shift = Int((offset / AgentLandClownMotion.frameDuration).rounded())
            return AgentLandJuggling.Window(start: start + offset, stop: stop + offset, seed: seed,
                                            reversals: reversals.map { $0 + shift })
        }

        /// Circus-clock frames at which the pedalling reverses: each end of the tightrope ridden backward, and
        /// each roll back in the middle of the rope and its end.
        var reversals: [Int] {
            let legs = ropeLegs
            return zip(legs, legs.dropFirst()).filter { $0.pedal != $1.pedal }.map(\.1.start)
        }
    }

    struct State: Equatable, Sendable {
        let design: Int
        let center: CGPoint
        let facingLeft: Bool
        let layer: Layer
        /// Continuous fade confined to the travel inside the doorway.
        let opacity: Double
        let appearance: Appearance
        /// On the tightrope: the rider's lean toward the way it faces, in degrees, about the wheel's contact.
        var lean: Double = 0
        /// On the tightrope: where the wheel presses the rope down.
        var bend: AgentLandTightropeArt.Bend? = nil
        /// On the tightrope: how far the wheel is above the rope, hopping.
        var lift: CGFloat = 0
        /// On the tightrope: the clown's scale about its wheel's contact, before it faces left: squashed and
        /// stretched for a hop, and its width narrowing and mirroring as it spins round in the air.
        var scale = CGSize(width: 1, height: 1)

        /// As the wheel passes the threshold the foreground grows up the sprite, with its rate derived
        /// from the actual doorway and outward tangent. Above this edge the curtains still occlude it.
        /// The doorway and foreground clips are disjoint, so a translucent rider is never drawn twice.
        var portalEdge: CGFloat {
            AgentLandCircusChoreography.threshold - max(0, center.y - AgentLandCircusChoreography.doorCenter.y)
                * AgentLandCircusChoreography.portalExposureRate
        }

        var placement: AgentLandJuggling.Placement {
            AgentLandJuggling.Placement(center: center, facingLeft: facingLeft, behind: layer == .behind,
                                        floor: appearance.act == .ring ? nil : AgentLandTightropeArt.layout.floor)
        }
    }

    /// The reveal the schedule starts from (the caller's, unless it was long before `now`).
    let reveal: Double
    let seed: UInt64
    /// Every reveal is on the tightrope.
    let forcesRope: Bool
    /// This reveal's performances are all on the tightrope, which stands in for the tent from the reveal on.
    let tightrope: Bool
    private let jugglings: [AgentLandJuggling]
    private var generator: AgentLandSeededGenerator
    private var bag: [Int] = []
    private(set) var appearances: [Appearance] = []

    /// The schedule replays every performance from the reveal on, so a reveal long before the performance
    /// is built (a stale moment, `.distantPast`) would replay millions. One more than `catchUpLimit` before
    /// `now` counts as 11-12 hours before it: it moves forward by whole `catchUpStep`s, so a performance
    /// rebuilt within the same hour replays the same one.
    static let catchUpLimit: Double = 12 * 3600
    static let catchUpStep: Double = 3600

    /// `reveal` is the circus-clock time (seconds since the shared reference date) when the surface was
    /// revealed and `now` the circus-clock time the performance is built at; one juggling engine per design.
    init(reveal: Double, seed: UInt64, jugglings: [AgentLandJuggling], now: Double? = nil,
         forcesRope: Bool = AgentLandCircusChoreography.launchForcesRope) {
        self.reveal = Self.bounded(reveal: reveal, now: now)
        self.seed = seed
        self.forcesRope = forcesRope
        self.jugglings = jugglings
        generator = AgentLandSeededGenerator(seed: seed)
        tightrope = Self.isTightrope(seed: seed, forcesRope: forcesRope)
    }

    /// Choose the stage before the performers load, from the same reveal seed on Home and chat.
    static func isTightrope(seed: UInt64, forcesRope: Bool = launchForcesRope) -> Bool {
        if !forcesRope && launchAct == "tent" { return false }
        // A separate generator preserves the ring's performance schedule.
        var stage = AgentLandSeededGenerator(seed: seed ^ 0x57A6_E5EE_D0A1_0001)
        return forcesRope || Double.random(in: 0..<1, using: &stage) < ropeShare
    }

    convenience init(reveal: Double, seed: UInt64, designs: [AgentLandClownDesign] = AgentLandClownArtwork.designs,
                     now: Double? = nil, forcesRope: Bool = AgentLandCircusChoreography.launchForcesRope) {
        self.init(reveal: reveal, seed: seed, jugglings: designs.map(\.juggling), now: now, forcesRope: forcesRope)
    }

    static func bounded(reveal: Double, now: Double?) -> Double {
        guard let now, now.isFinite else { return reveal.isFinite ? reveal : 0 }
        guard reveal.isFinite else { return now - catchUpLimit }
        guard now - reveal > catchUpLimit else { return reveal }
        return reveal + ((now - catchUpLimit - reveal) / catchUpStep).rounded(.up) * catchUpStep
    }

    /// A seed for a reveal moment: the same reveal always gives the same performance.
    static func seed(for reveal: Date) -> UInt64 {
        let milliseconds = (reveal.timeIntervalSinceReferenceDate * 1000).rounded()
        guard milliseconds.isFinite, abs(milliseconds) < 9e18 else { return milliseconds.bitPattern }
        return UInt64(bitPattern: Int64(milliseconds))
    }

    /// SplitMix-style derivation keeps each appearance independent while preserving replay across surfaces.
    private static func appearanceSeed(choreography: UInt64, index: Int) -> UInt64 {
        var value = choreography &+ 0x9E3779B97F4A7C15 &+ UInt64(index) &* 0xD1B54A32D192ED03
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        return value ^ (value >> 31)
    }

    /// Extends the schedule until it covers `time`.
    private func schedule(through time: Double) {
        guard !jugglings.isEmpty else { return }
        let beat = AgentLandClownMotion.beat, frame = AgentLandClownMotion.frameDuration
        let lap = AgentLandClownMotion.orbitPeriod
        while appearances.last.map({ $0.gone < time }) ?? true {
            let appearanceSeed = Self.appearanceSeed(choreography: seed, index: appearances.count)
            // It comes out on a beat, like the throws.
            let wanted = appearances.last.map { $0.gone + Double.random(in: Self.gaps, using: &generator) } ?? reveal
            if tightrope {
                // The style is drawn from the appearance's own seed.
                var dice = AgentLandSeededGenerator(seed: appearanceSeed ^ 0x5DEE_CE66_D1CE_4E5B)
                appearances.append(ropeAppearance(after: appearances.isEmpty ? wanted + Self.ropeEntranceDelay : wanted,
                                                  seed: appearanceSeed, turning: Bool.random(using: &dice)))
                continue
            }
            let emerge = (wanted / beat - 1e-9).rounded(.up) * beat
            let design = nextDesign()
            let join = emerge + Self.fadeDuration + Self.rideDuration
            // The circus clock's own lap passes the door at doorAngle / speed + k laps; the juggling clock is
            // the one of those that differs from this clock by whole 1.2 s ride loops.
            let loop = jugglings[design].rig.frameDuration * Double(jugglings[design].rig.rightPalm.count)
            let pass = Self.doorAngle / AgentLandClownMotion.orbitSpeed
            let candidates = (0..<8).map { pass - join + Double($0) * lap }.filter { offset in
                let loops = offset / loop
                return abs(loops - loops.rounded()) < 1e-6
            }
            let offset = candidates.isEmpty ? 0 : candidates[Int(generator.next() % UInt64(candidates.count))]
            let stop = join + Double.random(in: Self.stays, using: &generator)
            let window = AgentLandJuggling.Window(start: join + offset, stop: stop + offset, seed: appearanceSeed)
            let lastCatch = jugglings[design].runOutLimit(in: window) - offset
            // The next inward tangency after the last catch, at least a beat after it. The two spiral
            // tangencies differ, but the whole laps and juggling clock retain the reference orbit phase.
            let laps = max(0, ((lastCatch + beat - join - Self.returnTravel) / lap - 1e-9).rounded(.up))
            let turn = join + Self.returnTravel + laps * lap
            let back = turn + Self.rideDuration
            let fadeOut = (back / frame - 1e-9).rounded(.up) * frame
            appearances.append(Appearance(design: design, emerge: emerge, join: join, stop: stop, turn: turn, back: back,
                                          gone: fadeOut + Self.fadeDuration, offset: offset, seed: appearanceSeed))
        }
    }

    /// A tightrope act from the first moment on or after `wanted` at which the clown joins the rope with
    /// the pedalling's reversals in the middle of holds. It juggles on the circus clock and stops throwing
    /// in time to catch every ball before it fades out.
    private func ropeAppearance(after wanted: Double, seed: UInt64, turning: Bool) -> Appearance {
        let frame = AgentLandClownMotion.frameDuration, beatFrames = AgentLandClownMotion.framesPerBeat
        let earliest = Int((wanted / frame - 1e-9).rounded(.up))
        let joinFrame = earliest + ((Self.ropeReversalPhase - earliest) % beatFrames + beatFrames) % beatFrames
        let join = Double(joinFrame) * frame
        let design = nextDesign()
        // Its own generator, so the act and the ring's schedule draw as before.
        var plan = AgentLandSeededGenerator(seed: seed ^ 0x0B5E_55ED_7155_0A11)
        let runs = (0..<Self.ropeCrossings).map { _ in Self.crossingRuns(using: &plan) }
        let beats = runs.joined().reduce(0) { $0 + abs($1) } + (turning ? (Self.ropeCrossings - 1) * Self.ropeHopBeats : 0)
        let turn = join + Double(beats * beatFrames) * frame - Self.ropeFade
        let runOut = jugglings[design].runOutLimit(in: AgentLandJuggling.Window(start: 0, stop: 0))
        let back = turn + Self.ropeFade
        return Appearance(design: design, emerge: join, join: join,
                          stop: turn - runOut - AgentLandClownMotion.beat, turn: turn, back: back,
                          gone: back, offset: 0, seed: seed, act: .rope(turning: turning),
                          ropeRuns: runs)
    }

    /// One crossing's riding in beats. About half go straight across; the others, somewhere in the middle of
    /// the rope, roll back two to four beats and go on, or rock back and forth before going on. Every run
    /// starts and ends on a beat, so each reversal of the pedalling falls in the middle of a hold.
    static func crossingRuns(using generator: inout AgentLandSeededGenerator) -> [Int] {
        let beats = ropeCrossingBeats
        let roll = Double.random(in: 0..<1, using: &generator)
        guard roll >= 0.45 else { return [beats] }
        let at = Int.random(in: 5...12, using: &generator)
        guard roll < 0.82 else { return [at, -1, 1, -1, beats - at + 1] }
        let back = Int.random(in: 2...4, using: &generator)
        return [at, -back, beats - at + back]
    }

    /// Shuffled designs, a fresh shuffle whenever every design has come out, never the same twice in a row.
    private func nextDesign() -> Int {
        if bag.isEmpty {
            bag = Array(jugglings.indices).shuffled(using: &generator)
            if bag.count > 1, let previous = appearances.last?.design, bag.last == previous {
                bag.swapAt(bag.count - 1, 0)
            }
        }
        return bag.removeLast()
    }

    /// The latest performance that has started by `time` (it may be over: see `state(at:)`).
    func appearance(at time: Double) -> Appearance? {
        schedule(through: time)
        return appearances.last { $0.emerge <= time }
    }

    /// Every performance that has started by `time`.
    func appearances(through time: Double) -> [Appearance] {
        schedule(through: time)
        return appearances.filter { $0.emerge <= time }
    }

    /// Where the clown is at `time`, or nil while no clown is out (before its entrance or between designs).
    func state(at time: Double) -> State? {
        guard let appearance = appearance(at: time), time < appearance.gone else { return nil }
        if appearance.act != .ring, time < appearance.join || time >= appearance.back { return nil }
        return Self.state(of: appearance, at: time)
    }

    /// The ride frame shown at `time`: the circus clock's, except on return crossings ridden backward, where
    /// the frames count back down.
    static func rideFrame(of appearance: Appearance, at time: Double, frameCount: Int) -> Int {
        let reversals = appearance.reversals
        guard !reversals.isEmpty, frameCount > 0, time > 0 else {
            return AgentLandClownMotion.frameIndex(at: time, frameCount: frameCount)
        }
        let frame = AgentLandClownMotion.pedalFrame(Int(time / AgentLandClownMotion.frameDuration), reversals: reversals)
        return ((frame % frameCount) + frameCount) % frameCount
    }

    static func state(of appearance: Appearance, at time: Double) -> State {
        if case let .rope(turning) = appearance.act { return ropeState(of: appearance, at: time, turning: turning) }
        switch time {
        case ..<(appearance.emerge + fadeDuration):
            let t = min(1, max(0, (time - appearance.emerge) / fadeDuration))
            let center = curve(CGPoint(x: doorCenter.x, y: doorCenter.y - fadeDepth), doorCenter,
                               startVelocity: .zero, endVelocity: CGPoint(x: 0, y: portalSpeed), duration: fadeDuration, progress: t).point
            return State(design: appearance.design, center: center,
                         facingLeft: true, layer: .door, opacity: smooth(t), appearance: appearance)
        case ..<appearance.join:
            let progress = (time - appearance.emerge - fadeDuration) / rideDuration
            return spiralState(of: appearance, progress: progress, outward: true)
        case ..<appearance.turn:
            let angle = doorAngle + (time - appearance.join) * AgentLandClownMotion.orbitSpeed
            return State(design: appearance.design, center: AgentLandClownMotion.orbitPosition(angle: angle),
                         facingLeft: AgentLandClownMotion.isFacingLeft(angle: angle),
                         layer: AgentLandClownMotion.isBehind(angle: angle) ? .behind : .front, opacity: 1,
                         appearance: appearance)
        case ..<appearance.back:
            let progress = (time - appearance.turn) / rideDuration
            return spiralState(of: appearance, progress: progress, outward: false)
        default:
            let duration = appearance.gone - appearance.back
            let t = min(1, max(0, (time - appearance.back) / duration))
            let center = curve(doorCenter, CGPoint(x: doorCenter.x, y: doorCenter.y - fadeDepth),
                               startVelocity: CGPoint(x: 0, y: -portalSpeed), endVelocity: .zero, duration: duration, progress: t).point
            return State(design: appearance.design, center: center,
                         facingLeft: false, layer: .door, opacity: 1 - smooth(t), appearance: appearance)
        }
    }

    /// Rightward on the first and third crossings, leftward on the others. The wheel rolls exactly as far as the
    /// pedals turn it, so it never slips, whichever way it goes. It fades in riding away from the left end and
    /// fades out riding back into it. The rope gives under the wheel and the wheel rides on the bent rope.
    private static func ropeState(of appearance: Appearance, at time: Double, turning: Bool) -> State {
        let legs = appearance.ropeLegs, reversals = appearance.reversals
        guard let first = legs.first, let last = legs.last else {
            return State(design: appearance.design, center: CGPoint(x: AgentLandTightropeArt.layout.middle, y: AgentLandTightropeArt.layout.riderY),
                         facingLeft: false, layer: .front, opacity: 0, appearance: appearance)
        }
        let frame = min(max(ropeFrame(at: time), Double(first.start)), Double(last.end))
        var travel = 0.0, current = first
        for leg in legs where frame >= Double(leg.start) {
            current = leg
            // In the air the wheel spins without carrying the clown.
            guard !leg.hop else { continue }
            let pedalled = AgentLandClownMotion.pedalPosition(min(frame, Double(leg.end)), reversals: reversals)
                - AgentLandClownMotion.pedalPosition(Double(leg.start), reversals: reversals)
            travel += leg.facingLeft ? -pedalled : pedalled
        }
        let rope = AgentLandTightropeArt.layout
        let perFrame = AgentLandClownMotion.wheelSpeed * CGFloat(AgentLandClownMotion.frameDuration)
        let wheel = rope.middle - ropeLength / 2 + CGFloat(travel) * perFrame
        let share = ropeProgress(at: wheel)
        let bend = AgentLandTightropeArt.Bend(contact: wheel,
                                              depth: ropeSag * 4 * share * (1 - share) * ropeBounce(of: appearance, at: time, frame: frame))
        let opacity = min(smooth((time - appearance.join) / ropeFade), 1 - smooth((time - appearance.turn) / ropeFade))
        let hop = ropeHop(of: appearance, at: time)
        return State(design: appearance.design,
                     center: CGPoint(x: wheel + (current.facingLeft ? -ropeHubOffset : ropeHubOffset),
                                     y: rope.riderY + bend.drop(at: wheel) - hop.lift),
                     facingLeft: current.facingLeft, layer: .front, opacity: opacity, appearance: appearance,
                     lean: ropeLean(of: appearance, at: time, along: share), bend: bend,
                     lift: hop.lift, scale: hop.scale)
    }

    /// The hop at an end of the rope: how high the wheel is, and the clown's scale about its wheel's contact.
    /// Riding on into the end it squashes down (wider and shorter); it springs up stretched (taller and
    /// narrower), back to its own shape at the top, while it spins round in the air, narrowing to a quarter of
    /// its width edge-on and widening again mirrored; it lands facing the other way and squashes a little.
    static func ropeHop(of appearance: Appearance, at time: Double) -> (lift: CGFloat, scale: CGSize) {
        let frameDuration = AgentLandClownMotion.frameDuration
        for leg in appearance.ropeLegs where leg.hop {
            let takeoff = Double(leg.start) * frameDuration, landing = Double(leg.end) * frameDuration
            guard time > takeoff - ropeCrouch, time < landing + ropeLanding else { continue }
            let airtime = landing - takeoff, apex = takeoff + airtime / 2
            let squash: Double
            if time >= landing {
                // Landed: a small squash, quickly in and eased out.
                let since = time - landing
                squash = -0.1 * (since < 0.05 ? smooth(since / 0.05) : 1 - smooth((since - 0.05) / (ropeLanding - 0.05)))
                return (0, CGSize(width: 1 - squash / 2, height: 1 + squash))
            } else if time < takeoff {
                squash = -0.15 * smooth((time - takeoff + ropeCrouch) / (ropeCrouch * 0.8))
            } else if time < takeoff + 0.06 {
                squash = -0.15 + 0.25 * smooth((time - takeoff) / 0.06)
            } else {
                squash = 0.1 * (1 - smooth((time - takeoff - 0.06) / (apex - takeoff - 0.06)))
            }
            let tall = CGFloat(1 + squash), wide = CGFloat(1 - squash / 2)
            guard time >= takeoff else { return (0, CGSize(width: wide, height: tall)) }
            let progress = (time - takeoff) / airtime
            // A body has depth: edge-on it still shows a quarter of its width, mirroring there.
            let turned = cos(.pi * smooth((progress - 0.1) / 0.8))
            let spin = CGFloat((turned < 0 ? -1 : 1) * (0.25 + 0.75 * abs(turned)))
            return (ropeHopHeight * CGFloat(4 * progress * (1 - progress)), CGSize(width: wide * spin, height: tall))
        }
        return (0, CGSize(width: 1, height: 1))
    }

    /// The circus clock in frames, a moment within a millionth of a frame of one taken as that frame, so a leg
    /// starts exactly at its first frame whatever the rounding of the moment.
    static func ropeFrame(at time: Double) -> Double {
        let frame = time / AgentLandClownMotion.frameDuration
        return abs(frame - frame.rounded()) < 1e-6 ? frame.rounded() : frame
    }

    /// How far along the rope's free run `x` is, 0 at the left platform's edge and 1 at the right's; on the
    /// platforms 0 and 1.
    static func ropeProgress(at x: CGFloat) -> CGFloat {
        let anchors = AgentLandTightropeArt.layout.anchors
        return min(1, max(0, (x - anchors.lowerBound) / (anchors.upperBound - anchors.lowerBound)))
    }

    /// The rope's give relative to its standing sag: it dips a little on every push of the pedals (two a ride
    /// loop) and bounces, dying away, after every reversal and turn.
    private static func ropeBounce(of appearance: Appearance, at time: Double, frame: Double) -> CGFloat {
        let pedal = AgentLandClownMotion.pedalPosition(frame, reversals: appearance.reversals)
        var bounce = 0.07 * sin(2 * .pi * pedal / 36)
        let frameDuration = AgentLandClownMotion.frameDuration
        let kicks = appearance.reversals.map { (Double($0) * frameDuration, 0.16) }
            + appearance.ropeTurns.map { (Double($0) * frameDuration, 0.22) }
        for (moment, size) in kicks where time > moment && time < moment + 3 {
            let since = time - moment
            bounce += size * exp(-since / 0.55) * sin(2 * .pi * 1.7 * since)
        }
        return CGFloat(1 + bounce)
    }

    /// The rider's lean toward the way it faces, in degrees. It sways as it balances, more in the middle of the
    /// rope, where the rope gives most; it leans a little the way it is riding, leans hard the new way just
    /// before every reversal (a unicycle follows its rider's lean) and wobbles after it. It straightens up for
    /// each hop round, stays upright in the air and wobbles after landing.
    static func ropeLean(of appearance: Appearance, at time: Double, along share: CGFloat) -> Double {
        let legs = appearance.ropeLegs
        guard let first = legs.first else { return 0 }
        let frameDuration = AgentLandClownMotion.frameDuration
        var random = AgentLandSeededGenerator(seed: appearance.seed ^ 0x1EA4_5A7E_B0B5_0001)
        let phases = (0..<3).map { _ in Double.random(in: 0..<(2 * .pi), using: &random) }
        let middle = 4 * Double(share) * (1 - Double(share))
        let settle = smooth((time - appearance.join) / 0.8)
        var lean = settle * (0.4 + 0.6 * middle) * (2.0 * sin(2 * .pi * time / 1.37 + phases[0])
            + 1.2 * sin(2 * .pi * time / 2.23 + phases[1]) + 0.6 * sin(2 * .pi * time / 0.83 + phases[2]))
        // Riding on, a slight lean the way it goes; into each reversal a hard lean the new way, then a wobble.
        lean += 1.2 * Double(first.pedal)
        for (before, after) in zip(legs, legs.dropFirst()) where before.pedal != after.pedal {
            let change = Double(after.pedal - before.pedal) / 2, moment = Double(after.start) * frameDuration
            let since = time - moment
            lean += 2 * change * 1.2 * smooth((since + 0.35) / 0.5)
            lean += change * 5.5 * exp(-pow((since + 0.12) / 0.2, 2))
            if since > 0 { lean -= change * 2.5 * exp(-since / 0.5) * sin(2 * .pi * 1.5 * since) }
        }
        // Upright in the air, so the lean toward the old facing never jumps to the new one on landing.
        for leg in legs where leg.hop {
            let takeoff = Double(leg.start) * frameDuration, landing = Double(leg.end) * frameDuration
            if time > takeoff - ropeCrouch && time < landing + 0.3 {
                lean *= time < takeoff ? 1 - smooth((time - takeoff + ropeCrouch) / ropeCrouch)
                    : smooth((time - landing) / 0.3)
            }
        }
        for (index, turn) in appearance.ropeTurns.enumerated() {
            let since = time - Double(turn) * frameDuration
            if since > 0 { lean += (index % 2 == 0 ? 3 : -3) * exp(-since / 0.45) * sin(2 * .pi * 1.8 * since) }
        }
        return min(9, max(-9, lean))
    }

    /// The local spiral curls first down-left across the opening and then up-left onto the ring. The
    /// return curls from the near ring up-left, then turns right into the opening. Their endpoint tangents
    /// match the ring and the moving doorway fades; neither arc cuts through the facade.
    private static func spiralState(of appearance: Appearance, progress: Double, outward: Bool) -> State {
        let start = outward ? doorCenter : returnPoint
        let end = outward ? doorPoint : doorCenter
        let angle = outward ? doorAngle : returnAngle
        let ringVelocity = AgentLandClownMotion.orbitVelocity(angle: angle)
        let value = curve(start, end,
                          startVelocity: outward ? CGPoint(x: 0, y: portalSpeed) : ringVelocity,
                          endVelocity: outward ? ringVelocity : CGPoint(x: 0, y: -portalSpeed),
                          duration: rideDuration, progress: progress)
        return State(design: appearance.design, center: value.point, facingLeft: value.velocity.x <= 0,
                     layer: .door, opacity: 1, appearance: appearance)
    }

    /// Cubic Hermite travel with velocities in scene points per second.
    private static func curve(_ start: CGPoint, _ end: CGPoint, startVelocity: CGPoint, endVelocity: CGPoint,
                              duration: Double, progress: Double) -> (point: CGPoint, velocity: CGPoint) {
        let t = min(1, max(0, progress)), t2 = t * t, t3 = t2 * t
        func component(_ a: CGFloat, _ b: CGFloat, _ va: CGFloat, _ vb: CGFloat) -> (CGFloat, CGFloat) {
            let point = (2 * t3 - 3 * t2 + 1) * a + (-2 * t3 + 3 * t2) * b
                + (t3 - 2 * t2 + t) * va * duration + (t3 - t2) * vb * duration
            let velocity = ((6 * t2 - 6 * t) * a + (-6 * t2 + 6 * t) * b) / duration
                + (3 * t2 - 4 * t + 1) * va + (3 * t2 - 2 * t) * vb
            return (point, velocity)
        }
        let x = component(start.x, end.x, startVelocity.x, endVelocity.x)
        let y = component(start.y, end.y, startVelocity.y, endVelocity.y)
        return (CGPoint(x: x.0, y: y.0), CGPoint(x: x.1, y: y.1))
    }

    private static func smooth(_ progress: Double) -> Double {
        let t = min(1, max(0, progress))
        return t * t * (3 - 2 * t)
    }

    /// Balls in the clown's hands or in the air at `time`, in sprite pixels.
    func balls(at time: Double) -> [AgentLandJuggling.LocalBall] {
        guard let state = state(at: time) else { return [] }
        return Self.balls(of: state, at: time, juggling: jugglings[state.design])
    }

    static func balls(of state: State, at time: Double, juggling: AgentLandJuggling) -> [AgentLandJuggling.LocalBall] {
        juggling.balls(at: time + state.appearance.offset, window: state.appearance.juggling)
    }

    /// Missed balls rolling on the ground at `time`, from the performance that is on and any that just ended.
    func groundBalls(at time: Double) -> [AgentLandJuggling.GroundBall] {
        schedule(through: time)
        let recent = appearances.filter { $0.emerge <= time && time < $0.gone + AgentLandJuggling.rollDuration + 3 }
        return recent.flatMap { performance in
            jugglings[performance.design].groundBalls(at: time + performance.offset, window: performance.juggling) { landing in
                let clock = landing - performance.offset
                guard clock >= performance.emerge, clock < performance.gone else { return nil }
                return Self.state(of: performance, at: clock).placement
            }
        }
    }

}
