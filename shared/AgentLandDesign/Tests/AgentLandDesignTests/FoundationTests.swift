import SwiftUI
import XCTest
import AgentLandBranding
@testable import AgentLandDesign

/// Type roles, metrics, motion and haptics.
@MainActor
final class FoundationTests: XCTestCase {
    func testTypeRolesUseDynamicTypeTextStyles() {
        let expected: [AgentLandTypeRole: Font.TextStyle] = [
            .body: .body, .bodyEmphasized: .body, .secondary: .subheadline,
            .metadata: .footnote, .caption: .caption, .caption2: .caption2,
            .code: .subheadline, .codeSmall: .footnote,
            .heading1: .title2, .heading2: .title3, .heading3: .headline,
            .quip: .callout
        ]
        XCTAssertEqual(Set(expected.keys), Set(AgentLandTypeRole.allCases))
        for (role, style) in expected {
            XCTAssertEqual(role.textStyle, style, role.rawValue)
        }
        XCTAssertEqual(AgentLandTypeRole.code.design, .monospaced)
        XCTAssertEqual(AgentLandTypeRole.codeSmall.design, .monospaced)
        XCTAssertEqual(AgentLandTypeRole.bodyEmphasized.weight, .semibold)
        XCTAssertTrue(AgentLandTypeRole.quip.isItalic)
        XCTAssertEqual(AgentLandTypeRole.allCases.filter(\.isItalic), [.quip])
        XCTAssertEqual(AgentLandTypeRole.allCases.filter { $0.design == .monospaced }, [.code, .codeSmall])
    }

    func testTypeRolesRender() throws {
        for role in AgentLandTypeRole.allCases {
            for typeSize in renderTestTypeSizes {
                let result = try render(Text("Resume work").agentLandFont(role), typeSize: typeSize)
                XCTAssertTrue(result.hasVisiblePixels, role.rawValue)
            }
        }
        // Monospaced code keeps equal advances.
        let narrow = try render(Text("iiii").agentLandFont(.code)), wide = try render(Text("MMMM").agentLandFont(.code))
        XCTAssertEqual(narrow.size.width, wide.size.width, accuracy: 1)
    }

    func testSpacingAndRadius() {
        XCTAssertEqual(AgentLandSpacing.scale, [2, 4, 8, 12, 16, 24, 32, 48])
        XCTAssertEqual([AgentLandRadius.chip, AgentLandRadius.card, AgentLandRadius.bubble, AgentLandRadius.composer], [8, 12, 20, 28])
        XCTAssertEqual(AgentLandRadius.concentric(outer: AgentLandRadius.composer, padding: 8), AgentLandRadius.bubble)
        XCTAssertEqual(AgentLandRadius.concentric(outer: AgentLandRadius.card, padding: 4), AgentLandRadius.chip)
        XCTAssertEqual(AgentLandRadius.concentric(outer: 8, padding: 12), 0)
        XCTAssertEqual(AgentLandRadius.shape(AgentLandRadius.card).style, .continuous)
    }

    func testTapTargetMinimums() {
        XCTAssertEqual(AgentLandTapTarget.iOSMinimum, 44)
        XCTAssertEqual(AgentLandTapTarget.macOSMinimum, 28)
        #if os(macOS)
        XCTAssertEqual(AgentLandTapTarget.platformMinimum, 28)
        #else
        XCTAssertEqual(AgentLandTapTarget.platformMinimum, 44)
        #endif
        XCTAssertEqual(EnvironmentValues().agentLandMinimumTapTarget, AgentLandTapTarget.platformMinimum)
        let hit = AgentLandTapTarget.hitRect(for: CGRect(x: 10, y: 20, width: 20, height: 50), minimum: 44)
        XCTAssertEqual(hit, CGRect(x: -2, y: 20, width: 44, height: 50))
    }

    func testScaledIconsAndRows() throws {
        XCTAssertEqual(AgentLandIconSize.allCases.map(\.baseSide), [16, 20, 28])
        for height in AgentLandRowHeight.allCases {
            XCTAssertGreaterThanOrEqual(height.baseHeight, AgentLandTapTarget.platformMinimum)
        }
        for size in AgentLandIconSize.allCases {
            let result = try render(Image(systemName: "folder").agentLandIconFrame(size))
            XCTAssertEqual(result.size, CGSize(width: size.baseSide, height: size.baseSide), size.rawValue)
        }
        for minimum in [AgentLandTapTarget.platformMinimum, AgentLandTapTarget.iOSMinimum] {
            let row = try render(Text("General").agentLandRowHeight(), width: 300, minimumTapTarget: minimum)
            XCTAssertGreaterThanOrEqual(row.size.height, max(minimum, AgentLandRowHeight.standard.baseHeight))
            let twoLine = try render(Text("General").agentLandRowHeight(.twoLine), width: 300, minimumTapTarget: minimum)
            XCTAssertGreaterThanOrEqual(twoLine.size.height, AgentLandRowHeight.twoLine.baseHeight)
        }
    }

    func testMotionAndItsFallbacks() {
        let none: [String] = []
        XCTAssertEqual(AgentLandMotion.smooth.animation(reduceMotion: false, arguments: none), .smooth(duration: 0.25))
        XCTAssertEqual(AgentLandMotion.snappy.animation(reduceMotion: false, arguments: none), .snappy(duration: 0.25))
        XCTAssertEqual(AgentLandMotion.drawer.animation(reduceMotion: false, arguments: none), .spring(duration: 0.25, bounce: 0.15))
        // A header panel closes as quickly as a native menu (panels-v3, 2026-10-05).
        XCTAssertEqual(AgentLandMotion.quickDuration, 0.1)
        XCTAssertEqual(AgentLandMotion.drawerClose.animation(reduceMotion: false, arguments: none), .smooth(duration: 0.1))
        for motion in AgentLandMotion.allCases {
            XCTAssertEqual(motion.animation(reduceMotion: true, arguments: none), .easeInOut(duration: 0.12))
            XCTAssertNil(motion.animation(reduceMotion: true, reducedMotion: .none, arguments: none))
            let uiTests = ["AgentLand", "-AgentLandUITestsDisableAnimations"]
            XCTAssertNil(motion.animation(reduceMotion: false, arguments: uiTests))
            XCTAssertNil(motion.animation(reduceMotion: true, arguments: uiTests))
        }
        // The same switch as the app and the title's motion gate.
        XCTAssertEqual(AgentLandMotion.uiTestsDisableAnimationsArgument, AgentLandWordmarkMotionGate.uiTestsDisableAnimationsArgument)
    }

    func testHapticsMapToSensoryFeedback() {
        XCTAssertEqual(AgentLandHaptic.selection.feedback, .selection)
        XCTAssertEqual(AgentLandHaptic.success.feedback, .success)
        XCTAssertEqual(AgentLandHaptic.warning.feedback, .warning)
        // The modifiers compile onto any view and render.
        let view = Text("Send")
            .agentLandHaptic(.success, trigger: 1)
            .agentLandHaptic(.warning, trigger: 1) { old, new in new > old }
        XCTAssertNoThrow(try render(view))
    }
}
