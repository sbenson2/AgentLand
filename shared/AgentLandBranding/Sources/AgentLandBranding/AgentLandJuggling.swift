import CoreGraphics
import Foundation

/// The clown's juggling: a seeded three- or four-ball cascade,
/// balls added from a pocket or put away, and an occasional missed catch that
/// bounces away across the ground. Hands throw alternately on every beat, in
/// step with the rider frames, and every position is a pure function of time
/// within a seeded appearance, so every surface draws the same performance.
///
/// A performance can be limited to a window of the circus clock: a ball shows only from a moment inside the
/// window (so the clown starts with empty hands and takes balls out of its pocket) and is thrown only before
/// the window closes (so the clown finishes its catches and puts every ball away).
struct AgentLandJuggling: Sendable {
    enum Hand: Int, Sendable { case right = 0, left = 1 }

    /// Where the rider's palms are in each frame of the ride loop, in sprite pixels.
    struct Rig: Sendable {
        var rightPalm: [CGPoint]
        var leftPalm: [CGPoint]
        var framesPerBeat = 18
        var frameDuration: TimeInterval = 1.0 / 60.0
        /// Sprite row the wheel touches; dropped balls land here.
        var ground: CGFloat = 94
    }

    /// The span of the circus clock a performance may use.
    struct Window: Hashable, Sendable {
        /// No ball shows from before this moment.
        var start: Double
        /// No ball is thrown from this moment on.
        var stop: Double
        var seed: UInt64 = 0
        /// Juggling-clock frames at which the pedalling reverses (riding backward on the tightrope): the ride
        /// frames, and the palms on them, then count down. Empty on the ring.
        var reversals: [Int] = []
    }

    struct Stretch: Equatable, Sendable {
        let startBeat: Int
        let endBeat: Int
        let balls: Int
    }

    struct Performance: Sendable {
        let stretches: [Stretch]
        let spans: [Span]
        let bounces: [Bounce]
    }

    /// Where the clown is: its centre in scene points, its facing and whether it is behind the tent.
    struct Placement: Equatable, Sendable {
        var center: CGPoint
        var facingLeft: Bool
        var behind: Bool
        /// The floor's height in scene points when the wheel is above it (on the tightrope): a missed ball
        /// falls on past the wheel and bounces there. Nil when the wheel is on the floor.
        var floor: CGFloat? = nil
    }

    /// One visible use of a ball layer: held, thrown, then caught, put away or dropped.
    struct Span: Sendable {
        let slot: Int
        let start: Double
        let holder: Hand?
        let throwTime: Double
        let origin: CGPoint
        let velocity: CGVector
        let catchTime: Double
        let end: Double
        let dropped: Bool
        let tint: Int
        let spinRate: CGFloat
        let heldAngle: CGFloat
    }

    /// A missed ball reaching the ground, in the rider's sprite: where it lands and how fast. Where that is in
    /// the scene depends on where the clown is at that moment (`placed`).
    struct Bounce: Sendable {
        let slot: Int
        /// The dropped span's start and throw, for the performance window.
        let spanStart: Double
        let throwTime: Double
        /// When it lands and when it has rolled away.
        let start: Double
        let end: Double
        /// Sprite point of the landing, sprite pixels per second across, and the landing speed.
        let local: CGPoint
        let speedX: CGFloat
        let impact: CGFloat
        let tint: Int
        let spinRate: CGFloat
        let angle: CGFloat
    }

    /// A missed ball after it reaches the ground, in scene points. Off the tightrope it first falls for
    /// `fall` seconds from where it passes the wheel, `release`, at `fallVelocity`, to `contact` on the floor.
    struct PlacedBounce: Sendable {
        let slot: Int
        let start: Double
        let contact: CGPoint
        let velocity: CGVector
        let front: Bool
        let end: Double
        var release: CGPoint? = nil
        var fallVelocity = CGVector.zero
        var fall: Double = 0
    }

