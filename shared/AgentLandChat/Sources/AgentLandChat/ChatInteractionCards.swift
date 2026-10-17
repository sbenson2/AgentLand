import SwiftUI
import AgentLandBranding
import AgentLandDesign
import AgentLandCore

/// The docked pill's words for a pending interaction.
enum ChatInteractionCopy {
    static func pill(_ interaction: ChatInteraction, provider: AgentProvider) -> (String, String) {
        if interaction.kind == .permission { return ("\(provider.chatDisplayName) needs permission", "Review") }
        let count = interaction.questions.count
        return (count == 1 ? "\(provider.chatDisplayName) asked a question" : "\(provider.chatDisplayName) asked \(count) questions", "Answer")
    }

    /// "Allow Claude to run this command?", "…to edit `Auth.swift`?", "…to use `tool`?".
    static func approvalTitle(_ permission: ChatPermission, provider: AgentProvider) -> String {
        let name = provider.chatDisplayName
        switch ChatToolKind(toolName: permission.tool) {
        case .command:
            return "Allow \(name) to run this command?"
        case .edit:
            let target = ChatToolSummary.target(for: .edit, tool: ConversationTool(name: permission.tool, status: .pending,
                                                                                   title: permission.title, input: permission.input))
            return target.map { "Allow \(name) to edit `\($0)`?" } ?? "Allow \(name) to edit files?"
        default:
            return "Allow \(name) to use `\(permission.tool.isEmpty ? "a tool" : permission.tool)`?"
        }
    }

    /// The exact command or target the request is for.
    static func approvalTarget(_ permission: ChatPermission) -> String {
        if let data = permission.input.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["command", "cmd", "filePath", "file_path", "path", "url", "pattern"] {
                if let value = object[key] as? String, !value.isEmpty { return value }
                if let value = object[key] as? [String], !value.isEmpty { return value.joined(separator: " ") }
            }
        }
        if !permission.title.isEmpty { return permission.title }
        return permission.input
    }

    /// The Always button's words: what the host says Always grants ("Allow
    /// Bash(npm test *) in this project"), or Always Allow when it says nothing.
    static func alwaysTitle(_ interaction: ChatInteraction) -> String {
        let label = interaction.alwaysLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return label.isEmpty ? "Always Allow" : label
    }
}

