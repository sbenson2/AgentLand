import SwiftUI
import AgentLandBranding
import AgentLandDesign
import AgentLandCore

/// What the transcript's rows can ask the screen to do.
struct ChatRowActions {
    var editAndResend: @MainActor (String) -> Void = { _ in }
    var runAgain: @MainActor () -> Void = {}
    var fork: @MainActor (String?) -> Void = { _ in }
    var continueWithAnotherModel: @MainActor () -> Void = {}
    var sendAgain: @MainActor (PendingSend) -> Void = { _ in }
}

/// User text as typed: line breaks kept, fenced blocks shown as code, nothing
/// else styled, so pasted logs stay faithful.
enum ChatUserText {
    enum Segment: Hashable { case text(String), code(language: String, code: String) }

    static func segments(_ text: String) -> [Segment] {
        var result: [Segment] = []
        var prose: [String] = []
        var code: [String]?
        var language = ""
        var fence = ""
        func flushProse() {
            let joined = prose.joined(separator: "\n")
            if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result.append(.text(joined)) }
            prose = []
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if var open = code {
                if trimmed.hasPrefix(fence), trimmed.allSatisfy({ $0 == fence.first }) {
                    result.append(.code(language: language, code: open.joined(separator: "\n")))
                    code = nil
                } else {
                    open.append(line)
                    code = open
                }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushProse()
                fence = String(trimmed.prefix(while: { $0 == trimmed.first }))
                language = String(trimmed.dropFirst(fence.count)).trimmingCharacters(in: .whitespaces)
                code = []
                continue
            }
            prose.append(line)
        }
        if let open = code { result.append(.code(language: language, code: open.joined(separator: "\n"))) }
        flushProse()
        return result
    }
}

/// A user message: a trailing bubble with the text as typed.
struct ChatUserBubble: View {
    let text: String
    let attachments: [AttachmentRecord]
    let createdAt: Date?
    let maxWidth: CGFloat
    let identifier: String
    @State private var expanded = false
    @Environment(\.colorSchemeContrast) private var contrast

    private var lineCount: Int { text.reduce(1) { $1 == "\n" ? $0 + 1 : $0 } }
    private var collapsible: Bool { lineCount > 12 }

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if !attachments.isEmpty { ChatAttachmentChips(attachments) }
            if !text.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(shownSegments.enumerated()), id: \.offset) { _, segment in
                        switch segment {
                        case let .text(value):
                            Text(verbatim: value)
                                .font(.body)
                                .foregroundStyle(AgentLandColor.text.color)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        case let .code(language, code):
                            ChatCodeBlock(language: language, code: code, role: .reply)
                        }
                    }
                    if collapsible {
                        Button(expanded ? "Show Less" : "Show Full Message") { expanded.toggle() }
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(AgentLandColor.tint.color)
                            .chatBorderlessButton()
                            .frame(minHeight: ChatMetrics.target)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(AgentLandColor.surface.color, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    if contrast == .increased {
                        RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(AgentLandColor.text.color.opacity(0.6), lineWidth: 1)
                    }
                }
            }
        }
        .frame(maxWidth: maxWidth, alignment: .trailing)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var shownSegments: [ChatUserText.Segment] {
        guard collapsible, !expanded else { return ChatUserText.segments(text) }
        let first = text.split(separator: "\n", omittingEmptySubsequences: false).prefix(8).joined(separator: "\n")
        return ChatUserText.segments(first + "\n…")
    }

    /// "Your message, 9:41: …" for VoiceOver.
    static func accessibilityLabel(text: String, attachments: [AttachmentRecord], at date: Date?) -> String {
        var label = "Your message"
        if let date { label += ", \(ChatTimeFormat.clock(date))" }
        if !attachments.isEmpty { label += ", with \(attachments.map(\.name).joined(separator: ", "))" }
        return label + ": " + text
    }
}

/// Files sent with a message, by name.
public struct ChatAttachmentChips: View {
    let attachments: [AttachmentRecord]
    public init(_ attachments: [AttachmentRecord]) { self.attachments = attachments }

