import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The four appearances every AgentLand color defines: light and dark, each with and without
/// Increase Contrast.
public struct AgentLandAppearance: Hashable, Sendable, CaseIterable, CustomStringConvertible {
    public let isDark: Bool
    public let increasedContrast: Bool

    public init(isDark: Bool, increasedContrast: Bool) {
        self.isDark = isDark
        self.increasedContrast = increasedContrast
    }

    public static let light = AgentLandAppearance(isDark: false, increasedContrast: false)
    public static let dark = AgentLandAppearance(isDark: true, increasedContrast: false)
    public static let lightIncreasedContrast = AgentLandAppearance(isDark: false, increasedContrast: true)
    public static let darkIncreasedContrast = AgentLandAppearance(isDark: true, increasedContrast: true)

    public static let allCases: [AgentLandAppearance] = [.light, .dark, .lightIncreasedContrast, .darkIncreasedContrast]

    public var description: String {
        switch (isDark, increasedContrast) {
        case (false, false): "light"
        case (true, false): "dark"
        case (false, true): "light, Increase Contrast"
        case (true, true): "dark, Increase Contrast"
        }
    }

    /// The appearance SwiftUI describes in its environment.
    public init(colorScheme: ColorScheme, contrast: ColorSchemeContrast) {
        self.init(isDark: colorScheme == .dark, increasedContrast: contrast == .increased)
    }

    public init(_ environment: EnvironmentValues) {
        self.init(colorScheme: environment.colorScheme, contrast: environment.colorSchemeContrast)
    }

    #if canImport(UIKit)
    /// The appearance a UIKit trait collection describes.
    public init(traits: UITraitCollection) {
        self.init(isDark: traits.userInterfaceStyle == .dark, increasedContrast: traits.accessibilityContrast == .high)
    }
    #elseif canImport(AppKit)
    /// The appearance names an AppKit dynamic color is matched against.
    public static let appKitNames: [NSAppearance.Name] = [
        .aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua
    ]

    /// The appearance for the best match among `appKitNames`; anything else reads as light.
    public init(bestMatch name: NSAppearance.Name?) {
        switch name {
        case .darkAqua?: self = .dark
        case .accessibilityHighContrastAqua?: self = .lightIncreasedContrast
        case .accessibilityHighContrastDarkAqua?: self = .darkIncreasedContrast
        default: self = .light
        }
    }

    public init(appearance: NSAppearance) {
        self.init(bestMatch: appearance.bestMatch(from: Self.appKitNames))
    }
    #endif
}
