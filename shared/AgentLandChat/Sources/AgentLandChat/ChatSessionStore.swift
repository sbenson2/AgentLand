import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers
import AgentLandCore

/// A message this device sent that the transcript does not show yet, with
/// how its delivery went. Uncertain and failed sends stay until the person
/// acts on them; nothing is sent again by itself.
public struct PendingSend: Identifiable, Equatable, Sendable {
    public enum Delivery: Equatable, Sendable {
        case sending
        /// The host took it; waiting for it to appear in the transcript.
        case accepted(messageID: String?)
        /// The connection broke before the host answered. It may have arrived.
        case notConfirmed
        /// Checking the transcript for it.
        case checking
        /// Provably not delivered, or missing from the transcript after a check.
        case notSent(String)
    }
    public let id: UUID
    public let clientMessageID: String?
    public let text: String
    public let attachmentIDs: [String]
    public let attachmentNames: [AttachmentRecord]
    public let createdAt: Date
    public var delivery: Delivery
}

/// Inline notices on the composer. Chat errors never become toasts.
public struct ChatNotice: Equatable, Identifiable, Sendable {
    public enum Action: Equatable, Sendable { case refreshStatus }
    public let id = UUID()
    public let message: String
    public let action: Action?
    public init(_ message: String, action: Action? = nil) { self.message = message; self.action = action }
    public static func == (lhs: ChatNotice, rhs: ChatNotice) -> Bool { lhs.message == rhs.message && lhs.action == rhs.action }
}

/// How a reply to an approval or question is going.
public enum InteractionDelivery: Equatable, Sendable {
    case sending
    /// The host took it; the card waits for the stream to report the outcome.
    case sent
    case notConfirmed
    case failed(String)
}

/// The chat's agent needs a sign-in before it runs (`agent_auth_required`, docs/AGENT-CATALOG-PLAN.md "ACP
/// chats"): a send or an options read the host refused with it, or a reply that failed with it. The notice
/// over the composer says to open the agent in a terminal and follow its sign-in.
public struct ChatSignIn: Equatable, Sendable {
    /// What the host said, such as the agent's ways to sign in.
    public let detail: String?
    /// The failed reply it came from; nil for a refused request.
    let replyID: String?
}

/// A mode a chat can run in, with AgentLand's own short summary.
public struct ChatModeChoice: Identifiable, Hashable, Sendable {
    /// What a mode that runs without asking says before a chat first enters it (owner, 2026-10-12 ~21:10: "Confirm
    /// once per chat"): the system confirmation's title, message and confirming button.
    public struct Confirmation: Hashable, Sendable {
        public let title: String
        public let message: String
        public let action: String
    }

    public let id: String
    public let name: String
    public let summary: String
    public let symbol: String
    /// Sent as OpenCode's `agent`, or as `mode` to providers that list modes.
    public let sentAsMode: Bool
    /// Set for the modes that run without asking (Claude Code's Bypass permissions, Codex's Full access): a chat asks
    /// before it first enters one, and never again.
    public let confirmation: Confirmation?

    public init(id: String, name: String, summary: String, symbol: String, sentAsMode: Bool, confirmation: Confirmation? = nil) {
        self.id = id; self.name = name; self.summary = summary; self.symbol = symbol; self.sentAsMode = sentAsMode
        self.confirmation = confirmation
    }

    /// The choice for the mode `id`, named as the host names it (`name`) or as AgentLand does. Claude Code's modes
    /// (Ask, Accept edits, Plan, Auto, Bypass permissions, and Don't ask for older chats) and Codex's (Ask, Auto-review,
    /// Read only, Full access) are known by their IDs; `provider` tells Claude Code's `default` and `auto` from another
    /// agent's.
    static func make(id: String, name: String?, sentAsMode: Bool, provider: AgentProvider? = nil) -> ChatModeChoice {
        func choice(_ fallback: String, _ summary: String, _ symbol: String, confirmation: Confirmation? = nil) -> ChatModeChoice {
            ChatModeChoice(id: id, name: name ?? fallback, summary: summary, symbol: symbol, sentAsMode: sentAsMode, confirmation: confirmation)
        }
        let agent = provider?.displayName
        if provider == .claude {
            switch id {
            case "default": return choice("Ask", "Asks first", "hand.raised")
            case "acceptEdits": return choice("Accept edits", "Edits without asking", "pencil")
            case "auto": return choice("Auto", "Asks only when risky", "checkmark.shield")
            case "dontAsk": return choice("Don’t ask", "Never asks", "hand.raised.slash")
            default: break
            }
        }
        switch id {
        case "build": return choice("Build", "Edits on its own", "pencil")
        case "plan": return choice("Plan", "Plans only", "list.bullet")
        case "ask": return choice("Ask", "Asks first", "hand.raised")
        case "auto-review": return choice("Auto review", "Edits on its own", "pencil")
        case "read-only": return choice("Read only", "Reads only", "eye")
        case "bypassPermissions":
            let mode = name ?? "Bypass permissions"
            return choice("Bypass permissions", "Runs without asking", "bolt", confirmation: Confirmation(
                title: "Switch this chat to \(mode)?",
                message: "\(agent ?? "The agent") will edit files, run commands and use its tools without asking you first. This chat won’t ask again.",
                action: "Bypass Permissions"))
        case "full-access":
            let mode = name ?? "Full access"
            return choice("Full access", "Runs without asking", "bolt", confirmation: Confirmation(
                title: "Switch this chat to \(mode)?",
                message: "\(agent ?? "The agent") will run commands and edit files anywhere on your Mac, with network access, without asking you first. This chat won’t ask again.",
                action: "Allow Full Access"))
        default:
            let label = name ?? id.capitalized
            return choice(label, label, "slider.horizontal.3")
        }
    }
}

/// Where a mode was chosen, so a confirmation shows on the control that asked (AGENTS.md: a confirmation is attached
/// to what it acts on): the composer's mode chip (or its Options menu), or the chat's title menu.
public enum ChatModeOrigin: Hashable, Sendable { case composer, titleMenu }

/// A mode that asks before the chat first enters it, waiting for the person's answer.
public struct ChatModeQuestion: Hashable, Sendable {
    public let choice: ChatModeChoice
    public let origin: ChatModeOrigin
}

/// A workspace a chat can continue into: the host's ID and the name the app shows ("Continue in my-app").
public struct ChatWorkspace: Hashable, Sendable {
    public let id: String
    public let name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

/// One chat tab's live state. The app model owns it, not the view, so the
/// transcript, draft and stream position survive tab switches. Only the
/// selected, active, unlocked chat keeps a stream open.
@MainActor @Observable
public final class ChatSessionStore {
    public struct Identity: Hashable, Sendable {
        public let hostID: String
        public let projectID: String
        public let sessionID: String
        public let tabID: UUID
        public init(hostID: String, projectID: String, sessionID: String, tabID: UUID) {
            self.hostID = hostID; self.projectID = projectID; self.sessionID = sessionID; self.tabID = tabID
        }
    }

    public enum Phase: Equatable, Sendable {
        case loading
        case ready
        /// Nothing could be loaded; the message says why.
        case unavailable(String)
        case deleted
    }

    public enum TransportKind: Equatable, Sendable { case events, polling }

    /// Everything the store needs from its app. The view passes it whenever
    /// one of these changes.
    public struct Environment {
        public var client: APIClient?
        public var capabilities: CapabilitiesResponse?
        public var reachable: Bool
        public var connectionEpoch: Int
        /// Selected, scene active and unlocked.
        public var active: Bool
        public var refreshGeneration: UUID?
        /// The IDs of the host's workspaces, once read: an older host's workspace called `chats` is no Chats space.
        public var workspaceIDs: Set<String>?
        /// Where a read-only Chats-space chat continues (`isReadOnly`): the workspace in use, nil while none is.
        public var continueWorkspace: ChatWorkspace?
        public init(client: APIClient?, capabilities: CapabilitiesResponse?, reachable: Bool, connectionEpoch: Int, active: Bool,
                    refreshGeneration: UUID?, workspaceIDs: Set<String>? = nil, continueWorkspace: ChatWorkspace? = nil) {
            self.client = client; self.capabilities = capabilities; self.reachable = reachable
            self.connectionEpoch = connectionEpoch; self.active = active; self.refreshGeneration = refreshGeneration
            self.workspaceIDs = workspaceIDs; self.continueWorkspace = continueWorkspace
        }
    }

    public struct Callbacks {
        /// A stream or request failed at the transport level. The app's
        /// connection logic (the pulse) decides whether the host is gone.
        public var connectionFailed: (@MainActor () -> Void)?
        public var persistDraft: (@MainActor (String) -> Void)?
        public var persistOptions: (@MainActor (_ model: String?, _ mode: String?, _ effort: String?) -> Void)?
        /// The person confirmed a mode that runs without asking (Bypass permissions, Full access) in this chat: the
        /// app keeps that with the chat and passes it back (`init(…unattendedModeConfirmed:)`), so it never asks again.
        public var modeConfirmed: (@MainActor () -> Void)?
        /// Opens a chat the host created (a fork or a continued chat) in a new tab.
        public var openChat: (@MainActor (Session) -> Void)?
        /// The chat's name changed (`name`): the host's title, or its first prompt while that is a default.
        public var nameChanged: (@MainActor (String) -> Void)?
        /// The chat went on in another (`ChatInfo.continuedIn`: the handoff skill started its next session there) while
        /// this store showed it: the app gives the tab to that chat. A chat opened after it went on is not followed.
        public var continued: (@MainActor (_ next: String) -> Void)?
        /// A turn ended on this chat's stream (`turn.finished`), with the reply in the transcript.
        public var turnFinished: (@MainActor (ChatTurnOutcome) -> Void)?
        /// Opens a terminal of `program` in the chat's workspace (the sign-in notice's Open in Terminal).
        public var openTerminal: (@MainActor (TerminalProgram) -> Void)?
        /// The host refused a plain chat's request because it has not confirmed its `chat` agent (503
        /// `agent_unavailable`): the app reads the host's capabilities again.
        public var capabilitiesStale: (@MainActor () -> Void)?
        public init() {}
    }

    private struct Marker: Equatable { let generation: UUID? }

    public let identity: Identity
    public let projection = ChatProjection()
    public let attachments = ChatAttachmentTray()
    @ObservationIgnored public var callbacks = Callbacks()