    public var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { chips }
            VStack(alignment: .trailing, spacing: 6) { chips }
        }
    }

    private var chips: some View {
        ForEach(Array(attachments.enumerated()), id: \.offset) { _, attachment in
            HStack(spacing: 5) {
                Image(systemName: ChatAttachmentPolicy.symbol(forMime: attachment.mime))
                Text(attachment.name).lineLimit(1).truncationMode(.middle)
            }
            .font(.footnote)
            .foregroundStyle(AgentLandColor.text.color)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(AgentLandColor.surface.color, in: Capsule())
            #if os(macOS)
            .overlay(Capsule().strokeBorder(AgentLandColor.separator.color, lineWidth: 0.5))
            #endif
            .accessibilityLabel("Attachment \(attachment.name)")
        }
    }
}

/// A user message row with its context menu and VoiceOver actions.
struct ChatUserRow: View {
    let message: ChatMessageModel
    let store: ChatSessionStore
    let maxWidth: CGFloat
    let actions: ChatRowActions

    var body: some View {
        let text = message.plainText
        let created = ChatTime.date(message.createdAt)
        let editable = store.canEditLatest && message.id == store.latestUserMessageID
        ChatUserBubble(text: text, attachments: message.attachments, createdAt: created, maxWidth: maxWidth, identifier: message.id)
            #if os(iOS)
            .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 18, style: .continuous))
            #endif
            .contextMenu {
                Button("Copy", systemImage: "doc.on.doc") { ChatClipboard.copy(text) }
                if editable {
                    Button("Edit and Resend…", systemImage: "pencil") { actions.editAndResend(message.id) }
                        .accessibilityIdentifier("chatEditLatest")
                }
                Button("Use in Composer", systemImage: "text.insert") { store.useInComposer(text) }
                    .accessibilityIdentifier("chatUseInComposer")
                if store.canFork {
                    Button { actions.fork(message.id) } label: {
                        Label("Fork from Here", systemImage: "arrow.triangle.branch")
                        Text(store.isWorking ? "Waits until the agent stops" : "Uses the same files")
                    }
                    .disabled(store.isWorking)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(ChatUserBubble.accessibilityLabel(text: text, attachments: message.attachments, at: created))
            .accessibilityAddTraits(.isStaticText)
            .accessibilityIdentifier("chatUserMessage")
            .accessibilityActions {
                Button("Copy") { ChatClipboard.copy(text) }
                if editable { Button("Edit and Resend") { actions.editAndResend(message.id) } }
                Button("Use in Composer") { store.useInComposer(text) }
            }
    }
}

