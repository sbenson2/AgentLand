import SwiftUI

/// Whether the host can be reached, as the banner shows it.
public enum ConnectionStatus: Hashable, Sendable {
    case online
    case offline(title: String, detail: String? = nil, systemImage: String = "wifi.exclamationmark")

    public var isOffline: Bool {
        if case .offline = self { true } else { false }
    }
}

/// The offline banner. Keep it in the view tree at all times: it draws nothing while online, shows the
/// offline card when the connection is lost, and tells VoiceOver both about the loss (interrupting
/// current speech) and about the recovery.
///
/// VoiceOver reads it before the rest of the screen: it has a high `accessibilitySortPriority`, so place
/// it as a sibling of the screen's content inside one accessibility container.
public struct ConnectionStatusBanner: View {
    public static let accessibilitySortPriority: Double = 1000

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.agentLandAnnouncer) private var announcer

    private let status: ConnectionStatus
    private let recoveredAnnouncement: String
    private let retryTitle: String
    private let retry: (() -> Void)?
    private let identifier: String?
    private let retryIdentifier: String?

    /// `identifier` goes on the offline card and `retryIdentifier` on its Retry button, for UI
    /// automation; neither exists while online.
    public init(status: ConnectionStatus, recoveredAnnouncement: String = "Back online",
                retryTitle: String = "Retry", retry: (() -> Void)? = nil,
                identifier: String? = nil, retryIdentifier: String? = nil) {
        self.status = status
        self.recoveredAnnouncement = recoveredAnnouncement
        self.retryTitle = retryTitle
        self.retry = retry
        self.identifier = identifier
        self.retryIdentifier = retryIdentifier
    }

    public var body: some View {
        VStack(spacing: 0) {
            if case let .offline(title, detail, systemImage) = status {
                card(title: title, detail: detail, systemImage: systemImage)
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilitySortPriority(Self.accessibilitySortPriority)
        .onChange(of: status, initial: true) { old, new in
            if let announcement = Self.announcement(from: old, to: new, recovered: recoveredAnnouncement) {
                announcer.announce(announcement.text, priority: announcement.priority)
            }
        }
    }

    /// What to say when the status goes from `old` to `new` (the same value on first appearance).
    static func announcement(from old: ConnectionStatus, to new: ConnectionStatus,
                             recovered: String) -> (text: String, priority: AgentLandAnnouncer.Priority)? {
        switch new {
        case let .offline(title, detail, _):
            return ([title, detail].compactMap { $0 }.joined(separator: ". "), .high)
        case .online:
            return old.isOffline ? (recovered, .normal) : nil
        }
    }

    private func card(title: String, detail: String?, systemImage: String) -> some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: AgentLandSpacing.xxSmall) {
                    message(title: title, detail: detail, systemImage: systemImage)
                    retryButton.frame(maxWidth: .infinity, alignment: .trailing)
                }
            } else {
                HStack(spacing: AgentLandSpacing.xxSmall) {
                    message(title: title, detail: detail, systemImage: systemImage)
                    retryButton
                }
            }
        }
        .padding(.leading, AgentLandSpacing.small)
        .padding(.trailing, retry == nil ? AgentLandSpacing.small : AgentLandSpacing.xxSmall)
        .padding(.vertical, AgentLandSpacing.xxSmall)
        .modifier(NoticeChrome())
        .accessibilityElement(children: .contain)
        .optionalAccessibilityIdentifier(identifier)
    }

    private func message(title: String, detail: String?, systemImage: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AgentLandSpacing.small) {
            Image(systemName: systemImage)
                .font(AgentLandTypeRole.secondary.font.weight(.semibold))
                .foregroundStyle(AgentLandColor.danger)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: AgentLandSpacing.xxxSmall) {
                Text(title)
                    .font(AgentLandTypeRole.secondary.font.weight(.semibold))
                    .foregroundStyle(AgentLandColor.text)
                if let detail {
                    Text(detail)
                        .agentLandFont(.metadata)
                        .foregroundStyle(AgentLandColor.textSecondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, AgentLandSpacing.xSmall)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var retryButton: some View {
        if let retry {
            Button(action: retry) { NoticeButtonLabel(title: retryTitle) }
                .agentLandControlButton()
                .optionalAccessibilityIdentifier(retryIdentifier)
        }
    }
}

#Preview("Connection banner") {
    VStack(spacing: AgentLandSpacing.small) {
        ConnectionStatusBanner(status: .offline(title: "Can’t reach Studio Mac",
                                                detail: "The Mac may be asleep or on another network. Reconnecting…"),
                               retry: {})
        ConnectionStatusBanner(status: .offline(title: "No network connection",
                                                detail: "AgentLand reconnects when this device is back online.",
                                                systemImage: "wifi.slash"))
        ConnectionStatusBanner(status: .online)
    }
    .padding()
    .background(AgentLandColor.canvas)
    .environment(\.agentLandAnnouncer, AgentLandAnnouncer { _, _ in })
}
