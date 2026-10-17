import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import AgentLandBranding
import AgentLandDesign
import AgentLandCore
#if canImport(UIKit)
import UIKit
#endif

/// The floating composer: one glass container holding the rewind banner,
/// the queue, attachments, the text and its toolbar. Stop is always reachable
/// while the agent works.
struct ChatComposer: View {
    let store: ChatSessionStore
    let inputEnabled: Bool
    let focused: FocusState<Bool>.Binding
    let dropTargeted: Bool
    let addFiles: () -> Void
    let addPhotos: () -> Void
    let takePhoto: (() -> Void)?
    let pasteImage: (() -> Void)?
    let sent: () -> Void
    @StateObject private var dictation = ChatDictation()
    /// Settings → Chat: a long paste goes as a text file (off by default).
    @AppStorage(ChatSettings.longPasteAsFileKey) private var longPastesAsFiles = ChatSettings.longPasteAsFileDefault
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var circle: CGFloat = 32
    /// The chip row's width, and what the chips need with whole names: the mode folds to its symbol when they
    /// don't fit. Neither depends on the fold, so measuring can't loop.
    @State private var chipRowWidth: CGFloat = 0
    @State private var wholeChipsWidth: CGFloat = 0
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    private var compact: Bool {
        #if os(iOS)
        sizeClass != .regular
        #else
        false
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if store.rewind != nil {
                ChatRewindBanner(busy: store.mutating || store.isWorking || !inputEnabled) { Task { await store.restoreRewind() } }
            }
            if !store.queue.isEmpty {
                ChatQueueList(items: store.queue,
                              edit: { item in Task { await store.editQueued(item) } },
                              remove: { item in Task { await store.removeQueued(item) } })
                    .disabled(store.mutating || !inputEnabled || !store.reachable)
            }
            if !store.attachments.isEmpty { ChatPendingAttachmentsStrip(tray: store.attachments) }
            field
            toolbar
        }
        .padding(8)
        .chatFloatingSurface(RoundedRectangle(cornerRadius: 24, style: .continuous), reduceTransparency: reduceTransparency,
                             increasedContrast: contrast == .increased)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(AgentLandColor.tint.color, lineWidth: 2)
            }
        }
        .onChange(of: dictation.problem) { _, problem in
            if let problem { store.report(problem); dictation.problem = nil }
        }
        .onChange(of: store.attachments.problem) { _, problem in
            if let problem { store.report(problem); store.attachments.problem = nil }
        }
        .onChange(of: inputEnabled) { _, enabled in if !enabled { dictation.stop() } }
        .onDisappear { dictation.stop() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chatComposer")
    }

    /// "Message Claude Code"; a plain chat's is "Message".
    private var placeholder: String { store.isPlainChat ? "Message" : "Message \(store.provider.displayName)" }

    private var field: some View {
        // The prompt in the theme's secondary color: the system placeholder
        // color is too faint on the glass composer.
        TextField(text: Binding(get: { store.draft }, set: { store.editDraft($0, longPastesAsFiles: longPastesAsFiles) }),
                  prompt: Text(placeholder).foregroundStyle(AgentLandColor.textSecondary.color), axis: .vertical) { Text(placeholder) }
            // The composer is the field's frame; no second bezel on the Mac.
            .textFieldStyle(.plain)
            .font(.body)
            .lineLimit(1...(compact ? 6 : 10))
            .focused(focused)
            .disabled(!inputEnabled || store.phase == .deleted)
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .accessibilityIdentifier("chatDraft")
            .onKeyPress(keys: [.return], phases: .down) { press in
                // Hardware keyboards only: Return sends (or queues while the
                // agent works), ⇧Return and ⌥Return add a line, ⌘Return sends.
                if press.modifiers.contains(.shift) || press.modifiers.contains(.option) { return .ignored }
                submit()
                return .handled
            }
            #if os(macOS)
            .onPasteCommand(of: [.fileURL, .png, .jpeg, .tiff, .image]) { providers in paste(providers) }
            #endif
            .task(id: store.focusRequest) {
                guard inputEnabled, store.focusRequest != store.handledFocusRequest else { return }
                store.handledFocusRequest = store.focusRequest
                focused.wrappedValue = true
            }
    }

    private var toolbar: some View {
        HStack(spacing: 2) {
            HStack(spacing: 4) {
                attachMenu
                if typeSize.isAccessibilitySize && compact {
                    // At accessibility sizes on narrow screens the chips fold into one menu.
                    optionsMenu
                } else if store.isPlainChat {
                    // A plain chat has no mode: the model alone, scrolling sideways when its whole name doesn't fit.
                    chipRow { modelChip }
                } else {
                    // Whole names when they fit; then the mode as its symbol alone; as a last resort the row
                    // scrolls sideways. A chip's name is never cut short. No ViewThatFits: on iOS 27 the one here
                    // never finished its first layout on a physical iPhone (main thread at 95%, cover never lifted,
                    // 2026-10-07).
                    chipRow { HStack(spacing: 4) { modeChip(symbolOnly: wholeChipsWidth > chipRowWidth); modelChip } }
                        .background(alignment: .leading) {
                            // The whole names, measured unseen.
                            HStack(spacing: 4) {
                                Button {} label: { chip(symbol: modeSymbol, text: modeText) }.chatChipButton(compact: compact)
                                Button {} label: { chip(symbol: "cpu", text: modelText) }.chatChipButton(compact: compact)
                            }
                            .fixedSize()
                            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { wholeChipsWidth = $0 }
                            .hidden()
                            .accessibilityHidden(true)
                        }
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { chipRowWidth = $0 }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ChatDictationButton(dictation: dictation, draft: { store.draft }, update: { store.setDraft($0) })
                .disabled(!inputEnabled || store.sending)
            actionButtons
        }
    }

    @ViewBuilder private var actionButtons: some View {
        if store.isWorking {
            if store.canQueue && store.draftHasText {
                Button { Task { await store.queueDraft() } } label: {
                    Label("Queue", systemImage: "text.line.last.and.arrowtriangle.forward")
                        .labelStyle(.iconOnly)
                        .font(.body.weight(.semibold))
                        .frame(minWidth: ChatMetrics.target, minHeight: ChatMetrics.target)
                        .contentShape(Rectangle())
                }
                .chatBorderlessButton()
                .foregroundStyle(AgentLandColor.tint.color)
                .disabled(store.mutating || !store.attachments.isEmpty || !inputEnabled || !store.reachable)
                .help("Send when the agent is ready")
                .accessibilityLabel(store.attachments.isEmpty ? "Queue Message" : "Remove attachments to queue")
                .accessibilityIdentifier("chatQueueSend")
            }
            circleButton("Stop", symbol: "stop.fill", identifier: "chatStop", prominent: true) { Task { await store.stop() } }
                .disabled(!inputEnabled)
                .chatCommandShortcut(".", modifiers: .command)
        } else {
            let uploading = store.attachments.uploading
            circleButton(uploading ? "Uploading" : "Send", symbol: "arrow.up", identifier: "chatSend",
                         prominent: store.sendEnabled && inputEnabled, busy: uploading) { submit() }
                .disabled(!store.sendEnabled || !inputEnabled)
                .chatCommandShortcut(.return, modifiers: .command)
        }
    }

    private func circleButton(_ title: String, symbol: String, identifier: String, prominent: Bool, busy: Bool = false,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            #if os(iOS)
            Group {
                if busy { ProgressView().controlSize(.small) }
                else { Image(systemName: symbol).font(.body.weight(.semibold)) }
            }
            #else
            ZStack {
                // The prominent action (Send) is the design system's primary: onTint on the tint.
                Circle().fill(prominent ? AgentLandColor.tint.color : AgentLandColor.surface.color)
                if busy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: symbol)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(prominent ? AgentLandColor.onTint.color : AgentLandColor.textSecondary.color)
                }
            }
            .frame(width: min(circle, 56), height: min(circle, 56))
            .frame(minWidth: ChatMetrics.target, minHeight: ChatMetrics.target)
            .contentShape(Rectangle())
            #endif
        }
        // iOS owns Send’s press and disabled states; Mac retains its existing rendering.
        .buttonStyle(ChatSendButtonStyle())
        .accessibilityShowsLargeContentViewer { Label(title, systemImage: symbol) }
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
        .help(title)
    }

    /// Return and the Send button: sends, or queues while the agent works.
    private func submit() {
        guard inputEnabled else { return }
        if store.isWorking {
            guard store.canQueue, store.draftHasText, store.attachments.isEmpty else { return }
            Task { await store.queueDraft() }
            return
        }
        guard store.sendEnabled || !store.reachable else { return }
        dictation.stop()
        Task {
            await store.send()
            sent()
        }
    }

    private var attachMenu: some View {
        Menu {
            if store.canSendAttachments {
                Button("Photos", systemImage: "photo.on.rectangle", action: addPhotos)
                    .disabled(store.attachments.remaining == 0)
                    .accessibilityIdentifier("chatAttachPhotos")
                if let takePhoto {
                    Button("Camera", systemImage: "camera", action: takePhoto)
                        .disabled(store.attachments.remaining == 0)
                        .accessibilityIdentifier("chatAttachCamera")
                }
                Button("Files", systemImage: "doc", action: addFiles)
                    .disabled(store.attachments.remaining == 0)
                    .accessibilityIdentifier("chatAttachFiles")
                if let pasteImage {
                    Button("Paste Image", systemImage: "doc.on.clipboard", action: pasteImage)
                        .disabled(store.attachments.remaining == 0)
                }
            } else {
                Text("This Mac’s host does not take attachments.")
            }
        } label: {
            Image(systemName: "plus")
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(minWidth: ChatMetrics.target, minHeight: ChatMetrics.target)
                .contentShape(Rectangle())
        }
        .menuIndicator(.hidden)
        #if os(iOS)
        .menuStyle(.button)
        #endif
        .chatBorderlessButton()
        .disabled(!inputEnabled)
        .accessibilityLabel("Add Attachment")
        .accessibilityIdentifier("chatOptions")
    }

    /// The current mode, always visible: its symbol says whether the agent asks first.
    /// The chips scroll sideways when they don't fit.
    private func chipRow(@ViewBuilder _ chips: () -> some View) -> some View {
        ScrollView(.horizontal) { chips() }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    }

    private var modeSymbol: String { store.selectedModeChoice?.symbol ?? "slider.horizontal.3" }
    private var modeText: String { store.selectedModeChoice?.summary ?? "Default mode" }

    private func modeChip(symbolOnly: Bool) -> some View {
        Menu { modeItems } label: {
            chip(symbol: modeSymbol, text: modeText, symbolOnly: symbolOnly)
        }
        .menuIndicator(.hidden)
        .chatChipButton(compact: compact)
        .accessibilityShowsLargeContentViewer { Label(modeText, systemImage: modeSymbol) }
        .disabled(!inputEnabled || store.modeChoices.count < 2 || store.isWorking)
        .accessibilityLabel("Mode")
        .accessibilityValue(store.selectedModeChoice.map { "\($0.name), \($0.summary)" } ?? "Default")
        .accessibilityIdentifier("chatModeMenu")
        .chatModeConfirmation(store, origin: .composer)
    }

    /// One of several, the system's way: an inline picker checks the mode in use (CH-10), as the title menu's does.
    private var modeItems: some View {
        Picker(selection: Binding(get: { store.selectedModeChoice?.id ?? "" }, set: { store.selectMode($0, from: .composer) })) {
            ForEach(store.modeChoices) { choice in
                // A menu item's second text is its subtitle.
                VStack(alignment: .leading) {
                    Label(choice.name, systemImage: choice.symbol)
                    Text(choice.summary)
                }
                .accessibilityIdentifier(choice.id == "plan" ? "chatPlanToggle" : "chatMode-\(choice.id)")
                .tag(choice.id)
            }
        } label: { EmptyView() }
        .pickerStyle(.inline)
    }

    /// "Sonnet 4.5 · High"; the effort part only when the provider takes one. It opens the model menu
    /// (`ChatModelMenuContent`; owner's request, 2026-10-07).
    private var modelChip: some View {
        Menu { ChatModelMenuContent(store: store) } label: {
            chip(symbol: "cpu", text: modelText)
        }
        .menuIndicator(.hidden)
        // Written order: the composer sits at the bottom, and iOS would otherwise turn the menu over so the
        // models came last.
        .menuOrder(.fixed)
        .chatChipButton(compact: compact)
        .accessibilityShowsLargeContentViewer { Label(modelText, systemImage: "cpu") }
        .disabled(!inputEnabled)
        .keyboardShortcut("m", modifiers: [.command, .shift])
        .accessibilityLabel("Choose Model")
        .accessibilityValue(modelText)
        .accessibilityIdentifier("chatModelMenu")
    }

    private var modelText: String { store.modelMenuSummary }

    /// At accessibility text sizes the chips fold into one Options menu.
    private var optionsMenu: some View {
        Menu {
            if !store.isPlainChat { Section("Mode") { modeItems } }
            Menu { ChatModelMenuContent(store: store) } label: { Label("Model: \(modelText)", systemImage: "cpu") }
        } label: {
            // Only at accessibility sizes: the symbol, with the word in the
            // Large Content Viewer and for VoiceOver.
            Image(systemName: "slider.horizontal.3")
        }
        .menuIndicator(.hidden)
        .menuOrder(.fixed)
        .chatChipButton(compact: compact)
        .accessibilityLabel("Options")
        .accessibilityShowsLargeContentViewer { Label("Options", systemImage: "slider.horizontal.3") }
        .disabled(!inputEnabled)
        .accessibilityIdentifier("chatComposerOptions")
        .chatModeConfirmation(store, origin: .composer)
    }

    /// One line at its full width; the Large Content Viewer shows the chip
    /// when text is large.
    private func chip(symbol: String, text: String, symbolOnly: Bool = false) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
            if !symbolOnly {
                Text(text).lineLimit(1).fixedSize()
            }
            if !compact {
                Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).accessibilityHidden(true)
            }
        }
    }

    #if os(macOS)
    private func paste(_ providers: [NSItemProvider]) {
        ChatAttachmentLoader.load(providers, into: store)
    }
    #endif
}

