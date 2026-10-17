import SwiftUI
import QuartzCore
#if os(iOS)
import UIKit
#endif

/// The circus loader (owner's request, 2026-10-04): ten 3D circus objects in the riders' tones that melt into
/// one another with rubber-hose timing. `scripts/package-circus-loader.mjs` renders every object's idle bounce
/// and every melt between two objects into the `CircusLoader…` strips, in the day and the night tones; a run
/// here is a random order through some of them in its backdrop's tones, played as Core Animation `contents` keyframes on
/// the render server so a busy main thread never holds it. It pops in out of nothing and pops out again.
enum AgentLandCircusLoaderFrames {
    struct Manifest: Decodable {
        let side: Int
        let framesPerSecond: Double
        let idleFrames: Int
        let changeFrames: Int
        let objects: [String]
    }

    static let manifest = AgentLandBrandingResources.json("CircusLoader", as: Manifest.self)
    /// Objects in one run before it loops.
    static let runLength = 5

    /// A random run: each object bounces twice at rest and melts into the next, the last into the first. Under
    /// Reduce Motion each object rests still for a second instead, with no bounce and no melt.
    static func run(ramp: AgentLandClownRamp, reduceMotion: Bool) -> [CGImage] {
        guard let manifest, manifest.objects.count > 1 else { return [] }
        let order = Array(manifest.objects.shuffled().prefix(runLength))
        var frames: [CGImage] = []
        for (index, object) in order.enumerated() {
            let idle = strip("Idle-\(object)", ramp: ramp)
            if reduceMotion {
                if let rest = idle.first { frames += Array(repeating: rest, count: Int(manifest.framesPerSecond)) }
                continue
            }
            frames += idle + idle
            frames += strip("Change-\(object)-\(order[(index + 1) % order.count])", ramp: ramp)
        }
        return frames
    }

    /// A packaged strip in the backdrop's tones: both are packaged, so nothing is recoloured at launch.
    private static func strip(_ name: String, ramp: AgentLandClownRamp) -> [CGImage] {
        AgentLandBrandingResources.strip((ramp == .day ? "CircusLoader" : "CircusLoaderNight") + name, side: manifest?.side ?? 96)
    }
}

/// Runs made ahead, off the main thread, so a loader that appears never waits to decode: one per backdrop and
/// motion setting, replaced by a fresh random run each time one is taken.
final class AgentLandCircusLoaderRuns: @unchecked Sendable {
    static let shared = AgentLandCircusLoaderRuns()
    private let lock = NSLock()
    private var ready: [String: [CGImage]] = [:]
    private var making: Set<String> = []

    private func key(_ ramp: AgentLandClownRamp, _ reduceMotion: Bool) -> String { "\(ramp)-\(reduceMotion)" }

    /// Starts making a run for this backdrop and motion setting unless one is ready or on its way.
    func prepare(ramp: AgentLandClownRamp, reduceMotion: Bool) {
        let key = key(ramp, reduceMotion)
        lock.lock()
        guard ready[key] == nil, !making.contains(key) else { lock.unlock(); return }
        making.insert(key)
        lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async {
            let run = AgentLandCircusLoaderFrames.run(ramp: ramp, reduceMotion: reduceMotion)
            self.lock.lock()
            self.ready[key] = run
            self.making.remove(key)
            self.lock.unlock()
        }
    }

    /// The ready run, if any, and a fresh one started for next time.
    func take(ramp: AgentLandClownRamp, reduceMotion: Bool) -> [CGImage]? {
        let key = key(ramp, reduceMotion)
        lock.lock()
        let run = ready.removeValue(forKey: key)
        lock.unlock()
        prepare(ramp: ramp, reduceMotion: reduceMotion)
        return run
    }

    /// Calls `body` on the main queue with a run as soon as one is ready.
    func whenReady(ramp: AgentLandClownRamp, reduceMotion: Bool, _ body: @escaping @MainActor ([CGImage]) -> Void) {
        if let run = take(ramp: ramp, reduceMotion: reduceMotion) {
            DispatchQueue.main.async { body(run) }
            return
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.02) {
            self.whenReady(ramp: ramp, reduceMotion: reduceMotion, body)
        }
    }
}

