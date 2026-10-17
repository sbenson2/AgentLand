import CoreGraphics
import Foundation

/// How the title arrives when Home is revealed (0.9–1.4 s).
public enum AgentLandWordmarkEntrance: String, CaseIterable, Sendable {
    case dropAndBounce, marqueeLightUp, flipIn, arcUnfurl, pixelAssemble, curtainWipe
    case tossUp, spinIn, slotShuffle, inkFill, stamp, stretchSnap
}

/// An idle flourish, every 20–30 s while Home stays visible, or on a tap.
public enum AgentLandWordmarkFlourish: String, CaseIterable, Sendable {
    case bulbChase, ripple, looseLetter, juggleHop, marqueeBlink
    case fontFlip, fontDissolve, jellyWobble, dominoTip, sparkleTwinkle, spotlightSweep, leapfrog, dripAndReform
}

/// The same motion gate as the circus: a still resting pose under Reduce Motion, when the title is hidden,
/// covered or its scene is inactive or in the background, and in UI test runs that disable animations.
public enum AgentLandWordmarkMotionGate {
    public static let uiTestsDisableAnimationsArgument = "-AgentLandUITestsDisableAnimations"

    public static func allowsMotion(active: Bool, reduceMotion: Bool, sceneActive: Bool,
                                    arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        active && !reduceMotion && sceneActive && !arguments.contains(uiTestsDisableAnimationsArgument)
    }
}

/// Picks entrances, flourishes and each load's face and look at random (seedable), never the same one twice
/// in a row. The last entrance, face and look are remembered across launches, so a new launch never opens
/// with the previous launch's last ones.
public struct AgentLandWordmarkPicker: Sendable {
    public static let lastEntranceKey = "agentland.wordmark.lastEntrance"
    public static let lastFaceKey = "agentland.wordmark.lastFace"
    public static let lastLookKey = "agentland.wordmark.lastLook"

    private var generator: AgentLandSeededGenerator
    public private(set) var lastEntrance: AgentLandWordmarkEntrance?
    public private(set) var lastFlourish: AgentLandWordmarkFlourish?
    public private(set) var lastStyle: AgentLandWordmarkStyle?

    public init(seed: UInt64, lastEntrance: AgentLandWordmarkEntrance? = nil, lastStyle: AgentLandWordmarkStyle? = nil) {
        generator = AgentLandSeededGenerator(seed: seed)
        self.lastEntrance = lastEntrance
        self.lastStyle = lastStyle
    }

    /// The previous launch's last face and look, read defensively: anything unreadable, or a face no longer
    /// among `faces`, counts as none.
    public static func savedStyle(in defaults: UserDefaults, faces: [String]) -> AgentLandWordmarkStyle? {
        guard let face = defaults.object(forKey: lastFaceKey) as? String, faces.contains(face),
              let raw = defaults.object(forKey: lastLookKey) as? String, let look = AgentLandWordmarkLook(rawValue: raw)
        else { return nil }
        return AgentLandWordmarkStyle(face: face, look: look)
    }

    /// A face from `faces` and a look, each different from the last when there is a choice.
    public mutating func nextStyle(faces: [String], saving defaults: UserDefaults? = nil) -> AgentLandWordmarkStyle {
        let faceChoices = faces.count > 1 ? faces.filter { $0 != lastStyle?.face } : faces
        let face = faceChoices.randomElement(using: &generator) ?? "rubberHose"
        let lookChoices = AgentLandWordmarkLook.allCases.filter { $0 != lastStyle?.look }
        let look = lookChoices.randomElement(using: &generator) ?? .bevel
        let style = AgentLandWordmarkStyle(face: face, look: look)
        lastStyle = style
        defaults?.set(face, forKey: Self.lastFaceKey)
        defaults?.set(look.rawValue, forKey: Self.lastLookKey)
        return style
    }

    /// The previous launch's last entrance, read defensively: anything unreadable counts as none.
    public static func savedEntrance(in defaults: UserDefaults) -> AgentLandWordmarkEntrance? {
        guard let raw = defaults.object(forKey: lastEntranceKey) as? String else { return nil }
        return AgentLandWordmarkEntrance(rawValue: raw)
    }

    public mutating func nextEntrance(saving defaults: UserDefaults? = nil) -> AgentLandWordmarkEntrance {
        let choices = AgentLandWordmarkEntrance.allCases.filter { $0 != lastEntrance }
        let choice = choices.randomElement(using: &generator) ?? .dropAndBounce
        lastEntrance = choice
        defaults?.set(choice.rawValue, forKey: Self.lastEntranceKey)
        return choice
    }

