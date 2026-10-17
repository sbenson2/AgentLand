import SwiftUI
import AgentLandDesign

/// A small heading over a group of rows: footnote, semibold, in the secondary color, read as a header.
struct WorkspaceSectionHeading: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(AgentLandTypeRole.metadata.font.weight(.semibold))
            .foregroundStyle(AgentLandColor.textSecondary)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The label of an icon-only control: the symbol at body size in a frame of at least the minimum tap
/// target, which grows with the text size.
struct WorkspaceIconLabel: View {
    let systemImage: String
    var color: AgentLandColor = .text

    var body: some View {
        Image(systemName: systemImage)
            .font(AgentLandTypeRole.body.font)
            .foregroundStyle(color)
            .agentLandIconFrame(.regular)
            .minimumTapTarget(.reserveSpace)
            .contentShape(Rectangle())
    }
}

extension View {
    /// The pointer highlight, shaped like `shape`: the system's on iPad, a raised fill under the
    /// cursor on the Mac (as action tiles have).
    func workspaceHover<S: Shape>(_ shape: S) -> some View {
        #if os(iOS)
        contentShape(.hoverEffect, shape).hoverEffect(.highlight)
        #else
        modifier(MacHoverHighlight(shape: shape))
        #endif
    }

    /// The pointer highlight for a full-width row.
    func workspaceRowHover() -> some View {
        workspaceHover(AgentLandRadius.shape(AgentLandRadius.chip))
    }

    /// A hairline under a bar or row, in the separator color.
    func workspaceHairline(_ edge: VerticalEdge = .bottom) -> some View {
        overlay(alignment: edge == .bottom ? .bottom : .top) {
            AgentLandColor.separator.color.frame(height: 0.5).accessibilityHidden(true)
        }
    }
}

#if os(macOS)
/// The Mac's hover state for plain buttons: the raised surface fill while the cursor is over it, and
/// none while the control is disabled.
private struct MacHoverHighlight<S: Shape>: ViewModifier {
    let shape: S
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background {
                if hovering && isEnabled { shape.fill(AgentLandColor.surfaceRaised) }
            }
            .onHover { hovering = $0 }
    }
}
#endif

/// True under `-AgentLandUITestsDisableAnimations` in debug builds: UI automation may use test-only
/// controls, such as rebuilding every surface.
var workspaceUITestHooks: Bool {
    #if DEBUG
    AgentLandMotion.animationsDisabledForUITests()
    #else
    false
    #endif
}
