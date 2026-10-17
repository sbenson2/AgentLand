import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import AgentLandBranding
import AgentLandDesign
import AgentLandCore
#if canImport(UIKit)
import UIKit
import GameController
#endif

/// The chat: one implementation for iPhone, iPad and Mac. It is
/// self-contained: the app gives it a store (owned by the app model),
/// whether input is allowed right now, and a landing for an empty chat. The landing shows above the composer, which
/// stays in use, until the first message is on its way; a plain chat and an
/// agent's chat open alike.
public struct ChatScreen<Landing: View>: View {
    let store: ChatSessionStore
    let inputEnabled: Bool
    let landing: () -> Landing

    /// The chat has no header of its own: the apps show its title, subtitle and actions in their navigation bar
    /// (`ChatTitleMenuItems`). The chat's own header bar, never shown, went with the native-iOS pass (CH-25).
    public init(store: ChatSessionStore, inputEnabled: Bool, @ViewBuilder landing: @escaping () -> Landing) {
        self.store = store; self.inputEnabled = inputEnabled; self.landing = landing
    }

    public var body: some View {
        Group {
            if store.phase == .deleted {
                ContentUnavailableView("This chat was deleted.", systemImage: "trash",
                                       description: Text("It was removed on another device. Close this tab to continue."))
                    .accessibilityIdentifier("chatDeleted")
            } else if case let .unavailable(message) = store.phase, !store.hasContent {
                ContentUnavailableView {
                    Label("Chat Unavailable", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") { store.refreshStatus() }.accessibilityIdentifier("chatTryAgain")
                }
                .accessibilityIdentifier("chatUnavailable")
            } else if !store.hasContent && store.pendingSends.isEmpty && !store.composerRevealed {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("chatLoading")
            } else {
                // One conversation view for the landing and the transcript, so the composer keeps its text and
                // focus when the first message goes.
                ChatConversation(store: store, inputEnabled: inputEnabled, emptyLanding: { AnyView(landing()) })
            }
        }
        .background(AgentLandColor.canvas.color)
    }
}

private enum ChatDisplayRow: Identifiable {
    case row(ChatRow)
    case pending(PendingSend)
    case placeholder
    case interaction(ChatInteraction)

    var id: String {
        switch self {
        case let .row(row): row.id
        case let .pending(pending): "pending-" + pending.id.uuidString
        case .placeholder: "placeholder"
        case let .interaction(interaction): "interaction-" + interaction.id
        }
    }
}

struct ChatConversation: View {
    let store: ChatSessionStore
    let inputEnabled: Bool
    /// The landing, shown in place of the transcript while the chat is empty (`showsLanding`).
    var emptyLanding: (() -> AnyView)? = nil

    // Scrolls by row identity only: an edge-based position snaps the
    // centered column sideways on iOS.
    @State private var position = ScrollPosition(idType: String.self)
    /// Bumped by a new text size: the transcript is built again (see `relayout`).
    @State private var layoutGeneration = 0
    @State private var following = true
    /// More than a screen from the end (`ChatScrollPlace`): Jump to Latest shows while not following.
    @State private var screenAway = false
    @State private var userScrolling = false
    @State private var newActivity = false
    /// The transcript's frames and the cards in view, decided after each layout (`ChatTranscriptGeometry`).
    @State private var geometry = ChatTranscriptGeometry()
    @State private var columnWidth: CGFloat = 600
    @State private var rewindCandidate: String?
    @State private var confirmingRunAgain = false
    @State private var sendAgainCandidate: PendingSend?
    @State private var showsContinue = false
    @State private var showsPhotos = false
    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var showsFiles = false
    @State private var showsCamera = false
    /// The composer had the keyboard when a picker opened (`openPicker`); it takes it back when the picker goes.
    @State private var refocusAfterPicker = false
    @State private var dropTargeted = false
    @State private var earlierAnchor: String?
    @FocusState private var composerFocused: Bool
    @Namespace private var rotor
    // Settings → Chat (iPhone and iPad); the defaults keep the chat as it was.
    @AppStorage(ChatSettings.expandDetailsKey) private var expandsDetails = ChatSettings.expandDetailsDefault
    @AppStorage(ChatSettings.sendHapticKey) private var sendHaptic = ChatSettings.sendHapticDefault
    @ScaledMetric(relativeTo: .body) private var maximumColumn: CGFloat = 720
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    private var regular: Bool {
        #if os(iOS)
        sizeClass == .regular
        #else
        true
        #endif
    }