    public mutating func nextFlourish() -> AgentLandWordmarkFlourish {
        let choices = AgentLandWordmarkFlourish.allCases.filter { $0 != lastFlourish }
        let choice = choices.randomElement(using: &generator) ?? .ripple
        lastFlourish = choice
        return choice
    }

    /// Seconds until the next idle flourish.
    public mutating func idleDelay() -> TimeInterval {
        Double.random(in: 20...30, using: &generator)
    }

    public mutating func nextSeed() -> UInt64 { generator.next() }
}

// MARK: - Choreography

/// One keyframe track, described as data so tests can check it without a render server. Only
/// `transform.*`, `opacity` and `contents` are animated: never `position`, which identifies the clown's
/// orbit in the circus tests.
struct WordmarkTrack {
    enum Target: Hashable { case letter(Int), letterMask(Int), bulb(Int) }
    enum Value { case number(Double), image(CGImage) }
    /// Between keyframes: eased, alternately falling and rising (bounces), or straight (sampled curves).
    enum Easing { case easeInOut, bounce, linear }

    let target: Target
    let keyPath: String
    let values: [Value]
    /// One more than `values` for discrete tracks, as Core Animation expects; otherwise equal.
    let keyTimes: [Double]
    let duration: Double
    /// Seconds after the choreography starts.
    let delay: Double
    let discrete: Bool
    var easing: Easing = .easeInOut

    static let allowedKeyPaths: Set<String> = [
        "opacity", "contents", "transform.translation.x", "transform.translation.y", "transform.scale",
        "transform.scale.x", "transform.scale.y", "transform.rotation.z", "transform.rotation.y", "transform.rotation.x",
    ]

    var end: Double { delay + duration }

    var numbers: [Double] { values.compactMap { if case let .number(value) = $0 { value } else { nil } } }
}

enum WordmarkChoreography {
    static let beat = 0.3

