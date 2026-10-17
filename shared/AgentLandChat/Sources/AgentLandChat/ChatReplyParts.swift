import SwiftUI
import AgentLandBranding
import AgentLandDesign
import AgentLandCore

/// A reply's parts in their real order: text blocks between runs of
/// non-text work. A run of more than one item collapses into a group row,
/// except in a plain chat, where each item stands alone (its tools as cards).
enum ChatReplySegment: Identifiable {
    case text(ChatPartModel)
    case single(ChatPartModel)
    case group([ChatPartModel])
    case notice(ChatPartModel)
    case attachment(ChatPartModel)
    case resolved(ChatResolvedInteraction)

    var id: String {
        switch self {
        case let .text(part), let .single(part), let .notice(part), let .attachment(part): part.id
        case let .group(parts): "group-" + (parts.first?.id ?? "")
        case let .resolved(item): "resolved-" + item.id
        }
    }

    @MainActor static func make(_ parts: [ChatPartModel], resolved: [ChatResolvedInteraction], plain: Bool = false) -> [ChatReplySegment] {
        var result: [ChatReplySegment] = []
        var run: [ChatPartModel] = []
        func closeRun() {
            if run.count == 1 || plain {
                result += run.map { .single($0) }
            } else if run.count > 1 {
                result.append(.group(run))
            }
            run = []
        }
        let ids = Set(parts.map(\.id))
        let anchored = Dictionary(grouping: resolved.filter { $0.afterPartID.map(ids.contains) == true }) { $0.afterPartID ?? "" }
        let leading = resolved.filter { $0.afterPartID.map(ids.contains) != true }
        for part in parts {
            switch part.kind {
            case .reasoning, .tool, .patch: run.append(part)
            case .text: closeRun(); result.append(.text(part))
            case .notice, .context: closeRun(); result.append(.notice(part))
            case .attachment: closeRun(); result.append(.attachment(part))
            case .other: break
            }
            if let lines = anchored[part.id] {
                closeRun()
                result += lines.map { .resolved($0) }
            }
        }
        closeRun()
        result += leading.map { .resolved($0) }
        return result
    }
}

#if os(iOS)
/// The transcript's disclosures on iPhone and iPad (reasoning, tool rows and groups, a continued chat's context;
/// CH-07): the system's `DisclosureGroup`, with its own chevron in the secondary text colour and its own expanded or
/// collapsed state for VoiceOver. The state stays in the store (`isExpanded(_:byDefault:)`), so Settings → Chat's
/// Expand tool details still decides how each starts and a toggle lasts while the chat is open; it animates with the
/// chat's motion, not at all under Reduce Motion. The label is at least a touch target tall, and the identifier set
/// on it goes to the system's button. The Mac keeps its own row buttons: there a disclosure opens only from its
/// triangle.
struct ChatDisclosureGroup<Label: View, Content: View>: View {
    let key: String
    let store: ChatSessionStore
    var byDefault = false
    @ViewBuilder let content: () -> Content
    @ViewBuilder let label: () -> Label
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        DisclosureGroup(isExpanded: Binding(get: { store.isExpanded(key, byDefault: byDefault) }, set: { open in
            guard open != store.isExpanded(key, byDefault: byDefault) else { return }
            withAnimation(AgentLandMotion.smooth.animation(reduceMotion: reduceMotion, reducedMotion: .none)) {
                store.toggleExpanded(key)
            }
        })) {
            content()
        } label: {
            label().frame(maxWidth: .infinity, minHeight: ChatMetrics.target, alignment: .leading)
        }
        .tint(AgentLandColor.textSecondary.color)
    }
}
#endif

