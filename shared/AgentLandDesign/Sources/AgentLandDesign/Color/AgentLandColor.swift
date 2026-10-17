import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// A semantic AgentLand color with light, dark and Increase Contrast values.
///
/// In SwiftUI, use the token itself as a shape style (`.foregroundStyle(AgentLandColor.text)`,
/// `.background(AgentLandColor.canvas)`). It resolves from the view's color scheme and contrast on iPhone, iPad
/// and Mac. `color` is for APIs that require a `Color`; `uiColor`/`nsColor` are for UIKit and AppKit, resolved
/// from the trait collection or `NSAppearance`.
///
/// On iPhone and iPad a token with a `system` color draws that system color (primary text, glyphs and the status
/// colors); every other token, the backgrounds, secondary text and separators among them, draws its own paper and
/// slate there as on the Mac (the owner's choice, 2026-10-07). `rgb(for:)` is always the token's own value.
public struct AgentLandColor: ShapeStyle, Hashable, Sendable, Identifiable, CustomStringConvertible {
    public let name: String
    public let light: AgentLandRGB
    public let dark: AgentLandRGB
    public let lightIncreasedContrast: AgentLandRGB
    public let darkIncreasedContrast: AgentLandRGB
    /// The system color this token draws on iPhone and iPad, or nil where it keeps its own values there too.
    public let system: AgentLandSystemColor?

    public init(_ name: String, light: UInt32, dark: UInt32, lightIncreasedContrast: UInt32, darkIncreasedContrast: UInt32,
                system: AgentLandSystemColor? = nil) {
        self.name = name
        self.light = AgentLandRGB(light)
        self.dark = AgentLandRGB(dark)
        self.lightIncreasedContrast = AgentLandRGB(lightIncreasedContrast)
        self.darkIncreasedContrast = AgentLandRGB(darkIncreasedContrast)
        self.system = system
    }

    /// The same value in every appearance.
    public init(fixed name: String, _ hex: UInt32) {
        self.init(name, light: hex, dark: hex, lightIncreasedContrast: hex, darkIncreasedContrast: hex)
    }

    public var id: String { name }
    public var description: String { name }

    /// True when every appearance uses one value.
    public var isFixed: Bool {
        Set([light, dark, lightIncreasedContrast, darkIncreasedContrast]).count == 1
    }

    /// The token's own value: what the Mac draws, and on iPhone and iPad what a token without a `system` color
    /// draws.
    public func rgb(for appearance: AgentLandAppearance) -> AgentLandRGB {
        switch (appearance.isDark, appearance.increasedContrast) {
        case (false, false): light
        case (true, false): dark
        case (false, true): lightIncreasedContrast
        case (true, true): darkIncreasedContrast
        }
    }

    // MARK: SwiftUI

    public func resolve(in environment: EnvironmentValues) -> Color.Resolved {
        #if canImport(UIKit)
        if let system { return Color(uiColor: system.uiColor).resolve(in: environment) }
        #endif
        return rgb(for: AgentLandAppearance(environment)).resolvedColor
    }

    /// The token's own value for one appearance, as a plain color.
    public func color(for appearance: AgentLandAppearance) -> Color {
        rgb(for: appearance).color
    }

    /// A dynamic `Color` backed by the UIKit/AppKit color below.
    public var color: Color {
        #if canImport(UIKit)
        Color(uiColor: uiColor)
        #elseif canImport(AppKit)
        Color(nsColor: nsColor)
        #endif
    }

    // MARK: UIKit and AppKit

    #if canImport(UIKit)
    /// Resolves from the trait collection's interface style and accessibility contrast: the system color itself
    /// for a token that has one.
    public var uiColor: UIColor {
        if let system { return system.uiColor }
        let token = self
        return UIColor { traits in
            let rgb = token.rgb(for: AgentLandAppearance(traits: traits))
            return UIColor(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
        }
    }
    #elseif canImport(AppKit)
    /// Resolves from the drawing appearance (aqua, dark aqua and their high-contrast forms).
    public var nsColor: NSColor {
        let token = self
        return NSColor(name: NSColor.Name("AgentLand." + name)) { appearance in
            let rgb = token.rgb(for: AgentLandAppearance(appearance: appearance))
            return NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
        }
    }
    #endif
}
