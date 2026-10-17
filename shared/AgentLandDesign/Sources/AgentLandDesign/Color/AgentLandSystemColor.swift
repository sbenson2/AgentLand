import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The system's semantic colors that some of AgentLand's interface tokens stand for on iPhone and iPad: primary text,
/// glyphs and the status colors. They follow light and dark, Increase Contrast and elevated presentations by
/// themselves, and their contrast is the system's. Backgrounds, secondary text and separators draw the tokens' own
/// paper and slate there (the owner's choice, 2026-10-07), and the Mac keeps the tokens' own values throughout.
public enum AgentLandSystemColor: String, Hashable, Sendable, CaseIterable, CustomStringConvertible {
    case label
    case tertiaryLabel
    case systemGreen
    case systemOrange
    case systemRed

    /// The UIKit name, as in `UIColor.label`.
    public var description: String { rawValue }

    #if canImport(UIKit)
    public var uiColor: UIColor {
        switch self {
        case .label: .label
        case .tertiaryLabel: .tertiaryLabel
        case .systemGreen: .systemGreen
        case .systemOrange: .systemOrange
        case .systemRed: .systemRed
        }
    }
    #endif
}