/// "Reasoning · 0:07" while live, "Reasoning · 12 s" when done. Collapsed
/// until the person opens it; never opens by itself.
struct ChatReasoningRow: View {
    let part: ChatPartModel
    let live: Bool
    let store: ChatSessionStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.chatExpandsDetails) private var expandsByDefault

    private var expanded: Bool { store.isExpanded(part.id, byDefault: expandsByDefault) }
    private var redacted: Bool { part.text.isEmpty && !live }

    var body: some View {
        #if os(iOS)
        if redacted {
            // Nothing to open: the line alone.
            header.frame(maxWidth: .infinity, minHeight: ChatMetrics.target, alignment: .leading)
        } else {
            ChatDisclosureGroup(key: part.id, store: store, byDefault: expandsByDefault) {
                details
            } label: {
                header
            }
        }
        #else
        VStack(alignment: .leading, spacing: 8) {
            Button {
                guard !redacted else { return }
                withAnimation(AgentLandMotion.smooth.animation(reduceMotion: reduceMotion, reducedMotion: .none)) {
                    store.toggleExpanded(part.id)
                }
            } label: {
                HStack(spacing: 8) {
                    if live {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "brain").foregroundStyle(AgentLandColor.textSecondary.color)
                    }
                    title
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(AgentLandColor.textSecondary.color)
                    if !redacted {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AgentLandColor.textSecondary.color)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .accessibilityHidden(true)
                    }
                    Spacer(minLength: 0)
                }
                .frame(minHeight: ChatMetrics.target)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(live ? "Running" : (redacted ? "" : (expanded ? "Expanded" : "Collapsed")))
            .accessibilityIdentifier("chatReasoning")
            if expanded && !redacted { details }
        }
        #endif
    }

    #if os(iOS)
    /// The symbol and the title as one element; the disclosure speaks whether it is open.
    private var header: some View {
        HStack(spacing: 8) {
            if live {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "brain").foregroundStyle(AgentLandColor.textSecondary.color)
            }
            title
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AgentLandColor.textSecondary.color)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(live ? Text("\(title), Running") : title)
        .accessibilityIdentifier("chatReasoning")
    }
    #endif

    private var details: some View {
        ChatMarkdownBlocks(blocks: part.markdownBlocks, role: .supporting)
            .padding(.leading, 12)
            .overlay(alignment: .leading) { AgentLandColor.separator.color.frame(width: 2) }
    }

    private var title: Text {
        if live, let started = ChatTime.date(part.start) {
            // A timer text counts up by itself, without redrawing the row.
            Text("Reasoning · \(Text(timerInterval: started...Date.distantFuture, countsDown: false))")
        } else if live {
            Text("Reasoning")
        } else if let seconds = ChatDurations.seconds(start: part.start, end: part.end, legacyMilliseconds: part.durationMs) {
            Text("Reasoning · \(ChatDurations.finished(seconds))")
        } else {
            Text("Reasoning")
        }
    }
}

/// One humanized tool call: the kind's symbol, a verb phrase and the target,
/// with its state as a symbol and words. Opens to show input and output.
struct ChatToolRow: View {
    let part: ChatPartModel
    let interrupted: Bool
    let store: ChatSessionStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.chatExpandsDetails) private var expandsByDefault

    private var expanded: Bool { store.isExpanded(part.id, byDefault: expandsByDefault) }

    var body: some View {
        let tool = part.tool ?? ConversationTool(name: "tool", status: .running)
        let summary = ChatToolSummary(tool, interrupted: interrupted)
        #if os(iOS)
        ChatDisclosureGroup(key: part.id, store: store, byDefault: expandsByDefault) {
            ChatToolDetails(tool: tool, kind: summary.kind)
                .padding(.bottom, 10)
        } label: {
            summaryLine(summary, tool: tool)
                .padding(.vertical, 2)
                // One element with the row's words; the system's disclosure button takes its label and
                // identifier, and says itself whether the row is open.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(ChatInline.plain(summary.phrase)), \(summary.state.label)")
                .accessibilityIdentifier("chatToolRow")
        }
        .padding(.horizontal, 12)
        .chatCard(cornerRadius: 12, increasedContrast: contrast == .increased)
        #else
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(AgentLandMotion.smooth.animation(reduceMotion: reduceMotion, reducedMotion: .none)) {
                    store.toggleExpanded(part.id)
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    summaryLine(summary, tool: tool)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AgentLandColor.textSecondary.color)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(minHeight: ChatMetrics.target)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Label, value and identifier go on the button itself: wrapping it
            // in a new element gave that element the whole reply's frame, so
            // activating it landed on the reply text instead of the row.
            .accessibilityLabel("\(ChatInline.plain(summary.phrase)), \(summary.state.label)")
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .accessibilityIdentifier("chatToolRow")
            if expanded {
                ChatToolDetails(tool: tool, kind: summary.kind)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }
        }
        .chatCard(cornerRadius: 12, increasedContrast: contrast == .increased)
        #endif
    }

    /// The kind's symbol (or the state's), the verb phrase and, when it says more, the state in words.
    private func summaryLine(_ summary: ChatToolSummary, tool: ConversationTool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            ChatToolStateIcon(state: summary.state, kind: summary.kind)
            VStack(alignment: .leading, spacing: 2) {
                Text(ChatInline.attributed(summary.phrase, role: .supporting))
                    .font(.subheadline)
                    .foregroundStyle(AgentLandColor.text.color)
                    // The target is already one short line; the phrase wraps rather than cuts.
                    .fixedSize(horizontal: false, vertical: true)
                stateCaption(summary, tool: tool)
            }
        }
    }

    @ViewBuilder private func stateCaption(_ summary: ChatToolSummary, tool: ConversationTool) -> some View {
        switch summary.state {
        case .running where summary.kind == .command:
            if let started = ChatTime.date(part.start) {
                Text("Running · \(Text(timerInterval: started...Date.distantFuture, countsDown: false))")
                .font(.caption)
                .foregroundStyle(AgentLandColor.textSecondary.color)
            }
        case .failed, .denied, .interrupted, .waitingForApproval, .waitingForAnswer:
            Text(summary.state.label)
                .font(.caption.weight(.medium))
                .foregroundStyle(summary.state == .failed || summary.state == .denied ? AgentLandColor.danger.color : AgentLandColor.textSecondary.color)
        default:
            EmptyView()
        }
    }
}