    struct LocalBall: Equatable, Sendable {
        let slot: Int; let point: CGPoint; let tint: Int; let spinFrame: Int
        /// A missed ball keeps falling but has left the juggling routine.
        let isDropped: Bool
    }
    struct GroundBall: Equatable, Sendable {
        let slot: Int; let point: CGPoint; let opacity: Double; let front: Bool
        let tint: Int; let spinFrame: Int
    }

    static let gravity: CGFloat = 694
    static let dwellBeats = 2.0 / 3.0
    static let pocketLeadBeats = 0.5
    static let recoveryBeats = 2
    static let palmOffset = CGVector(dx: 0, dy: -3)
    static let restitution: CGFloat = 0.6
    static let rollDuration = 3.2
    /// Where a rolling ball stops at the stage's sides: the work surfaces' 404-point stage, centred on the
    /// tent at x 168, less half a ball.
    static let groundSpan: ClosedRange<CGFloat> = -28...364
    /// A finite reference performance for evidence callers without an appearance.
    static let referenceDuration = 120.0

    let rig: Rig
    let seed: UInt64
    private let maximumRunOut: Double
    private let cache = PerformanceCache()

    var beat: Double { Double(rig.framesPerBeat) * rig.frameDuration }
    var spans: [Span] { performance(in: referenceWindow).spans }
    var bounces: [Bounce] { performance(in: referenceWindow).bounces }
    private var referenceWindow: Window { Window(start: 0, stop: Self.referenceDuration, seed: seed) }

    init(rig: Rig, seed: UInt64 = 0) {
        self.rig = rig
        self.seed = seed
        let flight = (4 - Self.dwellBeats) * Double(rig.framesPerBeat) * rig.frameDuration
        let heights = (rig.rightPalm + rig.leftPalm).map { $0.y + Self.palmOffset.dy }
        let lowest = heights.min() ?? rig.ground, highest = heights.max() ?? rig.ground
        let upward = (highest - lowest) / max(flight, 0.001) + Self.gravity * flight / 2
        let fall = (upward + (upward * upward + 2 * Self.gravity * max(0, rig.ground - 2 - lowest)).squareRoot()) / Self.gravity
        maximumRunOut = max(flight, fall)
    }

    static func hand(beat: Int) -> Hand { beat & 1 == 0 ? .right : .left }