/// Composer chips: a capsule with a symbol and one line of text. A disabled
/// chip keeps readable muted text rather than fading out.
private extension View {
    @ViewBuilder func chatChipButton(compact: Bool) -> some View {
        #if os(iOS)
        self.menuStyle(.button)
            .buttonStyle(.bordered)
            .controlSize(.large)
            .font(.footnote.weight(.medium))
        #else
        self.buttonStyle(MacChatChipButtonStyle(compact: compact))
        #endif
    }
}

private struct MacChatChipButtonStyle: ButtonStyle {
    let compact: Bool
    func makeBody(configuration: Configuration) -> some View {
        ChatChipBody(configuration: configuration, compact: compact)
    }
}

/// Send and Stop: on iOS and iPad the system's prominent glass button in a circle, in the accent (CH-08).
private struct ChatSendButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        #if os(iOS)
        Button(configuration).buttonStyle(.glassProminent).buttonBorderShape(.circle).controlSize(.large)
            .minimumTapTarget(.reserveSpace)
        #else
        Button(configuration).buttonStyle(ChatUndimmedButtonStyle())
        #endif
    }
}

private struct ChatChipBody: View {
    let configuration: ButtonStyle.Configuration
    let compact: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(.footnote.weight(.medium))
            .foregroundStyle(isEnabled ? AgentLandColor.text.color : AgentLandColor.textSecondary.color)
            .padding(.horizontal, compact ? 8 : 10)
            .padding(.vertical, 6)
            .background(AgentLandColor.surface.color, in: Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
            .frame(minHeight: ChatMetrics.target)
            .contentShape(Rectangle())
    }
}

