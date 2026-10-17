import SwiftUI
import ImageIO
#if os(macOS)
import AppKit
import Combine
#endif

/// A still, decorative version of the packaged opening performer for work launchers.
public struct AgentLandClownMark: View {
    private let color: Color
    private static let sprite: CGImage? = AgentLandBrandingResources.image("ClownUnicycle")

    public init(color: Color = .white) { self.color = color }

    public var body: some View {
        Group {
            if let sprite = Self.sprite {
                Image(decorative: sprite, scale: 1)
                    .resizable()
                    .renderingMode(.template)
                    .interpolation(.none)
                    .scaledToFit()
                    .foregroundStyle(color)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The circus scene. On the opening cover (device authentication, host connection) the tent breathes on
/// Core Animation's render server, so Face ID and loading cannot hold its frames, and no clown shows. On a
/// work surface (`workSurface`: Home, the empty-chat landing) the scene runs on a native timeline capped at
/// 60 fps: the tent breathes and, from the moment the surface is revealed, the clowns come out of the
/// doorway, circle and juggle, and go back in, or, on one reveal in three, perform on a tightrope. The selected
/// stage is present from the first frame (`AgentLandCircusChoreography`), even before the clowns are decoded.
/// Pausing retains that stage without a clown; Reduce Motion uses the still tent.
///
/// The scene's units are the cover's 336 × 360 box, the tent centred at (168, 180). A work surface's stage is
/// wider, `stageSize`, centred on the same point, for the ring's sides and the tightrope's poles.
public struct AgentLandCircusLoading: View {
    /// A work surface's stage in scene points: the 336-point cover widened 34 points each side.
    public nonisolated static let stageSize = CGSize(width: 404, height: 360)
    /// The tent's square in scene points, centred in the scene (`AgentLandTentArt.sceneRect`).
    private static let tentSide = AgentLandTentArt.sceneRect.width

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    /// Resolves the backdrop, which picks the rider's tones.
    @Environment(\.self) private var environment

    private let fixedElapsed: TimeInterval?
    private let forceReduceMotion: Bool?
    private let authenticating: Bool
    private let showsClown: Bool
    private let animated: Bool
    private let markColor: Color
    private let workSurface: Bool
    private let backdrop: Color?
    private let revealedAt: Date?
    private let tonalArt: Bool
    /// A surface can soften its art without fading the fixed doorway fill or its occlusion masks.
    private let artOpacity: Double
    @State private var referenceDate: Date
    /// When `animated` first became true, the reveal when the caller gives none.
    @State private var firstAnimatedAt: Date?
    @State private var stage = CircusStage()
    #if os(macOS)
    @State private var macAppIsActive = NSApp.isActive
    #endif

    /// `revealedAt` is the moment the surface was revealed (after the opening cover or unlock); the first
    /// clown comes out of the doorway then. Nil falls back to the first moment `animated` was true.
    /// `fixedElapsed` shows one moment of the circus clock, still; Reduce Motion and `animated` still apply.
    public init(
        fixedElapsed: TimeInterval? = nil,
        forceReduceMotion: Bool? = nil,
        authenticating: Bool = false,
        showsClown: Bool = true,
        animated: Bool = true,
        markColor: Color = .white,
        workSurface: Bool = false,
        referenceDate: Date? = nil,
        backdrop: Color? = nil,
        revealedAt: Date? = nil,
        tonalArt: Bool = true,
        artOpacity: Double = 1
    ) {
        self.fixedElapsed = fixedElapsed
        self.forceReduceMotion = forceReduceMotion
        self.authenticating = authenticating
        self.showsClown = showsClown
        self.animated = animated
        self.markColor = markColor
        self.workSurface = workSurface
        self.backdrop = backdrop
        self.revealedAt = revealedAt
        self.tonalArt = tonalArt
        self.artOpacity = min(1, max(0, artOpacity))
        _referenceDate = State(initialValue: referenceDate ?? Date())
    }

    /// Starts decoding the circus's art (the clown designs, the tent loop, the tent's images and the title's
    /// letters) in a detached utility-priority task and returns at once. Call it early, behind the opening
    /// cover, so none of that decoding lands on the main thread when Home is revealed. Calling it again,
    /// from any thread, does nothing more.
    public nonisolated static func prepareArtwork() {
        _ = AgentLandCircusArtworkPreparation.task
    }

    public var body: some View {
        #if os(macOS)
        content
            .onAppear { macAppIsActive = NSApp.isActive }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                macAppIsActive = true
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                macAppIsActive = false
            }
        #else
        content
        #endif
    }

    private var content: some View {
        Group {
            #if os(iOS)
            if fixedElapsed == nil && !workSurface {
                AgentLandCircusCompositor(animated: motionIsAllowed, referenceDate: referenceDate,
                                         tonalArt: tonalArt, ramp: ramp, artOpacity: artOpacity)
            } else {
                timelineScene
            }
            #else
            timelineScene
            #endif
        }
        .frame(width: workSurface ? Self.stageSize.width : 336, height: 360)
        .onChange(of: animated, initial: true) { _, isAnimated in
            if isAnimated && firstAnimatedAt == nil { firstAnimatedAt = Date() }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("AgentLand is opening")
    }

    private var timelineScene: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !motionIsAllowed || fixedElapsed != nil)) { context in
            scene(elapsed: fixedElapsed ?? context.date.timeIntervalSince(referenceDate))
        }
    }

    /// The color of what the scene sits on. The depth mask, the rider's outline and the balls' rings
    /// are drawn in it, so they read as the background wherever the art is placed.
    private var backdropColor: Color { backdrop ?? AgentLandTheme.paper }

    /// The rider's tones: the day ramp on a light backdrop (Home on paper), the night ramp on a dark one (Home in
    /// dark appearance, the empty-chat landings on slate).
    private var ramp: AgentLandClownRamp {
        let resolved = backdropColor.resolve(in: environment)
        return .forBackdrop(linearRed: Double(resolved.linearRed), green: Double(resolved.linearGreen),
                            blue: Double(resolved.linearBlue))
    }

    private var motionIsAllowed: Bool {
        let requested = animated && !(forceReduceMotion ?? reduceMotion)
        // A fixed moment (the DEBUG loading preview, tests) is a still picture of that moment: only Reduce
        // Motion and `animated` decide what it shows. The scene's activity stops a running timeline, and a
        // fixed moment's is already paused.
        if fixedElapsed != nil { return requested }
        #if os(macOS)
        // AppKit hosts this SwiftUI view without a SwiftUI Scene. Its scenePhase
        // stays inactive even when the AgentLand window is frontmost.
        return requested && macAppIsActive
        #else
        return requested && (scenePhase == .active || (scenePhase == .inactive && authenticating))
        #endif
    }

    /// The clown designs once `prepareArtwork()` has decoded them, else none: this never waits for the decode.
    private var designs: [AgentLandClownDesign] { AgentLandClownArtwork.prepared?.designs ?? [] }

    /// Lets a work-surface layout follow the same stage choice as its artwork.
    public static func isTightrope(revealedAt: Date) -> Bool {
        AgentLandCircusChoreography.isTightrope(seed: AgentLandCircusChoreography.seed(for: revealedAt))
    }

    private var revealDate: Date? {
        // Workspace callers use distantFuture until their shared reveal is set. Do not draw a temporary stage.
        guard let reveal = revealedAt ?? firstAnimatedAt, reveal != .distantFuture else { return nil }
        return reveal
    }

    private var stageIsTightrope: Bool? {
        guard workSurface, showsClown, !(forceReduceMotion ?? reduceMotion) else { return false }
        guard let reveal = revealDate else { return nil }
        return Self.isTightrope(revealedAt: reveal)
    }

    /// The performance since this surface's reveal, on the circus clock. Clowns perform only on work surfaces,
    /// once their designs are decoded; the covers show the tent alone.
    private var performance: AgentLandCircusChoreography? {
        guard showsClown, workSurface, let prepared = AgentLandClownArtwork.prepared, !prepared.designs.isEmpty,
              let reveal = revealDate else { return nil }
        // Designs that arrive after the reveal (a slow debug build) start the show then, so the first clown still
        // curls out of the doorway. A fixed moment is a still picture of its own reveal.
        let start = fixedElapsed == nil ? max(reveal, prepared.at) : reveal
        return stage.choreography(reveal: reveal, start: start, referenceDate: referenceDate, designs: prepared.designs)
    }

    @ViewBuilder private func scene(elapsed: TimeInterval) -> some View {
        if let tightrope = stageIsTightrope {
            stageScene(elapsed: elapsed, tightrope: tightrope)
        }
    }

    @ViewBuilder private func stageScene(elapsed: TimeInterval, tightrope: Bool) -> some View {
        let motion = motionIsAllowed
        let performance = motion ? self.performance : nil
        let clown = performance?.state(at: elapsed)
        let grounded = performance?.groundBalls(at: elapsed) ?? []
        // Stage selection depends only on the reveal, never performer readiness or animation progress.
        let rope = tightrope ? 1.0 : 0.0
        let stage = Self.stageSize
        // On the tightrope the rope is drawn between the rider's cut-out ring and the rider, so the wheel sits on
        // the rope rather than in a gap the ring cuts.
        let ropeRider = clown.flatMap { $0.layer == .front && $0.bend != nil ? $0 : nil }

        ZStack {
            if let clown, clown.layer == .behind { rider(clown, elapsed: elapsed, ramp: ramp, outline: false) }
            groundBalls(grounded.filter { !$0.front })
            // Anything behind the tent, including a ball rolling there, hides behind its panels.
            if showsClown, rope < 1 {
                tentDepthMask(frame: motion ? AgentLandTentMark.loopFrame(at: elapsed) : nil)
                    .opacity(1 - rope)
            }
            AgentLandTentMark.doorway
                .frame(width: Self.tentSide, height: Self.tentSide)
                .opacity(1 - rope)
            // In the doorway the clown is seen through the opening, under the curtains.
            if let clown, clown.layer == .door {
                rider(clown, elapsed: elapsed, ramp: ramp, outline: true)
                    .frame(width: stage.width, height: stage.height)
                    .mask { AgentLandTentMark.doorway.frame(width: Self.tentSide, height: Self.tentSide) }
                    .mask {
                        VStack(spacing: 0) {
                            Color.black.frame(height: max(0, min(360, clown.portalEdge)))
                            Color.clear
                        }
                        .frame(width: stage.width, height: stage.height)
                    }
            }
            if rope < 1 {
                AgentLandTentMark(side: Self.tentSide, elapsed: motion ? elapsed : nil, color: markColor, showsDoorway: false,
                                  tonalArt: tonalArt, ramp: ramp)
                    .opacity(artOpacity * (1 - rope))
            }
            if rope > 0 {
                tightropePoles.opacity(artOpacity * rope)
                if ropeRider == nil { tightropeLine(.straight).opacity(artOpacity * rope) }
            }
            groundBalls(grounded.filter(\.front))
            if let ropeRider, let bend = ropeRider.bend {
                rider(ropeRider, elapsed: elapsed, ramp: ramp, outline: true, body: false)
                tightropeLine(bend).opacity(artOpacity * rope)
                rider(ropeRider, elapsed: elapsed, ramp: ramp, outline: false)
            } else if let clown, clown.layer == .front {
                rider(clown, elapsed: elapsed, ramp: ramp, outline: true)
            }
            // The wheel crossing the threshold progressively brings the whole rider in front of the curtains.
            if let clown, clown.layer == .door {
                rider(clown, elapsed: elapsed, ramp: ramp, outline: true)
                    .frame(width: stage.width, height: stage.height)
                    .mask {
                        VStack(spacing: 0) {
                            Color.clear.frame(height: max(0, min(360, clown.portalEdge)))
                            Color.black
                        }
                        .frame(width: stage.width, height: stage.height)
                    }
            }
        }
        .frame(width: workSurface ? stage.width : 336, height: 360)
    }

    /// The tightrope rig without its rope's free run, in the surface's tones (or the mark's colour), where the
    /// tent stands.
    @ViewBuilder private var tightropePoles: some View {
        let layout = AgentLandTightropeArt.layout
        if let image = AgentLandTightropeArt.poles(tonalArt ? ramp : .day) {
            Image(decorative: image, scale: 1)
                .resizable()
                .renderingMode(tonalArt ? .original : .template)
                .interpolation(.none)
                .foregroundStyle(markColor)
                .frame(width: layout.frame.width, height: layout.frame.height)
                .offset(x: layout.frame.midX - 168, y: layout.frame.midY - 180)
        }
    }

    /// The rope's free run, bent where the wheel presses it, in the rig's rope tone (or the mark's colour).
    private func tightropeLine(_ bend: AgentLandTightropeArt.Bend) -> some View {
        let layout = AgentLandTightropeArt.layout
        return AgentLandTightropeLine(bend: bend)
            .fill(ropeColor, style: FillStyle(antialiased: false))
            .frame(width: layout.frame.width, height: layout.frame.height)
            .offset(x: layout.frame.midX - 168, y: layout.frame.midY - 180)
    }

    private var ropeColor: Color {
        guard tonalArt, let tone = AgentLandTonalArtwork.tones(ramp)?[AgentLandTightropeArt.ropeTone - 1] else { return markColor }
        return Color(.sRGB, red: Double(tone[0]) / 255, green: Double(tone[1]) / 255, blue: Double(tone[2]) / 255)
    }

    /// Missed balls bouncing away on the ground, in scene points.
    private func groundBalls(_ balls: [AgentLandJuggling.GroundBall]) -> some View {
        ForEach(Array(balls.enumerated()), id: \.offset) { _, ball in
            ballView(tint: ball.tint, spinFrame: ball.spinFrame)
                .opacity(ball.opacity)
                .offset(x: ball.point.x - 168, y: ball.point.y - 180)
        }
    }

    /// One juggling ball on the rider's pixel grid; a background-colored ring
    /// keeps it visible where it crosses the rider or the tent.
    private func ballView(tint: Int = 0, spinFrame: Int = 0) -> some View {
        // The 16 px sprite has a 10 px ball inside transparent padding, drawn at the rider's pixel size:
        // a 12 pt canvas and a 7.5 pt ball before Home scales the scene down.
        let side = CGFloat(AgentLandJugglingBall.spriteSide) * AgentLandJugglingBall.pixelSize
        return ZStack {
            let frame = AgentLandJugglingBall.tintedFrame(tint: tint, spinFrame: spinFrame)
            let ring = AgentLandJugglingBall.ringFrame(for: spinFrame)
            if let ring {
                Image(decorative: ring, scale: 1)
                    .resizable().renderingMode(.template).interpolation(.none)
                    .foregroundStyle(backdropColor)
                    .frame(width: side, height: side)
            }
            if let frame {
                Image(decorative: frame, scale: 1)
                    .resizable().renderingMode(.original).interpolation(.none)
                    .frame(width: side, height: side)
                    .opacity(artOpacity)
            }
        }
    }

    @ViewBuilder private func tentDepthMask(frame: Int?) -> some View {
        if let mask = Self.depthImage(frame: frame) {
            Image(decorative: mask, scale: 1)
                .resizable()
                .renderingMode(.template)
                .interpolation(.none)
                .scaledToFit()
                .foregroundStyle(backdropColor)
                .frame(width: Self.tentSide, height: Self.tentSide)
        }
    }

    private static func depthImage(frame: Int?) -> CGImage? {
        if let frame, let depths = AgentLandTentLoop.artwork?.depths, depths.indices.contains(frame) { return depths[frame] }
        return AgentLandTentArt.depth
    }

    /// Where the wheel touches the ground in the sprite (column 41, row 94 of 96): the rider leans about it.
    private static let wheelContact = UnitPoint(x: 41.0 / 96, y: 94.0 / 96)

    /// The rider with its backdrop-coloured cut-out ring (`outline`) and its sprite and balls (`body`).
    @ViewBuilder private func rider(_ clown: AgentLandCircusChoreography.State, elapsed: TimeInterval,
                                    ramp: AgentLandClownRamp, outline: Bool, body: Bool = true) -> some View {
        let design = designs[clown.design]
        let index = AgentLandCircusChoreography.rideFrame(of: clown.appearance, at: elapsed, frameCount: design.frameCount)
        let scale = clown.scale
        ZStack {
            if outline {
                Image(decorative: design.outlines[index], scale: 1)
                    .resizable().renderingMode(.template).interpolation(.none)
                    .foregroundStyle(backdropColor)
                    .frame(width: 72, height: 72)
                    .scaleEffect(x: scale.width, y: scale.height, anchor: Self.wheelContact)
            }
            if body {
                Image(decorative: design.frames(ramp)[index], scale: 1)
                    .resizable().interpolation(.none)
                    .frame(width: 72, height: 72)
                    .scaleEffect(x: scale.width, y: scale.height, anchor: Self.wheelContact)
                    .opacity(artOpacity)
                ForEach(AgentLandCircusChoreography.balls(of: clown, at: elapsed, juggling: design.juggling), id: \.slot) { ball in
                    // Sprite pixel (top-left index) to points from the clown's centre, scaled with the clown about its
                    // wheel's contact (41, 94); the balls themselves keep their shape.
                    ballView(tint: ball.tint, spinFrame: ball.spinFrame)
                        .offset(x: (-7 + (ball.point.x - 41) * scale.width) * 0.75,
                                y: (46 + (ball.point.y - 94) * scale.height) * 0.75)
                }
            }
        }
        .frame(width: 72, height: 72)
        // Before the flip, so a lean toward the way it faces mirrors with it.
        .rotationEffect(.degrees(clown.lean), anchor: Self.wheelContact)
        .scaleEffect(x: clown.facingLeft ? -1 : 1, y: 1)
        .opacity(clown.opacity)
        .offset(x: clown.center.x - 168, y: clown.center.y - 180)
    }
}

/// The tightrope's free run as filled 0.75-point columns, in the rig's frame.
private struct AgentLandTightropeLine: Shape {
    var bend: AgentLandTightropeArt.Bend

