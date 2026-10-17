import SwiftUI

/// The spacing scale: 2, 4, 8, 12, 16, 24, 32, 48 pt.
public enum AgentLandSpacing {
    public static let xxxSmall: CGFloat = 2
    public static let xxSmall: CGFloat = 4
    public static let xSmall: CGFloat = 8
    public static let small: CGFloat = 12
    /// Standard side margins and padding.
    public static let medium: CGFloat = 16
    public static let large: CGFloat = 24
    public static let xLarge: CGFloat = 32
    public static let xxLarge: CGFloat = 48

    public static let scale: [CGFloat] = [xxxSmall, xxSmall, xSmall, small, medium, large, xLarge, xxLarge]
}

/// Corner radii, all drawn with continuous corners.
public enum AgentLandRadius {
    /// Chips and small buttons.
    public static let chip: CGFloat = 8
    /// Cards, tiles, notices, grouped sections.
    public static let card: CGFloat = 12
    /// Message bubbles.
    public static let bubble: CGFloat = 20
    /// The floating composer.
    public static let composer: CGFloat = 28

    /// The radius for a shape inset by `padding` inside a shape of radius `outer`, so both corners
    /// share one centre (a bubble 8 pt inside the composer gets 20 pt).
    public static func concentric(outer: CGFloat, padding: CGFloat) -> CGFloat {
        max(0, outer - padding)
    }

    /// A continuous rounded rectangle with one of the radii above.
    public static func shape(_ radius: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }
}