    public private(set) var provider: AgentProvider
    public private(set) var phase: Phase = .loading
    public private(set) var transportKind: TransportKind?
    public private(set) var runState: ChatRunState = .unknown
    public private(set) var retry: ChatRetryInfo?
    public private(set) var interactions: [ChatInteraction] = []
    public private(set) var interactionDelivery: [String: InteractionDelivery] = [:]
    public private(set) var resolvedAt: [String: Date] = [:]
    public private(set) var queue: [QueuedPrompt] = []
    public private(set) var rewind: RewindState?
    public private(set) var info: ChatInfo?
    public private(set) var hasMoreHistory = false
    public private(set) var loadingEarlier = false
    public private(set) var pendingSends: [PendingSend] = []
    public private(set) var notice: ChatNotice?
    /// The agent needs a sign-in; the notice stays until a newer turn starts, a send goes through or the
    /// person dismisses it.
    public private(set) var signIn: ChatSignIn?
    public private(set) var options: ChatOptionsResponse?
    public private(set) var selectedModelID: String
    public private(set) var selectedMode: String?
    public private(set) var selectedEffort: String?
    /// This chat may run without asking (Bypass permissions, Full access): the person confirmed it once, here or
    /// before the app last saved the chat, or the chat was saved in such a mode. Later switches don't ask.
    public private(set) var unattendedModeConfirmed: Bool
    /// A mode that asks first, waiting for the person's answer on the control that chose it.
    public private(set) var modeQuestion: ChatModeQuestion?
    public private(set) var draft: String
    public var composerRevealed = false
    /// Disclosures the person toggled away from how they start (reasoning, tool groups and rows start closed,
    /// or open with Settings → Chat's Expand tool details; `isExpanded(_:byDefault:)`). They stay as toggled
    /// while the chat is, and nothing opens or closes by itself.
    public var expandedParts: Set<String> = []

    /// Whether the disclosure `key` shows open: as it starts (`byDefault`), unless the person toggled it.
    public func isExpanded(_ key: String, byDefault: Bool = false) -> Bool { expandedParts.contains(key) != byDefault }

    /// Opens a closed disclosure or closes an open one.
    public func toggleExpanded(_ key: String) {
        if expandedParts.contains(key) { expandedParts.remove(key) } else { expandedParts.insert(key) }
    }
    /// Bumped whenever new reply text, a card or an error arrives, so a view
    /// scrolled away from the bottom can show a new-activity dot.
    public private(set) var activityCount = 0
    public private(set) var sending = false
    public private(set) var mutating = false
    /// A send or Run Again was accepted and its turn has not shown up yet (`awaitTurn`).
    public private(set) var awaitingTurnSince: Date?
    /// The sent message `awaitingTurnSince` waits on, when the host gave its ID.
    @ObservationIgnored private var awaitedMessageID: String?
    /// How many batches showed a turn, running or finished (`publish()`); a request compares it with its value
    /// when it left.
    @ObservationIgnored private var turnReports = 0
    /// When the running turn started, for the status line.
    public private(set) var turnStartedAt: Date?
    public private(set) var stoppedTurns: Set<String> = []
    public private(set) var capabilities: CapabilitiesResponse?
    public private(set) var reachable = true
    public private(set) var active = false
    /// Counters that views turn into haptics.
    public private(set) var sendCount = 0
    public private(set) var approvalArrivals = 0
    private var loadedMarker: Marker?
    private var optionsMarker: Marker?

    @ObservationIgnored public private(set) var state = ChatState()
    @ObservationIgnored private(set) var client: APIClient?
    @ObservationIgnored private var connectionEpoch = 0
    @ObservationIgnored private var refreshGeneration: UUID?
    @ObservationIgnored private var transportTask: Task<Void, Never>?
    @ObservationIgnored private var transportToken = UUID()
    @ObservationIgnored private var optionsTask: Task<Void, Never>?
    @ObservationIgnored private var draftSaveTask: Task<Void, Never>?
    @ObservationIgnored private var eventsUnsupported = false
    @ObservationIgnored private var shutDown = false
    /// The last `name` the app heard.
    @ObservationIgnored private var reportedName: String?
    /// When this store began showing the chat: a chat that went on in another since then is followed (`continued`).
    @ObservationIgnored var shownSince = Date()
    /// The last chat the app was told this one went on in.
    @ObservationIgnored private var reportedContinuation: String?
    /// The failed reply whose sign-in notice the person dismissed; it does not come back for that reply.
    @ObservationIgnored private var dismissedSignInReply: String?
    /// The device's saved copy, read once before the first network load.
    @ObservationIgnored private var transcriptCache: (any ChatTranscriptCache)?
    /// How long transport retries wait; tests shorten it.
    @ObservationIgnored public var retryDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(15)]
    @ObservationIgnored public var pollInterval: Duration = .seconds(1)

    public init(identity: Identity, provider: AgentProvider? = nil, draft: String = "", model: String? = nil, mode: String? = nil,
                effort: String? = nil, unattendedModeConfirmed: Bool = false, transcriptCache: (any ChatTranscriptCache)? = nil) {
        self.identity = identity
        let provider = provider ?? ChatSessionStore.provider(forSession: identity.sessionID)
        self.provider = provider
        self.draft = draft
        selectedModelID = model ?? ""
        selectedMode = mode
        selectedEffort = effort
        // A chat saved in such a mode got there through its confirmation.
        self.unattendedModeConfirmed = unattendedModeConfirmed
            || mode.map { ChatModeChoice.make(id: $0, name: nil, sentAsMode: true, provider: provider).confirmation != nil } == true
        self.transcriptCache = transcriptCache
    }

    /// The agent a chat's ID names: the host calls the chats of every agent but OpenCode
    /// `<agent>:<id>` ("claude:…", "codex:…", an ACP agent's "gemini:…"); OpenCode's own have no prefix.
    /// The name comes from the host's catalog once the chat has its capabilities.
    public static func provider(forSession id: String) -> AgentProvider {
        guard let colon = id.firstIndex(of: ":") else { return .opencode }
        let prefix = String(id[..<colon])
        return AgentID.isValid(prefix) ? AgentProvider(id: prefix) : .opencode
    }

    // MARK: Plain chats

    /// A chat of the host's Chats space (docs/HOST-API.md "Plain chats", `PlainChatsCapability.chatsSpace`): an AI
    /// chat outside every workspace. It takes no mode or effort, has no fork, changes no files, continues only into
    /// another plain chat, and shows its tools as plain cards.
    public var isPlainChat: Bool {
        identity.projectID == PlainChatsCapability.chatsSpace(capability: capabilities?.plainChats,
                                                               isWorkspace: { workspaceIDs?.contains($0) == true })
    }

    /// The IDs of the host's workspaces, as the app last passed them.
    public private(set) var workspaceIDs: Set<String>?

    /// Where this chat continues while it is read-only: the workspace in use, as the app last passed it.
    public private(set) var continueWorkspace: ChatWorkspace?

    /// What a read-only chat says over where its composer was, in the host's words.
    public static let readOnlyNotice = "Chat now runs in your workspaces; this chat stays readable."

    /// A Chats-space chat whose agent no longer runs there (owner, 2026-10-12: Chat is Claude Code and Codex in the
    /// workspaces): the host lists `workspaceChats`, and its Chats space does not offer this chat's provider (Claude
    /// Code's and Codex's never; OpenCode's unless the host runs with `--opencode-chat`). The host refuses everything
    /// that would start the agent there (503 `agent_unavailable`), so the chat shows no composer and asks for nothing
    /// of the kind; it stays readable and continues into a workspace (`continueWorkspace`). Older hosts still run them.
    public var isReadOnly: Bool {
        guard isPlainChat, capabilities?.workspaceChats != nil else { return false }
        return capabilities?.plainChats?.availableProviders.contains { $0.id == provider.id } != true
    }

    /// The host's entry for this chat's provider: the Chats space's for a plain chat, `workspaceChats`' for the others
    /// and for a read-only chat (which only reads, and streams as its provider's workspace chats do).
    private var providerEntry: PlainChatProvider? {
        isPlainChat && !isReadOnly ? capabilities?.plainChats?.availableProviders.first { $0.id == provider.id }
            : capabilities?.workspaceChats?.provider(provider.id)
    }

    /// The host says what this chat's provider supports: in `chatProviderInfo` (sent while its OpenCode streams), or in
    /// the provider's `workspaceChats` entry.
    private var providerFeaturesKnown: Bool {
        capabilities?.chatProviderInfo != nil || capabilities?.workspaceChats?.provider(provider.id) != nil
    }

    /// The chat streams its events: the host lists `events`, or this chat's provider entry does (a host whose OpenCode
    /// does not stream still streams its Claude Code and Codex chats).
    private var streamsEvents: Bool {
        capabilities?.supports(.events) == true || providerEntry?.features.contains(ChatFeature.events.rawValue) == true
    }

    /// A chat with nothing in it yet, a plain chat or an agent's alike. Its landing shows above the composer, which
    /// stays in use there (a saved draft waits in it), until the first message is on its way.
    public var showsLanding: Bool {
        loadedMarker != nil && projection.rows.isEmpty && state.messages.isEmpty && interactions.isEmpty
            && queue.isEmpty && rewind == nil && pendingSends.isEmpty && !runState.isWorking && awaitingTurnSince == nil
            && phase != .deleted
    }

    // MARK: Readiness

    /// The chat resolved its content (or an actionable error) and its options
    /// for this refresh generation; the opening cover may lift.
    public func isResolved(for generation: UUID?) -> Bool {
        loadedMarker == Marker(generation: generation) && optionsMarker == Marker(generation: generation)
    }

    public var hasContent: Bool { state.hasContent }

    public var isWorking: Bool { sending || runState.isWorking || awaitingTurnSince != nil }

    /// The chat's title: the host's, or while that is still a default such as
    /// "New chat", the first line of the first prompt, cut to 50 characters.
    public func displayTitle(fallback: String) -> String {
        let hostTitle = info?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let current = hostTitle.isEmpty ? fallback : hostTitle
        guard Self.isDefaultTitle(current, provider: provider), let prompt = firstPrompt else { return current }
        let line = prompt.split(whereSeparator: \.isNewline).lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        guard !line.isEmpty else { return current }
        return line.count > 50 ? String(line.prefix(49)) + "…" : line
    }