    private var bubbleWidth: CGFloat {
        let fraction: CGFloat = typeSize.isAccessibilitySize ? 0.9 : (regular ? 0.7 : 0.8)
        return max(160, columnWidth * fraction)
    }

    /// The host still runs the chat's agent: it lists it in `chatProviders`, as a chat agent of its catalog, or among
    /// its workspace chats' providers (signed in or not).
    private var providerInstalled: Bool {
        guard let capabilities = store.capabilities else { return true }
        let id = store.provider.id
        return capabilities.chatProviders.contains(id)
            || capabilities.agentCatalog?.contains { $0.id == id && $0.chat } == true
            || capabilities.workspaceChats.map { chats in (chats.providers + chats.unavailableProviders).contains { $0.id == id } } == true
    }

    var body: some View {
        scrollFollowing(presentations(layout))
            .task { focusOnOpen() }
            .background { shortcuts }
            .environment(\.chatExpandsDetails, expandsDetails)
    }

    private var layout: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                if let emptyLanding, store.showsLanding {
                    emptyLanding()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    transcript.id(layoutGeneration)
                }
                floatingControls
            }
            // Frames go to `geometry`, not to the view's state: writing them evaluated the conversation again at every
            // frame of the keyboard.
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { geometry.transcriptFrame = $0 }
            #if os(iOS)
            // The system's bar on the bottom edge, so the transcript's scroll edge effect runs under the composer (CH-02).
            .safeAreaBar(edge: .bottom, spacing: 0) { measuredBottomArea }
            #else
            .safeAreaInset(edge: .bottom, spacing: 0) { measuredBottomArea }
            #endif
        }
        .background(AgentLandColor.canvas.color)
        .onDrop(of: [.fileURL, .image], isTargeted: $dropTargeted) { providers in
            guard inputEnabled, store.canSendAttachments else { return false }
            ChatAttachmentLoader.load(providers, into: store)
            return true
        }
    }

    /// The composer and what sits on it, its top edge kept for the cards it may cover.
    private var measuredBottomArea: some View {
        bottomArea
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { geometry.composerTop = $0 }
    }

    /// Sheets and pickers. The confirmations are on the rows they act on (`rowQuestions`).
    private func presentations(_ content: some View) -> some View {
        content
        .sheet(isPresented: $showsContinue) {
            ChatContinueSheet(store: store, providers: store.continueProviders)
                .agentLandSheetPage()
        }
        .photosPicker(isPresented: $showsPhotos, selection: $photoSelection, maxSelectionCount: max(1, store.attachments.remaining),
                      matching: .images)
        .onChange(of: photoSelection) { _, items in
            guard !items.isEmpty else { return }
            photoSelection = []
            Task { await addPhotos(items) }
        }
        .fileImporter(isPresented: $showsFiles, allowedContentTypes: store.allowedAttachmentMIMEs.map { $0.compactMap { UTType(mimeType: $0) } } ?? [.image, .pdf, .text, .sourceCode, .json, .commaSeparatedText, .data],
                      allowsMultipleSelection: true) { result in
            switch result {
            case let .success(urls):
                for url in urls.prefix(store.attachments.remaining) {
                    Task { await ChatAttachmentLoader.prepare(url: url, store: store) }
                }
            case let .failure(error):
                store.report(error.localizedDescription)
            }
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $showsCamera) {
            ChatCameraPicker { data in
                showsCamera = false
                if let data { Task { await ChatAttachmentLoader.prepare(data: data, name: "Photo.jpg", type: .jpeg, store: store) } }
            }
            .ignoresSafeArea()
        }
        .onChange(of: showsPhotos || showsFiles || showsCamera) { _, shown in
            guard !shown, refocusAfterPicker else { return }
            refocusAfterPicker = false
            composerFocused = true
        }
        .sensoryFeedback(.impact(weight: .light), trigger: store.sendCount) { _, _ in sendHaptic }
        .sensoryFeedback(.warning, trigger: store.approvalArrivals) { _, _ in store.active }
        #endif
    }

    /// Keeps the latest row in view while following.
    private func scrollFollowing(_ content: some View) -> some View {
        content
        .onChange(of: store.sendCount) { _, _ in follow(animated: false) }
        .onChange(of: store.activityCount) { _, _ in
            // While following, new rows, text and cards keep the bottom in
            // view; otherwise the Jump button gets its dot.
            if following { scrollToLatest() } else { newActivity = true }
        }
        .onChange(of: store.interactions.count) { _, _ in if following { scrollToLatest() } }
        // A new text size re-flows every row (see `relayout`); so does a new width, and the latest row stays in view.
        .onChange(of: typeSize) { _, _ in relayout() }
        #if os(iOS)
        // Also a change of the reader's setting that leaves this view's size as it is (the app caps its step at
        // xxxLarge, so xxLarge and xxxLarge both show at xxxLarge).
        .onReceive(NotificationCenter.default.publisher(for: UIContentSizeCategory.didChangeNotification)) { _ in relayout() }
        #endif
        .onChange(of: columnWidth) { _, _ in if following { scrollToLatest() } }
        .onChange(of: store.phase) { _, phase in if phase == .ready, store.pendingSends.isEmpty { following = true } }
    }

    // MARK: Transcript

    private var displayRows: [ChatDisplayRow] {
        var rows = store.projection.rows.map(ChatDisplayRow.row)
        rows += store.pendingSends.map(ChatDisplayRow.pending)
        let waitingOnUser: Bool = {
            if !store.pendingSends.isEmpty {
                return store.pendingSends.contains {
                    if case .notSent = $0.delivery { return false }
                    return $0.delivery != .notConfirmed
                }
            }
            if case .user = store.projection.rows.last { return store.isWorking }
            return false
        }()
        if waitingOnUser { rows.append(.placeholder) }
        rows += store.interactions.map(ChatDisplayRow.interaction)
        return rows
    }

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                ForEach(displayRows) { row in
                    // Each row spans the scroll view and centers the column
                    // inside itself. Scrolling to a row then never needs a
                    // sideways offset, whatever anchor or text size; and a
                    // row that asks for more width (a long unbroken line)
                    // cannot widen the column.
                    rowView(row)
                        .frame(width: columnWidth, alignment: .leading)
                        .frame(maxWidth: .infinity)
                        .id(row.id)
                        // Which rows are on screen, for the row at the top (`relayout`).
                        .onScrollVisibilityChange(threshold: 0.01) { visible in geometry.rowVisibility(row.id, visible: visible) }
                }
            }
            // No `scrollTargetLayout`: with a row taller than the screen, the lazy transcript's rows as scroll targets
            // were laid out without end on iPhone, as the keyboard left or the text size changed (the app froze). Rows
            // are scrolled to by their `id`; the row at the top comes from the rows' visibility.
            .padding(.top, 16)
            .padding(.bottom, 12)
            // The width the scroll view gives its content: inside the safe area. (The container's width,
            // `containerRelativeFrame`, includes the area under an iPad's floating sidebar; the transcript
            // then asked for more than the detail column and pushed the whole chat under the sidebar.)
            .frame(maxWidth: .infinity)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            columnWidth = max(0, min(maximumColumn, width - 32))
        }
        .scrollPosition($position)
        // Leading anchors: resizing content never moves it sideways.
        .defaultScrollAnchor(.bottomLeading, for: .initialOffset)
        .defaultScrollAnchor(following ? .bottomLeading : .topLeading, for: .sizeChanges)
        .defaultScrollAnchor(.topLeading, for: .alignment)
        #if os(iOS)
        .scrollDismissesKeyboard(.interactively)
        #endif
        // The place, not its distances: the action runs where the view acts differently, not at every point of scrolling
        // or passing position of a layout pass; and it writes only what changed.
        .onScrollGeometryChange(for: ChatScrollPlace.self) { ChatScrollPlace($0) } action: { _, place in
            geometry.place = place
            // Only the person's own scrolling turns following off; content
            // growth, disclosures and the keyboard never do.
            if userScrolling, following != place.atEnd { following = place.atEnd }
            if following, newActivity { newActivity = false }
            if screenAway != place.screenAway { screenAway = place.screenAway }
            // A view that grew past the end (the keyboard went away) settles
            // on the latest row, rather than leaving a gap that swallows the
            // next tap as a scroll: once the layout is done, and only if the
            // place it ended at is still past the end.
            if !userScrolling, place.pastEnd {
                geometry.afterLayout { place in
                    guard !userScrolling, place?.pastEnd == true else { return }
                    following = true
                    scrollToLatest()
                }
            }
        }
        .onScrollPhaseChange { _, phase in
            userScrolling = phase == .interacting || phase == .tracking || phase == .decelerating
        }
        .accessibilityRotor("Replies") {
            // Replies picked out first: an `if` inside the rotor's ForEach needs iOS 27's Optional rotor content.
            ForEach(store.projection.rows.compactMap { row -> ChatReplyModel? in
                if case let .reply(reply) = row { reply } else { nil }
            }, id: \.id) { reply in
                AccessibilityRotorEntry("\(store.provider.chatDisplayName) reply", id: reply.id, in: rotor)
            }
        }
        .accessibilityIdentifier("chatTranscript")
    }

    @ViewBuilder private func rowView(_ row: ChatDisplayRow) -> some View {
        switch row {
        case let .row(row):
            switch row {
            case .earlier:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading earlier messages").font(.footnote).foregroundStyle(AgentLandColor.textSecondary.color)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("chatLoadingEarlier")
                .onAppear { loadEarlier() }
            case let .user(message):
                ChatUserRow(message: message, store: store, maxWidth: bubbleWidth, actions: actions)
                    .modifier(rewindQuestion(message.id))
            case let .context(message):
                ChatContextRow(message: message, store: store)
            case let .reply(reply):
                ChatReplyView(reply: reply, store: store, actions: actions, rotor: rotor)
                    .modifier(runAgainQuestion(reply))
            }
        case let .pending(pending):
            ChatPendingRow(pending: pending, store: store, maxWidth: bubbleWidth, actions: actions)
                .modifier(sendAgainQuestion(pending))
        case .placeholder:
            ChatStatusLine(store: store)
        case let .interaction(interaction):
            Group {
                if interaction.kind == .permission {
                    ChatApprovalCard(interaction: interaction, store: store, isFirst: interaction.id == store.interactions.first?.id)
                } else {
                    ChatQuestionCard(interaction: interaction, store: store, shortcutEnabled: inputEnabled)
                }
            }
            // In view means its bottom edge, where the buttons are, is above
            // the composer; a card half under the composer still gets the pill.
            // Decided after the layout (`ChatTranscriptGeometry`), never from a
            // position the layout passes through.
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                geometry.cardMoved(interaction.id, to: frame)
            }
            .onDisappear { geometry.cardGone(interaction.id) }
        }
    }

    // MARK: Row questions

    // Each confirmation is on the row it acts on, so on iPhone and iPad its popover points at that message (owner,
    // 2026-10-08; `DialogAnchor`), and only that row presents it.

    /// Edit and Resend's question, beside the message it goes back to.
    private func rewindQuestion(_ messageID: String) -> ChatRowQuestion {
        ChatRowQuestion(title: ChatRewindCopy.title, shown: Binding(get: { rewindCandidate == messageID },
                                                                    set: { if !$0, rewindCandidate == messageID { rewindCandidate = nil } })) {
            Button(ChatRewindCopy.confirm, role: .destructive) {
                following = true
                Task { await store.rewind(to: messageID) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(ChatRewindCopy.message(provider: store.provider, restoresFiles: store.rewindRestoresFiles))
        }
    }

    /// Run Again's question, beside the latest reply whose Run Again asked it.
    private func runAgainQuestion(_ reply: ChatReplyModel) -> ChatRowQuestion {
        ChatRowQuestion(title: "Run the latest prompt again?", shown: Binding(get: { confirmingRunAgain && reply.isLatest },
                                                                             set: { if !$0 { confirmingRunAgain = false } })) {
            Button("Run Again") {
                following = true
                Task { await store.runAgain() }
            }
            .accessibilityIdentifier("chatConfirmRunAgain")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(store.runAgainConfirmation)
        }
    }

    /// Send Again's question for a message whose delivery is not confirmed, beside that message.
    private func sendAgainQuestion(_ pending: PendingSend) -> ChatRowQuestion {
        ChatRowQuestion(title: "Send this message again?", shown: Binding(get: { sendAgainCandidate?.id == pending.id },
                                                                          set: { if !$0, sendAgainCandidate?.id == pending.id { sendAgainCandidate = nil } })) {
            Button("Send Again") {
                following = true
                Task { await store.sendAgain(pending.id) }
            }
            .accessibilityIdentifier("chatConfirmSendAgain")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("If the first try reached your Mac, the agent could get this message twice.")
        }
    }

    private var actions: ChatRowActions {
        ChatRowActions(
            editAndResend: { id in rewindCandidate = id },
            runAgain: { confirmingRunAgain = true },
            fork: { id in Task { await store.fork(from: id) } },
            continueWithAnotherModel: { showsContinue = true },
            sendAgain: { pending in
                if pending.delivery == .notConfirmed { sendAgainCandidate = pending } else { Task { await store.sendAgain(pending.id) } }
            })
    }

    private func loadEarlier() {
        guard !store.loadingEarlier else { return }
        let anchor = store.projection.rows.first { if case .earlier = $0 { return false } else { return true } }?.id
        Task {
            await store.loadEarlier()
            // Keep the message that was first on screen where it was.
            if let anchor { position.scrollTo(id: anchor, anchor: .top) }
        }
    }

    // MARK: Floating controls

    private var pendingOffscreen: ChatInteraction? {
        store.interactions.first { !geometry.visibleCards.contains($0.id) }
    }

    private var showsJump: Bool { !following && screenAway }

    private var floatingControls: some View {
        floatingGlass {
            floatingStack
        }
        .padding(.bottom, 12)
        .animation(AgentLandMotion.smooth.animation(reduceMotion: reduceMotion, reducedMotion: .none), value: showsJump)
        .animation(AgentLandMotion.smooth.animation(reduceMotion: reduceMotion, reducedMotion: .none), value: pendingOffscreen?.id)
    }

    /// The pill and Jump to Latest share one glass container on iOS and iPad (CH-15); closer than 4 pt they would blend.
    @ViewBuilder private func floatingGlass(@ViewBuilder _ content: () -> some View) -> some View {
        #if os(iOS)
        GlassEffectContainer(spacing: 4) { content() }
        #else
        content()
        #endif
    }

    private var floatingStack: some View {
        VStack(spacing: 8) {
            if let pending = pendingOffscreen {
                ChatNeedsYouPill(interaction: pending, provider: store.provider) {
                    withAnimation(AgentLandMotion.smooth.animation(reduceMotion: reduceMotion, reducedMotion: .none)) {
                        // Its foot (its buttons) just above the composer: the transcript runs on under the composer's
                        // glass, where a card shows but takes no taps, and a centred tall card ended there.
                        position.scrollTo(id: "interaction-" + pending.id, anchor: .bottom)
                    }
                }
                .transition(reduceMotion ? .identity : .opacity)
            }
            if showsJump {
                ChatJumpButton(newActivity: newActivity) { follow(animated: true) }
                    .transition(reduceMotion ? .identity : .opacity)
            }
        }
    }

    /// A new text size: the transcript is built again, then shows the latest row while following, or the row that
    /// was at the top. Re-flowed in place, the lazy rows could keep their old heights and leave the transcript
    /// blank until it was built again (seen under Xcode's accessibility audit, which changes the text size in place).
    private func relayout() {
        let top = following ? nil : geometry.firstVisibleRow(in: displayRows.map(\.id))
        layoutGeneration &+= 1
        Task { @MainActor in
            // Once the new scroll view is in place.
            await Task.yield()
            if let top { position.scrollTo(id: top, anchor: .top) } else { scrollToLatest() }
        }
    }

    /// The bottom of the transcript: the last row's bottom edge.
    private func scrollToLatest() {
        guard let last = displayRows.last?.id else { return }
        position.scrollTo(id: last, anchor: .bottom)
    }

    private func follow(animated: Bool) {
        following = true
        newActivity = false
        if animated && !reduceMotion {
            withAnimation(AgentLandMotion.smooth.animation(reduceMotion: reduceMotion)) { scrollToLatest() }
        } else {
            scrollToLatest()
        }
    }

    // MARK: Composer area

    private var bottomArea: some View {
        VStack(spacing: 6) {
            if !store.reachable {
                Label("Offline · your draft is kept", systemImage: "wifi.slash")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(AgentLandColor.textSecondary.color)
                    .accessibilityIdentifier("chatOfflineNote")
            }
            if let signIn = store.signIn {
                ChatSignInNotice(signIn: signIn, store: store, inputEnabled: inputEnabled)
            }
            if let notice = store.notice {
                ChatNoticeBanner(notice: notice, store: store)
            }
            if store.isReadOnly {
                // A Chats-space chat whose agent runs only in the workspaces now: readable, with Continue in the
                // workspace in use in place of the composer.
                ChatReadOnlyNotice(store: store, inputEnabled: inputEnabled) { showsContinue = true }
            } else if providerInstalled {
                ChatComposer(store: store, inputEnabled: inputEnabled && store.phase != .deleted, focused: $composerFocused,
                             dropTargeted: dropTargeted,
                             addFiles: { openPicker { showsFiles = true } }, addPhotos: { openPicker { showsPhotos = true } },
                             takePhoto: cameraAvailable ? { openPicker { showsCamera = true } } : nil,
                             pasteImage: pasteboardHasImage ? { pasteImage() } : nil,
                             sent: { follow(animated: false) })
            } else {
                Label("\(store.provider.chatDisplayName) isn’t available on your Mac.", systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(AgentLandColor.textSecondary.color)
                    .padding()
                    .accessibilityIdentifier("chatProviderMissing")
            }
        }
        .frame(maxWidth: maximumColumn)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
    }

    private var cameraAvailable: Bool {
        #if os(iOS)
        UIImagePickerController.isSourceTypeAvailable(.camera)
        #else
        false
        #endif
    }

    private var pasteboardHasImage: Bool {
        #if os(iOS)
        UIPasteboard.general.hasImages
        #else
        false
        #endif
    }

    private func pasteImage() {
        #if os(iOS)
        guard let image = UIPasteboard.general.image, let data = image.pngData() else { return }
        Task { await ChatAttachmentLoader.prepare(data: data, name: "Pasted image.png", type: .png, store: store) }
        #endif
    }

    private func addPhotos(_ items: [PhotosPickerItem]) async {
        for (index, item) in items.enumerated() where store.attachments.remaining > 0 {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else { continue }
                let type = item.supportedContentTypes.first
                await ChatAttachmentLoader.prepare(data: data, name: "Photo \(index + 1)." + (type?.preferredFilenameExtension ?? "jpg"),
                                                   type: type, store: store)
            } catch {
                store.report(error.localizedDescription)
            }
        }
    }

    /// Photos and Files run in their own process: the composer they covered stayed focused without its keyboard once
    /// they went, so a tap on it showed only Paste and typing reached nothing (script chats, run final; batch 14). On
    /// iPhone and iPad the composer lets go of the keyboard as a picker opens and takes it back when the picker goes.
    private func openPicker(_ open: () -> Void) {
        #if os(iOS)
        refocusAfterPicker = composerFocused
        composerFocused = false
        #endif
        open()
    }

    /// Mac, and iPad with a hardware keyboard: the composer takes focus on
    /// open. iPhone never raises the keyboard just because a chat opened.
    private func focusOnOpen() {
        guard inputEnabled, store.composerRevealed || store.hasContent else { return }
        #if os(macOS)
        composerFocused = true
        #else
        if regular, GCKeyboard.coalesced != nil { composerFocused = true }
        #endif
    }

    // MARK: Keyboard

    /// Commands without a visible button of their own.
    private var shortcuts: some View {
        Group {
            Button("Jump to Latest") { follow(animated: true) }
                .keyboardShortcut(.downArrow, modifiers: .command)
            Button("Jump to Top") {
                following = false
                if let first = displayRows.first?.id { position.scrollTo(id: first, anchor: .top) }
            }
            .keyboardShortcut(.upArrow, modifiers: .command)
            Button("Copy Latest Reply") {
                if let reply = store.projection.latestReply { ChatClipboard.copy(reply.plainText) }
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            Button("Focus Composer") { composerFocused = true }
                .keyboardShortcut("l", modifiers: .command)
            Button("Add Attachment") { if store.canSendAttachments { openPicker { showsFiles = true } } }
                .keyboardShortcut("a", modifiers: [.command, .shift])
            if store.isWorking {
                Button("Stop") { Task { await store.stop() } }
                    .keyboardShortcut(.escape, modifiers: [])
            }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
        .disabled(!inputEnabled)
    }
}

/// Jump to Latest: a small glass circle above the composer, with an accent
/// dot when something new arrived below.
struct ChatJumpButton: View {
    let newActivity: Bool
    let action: () -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        #if os(iOS)
        // The system's glass button in a circle (CH-15), the dot on its edge.
        Button(action: action) {
            Image(systemName: "arrow.down")
                .font(.body.weight(.semibold))
                .foregroundStyle(AgentLandColor.text.color)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .minimumTapTarget(.reserveSpace)
        .overlay(alignment: .topTrailing) { dot }
        .modifier(JumpAccessibility(newActivity: newActivity))
        #else
        Button(action: action) {
            Image(systemName: "arrow.down")
                .font(.body.weight(.semibold))
                .foregroundStyle(AgentLandColor.text.color)
                .frame(width: 36, height: 36)
                .chatFloatingSurface(Circle(), reduceTransparency: reduceTransparency, increasedContrast: contrast == .increased,
                                     interactive: true)
                .overlay(alignment: .topTrailing) { dot }
                .frame(minWidth: ChatMetrics.target, minHeight: ChatMetrics.target)
                .contentShape(Rectangle())
        }
        .agentLandControlButton()
        .modifier(JumpAccessibility(newActivity: newActivity))
        #endif
    }

    /// Something new arrived below.
    @ViewBuilder private var dot: some View {
        if newActivity {
            Circle().fill(AgentLandColor.tint.color).frame(width: 10, height: 10).offset(x: 1, y: -1)
                .accessibilityHidden(true)
        }
    }
}

private struct JumpAccessibility: ViewModifier {
    let newActivity: Bool

    func body(content: Content) -> some View {
        content
            .accessibilityLabel("Jump to Latest")
            .accessibilityValue(newActivity ? "New activity" : "")
            .accessibilityIdentifier("chatJumpToLatest")
            .help("Jump to Latest")
    }
}

/// An inline notice on the composer; chat problems never become toasts.
struct ChatNoticeBanner: View {
    let notice: ChatNotice
    let store: ChatSessionStore

    // The app's one floating notice over the composer, as the sign-in notice is (CH-16): the reason, Refresh Status
    // for a change whose delivery is uncertain (never sending again by itself), and Dismiss.
    var body: some View {
        InlineNotice(notice.message, tone: .warning,
                     actionTitle: notice.action == .refreshStatus ? "Refresh Status" : nil,
                     action: notice.action == .refreshStatus ? { store.refreshStatus() } : nil,
                     onDismiss: { store.dismissNotice() },
                     identifiers: .init(text: "chatNotice", action: "chatRefreshStatus", dismiss: "chatNoticeDismiss"))
    }
}

/// A read-only Chats-space chat (`ChatSessionStore.isReadOnly`): why there is no composer, in the host's words, and
/// Continue in the workspace in use, which opens the Continue sheet (nothing is sent until the person sends there).
/// Without a workspace in use it says to open one.
struct ChatReadOnlyNotice: View {
    let store: ChatSessionStore
    let inputEnabled: Bool
    let continueChat: () -> Void

    private var offersContinue: Bool {
        store.canContinue && store.continueWorkspace != nil && !store.continueProviders.isEmpty && store.hasContent
    }

    var body: some View {
        InlineNotice(ChatSessionStore.readOnlyNotice,
                     message: store.continueWorkspace == nil && store.canContinue ? "Open a workspace to continue it there." : nil,
                     tone: .info,
                     actionTitle: offersContinue ? store.continueWorkspace.map { "Continue in \($0.name)" } : nil,
                     action: offersContinue ? continueChat : nil,
                     identifiers: .init(text: "chatReadOnlyNotice", action: "chatContinueInWorkspace"))
            .disabled(!inputEnabled || !store.reachable)
    }
}

/// The agent needs a sign-in (`agent_auth_required`): what to do, the host's words (its ways to sign in),
/// and Open in Terminal when the agent has a terminal program, which opens it in the chat's workspace.
struct ChatSignInNotice: View {
    let signIn: ChatSignIn
    let store: ChatSessionStore
    let inputEnabled: Bool

    nonisolated static func title(agent: String) -> String { "Sign in to \(agent): open it in a terminal and follow its sign-in" }

    /// Chat's name for the agent, and the program the terminal opens when Chat calls it otherwise ("Sign in to
    /// <name>: open <program> in a terminal and follow its sign-in").
    nonisolated static func title(provider: AgentProvider) -> String {
        guard provider.chatDisplayName != provider.displayName else { return title(agent: provider.displayName) }
        return "Sign in to \(provider.chatDisplayName): open \(provider.displayName) in a terminal and follow its sign-in"
    }

    var body: some View {
        InlineNotice(Self.title(provider: store.provider), message: signIn.detail, tone: .warning,
                     actionTitle: store.canOpenSignInTerminal && inputEnabled ? "Open in Terminal" : nil,
                     action: store.canOpenSignInTerminal && inputEnabled ? { store.openSignInTerminal() } : nil,
                     onDismiss: { store.dismissSignIn() },
                     identifiers: .init(text: "chatSignInNotice", action: "chatSignInOpenTerminal", dismiss: "chatSignInDismiss"))
    }
}

/// Save as Markdown: the chat as a `.md` file for the share sheet.
public struct ChatMarkdownFile: Transferable {
    let title: String
    let text: String

    public init(title: String, text: String) { self.title = title; self.text = text }

    public static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: UTType("net.daringfireball.markdown") ?? .plainText) { file in
            Data(file.text.utf8)
        }
        .suggestedFileName { file in
            let name = file.title.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-")
            return (name.isEmpty ? "Chat" : name) + ".md"
        }
    }
}

#if os(iOS)
/// The camera, for attaching a photo; it is re-encoded like any other image.
struct ChatCameraPicker: UIViewControllerRepresentable {
    let finish: (Data?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(finish: finish) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let finish: (Data?) -> Void
        init(finish: @escaping (Data?) -> Void) { self.finish = finish }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            finish((info[.originalImage] as? UIImage)?.jpegData(compressionQuality: 0.9))
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { finish(nil) }
    }
}
#endif

/// A confirmation on the transcript row it acts on (`ChatScreen`'s row questions).
private struct ChatRowQuestion: ViewModifier {
    let title: String
    let shown: Binding<Bool>
    let actions: AnyView
    let message: AnyView

    init<Actions: View, Message: View>(title: String, shown: Binding<Bool>, @ViewBuilder actions: () -> Actions,
                                       @ViewBuilder message: () -> Message) {
        self.title = title
        self.shown = shown
        self.actions = AnyView(actions())
        self.message = AnyView(message())
    }

    func body(content: Content) -> some View {
        content.confirmationDialog(title, isPresented: shown, titleVisibility: .visible) { actions } message: { message }
    }
}
