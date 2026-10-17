import SwiftUI
import XCTest
@testable import AgentLandBranding
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
@testable import AgentLandDesign

/// Each token resolves to its own value for light, dark and both Increase Contrast appearances, through
/// SwiftUI's environment, UIKit trait collections and AppKit appearances. On iPhone and iPad a token with a system
/// color resolves to that color instead.
final class ColorResolutionTests: XCTestCase {
    /// The tokens whose own values every platform draws: all of them on the Mac, those without a system color on
    /// iPhone and iPad.
    private var ownValueTokens: [AgentLandColor] {
        let tokens = AgentLandColor.semanticColors + AgentLandColor.artColors
        #if canImport(UIKit)
        return tokens.filter { $0.system == nil }
        #else
        return tokens
        #endif
    }

    /// The app's AccentColor asset is AgentLand blue: the `tint` token's four values.
    func testAccentColorAssetIsTheTint() throws {
        let asset = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("ios/AgentLand/Assets.xcassets/AccentColor.colorset/Contents.json")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: asset)) as? [String: Any])
        let colors = try XCTUnwrap(json["colors"] as? [[String: Any]])
        var found: [AgentLandAppearance: AgentLandRGB] = [:]
        for entry in colors {
            let appearances = (entry["appearances"] as? [[String: String]]) ?? []
            let appearance = AgentLandAppearance(isDark: appearances.contains { $0["appearance"] == "luminosity" && $0["value"] == "dark" },
                                                 increasedContrast: appearances.contains { $0["appearance"] == "contrast" && $0["value"] == "high" })
            let color = try XCTUnwrap(entry["color"] as? [String: Any])
            XCTAssertEqual(color["color-space"] as? String, "srgb")
            let parts = try XCTUnwrap(color["components"] as? [String: String])
            func byte(_ key: String) throws -> UInt32 {
                let text = try XCTUnwrap(parts[key])
                return try XCTUnwrap(UInt32(text.replacingOccurrences(of: "0x", with: ""), radix: 16), key)
            }
            found[appearance] = AgentLandRGB((try byte("red") << 16) | (try byte("green") << 8) | (try byte("blue")))
        }
        for appearance in AgentLandAppearance.allCases {
            XCTAssertEqual(found[appearance], AgentLandColor.tint.rgb(for: appearance), "\(appearance)")
        }
    }

    func testArtTokensMatchEveryPackagedClownRamp() throws {
        XCTAssertEqual(AgentLandColor.artTones.count, 5)
        for clown in AgentLandClownArtwork.designs {
            for (ramp, appearance) in [(AgentLandClownRamp.day, AgentLandAppearance.light), (.night, .dark)] {
                let packaged = try XCTUnwrap(clown.tones[ramp]).map { $0.map(Int.init) }
                XCTAssertEqual(AgentLandColor.artTones.map { components($0.rgb(for: appearance)) }, packaged,
                               "Design tokens and circus artwork share the same palette")
            }
        }
    }

    private func environment(_ appearance: AgentLandAppearance) -> EnvironmentValues {
        var environment = EnvironmentValues()
        environment.colorScheme = appearance.isDark ? .dark : .light
        environment._colorSchemeContrast = appearance.increasedContrast ? .increased : .standard
        return environment
    }

    private func components(_ resolved: Color.Resolved) -> [Int] {
        [resolved.red, resolved.green, resolved.blue].map { Int(($0 * 255).rounded()) }
    }

    private func components(_ rgb: AgentLandRGB) -> [Int] {
        [rgb.red, rgb.green, rgb.blue].map { Int(($0 * 255).rounded()) }
    }

    func testRGBValues() {
        let rgb = AgentLandRGB(0x0E1422)
        XCTAssertEqual(rgb.description, "#0E1422")
        XCTAssertEqual(AgentLandRGB(0x000814).description, "#000814")
        XCTAssertEqual(components(rgb), [0x0E, 0x14, 0x22])
    }

    func testAppearanceFromSwiftUIEnvironment() {
        for appearance in AgentLandAppearance.allCases {
            XCTAssertEqual(AgentLandAppearance(environment(appearance)), appearance)
        }
    }

    func testShapeStyleResolvesFromColorSchemeAndContrast() {
        for token in ownValueTokens {
            for appearance in AgentLandAppearance.allCases {
                XCTAssertEqual(components(token.resolve(in: environment(appearance))), components(token.rgb(for: appearance)),
                               "\(token.name), \(appearance)")
            }
        }
    }

    /// Drawn by SwiftUI, a token fill takes the value for the view's color scheme and contrast.
    @MainActor
    func testTokenFillsRenderInEveryAppearance() throws {
        for appearance in AgentLandAppearance.allCases {
            for token in ownValueTokens {
                let swatch = Rectangle().fill(token).frame(width: 4, height: 4)
                    .environment(\._colorSchemeContrast, appearance.increasedContrast ? .increased : .standard)
                let result = try render(swatch, colorScheme: appearance.isDark ? .dark : .light)
                assertColor(result.color(at: CGPoint(x: 2, y: 2)), equals: token.rgb(for: appearance), "\(token.name), \(appearance)")
            }
        }
    }

    func testTokensDifferBetweenAppearances() {
        for token in AgentLandColor.semanticColors {
            XCTAssertNotEqual(token.light, token.dark, token.name)
            XCTAssertNotEqual(token.dark, token.darkIncreasedContrast, token.name)
        }
    }

    func testDynamicColorFollowsTheColorScheme() {
        for token in ownValueTokens {
            for appearance in [AgentLandAppearance.light, .dark] {
                XCTAssertEqual(components(token.color.resolve(in: environment(appearance))), components(token.rgb(for: appearance)),
                               "\(token.name), \(appearance)")
            }
        }
    }

    #if canImport(UIKit)
    func testUIColorResolvesFromTraits() {
        for token in ownValueTokens {
            for appearance in AgentLandAppearance.allCases {
                var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
                token.uiColor.resolvedColor(with: traits(appearance)).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
                XCTAssertEqual([red, green, blue].map { Int(($0 * 255).rounded()) }, components(token.rgb(for: appearance)),
                               "\(token.name), \(appearance)")
            }
        }
    }

    /// A token with a system color is that color, in UIKit and SwiftUI alike.
    func testSystemTokensResolveToTheSystemColors() {
        for token in AgentLandColor.semanticColors {
            guard let system = token.system else { continue }
            for appearance in AgentLandAppearance.allCases {
                XCTAssertEqual(token.uiColor.resolvedColor(with: traits(appearance)), system.uiColor.resolvedColor(with: traits(appearance)),
                               "\(token.name), \(appearance)")
                XCTAssertEqual(token.resolve(in: environment(appearance)), Color(uiColor: system.uiColor).resolve(in: environment(appearance)),
                               "\(token.name), \(appearance)")
            }
        }
    }

    private func traits(_ appearance: AgentLandAppearance) -> UITraitCollection {
        UITraitCollection { traits in
            traits.userInterfaceStyle = appearance.isDark ? .dark : .light
            traits.accessibilityContrast = appearance.increasedContrast ? .high : .normal
        }
    }
    #elseif canImport(AppKit)
    func testAppKitAppearanceNamesMapToAppearances() {
        XCTAssertEqual(AgentLandAppearance(bestMatch: .aqua), .light)
        XCTAssertEqual(AgentLandAppearance(bestMatch: .darkAqua), .dark)
        XCTAssertEqual(AgentLandAppearance(bestMatch: .accessibilityHighContrastAqua), .lightIncreasedContrast)
        XCTAssertEqual(AgentLandAppearance(bestMatch: .accessibilityHighContrastDarkAqua), .darkIncreasedContrast)
        XCTAssertEqual(AgentLandAppearance(bestMatch: nil), .light)
        XCTAssertEqual(AgentLandAppearance(appearance: NSAppearance(named: .darkAqua)!), .dark)
        XCTAssertEqual(AgentLandAppearance(appearance: NSAppearance(named: .aqua)!), .light)
    }

    /// AppKit only hands out the high-contrast appearances while the system setting is on, so this checks
    /// light and dark; the high-contrast names are covered by the mapping above.
    func testNSColorResolvesUnderAppearances() throws {
        for token in ownValueTokens {
            for (name, appearance) in [(NSAppearance.Name.aqua, AgentLandAppearance.light), (.darkAqua, .dark)] {
                var resolved: NSColor?
                try XCTUnwrap(NSAppearance(named: name)).performAsCurrentDrawingAppearance {
                    resolved = token.nsColor.usingColorSpace(.sRGB)
                }
                let color = try XCTUnwrap(resolved)
                XCTAssertEqual([color.redComponent, color.greenComponent, color.blueComponent].map { Int(($0 * 255).rounded()) },
                               components(token.rgb(for: appearance)), "\(token.name), \(appearance)")
            }
        }
    }
    #endif
}