/// Loads dropped or pasted items as attachments.
enum ChatAttachmentLoader {
    @MainActor static func load(_ providers: [NSItemProvider], into store: ChatSessionStore) {
        guard store.canSendAttachments else {
            store.report("This Mac’s host does not take attachments.")
            return
        }
        for provider in providers.prefix(store.attachments.remaining) {
            if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in await prepare(url: url, store: store) }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data else { return }
                    Task { @MainActor in await prepare(data: data, name: "Pasted image", type: .image, store: store) }
                }
            }
        }
    }

    @MainActor static func prepare(url: URL, store: ChatSessionStore) async {
        do {
            let prepared = try await Task.detached { try ChatAttachmentPolicy.prepare(fileAt: url) }.value
            store.attach(prepared)
        } catch { store.report(error.localizedDescription) }
    }

    @MainActor static func prepare(data: Data, name: String, type: UTType?, store: ChatSessionStore) async {
        do {
            // Re-encoding a full-size photo is too slow for the main thread.
            let prepared = try await Task.detached { try ChatAttachmentPolicy.prepare(name: name, data: data, type: type) }.value
            store.attach(prepared)
        } catch { store.report(error.localizedDescription) }
    }
}

/// Continue with Another Model: a new chat, of any installed provider,
/// seeded from this one. Nothing is sent until the person sends a message.
/// A plain chat continues into another plain chat: the sheet offers
/// OpenCode's models alone, with no agent, mode or effort to choose. A
/// read-only Chats-space chat continues into a Claude Code or Codex chat of
/// the workspace in use ("Continue in my-app").
public struct ChatContinueSheet: View {
    let store: ChatSessionStore
    let providers: [AgentProvider]
    @Environment(\.dismiss) private var dismiss
    @State private var provider: AgentProvider = .opencode
    @State private var options: ChatOptionsResponse?
    @State private var model = ""
    @State private var mode = ""
    @State private var effort = ""
    @State private var loading = false
    @State private var working = false

