import XCTest
#if canImport(UIKit)
import UIKit
#endif
@testable import AgentLandDesign

/// On iPhone and iPad the backgrounds, secondary text and separators draw the tokens' own paper and slate (the
/// owner's choice, 2026-10-07), while primary text, glyphs and the status colors draw exactly the system's. Primary
/// text keeps body-text contrast on every paper and slate background, and so does secondary text, which is why it
/// keeps the token's values rather than `secondaryLabel` (3.9:1 on the slate panels, 4.3:1 on the slate rows); glyphs
/// and the status colors keep what UIKit gives them, which Xcode's audits may call "nearly passed" under small text;
/// the UI tests log those findings. The checks run when the package's tests run on an iOS simulator
/// (`xcodebuild test -scheme AgentLandDesign -destination 'platform=iOS Simulator,…'` in the package); the Mac draws
/// the tokens' own values, which `ContrastTests` checks.
@MainActor
final class SystemTextContrastTests: XCTestCase {
    #if canImport(UIKit)
    /// Every background a word sits on: the screens' canvas, the rows' surface and the panels' and sheets' raised
    /// surface.
    private static let backgrounds: [(String, UIColor)] = [
        ("canvas", AgentLandColor.canvas.uiColor), ("surface", AgentLandColor.surface.uiColor),
        ("surfaceRaised", AgentLandColor.surfaceRaised.uiColor)
    ]

    /// Light and dark, at the base and the elevated level, with and without Increase Contrast.
    private static let appearances: [(String, UITraitCollection)] = {
        var all: [(String, UITraitCollection)] = []
        for style in [UIUserInterfaceStyle.light, .dark] {
            for level in [UIUserInterfaceLevel.base, .elevated] {
                for contrast in [UIAccessibilityContrast.normal, .high] {
                    let name = "\(style == .dark ? "Dark" : "Light")\(level == .elevated ? ", elevated" : "")\(contrast == .high ? ", IC" : "")"
                    all.append((name, UITraitCollection { traits in
                        traits.userInterfaceStyle = style
                        traits.userInterfaceLevel = level
                        traits.accessibilityContrast = contrast
                    }))
                }
            }
        }
        return all
    }()

    /// Primary text, glyphs and the status colors draw UIKit's own color in every appearance, with nothing of
    /// AgentLand's in between.
    func testTokensDrawUIKitsOwnColors() {
        let expected: [(AgentLandColor, UIColor)] = [
            (.text, .label), (.glyphTertiary, .tertiaryLabel),
            (.success, .systemGreen), (.warning, .systemOrange), (.danger, .systemRed)
        ]
        for (token, system) in expected {
            for (appearance, traits) in Self.appearances {
                XCTAssertEqual(token.uiColor.resolvedColor(with: traits), system.resolvedColor(with: traits),
                               "\(token.name), \(appearance)")
            }
        }
    }

    /// Primary text keeps body-text contrast (4.5:1) on every paper and slate background in every appearance.
    func testPrimaryTextKeepsBodyTextContrastOnTheSystemBackgrounds() {
        for (appearance, traits) in Self.appearances {
            for (name, background) in Self.backgrounds {
                let ratio = contrast(AgentLandColor.text.uiColor, on: background, traits)
                XCTAssertGreaterThanOrEqual(ratio, AgentLandContrast.text,
                                            String(format: "text on %@ in %@: %.2f:1", name, appearance, ratio))
            }
        }
    }

    /// Secondary text keeps body-text contrast (4.5:1) on every paper and slate background in every appearance (the
    /// owner's rule, 2026-10-07; the system's `secondaryLabel` would not on slate).
    func testSecondaryTextKeepsBodyTextContrastOnPaperAndSlate() {
        for (appearance, traits) in Self.appearances {
            for (name, background) in Self.backgrounds {
                let ratio = contrast(AgentLandColor.textSecondary.uiColor, on: background, traits)
                XCTAssertGreaterThanOrEqual(ratio, AgentLandContrast.text,
                                            String(format: "textSecondary on %@ in %@: %.2f:1", name, appearance, ratio))
            }
        }
    }

    /// What text, glyphs and the status colors measure on each background, for the record: the system's values for
    /// primary text, glyphs and status, which are not AgentLand's to raise. The table is printed and attached.
    func testRecordsTheSystemTextContrast() {
        var table: [String] = []
        for token in [AgentLandColor.text, .textSecondary, .glyphTertiary, .success, .warning, .danger] {
            for (appearance, traits) in Self.appearances {
                for (name, background) in Self.backgrounds {
                    let ratio = contrast(token.uiColor, on: background, traits)
                    XCTAssertGreaterThan(ratio, 1, "\(token.name) on \(name) in \(appearance) is visible")
                    table.append(String(format: "%@ on %@, %@: %.2f", token.name, name, appearance, ratio))
                }
            }
        }
        let text = table.joined(separator: "\n")
        print("System text contrast on iOS:\n\(text)")
        let attachment = XCTAttachment(string: text)
        attachment.name = "System text contrast"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The WCAG ratio of a foreground, composited over the background as it draws, against that background.
    private func contrast(_ foreground: UIColor, on background: UIColor, _ traits: UITraitCollection) -> Double {
        func components(_ color: UIColor) -> [Double] {
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            color.resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            return [red, green, blue, alpha].map(Double.init)
        }
        let back = components(background), front = components(foreground)
        func rgb(_ channels: [Double]) -> AgentLandRGB {
            let bytes = channels.prefix(3).map { UInt32((min(1, max(0, $0)) * 255).rounded()) }
            return AgentLandRGB(bytes[0] << 16 | bytes[1] << 8 | bytes[2])
        }
        let composited = (0..<3).map { front[$0] * front[3] + back[$0] * (1 - front[3]) }
        return rgb(composited).contrastRatio(with: rgb(back))
    }
    #endif
}