    /// Each immutable schedule is shared by copies of its design and computed
    /// once while it is recent. The lock protects both lookup and construction.
    private final class PerformanceCache: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Window: Performance] = [:]
        private var order: [Window] = []

        func value(for window: Window, build: () -> Performance) -> Performance {
            lock.lock()
            defer { lock.unlock() }
            if let value = values[window] { return value }
            let value = build()
            if order.count == 8 { values.removeValue(forKey: order.removeFirst()) }
            order.append(window)
            values[window] = value
            return value
        }
    }

    func performance(in window: Window) -> Performance {
        guard window.start.isFinite, window.stop.isFinite, window.stop > window.start,
              beat.isFinite, beat > 0, !rig.rightPalm.isEmpty, !rig.leftPalm.isEmpty,
              abs(window.start / beat) < Double(Int.max / 2),
              abs(window.stop / beat) < Double(Int.max / 2)
        else { return Performance(stretches: [], spans: [], bounces: []) }
        return cache.value(for: window) { buildPerformance(in: window) }
    }

    /// The palm in the ride frame shown at juggling-clock frame `frame`.
    private func palm(_ hand: Hand, frame: Int, reversals: [Int] = []) -> CGPoint {
        let values = hand == .right ? rig.rightPalm : rig.leftPalm
        let shown = AgentLandClownMotion.pedalFrame(frame, reversals: reversals)
        let point = values[((shown % values.count) + values.count) % values.count]
        return CGPoint(x: point.x + Self.palmOffset.dx, y: point.y + Self.palmOffset.dy)
    }

    private func buildPerformance(in window: Window) -> Performance {
        let first = Int((window.start / beat + Self.pocketLeadBeats - 1e-9).rounded(.up))
        let last = Int((window.stop / beat - 1e-9).rounded(.up)) - 1
        guard first <= last else { return Performance(stretches: [], spans: [], bounces: []) }
        var random = AgentLandSeededGenerator(seed: window.seed)
        var stretches: [Stretch] = []
        var count = Double.random(in: 0..<1, using: &random) < 0.6 ? 3 : 4
        var cursor = first
        while cursor <= last {
            let end = cursor + Int.random(in: 12...30, using: &random)
            stretches.append(Stretch(startBeat: cursor, endBeat: end, balls: count))
            cursor = end
            count = count == 3 ? 4 : 3
        }

        struct Arrival {
            let landing: Int
            let catchTime: Double
            let slot: Int
            let tint: Int
            let angle: CGFloat
        }
        var arrivals: [Arrival] = []
        var spans: [Span] = [], bounces: [Bounce] = []
        var lastMiss: Int?
        var pendingMisses: [Double] = []
        var nextIdentity = 0
        var stretchIndex = 0
        for current in first...last {
            while current >= stretches[stretchIndex].endBeat { stretchIndex += 1 }
            let wanted = stretches[stretchIndex].balls
            let received = arrivals.filter { $0.landing == current }
            arrivals.removeAll { $0.landing == current }
            let throwTime = Double(current) * beat
            let pocketTime = throwTime - Self.pocketLeadBeats * beat
            let replacement = pendingMisses.firstIndex { pocketTime >= $0 && pocketTime <= $0 + Double(Self.recoveryBeats) * beat }
            let start: Double, slot: Int, tint: Int, heldAngle: CGFloat
            if let caught = received.first, replacement == nil {
                // A second arrival goes into the pocket at its catch; only the
                // first ball continues. Its identity and landed angle survive.
                start = caught.catchTime
                slot = caught.slot
                tint = caught.tint
                heldAngle = caught.angle
            } else {
                start = pocketTime
                let active = spans.filter { start >= $0.start && start < $0.end }
                // Missed balls continue falling and retain their colour, like
                // rolling balls, but no longer occupy one of the routine's
                // three or four places. This keeps the half-beat pocket lead.
                let juggled = active.filter { !$0.dropped || start < $0.catchTime }
                // A drop can coincide with the transition from four to three.
                // Retrieve the replacement even if another ball arrives in
                // that hand: put that arrival away to keep the count bounded.
                guard (juggled.count < wanted || replacement != nil), juggled.count < 4 else { continue }
                let used = Set(spans.filter { $0.end > start }.map(\.tint) + bounces.filter { start < $0.end }.map(\.tint))
                guard let free = (0..<AgentLandJugglingBall.rgb.count).filter({ !used.contains($0) }).randomElement(using: &random)
                else { continue }
                tint = free
                slot = nextIdentity
                nextIdentity += 1
                heldAngle = CGFloat.random(in: 0..<(2 * .pi), using: &random)
                if let replacement { pendingMisses.remove(at: replacement) }
            }
            let landing = current + wanted
            let catchFrame = landing * rig.framesPerBeat - Int((Self.dwellBeats * Double(rig.framesPerBeat)).rounded())
            let catchTime = Double(catchFrame) * rig.frameDuration
            let hand = Self.hand(beat: current)
            let origin = palm(hand, frame: current * rig.framesPerBeat, reversals: window.reversals)
            let target = palm(Self.hand(beat: landing), frame: catchFrame, reversals: window.reversals)
            let flight = catchTime - throwTime
            let velocity = CGVector(dx: (target.x - origin.x) / flight,
                                    dy: (target.y - origin.y) / flight - Self.gravity * flight / 2)
            let direction: CGFloat = velocity.dx < 0 ? -1 : velocity.dx > 0 ? 1 : 0
            let spin = CGFloat.random(in: 1.0...2.4, using: &random) * direction
            let missAllowed = catchTime - window.start >= 12 * beat && (lastMiss.map { landing - $0 >= 40 } ?? true)
            let missed = missAllowed && Double.random(in: 0..<1, using: &random) < 0.03
            var end = catchTime
            if missed {
                let rest = rig.ground - 2
                let a = Self.gravity / 2, b = velocity.dy, c = origin.y - rest
                let fall = (-b + (b * b - 4 * a * c).squareRoot()) / (2 * a)
                end = throwTime + fall
                bounces.append(Bounce(slot: slot, spanStart: start, throwTime: throwTime,
                                      start: end, end: end + Self.rollDuration,
                                      local: CGPoint(x: origin.x + velocity.dx * fall, y: rest),
                                      speedX: velocity.dx, impact: velocity.dy + Self.gravity * fall,
                                      tint: tint, spinRate: spin,
                                      angle: heldAngle + spin * CGFloat(fall) * 2 * .pi))
                lastMiss = landing
                pendingMisses.append(catchTime)
            } else {
                arrivals.append(Arrival(landing: landing, catchTime: catchTime, slot: slot, tint: tint,
                                        angle: heldAngle + spin * CGFloat(flight) * 2 * .pi))
            }
            spans.append(Span(slot: slot, start: start, holder: hand, throwTime: throwTime,
                              origin: origin, velocity: velocity, catchTime: catchTime, end: end,
                              dropped: missed, tint: tint, spinRate: spin, heldAngle: heldAngle))
        }
        return Performance(stretches: stretches, spans: spans, bounces: bounces)
    }

    /// Held and flying balls on the sprite grid. Catches after the window stop
    /// finish normally, then go into the pocket without another throw.
    func balls(at time: Double, window: Window? = nil) -> [LocalBall] {
        let window = window ?? referenceWindow
        return performance(in: window).spans.compactMap { span in
            guard time >= span.start, time < span.end else { return nil }
            return LocalBall(slot: span.slot, point: position(span, at: time, reversals: window.reversals), tint: span.tint,
                             spinFrame: Self.spinFrame(angle: angle(span, at: time)),
                             isDropped: span.dropped && time >= span.catchTime)
        }
    }

    func position(_ span: Span, at time: Double, reversals: [Int] = []) -> CGPoint {
        if time < span.throwTime, let holder = span.holder {
            return palm(holder, frame: Int((time / rig.frameDuration).rounded(.down)), reversals: reversals)
        }
        let flight = CGFloat(time - span.throwTime)
        return CGPoint(x: (span.origin.x + span.velocity.dx * flight).rounded(),
                       y: (span.origin.y + span.velocity.dy * flight + Self.gravity * flight * flight / 2).rounded())
    }

    func angle(_ span: Span, at time: Double) -> CGFloat {
        guard time >= span.throwTime else { return span.heldAngle }
        return span.heldAngle + span.spinRate * CGFloat(time - span.throwTime) * 2 * .pi
    }

    static func spinFrame(angle: CGFloat) -> Int {
        let frame = Int((angle / (2 * .pi) * 8).rounded())
        return ((frame % 8) + 8) % 8
    }

    func lastCatch(in window: Window) -> Double {
        performance(in: window).spans.reduce(window.stop) { max($0, $1.end) }
    }

    /// Planning a return only needs a safe run-out bound. Avoid constructing
    /// hundreds of past ball schedules when catching up an old reveal; the
    /// selected appearance still uses its exact seeded catches for rendering.
    func runOutLimit(in window: Window) -> Double { window.stop + maximumRunOut }

    /// A missed ball's landing in the scene, for a clown at `place` when it lands.
    static func placed(_ bounce: Bounce, at place: Placement, start: Double) -> PlacedBounce {
        let flip: CGFloat = place.facingLeft ? -1 : 1
        let contact = snapped(CGPoint(x: place.center.x + flip * (bounce.local.x - 48) * 0.75,
                                      y: place.center.y + (bounce.local.y - 48) * 0.75))
        // The ball rolls back the way the clown came, so the two separate on screen.
        let roll = CGVector(dx: flip * bounce.speedX * 0.75 * 0.3 - flip * 20, dy: -bounce.impact * 0.75 * restitution)
        guard let floor = place.floor, floor > contact.y else {
            return PlacedBounce(slot: bounce.slot, start: start, contact: contact, velocity: roll, front: !place.behind,
                                end: start + (bounce.end - bounce.start))
        }
        // Off the tightrope it falls on to the floor, keeping its own speed across, and bounces there.
        let g = gravity * 0.75
        let falling = CGVector(dx: flip * bounce.speedX * 0.75, dy: bounce.impact * 0.75)
        let fall = (-falling.dy + (falling.dy * falling.dy + 2 * g * (floor - contact.y)).squareRoot()) / g
        let landing = CGPoint(x: contact.x + falling.dx * fall, y: floor)
        return PlacedBounce(slot: bounce.slot, start: start, contact: landing,
                            velocity: CGVector(dx: roll.dx, dy: -(falling.dy + g * fall) * restitution),
                            front: !place.behind, end: start + Double(fall) + (bounce.end - bounce.start),
                            release: contact, fallVelocity: falling, fall: Double(fall))
    }

    /// Ground balls retain their tint until the roll and fade are complete.
    func groundBalls(at time: Double, window: Window? = nil,
                     place: (Double) -> Placement?) -> [GroundBall] {
        performance(in: window ?? referenceWindow).bounces.compactMap { bounce in
            guard time >= bounce.start, time < bounce.end + Self.longestFall,
                  let placement = place(bounce.start) else { return nil }
            let placed = Self.placed(bounce, at: placement, start: bounce.start)
            guard time < placed.end else { return nil }
            let (point, opacity) = Self.bounce(placed, after: time - placed.start)
            let flip: CGFloat = placement.facingLeft ? -1 : 1
            // Ground spin follows actual travel over the ball's radius; a falling ball keeps its spin.
            let falling = min(time - placed.start, placed.fall)
            let angle = flip * (bounce.angle + bounce.spinRate * CGFloat(falling) * 2 * .pi)
                + (time - placed.start > placed.fall ? (point.x - placed.contact.x) / AgentLandJugglingBall.radius : 0)
            return GroundBall(slot: bounce.slot, point: point, opacity: opacity, front: placed.front,
                              tint: bounce.tint, spinFrame: Self.spinFrame(angle: angle))
        }
    }

    /// Longer than any fall from the tightrope to the floor.
    static let longestFall = 2.0

    static func bounce(_ bounce: PlacedBounce, after elapsed: Double) -> (CGPoint, Double) {
        let g = gravity * 0.75
        if let release = bounce.release, elapsed < bounce.fall {
            let t = CGFloat(elapsed)
            return (snapped(CGPoint(x: release.x + bounce.fallVelocity.dx * t,
                                    y: release.y + bounce.fallVelocity.dy * t + g * t * t / 2)), 1)
        }
        var hop = -bounce.velocity.dy
        var time = elapsed - bounce.fall
        var height: CGFloat = 0
        // Successive hops lose most of their height; the ball then rolls to a stop.
        while hop > 12 {
            let airtime = Double(2 * hop / g)
            if time < airtime {
                let t = CGFloat(time)
                height = hop * t - g * t * t / 2
                time = -1
                break
            }
            time -= airtime
            hop *= restitution
        }
        let travel = travelDistance(speed: bounce.velocity.dx, after: elapsed - bounce.fall)
        let x = min(max(bounce.contact.x + travel, groundSpan.lowerBound), groundSpan.upperBound)
        let fade = min(1, max(0, (bounce.end - bounce.start - elapsed) / 0.45))
        return (snapped(CGPoint(x: x, y: bounce.contact.y - max(0, height))), fade)
    }

    /// Scene positions land on the clown's 0.75 pt pixel grid.
    static func snapped(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x / 0.75).rounded() * 0.75, y: (point.y / 0.75).rounded() * 0.75)
    }

    private static func travelDistance(speed: CGFloat, after elapsed: Double) -> CGFloat {
        let friction: CGFloat = 12
        let stop = Double(abs(speed) / friction)
        let t = CGFloat(min(elapsed, stop))
        return speed * t - (speed < 0 ? -1 : 1) * friction * t * t / 2
    }
}
