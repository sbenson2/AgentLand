import Foundation
import XCTest
@testable import AgentLandDesign

/// WCAG 2.x contrast for every text and glyph pair in every appearance.
final class ContrastTests: XCTestCase {
    func testContrastMathMatchesWCAGReferenceValues() {
        XCTAssertEqual(AgentLandRGB(0x000000).contrastRatio(with: AgentLandRGB(0xFFFFFF)), 21, accuracy: 0.001)
        XCTAssertEqual(AgentLandRGB(0xFFFFFF).contrastRatio(with: AgentLandRGB(0xFFFFFF)), 1, accuracy: 0.001)
        // #767676 is the classic lightest gray that passes 4.5:1 on white; #777777 is the first that fails.
        XCTAssertEqual(AgentLandRGB(0x767676).contrastRatio(with: AgentLandRGB(0xFFFFFF)), 4.54, accuracy: 0.01)
        XCTAssertLessThan(AgentLandRGB(0x777777).contrastRatio(with: AgentLandRGB(0xFFFFFF)), 4.5)
        // The ratio is symmetric.
        let a = AgentLandRGB(0x2B55C6), b = AgentLandRGB(0xF7F8FB)
        XCTAssertEqual(a.contrastRatio(with: b), b.contrastRatio(with: a), accuracy: 1e-12)
    }

    func testEveryPairMeetsItsMinimumInEveryAppearance() {
        for pair in AgentLandContrast.requirements {
            for appearance in AgentLandAppearance.allCases {
                guard let minimum = pair.minimum(in: appearance) else { continue }
                let ratio = pair.ratio(in: appearance)
                XCTAssertGreaterThanOrEqual(ratio, minimum,
                                            "\(pair.name) is \(String(format: "%.2f", ratio)):1 in \(appearance), needs \(minimum):1")
            }
        }
    }

    func testTextPairsAreCheckedAtBodyTextContrast() {
        let text = AgentLandContrast.requirements.filter { $0.kind == .text }
        XCTAssertFalse(text.isEmpty)
        for pair in text {
            XCTAssertEqual(pair.minimum, AgentLandContrast.text, pair.name)
            XCTAssertGreaterThanOrEqual(pair.increasedContrastMinimum, AgentLandContrast.text, pair.name)
        }
        for pair in AgentLandContrast.requirements where pair.kind == .glyph || pair.kind == .art {
            XCTAssertEqual(pair.minimum, AgentLandContrast.graphics, pair.name)
        }
    }

    func testEveryTextAndGlyphTokenIsCheckedOnEveryBackground() {
        let checked = Set(AgentLandContrast.requirements.map { "\($0.foreground.name)|\($0.background.name)" })
        for foreground in [AgentLandColor.text, .textSecondary, .glyphTertiary, .tint, .success, .warning, .danger] {
            for background in AgentLandContrast.backgrounds {
                XCTAssertTrue(checked.contains("\(foreground.name)|\(background.name)"), "\(foreground.name) on \(background.name)")
            }
        }
        XCTAssertTrue(checked.contains("onTint|tint"))
        XCTAssertTrue(checked.contains("onBrand|brand"))
        XCTAssertTrue(checked.contains("artInk|artBackdrop"))
        XCTAssertTrue(checked.contains("artInkSecondary|artBackdrop"))
    }

    /// Home's quip sits on the art backdrop, so it keeps body-text contrast there, and AAA with Increase Contrast.
    func testWordsOnTheArtBackdropKeepTextContrast() throws {
        let pair = try XCTUnwrap(AgentLandContrast.requirements.first { $0.foreground == .artInkSecondary })
        XCTAssertEqual(pair.background, .artBackdrop)
        XCTAssertEqual(pair.kind, .text)
        XCTAssertEqual(pair.minimum, AgentLandContrast.text)
        XCTAssertEqual(pair.increasedContrastMinimum, AgentLandContrast.enhancedText)
    }

    func testIncreaseContrastNeverLowersAPair() {
        for pair in AgentLandContrast.requirements {
            XCTAssertGreaterThanOrEqual(pair.ratio(in: .lightIncreasedContrast), pair.ratio(in: .light) - 1e-9, "\(pair.name), light")
            XCTAssertGreaterThanOrEqual(pair.ratio(in: .darkIncreasedContrast), pair.ratio(in: .dark) - 1e-9, "\(pair.name), dark")
        }
    }

    func testPrimaryAndSecondaryTextReachAAAWithIncreaseContrast() {
        for foreground in [AgentLandColor.text, .textSecondary] {
            for background in AgentLandContrast.backgrounds {
                for appearance in [AgentLandAppearance.lightIncreasedContrast, .darkIncreasedContrast] {
                    let ratio = foreground.rgb(for: appearance).contrastRatio(with: background.rgb(for: appearance))
                    XCTAssertGreaterThanOrEqual(ratio, AgentLandContrast.enhancedText, "\(foreground.name) on \(background.name), \(appearance)")
                }
            }
        }
    }

