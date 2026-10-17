import Foundation
import Observation
import SwiftUI
import AgentLandChat
import AgentLandCore
import AgentLandDesign

/// What archive screens can ask the app to do.
public struct ArchiveActions {
    /// Opens the chat in a chat tab. Return false when the host no longer has
    /// it as a live chat; the archive then shows its read-only copy.
    public var openChat: (@MainActor (ArchivedChat) -> Bool)?
    public var showArchivedChat: (@MainActor (String) -> Void)?
    public var openTerminalLog: (@MainActor (ArchivedTerminalLog) -> Void)?
    /// A chat the host continued, or a prefilled draft for a new chat.
    public var continued: (@MainActor (ContinueResult) -> Void)?

    public init(openChat: (@MainActor (ArchivedChat) -> Bool)? = nil, continued: (@MainActor (ContinueResult) -> Void)? = nil,
                showArchivedChat: (@MainActor (String) -> Void)? = nil, openTerminalLog: (@MainActor (ArchivedTerminalLog) -> Void)? = nil) {
        self.openChat = openChat
        self.continued = continued
        self.showArchivedChat = showArchivedChat
        self.openTerminalLog = openTerminalLog
    }
}

/// What the archive screens need from the app, passed whenever it changes.
public struct ArchiveEnvironment {
    public var client: APIClient?
    public var capabilities: CapabilitiesResponse?
    public var reachable: Bool
    /// The Mac's name, for labels such as "Searched on Studio Mac".
    public var hostName: String
    /// Workspace names by project ID.
    public var workspaces: [String: String]
    public var sync: SyncEngine.Status?
    /// When set, the agents whose chats outside the Chats space the archive shows (the apps' Chat: Claude Code and
    /// Codex, 2026-10-12); every chat of the Chats space shows too. Other agents' chats stay saved, unlisted. Nil
    /// shows every chat.
    public var chatAgents: Set<String>?

    public init(client: APIClient?, capabilities: CapabilitiesResponse?, reachable: Bool, hostName: String,
                workspaces: [String: String] = [:], sync: SyncEngine.Status? = nil, chatAgents: Set<String>? = nil) {
        self.client = client; self.capabilities = capabilities; self.reachable = reachable; self.hostName = hostName
        self.workspaces = workspaces; self.sync = sync; self.chatAgents = chatAgents
    }

    /// Whether the archive shows the chat `chatID` of `projectID` (`chatAgents`). `provider` is the chat's agent when
    /// known; otherwise its ID names it (`<agent>:<id>`, OpenCode's without a prefix).
    public func showsChat(_ chatID: String, projectID: String, provider: String?) -> Bool {
        guard let chatAgents else { return true }
        if isChatsSpace(projectID) { return true }
        let agent = provider ?? chatID.firstIndex(of: ":").map { String(chatID[..<$0]) } ?? "opencode"
        return chatAgents.contains(agent)
    }

    var chatsSpaceID: String? {
        PlainChatsCapability.chatsSpace(capability: capabilities?.plainChats, isWorkspace: { workspaces[$0] != nil })
    }

    /// The host can be asked right now.
    var online: Bool { reachable && client != nil }

    /// Whether `projectID` is the host's Chats space, whose chats are plain chats (`PlainChatsCapability.chatsSpace`):
    /// an older host's workspace called `chats` stays a workspace.
    public func isChatsSpace(_ projectID: String) -> Bool {
        projectID == PlainChatsCapability.chatsSpace(capability: capabilities?.plainChats, isWorkspace: { workspaces[$0] != nil })
    }
}

/// A chat read from the archive: this device's copy first, the host's pages
/// when the device has not copied it yet. Read-only.
@MainActor @Observable
public final class ArchivedChatModel {
    public enum Phase: Equatable, Sendable {
        case loading
        case ready
        /// Neither this device nor the host has it.
        case missing
        case failed(String)
    }

