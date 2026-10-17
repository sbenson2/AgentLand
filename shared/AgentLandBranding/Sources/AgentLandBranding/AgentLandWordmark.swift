import QuartzCore
import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// The arched "AGENTLAND" title: one Core Animation layer per letter, each the letter's pixel bitmap on
/// the tent's grid (nearest-neighbour), tinted like the tent on the same surface. Entrances and flourishes
/// are keyframes on the render server, like the opening circus, and animate only `transform.*`, `opacity`
/// and `contents`. Motion follows the circus's gate; otherwise the letters rest on the arch.
public struct AgentLandWordmark: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    #if os(macOS)
    @State private var macAppIsActive = NSApp.isActive
    #else
    @Environment(\.scenePhase) private var scenePhase
    #endif
    @State private var flourishRequests = 0

    private let color: Color
    private let active: Bool
    private let referenceDate: Date
    private let onTap: (() -> Void)?
    private let tonalArt: Bool

    /// `active` is true while the title is visible and uncovered. `referenceDate` is the circus clock,
    /// so flourishes land on the clown's beat.
    public init(color: Color, active: Bool, referenceDate: Date, onTap: (() -> Void)? = nil, tonalArt: Bool = false) {
        self.color = color
        self.active = active
        self.referenceDate = referenceDate
        self.onTap = onTap
        self.tonalArt = tonalArt
    }

    /// The canvas (every letter and bulb) in circus scene units; the arch is centred on x = 168.
    public static var canvas: CGRect { AgentLandWordmarkGeometry.canvas }

    public var body: some View {
        content
            .contentShape(Rectangle())
            .onTapGesture(perform: tapped)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("AgentLand")
            .accessibilityAddTraits(.isHeader)
            .accessibilityAction(named: "Next quip", tapped)
    }

    private func tapped() {
        flourishRequests += 1
        onTap?()
    }

    @ViewBuilder private var content: some View {
        #if os(macOS)
        WordmarkRepresentable(color: color, motionAllowed: motionAllowed, referenceDate: referenceDate,
                              flourishRequests: flourishRequests, ramp: tonalArt ? (colorScheme == .dark ? .night : .day) : nil)
            .onAppear { macAppIsActive = NSApp.isActive }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                macAppIsActive = true
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                macAppIsActive = false
            }
        #else
        WordmarkRepresentable(color: color, motionAllowed: motionAllowed, referenceDate: referenceDate,
                              flourishRequests: flourishRequests, ramp: tonalArt ? (colorScheme == .dark ? .night : .day) : nil)
        #endif
    }

    private var motionAllowed: Bool {
        #if os(macOS)
        // AppKit hosts this SwiftUI view without a SwiftUI Scene, so scenePhase stays inactive.
        let sceneActive = macAppIsActive
        #else
        let sceneActive = scenePhase == .active
        #endif
        return AgentLandWordmarkMotionGate.allowsMotion(active: active, reduceMotion: reduceMotion, sceneActive: sceneActive)
    }

    /// The resting title as a bitmap: `scale` image pixels per art pixel, letters in `color` on
    /// `background` (clear when nil), bulbs shown only when asked. The image covers `canvas`.
    public static func restingImage(color: CGColor, background: CGColor? = nil, scale: Int = 4,
                                    showsBulbs: Bool = false) -> CGImage? {
        guard let artwork = WordmarkArtwork.shared, scale > 0 else { return nil }
        let width = artwork.canvasWidth * scale, height = artwork.canvasHeight * scale
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        if let background {
            context.setFillColor(background)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        context.setShouldAntialias(false)
        context.setFillColor(color)
        func fill(column: Int, row: Int) {
            // Bitmap y runs up; canvas rows run down.
            let x = (column - artwork.canvasColumn) * scale, y = height - (row - artwork.canvasRow + 1) * scale
            context.fill(CGRect(x: x, y: y, width: scale, height: scale))
        }
        for glyph in artwork.glyphs {
            for y in 0..<glyph.height { for x in 0..<glyph.width where glyph.isOn(x, y) {
                fill(column: glyph.column + x, row: glyph.row + y)
            } }
        }
        if showsBulbs {
            for bulb in artwork.bulbs {
                for dy in 0..<AgentLandWordmarkGeometry.bulbSide { for dx in 0..<AgentLandWordmarkGeometry.bulbSide {
                    fill(column: bulb.column + dx, row: bulb.row + dy)
                } }
            }
        }
        return context.makeImage()
    }
}

