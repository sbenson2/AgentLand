import SwiftUI

/// Minimum hit sizes from the Human Interface Guidelines: 44×44 pt on iPhone and iPad, 28×28 pt on Mac.
public enum AgentLandTapTarget {
    public static let iOSMinimum: CGFloat = 44
    public static let macOSMinimum: CGFloat = 28

    public static var platformMinimum: CGFloat {
        #if os(macOS)
        macOSMinimum
        #else
        iOSMinimum
        #endif
    }

    /// `bounds` grown evenly around its centre until each side is at least `minimum`.
    public static func hitRect(for bounds: CGRect, minimum: CGFloat) -> CGRect {
        let dx = max(0, (minimum - bounds.width) / 2)
        let dy = max(0, (minimum - bounds.height) / 2)
        return bounds.insetBy(dx: -dx, dy: -dy)
    }
}

/// How `minimumTapTarget` meets the minimum.
public enum AgentLandTapTargetMode: Sendable {
    /// Keep the control's layout size and grow only its hit area around it. Neighbours need enough
    /// spacing that the grown areas don't overlap.
    case expandHitArea
    /// Grow the control's layout frame to the minimum.
    case reserveSpace
}

public extension EnvironmentValues {
    /// The minimum hit side, the platform's by default. Previews and tests can set the other platform's.
    @Entry var agentLandMinimumTapTarget: CGFloat = AgentLandTapTarget.platformMinimum
}

public extension View {
    /// Makes this control label's hit area at least 44×44 pt (28×28 pt on Mac).
    ///
    /// Apply it to a button's or menu's label, not to the button: the grown area belongs to the label,
    /// so a tap on it triggers the control.
    func minimumTapTarget(_ mode: AgentLandTapTargetMode = .expandHitArea) -> some View {
        modifier(MinimumTapTargetModifier(mode: mode))
    }
}

struct MinimumTapTargetModifier: ViewModifier {
    @Environment(\.agentLandMinimumTapTarget) private var minimum
    let mode: AgentLandTapTargetMode

    func body(content: Content) -> some View {
        switch mode {
        case .expandHitArea:
            TapTargetLayout(minimum: minimum) {
                Color.clear
                    .contentShape(Rectangle())
                    .reportsTapTarget()
                    .accessibilityHidden(true)
                content
            }
        case .reserveSpace:
            content
                .frame(minWidth: minimum, minHeight: minimum)
                .contentShape(Rectangle())
                .reportsTapTarget()
        }
    }
}

/// Sizes and places the content (the second subview) as usual and lays the hit pad (the first,
/// drawn behind it) over the grown rectangle, outside the reported size.
struct TapTargetLayout: Layout {
    let minimum: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        subviews[1].sizeThatFits(proposal)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews[1].place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
        let hit = AgentLandTapTarget.hitRect(for: bounds, minimum: minimum)
        subviews[0].place(at: hit.origin, anchor: .topLeading, proposal: ProposedViewSize(hit.size))
    }

    func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout ()) -> CGFloat? {
        bounds.minX + subviews[1].dimensions(in: ProposedViewSize(bounds.size))[guide]
    }

    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout ()) -> CGFloat? {
        bounds.minY + subviews[1].dimensions(in: ProposedViewSize(bounds.size))[guide]
    }
}

/// The hit areas that `minimumTapTarget` produced, collected for render tests.
struct TapTargetPreferenceKey: PreferenceKey {
    static let defaultValue: [Anchor<CGRect>] = []
    static func reduce(value: inout [Anchor<CGRect>], nextValue: () -> [Anchor<CGRect>]) {
        value += nextValue()
    }
}

extension View {
    func reportsTapTarget() -> some View {
        anchorPreference(key: TapTargetPreferenceKey.self, value: .bounds) { [$0] }
    }
}
