import SwiftUI

/// Both screens resolve the same window anchor into their local coordinates.
/// Navigation bars and safe-area differences must not reposition the tent.
public struct AgentLandArtworkLayout: Sendable {
    public let windowFrame: CGRect
    public let referenceDate: Date

    public init(windowFrame: CGRect, referenceDate: Date) {
        self.windowFrame = windowFrame
        self.referenceDate = referenceDate
    }

    public var scale: CGFloat {
        max(0.1, min(0.92, (windowFrame.width - 40) / 336, (windowFrame.height - 120) / 360))
    }
    public var sceneSize: CGSize { CGSize(width: 336 * scale, height: 360 * scale) }
    public func center(in localFrame: CGRect) -> CGPoint {
        CGPoint(x: windowFrame.midX - localFrame.minX,
                y: windowFrame.minY + windowFrame.height * 0.46 - localFrame.minY)
    }
}

private struct AgentLandArtworkKey: EnvironmentKey {
    static let defaultValue = AgentLandArtworkLayout(windowFrame: .zero, referenceDate: .distantPast)
}

public extension EnvironmentValues {
    /// The window anchor shared by the opening cover, Home and the empty-chat landing.
    var agentLandArtwork: AgentLandArtworkLayout {
        get { self[AgentLandArtworkKey.self] }
        set { self[AgentLandArtworkKey.self] = newValue }
    }
}
