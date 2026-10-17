import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers
import AgentLandChat
import AgentLandCore
import AgentLandDesign

/// A new chat's draft for hosts that cannot continue chats themselves: the
/// source as a Markdown attachment (or inline when the host takes no
/// attachments) and a message ready to edit. The app opens a new chat of
/// `provider` and puts this in its composer. Nothing sends it until the
/// person does.
public struct ContinueDraft: Equatable, Sendable {
    public var projectID: String
    public var sourceChatID: String
    public var provider: String
    public var model: String?
    public var mode: String?
    public var effort: String?
    public var title: String
    public var text: String
    public var attachment: ChatAttachmentPolicy.Prepared?
}

public enum ContinueResult: Equatable, Sendable {
    /// The host created the chat (`POST /v1/chat/continue`): open it.
    case chat(Session)
    /// This host cannot continue chats: open a new chat with this draft.
    case draft(ContinueDraft)
}

/// Continue with…: the agent, model, mode and effort of the new chat, the
/// message to stop at, and how much context to carry, with a preview of the
/// seed's size computed from this device's copy.
@MainActor @Observable
public final class ContinueChatModel {
    public struct ContextSize: Identifiable, Hashable, Sendable {
        public let name: String
        public let characters: Int
        public var id: Int { characters }
    }

    public static let contextSizes = [ContextSize(name: "Short", characters: 16_000), ContextSize(name: "Standard", characters: 48_000),
                                      ContextSize(name: "Long", characters: 100_000), ContextSize(name: "Full", characters: 200_000)]

    public let chat: ArchivedChat
    public let store: ArchiveStore
    public private(set) var messages: [ArchivedMessage] = []
    public private(set) var provider: AgentProvider
    public private(set) var options: ChatOptionsResponse?
    public private(set) var loadingOptions = false
    public var model = ""
    public var mode = ""
    public var effort = ""
    /// The last message to carry; nil carries through the latest.
    public var cutoffMessageID: String?
    public var contextChars = ChatContinueRequest.defaultContextChars
    public private(set) var working = false
    public private(set) var notice: String?
    public private(set) var environment: ArchiveEnvironment
    public let workspaceName: String?

    public init(chat: ArchivedChat, store: ArchiveStore, environment: ArchiveEnvironment, workspaceName: String? = nil) {
        self.chat = chat
        self.store = store
        self.environment = environment
        self.workspaceName = workspaceName
        let offered = Self.providers(for: chat, environment: environment)
        // Another agent than the chat's own, when there is one.
        provider = offered.first { $0.id != chat.provider } ?? offered.first ?? .opencode
    }

    public func update(_ environment: ArchiveEnvironment) { self.environment = environment }

    /// A plain chat (the host's Chats space) continues only into another plain chat: OpenCode's, with a model and
    /// no mode or effort (docs/HOST-API.md "Plain chats").
    public var isPlainChat: Bool { environment.isChatsSpace(chat.projectID) }

    public var providers: [AgentProvider] { Self.providers(for: chat, environment: environment) }

    /// The agents a new chat continued from `chat` can have: OpenCode alone for a plain chat, the host's agents
    /// for the others.
    static func providers(for chat: ArchivedChat, environment: ArchiveEnvironment) -> [AgentProvider] {
        environment.isChatsSpace(chat.projectID) ? (environment.capabilities?.plainChats?.availableProviders.contains(where: { $0.id == chat.provider }) == true ? [chat.agent] : []) : AgentProvider.offered(by: environment.capabilities)
    }

    /// The host starts continued chats itself (`continue`).
    public var hostContinues: Bool {
        environment.capabilities?.supports(.continue) == true || environment.capabilities?.supportsArchive(.continue) == true
    }

    /// The cut-off is offered when the host takes `throughMessageId`, and
    /// always for the draft, which this device builds.
    public var offersCutoff: Bool { hostContinues ? environment.capabilities?.continuesThroughMessage == true : true }

    /// Messages that can end the carried context, oldest first.
    public var cutoffChoices: [ArchivedMessage] {
        messages.filter { !$0.hidden && !$0.isContextSeed && !ContinueSeed.render($0.message).isEmpty }
    }

    public var preview: ContinueSeed {
        ContinueSeed.build(chat: chat, messages: messages, through: offersCutoff ? cutoffMessageID : nil, budget: contextChars)
    }

    /// The new chat's modes; none for an ACP agent, whose new chat takes no mode (docs/HOST-API.md "Continue
    /// with another model"), so no picker shows.
    public var modeChoices: [ChatModeOption] {
        guard provider.continueTakesModeAndEffort, !isPlainChat else { return [] }
        if let modes = options?.modes, !modes.isEmpty { return modes }
        return options?.agents.map { ChatModeOption(id: $0, name: $0.prefix(1).uppercased() + $0.dropFirst()) } ?? []
    }

