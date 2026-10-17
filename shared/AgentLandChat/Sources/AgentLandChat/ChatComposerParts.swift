import SwiftUI
import AgentLandBranding
import AgentLandDesign
import AgentLandCore

/// Prompts waiting on the host. They send one at a time, in order, once the
/// agent is idle, even while this device is locked or closed.
public struct ChatQueueList: View {
    let items: [QueuedPrompt]
    let edit: (QueuedPrompt) -> Void
    let remove: (QueuedPrompt) -> Void

    public init(items: [QueuedPrompt], edit: @escaping (QueuedPrompt) -> Void, remove: @escaping (QueuedPrompt) -> Void) {
        self.items = items; self.edit = edit; self.remove = remove
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    Image(systemName: "text.line.first.and.arrowtriangle.forward")
                    Text("Queued · \(items.count)").fontWeight(.medium)
                    Spacer(minLength: 8)
                    Text(onHold ? "Queue on hold" : "Sends when the agent is ready")
                }
                Text("Queued · \(items.count)").fontWeight(.medium)
            }
            .font(.footnote)
            .foregroundStyle(AgentLandColor.textSecondary.color)
            .padding(.horizontal, 4)
            ForEach(items) { row($0) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chatQueue")
    }

    /// A failed item blocks the queue until the person edits or removes it.
    private var onHold: Bool { items.first?.status == .failed }

    private func row(_ item: QueuedPrompt) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Group {
                switch item.status {
                case .queued: Image(systemName: "clock").foregroundStyle(AgentLandColor.textSecondary.color)
                case .sending: ProgressView().controlSize(.mini)
                case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(AgentLandColor.danger.color)
                }
            }
            .font(.footnote)
            .frame(minWidth: 18)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.text)
                    .font(.subheadline)
                    .foregroundStyle(AgentLandColor.text.color)
                    .lineLimit(2)
                if item.status == .failed {
                    Text(item.error ?? "Not sent. Remove it or edit and send it again.")
                        .font(.caption)
                        .foregroundStyle(AgentLandColor.danger.color)
                } else if item.status == .sending {
                    Text("Sending…").font(.caption).foregroundStyle(AgentLandColor.textSecondary.color)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 4)
            Button { edit(item) } label: {
                Image(systemName: "pencil").foregroundStyle(.secondary)
                    .frame(minWidth: ChatMetrics.target, minHeight: ChatMetrics.target).contentShape(Rectangle())
            }
            .disabled(item.status == .sending)
            .accessibilityLabel("Edit Queued Message")
            Button { remove(item) } label: {
                Image(systemName: "xmark").foregroundStyle(.secondary)
                    .frame(minWidth: ChatMetrics.target, minHeight: ChatMetrics.target).contentShape(Rectangle())
            }
            .disabled(item.status == .sending)
            .accessibilityLabel("Remove Queued Message")
        }
        .chatBorderlessButton()
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .padding(.leading, 10)
        .background(AgentLandColor.surface.color, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        #if os(macOS)
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder((item.status == .failed ? AgentLandColor.danger.color : AgentLandColor.separator.color).opacity(0.7), lineWidth: 0.75))
        #endif
        // On iOS and iPad the paper or slate row alone, no outline (CH-17); a failed one says so in its icon and text.
    }
}

/// Shown while a chat is rewound for editing its latest message.
public struct ChatRewindBanner: View {
    let busy: Bool
    let restore: () -> Void

    public init(busy: Bool, restore: @escaping () -> Void) { self.busy = busy; self.restore = restore }

    public var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "arrow.uturn.backward.circle")
                .font(.title3)
                .foregroundStyle(AgentLandColor.tint.color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Editing your last message").font(.subheadline.weight(.semibold))
                Text("Send to continue from here, or restore the earlier reply.")
                    .font(.caption)
                    .foregroundStyle(AgentLandColor.textSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Button(action: restore) {
                Text("Restore").font(.subheadline.weight(.medium)).minimumTapTarget()
            }
                .buttonStyle(.bordered)
                .frame(minHeight: ChatMetrics.target)
                .disabled(busy)
                .accessibilityIdentifier("chatRestoreRewind")
        }
        .padding(10)
        .background(AgentLandColor.surface.color, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        #if os(macOS)
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(AgentLandColor.tint.color.opacity(0.5), lineWidth: 0.75))
        #endif
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chatRewindBanner")
    }
}

public enum ChatRewindCopy {
    public static let title = "Edit your last message?"
    public static let confirm = "Edit and Rewind"

    /// The consequences, with the file sentence only when files come back too.
    public static func message(provider: AgentProvider, restoresFiles: Bool) -> String {
        var text = "Everything after this message will be removed from this chat."
        if restoresFiles { text += " Changes \(provider.displayName) made to files after this point will be undone." }
        return text + " You can restore it until you send."
    }
}

/// What deleting a chat does, for its confirmation. A plain chat changes no files, so its has no file sentence.
public enum ChatDeleteCopy {
    public static func message(hostName: String, plainChat: Bool) -> String {
        let text = "It’s deleted from the archive on \(hostName) and from this device."
        return plainChat ? text : text + " Files the agent changed stay as they are."
    }
}