    /// Titles a chat gets before anyone names it, as the host counts them (its `default` title source): "New
    /// chat", "Claude Code chat", an agent's name alone, "Continued chat", OpenCode's "New session - <date>", and the
    /// defaults chats were saved with while Chat called its agents Claude and ChatGPT (2026-10-12): "Claude chat",
    /// "ChatGPT chat", "Claude", "ChatGPT". An agent the host names (an ACP agent) has its own: "Gemini CLI chat",
    /// "Gemini CLI".
    public static func isDefaultTitle(_ title: String, provider: AgentProvider) -> Bool {
        let lowered = title.trimmingCharacters(in: .whitespaces).lowercased()
        return lowered.isEmpty || lowered == provider.newChatTitle.lowercased() || lowered == provider.displayName.lowercased()
            || lowered == provider.chatDisplayName.lowercased()
            || placeholderTitles.contains(lowered) || lowered.hasPrefix("new session") || lowered.hasPrefix("child session - ")
    }

    /// The host's placeholder titles (docs/HOST-API.md, "Chat names"), lower-cased.
    static let placeholderTitles: Set<String> = [
        "new chat", "opencode", "claude", "claude code", "codex", "chatgpt", "continued chat", "opencode chat", "claude code chat",
        "codex chat", "claude chat", "chatgpt chat",
    ]

    /// What the chat is called in its tab and the sidebar: the host's title, or while that is a default,
    /// the first line of the first prompt, cut to 50 characters. Nil while it has neither.
    public var name: String? {
        let hostTitle = info?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !hostTitle.isEmpty, info?.titleSource != .default, !Self.isDefaultTitle(hostTitle, provider: provider) { return hostTitle }
        let line = firstPrompt?.split(whereSeparator: \.isNewline).lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        guard !line.isEmpty else { return nil }
        let name = line.count > 50 ? String(line.prefix(49)) + "…" : line
        return Self.isDefaultTitle(name, provider: provider) ? nil : name
    }

    /// Where the store's announcements go; tests read them here.
    @ObservationIgnored var announcer: @MainActor (String) -> Void = { AccessibilityNotification.Announcement($0).post() }

    /// Tells the app when `name` moved on.
    private func reportName() {
        guard let name, name != reportedName else { return }
        reportedName = name
        callbacks.nameChanged?(name)
    }

    private var firstPrompt: String? {
        for row in projection.rows {
            if case let .user(message) = row { return message.plainText }
        }
        return pendingSends.first?.text
    }

    // MARK: Environment and lifecycle

    public func update(_ environment: Environment) {
        guard !shutDown else { return }
        let clientChanged = client !== environment.client
        client = environment.client
        if capabilities != environment.capabilities {
            capabilities = environment.capabilities
            nameProvider()
        }
        if reachable != environment.reachable { reachable = environment.reachable }
        // No address of the host answers before this chat first loaded (B-14): say so now rather than show a
        // spinner until the load's own timeout. The load keeps going; its snapshot or its error replaces this.
        if !reachable, loadedMarker == nil, !state.hasContent, phase == .loading { phase = .unavailable(Self.hostAwayMessage) }
        if active != environment.active { active = environment.active }
        if workspaceIDs != environment.workspaceIDs { workspaceIDs = environment.workspaceIDs }
        if continueWorkspace != environment.continueWorkspace { continueWorkspace = environment.continueWorkspace }
        var restart = false
        if clientChanged {
            // Another connection (a restarted host, a new pairing): resume
            // from nothing; the snapshot reconciles what the chat holds.
            state.cursor = nil
            optionsMarker = nil
            eventsUnsupported = false
            restart = true
        }
        if environment.refreshGeneration != refreshGeneration {
            refreshGeneration = environment.refreshGeneration
            state.cursor = nil
            optionsMarker = nil
            restart = true
        }
        if environment.connectionEpoch != connectionEpoch {
            connectionEpoch = environment.connectionEpoch
            restart = true
        }
        guard active else {
            stopTransport()
            return
        }
        guard client != nil else {
            stopTransport()
            if loadedMarker == nil || optionsMarker == nil { resolveUnavailable("The host is unavailable.") }
            return
        }
        // Offline: keep the content and pause. A chat that never loaded still
        // tries once so it can show an honest error instead of a spinner.
        guard reachable || loadedMarker == nil else {
            stopTransport()
            return
        }
        if restart || transportTask == nil { startTransport() }
        if optionsMarker != Marker(generation: refreshGeneration), optionsTask == nil { loadOptions() }
    }

    /// Ends every task; used when the tab closes or the host changes.
    public func shutdown() {
        shutDown = true
        stopTransport()
        optionsTask?.cancel()
        optionsTask = nil
        flushDraft()
    }

    private func stopTransport() {
        transportTask?.cancel()
        transportTask = nil
        transportToken = UUID()
    }

    private func startTransport() {
        stopTransport()
        let kind: TransportKind = streamsEvents && !eventsUnsupported ? .events : .polling
        transportKind = kind
        let token = transportToken
        // The device archive is read once, before the first network load.
        let cache = transcriptCache
        transcriptCache = nil
        transportTask = Task { [weak self] in
            if let cache, let self, let saved = await cache.cachedTranscript(projectID: self.identity.projectID, sessionID: self.identity.sessionID),
               !self.state.hasContent, !self.shutDown {
                ChatReducer.replace(&self.state, with: saved)
                self.publish()
            }
            guard let self else { return }
            switch kind {
            case .events: await self.runEvents(token)
            case .polling: await self.runPolling(token)
            }
        }
    }

    private func current(_ token: UUID) -> Bool { !Task.isCancelled && token == transportToken && !shutDown }

    private func pause(_ delay: Duration) async -> Bool {
        do { try await Task.sleep(for: delay) } catch { return false }
        return true
    }

    /// A chat that had not loaded when no address of the host answered (B-14).
    static let hostAwayMessage = "Can’t reach the host. The chat loads once it answers."

    private func resolveUnavailable(_ message: String) {
        if !state.hasContent { phase = .unavailable(message) }
        loadedMarker = Marker(generation: refreshGeneration)
        if optionsMarker == nil { optionsMarker = Marker(generation: refreshGeneration) }
    }

    // MARK: Event stream

    private enum StreamEnd: Equatable {
        case ended, resync, stopping, unauthorized, dropped, cancelled
        case failed(String)
    }

    private func runEvents(_ token: UUID) async {
        var failures = 0
        var resyncs: [Date] = []
        while current(token) {
            guard let client else { return }
            var end: StreamEnd
            var failure: Error?
            do {
                let lines = try await client.chatEventLines(projectID: identity.projectID, sessionID: identity.sessionID,
                                                            after: state.cursor)
                guard current(token) else { return }
                let pump = ChatEventPump()
                await pump.start(lines)
                end = await consume(pump, token: token)
                await pump.stop()
                if end == .ended || end == .resync { failures = 0 }
            } catch {
                failure = error
                end = .failed(error.localizedDescription)
            }
            guard current(token) else { return }
            switch end {
            case .cancelled:
                return
            case .ended:
                continue
            case .resync:
                // Reconnect without a cursor; a fresh snapshot replaces the
                // state. Repeated disagreements back off instead of looping.
                state.cursor = nil
                resyncs = resyncs.filter { Date().timeIntervalSince($0) < 30 } + [Date()]
                if resyncs.count > 3, !(await pause(.seconds(5))) { return }
                continue
            case .unauthorized:
                notice = ChatNotice("The host no longer accepts this device. Pair again from Settings.")
                callbacks.connectionFailed?()
                return
            case .stopping, .dropped:
                callbacks.connectionFailed?()
            case .failed:
                if let failure, let decision = streamFailure(failure) {
                    switch decision {
                    case .poll:
                        eventsUnsupported = true
                        transportKind = .polling
                        await runPolling(token)
                        return
                    case .stop:
                        return
                    }
                }
            }
            failures += 1
            if loadedMarker == nil { resolveUnavailable(failure?.localizedDescription ?? "The chat could not be loaded.") }
            if !(await pause(retryDelays[min(failures, retryDelays.count) - 1])) { return }
        }
    }

    private enum FailureDecision { case poll, stop }

    /// Host refusals that change course; nil means retry after a pause.
    private func streamFailure(_ error: Error) -> FailureDecision? {
        if case let .server(code, message) = error as? ClientError {
            switch code {
            case "unsupported_operation", "stream_limit", "chat_streams_busy":
                // This chat (or this moment) cannot stream: fall back to reading the transcript.
                return .poll
            case "not_found":
                phase = .deleted
                loadedMarker = Marker(generation: refreshGeneration)
                return .stop
            case "unauthorized":
                notice = ChatNotice("The host no longer accepts this device. Pair again from Settings.")
                callbacks.connectionFailed?()
                return .stop
            default:
                if loadedMarker == nil { resolveUnavailable(message) }
                return nil
            }
        }
        if ClientError.isConnectionFailure(error) || error is URLError { callbacks.connectionFailed?() }
        return nil
    }

    private func consume(_ pump: ChatEventPump, token: UUID) async -> StreamEnd {
        for await output in pump.outputs {
            guard current(token) else { return .cancelled }
            switch output {
            case let .events(batch):
                if let end = apply(batch) { return end }
            case .finished:
                return .dropped
            case let .failed(error):
                if ClientError.isConnectionFailure(error) || error is URLError { return .dropped }
                return .failed(error.localizedDescription)
            }
        }
        return .cancelled
    }

    /// Applies one batch; returns how the stream should continue, if not as is.
    private func apply(_ batch: [ChatEventEnvelope]) -> StreamEnd? {
        var end: StreamEnd?
        for envelope in batch {
            switch ChatReducer.apply(envelope, to: &state) {
            case .resync:
                publish()
                return .resync
            case .ended: end = .ended
            case .stopping: end = .stopping
            case .unauthorized: end = .unauthorized
            case .applied, .ignored: break
            }
        }
        publish()
        return end
    }

    // MARK: Legacy polling (hosts without `events`)

    private func runPolling(_ token: UUID) async {
        while current(token) {
            await pollOnce(token)
            guard current(token), await pause(pollInterval) else { return }
        }
    }

