import SwiftUI

/// A launcher label with a symbol and a medium-weight title. Its iOS Button or Menu supplies native
/// control chrome through `agentLandControlButton()`. Mac keeps the surface capsule, separator border
/// and pointer highlight with `.plain`. Group labels in an `ActionCapsuleGrid`; `showsDisclosure` adds
/// a menu chevron. `compact` opts into a 48 pt label baseline while preserving the minimum tap target.
///
/// The content is centred and a long title wraps instead of shrinking. The capsule fills the height it is
/// offered, so capsules side by side in a grid are one size. At accessibility text sizes the symbol moves
/// above the title so the title keeps the full width. The Mac capsule also becomes a rounded rectangle.
public struct ActionCapsule: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.agentLandMinimumTapTarget) private var minimumTapTarget
    @ScaledMetric(relativeTo: .body) private var standardMinimumHeight: CGFloat = 56
    @ScaledMetric(relativeTo: .body) private var compactMinimumHeight: CGFloat = 48
    @State private var hovering = false

    private let title: String
    private let systemImage: String
    private let showsDisclosure: Bool
    private let compact: Bool

    public init(_ title: String, systemImage: String, showsDisclosure: Bool = false, compact: Bool = false) {
        self.title = title
        self.systemImage = systemImage
        self.showsDisclosure = showsDisclosure
        self.compact = compact
    }

    @ViewBuilder public var body: some View {
        #if os(iOS)
        content
            .frame(maxWidth: .infinity, minHeight: minimumTapTarget, maxHeight: .infinity)
            .reportsTapTarget()
        #else
        if dynamicTypeSize.isAccessibilitySize {
            decorated(AgentLandRadius.shape(AgentLandRadius.card))
        } else {
            decorated(Capsule())
        }
        #endif
    }

    private func decorated<S: InsettableShape>(_ shape: S) -> some View {
        content
            .padding(.horizontal, compact ? AgentLandSpacing.xSmall : AgentLandSpacing.small)
            .padding(.vertical, compact ? AgentLandSpacing.xxSmall : AgentLandSpacing.xSmall)
            .frame(maxWidth: .infinity,
                   minHeight: max(minimumTapTarget, compact ? compactMinimumHeight : standardMinimumHeight),
                   maxHeight: .infinity)
            .background(hovering ? AgentLandColor.surfaceRaised : AgentLandColor.surface, in: shape)
            .overlay(shape.strokeBorder(AgentLandColor.separator, lineWidth: 1))
            .contentShape(shape)
            .reportsTapTarget()
            .modifier(TileHover(shape: shape, hovering: $hovering))
    }

    @ViewBuilder private var content: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: AgentLandSpacing.xSmall) {
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
            .font(AgentLandTypeRole.body.font.weight(.medium))
            .foregroundStyle(isEnabled ? AgentLandColor.text : AgentLandColor.textSecondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
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

/// Lays out action capsules (each in its `Button` or `Menu`) in equal columns, `spacing` apart both ways.
/// Every cell is as tall as the tallest capsule, so the ovals line up, and a last row that is not full is
/// centred: five actions in two columns put the fifth under the middle.
public struct ActionCapsuleGrid: Layout {
    public let columns: Int
    public let spacing: CGFloat

    public init(columns: Int = 2, spacing: CGFloat = AgentLandSpacing.medium) {
        self.columns = max(1, columns)
        self.spacing = spacing
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let width = proposal.width ?? idealWidth(subviews)
        let cell = cellSize(width: width, subviews: subviews)
        let rows = CGFloat((subviews.count + columns - 1) / columns)
        return CGSize(width: width, height: rows * cell.height + (rows - 1) * spacing)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let cell = cellSize(width: bounds.width, subviews: subviews)
        for (index, subview) in subviews.enumerated() {
            let row = index / columns, column = index % columns
            let inRow = CGFloat(min(columns, subviews.count - row * columns))
            let rowWidth = inRow * cell.width + (inRow - 1) * spacing
            let x = bounds.minX + (bounds.width - rowWidth) / 2 + CGFloat(column) * (cell.width + spacing)
            let y = bounds.minY + CGFloat(row) * (cell.height + spacing)
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(cell))
        }
    }

    /// The cells' size at `width`: equal columns, as tall as the tallest subview at the column's width.
    private func cellSize(width: CGFloat, subviews: Subviews) -> CGSize {
        let cellWidth = max(0, (width - CGFloat(columns - 1) * spacing) / CGFloat(columns))
        let height = subviews.map { $0.sizeThatFits(ProposedViewSize(width: cellWidth, height: nil)).height }.max() ?? 0
        return CGSize(width: cellWidth, height: height)
    }

    /// Without a proposed width: columns as wide as the widest subview wants.
    private func idealWidth(_ subviews: Subviews) -> CGFloat {
        let widest = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        return widest * CGFloat(columns) + CGFloat(columns - 1) * spacing
    }
}

#Preview("Action capsules") {
    ActionCapsuleGrid {
        ActionCapsule("New Chat", systemImage: "bubble.left.and.bubble.right", showsDisclosure: true)
        ActionCapsule("New Terminal", systemImage: "terminal", showsDisclosure: true)
        ActionCapsule("Browse Files", systemImage: "folder")
        ActionCapsule("Resume Work", systemImage: "clock.arrow.circlepath").disabled(true)
        ActionCapsule("Open Workspace", systemImage: "square.grid.2x2")
    }
    .padding()
    .background(AgentLandColor.canvas)
}
