import CoreGraphics
import Foundation
import SwiftUI

/// One opaque sRGB color, written as 0xRRGGBB.
public struct AgentLandRGB: Hashable, Sendable, CustomStringConvertible {
    public let hex: UInt32

    public init(_ hex: UInt32) {
        precondition(hex <= 0xFFFFFF, "AgentLandRGB takes 0xRRGGBB")
        self.hex = hex
    }

    public var red: Double { Double((hex >> 16) & 0xFF) / 255 }
    public var green: Double { Double((hex >> 8) & 0xFF) / 255 }
    public var blue: Double { Double(hex & 0xFF) / 255 }

    /// "#RRGGBB".
    public var description: String {
        "#" + String(hex, radix: 16, uppercase: true).leftPadded(to: 6)
    }

    /// WCAG 2.x relative luminance.
    public var relativeLuminance: Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG 2.x contrast ratio, from 1 (same luminance) to 21 (black on white).
    public func contrastRatio(with other: AgentLandRGB) -> Double {
        let lighter = max(relativeLuminance, other.relativeLuminance)
        let darker = min(relativeLuminance, other.relativeLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    public var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: 1)
    }

    public var resolvedColor: Color.Resolved {
        Color.Resolved(colorSpace: .sRGB, red: Float(red), green: Float(green), blue: Float(blue), opacity: 1)
    }

    public var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }
}

extension String {
    func leftPadded(to length: Int, with pad: Character = "0") -> String {
        count >= length ? self : String(repeating: pad, count: length - count) + self
    }
}
