import SwiftUI
import ImageIO

/// The shared tent mark for the landing screen, breathing subtly: the roof's slopes lift by about a pixel once
/// a loop and the pennant flutters (the PixelLab tent loop).
///
/// The valance, walls, curtains and doorway stay still. Motion automatically stops at the still mark when Reduce
/// Motion is enabled, the scene is inactive, or animation is disabled.
public struct AgentLandLandingMark: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var referenceDate = Date()

    private let animated: Bool

    public init(animated: Bool = true) {
        self.animated = animated
    }

    public var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height) * 0.82
            let motionIsAllowed = animated && !reduceMotion && scenePhase == .active

            TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !motionIsAllowed)) { context in
                AgentLandTentMark(
                    side: side,
                    elapsed: motionIsAllowed ? context.date.timeIntervalSince(referenceDate) : nil
                )
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("AgentLand")
    }
}

/// One nearest-neighbour renderer for every large AgentLand tent placement: the doorway's dark fill under
/// the mark, the still mark or, when an elapsed time is supplied, that moment's frame of the tent loop.
struct AgentLandTentMark: View {
    private static let tentImage: Image = {
        guard let image = AgentLandTentArt.mark else { return Image(systemName: "tent") }
        return Image(decorative: image, scale: 1).renderingMode(.template)
    }()

    /// The doorway is a hole in the mark; this fills it with a fixed dark shade.
    static let doorwayImage: Image? = AgentLandTentArt.doorway.map {
        Image(decorative: $0, scale: 1).renderingMode(.template)
    }

    let side: CGFloat
    let elapsed: TimeInterval?
    var color: Color = .white
    /// False leaves the doorway's fill to the caller, which draws something between it and the mark.
    var showsDoorway = true
    var tonalArt = false
    var ramp: AgentLandClownRamp = .day

    var body: some View {
        ZStack {
            if showsDoorway { Self.doorway }
            markImage
                .resizable()
                .interpolation(.none)
                .scaledToFit()
                .foregroundStyle(color)
        }
        .frame(width: side, height: side)
    }

    private var markImage: Image {
        let frame = elapsed.flatMap(Self.loopFrame)
        if tonalArt, let image = AgentLandTentArt.tonal(frame: frame, ramp: ramp) {
            return Image(decorative: image, scale: 1).renderingMode(.original)
        }
        return Self.mark(frame: frame)
    }

    /// The doorway's dark fill, sized to the view it is in.
    @ViewBuilder static var doorway: some View {
        if let doorway = doorwayImage {
            doorway
                .resizable()
                .interpolation(.none)
                .scaledToFit()
                .foregroundStyle(AgentLandTheme.tentDoorway)
        }
    }

    /// The loop frame at `elapsed` on the circus clock, or nil when the loop is not packaged.
    static func loopFrame(at elapsed: TimeInterval) -> Int? {
        AgentLandTentLoop.frameCount > 0 ? AgentLandTentLoop.frameIndex(at: elapsed) : nil
    }

    /// A loop frame's mark, or the still mark.
    static func mark(frame: Int?) -> Image {
        guard let frame, let marks = AgentLandTentLoop.artwork?.marks, marks.indices.contains(frame) else { return tentImage }
        return Image(decorative: marks[frame], scale: 1).renderingMode(.template)
    }
}