/// Symbol plus shape for a tool's state; a spinner while it works.
struct ChatToolStateIcon: View {
    let state: ChatToolState
    let kind: ChatToolKind

    var body: some View {
        Group {
            if state.isActive {
                ProgressView().controlSize(.small)
            } else if let symbol = state.symbol, state != .succeeded {
                Image(systemName: symbol)
                    .foregroundStyle(state == .failed || state == .denied ? AgentLandColor.danger.color : AgentLandColor.textSecondary.color)
            } else {
                Image(systemName: kind.symbol).foregroundStyle(AgentLandColor.textSecondary.color)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption2)
                            #if os(iOS)
                            // The system's success badge: a white check on green (CH-22).
                            .foregroundStyle(.white, AgentLandColor.success.color)
                            #else
                            .foregroundStyle(AgentLandColor.success.color, AgentLandColor.canvas.color)
                            #endif
                            .offset(x: 5, y: 4)
                    }
            }
        }
        .font(.subheadline)
        .frame(minWidth: 20)
        .accessibilityHidden(true)
    }
}

/// A tool's input and output, each with Copy. Output shows its first 30
/// lines until the person asks for more.
struct ChatToolDetails: View {
    let tool: ConversationTool
    let kind: ChatToolKind
    @State private var showAllOutput = false
    private static let outputLines = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !tool.input.isEmpty { section("Input", text: inputText, copy: tool.input) }
            if !tool.output.isEmpty { outputSection }
            if !tool.error.isEmpty { section("Error", text: tool.error, copy: tool.error, danger: true) }
            if tool.truncated {
                Text("The host shortened this output.")
                    .font(.caption)
                    .foregroundStyle(AgentLandColor.textSecondary.color)
            }
        }
    }

    /// A command reads as the command; other arguments as key: value lines.
    private var inputText: String {
        guard let data = tool.input.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return tool.input }
        if kind == .command, let command = object["command"] as? String { return command }
        return object.keys.sorted().map { key in
            let value = object[key]
            if let text = value as? String { return "\(key): \(text)" }
            if let value, JSONSerialization.isValidJSONObject(value),
               let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]),
               let text = String(data: data, encoding: .utf8) { return "\(key): \(text)" }
            return "\(key): \(value.map { "\($0)" } ?? "null")"
        }.joined(separator: "\n")
    }

    private var outputSection: some View {
        let lines = tool.output.split(separator: "\n", omittingEmptySubsequences: false)
        let hidden = max(0, lines.count - Self.outputLines)
        let shown = showAllOutput || hidden == 0 ? tool.output : lines.prefix(Self.outputLines).joined(separator: "\n")
        return VStack(alignment: .leading, spacing: 4) {
            section("Output", text: shown, copy: tool.output)
            if hidden > 0 {
                Button(showAllOutput ? "Show Fewer Lines" : "Show \(hidden) More Lines") { showAllOutput.toggle() }
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(AgentLandColor.tint.color)
                    .chatBorderlessButton()
                    .frame(minHeight: ChatMetrics.target)
            }
        }
    }

    private func section(_ title: String, text: String, copy: String, danger: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(AgentLandColor.textSecondary.color)
                Spacer()
                ChatCopyButton(copy, label: "Copy \(title)", iconOnly: true)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                // Copy in the section header is the way to take it: selectable
                // text this small would be a touch target under 44 pt.
                Text(text)
                    .font(.footnote.monospaced())
                    .foregroundStyle(danger ? AgentLandColor.danger.color : AgentLandColor.text.color)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(8)
            }
            .background(AgentLandColor.canvas.color, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}