    private func pollOnce(_ token: UUID) async {
        guard let client else { return }
        let projectID = identity.projectID, sessionID = identity.sessionID
        let wantsQueue = capabilities?.supports(.queue) == true
        let wantsInteractions = capabilities?.interactions ?? true
        let withParts = capabilities?.supports(.parts) == true
        do {
            async let transcript = client.transcript(projectID: projectID, sessionID: sessionID, withParts: withParts)
            async let waiting: InteractionsResponse? = wantsInteractions ? try? client.interactions(projectID: projectID, sessionID: sessionID) : nil
            async let queued: [QueuedPrompt]? = wantsQueue ? try? client.queue(projectID: projectID, sessionID: sessionID) : []
            let status = try? await client.chatStatus(projectID: projectID, sessionID: sessionID)
            let (loaded, pending, items) = try await (transcript, waiting, queued)
            guard current(token) else { return }
            let running = status?.state == "busy" || status?.state == "retry"
            var turn = ""
            let lastAssistant = loaded.messages.lastIndex { $0.role == .assistant }
            let messages = loaded.messages.enumerated().map { index, message -> ConversationMessage in
                if message.role == .user { turn = message.id }
                return ConversationMessage(legacy: message, chatID: sessionID, turnID: turn, ord: Int64(index + 1),
                                           provider: provider.id, streaming: running && index == lastAssistant && index == loaded.messages.count - 1)
            }
            let interactions = (pending?.permissions.map(ChatInteraction.init(legacy:)) ?? [])
                + (pending?.questions.map(ChatInteraction.init(legacy:)) ?? [])
            let state: ChatRunState = switch status?.state {
            case "busy": interactions.isEmpty ? .running : .waiting
            case "retry": .retry
            case "idle": .idle
            default: .unknown
            }
            var snapshot = ChatSnapshot(chat: info ?? ChatInfo(id: sessionID, provider: provider.id), messages: messages,
                                        status: ChatStatusInfo(state: state), interactions: interactions,
                                        queue: items ?? self.queue, rewind: loaded.rewind)
            if items == nil { snapshot.queue = self.queue }
            reconcileLegacy(snapshot)
        } catch {
            guard current(token) else { return }
            if ClientError.isConnectionFailure(error) || error is URLError { callbacks.connectionFailed?() }
            if case .server(code: "not_found", _) = error as? ClientError {
                phase = .deleted
                loadedMarker = Marker(generation: refreshGeneration)
                return
            }
            if loadedMarker == nil { resolveUnavailable(error.localizedDescription) }
        }
    }

    /// A legacy load replaces the state only where it differs, so an
    /// unchanged transcript redraws nothing.
    private func reconcileLegacy(_ snapshot: ChatSnapshot) {
        let previous = state
        var next = previous
        ChatReducer.replace(&next, with: snapshot)
        let running = next.status.state.isWorking
        if running, !previous.status.state.isWorking, let user = next.messages.last(where: { $0.role == .user }) {
            next.turnID = user.id
        } else if !running, previous.status.state.isWorking {
            next.changes.finishedTurns.append(ChatTurnOutcome(turnID: previous.turnID ?? "", outcome: next.messages.last?.status == .error ? "error" : "completed"))
            next.turnID = nil
        }
        let previousIDs = Set(previous.interactions.map(\.id))
        next.changes.newInteractions = next.interactions.filter { !previousIDs.contains($0.id) }
        state = next
        publish()
    }

    // MARK: Publishing state to views

    private func publish() {
        let changes = state.changes
        state.changes = ChatChanges()
        projection.sync(state, changes: changes)
        if let chat = state.chat, chat != info {
            info = chat
            if !chat.provider.isEmpty, chat.provider != provider.id { provider = AgentProvider.named(chat.provider, by: capabilities) }
            followHostMode()
        }
        let status = state.status
        if runState != status.state { runState = status.state }
        if retry != status.retry { retry = status.retry }
        if interactions != state.interactions {
            interactions = state.interactions
            let pending = Set(interactions.map(\.id))
            interactionDelivery = interactionDelivery.filter { pending.contains($0.key) }
        }
        if queue != state.queue { queue = state.queue }
        if rewind != state.rewind { rewind = state.rewind }
        if hasMoreHistory != state.hasMore { hasMoreHistory = state.hasMore }
        if state.hasContent {
            if phase != .ready && phase != .deleted { phase = .ready }
            if loadedMarker != Marker(generation: refreshGeneration) { loadedMarker = Marker(generation: refreshGeneration) }
        }
        // A turn shows as running, or as finished: a fast one can start and finish between two batches (the host
        // and the pump each pass at most one batch per 33 ms), and the second shows only its end.
        let turnShown = status.state.isWorking || !changes.finishedTurns.isEmpty
        if turnShown { turnReports &+= 1 }
        if status.state.isWorking {
            if turnStartedAt == nil { turnStartedAt = awaitingTurnSince ?? Date() }
        } else if !changes.finishedTurns.isEmpty || status.state == .idle || status.state == .error {
            if turnStartedAt != nil { turnStartedAt = nil }
        }
        // The awaited turn showed, or a reload or a poll brought the sent message's finished reply without it.
        if awaitingTurnSince != nil, turnShown || replyFinished(to: awaitedMessageID) { endAwaitingTurn() }
        for resolved in changes.resolvedInteractions { resolvedAt[resolved.id] = Date() }
        if changes.structure || !changes.appended.isEmpty || !changes.newInteractions.isEmpty || !changes.parts.isEmpty
            || !changes.partLists.isEmpty || !changes.finishedTurns.isEmpty {
            activityCount &+= 1
        }
        reconcilePendingSends()
        noteSignIn()
        announce(changes)
        noteMemorySaves(reset: changes.reset)
        reportName()
        reportContinuation()
        for finished in changes.finishedTurns { callbacks.turnFinished?(finished) }
    }

    /// Tells the app when the chat went on in another since this store began showing it: live (`chat.updated`), or
    /// while the stream was away (the snapshot that follows). The host's time against this device's, so a chat that
    /// went on before it was opened, from the history or a restored tab, stays where it is.
    private func reportContinuation() {
        guard let next = info?.continuedIn, next != identity.sessionID, next != reportedContinuation,
              let at = info?.continuedDate, at >= shownSince else { return }
        reportedContinuation = next
        callbacks.continued?(next)
    }

    /// The agent's name from the host's catalog, for an agent this version cannot name (an ACP agent). A
    /// catalog without it leaves the name the chat has.
    private func nameProvider() {
        guard let name = capabilities?.agentCatalog?.first(where: { $0.id == provider.id })?.name else { return }
        let named = AgentProvider(id: provider.id, name: name)
        if named != provider { provider = named }
    }

    // MARK: Sign-in

    /// A latest reply that failed because the agent needs a sign-in shows the notice, until a newer turn
    /// starts or the person dismisses it for that reply.
    private func noteSignIn() {
        guard case let .reply(reply)? = projection.rows.last else {
            if signIn?.replyID != nil { signIn = nil }
            return
        }
        if let error = reply.error, error.code == AgentErrorCode.authRequired {
            guard signIn?.replyID != reply.id, dismissedSignInReply != reply.id else { return }
            signIn = ChatSignIn(detail: Self.signInDetail(error.message), replyID: reply.id)
        } else if signIn?.replyID != nil {
            signIn = nil
        }
    }

    public func dismissSignIn() {
        if let reply = signIn?.replyID { dismissedSignInReply = reply }
        signIn = nil
    }

    /// The program Open in Terminal starts for the chat's agent, when the host offers it one.
    public var signInProgram: TerminalProgram? { provider.terminalProgram(offeredBy: capabilities) }

    /// The notice offers Open in Terminal: the agent has a program and the app can open terminals.
    public var canOpenSignInTerminal: Bool { signInProgram != nil && callbacks.openTerminal != nil }

    /// Opens the chat's agent in a terminal of the chat's workspace, to follow its sign-in there.
    public func openSignInTerminal() {
        guard let program = signInProgram else { return }
        callbacks.openTerminal?(program)
    }

    private func requireSignIn(_ error: ClientError) {
        guard error.isAgentAuthRequired else { return }
        if case let .server(_, message) = error { signIn = ChatSignIn(detail: Self.signInDetail(message), replyID: nil) }
    }

    /// The host's words for the notice, bounded; nil when it said nothing.
    static func signInDetail(_ message: String) -> String? {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return text.count > 300 ? String(text.prefix(299)) + "…" : text
    }

    private func announce(_ changes: ChatChanges) {
        let name = provider.chatDisplayName
        if !changes.newInteractions.isEmpty { approvalArrivals += 1 }
        guard active else { return }
        for interaction in changes.newInteractions {
            if interaction.kind == .permission {
                let tool = ChatToolKind(toolName: interaction.permission?.tool ?? "")
                let what = tool == .command ? "to run a command" : tool == .edit ? "to edit a file" : "to use a tool"
                AccessibilityNotification.Announcement("\(name) needs permission \(what)").post()
            } else {
                let count = interaction.questions.count
                AccessibilityNotification.Announcement(count == 1 ? "\(name) asked a question" : "\(name) asked \(count) questions").post()
            }
        }
        for finished in changes.finishedTurns {
            switch finished.outcome {
            case "completed": AccessibilityNotification.Announcement("\(name) finished").post()
            case "error":
                let reason = projection.latestReply?.error.map { ChatErrorCopy.category($0, provider: provider).announcement } ?? "Reply failed"
                AccessibilityNotification.Announcement(reason).post()
            default: break
            }
        }
    }

    /// Whether the transcript already holds a finished reply to the user message `messageID`.
    private func replyFinished(to messageID: String?) -> Bool {
        guard let messageID, let index = state.messages.firstIndex(where: { $0.id == messageID && $0.role == .user }) else { return false }
        return state.messages[state.messages.index(after: index)...].contains { $0.role == .assistant && $0.status != .streaming }
    }

    /// Waits for the turn of a message (`messageID`, when the host gave it) or a Run Again the host accepted, unless
    /// it has already shown: the chat is working, a turn showed since the request left (`reportsBefore`; a fast turn
    /// can run to its end on the stream before the answer arrives), or its finished reply is already here.
    private func awaitTurn(of messageID: String?, reportsBefore: Int) {
        guard !runState.isWorking, turnReports == reportsBefore, !replyFinished(to: messageID) else { return }
        awaitingTurnSince = Date()
        awaitedMessageID = messageID
    }

    private func endAwaitingTurn() {
        awaitingTurnSince = nil
        awaitedMessageID = nil
    }

    /// Accepted sends leave once their message shows in the transcript.
    private func reconcilePendingSends() {
        guard !pendingSends.isEmpty else { return }
        let users = state.messages.filter { $0.role == .user }
        let next = pendingSends.filter { pending in
            switch pending.delivery {
            case let .accepted(messageID):
                if let messageID, users.contains(where: { $0.id == messageID }) { return false }
                if messageID == nil, appears(pending, in: users) { return false }
                return true
            default:
                return true
            }
        }
        if next != pendingSends { pendingSends = next }
    }