    public let chatID: String
    public let store: ArchiveStore
    public private(set) var chat: ArchivedChat?
    public private(set) var messages: [ArchivedMessage] = []
    public private(set) var hasEarlier = false
    public private(set) var phase: Phase = .loading
    /// Read from the host because this device has no copy yet.
    public private(set) var fromHost = false
    public private(set) var loadingEarlier = false
    public private(set) var environment: ArchiveEnvironment
    /// Where opened attachments are kept; without it attachments show by name only.
    public let attachments: AttachmentCache?
    /// The attachment being fetched (its `attachmentKey`).
    public private(set) var openingAttachment: String?
    /// A file to show in Quick Look.
    public var openedAttachment: URL?
    /// Why the last attachment did not open.
    public private(set) var attachmentNotice: String?
    @ObservationIgnored private var hostOldestID: String?

    public init(chatID: String, store: ArchiveStore, environment: ArchiveEnvironment, attachments: AttachmentCache? = nil) {
        self.chatID = chatID
        self.store = store
        self.environment = environment
        self.attachments = attachments
    }

    public func update(_ environment: ArchiveEnvironment) { self.environment = environment }

    public var workspaceName: String? { chat.flatMap { environment.workspaces[$0.projectID] } }

    public func load() async {
        do {
            if let saved = try await store.chat(id: chatID) {
                guard environment.showsChat(saved.id, projectID: saved.projectID, provider: saved.provider) else {
                    phase = .missing
                    return
                }
                let page = try await store.messages(chatID: chatID)
                chat = saved
                messages = page.messages
                hasEarlier = page.hasEarlier
                fromHost = false
                phase = .ready
                return
            }
            guard environment.online, let client = environment.client else {
                phase = .missing
                return
            }
            let page = try await client.archiveChat(chatID: chatID)
            guard environment.showsChat(chatID, projectID: page.chat.projectID, provider: page.chat.provider) else {
                phase = .missing
                return
            }
            chat = Self.chat(page.chat, pinned: false)
            messages = page.messages.filter { !$0.hidden }.map { ArchivedMessage(message: $0.message, hidden: $0.hidden) }
            hasEarlier = page.hasMore
            hostOldestID = page.oldestID
            fromHost = true
            phase = .ready
        } catch let ClientError.server(code, _) where code == "not_found" {
            phase = .missing
        } catch {
            phase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    public func loadEarlier() async {
        guard hasEarlier, !loadingEarlier else { return }
        loadingEarlier = true
        defer { loadingEarlier = false }
        do {
            if fromHost {
                guard let client = environment.client, let oldest = hostOldestID else { return }
                let page = try await client.archiveChat(chatID: chatID, before: oldest)
                messages = page.messages.filter { !$0.hidden }.map { ArchivedMessage(message: $0.message) } + messages
                hasEarlier = page.hasMore
                hostOldestID = page.oldestID
            } else {
                guard let oldest = messages.first?.id else { return }
                let page = try await store.messages(chatID: chatID, before: oldest)
                messages = page.messages + messages
                hasEarlier = page.hasEarlier
            }
        } catch {
            // The loaded messages stay; the button stays for another try.
        }
    }

    public func setPinned(_ pinned: Bool) async {
        guard !fromHost, chat != nil else { return }
        try? await store.setPinned(pinned, chatID: chatID)
        chat?.pinned = pinned
    }

    // MARK: Attachments

    /// The host, when it can send attachment bytes now (it lists `blobs`).
    var attachmentFetcher: (any AttachmentFetching)? {
        environment.online && environment.capabilities?.supportsArchive(.blobs) == true ? environment.client : nil
    }

    /// Whether an attachment can be opened. Copies synced from hosts that
    /// report sizes know when the host kept a file's name only (a size
    /// without a SHA-256); older copies find out from the host.
    public func canOpen(_ attachment: AttachmentRecord) -> Bool {
        attachments != nil && !(attachment.size != nil && attachment.sha256 == nil)
    }

    static func attachmentKey(_ attachment: AttachmentRecord, messageID: String) -> String {
        [messageID, attachment.name, attachment.sha256 ?? ""].joined(separator: "\u{1F}")
    }

    public func isOpening(_ attachment: AttachmentRecord, messageID: String) -> Bool {
        openingAttachment == Self.attachmentKey(attachment, messageID: messageID)
    }

    /// Shows an attachment: from this device when saved, otherwise fetched
    /// from the host first.
    public func open(_ attachment: AttachmentRecord, messageID: String) async {
        guard let attachments, canOpen(attachment) else { return }
        let key = Self.attachmentKey(attachment, messageID: messageID)
        openingAttachment = key
        defer { if openingAttachment == key { openingAttachment = nil } }
        do {
            openedAttachment = try await attachments.file(for: attachment, chatID: chatID, messageID: messageID, fetcher: attachmentFetcher)
            attachmentNotice = nil
        } catch is CancellationError {
        } catch AttachmentCacheError.notSaved where environment.online {
            attachmentNotice = "\(environment.hostName) can’t send files from the archive. Update AgentLand on your Mac to open them."
        } catch {
            attachmentNotice = "“\(attachment.name)” didn’t open. \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
        }
    }

    public func dismissAttachmentNotice() { attachmentNotice = nil }

    /// The attachment for the share sheet, fetched when it is shared.
    func shareable(_ attachment: AttachmentRecord, messageID: String) -> ArchivedAttachmentFile? {
        guard let attachments, canOpen(attachment) else { return nil }
        return ArchivedAttachmentFile(attachment: attachment, chatID: chatID, messageID: messageID, cache: attachments, fetcher: attachmentFetcher)
    }

    static func chat(_ record: ArchiveChatRecord, pinned: Bool) -> ArchivedChat {
        ArchivedChat(id: record.id, projectID: record.projectID, provider: record.provider, title: record.title, model: record.model,
                     mode: record.mode, effort: record.effort, parentID: record.parentID, relation: record.relation,
                     createdAt: ChatTime.date(record.createdAt) ?? .distantPast, updatedAt: ChatTime.date(record.updatedAt) ?? .distantPast,
                     pinned: pinned)
    }
}

/// A read-only transcript of an archived chat, with Export, Continue with…,
/// Pin and, when the app offers it, Open Chat.
public struct ArchivedChatView: View {
    @State private var model: ArchivedChatModel
    private let actions: ArchiveActions
    @State private var continuing = false

    public init(model: ArchivedChatModel, actions: ArchiveActions = ArchiveActions()) {
        _model = State(initialValue: model)
        self.actions = actions
    }

    public var body: some View {
        content
            .background(AgentLandColor.canvas)
            .navigationTitle(model.chat?.displayTitle ?? "Chat")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { toolbar }
            .task { await model.load() }
            .attachmentPreview($model.openedAttachment)
            .sheet(isPresented: $continuing) {
                if let chat = model.chat {
                    ContinueChatSheet(model: ContinueChatModel(chat: chat, store: model.store, environment: model.environment,
                                                               workspaceName: model.workspaceName)) { result in
                        actions.continued?(result)
                    }
                    .agentLandSheetPage()
                }
            }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView("Loading chat…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .missing:
            ContentUnavailable("Chat Not Found", systemImage: "archivebox",
                               description: model.environment.online ? "It is no longer in your Mac’s archive." : "It isn’t saved on this device yet. Connect to your Mac to read it.")
        case let .failed(message):
            ContentUnavailable("Chat Unavailable", systemImage: "exclamationmark.triangle", description: message)
        case .ready:
            transcript
        }
    }

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: AgentLandSpacing.large) {
                if let chat = model.chat { ArchivedChatHeader(chat: chat, workspace: model.workspaceName, fromHost: model.fromHost) }
                if let notice = model.attachmentNotice {
                    InlineNotice(notice, tone: .warning, onDismiss: { model.dismissAttachmentNotice() })
                }
                if model.hasEarlier {
                    Button {
                        Task { await model.loadEarlier() }
                    } label: {
                        Label(model.loadingEarlier ? "Loading…" : "Show Earlier Messages", systemImage: "arrow.up.circle")
                            .agentLandFont(.secondary)
                            .minimumTapTarget()
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.loadingEarlier)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("archivedChatEarlier")
                }
                if model.messages.isEmpty {
                    Text("No messages were archived for this chat.")
                        .agentLandFont(.secondary)
                        .foregroundStyle(AgentLandColor.textSecondary)
                }
                ForEach(model.messages) { message in
                    ArchivedMessageView(message: message, agent: model.chat?.agent ?? .opencode, model: model)
                }
            }
            .padding(AgentLandSpacing.medium)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.bottom)
        .accessibilityIdentifier("archivedChatTranscript")
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if let chat = model.chat {
            ToolbarItemGroup(placement: .primaryAction) {
                if let openChat = actions.openChat, model.environment.online {
                    Button("Open Chat", systemImage: "bubble.left.and.text.bubble.right") { _ = openChat(chat) }
                        .accessibilityIdentifier("archivedChatOpen")
                }
                Menu {
                    ShareLink(item: ArchiveChatExport(chat: chat, format: .markdown, client: model.environment.online ? model.environment.client : nil,
                                                      store: model.store, workspace: model.workspaceName),
                              preview: SharePreview(chat.displayTitle + ".md")) {
                        Label("Markdown", systemImage: "doc.richtext")
                    }
                    ShareLink(item: ArchiveChatExport(chat: chat, format: .json, client: model.environment.online ? model.environment.client : nil,
                                                      store: model.store, workspace: model.workspaceName),
                              preview: SharePreview(chat.displayTitle + ".json")) {
                        Label("JSON", systemImage: "curlybraces")
                    }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("archivedChatExport")
                Menu {
                    if actions.continued != nil {
                        Button("Continue with…", systemImage: "arrow.triangle.swap") { continuing = true }
                            .disabled(!model.environment.online)
                    }
                    if !model.fromHost {
                        Button(chat.pinned ? "Unpin" : "Pin", systemImage: chat.pinned ? "pin.slash" : "pin") {
                            Task { await model.setPinned(!chat.pinned) }
                        }
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .accessibilityIdentifier("archivedChatMore")
            }
        }
    }
}

/// Title, agent, model, workspace and dates.
struct ArchivedChatHeader: View {
    let chat: ArchivedChat
    let workspace: String?
    let fromHost: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: AgentLandSpacing.xxSmall) {
            Text(chat.displayTitle)
                .agentLandFont(.heading1)
                .foregroundStyle(AgentLandColor.text)
                .accessibilityAddTraits(.isHeader)
            Text(([chat.agent.displayName, chat.model, workspace].compactMap { $0 }.filter { !$0.isEmpty }).joined(separator: " · "))
                .agentLandFont(.secondary)
                .foregroundStyle(AgentLandColor.textSecondary)
            Text("Started \(chat.createdAt.formatted(date: .abbreviated, time: .shortened)) · Last active \(chat.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                .agentLandFont(.metadata)
                .foregroundStyle(AgentLandColor.textSecondary)
            if chat.relation == "continue" {
                Label("Continued from an earlier chat", systemImage: "arrow.triangle.swap")
                    .agentLandFont(.metadata)
                    .foregroundStyle(AgentLandColor.textSecondary)
            }
            if fromHost {
                Label("Read from your Mac; not saved on this device yet", systemImage: "desktopcomputer")
                    .agentLandFont(.metadata)
                    .foregroundStyle(AgentLandColor.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// One archived message, read-only: user text in a bubble; replies as
/// Markdown with reasoning, tool calls and changed files collapsed.
struct ArchivedMessageView: View {
    let message: ArchivedMessage
    let agent: AgentProvider
    /// Opens attachments; without it they show by name only.
    var model: ArchivedChatModel?

    var body: some View {
        let value = message.message
        if message.isContextSeed {
            ArchivedDisclosure(title: "Context from an earlier chat", systemImage: "text.quote") {
                ChatMarkdownView(value.parts.map(\.text).joined(separator: "\n\n"), role: .supporting)
            }
        } else if value.role == .user {
            userMessage(value)
        } else {
            reply(value)
        }
    }

    private func userMessage(_ value: ConversationMessage) -> some View {
        let text = value.parts.filter { $0.kind == .text }.map(\.text).joined(separator: "\n\n")
        let attachments = value.parts.compactMap(\.attachment)
        let date = ChatTime.date(value.createdAt)
        // The attachments stay their own accessibility elements, so each can
        // be opened; the text and time read as one.
        return VStack(alignment: .trailing, spacing: AgentLandSpacing.xxSmall) {
            if !attachments.isEmpty { ArchivedAttachments(attachments: attachments, messageID: value.id, model: model) }
            VStack(alignment: .trailing, spacing: AgentLandSpacing.xxSmall) {
                if !text.isEmpty {
                    Text(verbatim: text)
                        .agentLandFont(.body)
                        .foregroundStyle(AgentLandColor.text)
                        .textSelection(.enabled)
                        .padding(.horizontal, AgentLandSpacing.small + AgentLandSpacing.xxxSmall)
                        .padding(.vertical, AgentLandSpacing.small - AgentLandSpacing.xxxSmall)
                        .background(AgentLandColor.surface, in: AgentLandRadius.shape(AgentLandRadius.bubble))
                }
                if let date {
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                        .agentLandFont(.caption)
                        .foregroundStyle(AgentLandColor.textSecondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Your message" + (date.map { ", " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "") + ": " + text)
            .accessibilityIdentifier("archivedUserMessage")
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, AgentLandSpacing.xxLarge)
    }

    private func reply(_ value: ConversationMessage) -> some View {
        VStack(alignment: .leading, spacing: AgentLandSpacing.small) {
            ForEach(value.parts) { part in
                ArchivedPartView(part: part, interrupted: value.status != .streaming, messageID: value.id, model: model)
            }
            if value.status == .error, let error = value.error {
                Label(error.message.isEmpty ? "The reply failed." : error.message, systemImage: "exclamationmark.triangle")
                    .agentLandFont(.secondary)
                    .foregroundStyle(AgentLandColor.danger)
            } else if value.status == .aborted {
                Label("Stopped", systemImage: "stop.circle")
                    .agentLandFont(.metadata)
                    .foregroundStyle(AgentLandColor.textSecondary)
            }
            Text(([agent.displayName, value.model].compactMap { $0 } + [ChatTime.date(value.createdAt).map { $0.formatted(date: .omitted, time: .shortened) }].compactMap { $0 })
                .joined(separator: " · "))
                .agentLandFont(.caption)
                .foregroundStyle(AgentLandColor.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(agent.displayName) reply")
        .accessibilityIdentifier("archivedReply")
    }
}

/// One part of a reply.
struct ArchivedPartView: View {
    let part: ConversationPart
    let interrupted: Bool
    var messageID = ""
    var model: ArchivedChatModel?

    var body: some View {
        switch part.kind {
        case .text:
            if !part.text.isEmpty { ChatMarkdownView(part.text, role: .reply) }
        case .reasoning:
            if !part.text.isEmpty {
                ArchivedDisclosure(title: reasoningTitle, systemImage: "brain") {
                    ChatMarkdownView(part.text, role: .supporting)
                }
            }
        case .tool:
            if let tool = part.tool { ArchivedToolRow(tool: tool, interrupted: interrupted) }
        case .patch:
            let files = part.text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
            if !files.isEmpty {
                ArchivedDisclosure(title: files.count == 1 ? "Changed 1 file" : "Changed \(files.count) files", systemImage: "doc.badge.gearshape") {
                    VStack(alignment: .leading, spacing: AgentLandSpacing.xxSmall) {
                        ForEach(Array(files.enumerated()), id: \.offset) { _, file in
                            Text(verbatim: file).agentLandFont(.codeSmall).foregroundStyle(AgentLandColor.text)
                        }
                    }
                }
            }
        case .notice:
            if !part.text.isEmpty {
                Label(part.text, systemImage: "info.circle")
                    .agentLandFont(.metadata)
                    .foregroundStyle(AgentLandColor.textSecondary)
            }
        case .attachment:
            if let attachment = part.attachment { ArchivedAttachments(attachments: [attachment], messageID: messageID, model: model) }
        case .context:
            ArchivedDisclosure(title: "Context from an earlier chat", systemImage: "text.quote") {
                ChatMarkdownView(part.text, role: .supporting)
            }
        case .other:
            EmptyView()
        }
    }

    private var reasoningTitle: String {
        ChatDurations.seconds(start: part.start, end: part.end, legacyMilliseconds: part.durationMs)
            .map { "Thought for " + ChatDurations.finished($0) } ?? "Reasoning"
    }
}

/// A tool call: its summary, and its input and output when opened.
struct ArchivedToolRow: View {
    let tool: ConversationTool
    let interrupted: Bool

    var body: some View {
        let summary = ChatToolSummary(tool, interrupted: interrupted)
        ArchivedDisclosure(title: summary.phrase, systemImage: summary.kind.symbol, detail: summary.state.label) {
            VStack(alignment: .leading, spacing: AgentLandSpacing.xSmall) {
                if !tool.input.isEmpty { block("Input", tool.input) }
                if !tool.output.isEmpty { block("Output", tool.output) }
                if !tool.error.isEmpty { block("Error", tool.error) }
                if tool.truncated {
                    Text("Shortened by your Mac.").agentLandFont(.caption).foregroundStyle(AgentLandColor.textSecondary)
                }
            }
        }
    }

    private func block(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: AgentLandSpacing.xxSmall) {
            Text(title).agentLandFont(.caption).foregroundStyle(AgentLandColor.textSecondary)
            Text(verbatim: text.count > 8_000 ? String(text.prefix(8_000)) + "\n…" : text)
                .agentLandFont(.codeSmall)
                .foregroundStyle(AgentLandColor.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(AgentLandSpacing.xSmall)
                .background(AgentLandColor.surface, in: AgentLandRadius.shape(AgentLandRadius.chip))
        }
    }
}

/// A collapsed section with a symbol, a title and an optional state.
struct ArchivedDisclosure<Content: View>: View {
    let title: String
    let systemImage: String
    var detail: String?
    @ViewBuilder let content: () -> Content
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            content().padding(.top, AgentLandSpacing.xxSmall)
        } label: {
            HStack(spacing: AgentLandSpacing.xSmall) {
                Image(systemName: systemImage)
                    .foregroundStyle(AgentLandColor.glyphTertiary)
                    .agentLandIconFrame(.small)
                    .accessibilityHidden(true)
                Text(title).foregroundStyle(AgentLandColor.text)
                if let detail {
                    Text(detail).foregroundStyle(AgentLandColor.textSecondary)
                }
            }
            .agentLandFont(.secondary)
            .agentLandRowHeight()
        }
        .tint(AgentLandColor.glyphTertiary)
    }
}

/// Files sent with a message. With a model, a file the host kept opens in
/// Quick Look when tapped and can be shared from its context menu; it is
/// fetched from the host the first time.
struct ArchivedAttachments: View {
    let attachments: [AttachmentRecord]
    var messageID = ""
    var model: ArchivedChatModel?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: AgentLandSpacing.xxSmall) { chips }
            VStack(alignment: .trailing, spacing: AgentLandSpacing.xxSmall) { chips }
        }
    }

    private var chips: some View {
        ForEach(Array(attachments.enumerated()), id: \.offset) { _, attachment in
            if let model, model.canOpen(attachment) {
                let opening = model.isOpening(attachment, messageID: messageID)
                Button {
                    Task { await model.open(attachment, messageID: messageID) }
                } label: {
                    chip(attachment, opening: opening)
                }
                .buttonStyle(.plain)
                .disabled(opening)
                .minimumTapTarget()
                .contextMenu {
                    if let file = model.shareable(attachment, messageID: messageID) {
                        ShareLink(item: file, preview: SharePreview(attachment.name)) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                    }
                }
                .accessibilityLabel("Attachment \(attachment.name)")
                .accessibilityHint("Opens the file")
                .accessibilityIdentifier("archivedAttachment")
            } else {
                chip(attachment, opening: false)
                    .accessibilityLabel("Attachment \(attachment.name)")
            }
        }
    }

    private func chip(_ attachment: AttachmentRecord, opening: Bool) -> some View {
        HStack(spacing: AgentLandSpacing.xxSmall) {
            Label(attachment.name, systemImage: ChatAttachmentPolicy.symbol(forMime: attachment.mime))
                .lineLimit(1)
                .truncationMode(.middle)
            if opening {
                ProgressView().controlSize(.mini)
            }
        }
        .agentLandFont(.metadata)
        .foregroundStyle(AgentLandColor.text)
        .padding(.horizontal, AgentLandSpacing.small - AgentLandSpacing.xxSmall)
        .padding(.vertical, AgentLandSpacing.xxSmall + AgentLandSpacing.xxxSmall)
        .background(AgentLandColor.surface, in: Capsule())
    }
}
