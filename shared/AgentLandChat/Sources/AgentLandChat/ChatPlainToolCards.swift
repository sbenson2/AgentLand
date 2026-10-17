import SwiftUI
import AgentLandBranding
import AgentLandDesign
import AgentLandCore

/// What a plain chat's tool part does, from the tool's name (docs/HOST-API.md "Plain chats"): OpenCode's web
/// search, the host's `agentland_fetch`, which reads one public page, and its memory tools. OpenCode's `invalid`
/// reports a call it could not make; any other tool keeps its own name.
public enum ChatPlainToolKind: Equatable, Sendable {
    case webSearch, readPage, memorySave, memoryForget, invalid, other

    public init(toolName: String) {
        // The host's tools can arrive as "server/tool" or "mcp__server__tool" too.
        let name = toolName.lowercased()
            .replacingOccurrences(of: "__", with: "_")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "-", with: "_")
        if name == "websearch" || name == "web_search" {
            self = .webSearch
        } else if name.hasSuffix("agentland_fetch") {
            self = .readPage
        } else if name.hasSuffix("agentland_memory_save") {
            self = .memorySave
        } else if name.hasSuffix("agentland_memory_forget") {
            self = .memoryForget
        } else if name == "invalid" {
            self = .invalid
        } else {
            self = .other
        }
    }

    var symbol: String {
        switch self {
        case .webSearch: "magnifyingglass"
        case .readPage: "globe"
        case .memorySave, .memoryForget: "brain.head.profile"
        case .invalid, .other: "wrench.and.screwdriver"
        }
    }
}

/// A plain chat's tool part as its card says it: a headline ("Searched the web", "Read example.com", "Memory
/// updated"), a line of detail (what was searched for, what was remembered), what went wrong, the pages the tool
/// found or read, and the memory entry a save stored.
public struct ChatPlainToolSummary: Equatable, Sendable {
    public let kind: ChatPlainToolKind
    public let state: ChatToolState
    public let headline: String
    public let detail: String?
    /// What went wrong, in the host's words.
    public let problem: String?
    /// The pages, in the tool's order: the results of a search, or the page read.
    public let sources: [ChatToolSource]
    /// The entry a completed memory save stored, which Undo removes. A forget's removed entry is its detail,
    /// never this: there is nothing to undo.
    public let memory: ChatToolMemory?

    /// The longest query or problem a card shows, in characters.
    static let maximumLine = 300

    public init(_ tool: ConversationTool, interrupted: Bool = false) {
        let kind = ChatPlainToolKind(toolName: tool.name)
        let state = ChatToolSummary(tool, interrupted: interrupted).state
        let failed = state == .failed || state == .denied
        let stopped = state == .interrupted
        let done = state == .succeeded
        self.kind = kind
        self.state = state
        sources = tool.sources
        memory = kind == .memorySave && done ? tool.memory : nil
        problem = failed || kind == .invalid ? Self.problem(tool) : nil
        switch kind {
        case .webSearch:
            headline = done ? "Searched the web" : failed ? "Couldn’t search the web" : stopped ? "Web search stopped" : "Searching the web…"
            detail = Self.argument(tool, keys: ["query", "q"]).map { "“\($0)”" }
        case .readPage:
            let site = Self.site(tool)
            headline = done ? "Read \(site)" : failed ? "Couldn’t read \(site)" : stopped ? "Stopped reading \(site)" : "Reading \(site)…"
            detail = nil
        case .memorySave:
            headline = done ? "Memory updated" : failed || stopped ? "Memory not updated" : "Updating memory…"
            detail = tool.memory.map(\.text) ?? Self.argument(tool, keys: ["text", "memory", "fact"])
        case .memoryForget:
            // The entry the forget removed, as the host kept it; nothing to undo.
            headline = done ? "Removed from memory" : failed || stopped ? "Memory not updated" : "Updating memory…"
            detail = tool.memory.map(\.text) ?? Self.line(tool.title)
        case .invalid:
            headline = "Couldn’t use a tool"
            detail = nil
        case .other:
            let name = tool.name
            headline = done ? "Used \(name)" : failed ? "\(name) failed" : stopped ? "\(name) stopped" : "Using \(name)…"
            detail = nil
        }
    }

    /// The card shows a problem rather than a result.
    public var isProblem: Bool { state == .failed || state == .denied || kind == .invalid }

    /// What VoiceOver reads for the card's summary, which is one element: "Searched the web, “tide times lisbon”,
    /// 2 sources". The pages are links of their own under it.
    public var accessibilityLabel: String {
        var parts = [headline]
        if let detail { parts.append(detail) }
        if let problem { parts.append(problem) }
        switch sources.count {
        case 0: break
        case 1: parts.append("1 source")
        default: parts.append("\(sources.count) sources")
        }
        return parts.joined(separator: ", ")
    }