/// The loader on its own, always shown: the opening, lock and loading covers. It pops in as soon as its run
/// is ready. Decorative: callers give it the words VoiceOver reads.
public struct AgentLandCircusLoader: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private let forceReduceMotion: Bool?

    /// The loader's frame: its objects stand about two thirds as tall.
    public static let side: CGFloat = 96

    public init(forceReduceMotion: Bool? = nil) {
        self.forceReduceMotion = forceReduceMotion
    }

    /// Starts making the first runs off the main thread; call it as early as the app can.
    public static func prepare() {
        for ramp in AgentLandClownRamp.allCases { AgentLandCircusLoaderRuns.shared.prepare(ramp: ramp, reduceMotion: false) }
    }

    public var body: some View {
        loader
            .frame(width: Self.side, height: Self.side)
            .allowsHitTesting(false)
    }

    @ViewBuilder private var loader: some View {
        #if os(iOS)
        CircusLoaderLayerView(shown: true, ramp: colorScheme == .dark ? .night : .day,
                              reduceMotion: forceReduceMotion ?? systemReduceMotion)
        #else
        CircusLoaderTimeline(ramp: colorScheme == .dark ? .night : .day, reduceMotion: forceReduceMotion ?? systemReduceMotion)
        #endif
    }
}

/// The fade between views (owner's request, 2026-10-04): while `covered`, a layer of `color` fades in over
/// everything under it with the circus loader popping up in its middle; when it turns false the loader pops
/// away and the layer fades out, each over `duration`, as Core Animation on the render server. The caller keeps
/// it covered until the next view is on screen. Never hit-tested.
public struct AgentLandTransitionCurtain: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let covered: Bool
    private let duration: TimeInterval
    private let color: Color

    public init(covered: Bool, duration: TimeInterval = 0.25, color: Color) {
        self.covered = covered
        self.duration = duration
        self.color = color
    }

    public var body: some View {
        content
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    @ViewBuilder private var content: some View {
        #if os(iOS)
        TransitionCurtainLayerView(covered: covered, duration: duration, color: color,
                                   ramp: colorScheme == .dark ? .night : .day, reduceMotion: reduceMotion)
        #else
        color.opacity(covered ? 1 : 0)
        #endif
    }
}

#if os(iOS)
private struct CircusLoaderLayerView: UIViewRepresentable {
    let shown: Bool
    let ramp: AgentLandClownRamp
    let reduceMotion: Bool

    func makeUIView(context: Context) -> CircusLoaderView {
        let view = CircusLoaderView()
        view.configure(ramp: ramp, reduceMotion: reduceMotion)
        view.setShown(shown)
        return view
    }

    func updateUIView(_ view: CircusLoaderView, context: Context) {
        view.configure(ramp: ramp, reduceMotion: reduceMotion)
        view.setShown(shown)
    }
}

/// The loader's layer: its run as `contents` keyframes, popping in (up from nothing with a rubber-hose
/// overshoot) and out (a little rise, then down to nothing) about the object's shadow on the floor.
final class CircusLoaderView: UIView {
    /// How long the loader takes to pop away; the transition curtain lifts once it has.
    static let popOutDuration: CFTimeInterval = 0.22
    private let sprite = CALayer()
    private var ramp: AgentLandClownRamp = .night
    private var reduceMotion = false
    private var shown = false
    /// Counts shows, so a run that arrives after its show has ended is not played.
    private var show = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        sprite.magnificationFilter = .nearest
        sprite.contentsGravity = .resizeAspect
        // The floor under the objects, where their shadow is: they pop up out of it and back into it.
        sprite.anchorPoint = CGPoint(x: 0.5, y: 0.84)
        sprite.opacity = 0
        layer.addSublayer(sprite)
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sprite.bounds = bounds
        sprite.position = CGPoint(x: bounds.minX + bounds.width * 0.5, y: bounds.minY + bounds.height * 0.84)
        CATransaction.commit()
    }

    func configure(ramp: AgentLandClownRamp, reduceMotion: Bool) {
        self.ramp = ramp
        self.reduceMotion = reduceMotion
        AgentLandCircusLoaderRuns.shared.prepare(ramp: ramp, reduceMotion: reduceMotion)
    }

    func setShown(_ value: Bool) {
        guard value != shown else { return }
        shown = value
        show += 1
        if value { appear() } else { disappear() }
    }

    private func appear() {
        let current = show
        AgentLandCircusLoaderRuns.shared.whenReady(ramp: ramp, reduceMotion: reduceMotion) { [weak self] run in
            guard let self, self.shown, self.show == current, !run.isEmpty else { return }
            self.play(run)
            self.pop(in: true)
        }
    }

    private func disappear() {
        guard sprite.animation(forKey: "run") != nil else { return }
        pop(in: false)
    }

    private func play(_ run: [CGImage]) {
        let fps = AgentLandCircusLoaderFrames.manifest?.framesPerSecond ?? 15
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sprite.contents = run[0]
        CATransaction.commit()
        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = run
        animation.calculationMode = .discrete
        animation.duration = CFTimeInterval(Double(run.count) / fps)
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        sprite.add(animation, forKey: "run")
    }

    private func pop(in appearing: Bool) {
        let scale = CAKeyframeAnimation(keyPath: "transform.scale")
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        if reduceMotion {
            scale.values = [1, 1]
            fade.values = appearing ? [0, 1] : [1, 0]
            scale.duration = 0.2
            fade.duration = 0.2
        } else if appearing {
            scale.values = [0.01, 1.18, 0.92, 1]
            scale.keyTimes = [0, 0.5, 0.78, 1]
            scale.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut),
                                     CAMediaTimingFunction(name: .easeOut)]
            scale.duration = 0.34
            fade.values = [0, 1, 1]
            fade.keyTimes = [0, 0.25, 1]
            fade.duration = 0.34
        } else {
            scale.values = [1, 1.12, 0.01]
            scale.keyTimes = [0, 0.35, 1]
            scale.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeIn)]
            scale.duration = Self.popOutDuration
            fade.values = [1, 1, 0]
            fade.keyTimes = [0, 0.75, 1]
            fade.duration = Self.popOutDuration
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if !appearing {
            let current = show
            CATransaction.setCompletionBlock { [weak self] in
                guard let self, !self.shown, self.show == current else { return }
                // Gone: stop playing until the next show.
                self.sprite.removeAnimation(forKey: "run")
            }
        }
        sprite.opacity = appearing ? 1 : 0
        sprite.transform = CATransform3DMakeScale(appearing || reduceMotion ? 1 : 0.01, appearing || reduceMotion ? 1 : 0.01, 1)
        sprite.add(scale, forKey: "popScale")
        sprite.add(fade, forKey: "popFade")
        CATransaction.commit()
    }
}