/// A message this device sent that the transcript does not show yet.
struct ChatPendingRow: View {
    let pending: PendingSend
    let store: ChatSessionStore
    let maxWidth: CGFloat
    let actions: ChatRowActions

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            ChatUserBubble(text: pending.text, attachments: pending.attachmentNames, createdAt: pending.createdAt, maxWidth: maxWidth,
                           identifier: pending.id.uuidString)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(ChatUserBubble.accessibilityLabel(text: pending.text, attachments: pending.attachmentNames, at: pending.createdAt))
                .accessibilityAddTraits(.isStaticText)
                .accessibilityIdentifier("chatUserMessage")
            badge
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    @ViewBuilder private var badge: some View {
        switch pending.delivery {
        case .sending:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Sending…")
            }
            .font(.caption)
            .foregroundStyle(AgentLandColor.textSecondary.color)
            .accessibilityElement(children: .combine)
        case .accepted:
            EmptyView()
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Checking…")
            }
            .font(.caption)
            .foregroundStyle(AgentLandColor.textSecondary.color)
            .accessibilityElement(children: .combine)
        case .notConfirmed:
            VStack(alignment: .trailing, spacing: 4) {
                Label("Not Confirmed", systemImage: "questionmark.circle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AgentLandColor.warning.color)
                    .accessibilityIdentifier("chatNotConfirmed")
                Text("The connection broke before your Mac answered. It may have arrived.")
                    .font(.caption)
                    .foregroundStyle(AgentLandColor.textSecondary.color)
                    .multilineTextAlignment(.trailing)
                HStack(spacing: 8) {
                    Button { Task { await store.checkPending(pending.id) } } label: { Text("Check").minimumTapTarget() }
                        .accessibilityIdentifier("chatCheckPending")
                    Button { actions.sendAgain(pending) } label: { Text("Send Again").minimumTapTarget() }
                        .accessibilityIdentifier("chatSendAgain")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .frame(minHeight: ChatMetrics.target)
            }
        case let .notSent(reason):
            VStack(alignment: .trailing, spacing: 4) {
                Label("Not Sent", systemImage: "exclamationmark.circle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AgentLandColor.danger.color)
                    .accessibilityIdentifier("chatNotSent")
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(AgentLandColor.textSecondary.color)
                    .multilineTextAlignment(.trailing)
                HStack(spacing: 8) {
                    Button { actions.sendAgain(pending) } label: { Text("Send Again").minimumTapTarget() }
                        .accessibilityIdentifier("chatSendAgain")
                    Button { store.editPending(pending.id) } label: { Text("Edit").minimumTapTarget() }
                    Button(role: .destructive) { store.discardPending(pending.id) } label: { Text("Delete").minimumTapTarget() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .frame(minHeight: ChatMetrics.target)
            }
        }
    }
}

/// The seed of a chat continued from another: shown collapsed.
struct ChatContextRow: View {
    let message: ChatMessageModel
    let store: ChatSessionStore
    @Environment(\.colorSchemeContrast) private var contrast

    private var expanded: Bool { store.isExpanded(message.id) }

    var body: some View {
        #if os(iOS)
        ChatDisclosureGroup(key: message.id, store: store) {
            ChatMarkdownView(message.plainText, role: .supporting)
                .padding(.bottom, 12)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "text.quote")
                Text("Context from an earlier chat")
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(AgentLandColor.textSecondary.color)
        }
        .padding(.horizontal, 12)
        .chatCard(increasedContrast: contrast == .increased)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chatContextSeed")
        #else
        VStack(alignment: .leading, spacing: 8) {
            Button {
                store.toggleExpanded(message.id)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "text.quote")
                    Text("Context from an earlier chat")
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .accessibilityHidden(true)
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AgentLandColor.textSecondary.color)
                .padding(.horizontal, 12)
                .frame(minHeight: ChatMetrics.target)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            if expanded {
                ChatMarkdownView(message.plainText, role: .supporting)
                    .padding([.horizontal, .bottom], 12)
            }
        }
        .chatCard(increasedContrast: contrast == .increased)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chatContextSeed")
        #endif
    }
}

/// An agent reply: its parts in order, then a failure card, a Stopped or
/// No response marker, and on the latest finished reply its action row.
struct ChatReplyView: View {
    let reply: ChatReplyModel
    let store: ChatSessionStore
    let actions: ChatRowActions
    let rotor: Namespace.ID
    @State private var hovering = false
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let parts = reply.parts
        let streaming = reply.isStreaming
        let running = streaming && reply.isLatest
        let plain = store.isPlainChat
        let segments = ChatReplySegment.make(parts, resolved: reply.resolved, plain: plain)
        let lastText = parts.last(where: { $0.kind == .text })?.id
        let name = store.provider.chatDisplayName
        VStack(alignment: .leading, spacing: 10) {
            if parts.isEmpty && running { ChatStatusLine(store: store) }
            ForEach(segments) { segment in
                switch segment {
                case let .text(part):
                    ChatTextPart(part: part, caret: running && part.id == parts.last?.id, store: store, showsStatus: running && part.id == lastText)
                case let .single(part) where plain && part.kind == .tool:
                    // A plain chat's tools read as plain cards: what was searched or read, and what was remembered.
                    ChatPlainToolCard(part: part, interrupted: reply.aborted, store: store)
                case let .single(part):
                    ChatWorkItem(part: part, live: running && part.id == parts.last?.id, interrupted: reply.aborted, store: store)
                case let .group(items):
                    ChatToolGroup(parts: items, live: running && items.last?.id == parts.last?.id, interrupted: reply.aborted, store: store)
                case let .notice(part):
                    ChatNoticeRow(part: part)
                case let .attachment(part):
                    if let attachment = part.attachment { ChatAttachmentChips([attachment]) }
                case let .resolved(item):
                    ChatResolvedLine(item: item, at: store.resolvedAt[item.id])
                }
            }
            if reply.failed, let error = reply.error {
                // A plain chat's tools change no files, so its card never says they may have.
                ChatErrorCard(error: error, provider: store.provider,
                              didToolWork: !plain && parts.contains { $0.kind == .tool || $0.kind == .patch },
                              canRunAgain: reply.isLatest && !store.isWorking) {
                    Task { await store.sendPromptAgain() }
                }
            } else if reply.aborted {
                Label("Stopped", systemImage: "stop.circle")
                    .font(.footnote)
                    .foregroundStyle(AgentLandColor.textSecondary.color)
                    .accessibilityIdentifier("chatStoppedMarker")
            } else if !streaming, reply.messages.allSatisfy({ $0.status == .complete }),
                      parts.allSatisfy({ $0.kind != .tool && $0.kind != .patch }), reply.plainText.isEmpty {
                HStack(spacing: 8) {
                    Label("No response", systemImage: "ellipsis.bubble")
                        .font(.footnote)
                        .foregroundStyle(AgentLandColor.textSecondary.color)
                    if reply.isLatest && !store.isWorking {
                        Button { Task { await store.sendPromptAgain() } } label: {
                            Text("Run Again").font(.footnote).minimumTapTarget()
                        }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("chatRunAgainEmpty")
                    }
                }
            }
            // Text is read only once the reply stops streaming, so deltas
            // redraw the streaming part alone, not this whole row.
            if !streaming, reply.isLatest || hovering || contrast == .increased, !reply.plainText.isEmpty {
                ChatReplyActionRow(reply: reply, store: store, runAgain: actions.runAgain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu { menu }
        .environment(\.chatAccessibilityActions, accessibilityActions)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(name) reply")
        .accessibilityIdentifier("chatReply")
        .accessibilityRotorEntry(id: reply.id, in: rotor)
    }

    @ViewBuilder private var menu: some View {
        Button("Copy", systemImage: "doc.on.doc") { ChatClipboard.copy(reply.plainText) }
        if !reply.isStreaming {
            ShareLink(item: reply.plainText) { Label("Share…", systemImage: "square.and.arrow.up") }
        }
        if reply.isLatest && store.canRunAgain {
            Button("Run Again…", systemImage: "arrow.clockwise", action: actions.runAgain)
        }
        if store.canFork {
            Button { actions.fork(reply.messages.last?.id) } label: {
                Label("Fork from Here", systemImage: "arrow.triangle.branch")
                Text(store.isWorking ? "Waits until the agent stops" : "Uses the same files")
            }
            .disabled(store.isWorking)
        }
        if store.canContinue {
            Button("Continue with Another Model…", systemImage: "arrow.triangle.swap", action: actions.continueWithAnotherModel)
        }
        Button("Use in Composer", systemImage: "text.insert") { store.useInComposer(reply.plainText) }
    }

    private var accessibilityActions: [ChatAccessibilityAction] {
        var result = [ChatAccessibilityAction(name: "Copy Reply") { ChatClipboard.copy(reply.plainText) }]
        if reply.isLatest && store.canRunAgain { result.append(ChatAccessibilityAction(name: "Run Again", perform: actions.runAgain)) }
        if store.canFork && !store.isWorking {
            let id = reply.messages.last?.id
            result.append(ChatAccessibilityAction(name: "Fork from Here") { actions.fork(id) })
        }
        result.append(ChatAccessibilityAction(name: "Use in Composer") { store.useInComposer(reply.plainText) })
        return result
    }
}

/// A reply's text part; the caret follows its last glyph while it streams.
struct ChatTextPart: View {
    let part: ChatPartModel
    let caret: Bool
    let store: ChatSessionStore
    let showsStatus: Bool

    var body: some View {
        let blocks = part.markdownBlocks
        if blocks.isEmpty {
            if caret && showsStatus { ChatStatusLine(store: store) }
        } else {
            ChatMarkdownBlocks(blocks: blocks, role: .reply, caret: caret)
                .accessibilityIdentifier("chatReplyText")
        }
    }
}
