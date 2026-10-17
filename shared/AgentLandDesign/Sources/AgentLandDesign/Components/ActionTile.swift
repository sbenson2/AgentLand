import SwiftUI

/// A launcher label with a symbol and title. On iOS, its Button or Menu supplies native control chrome
/// through `agentLandControlButton()`. Mac keeps the surface card and pointer highlight with `.plain`.
/// `showsDisclosure` adds the chevron for a tile that opens a menu.
///
/// At accessibility text sizes the symbol moves above the title so the title keeps the full width and
/// wraps instead of shrinking.
public struct ActionTile: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.agentLandMinimumTapTarget) private var minimumTapTarget
    @ScaledMetric(relativeTo: .subheadline) private var minimumHeight: CGFloat = 48
    @State private var hovering = false

    private let title: String
    private let systemImage: String
    private let showsDisclosure: Bool

    public init(_ title: String, systemImage: String, showsDisclosure: Bool = false) {
        self.title = title
        self.systemImage = systemImage
        self.showsDisclosure = showsDisclosure
    }

    @ViewBuilder public var body: some View {
        #if os(iOS)
        content
            .frame(maxWidth: .infinity, minHeight: minimumTapTarget, alignment: .leading)
            .reportsTapTarget()
        #else
        let shape = AgentLandRadius.shape(AgentLandRadius.card)
        content
            .padding(.horizontal, AgentLandSpacing.small)
            .padding(.vertical, AgentLandSpacing.xSmall)
            .frame(maxWidth: .infinity, minHeight: max(minimumTapTarget, minimumHeight), alignment: .leading)
            .background(hovering ? AgentLandColor.surfaceRaised : AgentLandColor.surface, in: shape)
            .overlay(shape.strokeBorder(AgentLandColor.separator, lineWidth: 1))
            .contentShape(shape)
            .reportsTapTarget()
            .modifier(TileHover(shape: shape, hovering: $hovering))
        #endif
    }

    @ViewBuilder private var content: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: AgentLandSpacing.xSmall) {
                symbol
                HStack(alignment: .firstTextBaseline, spacing: AgentLandSpacing.xSmall) {
                    titleText
                    disclosure
                }
            }
        } else {
            HStack(spacing: AgentLandSpacing.xSmall) {
                symbol
                titleText
                disclosure
            }
        }
    }

    private var symbol: some View {
        Image(systemName: systemImage)
            .font(AgentLandTypeRole.body.font)
            .foregroundStyle(isEnabled ? AgentLandColor.textSecondary : AgentLandColor.glyphTertiary)
            .agentLandIconFrame(.regular)
            .accessibilityHidden(true)
    }

    private var titleText: some View {
        Text(title)
            .font(AgentLandTypeRole.secondary.font.weight(.medium))
            .foregroundStyle(isEnabled ? AgentLandColor.text : AgentLandColor.textSecondary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var disclosure: some View {
        if showsDisclosure {
            Image(systemName: "chevron.down")
                .font(AgentLandTypeRole.caption.font.weight(.semibold))
                .foregroundStyle(AgentLandColor.glyphTertiary)
                .accessibilityHidden(true)
        }
    }
}

/// The pointer highlight on iPad and a raised fill under the cursor on Mac (tiles and capsules).
struct TileHover<S: Shape>: ViewModifier {
    let shape: S
    @Binding var hovering: Bool

    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .contentShape(.hoverEffect, shape)
            .hoverEffect(.highlight)
        #else
        content.onHover { hovering = $0 }
        #endif
    }
}

#Preview("Action tiles") {
    Grid(horizontalSpacing: AgentLandSpacing.xSmall, verticalSpacing: AgentLandSpacing.xSmall) {
        GridRow {
            ActionTile("New chat", systemImage: "bubble.left.and.bubble.right", showsDisclosure: true)
            ActionTile("New terminal", systemImage: "terminal", showsDisclosure: true)
        }
        GridRow {
            ActionTile("Browse files", systemImage: "folder")
            ActionTile("Resume work", systemImage: "clock.arrow.circlepath").disabled(true)
        }
    }
    .padding()
    .background(AgentLandColor.canvas)
}