    /// A user message with the same text created after this send began.
    private func appears(_ pending: PendingSend, in users: [ConversationMessage]) -> Bool {
        let text = pending.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return users.contains { message in
            let created = ChatTime.date(message.createdAt)
            let recent = created.map { $0 >= pending.createdAt.addingTimeInterval(-5) } ?? true
            return recent && message.plainText.trimmingCharacters(in: .whitespacesAndNewlines) == text
        }
    }

    // MARK: History

    public var canPage: Bool { streamsEvents && transportKind == .events }

    /// Loads the page before the oldest loaded message.
    public func loadEarlier() async {
        guard canPage, hasMoreHistory, !loadingEarlier, let client, reachable else { return }
        guard let oldest = state.messages.first?.id else { return }
        loadingEarlier = true
        defer { loadingEarlier = false }
        do {
            let page = try await client.chatMessagesPage(projectID: identity.projectID, sessionID: identity.sessionID, before: oldest)
            guard !shutDown, state.messages.first?.id == oldest else { return }
            ChatReducer.mergeOlder(page, into: &state)
            publish()
        } catch {
            if ClientError.isConnectionFailure(error) { callbacks.connectionFailed?() }
            notice = ChatNotice("Earlier messages could not be loaded. \(error.localizedDescription)")
        }
    }

    // MARK: Options: model, mode and effort

    /// The modes the next message can run in, in the host's order with its names; none for a plain chat, which takes
    /// no mode. A new Claude Code or Codex chat starts in the host's default, Ask.
    public var modeChoices: [ChatModeChoice] {
        guard let options, !isPlainChat else { return [] }
        if let modes = options.modes, !modes.isEmpty {
            return modes.map { ChatModeChoice.make(id: $0.id, name: $0.name, sentAsMode: true, provider: provider) }
        }
        return options.agents.map { ChatModeChoice.make(id: $0, name: nil, sentAsMode: false, provider: provider) }
    }

    public var selectedModeChoice: ChatModeChoice? {
        let choices = modeChoices
        return choices.first { $0.id == selectedMode } ?? choices.first
    }

    public var selectedModel: AgentModelOption? { options?.models.first { $0.id == selectedModelID } }

    /// Effort levels supported by both this provider's conversation profile and the chosen model.
    public var effortChoices: [String] {
        guard plainChatSupports("effort"), capabilities?.supports(.effort, provider: provider.id) == true else { return [] }
        return selectedModel?.efforts ?? []
    }

    /// The efforts the chosen model lists, which the store keeps a choice among; none for a plain chat.
    private var modelEfforts: [String] { plainChatSupports("effort") ? selectedModel?.efforts ?? [] : [] }

    private func loadOptions() {
        guard let client else { return }
        let generation = refreshGeneration
        // A read-only chat's options are refused (503 `agent_unavailable`) and it has nothing to choose.
        if isReadOnly {
            optionsMarker = Marker(generation: generation)
            return
        }
        optionsTask = Task { [weak self] in
            let loaded: ChatOptionsResponse?
            var refusal: ClientError?
            do {
                loaded = try await client.chatOptions(projectID: self?.identity.projectID ?? "", sessionID: self?.identity.sessionID)
            } catch {
                loaded = nil
                refusal = error as? ClientError
            }
            guard let self, !Task.isCancelled, !self.shutDown else { return }
            self.optionsTask = nil
            guard generation == self.refreshGeneration, client === self.client else { return }
            if let loaded { self.apply(options: loaded) }
            // An agent that must sign in first may say so as soon as its options are asked for.
            if let refusal, self.signIn == nil { self.requireSignIn(refusal) }
            // A host default can still send; delivery reports actionable failures.
            self.optionsMarker = Marker(generation: generation)
        }
    }

    private func apply(options loaded: ChatOptionsResponse) {
        options = loaded
        if !loaded.models.contains(where: { $0.id == selectedModelID }) {
            selectedModelID = loaded.models.contains { $0.id == loaded.defaultModel } ? loaded.defaultModel : (loaded.models.first?.id ?? "")
        }
        let choices = modeChoices
        if !choices.contains(where: { $0.id == selectedMode }) {
            selectedMode = loaded.defaultMode.flatMap { mode in choices.first { $0.id == mode }?.id } ?? choices.first?.id
        }
        let efforts = modelEfforts
        if let effort = selectedEffort, !efforts.contains(effort) { selectedEffort = nil }
        if selectedEffort == nil, !efforts.isEmpty { selectedEffort = selectedModel?.defaultEffort ?? efforts.first }
    }

    public func selectModel(_ id: String) {
        guard selectedModelID != id else { return }
        selectedModelID = id
        let efforts = modelEfforts
        if let effort = selectedEffort, efforts.contains(effort) {} else { selectedEffort = efforts.isEmpty ? nil : (selectedModel?.defaultEffort ?? efforts.first) }
        persistOptions()
    }

    /// Chooses the mode the next message runs in. A mode that runs without asking (Bypass permissions, Full access)
    /// asks first, once per chat (owner, 2026-10-12 ~21:10): until this chat confirmed one, choosing it only raises the
    /// question (`modeQuestion`) on the control it came from, and nothing changes or is sent in it.
    public func selectMode(_ id: String, from origin: ChatModeOrigin = .composer) {
        guard selectedMode != id else { return }
        if let choice = modeChoices.first(where: { $0.id == id }), choice.confirmation != nil, !unattendedModeConfirmed {
            modeQuestion = ChatModeQuestion(choice: choice, origin: origin)
            return
        }
        modeQuestion = nil
        selectedMode = id
        persistOptions()
    }

    /// The person confirmed `choice` (the dialog acts on the choice it presented, never on `modeQuestion`, which its
    /// dismissal may already have cleared): this chat runs that way from the next message, and never asks again.
    public func confirmMode(_ choice: ChatModeChoice) {
        modeQuestion = nil
        guard modeChoices.contains(where: { $0.id == choice.id }) else { return }
        if !unattendedModeConfirmed {
            unattendedModeConfirmed = true
            callbacks.modeConfirmed?()
        }
        guard selectedMode != choice.id else { return }
        selectedMode = choice.id
        persistOptions()
    }

    /// The person declined, or the question went away: the mode stays as it was.
    public func cancelModeQuestion() { modeQuestion = nil }

    /// The mode the host last reported for this chat (`info.mode`).
    @ObservationIgnored private var reportedMode: String?

    /// Follows a mode change the host reports while the chat is open: Claude Code changes its own mode (leaving Plan
    /// once the plan is approved returns to the mode before it; a permission's suggestion may switch it), and the
    /// next message must keep that mode rather than put Plan back. The mode the chat opens with is the device's (its
    /// saved choice, else the host's default), as before. A return to Bypass permissions or Full access is followed
    /// only in a chat that confirmed it, so it never asks twice, and a device never takes one up without its own
    /// confirmation (another device may have chosen it): it keeps its choice, which its next message sends.
    private func followHostMode() {
        guard let mode = info?.mode, !mode.isEmpty, mode != reportedMode else { return }
        let first = reportedMode == nil
        reportedMode = mode
        guard !first, mode != selectedMode, let choice = modeChoices.first(where: { $0.id == mode }), choice.sentAsMode else { return }
        if choice.confirmation != nil, !unattendedModeConfirmed { return }
        if modeQuestion != nil { modeQuestion = nil }
        selectedMode = mode
        persistOptions()
    }

    public func selectEffort(_ effort: String) {
        guard selectedEffort != effort else { return }
        selectedEffort = effort
        persistOptions()
    }

    private func persistOptions() {
        callbacks.persistOptions?(selectedModelID.isEmpty ? nil : selectedModelID, selectedMode, selectedEffort)
    }

    // MARK: Draft

    public func setDraft(_ text: String) {
        guard text != draft else { return }
        draft = text
        // Any edit puts the composer in use: the chat keeps it, never the
        // loading indicator, while its content is still on the way.
        composerRevealed = true
        scheduleDraftSave()
    }