    func testPrimaryButtonsUseDarkTextOnTheTintInDarkMode() {
        let darkLabel = AgentLandColor.onTint.rgb(for: .dark)
        XCTAssertLessThan(darkLabel.relativeLuminance, AgentLandColor.tint.rgb(for: .dark).relativeLuminance)
        // White on the dark-mode tint would fail AA; that is why onTint turns dark.
        XCTAssertLessThan(AgentLandRGB(0xFFFFFF).contrastRatio(with: AgentLandColor.tint.rgb(for: .dark)), AgentLandContrast.text)
        XCTAssertEqual(AgentLandColor.onTint.rgb(for: .light), AgentLandRGB(0xFFFFFF))
    }

    /// One brand color, the owner's slate: the covers, the launch screen and the icon background. The Home and
    /// empty-chat art keeps the paper/slate theme on every platform: paper or slate behind it, its ink the theme's
    /// text colors.
    func testBrandAndFixedColors() {
        XCTAssertEqual(AgentLandColor.brand.light, AgentLandRGB(0x27313F))
        XCTAssertEqual(AgentLandColor.tentDoorway.light, AgentLandRGB(0x1B222C))
        for fixed in [AgentLandColor.brand, .onBrand, .tentDoorway] {
            XCTAssertTrue(fixed.isFixed, fixed.name)
        }
        for token in AgentLandColor.semanticColors + AgentLandColor.artColors {
            XCTAssertFalse(token.isFixed, token.name)
        }
        XCTAssertEqual(AgentLandColor.artBackdrop.rgb(for: .light), AgentLandRGB(0xF4F0E7), "paper behind the art")
        XCTAssertEqual(AgentLandColor.artBackdrop.rgb(for: .dark), AgentLandColor.brand.light, "the slate of the covers behind the art")
        XCTAssertEqual(AgentLandColor.artInk.rgb(for: .light), AgentLandRGB(0x354052), "dark ink on paper")
        XCTAssertEqual(AgentLandColor.artInk.rgb(for: .dark), AgentLandRGB(0xD6DDE7), "light ink on slate")
        for appearance in AgentLandAppearance.allCases {
            // The Mac keeps the paper/slate canvas, so its art and its screens share one background.
            XCTAssertEqual(AgentLandColor.artBackdrop.rgb(for: appearance), AgentLandColor.canvas.rgb(for: appearance), "\(appearance)")
            XCTAssertEqual(AgentLandColor.artInkSecondary.rgb(for: appearance), AgentLandColor.textSecondary.rgb(for: appearance), "\(appearance)")
        }
        let names = (AgentLandColor.semanticColors + AgentLandColor.artColors).map(\.name)
        XCTAssertEqual(Set(names).count, names.count)
    }

    /// iPhone and iPad draw the system's colors for primary text, glyphs and status; the backgrounds, secondary text
    /// and separators draw paper and slate there too (the owner's choice, 2026-10-07), and the accent, its label color,
    /// the brand and the art keep AgentLand's own.
    func testIPhoneAndIPadDrawPaperAndSlateWithSystemLabels() {
        let expected: [(AgentLandColor, AgentLandSystemColor)] = [
            (.text, .label), (.glyphTertiary, .tertiaryLabel),
            (.success, .systemGreen), (.warning, .systemOrange), (.danger, .systemRed)
        ]
        for (token, system) in expected {
            XCTAssertEqual(token.system, system, token.name)
        }
        let paperAndSlate: [AgentLandColor] = [.canvas, .surface, .surfaceRaised, .textSecondary, .separator]
        for token in paperAndSlate + [.tint, .onTint, .brand, .onBrand, .tentDoorway] + AgentLandColor.artColors + AgentLandColor.artTones {
            XCTAssertNil(token.system, token.name)
        }
        XCTAssertEqual(Set(expected.map(\.0.name)).union(paperAndSlate.map(\.name)).union(["tint", "onTint"]),
                       Set(AgentLandColor.semanticColors.map(\.name)), "every interface token is mapped, paper and slate, or the accent")
        // The canvas is the art's own paper and slate, so Home and every other screen share one tone.
        for appearance in AgentLandAppearance.allCases {
            XCTAssertEqual(AgentLandColor.canvas.rgb(for: appearance), AgentLandColor.artBackdrop.rgb(for: appearance), "\(appearance)")
        }
    }

    /// The README records both tables; this keeps them equal to the code.
    func testReadmeRecordsTheCurrentTables() throws {
        let readme = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("README.md")
        let text = try String(contentsOf: readme, encoding: .utf8)
        let tokens = AgentLandContrast.tokenTable(), ratios = AgentLandContrast.ratioTable()
        XCTAssertTrue(text.contains(tokens), "README token table is out of date. Current:\n\(tokens)")
        XCTAssertTrue(text.contains(ratios), "README contrast table is out of date. Current:\n\(ratios)")
    }
}
