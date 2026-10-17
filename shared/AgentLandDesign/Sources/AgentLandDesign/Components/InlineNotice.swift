import SwiftUI

/// The one toast style: a symbol, a title and an optional message on the raised card, with an optional
/// action and a dismiss button, each at least the minimum tap target. VoiceOver hears it when it
/// appears and whenever its text changes; warnings and errors interrupt current speech.
///
/// The tone is carried by the symbol's shape and the spoken prefix as well as by color.
public struct InlineNotice: View {
    public enum Tone: String, CaseIterable, Sendable {
        case info, success, warning, error

        public var systemImage: String {
            switch self {
            case .info: "info.circle.fill"
            case .success: "checkmark.circle.fill"
            case .warning: "exclamationmark.triangle.fill"
            case .error: "xmark.octagon.fill"
            }
        }

        public var color: AgentLandColor {
            switch self {
            case .info: .tint
            case .success: .success
            case .warning: .warning
            case .error: .danger
            }
        }

        /// Said before the title, since the symbol's color and shape aren't.
        var spokenPrefix: String? {
            switch self {
            case .info, .success: nil
            case .warning: "Warning"
            case .error: "Error"
            }
        }

        var priority: AgentLandAnnouncer.Priority {
            switch self {
            case .info, .success: .normal
            case .warning, .error: .high
            }
        }
    }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.agentLandAnnouncer) private var announcer

    private let title: String
    private let message: String?
    private let tone: Tone
    private let actionTitle: String?
    private let action: (() -> Void)?
    private let onDismiss: (() -> Void)?
    private let identifiers: Identifiers

    /// Accessibility identifiers for UI automation: the text, the action and the dismiss button.
    /// They go on those elements, never on the notice's container, so one cannot replace another.
    public struct Identifiers: Sendable {
        public var text: String?
        public var action: String?
        public var dismiss: String?

        public init(text: String? = nil, action: String? = nil, dismiss: String? = nil) {
            self.text = text
            self.action = action
            self.dismiss = dismiss
        }
    }

    public init(_ title: String, message: String? = nil, tone: Tone = .info,
                actionTitle: String? = nil, action: (() -> Void)? = nil, onDismiss: (() -> Void)? = nil,
                identifiers: Identifiers = Identifiers()) {
        self.title = title
        self.message = message
        self.tone = tone
        self.actionTitle = actionTitle
        self.action = action
        self.onDismiss = onDismiss
        self.identifiers = identifiers
    }

    /// What VoiceOver says when the notice appears.
    public var spokenText: String {
        var parts: [String] = []
        if let prefix = tone.spokenPrefix { parts.append(prefix + ":") }
        parts.append(title)
        if let message { parts.append(message) }
        return parts.joined(separator: " ")
    }

    public var body: some View {
        Group {
            if stacksButtons {
                VStack(alignment: .leading, spacing: AgentLandSpacing.xxSmall) {
                    text
                    buttons.frame(maxWidth: .infinity, alignment: .trailing)
                }
            } else {
                HStack(spacing: AgentLandSpacing.xxSmall) {
                    text
                    buttons
                }
            }
        }
        .padding(.leading, AgentLandSpacing.small)
        .padding(.trailing, hasButtons ? AgentLandSpacing.xxSmall : AgentLandSpacing.small)
        .padding(.vertical, AgentLandSpacing.xxSmall)
        .modifier(NoticeChrome())
        .accessibilityElement(children: .contain)
        .onChange(of: spokenText, initial: true) { _, text in
            announcer.announce(text, priority: tone.priority)
        }
    }

    private var stacksButtons: Bool {
        #if os(iOS)
        dynamicTypeSize.isAccessibilitySize || hasButtons
        #else
        dynamicTypeSize.isAccessibilitySize
        #endif
    }

    private var hasButtons: Bool { (actionTitle != nil && action != nil) || onDismiss != nil }

    private var text: some View {
        HStack(alignment: .firstTextBaseline, spacing: AgentLandSpacing.small) {
            Image(systemName: tone.systemImage)
                .font(AgentLandTypeRole.secondary.font)
                .foregroundStyle(tone.color)
            VStack(alignment: .leading, spacing: AgentLandSpacing.xxxSmall) {
                Text(title)
                    .font(AgentLandTypeRole.secondary.font.weight(.semibold))
                    .foregroundStyle(AgentLandColor.text)
                if let message {
                    Text(message)
                        .agentLandFont(.metadata)
                        .foregroundStyle(AgentLandColor.textSecondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, AgentLandSpacing.xSmall)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenText)
        .optionalAccessibilityIdentifier(identifiers.text)
    }

    @ViewBuilder private var buttons: some View {
        if hasButtons {
            HStack(spacing: 0) {
                if let actionTitle, let action {
                    Button(action: action) { NoticeButtonLabel(title: actionTitle) }
                        .agentLandControlButton()
                        .optionalAccessibilityIdentifier(identifiers.action)
                }
                if let onDismiss {
                    Button(action: onDismiss) { DismissButtonLabel() }
                        .agentLandControlButton()
                        .accessibilityLabel("Dismiss")
                        .optionalAccessibilityIdentifier(identifiers.dismiss)
                }
            }
        }
    }
}

#Preview("Inline notices") {
    VStack(spacing: AgentLandSpacing.small) {
        InlineNotice("Copied")
        InlineNotice("Saved README.md", tone: .success, onDismiss: {})
        InlineNotice("Chat moved to the archive", message: "Its files are still on your Mac.",
                     actionTitle: "Undo", action: {}, onDismiss: {})
        InlineNotice("Couldn't save the file", message: "The Mac is offline. Your edits are kept.",
                     tone: .error, onDismiss: {})
    }
    .padding()
    .background(AgentLandColor.canvas)
    .environment(\.agentLandAnnouncer, AgentLandAnnouncer { _, _ in })
}