    static func entrance(_ kind: AgentLandWordmarkEntrance, stage: WordmarkStage, seed: UInt64) -> [WordmarkTrack] {
        let set = stage.set, artwork = set.classic
        let letters = set.boxes.indices
        switch kind {
        case .dropAndBounce:
            // Each letter falls from above, lands and settles with two smaller bounces.
            return letters.flatMap { index -> [WordmarkTrack] in
                let delay = Double(index) * 0.05
                return [
                    track(.letter(index), "transform.translation.y", [-58, 0, -13, 0, -4, 0],
                          [0, 0.42, 0.6, 0.76, 0.88, 1], duration: 0.9, delay: delay, easing: .bounce),
                    track(.letter(index), "opacity", [0, 1, 1], [0, 0.18, 1], duration: 0.9, delay: delay),
                ]
            }
        case .marqueeLightUp:
            // A run of bulbs sweeps the arch; each unlit letter switches on as the run reaches it.
            let sweep = 0.75
            var tracks: [WordmarkTrack] = letters.map { index in
                let reached = 0.02 + sweep * set.fraction(ofLetter: index)
                return track(.letter(index), "opacity", [0.12, 0.12, 1, 1],
                             [0, reached / 1.25, (reached + 0.1) / 1.25, 1], duration: 1.25, delay: 0)
            }
            tracks += artwork.bulbs.indices.map { index in
                let lit = 0.02 + sweep * Double(index) / Double(max(1, artwork.bulbs.count - 1))
                return track(.bulb(index), "opacity", [0, 0, 1, 1, 0],
                             [0, lit / 1.3, (lit + 0.05) / 1.3, 0.8, 1], duration: 1.3, delay: 0)
            }
            return tracks
        case .flipIn:
            return letters.flatMap { index -> [WordmarkTrack] in
                let delay = Double(index) * 0.08
                return [
                    track(.letter(index), "transform.rotation.y", [-Double.pi / 2, 0.22, -0.08, 0], [0, 0.6, 0.82, 1],
                          duration: 0.6, delay: delay),
                    track(.letter(index), "opacity", [0, 1, 1], [0, 0.3, 1], duration: 0.6, delay: delay),
                ]
            }
        case .arcUnfurl:
            // Letters open along the arc from left to right, each turning up from its baseline.
            return letters.flatMap { index -> [WordmarkTrack] in
                let delay = Double(index) * 0.09
                return [
                    track(.letter(index), "transform.scale", [0.2, 1.12, 1], [0, 0.65, 1], duration: 0.5, delay: delay),
                    track(.letter(index), "transform.rotation.z", [-0.6, 0.06, 0], [0, 0.65, 1], duration: 0.5, delay: delay),
                    track(.letter(index), "opacity", [0, 1, 1], [0, 0.35, 1], duration: 0.5, delay: delay),
                ]
            }
        case .pixelAssemble:
            // Each letter gathers its pixels in a seeded order, stepping on the tent's grid.
            return letters.map { index in
                let frames = set.revealMasks(stage.style, slot: index, count: 6, order: .seeded(seed &+ UInt64(index)))
                return discreteTrack(.letterMask(index), frames, duration: 0.8, delay: Double(index) * 0.06)
            }
        case .curtainWipe:
            // Revealed column by column from the middle of the arch outward.
            let middle = Double(letters.count - 1) / 2
            return letters.map { index in
                let frames = set.revealMasks(stage.style, slot: index, count: 6, order: .columnsFromMiddle(fromLeft: set.angles[index] >= 0))
                return discreteTrack(.letterMask(index), frames, duration: 0.6, delay: abs(Double(index) - middle) * 0.15)
            }
        case .tossUp:
            // Juggled up from below: each letter arcs over and lands with a squash, straightening as it lands.
            return letters.flatMap { index -> [WordmarkTrack] in
                let delay = Double(index) * 0.06, squash = [0, 0.3, 0.72, 0.8, 0.92, 1.0]
                return [
                    track(.letter(index), "transform.translation.y", [68, -24, 0, 0], [0, 0.38, 0.72, 1], duration: 0.9, delay: delay, easing: .bounce),
                    track(.letter(index), "transform.scale.y", [1.15, 1.08, 1, 0.74, 1.06, 1], squash, duration: 0.9, delay: delay),
                    track(.letter(index), "transform.scale.x", [0.9, 0.95, 1, 1.16, 0.97, 1], squash, duration: 0.9, delay: delay),
                    track(.letter(index), "transform.rotation.z", [-0.5, 0, 0], [0, 0.72, 1], duration: 0.9, delay: delay),
                    track(.letter(index), "opacity", [0, 1, 1], [0, 0.1, 1], duration: 0.9, delay: delay),
                ]
            }
        case .spinIn:
            // Each letter spins twice round its upright axis, in a wave from the left.
            return letters.flatMap { index -> [WordmarkTrack] in
                let delay = Double(index) * 0.07
                return [
                    track(.letter(index), "transform.rotation.y", [-4 * Double.pi, 0], [0, 1], duration: 0.75, delay: delay),
                    track(.letter(index), "opacity", [0, 1, 1], [0, 0.15, 1], duration: 0.75, delay: delay),
                ]
            }
        case .slotShuffle:
            // Each letter flicks through eight other faces like a slot reel and lands on the load's face.
            let others = set.faces.map(\.id).filter { $0 != stage.style.face }
            return letters.flatMap { index -> [WordmarkTrack] in
                let delay = Double(index) * 0.06
                var tracks = [track(.letter(index), "transform.scale.y", [1, 1, 1.12, 1], [0, 0.9, 0.95, 1], duration: 0.8, delay: delay)]
                guard !others.isEmpty else { return tracks }
                var generator = AgentLandSeededGenerator(seed: seed &+ UInt64(index))
                var reel: [String] = []
                for _ in 0..<8 {
                    let choices = others.count > 1 ? others.filter { $0 != reel.last } : others
                    reel.append(choices.randomElement(using: &generator) ?? others[0])
                }
                let styles = reel.map { AgentLandWordmarkStyle(face: $0, look: stage.style.look) } + [stage.style]
                if let ramp = stage.ramp {
                    tracks.append(discreteTrack(.letter(index), styles.compactMap { set.face($0, slot: index, ramp: ramp) },
                                                duration: 0.8, delay: delay))
                }
                tracks.append(discreteTrack(.letterMask(index), styles.compactMap { set.mask($0, slot: index) }, duration: 0.8, delay: delay))
                return tracks
            }
        case .inkFill:
            // Each letter fills with ink from the bottom up.
            return letters.map { index in
                discreteTrack(.letterMask(index), set.revealMasks(stage.style, slot: index, count: 8, order: .rowsFromBottom),
                              duration: 0.7, delay: Double(index) * 0.06)
            }
        case .stamp:
            // Letters press down one by one, squashing on impact and recoiling.
            return letters.flatMap { index -> [WordmarkTrack] in
                let delay = Double(index) * 0.1, times = [0, 0.45, 0.62, 0.82, 1.0]
                return [
                    track(.letter(index), "transform.scale.x", [1.7, 1.18, 1.22, 0.97, 1], times, duration: 0.45, delay: delay),
                    track(.letter(index), "transform.scale.y", [1.7, 0.74, 0.8, 1.05, 1], times, duration: 0.45, delay: delay),
                    track(.letter(index), "opacity", [0, 1, 1], [0, 0.2, 1], duration: 0.45, delay: delay),
                ]
            }
        case .stretchSnap:
            // Letters arrive tall and thin and snap to shape with a wobble.
            return letters.flatMap { index -> [WordmarkTrack] in
                let delay = Double(index) * 0.06, times = [0, 0.4, 0.65, 0.85, 1.0]
                return [
                    track(.letter(index), "transform.scale.y", [2.2, 0.8, 1.08, 0.97, 1], times, duration: 0.7, delay: delay),
                    track(.letter(index), "transform.scale.x", [0.45, 1.18, 0.95, 1.02, 1], times, duration: 0.7, delay: delay),
                    track(.letter(index), "opacity", [0, 1, 1], [0, 0.15, 1], duration: 0.7, delay: delay),
                ]
            }
        }
    }

