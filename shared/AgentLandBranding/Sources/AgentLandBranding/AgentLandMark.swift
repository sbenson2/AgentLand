import SwiftUI

/// The AgentLand logo: the tent of the app icon (branding/tent-logo.json).
///
/// Day tones on a light backdrop and the night ramp on a dark one, like the riders.
/// Opt into animation only on a loading screen. Other placements stay still. Motion pauses
/// automatically when accessibility Reduce Motion is enabled or the scene is
/// inactive.
public struct AgentLandMark: View {
    /// The tent in each ramp, and the side in pixels of its square sprite (scripts/package-logo.py packages
    /// its day tones, cropped to the tent and padded to a square).
    private static let artwork: (tents: [AgentLandClownRamp: Image], spritePixels: CGFloat) = {
        guard let day = AgentLandBrandingResources.image("LogoMark") else { return ([:], 1) }
        var tents: [AgentLandClownRamp: Image] = [:]
        for ramp in AgentLandClownRamp.allCases {
            if let image = AgentLandTonalArtwork.recolour(day, ramp: ramp) { tents[ramp] = Image(decorative: image, scale: 1) }
        }
        return (tents, CGFloat(max(day.width, day.height)))
    }()
    private enum Pose: Equatable {
        case resting
        case anticipation
        case airborne
        case landing

        var verticalOffset: CGFloat {
            switch self {
            case .resting: 0
            case .anticipation: 0.024
            case .airborne: -0.082
            case .landing: 0.012
            }
        }

        var xScale: CGFloat {
            switch self {
            case .resting, .airborne: 1
            case .anticipation: 1.035
            case .landing: 1.045
            }
        }

        var yScale: CGFloat {
            switch self {
            case .resting, .airborne: 1
            case .anticipation: 0.968
            case .landing: 0.94
            }
        }
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @Environment(\.scenePhase) private var scenePhase
    @State private var pose: Pose = .resting

    private let animated: Bool

    public init(animated: Bool = false) {
        self.animated = animated
    }

    public var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let markSide = side * 0.82

            // Nearest-neighbour from twice the sprite's size up; below that it would drop or double odd rows,
            // so smaller marks are smoothed.
            (Self.artwork.tents[colorScheme == .dark ? .night : .day] ?? Image(systemName: "tent"))
                .resizable()
                .interpolation(markSide * displayScale >= Self.artwork.spritePixels * 2 ? .none : .high)
                .scaledToFit()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("AgentLand")
                .frame(width: markSide, height: markSide)
                .scaleEffect(x: pose.xScale, y: pose.yScale, anchor: .bottom)
                .offset(y: side * pose.verticalOffset)
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
        .task(id: motionIsAllowed) {
            guard motionIsAllowed else {
                pose = .resting
                return
            }
            await hopLoop()
        }
    }

    private var motionIsAllowed: Bool {
        animated && !reduceMotion && scenePhase == .active
    }

    @MainActor
    private func hopLoop() async {
        while !Task.isCancelled {
            await pause(for: 2.4)
            guard !Task.isCancelled else { break }

            withAnimation(.easeInOut(duration: 0.12)) { pose = .anticipation }
            await pause(for: 0.12)
            guard !Task.isCancelled else { break }

            withAnimation(.easeOut(duration: 0.2)) { pose = .airborne }
            await pause(for: 0.2)
            guard !Task.isCancelled else { break }

            withAnimation(.easeIn(duration: 0.11)) { pose = .landing }
            await pause(for: 0.11)
            guard !Task.isCancelled else { break }

            withAnimation(.easeOut(duration: 0.16)) { pose = .resting }
        }
        pose = .resting
    }

    private func pause(for seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }
}