/// A run of tool calls and reasoning: live, the current step and a count;
/// done, a summary by kind.
struct ChatToolGroup: View {
    let parts: [ChatPartModel]
    let live: Bool
    let interrupted: Bool
    let store: ChatSessionStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    @Environment(\.chatExpandsDetails) private var expandsByDefault

    private var key: String { "group-" + (parts.first?.id ?? "") }
    private var expanded: Bool { store.isExpanded(key, byDefault: expandsByDefault) }

    var body: some View {
        let summaries = parts.compactMap { part in part.tool.map { ChatToolSummary($0, interrupted: interrupted) } }
        let reasoning = parts.filter { $0.kind == .reasoning }.count
        let patches = parts.filter { $0.kind == .patch }
        let active = summaries.last { $0.state.isActive }
        let failed = summaries.contains { $0.state == .failed || $0.state == .denied }
        let spinning = live && (active != nil || reasoning > 0 && summaries.allSatisfy { !$0.state.isActive } && live)
        let text = headline(summaries: summaries, reasoning: reasoning, patches: patches.count, active: active)
        VStack(alignment: .leading, spacing: 6) {
            #if os(iOS)
            // The card is the disclosure's header alone: the steps follow under it, as before.
            ChatDisclosureGroup(key: key, store: store, byDefault: expandsByDefault) {
                EmptyView()
            } label: {
                headerLine(text, spinning: spinning, failed: failed)
                    .padding(.vertical, 2)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(ChatInline.plain(text) + (live ? ", Running" : (failed ? ", Failed" : "")))
                    .accessibilityIdentifier("chatToolGroup")
            }
            .padding(.horizontal, 12)
            .chatCard(cornerRadius: 12, increasedContrast: contrast == .increased)
            #else
            Button {
                withAnimation(AgentLandMotion.smooth.animation(reduceMotion: reduceMotion, reducedMotion: .none)) {
                    store.toggleExpanded(key)
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    headerLine(text, spinning: spinning, failed: failed)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AgentLandColor.textSecondary.color)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(minHeight: ChatMetrics.target)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .chatCard(cornerRadius: 12, increasedContrast: contrast == .increased)
            .accessibilityValue(live ? "Running" : (failed ? "Failed, \(expanded ? "Expanded" : "Collapsed")" : (expanded ? "Expanded" : "Collapsed")))
            .accessibilityIdentifier("chatToolGroup")
            #endif
            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(parts) { part in
                        ChatWorkItem(part: part, live: live && part.id == parts.last?.id, interrupted: interrupted, store: store)
                    }
                }
                .padding(.leading, 12)
            }
        }
    }

    /// A spinner while it works, else whether every step went through; then the headline.
    private func headerLine(_ text: String, spinning: Bool, failed: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Group {
                if spinning {
                    ProgressView().controlSize(.small)
                } else if failed {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(AgentLandColor.danger.color)
                } else {
                    Image(systemName: "checkmark.circle").foregroundStyle(AgentLandColor.success.color)
                }
            }
            .font(.subheadline)
            .frame(minWidth: 20)
            .accessibilityHidden(true)
            Text(ChatInline.attributed(text, role: .supporting))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AgentLandColor.text.color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func headline(summaries: [ChatToolSummary], reasoning: Int, patches: Int, active: ChatToolSummary?) -> String {
        if live, let active {
            let step = (summaries.firstIndex(of: active) ?? summaries.count - 1) + 1
            return "\(active.phrase) · Step \(step) of \(summaries.count)"
        }
        if live, reasoning > 0 { return "Reasoning…" }
        var summary = ChatToolSummary.groupSummary(summaries, reasoning: reasoning)
        if patches > 0 { summary += (summary.isEmpty ? "" : " · ") + (patches == 1 ? "Changed files" : "Changed files \(patches) times") }
        return summary.isEmpty ? "Worked" : summary
    }
}

/// One non-text item: reasoning, a tool call or a changed-files list.
struct ChatWorkItem: View {
    let part: ChatPartModel
    let live: Bool
    let interrupted: Bool
    let store: ChatSessionStore