    func path(in rect: CGRect) -> Path {
        let frame = AgentLandTightropeArt.layout.frame
        var path = Path()
        for column in bend.columns() { path.addRect(column.offsetBy(dx: -frame.minX, dy: -frame.minY)) }
        return path
    }
}

/// Keeps one surface's choreography across timeline ticks; a new reveal starts a new performance. It is keyed
/// on the caller's reveal, never on the bounded one, which depends on the moment it was built. The show starts at
/// `start` (the reveal, or the later moment the designs were decoded) and is seeded by the reveal.
@MainActor
final class CircusStage {
    private var key: (reveal: Date, start: Date, reference: Date)?
    private var cached: AgentLandCircusChoreography?

    func choreography(reveal: Date, start: Date? = nil, referenceDate: Date, designs: [AgentLandClownDesign],
                      now: Date = Date()) -> AgentLandCircusChoreography {
        let start = start ?? reveal
        if let cached, let key, key.reveal == reveal, key.start == start, key.reference == referenceDate { return cached }
        let made = AgentLandCircusChoreography(reveal: start.timeIntervalSince(referenceDate),
                                               seed: AgentLandCircusChoreography.seed(for: reveal), designs: designs,
                                               now: now.timeIntervalSince(referenceDate))
        key = (reveal, start, referenceDate)
        cached = made
        return made
    }
}