    /// `beatDelay` postpones the flourish to the next beat of the circus clock.
    static func flourish(_ kind: AgentLandWordmarkFlourish, stage: WordmarkStage, seed: UInt64, beatDelay: Double) -> [WordmarkTrack] {
        var generator = AgentLandSeededGenerator(seed: seed)
        let set = stage.set, artwork = set.classic
        let letters = set.boxes.indices
        switch kind {
        case .bulbChase:
            // Every fourth bulb lit, stepping along the arch twice per beat for eight beats.
            // Each bulb is on for one step in four (1.7 Hz); the run then goes dark.
            let step = beat / 2, steps = 16
            return artwork.bulbs.indices.map { index in
                let values = (0..<steps).map { moment -> Double in (moment - index % 4 + 4) % 4 == 0 ? 1 : 0 } + [0]
                return WordmarkTrack(target: .bulb(index), keyPath: "opacity", values: values.map { .number($0) },
                                     keyTimes: (0...values.count).map { Double($0) / Double(values.count) },
                                     duration: Double(values.count) * step, delay: beatDelay, discrete: true)
            }
        case .ripple:
            return letters.map { index in
                track(.letter(index), "transform.scale", [1, 1.16, 1], [0, 0.45, 1], duration: 0.36,
                      delay: beatDelay + Double(index) * 0.07)
            }
        case .looseLetter:
            // One letter works loose and swings back into place.
            let index = letters.randomElement(using: &generator) ?? 0
            return [track(.letter(index), "transform.rotation.z", [0, 0.24, -0.17, 0.1, -0.05, 0.02, 0],
                          [0, 0.16, 0.36, 0.55, 0.72, 0.87, 1], duration: 1.6, delay: beatDelay)]
        case .juggleHop:
            // One letter hops like a juggled ball, landing on each of four circus beats.
            let index = letters.randomElement(using: &generator) ?? 0
            let hop = (0...8).map { step -> Double in
                let t = Double(step) / 8
                return -9 * 4 * t * (1 - t)
            }
            var values: [Double] = [], times: [Double] = []
            for bounce in 0..<4 {
                for (step, value) in hop.enumerated() where !(bounce > 0 && step == 0) {
                    values.append(value)
                    times.append((Double(bounce) + Double(step) / 8) / 4)
                }
            }
            return [track(.letter(index), "transform.translation.y", values, times, duration: 4 * beat, delay: beatDelay,
                          easing: .linear)]
        case .marqueeBlink:
            // Two gentle dips, 0.6 s apart (under 2 Hz), never to black.
            return letters.map { index in
                track(.letter(index), "opacity", [1, 0.4, 1, 0.4, 1], [0, 0.25, 0.5, 0.75, 1], duration: 1.2, delay: beatDelay)
            }
        case .fontFlip:
            // A wave of letters flips edge-on into another face, holds it, and flips back.
            guard let other = otherStyle(stage, using: &generator) else { return [] }
            let times = [0, 0.18, 0.36, 1.74, 1.92, 2.1].map { $0 / 2.1 }, swaps = [0, 0.18, 1.92, 2.1].map { $0 / 2.1 }
            return letters.flatMap { index -> [WordmarkTrack] in
                let delay = beatDelay + Double(index) * 0.08
                var tracks = [track(.letter(index), "transform.scale.x", [1, 0.02, 1, 1, 0.02, 1], times, duration: 2.1, delay: delay)]
                let styles = [stage.style, other, stage.style]
                if let ramp = stage.ramp {
                    tracks.append(timedTrack(.letter(index), styles.compactMap { set.face($0, slot: index, ramp: ramp) }, swaps, duration: 2.1, delay: delay))
                }
                tracks.append(timedTrack(.letterMask(index), styles.compactMap { set.mask($0, slot: index) }, swaps, duration: 2.1, delay: delay))
                return tracks
            }
        case .fontDissolve:
            // Letters dissolve pixel by pixel into another face, hold it, and dissolve back.
            guard let other = otherStyle(stage, using: &generator) else { return [] }
            let step = 0.5 / 6
            let starts = (0...6).map { Double($0) * step } + (1...6).map { 1.7 + Double($0 - 1) * step }
            let times = (starts + [2.2]).map { $0 / 2.2 }
            return letters.flatMap { index -> [WordmarkTrack] in
                let delay = beatDelay + Double(index) * 0.05
                let frames = set.dissolve(from: stage.style, to: other, slot: index, steps: 6, seed: seed &+ UInt64(index), ramp: stage.ramp)
                let order = Array(0...6) + Array((0...5).reversed())
                var tracks = [timedTrack(.letterMask(index), order.map { frames.masks[$0] }, times, duration: 2.2, delay: delay)]
                if stage.ramp != nil { tracks.append(timedTrack(.letter(index), order.map { frames.faces[$0] }, times, duration: 2.2, delay: delay)) }
                return tracks
            }
        case .jellyWobble:
            return letters.flatMap { index -> [WordmarkTrack] in
                let delay = beatDelay + Double(index) * 0.06, times = [0, 0.2, 0.4, 0.6, 0.8, 1.0]
                return [track(.letter(index), "transform.scale.x", [1, 1.18, 0.88, 1.08, 0.96, 1], times, duration: 0.9, delay: delay),
                        track(.letter(index), "transform.scale.y", [1, 0.84, 1.12, 0.94, 1.03, 1], times, duration: 0.9, delay: delay)]
            }
        case .dominoTip:
            // Letters tip over in turn and spring back upright.
            return letters.map { index in
                track(.letter(index), "transform.rotation.z", [0, 0.5, -0.08, 0.03, 0], [0, 0.35, 0.6, 0.8, 1],
                      duration: 0.8, delay: beatDelay + Double(index) * 0.09)
            }
        case .sparkleTwinkle:
            // Fourteen single white glints, each on its own pixel, each lit once for 0.24 s.
            guard let ramp = stage.ramp else { return [] }
            let points = set.sparkles(stage.style, seed: seed, count: 14)
            return letters.compactMap { index -> WordmarkTrack? in
                let mine = points.enumerated().filter { $0.element.slot == index }
                guard !mine.isEmpty, let plain = set.face(stage.style, slot: index, ramp: ramp) else { return nil }
                var images = [plain], starts = [0.0]
                for (position, (order, point)) in mine.enumerated() {
                    let start = 0.1 + 0.16 * Double(order)
                    let next = position + 1 < mine.count ? 0.1 + 0.16 * Double(mine[position + 1].offset) : 2.4
                    guard let glint = set.face(stage.style, slot: index, ramp: ramp, sparkle: (point.column, point.row)) else { continue }
                    images.append(glint); starts.append(start)
                    if start + 0.24 < next { images.append(plain); starts.append(start + 0.24) }
                }
                if images.last !== plain { images.append(plain); starts.append(min(2.4, starts.last! + 0.24)) }
                return timedTrack(.letter(index), images, (starts + [2.4]).map { $0 / 2.4 }, duration: 2.4, delay: beatDelay)
            }
        case .spotlightSweep:
            // A bright band sweeps the arch, lifting each letter one tone while it passes.
            guard let ramp = stage.ramp else { return [] }
            return letters.compactMap { index -> WordmarkTrack? in
                let fraction = set.fraction(ofLetter: index)
                let on = max(0, (fraction - 0.11 + 0.15) * 1.2 / 1.3), off = min(1.2, (fraction + 0.11 + 0.15) * 1.2 / 1.3)
                guard let plain = set.face(stage.style, slot: index, ramp: ramp),
                      let lit = set.face(stage.style, slot: index, ramp: ramp, boosted: true) else { return nil }
                return timedTrack(.letter(index), [plain, lit, plain], [0, on / 1.3, off / 1.3, 1], duration: 1.3, delay: beatDelay)
            }
        case .leapfrog:
            // Two neighbours swap places, one hopping over the other, pause, and swap back.
            let a = Int(generator.next() % UInt64(max(1, letters.count - 1))), b = a + 1
            guard b < letters.count else { return [] }
            return [(a, b, -26.0), (b, a, 4.0)].flatMap { mover, target, hop -> [WordmarkTrack] in
                let dx = Double(set.pivots[target].x - set.pivots[mover].x), dy = Double(set.pivots[target].y - set.pivots[mover].y)
                let turn = Double(set.angles[target] - set.angles[mover])
                var times: [Double] = [], progress: [Double] = [], lift: [Double] = []
                for (start, forward) in [(0.0, true), (1.4, false)] {
                    for sample in 0...16 {
                        let p = Double(sample) / 16, eased = p * p * (3 - 2 * p)
                        times.append((start + 0.6 * p) / 2.0)
                        progress.append(forward ? eased : 1 - eased)
                        lift.append(hop * 4 * p * (1 - p))
                    }
                }
                func sampled(_ keyPath: String, _ values: [Double]) -> WordmarkTrack {
                    track(.letter(mover), keyPath, values, times, duration: 2.0, delay: beatDelay, easing: .linear)
                }
                return [sampled("transform.translation.x", progress.map { $0 * dx }),
                        sampled("transform.translation.y", zip(progress, lift).map { $0 * dy + $1 }),
                        sampled("transform.rotation.z", progress.map { $0 * turn })]
            }
        case .dripAndReform:
            // Ink drips from the letters' bottoms and pulls back into shape.
            let times = [0, 0.1125, 0.225, 0.3375, 0.45, 0.5875, 0.725, 0.8625, 0.95, 1]
            return letters.flatMap { index -> [WordmarkTrack] in
                let delay = beatDelay + Double(index) * 0.05
                let frames = set.drip(stage.style, slot: index, steps: 4, seed: seed &+ UInt64(index), ramp: stage.ramp)
                var tracks = [timedTrack(.letterMask(index), frames.masks, times, duration: 1.1, delay: delay)]
                if stage.ramp != nil { tracks.append(timedTrack(.letter(index), frames.faces, times, duration: 1.1, delay: delay)) }
                return tracks
            }
        }
    }