    private func scheduleDraftSave() {
        draftSaveTask?.cancel()
        draftSaveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            self?.flushDraft()
        }
    }

    /// Saves the draft now (leaving the tab, backgrounding).
    public func flushDraft() {
        draftSaveTask?.cancel()
        draftSaveTask = nil
        callbacks.persistDraft?(draft)
    }

    /// The composer's field changed to `text`. With `longPastesAsFiles` (Settings → Chat), an edit that put a long
    /// text in at once (`ChatLongPaste`: a paste) attaches it as a text file instead, while the host takes
    /// attachments and the message has room for one more; the draft keeps the rest. Otherwise the text goes into
    /// the draft as it is.
    public func editDraft(_ text: String, longPastesAsFiles: Bool) {
        guard longPastesAsFiles, client != nil, canSendAttachments, attachments.remaining > 0,
              let edit = ChatLongPaste.insertion(from: draft, to: text), ChatLongPaste.isLong(edit.inserted),
              let prepared = try? ChatAttachmentPolicy.prepare(name: ChatLongPaste.fileName, data: Data(edit.inserted.utf8),
                                                                type: .plainText) else {
            setDraft(text)
            return
        }
        setDraft(edit.remainder)
        attach(prepared)
    }

    /// Puts text into the composer, after anything already typed.
    public func useInComposer(_ text: String) {
        let current = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        setDraft(current.isEmpty ? text : text + "\n\n" + current)
        requestComposerFocus()
    }

    /// Bumped to move keyboard focus into the composer (Use in Composer,
    /// Edit and Resend). Opening a chat alone never raises it.
    public private(set) var focusRequest = 0
    @ObservationIgnored var handledFocusRequest = 0

    public func requestComposerFocus() {
        composerRevealed = true
        focusRequest &+= 1
    }

    /// Uploads a prepared file for the next message.
    public func attach(_ prepared: ChatAttachmentPolicy.Prepared) {
        if let accepted = allowedAttachmentMIMEs, !accepted.contains(prepared.mime) {
            notice = ChatNotice("This provider accepts photos and text files. Use Claude or OpenCode for PDFs.")
            return
        }
        guard let client else {
            notice = ChatNotice("The host is unavailable, so nothing was attached.")
            return
        }
        let projectID = identity.projectID, sessionID = identity.sessionID
        composerRevealed = true
        attachments.add(prepared) { prepared in
            try await client.uploadAttachment(projectID: projectID, sessionID: sessionID, name: prepared.name,
                                              mime: prepared.mime, data: prepared.data)
        }
    }

    public func report(_ problem: String) { notice = ChatNotice(problem) }

    /// Options a new chat of `target` could use, for Continue, as the host lists them for the project the new chat
    /// would be in. A plain chat continues only into another plain chat, whose agent is OpenCode's: its models are the
    /// Chats space's. A read-only chat continues into a Claude Code or Codex chat of the workspace in use.
    public func options(for target: AgentProvider) async -> ChatOptionsResponse? {
        guard let projectID = continueProject(for: target), let client else { return nil }
        return try? await client.chatOptions(projectID: projectID, provider: target.id)
    }

    /// The project a continued chat of `target` would be in, or nil when this chat cannot continue into one.
    private func continueProject(for target: AgentProvider) -> String? {
        if isReadOnly {
            guard let workspace = continueWorkspace, continueProviders.contains(target) else { return nil }
            return workspace.id
        }
        if isPlainChat, target.id != provider.id { return nil }
        return identity.projectID
    }

    public func dismissNotice() { notice = nil }

    // MARK: Sending

    public var canSendAttachments: Bool { plainChatSupports("attachments") && capabilities?.supports(.attachments) == true }
    /// The types the provider's entry takes (a plain chat's, or a Claude Code or Codex workspace chat's); nil for any.
    public var allowedAttachmentMIMEs: [String]? { providerEntry?.attachmentTypes }
    public var canQueue: Bool { plainChatSupports("queue") && capabilities?.supports(.queue) == true }

    private func plainChatSupports(_ feature: String) -> Bool {
        guard isPlainChat else { return true }
        return capabilities?.plainChats?.availableProviders.first(where: { $0.id == provider.id })?.features.contains(feature) == true
    }
    public var draftHasText: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public var sendEnabled: Bool {
        guard !isReadOnly, attachments.isEmpty || attachments.uploadedIDs != nil else { return false }
        return (draftHasText || !attachments.isEmpty) && !sending && reachable && phase != .deleted
    }

    /// Sends the draft. Offline sends are refused with a notice and the draft
    /// is kept. The draft is saved as empty only once the host accepts.
    public func send() async {
        guard !sending, !isReadOnly else { return }
        guard reachable else {
            notice = ChatNotice("Offline · your draft is kept")
            return
        }
        guard client != nil, let files = attachments.uploadedIDs else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !files.isEmpty else { return }
        let names = attachments.items.map { AttachmentRecord(name: $0.name, mime: $0.mime) }
        let pending = PendingSend(id: UUID(), clientMessageID: capabilities?.supports(.clientMessageId) == true ? Self.makeClientMessageID() : nil,
                                  text: text, attachmentIDs: files, attachmentNames: names, createdAt: Date(), delivery: .sending)
        composerRevealed = true
        draftSaveTask?.cancel()
        draft = ""
        attachments.removeSent(files)
        notice = nil
        sendCount += 1
        pendingSends.append(pending)
        // A chat still called by a default title goes by this first prompt from now on.
        reportName()
        await deliver(pending)
    }

    /// Sends a message again, only because the person asked. It keeps its
    /// clientMessageId, so a host that saw the first attempt does not repeat it.
    public func sendAgain(_ id: UUID) async {
        guard let pending = pendingSends.first(where: { $0.id == id }), !sending, !isReadOnly else { return }
        guard reachable else {
            notice = ChatNotice("Offline · nothing was sent")
            return
        }
        update(id) { $0.delivery = .sending }
        sendCount += 1
        await deliver(pending)
    }

    private func deliver(_ pending: PendingSend) async {
        guard let client else {
            update(pending.id) { $0.delivery = .notSent("The host is unavailable.") }
            return
        }
        sending = true
        defer { sending = false }
        let reportsBefore = turnReports
        let outcome = await client.sendChatMessage(request(text: pending.text, attachments: pending.attachmentIDs,
                                                           clientMessageID: pending.clientMessageID))
        guard !shutDown, client === self.client else { return }
        switch outcome {
        case let .accepted(receipt):
            update(pending.id) { $0.delivery = .accepted(messageID: receipt.messageID) }
            // The agent took a message: a refusal's sign-in notice is done with.
            if signIn != nil, signIn?.replyID == nil { signIn = nil }
            if draft.isEmpty { callbacks.persistDraft?("") }
            awaitTurn(of: receipt.messageID, reportsBefore: reportsBefore)
            reconcilePendingSends()
        case .uncertain:
            update(pending.id) { $0.delivery = .notConfirmed }
        case let .failed(error):
            if error == .unreachable { callbacks.connectionFailed?() }
            requireSignIn(error)
            noteAgentUnavailable(error)
            update(pending.id) { $0.delivery = .notSent(error.localizedDescription) }
        }
    }

    /// A plain chat's request the host refused because its `chat` agent is not confirmed: the app reads the
    /// host's capabilities again (docs/HOST-API.md "Plain chats").
    private func noteAgentUnavailable(_ error: ClientError) {
        if error.isPlainChatAgentUnavailable { callbacks.capabilitiesStale?() }
    }

    /// Looks for an unconfirmed message in the chat as the host has it now.
    /// Found, it joins the transcript; missing, it becomes Not Sent.
    public func checkPending(_ id: UUID) async {
        guard let pending = pendingSends.first(where: { $0.id == id }), let client else { return }
        update(id) { $0.delivery = .checking }
        do {
            let users: [ConversationMessage]
            if streamsEvents {
                users = try await client.chatMessagesPage(projectID: identity.projectID, sessionID: identity.sessionID, before: nil)
                    .messages.filter { $0.role == .user }
            } else {
                let transcript = try await client.transcript(projectID: identity.projectID, sessionID: identity.sessionID, withParts: false)
                users = transcript.messages.filter { $0.role == .user }.map {
                    ConversationMessage(legacy: $0, chatID: identity.sessionID, turnID: $0.id, ord: 0, provider: provider.id, streaming: false)
                }
            }
            guard pendingSends.contains(where: { $0.id == id }) else { return }
            if appears(pending, in: users) {
                pendingSends.removeAll { $0.id == id }
                if draft.isEmpty { callbacks.persistDraft?("") }
                if state.cursor != nil || transportKind == .polling { restartTransport(fresh: true) }
            } else {
                update(id) { $0.delivery = .notSent("It isn’t in the chat on your Mac.") }
            }
        } catch {
            if ClientError.isConnectionFailure(error) { callbacks.connectionFailed?() }
            update(id) { $0.delivery = .notConfirmed }
            notice = ChatNotice("Couldn’t check the chat. \(error.localizedDescription)")
        }
    }

    /// Takes an unsent message back into the composer.
    public func editPending(_ id: UUID) {
        guard let pending = pendingSends.first(where: { $0.id == id }) else { return }
        pendingSends.removeAll { $0.id == id }
        useInComposer(pending.text)
    }

    /// Forgets an unsent message on this device only.
    public func discardPending(_ id: UUID) {
        pendingSends.removeAll { $0.id == id }
    }

    private func update(_ id: UUID, _ change: (inout PendingSend) -> Void) {
        guard let index = pendingSends.firstIndex(where: { $0.id == id }) else { return }
        change(&pendingSends[index])
    }

    /// A request carrying only the fields this host advertises.
    func request(text: String, attachments: [String], clientMessageID: String?) -> ChatSendRequest {
        var request = ChatSendRequest(projectID: identity.projectID, sessionID: identity.sessionID, text: text,
                                      model: selectedModelID.isEmpty ? nil : selectedModelID, attachments: attachments)
        // A plain chat takes no mode or effort: the host answers them, and OpenCode's `agent`, with 400.
        if let choice = selectedModeChoice, !isPlainChat {
            if choice.sentAsMode {
                // A mode that runs without asking goes only from a chat that confirmed it.
                if capabilities?.supports(.modes, provider: provider.id) == true, choice.confirmation == nil || unattendedModeConfirmed {
                    request.mode = choice.id
                }
            } else if options?.agents.contains(choice.id) == true {
                request.agent = choice.id
            }
        }
        if let effort = selectedEffort, plainChatSupports("effort"), capabilities?.supports(.effort, provider: provider.id) == true,
           selectedModel?.efforts?.contains(effort) == true {
            request.effort = effort
        }
        if capabilities?.supports(.clientMessageId) == true { request.clientMessageID = clientMessageID }
        return request
    }

    static func makeClientMessageID() -> String {
        (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased().prefix(40).description
    }

    /// Queues the draft on the host while the agent works.
    public func queueDraft() async {
        guard let client, canQueue, !mutating, attachments.isEmpty else { return }
        guard reachable else {
            notice = ChatNotice("Offline · your draft is kept")
            return
        }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        mutating = true
        defer { mutating = false }
        let agent = isPlainChat ? nil : selectedModeChoice.flatMap { $0.sentAsMode ? nil : $0.id }
        let outcome = await client.enqueue(projectID: identity.projectID, sessionID: identity.sessionID, text: text,
                                           model: selectedModelID.isEmpty ? nil : selectedModelID,
                                           agent: options?.agents.contains(agent ?? "") == true ? agent : nil)
        guard !shutDown else { return }
        switch outcome {
        case .accepted:
            if draft.trimmingCharacters(in: .whitespacesAndNewlines) == text {
                draft = ""
                flushDraft()
            }
            if transportKind == .polling { restartTransport(fresh: false) }
        case .uncertain:
            notice = ChatNotice("The host may have queued this message. Check the queue before adding it again; your draft is kept.")
        case let .failed(error):
            notice = ChatNotice(error.localizedDescription)
        }
    }

    /// Takes a queued message back into the composer; it leaves the queue
    /// first, so it cannot send twice.
    public func editQueued(_ item: QueuedPrompt) async {
        guard await removeQueued(item) else { return }
        useInComposer(item.text)
    }

    @discardableResult
    public func removeQueued(_ item: QueuedPrompt) async -> Bool {
        guard let client, !mutating else { return false }
        mutating = true
        defer { mutating = false }
        let outcome = await client.removeQueued(projectID: identity.projectID, sessionID: identity.sessionID, itemID: item.id)
        guard !shutDown else { return false }
        switch outcome {
        case .accepted:
            state.queue.removeAll { $0.id == item.id }
            state.changes.meta = true
            publish()
            return true
        case .uncertain:
            notice = ChatNotice("The queued message may already be removed. Refresh before trying again.", action: .refreshStatus)
        case let .failed(error):
            notice = ChatNotice(error.localizedDescription)
        }
        return false
    }

    /// Stops the running turn. The queue continues in order afterwards.
    public func stop() async {
        guard let client else { return }
        if let turn = state.turnID ?? state.messages.last(where: { $0.role == .user })?.id { stoppedTurns.insert(turn) }
        let outcome = await client.abort(projectID: identity.projectID, sessionID: identity.sessionID)
        guard !shutDown else { return }
        switch outcome {
        case .accepted:
            endAwaitingTurn()
            if transportKind == .polling { restartTransport(fresh: false) }
        case .uncertain:
            notice = ChatNotice("Stop may have reached the host. Refresh to check.", action: .refreshStatus)
        case let .failed(error):
            notice = ChatNotice(error.localizedDescription)
        }
    }

    /// Reads the chat again from the host, without a cursor.
    public func refreshStatus() {
        notice = nil
        restartTransport(fresh: true)
    }

    private func restartTransport(fresh: Bool) {
        if fresh { state.cursor = nil }
        guard active, client != nil else { return }
        startTransport()
    }

    // MARK: Rewind, Run Again, Fork, Continue

    /// Edit and Resend is offered on the latest user message when the chat's
    /// provider can rewind.
    public var canRewind: Bool {
        guard !isReadOnly, plainChatSupports("rewind"), capabilities?.supports(.rewind) == true else { return false }
        if providerFeaturesKnown { return capabilities?.supports(.rewind, provider: provider.id) == true }
        return provider == .opencode
    }

    /// Whether rewinding also restores files, as the host reports it. A plain chat changes no files.
    public var rewindRestoresFiles: Bool {
        guard !isPlainChat else { return false }
        return capabilities?.supports(.restoreFiles, provider: provider.id) == true || (!providerFeaturesKnown && provider == .opencode)
    }

    public var latestUserMessageID: String? { state.messages.last { $0.role == .user && !$0.parts.allSatisfy { $0.kind == .context } }?.id }

    public var canEditLatest: Bool {
        canRewind && !isWorking && queue.isEmpty && rewind == nil && !mutating && latestUserMessageID != nil
    }

    /// Rewinds the chat to before `messageID` and puts its text back in the composer.
    public func rewind(to messageID: String) async {
        guard let client, canRewind, !mutating, !isWorking else { return }
        let text = projection.message(messageID)?.plainText ?? ""
        mutating = true
        defer { mutating = false }
        let outcome = await client.rewindChat(projectID: identity.projectID, sessionID: identity.sessionID, messageID: messageID)
        guard !shutDown else { return }
        switch outcome {
        case .accepted:
            useInComposer(text)
            if state.messages.first(where: { $0.id == messageID })?.parts.contains(where: { $0.kind == .attachment }) == true {
                notice = ChatNotice("Attach the files again before resending this message.")
            }
            if transportKind == .polling { restartTransport(fresh: false) }
        case .uncertain:
            notice = ChatNotice("Rewind not confirmed. Refresh the chat before trying again.", action: .refreshStatus)
        case let .failed(error):
            notice = ChatNotice(error.localizedDescription)
        }
    }

    public func restoreRewind() async {
        guard let client, !mutating else { return }
        mutating = true
        defer { mutating = false }
        let outcome = await client.restoreChat(projectID: identity.projectID, sessionID: identity.sessionID)
        guard !shutDown else { return }
        switch outcome {
        case .accepted:
            if transportKind == .polling { restartTransport(fresh: false) }
        case .uncertain:
            notice = ChatNotice("Restore may have reached the host. Refresh to check.", action: .refreshStatus)
        case let .failed(error):
            notice = ChatNotice(error.localizedDescription)
        }
    }

    /// Run Again on the latest reply: the host's regenerate when it offers
    /// one, otherwise a rewind and the same prompt sent again.
    public var canRunAgain: Bool {
        guard !isWorking, !mutating, queue.isEmpty, rewind == nil, latestUserMessageID != nil else { return false }
        return hostRegenerates || canRewind
    }

    /// The host runs this chat's latest prompt again (`regenerate`). A host lists it when one of its agents
    /// can; an agent this version cannot name (an ACP agent) takes it only when its provider info lists it
    /// too, so its chats show no Run Again the host would refuse.
    var hostRegenerates: Bool {
        guard !isReadOnly, plainChatSupports("regenerate"), capabilities?.supports(.regenerate) == true else { return false }
        // Older hosts advertise regeneration globally for OpenCode and Claude.
        // Codex uses rewind + send, even when another provider can regenerate.
        if provider == .opencode || provider == .claude { return true }
        return plainChatSupports("regenerate") && capabilities?.chatProviderInfo?[provider.id]?.features.contains(ChatFeature.regenerate.rawValue) == true
    }

    public func runAgain() async {
        guard canRunAgain, let client else { return }
        if let messageID = latestUserMessageID, state.messages.first(where: { $0.id == messageID })?.parts.contains(where: { $0.kind == .attachment }) == true {
            notice = ChatNotice("Attach the files again to retry this message.")
            return
        }
        if hostRegenerates {
            mutating = true
            defer { mutating = false }
            let choice = selectedModeChoice
            let reportsBefore = turnReports
            let outcome = await client.regenerateChat(
                projectID: identity.projectID, sessionID: identity.sessionID,
                model: selectedModelID.isEmpty ? nil : selectedModelID,
                mode: choice?.sentAsMode == true && capabilities?.supports(.modes, provider: provider.id) == true ? choice?.id : nil,
                effort: plainChatSupports("effort") && capabilities?.supports(.effort, provider: provider.id) == true ? selectedEffort : nil)
            guard !shutDown else { return }
            switch outcome {
            // The turn runs the latest prompt again: no new message to wait on.
            case .accepted: awaitTurn(of: nil, reportsBefore: reportsBefore)
            case .uncertain: notice = ChatNotice("Run Again may have reached the host. Refresh to check.", action: .refreshStatus)
            case let .failed(error):
                noteAgentUnavailable(error)
                notice = ChatNotice(error.localizedDescription)
            }
            return
        }
        guard let messageID = latestUserMessageID else { return }
        let text = projection.message(messageID)?.plainText ?? ""
        mutating = true
        let outcome = await client.rewindChat(projectID: identity.projectID, sessionID: identity.sessionID, messageID: messageID)
        mutating = false
        guard !shutDown else { return }
        switch outcome {
        case .accepted:
            let saved = draft
            draft = text
            await send()
            if draft.isEmpty, !saved.isEmpty { draft = saved }
        case .uncertain:
            notice = ChatNotice("Rewind not confirmed. Refresh the chat before trying again.", action: .refreshStatus)
        case let .failed(error):
            notice = ChatNotice(error.localizedDescription)
        }
    }

    /// Sends the latest prompt again as a new turn (an error card's Run Again).
    public func sendPromptAgain() async {
        guard let messageID = latestUserMessageID, let text = projection.message(messageID)?.plainText, !text.isEmpty else { return }
        if state.messages.first(where: { $0.id == messageID })?.parts.contains(where: { $0.kind == .attachment }) == true {
            useInComposer(text)
            notice = ChatNotice("Attach the files again before retrying this message.")
            return
        }
        let saved = draft
        draft = text
        await send()
        if draft.isEmpty, !saved.isEmpty { draft = saved }
    }

    /// Branching is exposed only by providers whose conversation profile supports it.
    public var canFork: Bool {
        guard !isReadOnly, plainChatSupports("fork") else { return false }
        return capabilities?.supports(.fork, provider: provider.id) == true || (capabilities?.supports(.fork) == true && !providerFeaturesKnown)
    }

    public func fork(from messageID: String?) async {
        guard let client, canFork, !mutating else { return }
        mutating = true
        defer { mutating = false }
        let title = (info?.title).map { $0.isEmpty ? "Chat" : $0 } ?? "Chat"
        let outcome = await client.forkChat(projectID: identity.projectID, sessionID: identity.sessionID, messageID: messageID,
                                            title: HostTitle.clipped(title + " (fork)"))
        guard !shutDown else { return }
        switch outcome {
        case let .created(session): callbacks.openChat?(session)
        case .uncertain: notice = ChatNotice("The fork may have been created. Check Resume work before trying again.")
        case let .failed(error): notice = ChatNotice(error.localizedDescription)
        }
    }

    public var canContinue: Bool { capabilities?.supports(.continue) == true }

    /// The agents Continue offers: for a read-only Chats-space chat, the Claude Code and Codex chats the host runs in
    /// its workspaces (`workspaceChats`); OpenCode alone for another plain chat, which continues only into another plain
    /// chat (docs/HOST-API.md "Plain chats"); the host's agents for the others.
    public var continueProviders: [AgentProvider] {
        if isReadOnly { return (capabilities?.workspaceChats?.providers ?? []).map { AgentProvider(id: $0.id) } }
        return isPlainChat ? (capabilities?.plainChats?.availableProviders.contains(where: { $0.id == provider.id }) == true ? [provider] : [])
            : AgentProvider.offered(by: capabilities)
    }

    /// Starts a new chat with another provider or model, seeded from this one; nothing is sent. An ACP agent's new
    /// chat takes no mode or effort, and only `<id>/default` as its model (docs/HOST-API.md "Continue with another
    /// model"). A plain chat continues into a plain chat of OpenCode's, with a model and no mode or effort; a read-only
    /// one into a Claude Code or Codex chat of the workspace in use (`continueWorkspace`). A new chat never starts in a
    /// mode that runs without asking: it asks for itself (`selectMode`).
    public func continueChat(provider target: AgentProvider, model: String?, mode: String?, effort: String?) async -> Bool {
        guard let client, canContinue, !mutating, let projectID = continueProject(for: target) else { return false }
        mutating = true
        defer { mutating = false }
        let plain = isPlainChat && !isReadOnly
        var settings = plain ? (model: model, mode: nil, effort: plainChatSupports("effort") ? effort : nil) : target.continueSettings(model: model, mode: mode, effort: effort)
        if let chosen = settings.mode, ChatModeChoice.make(id: chosen, name: nil, sentAsMode: true, provider: target).confirmation != nil {
            settings.mode = nil
        }
        let outcome = await client.continueChat(ChatContinueRequest(projectID: projectID, sourceSessionID: identity.sessionID,
                                                                    provider: target.id, model: settings.model, mode: settings.mode,
                                                                    effort: settings.effort))
        guard !shutDown else { return false }
        switch outcome {
        case let .created(session):
            callbacks.openChat?(session)
            return true
        case .uncertain:
            notice = ChatNotice("The new chat may have been created. Check Resume work before trying again.")
        case let .failed(error):
            noteAgentUnavailable(error)
            notice = ChatNotice(error.localizedDescription)
        }
        return false
    }

    // MARK: Approvals and questions

    public func reply(to interaction: ChatInteraction, with reply: PermissionReply) async {
        guard let client else { return }
        if reply == .always, !interaction.offersAlways { return }
        interactionDelivery[interaction.id] = .sending
        let outcome = await client.replyPermission(projectID: identity.projectID, sessionID: identity.sessionID,
                                                   requestID: interaction.id, reply: reply)
        finishInteraction(interaction.id, outcome)
    }

    /// Answers every question at once; a tap never submits by itself.
    public func answer(_ interaction: ChatInteraction, answers: [[String]]) async {
        guard let client else { return }
        interactionDelivery[interaction.id] = .sending
        let outcome = await client.replyQuestion(projectID: identity.projectID, sessionID: identity.sessionID,
                                                 requestID: interaction.id, answers: answers)
        finishInteraction(interaction.id, outcome)
    }

    public func dismiss(_ interaction: ChatInteraction) async {
        guard let client else { return }
        interactionDelivery[interaction.id] = .sending
        let outcome = await client.rejectQuestion(projectID: identity.projectID, sessionID: identity.sessionID, requestID: interaction.id)
        finishInteraction(interaction.id, outcome)
    }

    private func finishInteraction(_ id: String, _ outcome: SendOutcome) {
        guard !shutDown, interactions.contains(where: { $0.id == id }) else { return }
        switch outcome {
        case .accepted:
            interactionDelivery[id] = .sent
            if transportKind == .polling { restartTransport(fresh: false) }
        case .uncertain:
            interactionDelivery[id] = .notConfirmed
        case let .failed(error):
            interactionDelivery[id] = .failed(error.localizedDescription)
        }
    }

    // MARK: Export

    /// The chat as Markdown: title, provider and model, then each turn's text. A plain chat belongs to no
    /// workspace, so none is named, and names its agent as Chat does.
    public func markdownExport(workspace: String?) -> String {
        ChatExport.markdown(title: info?.title ?? "", provider: provider, name: isPlainChat ? provider.chatDisplayName : nil,
                            model: info?.model ?? selectedModelID,
                            workspace: isPlainChat ? nil : workspace, messages: state.messages)
    }

    // MARK: Memory

    /// How the Undo of a memory save went.
    public enum MemoryUndo: Equatable, Sendable {
        case undoing
        /// The entry is gone: removed now, or before (404).
        case undone
        /// The answer did not arrive, so the entry may be gone. Check reads the memory again; nothing is sent
        /// again by itself.
        case notConfirmed
        /// Checking an undo that was not confirmed.
        case checking
        /// Nothing changed, for this reason.
        case failed(String)
    }

    /// Undo on each memory save of this chat, by the entry's ID.
    public private(set) var memoryUndo: [String: MemoryUndo] = [:]

    /// A memory save shows Undo while the host takes the memory routes (`capabilities.plainChats` lists `memory`), in
    /// OpenCode's plain chats alone: Claude Code and Codex have no AgentLand memory (owner, 2026-10-12, "dont need"),
    /// so their old "Memory updated" cards keep their text without Undo.
    public var offersMemoryUndo: Bool { isPlainChat && provider == .opencode && capabilities?.plainChats?.offers(.memory) == true }

    /// Undo on a "Memory updated" card: removes the entry the save stored (`DELETE /v1/memory`). A page the model
    /// read can ask it to remember something, so every save can be undone from where it shows. Refused offline;
    /// an answer that did not arrive shows as not confirmed, and only Undo or Check sends anything again.
    public func undoMemory(_ memory: ChatToolMemory) async {
        guard offersMemoryUndo else { return }
        switch memoryUndo[memory.id] {
        case .undoing?, .undone?, .checking?: return
        default: break
        }
        guard reachable, let client else {
            notice = ChatNotice("Offline · memory wasn’t changed")
            return
        }
        memoryUndo[memory.id] = .undoing
        let outcome = await client.deleteMemory(id: memory.id)
        guard !shutDown else { return }
        switch outcome {
        case .removed, .refused(.notFound, _):
            memoryUndo[memory.id] = .undone
            if active { announcer("Removed from memory") }
        case .uncertain:
            memoryUndo[memory.id] = .notConfirmed
        case let .refused(refusal, message):
            memoryUndo[memory.id] = .failed(Self.memoryRefusalText(refusal, message: message))
        case let .failed(error):
            if error == .unreachable { callbacks.connectionFailed?() }
            memoryUndo[memory.id] = .failed(error.localizedDescription)
        }
    }

    /// Check on an Undo that was not confirmed: reads the memory, never deletes again. The entry gone means it was
    /// undone; still there, Undo shows again.
    public func checkMemoryUndo(_ memory: ChatToolMemory) async {
        guard offersMemoryUndo, memoryUndo[memory.id] == .notConfirmed, let client else { return }
        guard reachable else {
            notice = ChatNotice("Offline · reconnect to check your memory")
            return
        }
        memoryUndo[memory.id] = .checking
        do {
            let list = try await client.memory()
            guard !shutDown else { return }
            memoryUndo[memory.id] = list.entries.contains { $0.id == memory.id } ? nil : .undone
        } catch {
            guard !shutDown else { return }
            if ClientError.isConnectionFailure(error) { callbacks.connectionFailed?() }
            memoryUndo[memory.id] = .notConfirmed
            notice = ChatNotice("Couldn’t check your memory. \(error.localizedDescription)")
        }
    }

    static func memoryRefusalText(_ refusal: MemoryRefusal, message: String) -> String {
        switch refusal {
        case .unavailable: "Memory isn’t available on your Mac right now."
        case .notFound, .overLimit: message.isEmpty ? "Your Mac refused the change." : message
        }
    }

    /// Memory entries whose save this chat has shown. A save that arrives on the stream is announced; saves a
    /// snapshot or a reload brings are only noted.
    @ObservationIgnored private var seenMemorySaves: Set<String> = []

    private func noteMemorySaves(reset: Bool) {
        // Only OpenCode's plain chats have the memory tools.
        guard isPlainChat, provider == .opencode else { return }
        // Saves arrive in the running turn: the messages after the latest prompt. A reset brings them all.
        let start = reset ? state.messages.startIndex : (state.messages.lastIndex { $0.role == .user } ?? state.messages.startIndex)
        var fresh: [ChatToolMemory] = []
        for message in state.messages[start...] where message.role == .assistant {
            for part in message.parts {
                // Saves only: a forget's part carries the entry it removed.
                guard let tool = part.tool, tool.status == .completed, let memory = tool.memory,
                      ChatPlainToolKind(toolName: tool.name) == .memorySave, !seenMemorySaves.contains(memory.id) else { continue }
                seenMemorySaves.insert(memory.id)
                fresh.append(memory)
            }
        }
        guard !reset, active else { return }
        for memory in fresh { announcer("Memory updated: \(memory.text)") }
    }
}

