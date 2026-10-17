import Foundation
import SwiftUI

/// Interface animations with their Reduce Motion fallbacks. UI test runs launched with
/// `-AgentLandUITestsDisableAnimations` get no animation at all.
///
/// Every interface animation runs for `standardDuration` (owner's request, 2026-10-04: one speed for the
/// whole app, the average of the drawers' former 0.2 s and Home's action boxes' 0.3 s). The cases keep
/// their curves; only the speed is shared. The one exception is the iPhone's header panels closing, which
/// go as quickly as a native menu does (`drawerClose`, `quickDuration`; owner's instruction, 2026-10-05).
public enum AgentLandMotion: String, CaseIterable, Sendable {
    /// Things that move or change size: banners, notices, expanding rows, Home's action boxes (`.smooth`).
    case smooth
    /// Small state changes: selection, toggles, button feedback (`.snappy`).
    case snappy
    /// The iPhone's header panels growing out of their buttons: a spring with an iOS 26 menu's small settle (a native
    /// menu overshoots about 8% and settles, measured 2026-10-05), at the one speed.
    case drawer
    /// The iPhone's header panels shrinking back into their buttons: as quick as a native menu's close (it goes in
    /// well under 0.1 s, measured 2026-10-05), with no settle.
    case drawerClose

    /// The app's one interface speed.
    public static let standardDuration: TimeInterval = 0.25
    /// A header panel's close: a native menu's speed, not the app's one speed.
    public static let quickDuration: TimeInterval = 0.1

    /// What replaces the animation under Reduce Motion.
    public enum ReducedMotion: Sendable {
        /// A 0.12 s ease: fades and color changes stay soft; nothing travels or bounces.
        case quickEase
        /// No animation.
        case none
    }

    /// The same launch argument the app and the title's motion gate use.
    public static let uiTestsDisableAnimationsArgument = "-AgentLandUITestsDisableAnimations"

    public static func animationsDisabledForUITests(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        arguments.contains(uiTestsDisableAnimationsArgument)
    }

    /// The full animation, before Reduce Motion or UI tests are considered.
    public var animation: Animation {
        switch self {
        case .smooth: .smooth(duration: Self.standardDuration)
        case .drawer: .spring(duration: Self.standardDuration, bounce: 0.15)
        case .drawerClose: .smooth(duration: Self.quickDuration)
        case .snappy: .snappy(duration: Self.standardDuration)
        }
    }

    /// The animation to run: nil in UI test runs, the fallback under Reduce Motion, otherwise `animation`.
    public func animation(reduceMotion: Bool, reducedMotion: ReducedMotion = .quickEase,
                          arguments: [String] = ProcessInfo.processInfo.arguments) -> Animation? {
        if Self.animationsDisabledForUITests(arguments: arguments) { return nil }
        guard reduceMotion else { return animation }
        switch reducedMotion {
        case .quickEase: return .easeInOut(duration: 0.12)
        case .none: return nil
        }
    }
}

public extension View {
    /// Animates changes to `value` with an AgentLand motion, following Reduce Motion from the environment.
    func agentLandAnimation<V: Equatable>(_ motion: AgentLandMotion, value: V,
                                          reducedMotion: AgentLandMotion.ReducedMotion = .quickEase) -> some View {
        modifier(AgentLandAnimationModifier(motion: motion, value: value, reducedMotion: reducedMotion))
    }
}

/// `withAnimation` for an AgentLand motion. Pass the view's `accessibilityReduceMotion`.
@MainActor
public func withAgentLandAnimation<Result>(_ motion: AgentLandMotion, reduceMotion: Bool,
                                           reducedMotion: AgentLandMotion.ReducedMotion = .quickEase,
                                           _ body: () throws -> Result) rethrows -> Result {
    try withAnimation(motion.animation(reduceMotion: reduceMotion, reducedMotion: reducedMotion), body)
}

struct AgentLandAnimationModifier<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let motion: AgentLandMotion
    let value: V
    let reducedMotion: AgentLandMotion.ReducedMotion

    func body(content: Content) -> some View {
        content.animation(motion.animation(reduceMotion: reduceMotion, reducedMotion: reducedMotion), value: value)
    }
}