// MARK: - Placement

/// Where the title goes around a circus scene that stays at its shared anchor. Above the scene, the
/// arch's bottom edge sits where the scene-size arch's would, overlapping only the scene's motion-free top
/// band, and it grows up and out from there, past the scene's own scale, as far as the container's width
/// (less the side insets) and the room below the navigation bar allow. In compact height (a phone in
/// landscape) it moves to the leading side of the tent instead.
public struct AgentLandTitlePlacement: Equatable, Sendable {
    public let frame: CGRect
    /// Points per circus scene unit.
    public let scale: CGFloat
    public let leadingSide: Bool

    /// The clown's leftmost reach in scene units: the orbit's left end less half the rider's sprite.
    static let motionLeft: CGFloat = 168 - 121 - 36
    static let minimumScale: CGFloat = 0.3
    /// The title grows past the scene's scale to fill a phone's width, but on an iPad or a Mac window it
    /// stops at this many times the scene's scale, so it stays in proportion with the tent under it.
    static let maximumSceneRatio: CGFloat = 1.25

    /// `sceneCenter` and `container` are in the same coordinates: the scene's centre and the space the
    /// title may use (below the navigation bar). `sceneScale` is the scene's points per scene unit.
    public init(sceneCenter: CGPoint, sceneScale: CGFloat, container: CGSize, compactHeight: Bool,
                topInset: CGFloat = 8, sideInset: CGFloat = 16) {
        let canvas = AgentLandWordmarkGeometry.canvas
        if compactHeight {
            let sceneLeft = sceneCenter.x + (Self.motionLeft - 168) * sceneScale - 12
            let width = max(1, sceneLeft - sideInset), height = max(1, container.height - 2 * topInset)
            let scale = max(Self.minimumScale, min(width / canvas.width, height / canvas.height,
                                                   sceneScale * Self.maximumSceneRatio))
            let size = CGSize(width: canvas.width * scale, height: canvas.height * scale)
            let y = min(max(topInset, sceneCenter.y - size.height / 2), max(topInset, container.height - topInset - size.height))
            frame = CGRect(origin: CGPoint(x: sideInset + max(0, (width - size.width) / 2), y: y), size: size)
            self.scale = scale
            leadingSide = true
        } else {
            let anchor = CGPoint(x: sceneCenter.x + (canvas.midX - 168) * sceneScale,
                                 y: sceneCenter.y + (canvas.maxY - 180) * sceneScale)
            let scale = max(Self.minimumScale, min((anchor.y - topInset) / canvas.height,
                                                   (container.width - 2 * sideInset) / canvas.width,
                                                   sceneScale * Self.maximumSceneRatio))
            let size = CGSize(width: canvas.width * scale, height: canvas.height * scale)
            // Centred over the tent, kept inside the side insets.
            let x = min(max(sideInset, anchor.x - size.width / 2), max(sideInset, container.width - sideInset - size.width))
            frame = CGRect(origin: CGPoint(x: x, y: anchor.y - size.height), size: size)
            self.scale = scale
            leadingSide = false
        }
    }
}

// MARK: - Title block

/// The title for Home: the arched wordmark, its frame the wordmark canvas at `scale` points per scene unit.
/// The quip is not in the arch: Home shows `QuipStore`'s current quip under the tent. Showing the title
/// (`active` turning true) moves to the next quip and, after about 2 s, lets the quip store top up its ring
/// in the background; a tap on the title shows the next quip and plays a flourish.
public struct AgentLandTitleBlock: View {
    @ObservedObject private var quips: QuipStore
    private let scale: CGFloat
    private let color: Color
    private let active: Bool
    private let referenceDate: Date
    private let tonalArt: Bool