    /// The site a page is on: after redirects once read, else the address asked for; "www." left out.
    static func site(_ tool: ConversationTool) -> String {
        let address = tool.sources.first?.url ?? argument(tool, keys: ["url", "address"], clean: false).flatMap { URL(string: $0) }
        guard var host = address?.host(percentEncoded: false), !host.isEmpty else { return "a web page" }
        if host.lowercased().hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    /// The first of `keys` that the tool's input (its JSON object) has as a string, on one line; else the part's
    /// title. With `clean` false, the value as sent (an address), and no title.
    static func argument(_ tool: ConversationTool, keys: [String], clean: Bool = true) -> String? {
        let object = (try? JSONSerialization.jsonObject(with: Data(tool.input.utf8))) as? [String: Any]
        for key in keys {
            guard let value = object?[key] as? String else { continue }
            let found = clean ? line(value) : value.trimmingCharacters(in: .whitespacesAndNewlines)
            if let found, !found.isEmpty { return found }
        }
        return clean ? line(tool.title) : nil
    }

    /// The host's error, else the first line of what the tool said (`invalid` says there what it could not do).
    static func problem(_ tool: ConversationTool) -> String? {
        if let error = line(tool.error) { return error }
        return tool.output.split(whereSeparator: \.isNewline).lazy.compactMap { line(String($0)) }.first
    }

    /// `text` on one line, each run of white space one space, ends trimmed, cut to `maximumLine` characters; nil
    /// when nothing is left.
    static func line(_ text: String) -> String? {
        let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        guard !words.isEmpty else { return nil }
        let joined = words.joined(separator: " ")
        return joined.count > maximumLine ? String(joined.prefix(maximumLine - 1)) + "…" : joined
    }
}

/// A plain chat's tool as a card: its symbol (a spinner while it works), the headline and its detail, what went
/// wrong, then the pages as links, and under a memory save its Undo. The summary is one element; each page is a link
/// and Undo a button of their own, so VoiceOver, Voice Control, Switch Control and Full Keyboard Access reach them.
struct ChatPlainToolCard: View {
    let part: ChatPartModel
    let interrupted: Bool
    let store: ChatSessionStore
    @Environment(\.colorSchemeContrast) private var contrast

    /// Pages a card lists before Show All.
    static let shownSources = 5