    /// Another face in the load's look, for the morphs; nil when there is no other face.
    private static func otherStyle(_ stage: WordmarkStage, using generator: inout AgentLandSeededGenerator) -> AgentLandWordmarkStyle? {
        let others = stage.set.faces.map(\.id).filter { $0 != stage.style.face }
        return others.randomElement(using: &generator).map { AgentLandWordmarkStyle(face: $0, look: stage.style.look) }
    }

    /// Discrete images at given key times (one more key time than images, the last 1).
    private static func timedTrack(_ target: WordmarkTrack.Target, _ frames: [CGImage], _ keyTimes: [Double],
                                   duration: Double, delay: Double) -> WordmarkTrack {
        WordmarkTrack(target: target, keyPath: "contents", values: frames.map { .image($0) }, keyTimes: keyTimes,
                      duration: duration, delay: delay, discrete: true)
    }

    private static func track(_ target: WordmarkTrack.Target, _ keyPath: String, _ values: [Double], _ keyTimes: [Double],
                              duration: Double, delay: Double, easing: WordmarkTrack.Easing = .easeInOut) -> WordmarkTrack {
        WordmarkTrack(target: target, keyPath: keyPath, values: values.map { .number($0) }, keyTimes: keyTimes,
                      duration: duration, delay: delay, discrete: false, easing: easing)
    }

    private static func discreteTrack(_ target: WordmarkTrack.Target, _ frames: [CGImage], duration: Double, delay: Double) -> WordmarkTrack {
        WordmarkTrack(target: target, keyPath: "contents", values: frames.map { .image($0) },
                      keyTimes: (0...frames.count).map { Double($0) / Double(max(1, frames.count)) },
                      duration: duration, delay: delay, discrete: true)
    }
}

extension WordmarkFontSet {
    /// How far along the arch a letter slot sits, from 0 (left end) to 1 (right end).
    func fraction(ofLetter index: Int) -> Double {
        guard angles.count > 1 else { return 0 }
        let angle = Double(angles[index]), half = Double(AgentLandWordmarkGeometry.sweep) / 2
        return min(1, max(0, (angle + half) / (2 * half)))
    }
}