    public var effortChoices: [String] {
        guard provider.continueTakesModeAndEffort,
              !isPlainChat || environment.capabilities?.plainChats?.availableProviders.first(where: { $0.id == provider.id })?.features.contains("effort") == true,
              environment.capabilities?.supports(.effort, provider: provider.id) == true else { return [] }
        return options?.models.first { $0.id == model }?.efforts ?? []
    }

    public var canContinue: Bool { !working && environment.online }

    public func load() async {
        messages = (try? await store.allMessages(chatID: chat.id)) ?? []
        // By id, taking the host's current name for it: its catalog may have named the agent since.
        if let current = providers.first(where: { $0.id == provider.id }) { provider = current }
        else if let first = providers.first { provider = first }
        await loadOptions()
    }

    /// Chooses the agent the host offers under `id`.
    public func select(id: String) async {
        guard let chosen = providers.first(where: { $0.id == id }) else { return }
        let changed = chosen.id != provider.id
        provider = chosen
        if changed { await loadOptions() }
    }

    public func select(_ provider: AgentProvider) async { await select(id: provider.id) }

    private func loadOptions() async {
        let provider = provider
        guard environment.online, let client = environment.client else {
            options = nil
            return
        }
        loadingOptions = true
        let loaded = try? await client.chatOptions(projectID: chat.projectID, provider: provider.id)
        guard provider == self.provider else { return }
        loadingOptions = false
        options = loaded
        model = loaded.map { options in options.models.contains { $0.id == options.defaultModel } ? options.defaultModel : options.models.first?.id ?? "" } ?? ""
        let modes = modeChoices
        mode = loaded?.defaultMode.flatMap { mode in modes.first { $0.id == mode }?.id } ?? modes.first?.id ?? ""
        let efforts = effortChoices
        effort = loaded?.models.first { $0.id == model }?.defaultEffort.flatMap { efforts.contains($0) ? $0 : nil } ?? efforts.first ?? ""
    }

    /// Continues on the host, or builds the draft for hosts without Continue.
    /// Nil when it did not happen; `notice` says why.
    public func submit() async -> ContinueResult? {
        guard canContinue, let client = environment.client else {
            notice = "Connect to your Mac to continue this chat."
            return nil
        }
        notice = nil
        guard hostContinues else { return .draft(makeDraft()) }
        working = true
        defer { working = false }
        let settings = chosenSettings
        let request = ChatContinueRequest(
            projectID: chat.projectID, sourceSessionID: chat.id, provider: provider.id,
            model: settings.model, mode: settings.mode, effort: settings.effort,
            throughMessageID: environment.capabilities?.continuesThroughMessage == true ? cutoffMessageID : nil,
            contextChars: contextChars == ChatContinueRequest.defaultContextChars ? nil : contextChars)
        switch await client.continueChat(request) {
        case let .created(session):
            return .chat(session)
        case .uncertain:
            notice = "Your Mac may have created the new chat. Check your chats before trying again."
        case let .failed(error):
            notice = error.localizedDescription
        }
        return nil
    }

    func makeDraft() -> ContinueDraft {
        let seed = preview
        let source = chat.displayTitle
        let agent = chat.agent.displayName
        var attachment: ChatAttachmentPolicy.Prepared?
        var text: String
        if environment.capabilities?.supports(.attachments) == true, !seed.isEmpty,
           let prepared = try? ChatAttachmentPolicy.prepare(
               name: ArchiveChatExport(chat: chat, format: .markdown, client: nil, store: store).fileName,
               data: Data(seed.markdown(title: source, agent: agent, model: chat.model, workspace: workspaceName).utf8),
               type: UTType(filenameExtension: "md")) {
            attachment = prepared
            text = "The attached file is an earlier chat, “\(source)”, with \(agent). Continue from where it ends."
        } else {
            text = "Here is an earlier chat, “\(source)”, with \(agent). Continue from where it ends."
            if !seed.isEmpty { text += "\n\n" + seed.text }
        }
        let settings = chosenSettings
        return ContinueDraft(projectID: chat.projectID, sourceChatID: chat.id, provider: provider.id, model: settings.model,
                             mode: settings.mode, effort: settings.effort,
                             title: HostTitle.clipped(source + " (continued)"), text: text, attachment: attachment)
    }

    /// The model, mode and effort chosen, as the new chat's agent takes them: an ACP agent gets no mode or
    /// effort, and only `<id>/default` as its model.
    private var chosenSettings: (model: String?, mode: String?, effort: String?) {
        // A plain chat's new chat takes a model alone.
        if isPlainChat { return (model.isEmpty ? nil : model, nil, effortChoices.contains(effort) ? effort : nil) }
        return provider.continueSettings(model: model.isEmpty ? nil : model, mode: mode.isEmpty ? nil : mode,
                                         effort: effortChoices.contains(effort) ? effort : nil)
    }