    var body: some View {
        switch part.kind {
        case .reasoning:
            ChatReasoningRow(part: part, live: live && part.end == nil, store: store)
        case .tool:
            ChatToolRow(part: part, interrupted: interrupted, store: store)
        case .patch:
            ChatPatchRow(part: part)
        default:
            EmptyView()
        }
    }
}

/// Files the agent changed, one per line.
struct ChatPatchRow: View {
    let part: ChatPartModel
    var body: some View {
        let files = part.text.split(separator: "\n").map(String.init)
        VStack(alignment: .leading, spacing: 2) {
            Label(files.count == 1 ? "Changed 1 file" : "Changed \(files.count) files", systemImage: "doc.badge.gearshape")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AgentLandColor.text.color)
            ForEach(files.prefix(12), id: \.self) { file in
                Text(file).font(.footnote.monospaced()).foregroundStyle(AgentLandColor.textSecondary.color).lineLimit(1).truncationMode(.middle)
            }
            if files.count > 12 {
                Text("and \(files.count - 12) more").font(.footnote).foregroundStyle(AgentLandColor.textSecondary.color)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// Retries, compaction and other notices from the provider.
struct ChatNoticeRow: View {
    let part: ChatPartModel
    var body: some View {
        Label(part.text, systemImage: part.kind == .context ? "text.quote" : "info.circle")
            .font(.footnote)
            .foregroundStyle(AgentLandColor.textSecondary.color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// An approval's or question's outcome, kept in the tool timeline.
struct ChatResolvedLine: View {
    let item: ChatResolvedInteraction
    let at: Date?

    var body: some View {
        let (symbol, text) = describe()
        HStack(spacing: 6) {
            Image(systemName: symbol)
            Text(at.map { "\(text) · \(ChatTimeFormat.clock($0))" } ?? text)
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(AgentLandColor.textSecondary.color)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("chatResolvedInteraction")
    }

    private func describe() -> (String, String) {
        if item.interaction.kind == .permission {
            switch item.outcome {
            case "once": return ("checkmark.shield", "Allowed once")
            case "always": return ("checkmark.shield.fill", "Always allowed")
            case "reject": return ("nosign", "Denied")
            default: return ("clock.badge.xmark", "Request closed")
            }
        }
        let count = item.interaction.questions.count
        switch item.outcome {
        case "answered": return ("checkmark.bubble", count == 1 ? "Answered 1 question" : "Answered \(count) questions")
        case "rejected": return ("xmark.bubble", count == 1 ? "Question dismissed" : "Questions dismissed")
        default: return ("clock.badge.xmark", count == 1 ? "Question closed" : "Questions closed")
        }
    }
}

/// Before the first output: "Starting Claude Code…", then "Waiting for
/// Claude Code…" after 3 s, or the provider's own retry countdown.
struct ChatStatusLine: View {
    let store: ChatSessionStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(text(at: context.date))
                    .font(.subheadline)
                    .foregroundStyle(AgentLandColor.textSecondary.color)
            }
            .frame(minHeight: ChatMetrics.target, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("chatStatusLine")
        }
    }

    private func text(at now: Date) -> String {
        let name = store.provider.chatDisplayName
        if store.runState == .retry {
            let message = store.retry?.message.isEmpty == false ? store.retry!.message : "The provider is retrying"
            if let next = ChatTime.date(store.retry?.nextAt) {
                let seconds = max(0, Int(next.timeIntervalSince(now).rounded()))
                let lowered = message.lowercased()
                let label = lowered.contains("rate") || lowered.contains("429") ? "Rate limited" : "Retrying"
                return "\(label) · retrying in \(seconds) s"
            }
            return message
        }
        guard let started = store.turnStartedAt else { return "Starting \(name)…" }
        return now.timeIntervalSince(started) < 3 ? "Starting \(name)…" : "Waiting for \(name)…"
    }
}

/// A failed reply: what went wrong, in the provider's own bounded words, and
/// an explicit Run Again. Nothing runs by itself.
struct ChatErrorCard: View {
    let error: ConversationError
    let provider: AgentProvider
    let didToolWork: Bool
    let canRunAgain: Bool
    let runAgain: () -> Void
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let copy = ChatErrorCopy.category(error, provider: provider)
        VStack(alignment: .leading, spacing: 8) {
            Label(copy.title, systemImage: "exclamationmark.triangle")
                .font(.headline)
                .foregroundStyle(AgentLandColor.text.color)
            if !error.message.isEmpty {
                Text(error.message)
                    .font(.subheadline)
                    .foregroundStyle(AgentLandColor.text.color)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let guidance = copy.guidance {
                Text(guidance).font(.footnote).foregroundStyle(AgentLandColor.textSecondary.color)
            }
            if canRunAgain {
                if didToolWork {
                    Text("The agent may already have changed files.")
                        .font(.footnote)
                        .foregroundStyle(AgentLandColor.textSecondary.color)
                }
                Button(action: runAgain) {
                    Label("Run Again", systemImage: "arrow.clockwise").minimumTapTarget()
                }
                    .buttonStyle(.bordered)
                    .frame(minHeight: ChatMetrics.target)
                    .accessibilityIdentifier("chatRunAgainError")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .chatCard(fill: AgentLandColor.warning.color.opacity(0.08), increasedContrast: contrast == .increased, tint: AgentLandColor.warning.color)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chatErrorCard")
    }
}

/// The action row of a finished reply: Copy · Run Again · Details.
struct ChatReplyActionRow: View {
    let reply: ChatReplyModel
    let store: ChatSessionStore
    let runAgain: () -> Void
    @State private var showsDetails = false

    var body: some View {
        HStack(spacing: 0) {
            ChatCopyButton(reply.plainText, label: "Copy Reply", identifier: "chatCopyReply", iconOnly: true)
            if reply.isLatest && store.canRunAgain {
                Button(action: runAgain) {
                    Label("Run Again", systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: ChatMetrics.target, minHeight: ChatMetrics.target)
                        .contentShape(Rectangle())
                }
                .chatBorderlessButton()
                .help("Run Again")
                // ⌘R reloads the surface; regenerating is ⇧⌘R, as in the workspace's commands.
                .chatCommandShortcut("r", modifiers: [.command, .shift])
                .accessibilityIdentifier("chatRunAgain")
            }
            Button { showsDetails = true } label: {
                Label("Details", systemImage: "info.circle")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: ChatMetrics.target, minHeight: ChatMetrics.target)
                    .contentShape(Rectangle())
            }
            .chatBorderlessButton()
            .help("Details")
            .accessibilityIdentifier("chatReplyDetails")
            .popover(isPresented: $showsDetails) {
                ChatReplyDetails(reply: reply, store: store)
                    .presentationCompactAdaptation(.popover)
                    .agentLandSheetPage()
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
}

/// Provider, model, times and usage for one reply.
struct ChatReplyDetails: View {
    let reply: ChatReplyModel
    let store: ChatSessionStore

    var body: some View {
        let first = reply.messages.first
        let last = reply.messages.last
        let usage = reply.messages.compactMap(\.usage).reduce(into: ConversationUsage()) { total, next in
            total.input += next.input; total.output += next.output; total.reasoning += next.reasoning
            if let cost = next.costMicros { total.costMicros = (total.costMicros ?? 0) + cost }
        }
        // Native label-and-value rows (CH-23): the name in the primary color, its value after it in the secondary.
        VStack(alignment: .leading, spacing: 8) {
            row("Provider", store.provider.chatDisplayName)
            if let model = reply.model { row("Model", model) }
            if let mode = store.info?.mode { row("Mode", mode) }
            if let effort = store.info?.effort { row("Effort", effort) }
            if let start = ChatTime.date(first?.createdAt) { row("Started", start.formatted(date: .abbreviated, time: .standard)) }
            if let end = ChatTime.date(last?.completedAt) {
                row("Finished", end.formatted(date: .omitted, time: .standard))
                if let start = ChatTime.date(first?.createdAt) { row("Duration", ChatDurations.finished(end.timeIntervalSince(start))) }
            }
            if usage.input > 0 || usage.output > 0 {
                row("Input tokens", usage.input.formatted())
                row("Output tokens", usage.output.formatted())
            }
            if let cost = usage.costMicros, cost > 0 {
                row("Cost", (Double(cost) / 1_000_000).formatted(.currency(code: "USD")))
            }
        }
        .font(.subheadline)
        .padding()
        .frame(minWidth: 240)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chatReplyDetailsPopover")
    }

    private func row(_ title: String, _ value: String) -> some View {
        LabeledContent {
            Text(value).foregroundStyle(AgentLandColor.textSecondary.color).textSelection(.enabled)
        } label: {
            Text(title).foregroundStyle(AgentLandColor.text.color)
        }
    }
}
