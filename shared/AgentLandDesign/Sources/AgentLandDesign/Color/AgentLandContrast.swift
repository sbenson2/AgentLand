import Foundation

/// One foreground/background pair and the WCAG 2.x contrast it must keep.
public struct AgentLandContrastRequirement: Hashable, Sendable {
    public enum Kind: String, Sendable {
        /// Words at any size: 4.5:1.
        case text
        /// Symbols and other non-text graphics: 3:1.
        case glyph
        /// Borders that carry separation: 3:1 where they do.
        case boundary
        /// One-color brand art (tent, clown, arched title): 3:1, like large text and graphics.
        case art
    }

    public let foreground: AgentLandColor
    public let background: AgentLandColor
    public let kind: Kind
    /// The minimum in the standard appearances, or nil where the pair is decorative (hairlines).
    public let minimum: Double?
    /// The minimum with Increase Contrast.
    public let increasedContrastMinimum: Double

    public init(_ foreground: AgentLandColor, on background: AgentLandColor, kind: Kind,
                minimum: Double?, increasedContrastMinimum: Double) {
        self.foreground = foreground
        self.background = background
        self.kind = kind
        self.minimum = minimum
        self.increasedContrastMinimum = increasedContrastMinimum
    }

    public func ratio(in appearance: AgentLandAppearance) -> Double {
        foreground.rgb(for: appearance).contrastRatio(with: background.rgb(for: appearance))
    }

    public func minimum(in appearance: AgentLandAppearance) -> Double? {
        appearance.increasedContrast ? increasedContrastMinimum : minimum
    }

    public var name: String { "\(foreground.name) on \(background.name)" }
}

/// WCAG 2.x thresholds and every pair AgentLand checks: the tokens' own values (the Mac's interface, and the art and
/// its words everywhere). On iPhone and iPad the interface tokens draw the system's colors, whose contrast is the
/// system's (`AgentLandColor.system`).
public enum AgentLandContrast {
    /// AA for body text (1.4.3).
    public static let text: Double = 4.5
    /// AA for large text and for non-text graphics and component boundaries (1.4.3, 1.4.11).
    public static let graphics: Double = 3
    /// AAA for text (1.4.6), required of primary and secondary text with Increase Contrast.
    public static let enhancedText: Double = 7

    public static let backgrounds: [AgentLandColor] = [.canvas, .surface, .surfaceRaised]

    public static let requirements: [AgentLandContrastRequirement] = {
        var pairs: [AgentLandContrastRequirement] = []
        for foreground in [AgentLandColor.text, .textSecondary] {
            for background in backgrounds {
                pairs.append(.init(foreground, on: background, kind: .text, minimum: text, increasedContrastMinimum: enhancedText))
            }
        }
        for background in backgrounds {
            pairs.append(.init(.glyphTertiary, on: background, kind: .glyph, minimum: graphics, increasedContrastMinimum: graphics))
        }
        for foreground in [AgentLandColor.tint, .success, .warning, .danger] {
            for background in backgrounds {
                pairs.append(.init(foreground, on: background, kind: .text, minimum: text, increasedContrastMinimum: text))
            }
        }
        pairs.append(.init(.onTint, on: .tint, kind: .text, minimum: text, increasedContrastMinimum: text))
        for background in [AgentLandColor.canvas, .surface] {
            pairs.append(.init(.separator, on: background, kind: .boundary, minimum: nil, increasedContrastMinimum: graphics))
        }
        pairs.append(.init(.onBrand, on: .brand, kind: .text, minimum: text, increasedContrastMinimum: text))
        pairs.append(.init(.artInk, on: .artBackdrop, kind: .art, minimum: graphics, increasedContrastMinimum: graphics))
        pairs.append(.init(.artInkSecondary, on: .artBackdrop, kind: .text, minimum: text, increasedContrastMinimum: enhancedText))
        return pairs
    }()

    /// The token values as a Markdown table (recorded in the README): what iPhone and iPad draw, then the token's own
    /// values.
    public static func tokenTable() -> String {
        var rows = ["| Token | iPhone and iPad | Light | Dark | Light, Increase Contrast | Dark, Increase Contrast |",
                    "|---|---|---|---|---|---|"]
        let fixed: [AgentLandColor] = [.brand, .onBrand, .tentDoorway]
        func iOS(_ token: AgentLandColor) -> String { token.system.map { "`\($0)`" } ?? "these values" }
        for token in AgentLandColor.semanticColors + AgentLandColor.artColors {
            rows.append("| `\(token.name)` | \(iOS(token)) | \(token.light) | \(token.dark) | \(token.lightIncreasedContrast) | \(token.darkIncreasedContrast) |")
        }
        for token in fixed {
            rows.append("| `\(token.name)` | \(iOS(token)) | \(token.light) | fixed | fixed | fixed |")
        }
        return rows.joined(separator: "\n")
    }

    /// Every checked pair with its ratio in each appearance, as a Markdown table (recorded in the README).
    public static func ratioTable() -> String {
        var rows = ["| Pair | Kind | Needs | Light | Dark | Light, IC | Dark, IC |",
                    "|---|---|---|---|---|---|---|"]
        for pair in requirements {
            let needs: String
            if let minimum = pair.minimum {
                needs = pair.increasedContrastMinimum == minimum ? format(minimum) : "\(format(minimum)); IC \(format(pair.increasedContrastMinimum))"
            } else {
                needs = "decorative; IC \(format(pair.increasedContrastMinimum))"
            }
            let ratios = AgentLandAppearance.allCases.map { String(format: "%.2f", pair.ratio(in: $0)) }
            rows.append("| \(pair.name) | \(pair.kind.rawValue) | \(needs) | " + ratios.joined(separator: " | ") + " |")
        }
        return rows.joined(separator: "\n")
    }

    private static func format(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }
}