private struct TransitionCurtainLayerView: UIViewRepresentable {
    let covered: Bool
    let duration: TimeInterval
    let color: Color
    let ramp: AgentLandClownRamp
    let reduceMotion: Bool

    func makeUIView(context: Context) -> TransitionCurtainView {
        let view = TransitionCurtainView()
        view.configure(covered: covered, duration: duration, color: UIColor(color), ramp: ramp, reduceMotion: reduceMotion, initial: true)
        return view
    }

    func updateUIView(_ view: TransitionCurtainView, context: Context) {
        view.configure(covered: covered, duration: duration, color: UIColor(color), ramp: ramp, reduceMotion: reduceMotion, initial: false)
    }
}

private final class TransitionCurtainView: UIView {
    private let backdrop = CALayer()
    private let loader = CircusLoaderView()
    private var covered = false
    private var color: UIColor = .clear

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backdrop.opacity = 0
        layer.addSublayer(backdrop)
        addSubview(loader)
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdrop.frame = bounds
        CATransaction.commit()
        let side = AgentLandCircusLoader.side
        loader.frame = CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        backdrop.backgroundColor = color.resolvedColor(with: traitCollection).cgColor
    }

    func configure(covered value: Bool, duration: TimeInterval, color: UIColor, ramp: AgentLandClownRamp, reduceMotion: Bool, initial: Bool) {
        self.color = color
        backdrop.backgroundColor = color.resolvedColor(with: traitCollection).cgColor
        loader.configure(ramp: ramp, reduceMotion: reduceMotion)
        if initial {
            covered = value
            backdrop.opacity = value ? 1 : 0
            loader.setShown(value)
            return
        }
        guard value != covered else { return }
        covered = value
        loader.setShown(value)
        // From wherever a fade under way has got to. Uncovering waits for the loader's pop away to finish, so
        // it never shrinks over the new view.
        let from = backdrop.presentation()?.opacity ?? backdrop.opacity
        let target: Float = value ? 1 : 0
        // The explicit fade below owns opacity. In particular, an immediate session cover must not
        // inherit CALayer's implicit fade and expose a fast host's newly mounted surface beneath it.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdrop.opacity = target
        CATransaction.commit()
        if value && duration == 0 {
            backdrop.removeAnimation(forKey: "fade")
            return
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from
        fade.toValue = target
        fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        if !value {
            fade.beginTime = CACurrentMediaTime() + CircusLoaderView.popOutDuration
            fade.fillMode = .backwards
        }
        backdrop.add(fade, forKey: "fade")
    }
}
#else
/// The Mac draws the loader with a timeline (it has no covers that hold the main thread).
private struct CircusLoaderTimeline: View {
    let ramp: AgentLandClownRamp
    let reduceMotion: Bool
    @State private var run: [CGImage] = []

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / (AgentLandCircusLoaderFrames.manifest?.framesPerSecond ?? 15))) { context in
            if !run.isEmpty {
                let fps = AgentLandCircusLoaderFrames.manifest?.framesPerSecond ?? 15
                let frame = run[Int(context.date.timeIntervalSinceReferenceDate * fps) % run.count]
                Image(decorative: frame, scale: 1).interpolation(.none).resizable()
            }
        }
        .task { run = AgentLandCircusLoaderFrames.run(ramp: ramp, reduceMotion: reduceMotion) }
    }
}
#endif