    /// `quipColor` and `showsQuip` are kept so existing layouts compile; the flat arch has no hollow for a
    /// quip, so neither is drawn here.
    public init(scale: CGFloat, color: Color, quipColor: Color, active: Bool, referenceDate: Date,
                showsQuip: Bool = false, quips: QuipStore = .shared, tonalArt: Bool = false) {
        self.scale = scale
        self.color = color
        self.active = active
        self.referenceDate = referenceDate
        self.tonalArt = tonalArt
        _quips = ObservedObject(wrappedValue: quips)
    }

    public static var canvas: CGRect { AgentLandWordmarkGeometry.canvas }
    public static func designSize(scale: CGFloat = 1) -> CGSize {
        CGSize(width: canvas.width * scale, height: canvas.height * scale)
    }

    public var body: some View {
        let canvas = Self.canvas
        AgentLandWordmark(color: color, active: active, referenceDate: referenceDate, onTap: quips.advance, tonalArt: tonalArt)
            .frame(width: canvas.width * scale, height: canvas.height * scale)
            .accessibilityIdentifier("homeWordmark")
            .onChange(of: active, initial: true) { _, visible in
                if visible { quips.advance() }
            }
            .task(id: active) {
                guard active else { return }
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                quips.prefetchIfNeeded()
            }
    }
}

// MARK: - Layers

/// Builds and drives the title's layers. Platform views host `root`.
@MainActor
final class WordmarkLayerController {
    let root = CALayer()
    private let container = CALayer()
    private(set) var letters: [CALayer] = []
    private(set) var masks: [CALayer] = []
    private(set) var bulbs: [CALayer] = []
    private let set: WordmarkFontSet?
    private let defaults: UserDefaults
    /// The face and look the letters wear: picked at the first update and again at every entrance.
    private(set) var style = AgentLandWordmarkStyle.classic
    private var styled = false
    private var color: CGColor?
    private var ramp: AgentLandClownRamp?
    private var motionAllowed = false
    private var configured = false
    private var referenceDate = Date()
    private var flourishRequests = 0
    private var idleTask: Task<Void, Never>?

    /// Shared by every title in the process, so no two consecutive animations or styles repeat anywhere.
    static var picker = AgentLandWordmarkPicker(
        seed: .random(in: .min ... .max), lastEntrance: AgentLandWordmarkPicker.savedEntrance(in: .standard),
        lastStyle: AgentLandWordmarkPicker.savedStyle(in: .standard, faces: WordmarkFontSet.shared?.faces.map(\.id) ?? []))

    init(set: WordmarkFontSet? = .shared, defaults: UserDefaults = .standard) {
        self.set = set
        self.defaults = defaults
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.masksToBounds = false
        root.addSublayer(container)
        var perspective = CATransform3DIdentity
        perspective.m34 = -1 / 520
        container.sublayerTransform = perspective
        if let set { build(set) }
        CATransaction.commit()
    }

    /// One layer per letter slot, on the slot's fixed box (every face and look fits it), turning and scaling
    /// about the faces' mean point on the arch. The container keeps Rubber Hose's canvas, so the layout never
    /// changes; broader faces draw a little past it.
    private func build(_ set: WordmarkFontSet) {
        let artwork = set.classic, canvas = artwork.canvas
        container.bounds = CGRect(origin: .zero, size: canvas.size)
        for (slot, box) in set.boxes.enumerated() {
            let slotFrame = box.frame, pivot = set.pivots[slot]
            let letter = CALayer()
            letter.contentsGravity = .resize
            letter.magnificationFilter = .nearest
            letter.minificationFilter = .nearest
            letter.anchorPoint = CGPoint(x: (pivot.x - slotFrame.minX) / slotFrame.width, y: (pivot.y - slotFrame.minY) / slotFrame.height)
            letter.frame = slotFrame.offsetBy(dx: -canvas.minX, dy: -canvas.minY)
            let mask = CALayer()
            mask.frame = letter.bounds
            mask.contents = set.mask(style, slot: slot)
            mask.contentsGravity = .resize
            mask.magnificationFilter = .nearest
            mask.minificationFilter = .nearest
            letter.mask = mask
            container.addSublayer(letter)
            letters.append(letter)
            masks.append(mask)
        }
        for index in artwork.bulbs.indices {
            let bulb = CALayer()
            bulb.frame = artwork.bulbFrame(index).offsetBy(dx: -canvas.minX, dy: -canvas.minY)
            bulb.opacity = 0
            container.addSublayer(bulb)
            bulbs.append(bulb)
        }
    }