/// A tool permission request, inline where it arrived. Allow Once is the
/// prominent default; Always Allow appears only when the request offers it.
struct ChatApprovalCard: View {
    let interaction: ChatInteraction
    let store: ChatSessionStore
    let isFirst: Bool
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.dynamicTypeSize) private var typeSize
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    /// Compact width stacks the buttons full width, Allow Once on top.
    private var stacked: Bool {
        #if os(iOS)
        sizeClass != .regular || typeSize.isAccessibilitySize
        #else
        typeSize.isAccessibilitySize
        #endif
    }

    var body: some View {
        let permission = interaction.permission ?? ChatPermission(tool: "")
        let delivery = store.interactionDelivery[interaction.id]
        let busy = delivery == .sending || delivery == .sent
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(ChatInline.attributed(ChatInteractionCopy.approvalTitle(permission, provider: store.provider), role: .reply))
                    .font(.headline)
                    .foregroundStyle(AgentLandColor.text.color)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "hand.raised").foregroundStyle(AgentLandColor.tint.color)
            }
            .accessibilityAddTraits(.isHeader)
            let target = ChatInteractionCopy.approvalTarget(permission)
            if !target.isEmpty { ChatRequestTarget(text: target) }
            if !permission.detail.isEmpty {
                Text(permission.detail)
                    .font(.subheadline)
                    .foregroundStyle(AgentLandColor.textSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            deliveryLine(delivery)
            Group {
                if stacked {
                    VStack(spacing: 8) {
                        allowOnce
                        if interaction.offersAlways { always }
                        deny
                    }
                } else {
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        deny.fixedSize()
                        // A host's scope wording may be long: it wraps.
                        if interaction.offersAlways { always.fixedSize(horizontal: interaction.alwaysLabel?.isEmpty ?? true, vertical: true) }
                        allowOnce.fixedSize()
                    }
                }
            }
            .disabled(busy || !store.reachable)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .chatCard(fill: AgentLandColor.surfaceRaised.color, increasedContrast: contrast == .increased, tint: AgentLandColor.tint.color)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chatApprovalCard")
    }

    private var allowOnce: some View {
        Button { Task { await store.reply(to: interaction, with: .once) } } label: {
            Text("Allow Once").frame(maxWidth: stacked ? .infinity : nil)
        }
        .buttonStyle(ChatCardButtonStyle(prominent: true))
        .keyboardShortcut(isFirst ? KeyboardShortcut(.return, modifiers: [.command, .option]) : nil)
        .accessibilityIdentifier("chatAllowOnce")
    }

    private var always: some View {
        Button { Task { await store.reply(to: interaction, with: .always) } } label: {
            Text(ChatInteractionCopy.alwaysTitle(interaction)).frame(maxWidth: stacked ? .infinity : nil)
        }
        .buttonStyle(ChatCardButtonStyle())
        .accessibilityHint(interaction.alwaysDetail ?? "")
        .accessibilityIdentifier("chatAlwaysAllow")
    }

    /// Denying is the safe choice, so it is not styled as destructive.
    private var deny: some View {
        Button { Task { await store.reply(to: interaction, with: .reject) } } label: {
            Text("Deny").frame(maxWidth: stacked ? .infinity : nil)
        }
        .buttonStyle(ChatCardButtonStyle())
        .keyboardShortcut(isFirst ? KeyboardShortcut(.delete, modifiers: [.command, .option]) : nil)
        .accessibilityIdentifier("chatDeny")
    }

    @ViewBuilder private func deliveryLine(_ delivery: InteractionDelivery?) -> some View {
        switch delivery {
        case .sending, .sent:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(delivery == .sending ? "Sending…" : "Waiting for the agent…")
            }
            .font(.footnote)
            .foregroundStyle(AgentLandColor.textSecondary.color)
        case .notConfirmed:
            ChatUnconfirmedReply(store: store)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.circle")
                .font(.footnote)
                .foregroundStyle(AgentLandColor.danger.color)
        case nil:
            EmptyView()
        }
    }
}

/// The exact command or target of a request, as selectable monospace. It
/// wraps, so no part of what is being approved is out of sight; a very long
/// one scrolls inside a capped box.
struct ChatRequestTarget: View {
    let text: String
    @ScaledMetric(relativeTo: .callout) private var maximumHeight: CGFloat = 180
    @State private var height: CGFloat = 0