    var body: some View {
        let tool = part.tool ?? ConversationTool(name: "tool", status: .running)
        let summary = ChatPlainToolSummary(tool, interrupted: interrupted)
        VStack(alignment: .leading, spacing: 4) {
            header(summary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(summary.accessibilityLabel)
                .accessibilityValue(undoValue(summary.memory))
                .accessibilityIdentifier(Self.identifier(summary.kind))
            if !summary.sources.isEmpty {
                sourceLinks(summary.sources)
            }
            if let memory = summary.memory {
                undoRow(memory)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .chatCard(cornerRadius: 12, increasedContrast: contrast == .increased)
    }

    static func identifier(_ kind: ChatPlainToolKind) -> String {
        switch kind {
        case .webSearch: "chatWebSearchCard"
        case .readPage: "chatReadPageCard"
        case .memorySave, .memoryForget: "chatMemoryCard"
        case .invalid, .other: "chatToolCard"
        }
    }

    // MARK: Parts

    private func header(_ summary: ChatPlainToolSummary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            icon(summary)
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.headline)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AgentLandColor.text.color)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = summary.detail {
                    // What was remembered is the card's content; a query is its caption.
                    Text(detail)
                        .font(summary.kind == .memorySave ? .subheadline : .footnote)
                        .foregroundStyle(summary.kind == .memorySave ? AgentLandColor.text.color : AgentLandColor.textSecondary.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let problem = summary.problem {
                    Text(problem)
                        .font(.footnote)
                        .foregroundStyle(AgentLandColor.danger.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .frame(minHeight: ChatMetrics.target, alignment: .leading)
    }

    private func icon(_ summary: ChatPlainToolSummary) -> some View {
        Group {
            if summary.state.isActive {
                ProgressView().controlSize(.small)
            } else if summary.isProblem {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(AgentLandColor.danger.color)
            } else {
                Image(systemName: summary.kind.symbol).foregroundStyle(AgentLandColor.textSecondary.color)
            }
        }
        .font(.subheadline)
        .frame(minWidth: 20)
        .accessibilityHidden(true)
    }

    private var sourcesKey: String { "sources-" + part.id }

    /// The pages as links: the title in the tint, the site under it. A long list shows its first few until Show All.
    private func sourceLinks(_ sources: [ChatToolSource]) -> some View {
        let all = store.expandedParts.contains(sourcesKey)
        let shown = all ? sources : Array(sources.prefix(Self.shownSources))
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(shown, id: \.url) { source in
                let site = Self.site(source.url)
                Link(destination: source.url) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(source.title)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(AgentLandColor.tint.color)
                            .lineLimit(2)
                        // A page without a title is named by its site already.
                        if site != source.title {
                            Text(site)
                                .font(.caption)
                                .foregroundStyle(AgentLandColor.textSecondary.color)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: ChatMetrics.target, alignment: .leading)
                    .contentShape(Rectangle())
                }
                #if os(macOS)
                .buttonStyle(.plain)
                #endif
                // The system's link (CH-21), with Share and Copy Link on a long press.
                .contextMenu {
                    ShareLink(item: source.url)
                    Button("Copy Link", systemImage: "doc.on.doc") { ChatClipboard.copy(source.url.absoluteString) }
                }
                .help(source.url.absoluteString)
                .accessibilityLabel(source.title)
                .accessibilityValue(site == source.title ? "" : site)
                .accessibilityIdentifier("chatToolSource")
            }
            if sources.count > Self.shownSources {
                Button(all ? "Show Fewer" : "Show All \(sources.count)") {
                    if all { store.expandedParts.remove(sourcesKey) } else { store.expandedParts.insert(sourcesKey) }
                }
                .font(.footnote.weight(.medium))
                .foregroundStyle(AgentLandColor.tint.color)
                .chatBorderlessButton()
                .frame(minHeight: ChatMetrics.target)
                .accessibilityIdentifier("chatToolSourcesMore")
            }
        }
        .padding(.leading, 28)
    }

    static func site(_ url: URL) -> String {
        guard var host = url.host(percentEncoded: false), !host.isEmpty else { return url.absoluteString }
        if host.lowercased().hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    /// Undo under a memory save, and how it went. The state is the summary's value, so only the buttons are elements
    /// of their own here.
    @ViewBuilder private func undoRow(_ memory: ChatToolMemory) -> some View {
        let state = store.memoryUndo[memory.id]
        if state != nil || store.offersMemoryUndo {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                switch state {
                case .undoing?:
                    progress("Undoing…")
                case .checking?:
                    progress("Checking…")
                case .undone?:
                    Label("Removed from memory", systemImage: "checkmark")
                        .font(.footnote)
                        .foregroundStyle(AgentLandColor.textSecondary.color)
                        .frame(minHeight: ChatMetrics.target)
                        .accessibilityHidden(true)
                case .notConfirmed?:
                    Text("Undo not confirmed")
                        .font(.footnote)
                        .foregroundStyle(AgentLandColor.warning.color)
                        .accessibilityHidden(true)
                    button("Check", hint: "Reads your memory to see whether it was removed", identifier: "chatMemoryUndoCheck") {
                        await store.checkMemoryUndo(memory)
                    }
                case let .failed(reason)?:
                    Text("Couldn’t undo: \(reason)")
                        .font(.footnote)
                        .foregroundStyle(AgentLandColor.danger.color)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityHidden(true)
                    if store.offersMemoryUndo { undoButton(memory) }
                case nil:
                    undoButton(memory)
                }
            }
            .padding(.leading, 28)
        }
    }

    private func undoButton(_ memory: ChatToolMemory) -> some View {
        button("Undo", hint: "Removes “\(memory.text)” from memory", identifier: "chatMemoryUndo") { await store.undoMemory(memory) }
    }

    private func progress(_ text: String) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(text).font(.footnote).foregroundStyle(AgentLandColor.textSecondary.color)
        }
        .frame(minHeight: ChatMetrics.target)
        .accessibilityHidden(true)
    }

    private func button(_ title: String, hint: String, identifier: String, action: @escaping @MainActor () async -> Void) -> some View {
        Button { Task { await action() } } label: {
            Text(title).font(.footnote.weight(.medium)).minimumTapTarget()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .frame(minHeight: ChatMetrics.target)
        .accessibilityHint(hint)
        .accessibilityIdentifier(identifier)
    }

    // MARK: VoiceOver

    /// The undo's state in words, as the summary's value.
    private func undoValue(_ memory: ChatToolMemory?) -> String {
        guard let memory else { return "" }
        switch store.memoryUndo[memory.id] {
        case .undoing?: return "Undoing"
        case .checking?: return "Checking"
        case .undone?: return "Removed from memory"
        case .notConfirmed?: return "Undo not confirmed"
        case let .failed(reason)?: return "Couldn’t undo: \(reason)"
        case nil: return ""
        }
    }
}