    func layout(in bounds: CGRect) {
        guard let set else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.frame = bounds
        let canvas = set.classic.canvas
        let scale = min(bounds.width / canvas.width, bounds.height / canvas.height)
        container.position = CGPoint(x: bounds.midX, y: bounds.midY)
        container.transform = CATransform3DMakeScale(scale, scale, 1)
        CATransaction.commit()
    }

    func update(color: CGColor, motionAllowed: Bool, referenceDate: Date, flourishRequests: Int, ramp: AgentLandClownRamp? = nil) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if self.color != color || self.ramp != ramp {
            self.color = color
            self.ramp = ramp
            apply(style)
            for layer in bulbs { layer.backgroundColor = color }
        }
        CATransaction.commit()
        self.referenceDate = referenceDate
        let tapped = flourishRequests != self.flourishRequests
        self.flourishRequests = flourishRequests
        if !configured || motionAllowed != self.motionAllowed {
            configured = true
            self.motionAllowed = motionAllowed
            if motionAllowed {
                playEntrance()
            } else {
                if !styled { pickStyle() }
                rest()
            }
        } else if tapped, motionAllowed {
            playFlourish()
        }
    }

    /// Removes every animation and shows the still title: letters on the arch, bulbs dark.
    func rest() {
        idleTask?.cancel()
        idleTask = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in letters + masks + bulbs { layer.removeAllAnimations() }
        for letter in letters {
            letter.opacity = 1
            letter.transform = CATransform3DIdentity
        }
        apply(style)
        for bulb in bulbs { bulb.opacity = 0 }
        CATransaction.commit()
    }

    /// The letters in `style`: each letter's image (in the ramp's tones, or tinted with the colour) and its mask.
    func apply(_ style: AgentLandWordmarkStyle) {
        guard let set else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (slot, letter) in letters.enumerated() {
            letter.backgroundColor = ramp == nil ? color : nil
            letter.contents = ramp.flatMap { set.face(style, slot: slot, ramp: $0) }
            masks[slot].contents = set.mask(style, slot: slot)
        }
        CATransaction.commit()
    }

    private func pickStyle() {
        guard let set else { return }
        style = Self.picker.nextStyle(faces: set.faces.map(\.id), saving: defaults)
        styled = true
        apply(style)
    }

    /// A new face and look, then a new entrance: each Home load.
    func playEntrance() {
        pickStyle()
        playEntrance(Self.picker.nextEntrance(saving: defaults))
    }

    func playEntrance(_ kind: AgentLandWordmarkEntrance) {
        guard let stage else { return }
        run(WordmarkChoreography.entrance(kind, stage: stage, seed: Self.picker.nextSeed()), key: "wordmarkEntrance")
        scheduleIdleFlourish()
    }

    func playFlourish() {
        guard motionAllowed else { return }
        playFlourish(Self.picker.nextFlourish())
    }

    func playFlourish(_ kind: AgentLandWordmarkFlourish) {
        guard let stage, motionAllowed else { return }
        run(WordmarkChoreography.flourish(kind, stage: stage, seed: Self.picker.nextSeed(), beatDelay: beatDelay()),
            key: "wordmarkFlourish")
        scheduleIdleFlourish()
    }

    private var stage: WordmarkStage? { self.set.map { WordmarkStage(set: $0, style: style, ramp: ramp) } }

    /// Seconds to the next beat of the circus clock (0.3 s: three ride frames).
    private func beatDelay() -> Double {
        let beat = WordmarkChoreography.beat
        let elapsed = max(0, Date().timeIntervalSince(referenceDate))
        let remainder = elapsed.truncatingRemainder(dividingBy: beat)
        return remainder < 0.001 ? 0 : beat - remainder
    }

    private func scheduleIdleFlourish() {
        idleTask?.cancel()
        let delay = Self.picker.idleDelay()
        idleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.motionAllowed else { return }
            self.playFlourish()
        }
    }

    private func run(_ tracks: [WordmarkTrack], key: String) {
        let now = CACurrentMediaTime()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for track in tracks {
            guard let layer = layer(for: track.target) else { continue }
            let animation = CAKeyframeAnimation(keyPath: track.keyPath)
            animation.values = track.values.map { value -> Any in
                switch value {
                case .number(let number): NSNumber(value: number)
                case .image(let image): image
                }
            }
            animation.keyTimes = track.keyTimes.map { NSNumber(value: $0) }
            animation.duration = track.duration
            animation.beginTime = now + track.delay
            animation.fillMode = .both
            animation.isRemovedOnCompletion = true
            if track.discrete {
                animation.calculationMode = .discrete
            } else {
                let segments = max(0, track.values.count - 1)
                switch track.easing {
                case .linear: break
                case .easeInOut:
                    animation.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: segments)
                case .bounce:
                    // Falls speed up into each landing; rebounds slow toward each peak.
                    animation.timingFunctions = (0..<segments).map {
                        CAMediaTimingFunction(name: $0.isMultiple(of: 2) ? .easeIn : .easeOut)
                    }
                }
            }
            layer.add(animation, forKey: "\(key).\(track.keyPath)")
        }
        CATransaction.commit()
    }

    private func layer(for target: WordmarkTrack.Target) -> CALayer? {
        switch target {
        case .letter(let index): letters.indices.contains(index) ? letters[index] : nil
        case .letterMask(let index): masks.indices.contains(index) ? masks[index] : nil
        case .bulb(let index): bulbs.indices.contains(index) ? bulbs[index] : nil
        }
    }

    /// Every layer that can carry an animation, for tests.
    var animatableLayers: [CALayer] { letters + masks + bulbs }

    /// Back in a window with motion still allowed: keep the idle flourishes coming (no new entrance).
    func resume() {
        if motionAllowed && idleTask == nil { scheduleIdleFlourish() }
    }
}

