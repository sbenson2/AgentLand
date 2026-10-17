import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Shared native colors matched to the owner's established paper/slate interface.
public enum AgentLandTheme {
    public static let paper = adaptive(light: 0xF4F0E7, dark: 0x27313F)
    public static let surface = adaptive(light: 0xE7E1D5, dark: 0x344153)
    public static let elevated = adaptive(light: 0xFBF7F0, dark: 0x3C4A5D)
    public static let foreground = adaptive(light: 0x354052, dark: 0xD6DDE7)
    public static let muted = adaptive(light: 0x59616C, dark: 0xAEBCCC)
    public static let line = adaptive(light: 0xC8C0B3, dark: 0x53647A)
    public static let accent = adaptive(light: 0x32648B, dark: 0x93C4E6)
    public static let success = adaptive(light: 0x16A34A, dark: 0x4ADE80)
    public static let warning = adaptive(light: 0xB45309, dark: 0xFBBF24)
    public static let danger = adaptive(light: 0xDC2626, dark: 0xF87171)
    /// The tent's open doorway, drawn beneath the mark in every appearance: a
    /// shadowed opening on slate and a dark door on light paper.
    public static let tentDoorway = Color(.sRGB, red: 0x1B / 255.0, green: 0x22 / 255.0, blue: 0x2C / 255.0, opacity: 1)
    static let tentDoorwayRGB: (red: Double, green: Double, blue: Double) = (0x1B / 255.0, 0x22 / 255.0, 0x2C / 255.0)

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        #if canImport(UIKit)
        return Color(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 255) / 255,
                           green: CGFloat((hex >> 8) & 255) / 255,
                           blue: CGFloat(hex & 255) / 255, alpha: 1)
        })
        #else
        return Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                           green: CGFloat((hex >> 8) & 255) / 255,
                           blue: CGFloat(hex & 255) / 255, alpha: 1)
        })
        #endif
    }
}
