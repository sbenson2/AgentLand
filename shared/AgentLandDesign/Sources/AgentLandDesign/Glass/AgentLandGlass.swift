import SwiftUI

// Liquid Glass belongs to the navigation and controls layer only (HIG, Materials):
// - Use it on floating controls: the composer group, jump to latest, a docked "needs your input" pill.
//   System bars already provide their own.
// - Never on content: messages, rows, cards, code blocks, the terminal, sheets' bodies.
// - Never stack glass on glass. A `glassControl()` inside another adds nothing.
// - At most one `.glassProminent` control per screen. Where a label sits on a `tint` fill of its own, give it
//   `onTint` so dark mode keeps its contrast.
// - Group neighbouring glass controls in one `GlassControlGroup` so they blend and morph together.

public extension View {
    /// A floating control on Liquid Glass, in a capsule.
    func glassControl(interactive: Bool = true) -> some View {
        glassControl(in: Capsule(), interactive: interactive)
    }

    /// A floating control on Liquid Glass in `shape`. iOS owns its accessibility material treatment;
    /// Mac keeps the opaque theme fallback. Inside another glass control this adds nothing.
    func glassControl<S: InsettableShape>(in shape: S, interactive: Bool = true) -> some View {
        modifier(GlassControlModifier(shape: shape, interactive: interactive))
    }
}

/// Neighbouring glass controls that blend and morph together (a `GlassEffectContainer`).
public struct GlassControlGroup<Content: View>: View {
    private let spacing: CGFloat?
    private let content: Content

    public init(spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    public var body: some View {
        GlassEffectContainer(spacing: spacing) {
            content
        }
    }
}

/// What a glass control draws behind itself.
enum GlassControlBackground: Equatable {
    case glass
    case opaque
    /// Already on glass: nothing, so glass never stacks.
    case none

    init(reduceTransparency: Bool, insideGlass: Bool) {
        if insideGlass {
            self = .none
        } else {
            self = reduceTransparency ? .opaque : .glass
        }
    }
}

public extension EnvironmentValues {
    /// True inside a glass control's content.
    @Entry var agentLandInsideGlass = false
}

struct GlassControlModifier<S: InsettableShape>: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.agentLandInsideGlass) private var insideGlass
    let shape: S
    let interactive: Bool

    func body(content: Content) -> some View {
        #if os(iOS)
        if insideGlass {
            content
        } else {
            // iOS owns Reduce Transparency and contrast treatment for its glass.
            content
                .environment(\.agentLandInsideGlass, true)
                .glassEffect(.regular.interactive(interactive), in: shape)
        }
        #else
        switch GlassControlBackground(reduceTransparency: reduceTransparency, insideGlass: insideGlass) {
        case .glass:
            content
                .environment(\.agentLandInsideGlass, true)
                .glassEffect(.regular.interactive(interactive), in: shape)
        case .opaque:
            content
                .environment(\.agentLandInsideGlass, true)
                .background(AgentLandColor.surfaceRaised, in: shape)
                .overlay(shape.strokeBorder(AgentLandColor.separator, lineWidth: 1))
        case .none:
            content
        }
        #endif
    }
}