#if os(iOS)
final class WordmarkHostView: UIView {
    let controller: WordmarkLayerController

    init(frame: CGRect, defaults: UserDefaults = .standard) {
        controller = WordmarkLayerController(defaults: defaults)
        super.init(frame: frame)
        isOpaque = false
        isAccessibilityElement = false
        // SwiftUI handles the tap; the layers only draw.
        isUserInteractionEnabled = false
        layer.addSublayer(controller.root)
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    override func layoutSubviews() {
        super.layoutSubviews()
        controller.layout(in: bounds)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { controller.rest() } else { controller.resume() }
    }
}

struct WordmarkRepresentable: UIViewRepresentable {
    let color: Color
    let motionAllowed: Bool
    let referenceDate: Date
    let flourishRequests: Int
    var ramp: AgentLandClownRamp? = nil

    func makeUIView(context: Context) -> WordmarkHostView { WordmarkHostView(frame: .zero) }

    func updateUIView(_ view: WordmarkHostView, context: Context) {
        view.controller.update(color: color.resolve(in: context.environment).cgColor, motionAllowed: motionAllowed,
                               referenceDate: referenceDate, flourishRequests: flourishRequests, ramp: ramp)
    }
}
#elseif os(macOS)
final class WordmarkHostView: NSView {
    let controller: WordmarkLayerController

    init(frame: NSRect, defaults: UserDefaults = .standard) {
        controller = WordmarkLayerController(defaults: defaults)
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(controller.root)
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    // Top-left origin, as on iOS, so the letters' layer geometry matches.
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        controller.layout(in: bounds)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        controller.layout(in: bounds)
    }

    // SwiftUI handles the click; the layers only draw.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { controller.rest() } else { controller.resume() }
    }
}

struct WordmarkRepresentable: NSViewRepresentable {
    let color: Color
    let motionAllowed: Bool
    let referenceDate: Date
    let flourishRequests: Int
    var ramp: AgentLandClownRamp? = nil

    func makeNSView(context: Context) -> WordmarkHostView { WordmarkHostView(frame: .zero) }

    func updateNSView(_ view: WordmarkHostView, context: Context) {
        view.controller.update(color: color.resolve(in: context.environment).cgColor, motionAllowed: motionAllowed,
                               referenceDate: referenceDate, flourishRequests: flourishRequests, ramp: ramp)
    }
}
#endif
