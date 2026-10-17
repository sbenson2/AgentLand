import SwiftUI

/// A short count or word in a capsule, for example the number of changed files beside Git.
/// It grows with Dynamic Type; a single character stays a circle.
public struct Badge: View {
    public enum Style: String, CaseIterable, Sendable {
        /// `onTint` on a `tint` capsule, for counts that want attention.
        case prominent
        /// `textSecondary` inside a `separator` outline, on whatever background the badge sits.
        case neutral
    }

    /// Counts above this show as "99+".
    public static let maximumCount = 99

    @ScaledMetric(relativeTo: .caption) private var minimumSide: CGFloat = 20

    private let text: String
    private let style: Style

    public init(_ text: String, style: Style = .neutral) {
        self.text = text
        self.style = style
    }

    public init(count: Int, style: Style = .prominent) {
        self.init(Self.label(forCount: count), style: style)
    }

    static func label(forCount count: Int) -> String {
        count > maximumCount ? "\(maximumCount)+" : String(max(0, count))
    }

    public var body: some View {
        Text(text)
            .font(AgentLandTypeRole.caption.font.weight(.semibold))
            .monospacedDigit()
            .lineLimit(1)
            .foregroundStyle(style == .prominent ? AgentLandColor.onTint : AgentLandColor.textSecondary)
            .padding(.horizontal, AgentLandSpacing.xSmall - AgentLandSpacing.xxxSmall)
            .frame(minWidth: minimumSide, minHeight: minimumSide)
            .background {
                switch style {
                case .prominent: Capsule().fill(AgentLandColor.tint)
                case .neutral: Capsule().strokeBorder(AgentLandColor.separator, lineWidth: 1)
                }
            }
            .fixedSize()
    }
}

#Preview("Badges") {
    HStack(spacing: AgentLandSpacing.small) {
        Badge(count: 3)
        Badge(count: 128)
        Badge("New")
        Badge("Beta", style: .prominent)
    }
    .padding()
    .background(AgentLandColor.canvas)
}
