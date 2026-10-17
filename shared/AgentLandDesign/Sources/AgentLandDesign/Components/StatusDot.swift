import SwiftUI

/// A small status mark. Each status has its own shape as well as its own color, so it reads without
/// color: online ●, working ◉, needs attention ◆, offline ■, idle ○. It grows with Dynamic Type.
///
/// It is one accessibility element with the status as its label. When a visible text label beside it
/// already says the same thing, hide the dot from accessibility.
public struct StatusDot: View {
    public enum Status: String, CaseIterable, Sendable {
        case online, working, attention, offline, idle

        public var color: AgentLandColor {
            switch self {
            case .online: .success
            case .working: .tint
            case .attention: .warning
            case .offline: .danger
            case .idle: .glyphTertiary
            }
        }

        public var label: String {
            switch self {
            case .online: "Online"
            case .working: "Working"
            case .attention: "Needs attention"
            case .offline: "Offline"
            case .idle: "Idle"
            }
        }
    }

    @ScaledMetric(relativeTo: .caption) private var side: CGFloat = 10

    private let status: Status
    private let label: String

    public init(_ status: Status, label: String? = nil) {
        self.status = status
        self.label = label ?? status.label
    }

    public var body: some View {
        mark
            .frame(width: side, height: side)
            .accessibilityElement()
            .accessibilityLabel(label)
    }

    @ViewBuilder private var mark: some View {
        let color = status.color
        switch status {
        case .online:
            Circle().fill(color)
        case .working:
            Circle().strokeBorder(color, lineWidth: side * 0.2)
                .overlay(Circle().fill(color).padding(side * 0.32))
        case .attention:
            RoundedRectangle(cornerRadius: side * 0.12, style: .continuous).fill(color)
                .rotationEffect(.degrees(45))
                .padding(side * 0.15)
        case .offline:
            RoundedRectangle(cornerRadius: side * 0.15, style: .continuous).fill(color)
                .padding(side * 0.06)
        case .idle:
            Circle().strokeBorder(color, lineWidth: side * 0.2)
        }
    }
}

#Preview("Status dots") {
    VStack(alignment: .leading, spacing: AgentLandSpacing.xSmall) {
        ForEach(StatusDot.Status.allCases, id: \.self) { status in
            HStack(spacing: AgentLandSpacing.xSmall) {
                StatusDot(status).accessibilityHidden(true)
                Text(status.label).foregroundStyle(AgentLandColor.text)
            }
        }
    }
    .padding()
    .background(AgentLandColor.canvas)
}