    public init(store: ChatSessionStore, providers: [AgentProvider]) {
        self.store = store
        self.providers = providers
    }

    public var body: some View {
        NavigationStack {
            AgentLandForm {
                Section {
                    if !plain {
                        Picker("Agent", selection: $provider) {
                            ForEach(providers) { Text($0.displayName).tag($0) }
                        }
                        .accessibilityIdentifier("chatContinueProvider")
                    }
                    if loading {
                        ProgressView()
                    } else if let options {
                        Picker("Model", selection: $model) {
                            ForEach(options.models) { Text($0.name).tag($0.id) }
                        }
                        .accessibilityIdentifier("chatContinueModel")
                        let modes = Self.modes(options, provider: provider, plain: plain)
                        if modes.count > 1 {
                            Picker("Mode", selection: $mode) {
                                ForEach(modes, id: \.self) { id in
                                    Text(ChatModeChoice.make(id: id, name: options.modes?.first { $0.id == id }?.name, sentAsMode: true,
                                                             provider: provider).name).tag(id)
                                }
                            }
                        }
                        let efforts = Self.efforts(options, model: model, provider: provider, plain: suppressConversationEffort)
                        if !efforts.isEmpty {
                            Picker("Effort", selection: $effort) {
                                ForEach(efforts, id: \.self) { Text($0.capitalized).tag($0) }
                            }
                        }
                    } else {
                        Text("This agent’s models could not be read.").foregroundStyle(AgentLandColor.textSecondary.color)
                    }
                } footer: {
                    // The explanation as the section's footer, in the system's own footer style (CH-24).
                    Text(footer)
                }
            }
            #if os(iOS)
            // The sheet's raised paper or slate behind paper or slate rows (2026-10-07).
            .listPageBackground()
            #endif
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Continue") {
                        working = true
                        Task {
                            let created = await store.continueChat(provider: provider, model: model.isEmpty ? nil : model,
                                                                   mode: mode.isEmpty ? nil : mode, effort: effort.isEmpty ? nil : effort)
                            working = false
                            if created { dismiss() }
                        }
                    }
                    .disabled(working || loading || options == nil || (store.isReadOnly && store.continueWorkspace == nil))
                    .accessibilityIdentifier("chatContinueStart")
                }
            }
            .task(id: provider) {
                loading = true
                let loaded = await store.options(for: provider)
                options = loaded
                model = loaded?.defaultModel ?? ""
                mode = Self.initialMode(loaded, provider: provider, plain: plain)
                effort = Self.initialEffort(loaded, model: model, provider: provider, plain: suppressConversationEffort)
                loading = false
            }
        }
        .frame(minWidth: 360, minHeight: 360)
        .onAppear { if let first = providers.first, !providers.contains(provider) { provider = first } }
    }

    /// The chat continued is a plain chat: the new one is a plain chat too. A read-only one continues into a workspace.
    private var plain: Bool { store.isPlainChat && !store.isReadOnly }

    private var title: String {
        guard store.isReadOnly else { return "Continue with Another Model" }
        return store.continueWorkspace.map { "Continue in \($0.name)" } ?? "Continue in a Workspace"
    }

    private var footer: String {
        guard store.isReadOnly else {
            return "The new chat starts with this conversation as context. Nothing is sent until you send a message."
        }
        guard let workspace = store.continueWorkspace else { return "Open a workspace to continue this chat there." }
        return "A new chat in \(workspace.name) starts with this conversation as context. Nothing is sent until you send a message."
    }
    private var suppressConversationEffort: Bool {
        plain && store.capabilities?.plainChats?.availableProviders.first(where: { $0.id == provider.id })?.features.contains("effort") != true
    }

    // What the sheet offers for a new chat of `provider` (docs/HOST-API.md "Continue with another model"):
    // an ACP agent's new chat lists no modes yet and takes no mode or effort, so it gets neither picker; nor
    // does a plain chat's (docs/HOST-API.md "Plain chats"). A mode that runs without asking is left out: the new
    // chat asks before it first enters one.

    static func modes(_ options: ChatOptionsResponse, provider: AgentProvider, plain: Bool = false) -> [String] {
        guard provider.continueTakesModeAndEffort, !plain else { return [] }
        return (options.modes.map { $0.map(\.id) } ?? options.agents).filter {
            ChatModeChoice.make(id: $0, name: nil, sentAsMode: true, provider: provider).confirmation == nil
        }
    }

    static func initialMode(_ options: ChatOptionsResponse?, provider: AgentProvider, plain: Bool = false) -> String {
        guard provider.continueTakesModeAndEffort, !plain else { return "" }
        return options?.defaultMode ?? options?.agents.first ?? ""
    }

    static func efforts(_ options: ChatOptionsResponse, model: String, provider: AgentProvider, plain: Bool = false) -> [String] {
        guard provider.continueTakesModeAndEffort, !plain else { return [] }
        return options.models.first { $0.id == model }?.efforts ?? []
    }

    static func initialEffort(_ options: ChatOptionsResponse?, model: String, provider: AgentProvider, plain: Bool = false) -> String {
        guard provider.continueTakesModeAndEffort, !plain else { return "" }
        return options?.models.first { $0.id == model }?.defaultEffort ?? ""
    }
}