    /// "You · 12:03 · Why does the login…"
    public func summary(of message: ArchivedMessage) -> String {
        let value = message.message
        let who = value.role == .user ? "You" : chat.agent.displayName
        let when = ChatTime.date(value.createdAt).map { $0.formatted(date: .abbreviated, time: .shortened) }
        let text = value.parts.filter { $0.kind == .text }.map(\.text).joined(separator: " ")
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        let short = line.count > 60 ? String(line.prefix(59)) + "…" : line
        return ([who, when].compactMap { $0 } + (short.isEmpty ? [] : [short])).joined(separator: " · ")
    }
}

/// The Continue with… sheet. It hands the new chat (or the draft) back
/// through `onContinue` and closes.
public struct ContinueChatSheet: View {
    @State private var model: ContinueChatModel
    private let onContinue: @MainActor (ContinueResult) -> Void
    @Environment(\.dismiss) private var dismiss

    public init(model: ContinueChatModel, onContinue: @escaping @MainActor (ContinueResult) -> Void) {
        _model = State(initialValue: model)
        self.onContinue = onContinue
    }

    public var body: some View {
        NavigationStack {
            AgentLandForm {
                agentSection
                if model.offersCutoff, model.cutoffChoices.count > 1 { cutoffSection }
                contextSection
                if let notice = model.notice {
                    Section {
                        Label(notice, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(AgentLandColor.warning)
                            .accessibilityIdentifier("continueNotice")
                    }
                }
            }
            .formStyle(.grouped)
            #if os(iOS)
            // The sheet's raised paper or slate behind paper or slate rows (2026-10-07).
            .listPageBackground()
            #endif
            .navigationTitle("Continue with…")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(model.hostContinues ? "Continue" : "Prepare Draft") {
                        Task {
                            guard let result = await model.submit() else { return }
                            onContinue(result)
                            dismiss()
                        }
                    }
                    .disabled(!model.canContinue)
                    .accessibilityIdentifier("continueStart")
                }
            }
            .task { await model.load() }
        }
        .frame(minWidth: 380, minHeight: 440)
    }

    private var agentSection: some View {
        Section {
            // A plain chat continues into a plain chat: there is no agent to choose.
            if !model.isPlainChat {
                // By id: the host's name for an agent may change while the sheet is open.
                Picker("Agent", selection: Binding(get: { model.provider.id }, set: { id in Task { await model.select(id: id) } })) {
                    ForEach(model.providers) { Text($0.displayName).tag($0.id) }
                }
                .accessibilityIdentifier("continueProvider")
            }
            if model.loadingOptions {
                ProgressView()
            } else if let options = model.options {
                if !options.models.isEmpty {
                    Picker("Model", selection: $model.model) {
                        ForEach(options.models) { Text($0.name).tag($0.id) }
                    }
                    .accessibilityIdentifier("continueModel")
                }
                if model.modeChoices.count > 1 {
                    Picker("Mode", selection: $model.mode) {
                        ForEach(model.modeChoices) { Text($0.name).tag($0.id) }
                    }
                }
                if !model.effortChoices.isEmpty {
                    Picker("Effort", selection: $model.effort) {
                        ForEach(model.effortChoices, id: \.self) { Text($0.capitalized).tag($0) }
                    }
                }
            } else if !model.environment.online {
                Text("Connect to your Mac to choose a model.")
                    .foregroundStyle(AgentLandColor.textSecondary)
            }
        } header: {
            Text("New Chat")
        }
    }

    private var cutoffSection: some View {
        Section {
            Picker("Include Through", selection: $model.cutoffMessageID) {
                Text("Latest Message").tag(String?.none)
                ForEach(model.cutoffChoices.reversed()) { message in
                    Text(model.summary(of: message)).lineLimit(1).tag(Optional(message.id))
                }
            }
            .accessibilityIdentifier("continueCutoff")
        } header: {
            Text("Messages")
        } footer: {
            Text("Messages after this one are left out.")
        }
    }

    private var contextSection: some View {
        let seed = model.preview
        return Section {
            Picker("Context Size", selection: $model.contextChars) {
                ForEach(ContinueChatModel.contextSizes) { size in
                    Text("\(size.name) · \(size.characters.formatted()) characters").tag(size.characters)
                }
            }
            .accessibilityIdentifier("continueContextSize")
            LabeledContent("Messages", value: "\(seed.included) of \(seed.included + seed.omitted)")
            LabeledContent("Size", value: "\(seed.characters.formatted()) characters, about \(seed.estimatedTokens.formatted()) tokens")
                .accessibilityIdentifier("continuePreview")
        } header: {
            Text("Context")
        } footer: {
            if model.hostContinues {
                Text("The new chat starts with the first message and the most recent ones as context, counted from the copy on this device. Nothing is sent until you send a message.")
            } else {
                Text("Your Mac can’t continue chats itself. A new chat opens with this conversation attached and a message ready to edit. Nothing is sent until you send it.")
            }
        }
    }
}