/// Error card titles and guidance by category.
public struct ChatErrorCopy: Equatable, Sendable {
    public let title: String
    public let guidance: String?
    public let announcement: String

    public static func category(_ error: ConversationError, provider: AgentProvider) -> ChatErrorCopy {
        let name = provider.chatDisplayName
        if error.code == AgentErrorCode.authRequired {
            // The terminal opens the program, which Chat may call otherwise (an agent the host names differently).
            let program = name == provider.displayName ? "it" : provider.displayName
            return ChatErrorCopy(title: "Sign In to \(name)", guidance: "Open \(program) in a terminal and follow its sign-in, then choose Run Again.",
                                 announcement: "Reply failed: \(name) needs you to sign in")
        }
        let lowered = (error.code + " " + error.message).lowercased()
        if error.code == "provider_auth" || lowered.contains("not signed in") || lowered.contains("unauthorized") || lowered.contains("api key") {
            return ChatErrorCopy(title: "\(name) Isn’t Signed In", guidance: "Sign in on your Mac, then choose Run Again.",
                                 announcement: "Reply failed: \(name) isn’t signed in")
        }
        if lowered.contains("rate limit") || lowered.contains("429") || lowered.contains("overloaded") || lowered.contains("too many requests") {
            return ChatErrorCopy(title: "Rate Limited", guidance: "Wait a moment, then choose Run Again.", announcement: "Reply failed: rate limited")
        }
        if error.code == "delivery_uncertain" || lowered.contains("connection") || lowered.contains("unreachable") {
            return ChatErrorCopy(title: "Couldn’t Reach Your Mac", guidance: nil, announcement: "Reply failed: couldn’t reach your Mac")
        }
        return ChatErrorCopy(title: "Reply Failed", guidance: nil, announcement: "Reply failed")
    }
}

public enum ChatExport {
    /// Copy Chat: reasoning and tool details are left out; attachments are listed by name. The agent is named
    /// `name`, else its `displayName`.
    public static func markdown(title: String, provider: AgentProvider, name: String? = nil, model: String?, workspace: String?,
                                messages: [ConversationMessage]) -> String {
        let name = name ?? provider.displayName
        var lines: [String] = ["# " + (title.isEmpty ? "Chat" : title)]
        var subtitle = name
        if let model, !model.isEmpty { subtitle += " · " + model }
        if let workspace, !workspace.isEmpty { subtitle += " · " + workspace }
        lines.append("")
        lines.append("_\(subtitle)_")
        var lastRole: MessageRole?
        for message in messages {
            let text = message.parts.filter { $0.kind == .text }.map(\.text).joined(separator: "\n\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let files = message.parts.compactMap(\.attachment).map(\.name)
            guard !text.isEmpty || !files.isEmpty else { continue }
            if lastRole != message.role {
                lines.append("")
                lines.append(message.role == .user ? "**Me**" : "**\(name)**")
                lastRole = message.role
            }
            lines.append("")
            if !files.isEmpty { lines.append("Attachments: " + files.joined(separator: ", ")) }
            if !text.isEmpty { lines.append(text) }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