    var body: some View {
        ScrollView(.vertical) {
            Text(text)
                .font(.callout.monospaced())
                .foregroundStyle(AgentLandColor.text.color)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, minHeight: ChatMetrics.target, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(max(height, ChatMetrics.target), maximumHeight))
        .background(AgentLandColor.canvas.color, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityIdentifier("chatRequestTarget")
    }
}

/// A reply to a card whose delivery is uncertain: never sent again by itself.
struct ChatUnconfirmedReply: View {
    let store: ChatSessionStore
    var body: some View {
        HStack(spacing: 8) {
            Label("Not confirmed", systemImage: "questionmark.circle")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(AgentLandColor.warning.color)
            Button { store.refreshStatus() } label: {
                Text("Refresh Status").font(.footnote).minimumTapTarget()
            }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("chatRefreshStatus")
        }
    }
}

/// The agent's questions, all in one card. Answers go only with Send Answers.
struct ChatQuestionCard: View {
    let interaction: ChatInteraction
    let store: ChatSessionStore
    /// ⌘↩ sends the answers only while the chat takes input: under the iPhone drawer, a sheet or a question, the
    /// shortcut is theirs (the drawer's Git Commit has ⌘↩ too).
    var shortcutEnabled = true
    @State private var selections: [String: Set<String>] = [:]
    @State private var custom: [String: String] = [:]
    @State private var customOpen: Set<String> = []
    @State private var revealed: Set<String> = []
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let delivery = store.interactionDelivery[interaction.id]
        let busy = delivery == .sending || delivery == .sent
        VStack(alignment: .leading, spacing: 12) {
            Label(interaction.questions.count == 1 ? "\(store.provider.chatDisplayName) asked a question"
                  : "\(store.provider.chatDisplayName) asked \(interaction.questions.count) questions",
                  systemImage: "questionmark.bubble")
                .font(.headline)
                .foregroundStyle(AgentLandColor.text.color)
                .accessibilityAddTraits(.isHeader)
            ForEach(Array(interaction.questions.enumerated()), id: \.element.id) { index, question in
                if index > 0 { Divider().overlay(AgentLandColor.separator.color) }
                questionView(question)
            }
            switch delivery {
            case .notConfirmed: ChatUnconfirmedReply(store: store)
            case let .failed(message):
                Label(message, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(AgentLandColor.danger.color)
            case .sending, .sent:
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Sending…") }
                    .font(.footnote).foregroundStyle(AgentLandColor.textSecondary.color)
            case nil: EmptyView()
            }
            HStack(spacing: 8) {
                Button("Dismiss") { Task { await store.dismiss(interaction) } }
                    .buttonStyle(ChatCardButtonStyle())
                    .accessibilityIdentifier("chatDismissQuestions")
                Spacer(minLength: 0)
                Button("Send Answers") { Task { await store.answer(interaction, answers: answers) } }
                .buttonStyle(ChatCardButtonStyle(prominent: true))
                .disabled(!allAnswered)
                .keyboardShortcut(shortcutEnabled ? KeyboardShortcut(.return, modifiers: .command) : nil)
                .accessibilityIdentifier("chatSendAnswers")
            }
            .disabled(busy || !store.reachable)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .chatCard(fill: AgentLandColor.surfaceRaised.color, increasedContrast: contrast == .increased, tint: AgentLandColor.tint.color)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chatQuestionCard")
    }

    private func questionView(_ question: ChatQuestion) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !question.header.isEmpty {
                Text(question.header).font(.subheadline.weight(.semibold)).foregroundStyle(AgentLandColor.text.color)
            }
            Text(question.text).font(.body).foregroundStyle(AgentLandColor.text.color).fixedSize(horizontal: false, vertical: true)
            ForEach(question.options) { option in
                #if os(iOS)
                // The system's button toggle (CH-12): its own selected tint and selected trait. One choice or
                // several by the binding: choosing a single answer clears the others, and choosing it again keeps it.
                Toggle(isOn: Binding(get: { selections[question.id, default: []].contains(option.label) },
                                     set: { _ in toggle(option.label, in: question) })) {
                    optionText(option)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, minHeight: ChatMetrics.target, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .toggleStyle(.button)
                #else
                let selected = selections[question.id, default: []].contains(option.label)
                Button { toggle(option.label, in: question) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: question.multiple ? (selected ? "checkmark.square.fill" : "square")
                                                           : (selected ? "largecircle.fill.circle" : "circle"))
                            .foregroundStyle(selected ? AgentLandColor.tint.color : AgentLandColor.textSecondary.color)
                        optionText(option)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(minHeight: ChatMetrics.target)
                    .background(selected ? AgentLandColor.surface.color : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
                #endif
            }
            if question.custom || question.options.isEmpty { customAnswer(question) }
        }
    }

    /// An answer and, when it has one, the line that explains it.
    private func optionText(_ option: ChatQuestionOption) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(option.label).font(.body).foregroundStyle(AgentLandColor.text.color)
            if !option.description.isEmpty {
                Text(option.description).font(.footnote).foregroundStyle(AgentLandColor.textSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private func customAnswer(_ question: ChatQuestion) -> some View {
        let open = customOpen.contains(question.id) || question.options.isEmpty
        if !open {
            Button("Something Else…") {
                customOpen.insert(question.id)
                if !question.multiple { selections[question.id] = [] }
            }
            .font(.body)
            .chatBorderlessButton()
            .foregroundStyle(AgentLandColor.tint.color)
            .frame(minHeight: ChatMetrics.target)
        } else {
            let binding = Binding(get: { custom[question.id, default: ""] }, set: { value in
                custom[question.id] = value
                if !question.multiple, !value.isEmpty { selections[question.id] = [] }
            })
            HStack(spacing: 6) {
                if question.secret && !revealed.contains(question.id) {
                    SecureField("Answer", text: binding)
                        .textContentType(.password)
                } else {
                    TextField("Answer", text: binding)
                        .autocorrectionDisabled(question.secret)
                }
                if question.secret {
                    Button {
                        if revealed.contains(question.id) { revealed.remove(question.id) } else { revealed.insert(question.id) }
                    } label: {
                        Image(systemName: revealed.contains(question.id) ? "eye.slash" : "eye")
                            .frame(minWidth: ChatMetrics.target, minHeight: ChatMetrics.target)
                    }
                    .chatBorderlessButton()
                    .accessibilityLabel(revealed.contains(question.id) ? "Hide Answer" : "Show Answer")
                }
            }
            .font(.body)
            .padding(.horizontal, 10)
            .frame(minHeight: ChatMetrics.target)
            .background(AgentLandColor.canvas.color, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityIdentifier(question.secret ? "chatSecretAnswer" : "chatCustomAnswer")
        }
    }

    private func toggle(_ label: String, in question: ChatQuestion) {
        if question.multiple {
            if selections[question.id, default: []].contains(label) { selections[question.id]?.remove(label) }
            else { selections[question.id, default: []].insert(label) }
        } else {
            selections[question.id] = [label]
            custom[question.id] = ""
            customOpen.remove(question.id)
        }
    }

    private var answers: [[String]] {
        interaction.questions.map { question in
            let chosen = question.options.map(\.label).filter { selections[question.id, default: []].contains($0) }
            let typed = custom[question.id, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
            if question.multiple { return typed.isEmpty ? chosen : chosen + [typed] }
            return typed.isEmpty ? Array(chosen.prefix(1)) : [typed]
        }
    }

    private var allAnswered: Bool { answers.allSatisfy { !$0.isEmpty } }
}

/// A glass pill above the composer while a card waits off-screen.
struct ChatNeedsYouPill: View {
    let interaction: ChatInteraction
    let provider: AgentProvider
    let action: () -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let (text, verb) = ChatInteractionCopy.pill(interaction, provider: provider)
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: interaction.kind == .permission ? "hand.raised.fill" : "questionmark.bubble.fill")
                    .foregroundStyle(AgentLandColor.tint.color)
                Text(text).foregroundStyle(AgentLandColor.text.color)
                Text("·").foregroundStyle(AgentLandColor.textSecondary.color).accessibilityHidden(true)
                Text(verb).fontWeight(.semibold).foregroundStyle(AgentLandColor.tint.color)
            }
            .font(.subheadline)
            .lineLimit(1)
            #if os(macOS)
            .padding(.horizontal, 16)
            .frame(minHeight: ChatMetrics.target)
            .contentShape(Capsule())
            #endif
        }
        #if os(iOS)
        // The system's glass button in a capsule: a floating control (CH-14).
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .minimumTapTarget(.reserveSpace)
        #else
        .buttonStyle(.plain)
        .chatFloatingSurface(Capsule(), reduceTransparency: reduceTransparency, increasedContrast: contrast == .increased, interactive: true)
        #endif
        .accessibilityLabel("\(text). \(verb)")
        .accessibilityIdentifier("chatNeedsYouPill")
    }
}
