import Foundation
import Observation
import AgentLandCore
import AgentLandChat
import AgentLandArchive

/// The control that owns a dirty-file close confirmation.
public enum WorkspaceTabCloseSource: Equatable, Sendable {
    case menu, row, header
}

/// Identifies one opening of the workspace: the host and the tab selected when it began. Only that
/// tab's surface can report readiness for it, and only a display frame of the prepared workspace
/// completes it.
public struct WorkspacePresentationTicket: Hashable, Sendable {
    public let id: UUID
    public let hostID: String
    public let tabID: UUID?

    public init(id: UUID = UUID(), hostID: String, tabID: UUID?) {
        self.id = id
        self.hostID = hostID
        self.tabID = tabID
    }
}

/// Where a workspace remembers its per-host choices in user defaults. Each key is a prefix followed by
/// the connection identity's storage key.
public struct WorkspaceStorageKeys: Sendable, Equatable {
    /// The workspace (project) the person opened on this host.
    public var currentWorkspace: String
    /// The tab each workspace last showed.
    public var tabSelections: String
    /// When each workspace was last the one in use on this device (the Workspaces screen shows it).
    public var lastUsed: String

    /// `lastUsed` defaults to a key beside `currentWorkspace`.
    public init(currentWorkspace: String, tabSelections: String, lastUsed: String? = nil) {
        self.currentWorkspace = currentWorkspace
        self.tabSelections = tabSelections
        self.lastUsed = lastUsed ?? currentWorkspace + "lastUsed."
    }

    /// The keys the iPhone and iPad app has always used.
    public static let mobile = WorkspaceStorageKeys(currentWorkspace: "agentland.workspace.current.",
                                                    tabSelections: "agentland.workspace.selection.",
                                                    lastUsed: "agentland.workspace.lastUsed.")
}

/// One host's workspace: its projects, the open tabs and the selected one, the live session of
/// every open tab, and the actions the surfaces share. The app that owns it decides which host is
/// attached, whether it is reachable and whether a lock covers it; the workspace keeps everything
/// that belongs to the tabs.
@MainActor @Observable public final class WorkspaceModel {
    // MARK: Host

    /// The attached host's identifier; nil while no host is attached.
    public private(set) var hostID: String?
    /// The identity the tabs and choices are saved under.
    public private(set) var identity: ConnectionIdentity?
    /// The host's name as the person saved it, for labels such as "Searched on Studio Mac".
    public var hostName = "your Mac"
    public var client: APIClient?
    public var projects: [Project] = []
    public var capabilities: CapabilitiesResponse?
    public private(set) var loadingProjects = false
    /// The host's projects and capabilities were answered, or failed, for the attached host.
    public private(set) var metadataResolved = false
    /// Why the host's workspaces can't be listed: a failed load or a missing credential.
    public var hostIssue: String?
    /// Whether the host answers, as the owning app's connection logic decides. Surfaces pause their
    /// polling and refuse input while it is false.
    public var reachable = true
    /// Increments each time the host is reachable again after an outage, so retained surfaces resume
    /// from their cursors and reload what failed meanwhile.
    public var connectionEpoch = 0
    /// How far this run of the app's renderers have read each terminal's output. A terminal made here starts
    /// at 0, so the queries in its first output are answered. A terminal missing here was made in an earlier
    /// run, whose renderer answered the queries in its history; a later session reading it again (after the
    /// tab closed or the host changed) leaves the queries this run answered before it.
    @ObservationIgnored var terminalOutputReadHere: [String: UInt64] = [:]
    /// The app lock covers the workspace. Surfaces keep their state but stop streaming and input.
    public var locked = false {
        didSet {
            guard locked, !oldValue else { return }
            naming.stop()
            // Unlocking reveals the work surfaces again: the clown comes out of the door once more.
            circusRevealedAt = nil
        }
    }
    /// A surface saw a transport failure. The owning app decides whether the host is actually gone.
    @ObservationIgnored public var onConnectionFailure: (() -> Void)?

    // MARK: Tabs

    let phoneNavigation = WorkspacePhoneNavigation()
    public var tabs: [WorkspaceTab] = []
    public var selectedTabID: UUID? {
        didSet {
            // Session selection restores its UI workspace; Chat's API project remains the Chats space.
            if let tab = currentTab, let owner = workspaceID(for: tab) {
                selectedProjectID = owner
                if tab.kind != .home { workspaceSelections[owner] = tab.id }
                rememberWorkspace()
            }
            if selectedTabID != oldValue {
                if sessionPresentationTicket?.tabID != selectedTabID { sessionPresentationTicket = nil }
                saveTabs()
                if presentationPending { beginPresentation() }
            }
        }
    }
    /// The workspace the person chose. Nothing is assumed from the host's project list.
    public var selectedProjectID: String? {
        didSet {
            // The workspace left and the one chosen were both in use until now.
            guard selectedProjectID != oldValue, !restoringSelection else { return }
            noteUse([oldValue, selectedProjectID].compactMap { $0 })
        }
    }
    /// When each workspace was last the one in use on this device, saved per host and device identity.
    public private(set) var lastUsed: [String: Date] = [:]
    /// Closed here (the Workspaces screen's Close), not removed from the host: not open on this device
    /// (`WorkspaceSummary.isOpen`) until it is in use again.
    private(set) var closedWorkspaceIDs: Set<String> = []
    /// Attaching restores the saved choice; that is not a use.
    @ObservationIgnored private var restoringSelection = false
    /// A dirty editor waiting for the person to confirm closing it.
    public private(set) var pendingCloseTab: WorkspaceTab?
    /// The invoking control owns the confirmation: a task row, the header X, or the
    /// shell's menu anchor. Row and header controls must not present one another's question.
    public private(set) var pendingCloseSource: WorkspaceTabCloseSource = .menu
    public var pendingCloseFromRow: Bool { pendingCloseSource == .row }
    /// Bumped by Reload; a surface's results count only for the generation they were requested in.
    public private(set) var tabRefreshGeneration: [UUID: UUID] = [:]
    /// Bumped by Find (⌘F): the surface in front shows its find field.
    public private(set) var findRequest = 0
    /// Bumped by Regenerate (⇧⌘R): the chat in front asks to run its latest prompt again.
    public private(set) var runAgainRequest = 0
    /// The surface views showing each tab. The detail column can build a surface again in place, and
    /// the new view may appear before the old one disappears.
    @ObservationIgnored private var surfaceViews: [UUID: Set<UUID>] = [:]

    /// Per-host/device ownership survives closing tabs and workspaces, including a relaunch.
    var chatWorkspaceIDs: [String: String] = [:]
    public var pendingSessionResume: WorkspaceResumeTarget?
    /// Bumped by every Resume that waits for a workspace choice: the shell asks on each one, even when the
    /// same session is asked for again while `pendingSessionResume` holds it still.
    public internal(set) var sessionResumeRequest = 0
    /// The Home tab the waiting Resume was launched from, which it replaces once the workspace is chosen.
    @ObservationIgnored var pendingResumeHomeID: UUID?
    public var resumedArchive: WorkspaceResumeTarget?

    // MARK: Opening

    public private(set) var presentationTicket: WorkspacePresentationTicket?
    private var presentationSurfaceReady = false
    /// The host answered on no address during this opening (see `resolvePresentationOffline`).
    private var presentationResolvedOffline = false

    /// When Home or an empty chat's landing was first shown after the opening cover or an unlock: the moment
    /// the circus's first clown comes out of the tent's door. Tab switches, sheets, scene changes and views
    /// built again keep it; a new opening (`beginPresentation`) and the lock clear it.
    public private(set) var circusRevealedAt: Date?

    /// Home or a landing shows its circus in front: the first time after the cover or an unlock, that moment
    /// is the reveal. Nothing is revealed while the opening cover or the lock is up.
    public func circusShown(at date: Date = Date()) {
        guard circusRevealedAt == nil, !presentationPending, !locked else { return }
        circusRevealedAt = date
    }

    // MARK: Creation

    /// A chat or terminal is being created on the host.
    public private(set) var creating = false
    /// Creation and the new surface's first resolved content share one continuous cover. This ticket
    /// uses the surfaces' existing readiness reports without restarting the whole-app opening.
    private var sessionPresentationTicket: WorkspacePresentationTicket?
    public var sessionOpening: Bool { creating || sessionPresentationTicket != nil }
    /// Why the last creation could not be confirmed.
    public var creationIssue: String?

    // MARK: Sessions

    /// The live state of every open tab, owned here rather than by the views, so a surface can be torn
    /// down and built again without losing its renderer, stream, draft or listing.
    @ObservationIgnored public let sessions = WorkspaceSessionRegistry()

    // MARK: Archive and sidebar

    /// The attached host's copy on this device, when this device keeps one. The owning app opens it
    /// with the host and drives its sync; chats read it first, and the sidebar lists its chats.
    public private(set) var archive: WorkspaceArchive? {
        didSet {
            guard archive !== oldValue else { return }
            // Workspaces added, made or removed on another device move the host's feed to another epoch.
            archive?.onEpochChange = { [weak self] in Task { await self?.refreshProjects() } }
            // Once the copy has caught up in a foreground period, its recent chats are named.
            archive?.onCaughtUp = { [weak self] in self?.naming.archiveCaughtUp() }
        }
    }
    /// The copy while it opens off the main actor (`openArchive`). Chats made meanwhile read it once
    /// it has opened.
    @ObservationIgnored private var archiveOpening: Task<WorkspaceArchive?, Never>?
    /// Done once the copy the last `detach()` let go of has stopped (and one still opening then has opened and
    /// stopped): its files can be deleted after that.
    @ObservationIgnored public private(set) var archiveClosing: Task<Void, Never>?
    /// The sidebar's lists: the chat library, the host's terminals and the Git change count.
    @ObservationIgnored public let sidebar = WorkspaceSidebarModel()
    /// "On <device>": the terminals open on the owner's other devices and on the Mac, for hosts that share them.
    @ObservationIgnored public let others = OtherDevicesModel()
    /// The tabs of terminals shown on a screen of their own (`openShared`, outside any workspace this device knows), by
    /// tab ID. They never join `tabs`; each one's session lives in `sessions` until its screen goes (`endStandalone`) or
    /// the host changes.
    @ObservationIgnored var standaloneTabs: [UUID: WorkspaceTab] = [:]
    /// Where each terminal's name came from, by terminal ID, as the host's lists last said or this device's accepted
    /// name: a device's name stays over the program's later titles, as the host keeps it (`TerminalSession`).
    @ObservationIgnored var terminalNameSources: [String: TerminalNameSource] = [:]
    /// Chat names from this device's language model, for hosts that take them (`ChatNaming`). The owning
    /// app says when a foreground period begins and ends.
    @ObservationIgnored public let naming = ChatNaming()

    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored let keys: WorkspaceStorageKeys
    @ObservationIgnored private let persistence: WorkspacePersistence
    @ObservationIgnored private var workspaceSelections: [String: UUID] = [:]
    /// Changes whenever a host is attached or detached; results from an earlier attachment are dropped.
    @ObservationIgnored private var attachment = UUID()
    /// Capabilities reads started (`refreshProjects`, `refreshCapabilities`), and the newest whose answer applies:
    /// an older read that answers later never undoes a newer one's answer.
    @ObservationIgnored private var capabilitiesReads = 0
    @ObservationIgnored private var capabilitiesReadApplied = 0
    /// The plain chats revision the pulse named that capabilities were last read for, and one being read.
    @ObservationIgnored private var plainChatsRevision: String?
    @ObservationIgnored private var plainChatsRevisionReading: String?
    @ObservationIgnored private var creationTask: Task<Void, Never>?
    @ObservationIgnored private var creationID = UUID()

    public init(defaults: UserDefaults = .standard, keys: WorkspaceStorageKeys = .mobile) {
        self.defaults = defaults
        self.keys = keys
        persistence = WorkspacePersistence(defaults: defaults)
        sidebar.workspace = self
        naming.workspace = self
        others.workspace = self
    }

    // MARK: Attaching a host

    /// Shows `hostID`'s saved workspace: its tabs, selection and chosen project. Sessions of the
    /// previous host end. The opening cover is established before this returns. Without a client
    /// the workspace resolves at once with `issue`.
    public func attach(hostID: String, identity: ConnectionIdentity, client: APIClient?, issue: String? = nil,
                       archive: WorkspaceArchive? = nil) {
        endHostWork()
        if self.archive !== archive { self.archive?.close() }
        // Before any chat store exists, so every chat of this host reads the copy first.
        self.archive = archive
        archiveOpening = nil
        attachment = UUID()
        metadataResolved = false
        loadingProjects = true
        // Identity first: the selection's didSet saves under the new host.
        self.hostID = hostID
        self.identity = identity
        // A saved OpenCode counts as no choice: OpenCode left Chat on 2026-10-12 (`newPlainChatProvider`).
        let savedProvider = defaults.string(forKey: Self.plainChatModelKey + identity.storageKey + ".provider")
        plainChatProviderChosen = savedProvider != nil && savedProvider != AgentProvider.opencode.id
        plainChatDefaultProvider = plainChatProviderChosen ? AgentProvider(id: savedProvider ?? "") : .claude
        plainChatDefaultModel = plainChatDefaultModel(for: plainChatDefaultProvider)
        self.client = nil
        projects = []
        capabilities = nil
        hostIssue = nil
        restoringSelection = true
        selectedProjectID = defaults.string(forKey: keys.currentWorkspace + identity.storageKey)
        lastUsed = (defaults.data(forKey: keys.lastUsed + identity.storageKey)
            .flatMap { try? JSONDecoder().decode([String: Date].self, from: $0) }) ?? [:]
        closedWorkspaceIDs = Set(defaults.stringArray(forKey: keys.currentWorkspace + "closedInMenu." + identity.storageKey) ?? [])
        chatWorkspaceIDs = defaults.dictionary(forKey: keys.currentWorkspace + "chatWorkspaces." + identity.storageKey) as? [String: String] ?? [:]
        let restored = persistence.loadState(for: identity)
        workspaceSelections = (defaults.data(forKey: keys.tabSelections + identity.storageKey)
            .flatMap { try? JSONDecoder().decode([String: UUID].self, from: $0) }) ?? [:]
        tabs = restored.tabs
        if defaults.object(forKey: keys.currentWorkspace + "closedInMenu." + identity.storageKey) == nil {
            // Older saves kept last use but no closed-menu state. Keep active/tabbed workspaces;
            // a previously used workspace with neither has already been closed on this device.
            let openIDs = Set(tabs.map(\.projectID)).union([selectedProjectID].compactMap { $0 })
            closedWorkspaceIDs = Set(lastUsed.keys).subtracting(openIDs)
            saveClosedWorkspaces()
        }
        selectedTabID = restored.selectedTabID
        restoringSelection = false
        pendingCloseTab = nil
        tabRefreshGeneration = [:]
        // Establish the cover synchronously. Waiting until the project load's Task runs permits a
        // frame of the restored tab's empty or loading surface to escape.
        beginPresentation()
        guard let client else {
            hostIssue = issue
            loadingProjects = false
            metadataResolved = true
            return
        }
        self.client = client
    }

    /// Opens the attached host's copy on this device without holding up the opening: `open` does its
    /// file work off the main actor, and the copy is attached once it has opened, unless another host
    /// was attached (or none) meanwhile. Chats made before then read it as soon as it has opened.
    /// `opened` runs with the attached copy (the owning app hands it the client and starts its sync).
    public func openArchive(_ open: @escaping @MainActor () async -> WorkspaceArchive?,
                            opened: @escaping @MainActor (WorkspaceArchive) -> Void = { _ in }) {
        let stamp = attachment
        archiveOpening = Task { @MainActor [weak self] in
            let archive = await open()
            guard let self, self.attachment == stamp, let archive else {
                archive?.close()
                await archive?.settle()
                return nil
            }
            self.archive = archive
            self.archiveOpening = nil
            opened(archive)
            return archive
        }
    }

    /// Leaves the host: sessions end and the workspace empties. The saved tabs stay saved.
    public func detach() {
        endHostWork()
        archive?.close()
        let closing = archive, opening = archiveOpening
        archiveClosing = Task {
            _ = await opening?.value
            await closing?.settle()
        }
        archive = nil
        archiveOpening = nil
        attachment = UUID()
        client = nil
        // Clear the identity before the selection, so emptying the tabs saves nothing.
        identity = nil
        hostID = nil
        projects = []
        capabilities = nil
        hostIssue = nil
        tabs = []
        selectedTabID = nil
        pendingCloseTab = nil
        tabRefreshGeneration = [:]
        workspaceSelections = [:]
        lastUsed = [:]
        closedWorkspaceIDs = []
        chatWorkspaceIDs = [:]
        pendingSessionResume = nil
        resumedArchive = nil
        plainChatDefaultModel = nil
        loadingProjects = false
        presentationTicket = nil
        presentationSurfaceReady = false
        presentationResolvedOffline = false
        metadataResolved = false
    }

    /// Removes what this workspace saved for `identity`: its tabs (drafts included), the workspace in use and each
    /// workspace's last tab and use, the phone's closed workspaces, and the plain chats' default model.
    public func forgetSavedState(for identity: ConnectionIdentity) {
        persistence.save([], for: identity)
        defaults.removeObject(forKey: keys.tabSelections + identity.storageKey)
        defaults.removeObject(forKey: keys.currentWorkspace + identity.storageKey)
        defaults.removeObject(forKey: keys.lastUsed + identity.storageKey)
        defaults.removeObject(forKey: keys.currentWorkspace + "chatWorkspaces." + identity.storageKey)
        defaults.removeObject(forKey: keys.currentWorkspace + "closedInMenu." + identity.storageKey)
        // WorkspacePhoneNavigation's closed workspaces.
        defaults.removeObject(forKey: "agentland.phone.closedWorkspaces." + identity.storageKey)
        defaults.removeObject(forKey: Self.plainChatModelKey + identity.storageKey)
        defaults.removeObject(forKey: Self.plainChatModelKey + identity.storageKey + ".provider")
        defaults.removeObject(forKey: Self.plainChatModelKey + identity.storageKey + ".models")
    }

    /// Clears this device's copy of the attached host's chats and terminal logs and makes it again from the host
    /// (`WorkspaceArchive.clearCopy`). Tabs and their drafts stay. Nothing to do without a copy.
    public func clearDeviceCopy() async throws {
        if archive == nil, let opening = archiveOpening { _ = await opening.value }
        try await archive?.clearCopy()
    }

    // MARK: Chat's provider and model

    /// Where the model new chats start with is saved, followed by the host's storage key.
    public static let plainChatModelKey = "agentland.chat.defaultModel."

    /// Settings → Chat: the model new chats of `plainChatDefaultProvider` on the attached host start with (the host's
    /// lists' ID); nil leaves it to the host, as before. Saved per host and device identity.
    public private(set) var plainChatDefaultModel: String?

    public private(set) var plainChatDefaultProvider: AgentProvider = .claude
    /// The person chose `plainChatDefaultProvider` (it was saved), as opposed to the default, Claude.
    @ObservationIgnored private var plainChatProviderChosen = false

    /// Chat's agents now (owner's decision, 2026-10-12: Chat is Claude Code and Codex in the selected workspace): the
    /// providers `capabilities.workspaceChats` lists, then OpenCode in the Chats space while the host lists it there
    /// (`--opencode-chat`: a development and test host; the Mac app never passes it). A host without `workspaceChats`
    /// offers no Chat: there is no Chats-space fallback.
    public var plainChatProviders: [PlainChatProvider] {
        guard let workspaceChats = capabilities?.workspaceChats else { return [] }
        return workspaceChats.providers + chatsSpaceChatProviders
    }

    /// The providers Chat starts in the Chats space: OpenCode while the host lists it in `generalChats` (`--opencode-chat`).
    /// Claude Code and Codex start in the workspace only.
    private var chatsSpaceChatProviders: [PlainChatProvider] {
        (capabilities?.plainChats?.availableProviders ?? []).filter { !Self.isChatAgent($0.id) }
    }

    /// Providers the host found installed but not signed in with a subscription, which Chat does not use
    /// (`WorkspaceChatsCapability.unavailableProviders`); Settings says how to sign in.
    public var plainChatUnavailableProviders: [PlainChatProvider] { capabilities?.workspaceChats?.unavailableProviders ?? [] }

    /// The provider a new chat starts with when none is asked for: the host's only one; the saved choice; with none
    /// saved, Claude Code when the host offers it, else the host's first. Chat runs on the Mac's Claude and ChatGPT
    /// subscriptions (owner's decision, 2026-10-12): a saved OpenCode counts as none, since Chat never offers it. A
    /// saved choice the host does not offer is never switched silently.
    public var newPlainChatProvider: AgentProvider {
        let offered = plainChatProviders.map { AgentProvider(id: $0.id) }
        if offered.count == 1 { return offered[0] }
        if plainChatProviderChosen || offered.contains(plainChatDefaultProvider) { return plainChatDefaultProvider }
        return offered.contains(.claude) ? .claude : offered.first ?? plainChatDefaultProvider
    }

    public func plainChatDefaultModel(for provider: AgentProvider) -> String? {
        guard let identity else { return nil }
        let key = Self.plainChatModelKey + identity.storageKey
        if provider == .opencode { return defaults.string(forKey: key) }
        return defaults.dictionary(forKey: key + ".models")?[provider.id] as? String
    }

    public func setPlainChatDefaultProvider(_ provider: AgentProvider) {
        guard let identity else { return }
        plainChatDefaultProvider = provider
        plainChatProviderChosen = true
        defaults.set(provider.id, forKey: Self.plainChatModelKey + identity.storageKey + ".provider")
        plainChatDefaultModel = plainChatDefaultModel(for: provider)
    }

    public func setPlainChatDefaultModel(_ model: String?) {
        guard let identity else { return }
        let model = model?.isEmpty == true ? nil : model
        plainChatDefaultModel = model
        let key = Self.plainChatModelKey + identity.storageKey
        if plainChatDefaultProvider == .opencode {
            if let model { defaults.set(model, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        } else {
            var values = defaults.dictionary(forKey: key + ".models") ?? [:]
            values[plainChatDefaultProvider.id] = model
            defaults.set(values, forKey: key + ".models")
        }
    }

    private func endHostWork() {
        pendingSessionResume = nil
        resumedArchive = nil
        naming.hostChanged()
        sessions.endAll()
        standaloneTabs = [:]
        terminalNameSources = [:]
        others.reset()
        sidebar.reset()
        workspacesModel?.reset()
        agentsModel?.reset()
        aiProvidersModel?.reset()
        vaultModel?.reset()
        creationTask?.cancel()
        creationTask = nil
        creationID = UUID()
        creating = false
        sessionPresentationTicket = nil
        creationIssue = nil
        plainChatsRevision = nil
        plainChatsRevisionReading = nil
    }

    /// Loads the host's projects and capabilities for the attached host.
    public func refreshProjects() async {
        guard let client, let hostID else { return }
        let stamp = attachment
        loadingProjects = true
        defer {
            if stamp == attachment {
                loadingProjects = false
                metadataResolved = true
            }
        }
        let read = startCapabilitiesRead()
        do {
            async let fetchedCapabilities = try? client.capabilities()
            let result = try await client.projects()
            let caps = await fetchedCapabilities
            guard stamp == attachment, self.hostID == hostID else { return }
            projects = result
            // A capabilities read that failed keeps what this host answered before (attaching clears it).
            if let caps { _ = apply(caps, read: read) }
            if let selected = selectedProjectID, !result.contains(where: { $0.id == selected }) { selectedProjectID = nil }
            if let tab = currentTab, isPlainChat(tab) {
                if let owner = workspaceID(for: tab), projects.contains(where: { $0.id == owner }) { selectProject(owner) }
                else { selectedTabID = nil }
            }
            hostIssue = nil
        } catch {
            guard stamp == attachment else { return }
            hostIssue = error.localizedDescription
        }
    }

    /// Reads the host's capabilities again, as when the pulse names another plain chats revision or a plain
    /// chat's send finds the host's `chat` agent gone. True once they were read and apply, or a read started
    /// later already applied; an answer for another host or connection is dropped. The device's copy takes
    /// them too.
    @discardableResult
    public func refreshCapabilities() async -> Bool {
        guard let stamp = requestStamp() else { return false }
        let attachmentAtStart = attachment
        let number = startCapabilitiesRead()
        guard let read = try? await stamp.client.capabilities(),
              isCurrent(stamp), attachment == attachmentAtStart else { return false }
        if apply(read, read: number) { archive?.update(client: stamp.client, capabilities: read) }
        return true
    }

    /// Has this Mac's host check Claude Code's and Codex's sign-ins now, then reads the capabilities, so a sign-in made
    /// a moment ago shows at once (the Mac's setup and Settings → Agents, owner 2026-10-17). A host without the check
    /// (404) or one that could not check is read as it is. The route is this Mac's session's alone. False when the
    /// capabilities were not read.
    @discardableResult
    public func checkChatSignIns() async -> Bool {
        if let client { _ = try? await client.checkChatSignIns() }
        return await refreshCapabilities()
    }

    private func startCapabilitiesRead() -> Int {
        capabilitiesReads += 1
        return capabilitiesReads
    }

    /// The answer of capabilities read `read`, unless a read started after it already applied. False when dropped.
    private func apply(_ read: CapabilitiesResponse, read number: Int) -> Bool {
        guard number > capabilitiesReadApplied else { return false }
        capabilitiesReadApplied = number
        if capabilities != read { capabilities = read }
        if let tab = currentTab, !supportsTab(tab) { selectedTabID = nil }
        followOfferedPlainChatProvider()
        return true
    }

    /// With no provider chosen, the default follows what the host offers (`newPlainChatProvider`), so Settings'
    /// model and a new chat name the same provider. Nothing is saved until a chat or Settings chooses one.
    private func followOfferedPlainChatProvider() {
        guard !plainChatProviderChosen, !plainChatProviders.isEmpty else { return }
        let provider = newPlainChatProvider
        guard provider != plainChatDefaultProvider else { return }
        plainChatDefaultProvider = provider
        plainChatDefaultModel = plainChatDefaultModel(for: provider)
    }

    /// The pulse named `revision` for `capabilities.plainChats` (docs/HOST-API.md "Plain chats"): another
    /// revision than the one capabilities were last read for reads them again. A read that fails leaves the
    /// revision unread, so the line the pulse sends after its next `ready` reads them again.
    public func notePlainChatsRevision(_ revision: String) {
        guard revision != plainChatsRevision, revision != plainChatsRevisionReading else { return }
        plainChatsRevisionReading = revision
        let attachmentAtStart = attachment
        Task { [weak self] in
            guard let self else { return }
            let read = await self.refreshCapabilities()
            guard self.attachment == attachmentAtStart, self.plainChatsRevisionReading == revision else { return }
            self.plainChatsRevisionReading = nil
            if read { self.plainChatsRevision = revision }
        }
    }

    /// Surfaces call this after a transport failure.
    public func noteConnectionFailure() { onConnectionFailure?() }

    // MARK: Queries

    public var currentProject: Project? { projects.first { $0.id == selectedProjectID } }
    public var currentTab: WorkspaceTab? { tabs.first { $0.id == selectedTabID } }
    /// The host's workspace list is not known for this attachment: it is loading, or the host could not be asked
    /// (out of reach, or not paired: `hostIssue`). Meanwhile the tabs and workspace restored on this device stand for
    /// it: the iPhone's switcher lists them and choosing an open tab selects it (2026-10-12).
    var workspaceListPending: Bool { projects.isEmpty && (!metadataResolved || hostIssue != nil) }
    /// The open tabs the tab list shows: the plain chats, whatever workspace is open, and the current
    /// workspace's tabs, in the order they were opened or moved to.
    public var workspaceTabs: [WorkspaceTab] { tabs.filter(listsTab) }

    /// Whether the tab list shows `tab` now: a plain chat always, another tab while its workspace is open.
    private func listsTab(_ tab: WorkspaceTab) -> Bool { supportsTab(tab) && (workspaceID(for: tab) == selectedProjectID || (isPlainChat(tab) && workspaceID(for: tab) == nil)) }

    /// Whether `tab` is an app surface: every tab but a chat Chat does not show (`isChatShown`). Other agents'
    /// workspace chats (OpenCode, ACP agents) stay saved for compatibility, but are no app surfaces.
    func supportsTab(_ tab: WorkspaceTab) -> Bool { tab.kind != .chat || isPlainChat(tab) || isWorkspaceChat(tab) }

    /// Chat's agents in a workspace: Claude Code and Codex (owner's decision, 2026-10-12).
    public static func isChatAgent(_ provider: String) -> Bool {
        provider == AgentProvider.claude.id || provider == AgentProvider.codex.id
    }

    /// A Claude Code or Codex chat in one of the host's workspaces: Chat's own chats since 2026-10-12. It belongs to
    /// its workspace (`projectID`) like a terminal; resuming it opens that workspace.
    public func isWorkspaceChat(_ tab: WorkspaceTab) -> Bool {
        tab.kind == .chat && !isChatsSpace(tab.projectID) && Self.isChatAgent(ChatSessionStore.provider(forSession: tab.resourceID).id)
    }

    /// Whether Chat shows the chat `chatID` of `projectID` (its tabs, library, search, Resume and notices): every chat
    /// of the Chats space, which stay readable, and Claude Code and Codex chats in a workspace. `provider` is the
    /// chat's agent when the caller knows it; otherwise the chat's ID names it.
    public func isChatShown(_ chatID: String, projectID: String, provider: String? = nil) -> Bool {
        isChatsSpace(projectID) || Self.isChatAgent(provider ?? ChatSessionStore.provider(forSession: chatID).id)
    }

    // MARK: Plain chats

    /// The host offers Chat now: Claude Code or Codex chats in its workspaces (`capabilities.workspaceChats`).
    public var offersPlainChats: Bool { !plainChatProviders.isEmpty }

    /// The host's Chats space (`PlainChatsCapability.chatsSpace`): the one its plain chats name; while it lists
    /// none, `chats`, unless that is one of its workspaces, as on an older host, which has none (nil).
    public var chatsSpaceID: String? {
        PlainChatsCapability.chatsSpace(capability: capabilities?.plainChats, isWorkspace: { id in projects.contains { $0.id == id } })
    }

    /// Whether `projectID` is the host's Chats space, whose chats are plain chats.
    public func isChatsSpace(_ projectID: String) -> Bool { projectID == chatsSpaceID }

    /// The IDs of the host's workspaces, which chat stores are told (`ChatSessionStore.Environment`).
    public var workspaceIDs: Set<String> { Set(projects.map(\.id)) }

    /// A chat of the Chats space. It stays in the tab list whatever workspace is open, and showing it never
    /// changes the workspace in use.
    public func isPlainChat(_ tab: WorkspaceTab) -> Bool {
        tab.kind == .chat && isChatsSpace(tab.projectID)
    }

    /// A new chat: Claude Code or Codex in the selected workspace's folder (`capabilities.workspaceChats`). It needs a
    /// selected workspace and replaces Home like any new surface; nothing is sent until the person sends a message, and
    /// it starts in the host's default mode (Ask). OpenCode, offered only under `--opencode-chat`, starts in the Chats
    /// space as before. A host without `workspaceChats` offers no Chat.
    public func newPlainChat(provider requested: AgentProvider? = nil) {
        guard let project = currentProject, capabilities?.workspaceChats != nil else { return }
        let provider = requested ?? newPlainChatProvider
        guard plainChatProviders.contains(where: { $0.id == provider.id }) else {
            creationIssue = "Choose an available Chat provider. \(provider.chatDisplayName) is unavailable on this Mac."
            return
        }
        setPlainChatDefaultProvider(provider)
        if chatsSpaceChatProviders.contains(where: { $0.id == provider.id }), let space = capabilities?.plainChats?.projectID {
            create(.chat, projectID: space, provider: provider)
        } else {
            create(.chat, projectID: project.id, provider: provider)
        }
    }
    /// True while `tabID` is open on `hostID`, as a tab or a standalone terminal's screen; asynchronous results check it
    /// before they apply.
    public func isCurrent(hostID: String?, tabID: UUID) -> Bool {
        self.hostID == hostID && (tabs.contains(where: { $0.id == tabID }) || standaloneTabs[tabID] != nil)
    }
    public func tab(_ id: UUID) -> WorkspaceTab? { tabs.first { $0.id == id } }

    // MARK: Workspaces

    public func selectProject(_ id: String) {
        guard projects.contains(where: { $0.id == id }) else { return }
        selectedProjectID = id
        rememberWorkspace()
    }

    /// Each workspace resumes its own live tab. Remote discovery never recreates closed tabs; a newly
    /// opened workspace begins in Files by default; the phone navigator uses Home when it is empty.
    public func openWorkspace(_ id: String, openFilesIfEmpty: Bool = true) {
        guard projects.contains(where: { $0.id == id }) else { return }
        selectedProjectID = id
        rememberWorkspace()
        if let remembered = workspaceSelections[id], tabs.contains(where: { $0.id == remembered && workspaceID(for: $0) == id && $0.kind != .home && supportsTab($0) }) {
            selectedTabID = remembered
        } else if let existing = tabs.last(where: { workspaceID(for: $0) == id && $0.kind != .home && supportsTab($0) }) {
            selectedTabID = existing.id
        } else if openFilesIfEmpty && !phoneNavigation.drawerHoldsBrowsers {
            // On iPhone an empty workspace shows Home; its Files is a page of the drawer.
            open(WorkspaceTab(kind: .files, projectID: id, title: "Files"))
        } else {
            selectedTabID = nil
        }
    }

    private func rememberWorkspace() {
        if let selectedProjectID, closedWorkspaceIDs.remove(selectedProjectID) != nil { saveClosedWorkspaces() }
        guard let identity else { return }
        if let selectedProjectID { defaults.set(selectedProjectID, forKey: keys.currentWorkspace + identity.storageKey) }
        else { defaults.removeObject(forKey: keys.currentWorkspace + identity.storageKey) }
    }

    private func saveClosedWorkspaces() {
        guard let identity else { return }
        defaults.set(closedWorkspaceIDs.sorted(), forKey: keys.currentWorkspace + "closedInMenu." + identity.storageKey)
    }

    /// Records that the workspaces `ids` were in use on this device until now.
    private func noteUse(_ ids: [String], at date: Date = Date()) {
        guard identity != nil, !ids.isEmpty else { return }
        for id in ids { lastUsed[id] = date }
        saveLastUsed()
    }

    private func saveLastUsed() {
        guard let identity else { return }
        if let data = try? JSONEncoder().encode(lastUsed) { defaults.set(data, forKey: keys.lastUsed + identity.storageKey) }
    }

    /// The open tabs of workspace `id` on this device.
    public func tabs(inWorkspace id: String) -> [WorkspaceTab] { tabs.filter { workspaceID(for: $0) == id } }

    /// Closes workspace `id` on this device: every one of its tabs closes and its session ends (the
    /// terminals' processes keep running; the caller ends the ones this device opened). When it was
    /// the workspace in use, none is afterwards: Home offers the list. Returns the closed tabs.
    @discardableResult
    public func closeWorkspace(_ id: String) -> [WorkspaceTab] {
        closedWorkspaceIDs.insert(id)
        saveClosedWorkspaces()
        // Hidden coding chats are kept, drafts and all: they are no product surface to close (owner, 2026-10-08).
        let closing = tabs(inWorkspace: id).filter(supportsTab)
        if pendingCloseTab?.projectID == id { pendingCloseTab = nil }
        let closingIDs = Set(closing.map(\.id))
        tabs.removeAll { closingIDs.contains($0.id) }
        for tab in closing { tabRefreshGeneration.removeValue(forKey: tab.id) }
        workspaceSelections.removeValue(forKey: id)
        if let selected = selectedTabID, closing.contains(where: { $0.id == selected }) { selectedTabID = nil }
        if selectedProjectID == id {
            selectedProjectID = nil
            rememberWorkspace()
        }
        saveTabs()
        // Last, as for one tab: ending a terminal hides its keyboard and SwiftUI lays out again at once.
        for tab in closing { sessions.end(tab.id) }
        return closing
    }

    /// Forgets what this device kept for a workspace the host no longer has: its tabs close as with
    /// `closeWorkspace` and its last use goes.
    public func forgetWorkspace(_ id: String) {
        closeWorkspace(id)
        projects.removeAll { $0.id == id }
        if lastUsed.removeValue(forKey: id) != nil { saveLastUsed() }
    }

    @ObservationIgnored private var workspacesModel: WorkspaceManager?
    /// The Workspaces screen's state and actions, one for as long as this workspace model (it follows
    /// the attached host itself).
    public var workspaces: WorkspaceManager {
        if let workspacesModel { return workspacesModel }
        let made = WorkspaceManager(workspace: self)
        workspacesModel = made
        return made
    }

    @ObservationIgnored private var agentsModel: AgentsModel?
    /// Settings → Agents: the host's agent catalog, one model for as long as this workspace model (it
    /// follows the attached host itself).
    public var agents: AgentsModel {
        if let agentsModel { return agentsModel }
        let made = AgentsModel(workspace: self)
        agentsModel = made
        return made
    }

    @ObservationIgnored private var aiProvidersModel: AIProvidersModel?
    /// Settings → AI Providers on iPhone and iPad: the host's model providers, read-only.
    public var aiProviders: AIProvidersModel {
        if let aiProvidersModel { return aiProvidersModel }
        let made = AIProvidersModel(workspace: self)
        aiProvidersModel = made
        return made
    }

    @ObservationIgnored private var vaultModel: VaultModel?
    /// Settings → Vault on the Mac: the Markdown copy of the archive, one model for as long as this workspace model
    /// (it follows the attached host itself).
    public var vault: VaultModel {
        if let vaultModel { return vaultModel }
        let made = VaultModel(workspace: self)
        vaultModel = made
        return made
    }

    // MARK: Tabs

    /// The selected Home tab, which the next opened surface replaces.
    public var launchingHomeTabID: UUID? { currentTab?.kind == .home ? selectedTabID : nil }

    /// Opens a surface. Launching from a Home tab turns that tab into the new surface in place; the
    /// permanent Home and other tabs are never replaced.
    public func open(_ tab: WorkspaceTab) { open(tab, replacingHome: launchingHomeTabID) }

    public func open(_ tab: WorkspaceTab, replacingHome homeID: UUID?) {
        // On iPhone Files and Git are pages of the drawer, never tasks: they show there and the task in front stays.
        if phoneNavigation.revealsInsteadOfOpening(tab) {
            phoneNavigation.reveal(tab.kind == .files ? .files : .git, projectID: tab.projectID, model: self)
            return
        }
        let launcher = tab.kind == .home ? nil : homeID.flatMap { id in tabs.firstIndex { $0.id == id && $0.kind == .home } }
        if tab.kind != .home,
           let existing = tabs.first(where: { $0.kind == tab.kind && $0.projectID == tab.projectID && $0.resourceID == tab.resourceID }) {
            // Already open elsewhere: show it, and the Home that asked for it is spent.
            if let launcher { discardTab(at: launcher) }
            selectedTabID = existing.id
            saveTabs()
            return
        }
        if let launcher {
            tabRefreshGeneration.removeValue(forKey: tabs[launcher].id)
            tabs[launcher] = tab
        } else {
            tabs.append(tab)
        }
        selectedTabID = tab.id
        saveTabs()
    }

    private func discardTab(at index: Int) {
        let id = tabs[index].id
        sessions.end(id)
        tabRefreshGeneration.removeValue(forKey: id)
        tabs.remove(at: index)
        for (project, remembered) in workspaceSelections where remembered == id { workspaceSelections.removeValue(forKey: project) }
    }

    public func openHomeTab() {
        guard let projectID = selectedProjectID, projects.contains(where: { $0.id == projectID }) else { return }
        let lastNumber = tabs.filter { $0.kind == .home && $0.projectID == projectID }
            .compactMap { Int($0.title.dropFirst("Home ".count)) }.max() ?? 1
        open(WorkspaceTab(kind: .home, projectID: projectID, title: "Home \(lastNumber + 1)"))
    }

    public func requestFind() { findRequest &+= 1 }
    public func requestRunAgain() { runAgainRequest &+= 1 }

    /// Records that the view `view` shows (or stopped showing) the surface of the tab `tabID`, and
    /// returns whether any view still shows it.
    @discardableResult
    func surfaceView(_ view: UUID, of tabID: UUID, shown: Bool) -> Bool {
        var views = surfaceViews[tabID] ?? []
        if shown { views.insert(view) } else { views.remove(view) }
        surfaceViews[tabID] = views.isEmpty ? nil : views
        return !views.isEmpty
    }

    public func reloadTab(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        tabRefreshGeneration[id] = UUID()
        if presentationTicket?.tabID == id { beginPresentation() }
    }

    /// Closes a tab and ends its session. A dirty editor waits for confirmation first, asked beside the task row
    /// when `fromRow`. Closing a terminal's tab leaves its process running on the host.
    public func close(_ id: UUID, fromRow: Bool = false) {
        close(id, source: fromRow ? .row : .menu)
    }

    public func close(_ id: UUID, source: WorkspaceTabCloseSource) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        if tab.kind == .editor && tab.editorDirty {
            pendingCloseSource = source
            pendingCloseTab = tab
            return
        }
        closeImmediately(id)
    }

    public func cancelClose() {
        pendingCloseTab = nil
    }

    public func discardAndClose() {
        guard let tab = pendingCloseTab, tabs.contains(where: { $0.id == tab.id }) else {
            pendingCloseTab = nil
            return
        }
        pendingCloseTab = nil
        closeImmediately(tab.id)
    }

    /// A terminal that ended by going on in another (`TerminalEnd.continuedIn`: the handoff skill started its next
    /// Claude Code session there, owner 2026-10-26: "open a new terminal kinda behavior and close the old one out after a
    /// moment") gives its tab to that terminal, in place: the same tab, its place in the switcher and its page kept. The
    /// tab's session ends and its view makes one for the new terminal (`WorkspaceSessions`). This device's own ended
    /// terminal is then closed on the host, so it stops counting toward the host's limit; a tab following another
    /// device's terminal leaves that to its device. Nothing happens once the tab closed or shows another terminal.
    func followContinuation(of tabID: UUID, from terminalID: String, to next: String) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }), tabs[index].kind == .terminal,
              tabs[index].resourceID == terminalID, next != terminalID else { return }
        let old = tabs[index]
        if old.sharedFrom == nil {
            // This device draws the new terminal from its start, so it answers the queries there, as for one it made.
            terminalOutputReadHere[next] = 0
        }
        tabs[index].resourceID = next
        saveTabs()
        guard old.sharedFrom == nil, let client else { return }
        Task { _ = await client.closeTerminal(projectID: old.projectID, terminalID: terminalID) }
    }

    /// A chat that went on in another while its tab showed it (`ChatInfo.continuedIn`: the handoff skill started its
    /// next Claude Code session there, owner 2026-10-26: "handoff needs to work in the chat screen to") gives its tab to
    /// that chat, in place, as a terminal's does (`followContinuation`): the same tab and page, with its model, mode,
    /// effort and confirmed mode, so the new chat never asks again (owner: "Keep it, no re-ask"). The old chat stays in
    /// the history. Nothing happens once the tab closed or shows another chat, or when another tab shows the new one.
    func followChatContinuation(of tabID: UUID, from chatID: String, to next: String) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }), tabs[index].kind == .chat,
              tabs[index].resourceID == chatID, next != chatID,
              !tabs.contains(where: { $0.kind == .chat && $0.resourceID == next }) else { return }
        tabs[index].resourceID = next
        saveTabs()
    }

    private func closeImmediately(_ id: UUID) {
        let closing = tabs.first(where: { $0.id == id })
        let projectID = closing.flatMap { workspaceID(for: $0) }
        tabRefreshGeneration.removeValue(forKey: id)
        tabs.removeAll { $0.id == id }
        if let projectID, workspaceSelections[projectID] == id { workspaceSelections.removeValue(forKey: projectID) }
        if selectedTabID == id {
            // A workspace's tab gives way to the last one of its workspace; a plain chat to the last tab listed.
            selectedTabID = closing.map(isPlainChat) == true ? workspaceTabs.last?.id : tabs.last(where: { $0.projectID == projectID })?.id
        }
        saveTabs()
        // Last: ending a terminal hides its keyboard, and SwiftUI lays out again at once. The tab is
        // already gone, so its view does not make a new session for it.
        sessions.end(id)
    }

    /// Moves open tabs of the tab list (the plain chats and the current workspace's tabs), as a list's `onMove`
    /// reports it: `source` and `destination` index `workspaceTabs`. Other workspaces' tabs keep their places.
    public func moveWorkspaceTabs(fromOffsets source: IndexSet, toOffset destination: Int) {
        var visible = workspaceTabs
        guard !source.isEmpty, source.allSatisfy({ visible.indices.contains($0) }) else { return }
        let moving = source.sorted().map { visible[$0] }
        let before = visible[..<min(destination, visible.count)].filter { tab in !moving.contains { $0.id == tab.id } }
        let after = visible[min(destination, visible.count)...].filter { tab in !moving.contains { $0.id == tab.id } }
        visible = Array(before) + moving + Array(after)
        guard visible.map(\.id) != workspaceTabs.map(\.id) else { return }
        // Put the reordered tabs back into the slots the listed tabs held.
        var remaining = visible.makeIterator()
        tabs = tabs.map { tab in listsTab(tab) ? (remaining.next() ?? tab) : tab }
        saveTabs()
    }

    /// Closes every other tab of the tab list (the plain chats and the current workspace's tabs). An editor
    /// with unsaved changes stays open: closing it needs its own confirmation. A closed selection moves to a
    /// tab that stays.
    public func closeOtherTabs(keeping id: UUID?) {
        let closing = workspaceTabs.filter { $0.id != id && !($0.kind == .editor && $0.editorDirty) }
        guard !closing.isEmpty else { return }
        for tab in closing { closeImmediately(tab.id) }
    }

    /// The tabs a person steps through: the permanent Home, then the tab list (the plain chats and the
    /// current workspace's tabs).
    public var tabOrder: [UUID?] { [nil] + workspaceTabs.map { Optional($0.id) } }

    /// ⌘1 is Home, ⌘2 … ⌘8 the workspace's tabs in order, ⌘9 the last one.
    public func selectTab(number: Int) {
        let order = tabOrder
        guard number >= 1 else { return }
        let index = number == 9 ? order.count - 1 : number - 1
        guard order.indices.contains(index) else { return }
        selectNavigationTab(order[index])
    }

    /// The next tab (or the previous one), wrapping around.
    public func selectAdjacentTab(forward: Bool = true) {
        let order = tabOrder
        guard order.count > 1 else { return }
        let current = order.firstIndex { $0 == selectedTabID } ?? 0
        selectNavigationTab(order[(current + (forward ? 1 : order.count - 1)) % order.count])
    }

    private func selectNavigationTab(_ id: UUID?) {
        if let id, let tab = tab(id), tab.kind == .chat || tab.kind == .terminal {
            requestResume(.tab(tab))
        } else {
            selectedTabID = id
        }
    }

    /// Shows the current workspace's Files tab, opening one when it has none (in place of a Home tab
    /// that asked for it, like any surface).
    public func showFiles() {
        guard let project = currentProject else { return }
        open(WorkspaceTab(kind: .files, projectID: project.id, title: "Files"))
    }

    /// Shows the current workspace's Git tab (its repositories, staging and commits), opening one when
    /// it has none.
    public func showGit() {
        guard let project = currentProject else { return }
        open(WorkspaceTab(kind: .git, projectID: project.id, title: "Git"))
    }

    /// Opens a project file in its editor tab (a new one, or the one that shows it already). With `line`
    /// the editor shows that line and puts the caret at its start.
    public func openFile(projectID: String, path: String, line: Int? = nil) {
        // A file opened from the iPhone drawer's Files page shows in front: the drawer goes.
        phoneNavigation.dismissPopovers()
        let name = path.split(separator: "/").last.map(String.init) ?? path
        open(WorkspaceTab(kind: .editor, projectID: projectID, resourceID: path, title: name))
        guard let line, let tab = tabs.first(where: { $0.kind == .editor && $0.projectID == projectID && $0.resourceID == path }) else { return }
        editorSession(for: tab).reveal(line: line)
    }

    /// Editor tabs follow a file or folder the person renamed or moved: their path and title change, and
    /// each keeps its draft with the revision it was based on (a rename leaves the content, and so the
    /// revision, as it was).
    public func retargetEditorTabs(projectID: String, from old: String, to new: String) {
        guard old != new else { return }
        var changed = false
        for index in tabs.indices where tabs[index].kind == .editor && tabs[index].projectID == projectID {
            let resource = tabs[index].resourceID
            let moved: String
            if resource == old {
                moved = new
            } else if resource.hasPrefix(old + "/") {
                moved = new + resource.dropFirst(old.count)
            } else {
                continue
            }
            tabs[index].resourceID = moved
            tabs[index].title = moved.split(separator: "/").last.map(String.init) ?? moved
            changed = true
        }
        if changed { saveTabs() }
    }

    /// Opens a chat the host has, in a new tab or the one that shows it already: a workspace chat in its workspace.
    public func openChat(_ session: Session) {
        guard isChatShown(session.id, projectID: session.projectID, provider: session.provider) else { return }
        requestResume(.tab(WorkspaceTab(kind: .chat, projectID: session.projectID, resourceID: session.id, title: session.title)),
                      replacingHome: launchingHomeTabID)
    }

    /// The open tab of a chat, if it has one.
    public func chatTab(sessionID: String) -> WorkspaceTab? {
        tabs.first { $0.kind == .chat && $0.resourceID == sessionID }
    }

    /// Closes a chat's tab after its chat was deleted: its draft goes with the chat.
    public func closeChat(sessionID: String) {
        for tab in tabs where tab.kind == .chat && tab.resourceID == sessionID { closeImmediately(tab.id) }
    }

    public func updateChatOptions(_ id: UUID, modelID: String?, agent: String?, effort: String? = nil) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        guard tabs[index].chatModelID != modelID || tabs[index].chatAgent != agent || tabs[index].chatEffort != effort else { return }
        tabs[index].chatModelID = modelID
        tabs[index].chatAgent = agent
        tabs[index].chatEffort = effort
        saveTabs()
    }

    /// The person confirmed a mode that runs without asking in this chat (`ChatSessionStore.Callbacks.modeConfirmed`):
    /// it is kept with the tab, so the chat never asks again.
    public func noteChatModeConfirmed(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }), tabs[index].chatModeConfirmed != true else { return }
        tabs[index].chatModeConfirmed = true
        saveTabs()
    }

    public func updateDraft(_ id: UUID, _ draft: String) {
        guard let index = tabs.firstIndex(where: { $0.id == id }), tabs[index].draft != draft else { return }
        tabs[index].draft = draft
        saveTabs()
    }

    public func updateEditorDraft(_ id: UUID, _ draft: String, dirty: Bool, baseRevision: String) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].draft = draft
        tabs[index].editorDirty = dirty
        tabs[index].editorBaseRevision = dirty ? baseRevision : nil
        saveTabs()
    }

    /// Records editor changes synchronously for close confirmation. Disk writes remain debounced by
    /// the editor and are flushed on lifecycle boundaries.
    public func noteEditorEdit(_ id: UUID, _ draft: String, dirty: Bool, baseRevision: String) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].draft = draft
        tabs[index].editorDirty = dirty
        tabs[index].editorBaseRevision = dirty ? baseRevision : nil
        if pendingCloseTab?.id == id { pendingCloseTab = tabs[index] }
    }

    public func rename(_ id: UUID, _ title: String) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].title = title
        saveTabs()
    }

    func saveTabs() {
        guard let identity else { return }
        persistence.save(tabs, selectedTabID: selectedTabID, for: identity)
        if let data = try? JSONEncoder().encode(workspaceSelections) {
            defaults.set(data, forKey: keys.tabSelections + identity.storageKey)
        }
    }

    // MARK: Opening readiness

    public var presentationPending: Bool { presentationTicket != nil }

    /// Home needs only the host's metadata; any other tab needs its surface's own report too. A host
    /// that answers on no address resolves the opening by itself (`resolvePresentationOffline`).
    public var presentationReady: Bool {
        guard let ticket = presentationTicket else { return false }
        if presentationResolvedOffline { return true }
        let homeReady = ticket.tabID == nil || (currentTab?.id == ticket.tabID && currentTab?.kind == .home)
        return metadataResolved && (homeReady || presentationSurfaceReady)
    }

    /// No address of the host answered (the route race's probes or the pulse gave up): the opening is
    /// resolved with the workspace's offline state — the banner, and each surface's own offline notice —
    /// instead of waiting out the surfaces' request timeouts (B-14). An actionable error is a resolved
    /// state; the connection keeps retrying, and recovery follows the connection epoch as usual.
    public func resolvePresentationOffline() {
        sessionPresentationTicket = nil
        guard presentationTicket != nil else { return }
        presentationResolvedOffline = true
    }

    /// Starts a new opening for the attached host and the selected tab. Earlier tickets are void.
    public func beginPresentation() {
        // What shows once the cover lifts is revealed afresh.
        circusRevealedAt = nil
        presentationResolvedOffline = false
        guard let hostID else {
            presentationTicket = nil
            presentationSurfaceReady = false
            return
        }
        presentationSurfaceReady = false
        presentationTicket = WorkspacePresentationTicket(hostID: hostID, tabID: selectedTabID)
        // Already answering on no address: this opening, too, resolves with the offline state (B-14).
        presentationResolvedOffline = !reachable
    }

    /// The current ticket, if `tabID` is the tab it waits for.
    public func presentationRequest(for tabID: UUID) -> WorkspacePresentationTicket? {
        guard let ticket = presentationTicket ?? sessionPresentationTicket,
              ticket.hostID == hostID,
              ticket.tabID == tabID, selectedTabID == tabID else { return nil }
        return ticket
    }

    /// The selected surface resolved its content, empty state or actionable error.
    public func reportPresentationReady(_ ticket: WorkspacePresentationTicket) {
        guard ticket.hostID == hostID,
              ticket.tabID == selectedTabID else { return }
        if ticket == sessionPresentationTicket { sessionPresentationTicket = nil }
        if ticket == presentationTicket { presentationSurfaceReady = true }
    }

    /// Ends the opening once the prepared workspace passed through a display frame. The owning app
    /// calls it only when nothing else (a lock, pairing, a background scene) still covers it.
    @discardableResult
    public func completePresentation(_ ticket: WorkspacePresentationTicket) -> Bool {
        guard ticket == presentationTicket, presentationReady,
              ticket.hostID == hostID, ticket.tabID == selectedTabID else { return false }
        if sessionPresentationTicket?.tabID == ticket.tabID { sessionPresentationTicket = nil }
        presentationTicket = nil
        presentationSurfaceReady = false
        presentationResolvedOffline = false
        return true
    }

    // MARK: Sessions

    private func sessionKey(_ tab: WorkspaceTab) -> WorkspaceSessionKey {
        WorkspaceSessionKey(tabID: tab.id, kind: tab.kind, hostID: hostID ?? "", projectID: tab.projectID, resourceID: tab.resourceID)
    }

    /// The chat store of a chat tab. It keeps its transcript, draft and stream position across tab
    /// switches and view rebuilds; closing the tab or changing host ends it. Its agent is the one the chat's
    /// ID names, with the host's name for it, until the chat's snapshot says.
    public func chatStore(for tab: WorkspaceTab) -> ChatSessionStore {
        sessions.session(for: sessionKey(tab)) {
            let store = ChatSessionStore(identity: .init(hostID: hostID ?? "", projectID: tab.projectID, sessionID: tab.resourceID, tabID: tab.id),
                                         provider: AgentProvider.named(ChatSessionStore.provider(forSession: tab.resourceID).id, by: capabilities),
                                         draft: tab.draft, model: tab.chatModelID, mode: tab.chatAgent, effort: tab.chatEffort,
                                         unattendedModeConfirmed: tab.chatModeConfirmed == true,
                                         transcriptCache: archive?.transcriptCache ?? archiveOpening.map(OpeningArchiveTranscriptCache.init))
            let id = tab.id
            store.callbacks.persistDraft = { [weak self] draft in self?.updateDraft(id, draft) }
            store.callbacks.persistOptions = { [weak self] model, mode, effort in
                self?.updateChatOptions(id, modelID: model, agent: mode, effort: effort)
            }
            store.callbacks.modeConfirmed = { [weak self] in self?.noteChatModeConfirmed(id) }
            store.callbacks.connectionFailed = { [weak self] in self?.noteConnectionFailure() }
            // The host's `chat` agent went (503 `agent_unavailable`): what it offers is read again.
            store.callbacks.capabilitiesStale = { [weak self] in Task { await self?.refreshCapabilities() } }
            store.callbacks.openChat = { [weak self] session in
                guard let self else { return }
                // A plain continuation inherits its source's ownership, even if another workspace is now selected. A chat
                // continued into a workspace (a read-only Chats-space chat's Continue in <workspace>) is that workspace's.
                if self.isPlainChat(tab), self.isChatsSpace(session.projectID), let owner = self.workspaceID(for: tab) {
                    self.rememberChatWorkspace(session.id, workspaceID: owner)
                }
                self.openChat(session)
            }
            // The sign-in notice's Open in Terminal: the agent's terminal program, in the chat's workspace. A plain
            // chat has none: the Chats space has no terminals.
            let projectID = tab.projectID
            if !isPlainChat(tab) {
                store.callbacks.openTerminal = { [weak self] program in
                    self?.create(.terminal, program: program, projectID: projectID)
                }
            }
            // The tab follows the chat's title as its stream brings it, whether or not a view shows it.
            store.callbacks.nameChanged = { [weak self] name in self?.chatNamed(tabID: id, name) }
            // The chat went on in another (the handoff skill): the tab follows it, once the store has published.
            let chatID = tab.resourceID
            store.callbacks.continued = { [weak self] next in
                Task { @MainActor in self?.followChatContinuation(of: id, from: chatID, to: next) }
            }
            // A finished turn names the chat for what it worked on, where the host takes names.
            store.callbacks.turnFinished = { [weak self, weak store] _ in
                guard let self, let store else { return }
                self.naming.turnFinished(in: store)
            }
            return store
        }
    }

    /// The store of an open chat tab, if its view made one.
    public func existingChatStore(_ id: UUID) -> ChatSessionStore? { sessions.existing(id) as? ChatSessionStore }

    public func terminalSession(for tab: WorkspaceTab) -> TerminalSession {
        sessions.session(for: sessionKey(tab)) { TerminalSession(tab: tab, workspace: self, standalone: standaloneTabs[tab.id] != nil) }
    }

    public func editorSession(for tab: WorkspaceTab) -> EditorSession {
        sessions.session(for: sessionKey(tab)) { EditorSession(tab: tab, workspace: self) }
    }

    public func filesSession(for tab: WorkspaceTab) -> FilesSession {
        sessions.session(for: sessionKey(tab)) { FilesSession(tab: tab, workspace: self) }
    }

    public func gitSession(for tab: WorkspaceTab) -> GitSession {
        sessions.session(for: sessionKey(tab)) { GitSession(tab: tab, workspace: self) }
    }

    /// Sends a menu action to an open terminal. Its session checks that the terminal takes input now.
    public func perform(_ action: TerminalAction, onTerminal tabID: UUID) {
        (sessions.existing(tabID) as? TerminalSession)?.perform(action)
    }

    // MARK: Creating chats and terminals

    /// A new chat of the draft's agent (Continue with… on a host that cannot continue chats itself), with
    /// the draft in its composer and its file attached. Nothing is sent until the person sends it. A plain
    /// chat's draft opens in a new plain chat.
    public func openDraft(_ draft: ContinueDraft) {
        guard !sessionOpening, let client, accepts(.chat, projectID: draft.projectID, provider: AgentProvider(id: draft.provider)) else { return }
        guard reachable else {
            creationIssue = Self.offlineIssue(.chat)
            return
        }
        let hostID = self.hostID
        let creation = UUID()
        creationID = creation
        creating = true
        creationIssue = nil
        let provider = AgentProvider(id: draft.provider)
        let owner = chatWorkspaceIDs[draft.sourceChatID] ?? selectedProjectID
        creationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.creationID == creation { self.creating = false } }
            do {
                let session = try await client.createSession(projectID: draft.projectID, title: draft.title, provider: provider.requestValue)
                guard !Task.isCancelled, self.client === client, self.hostID == hostID else { return }
                var tab = WorkspaceTab(kind: .chat, projectID: session.projectID, resourceID: session.id, title: session.title)
                tab.chatModelID = draft.model
                tab.chatAgent = draft.mode
                tab.chatEffort = draft.effort
                if let owner, self.isChatsSpace(session.projectID) { self.rememberChatWorkspace(tab.resourceID, workspaceID: owner) }
                self.prepareSessionPresentation(for: tab)
                self.open(tab)
                let store = self.chatStore(for: tab)
                // The upload needs the host now; the tab's view takes over the environment when it shows.
                store.update(ChatSessionStore.Environment(client: client, capabilities: self.capabilities, reachable: self.reachable,
                                                          connectionEpoch: self.connectionEpoch, active: false,
                                                          refreshGeneration: self.tabRefreshGeneration[tab.id],
                                                          workspaceIDs: self.workspaceIDs,
                                                          continueWorkspace: self.currentProject.map { ChatWorkspace(id: $0.id, name: $0.name) }))
                store.useInComposer(draft.text)
                if let attachment = draft.attachment { store.attach(attachment) }
            } catch {
                guard self.client === client, self.hostID == hostID else { return }
                self.creationIssue = self.chatRefusal(error)
                    ?? "Could not confirm the new chat: \(error.localizedDescription) Check your chats before trying again."
            }
        }
    }

    /// What a new chat the host refused says (nothing was made): the agent's sign-in in the host's words (400
    /// `agent_auth_required`, "Subscriptions only"); while the agent cannot run Chat (503 `agent_unavailable`), that
    /// chats are not ready, and the host's capabilities are read again. Nil for other failures.
    private func chatRefusal(_ error: Error) -> String? {
        guard case let .server(code, message)? = error as? ClientError else { return nil }
        switch code {
        case "agent_auth_required":
            Task { await refreshCapabilities() }
            return message.isEmpty ? "Sign in on \(hostName) first. Nothing was started." : "\(message) Nothing was started."
        case "agent_unavailable":
            Task { await refreshCapabilities() }
            return "Chats aren’t ready on \(hostName) yet. Nothing was started; try again in a moment."
        default:
            return nil
        }
    }

    /// What a new chat or terminal asked for while the host does not answer says: nothing was sent.
    static func offlineIssue(_ kind: WorkspaceTabKind) -> String {
        kind == .terminal ? "Offline · no terminal was started" : "Offline · no chat was started"
    }

    /// Whether a new `kind` of `provider` can be made in `projectID`: a workspace of the host's, a chat only of an
    /// agent Chat offers (`workspaceChats`); or, for a draft continued on a host without Continue, the Chats space while
    /// it takes that provider (OpenCode under `--opencode-chat`).
    private func accepts(_ kind: WorkspaceTabKind, projectID: String, provider: AgentProvider) -> Bool {
        if kind == .chat, isChatsSpace(projectID) {
            return capabilities?.plainChats?.availableProviders.contains { $0.id == provider.id } == true
        }
        guard !isChatsSpace(projectID), projects.contains(where: { $0.id == projectID }) else { return false }
        return kind != .chat || capabilities?.workspaceChats?.offers(provider) == true
    }

    /// Starts a chat or terminal on the host and opens it, in place of the Home tab that asked for it.
    /// A terminal whose creation could not be confirmed is not retried; the person checks first. A chat in
    /// the Chats space needs no workspace, and choosing another workspace meanwhile does not drop it; a workspace
    /// chat (`newPlainChat`) is dropped like a terminal. While the host does not answer nothing is sent, and `creationIssue` says so at once.
    /// `resume` continues a Claude Code conversation in the new terminal; `replacing` is the ended terminal's tab the
    /// new one takes the place of once it opens (Resume).
    public func create(_ kind: WorkspaceTabKind, program: TerminalProgram = .shell, projectID requested: String? = nil,
                       provider: AgentProvider = .opencode, resume: TerminalResume? = nil, replacing: UUID? = nil) {
        guard !sessionOpening, let client, let projectID = requested ?? selectedProjectID,
              accepts(kind, projectID: projectID, provider: provider) else { return }
        // Offline nothing is sent, and the notice says so at once, as the composer does for a message.
        guard reachable else {
            creationIssue = Self.offlineIssue(kind)
            return
        }
        let plain = isChatsSpace(projectID)
        let hostID = self.hostID
        let selectionAtStart = selectedProjectID
        // The Home tab that launched this becomes the new surface when it opens.
        let launcher = launchingHomeTabID
        let creation = UUID()
        creationID = creation
        creating = true
        creationIssue = nil
        creationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // A creation the host change cancelled must not end a newer one.
            defer { if self.creationID == creation { self.creating = false } }
            @MainActor func stillCurrent() -> Bool {
                guard !Task.isCancelled, self.client === client else { return false }
                return self.hostID == hostID && (plain || self.selectedProjectID == selectionAtStart)
            }
            do {
                let tab: WorkspaceTab
                var terminalUpdateNotice: String?
                if kind == .chat {
                    let session = try await client.createSession(projectID: projectID, title: provider.newChatTitle, provider: provider.requestValue)
                    var made = WorkspaceTab(kind: .chat, projectID: projectID, resourceID: session.id, title: session.title)
                    // A new chat starts with the model Settings → Chat chose for this host and agent; the chat falls back
                    // to the host's default when its list no longer has it. No mode: the host starts it in Ask.
                    made.chatModelID = self.plainChatDefaultModel(for: provider)
                    tab = made
                } else {
                    switch await client.createTerminal(projectID: projectID, title: program.terminalTitle, rows: 24, cols: 80,
                                                       program: program.requestValue, resume: resume) {
                    case .created(let terminal):
                        terminalOutputReadHere[terminal.id] = 0
                        tab = .terminal(terminal, projectID: projectID)
                        terminalUpdateNotice = terminal.updateNotice
                    case .uncertain:
                        if stillCurrent() { self.creationIssue = "The terminal may have opened. Check Terminal history in Search before trying again." }
                        return
                    case .failed(let error): throw error
                    }
                }
                guard stillCurrent() else { return }
                if plain, let owner = selectionAtStart { self.rememberChatWorkspace(tab.resourceID, workspaceID: owner) }
                // A plain chat made while another workspace was chosen leaves that workspace's Home tab alone.
                self.prepareSessionPresentation(for: tab)
                self.open(tab, replacingHome: self.selectedProjectID == selectionAtStart ? launcher : nil)
                // Resume: the ended terminal's tab gives way to the new one, in its place.
                if let replacing, replacing != tab.id, let index = self.tabs.firstIndex(where: { $0.id == replacing }),
                   let opened = self.tabs.firstIndex(where: { $0.id == tab.id }) {
                    let moved = self.tabs.remove(at: opened)
                    self.tabs.insert(moved, at: opened < index ? index - 1 : index)
                    self.closeImmediately(replacing)
                }
                if let terminalUpdateNotice { self.terminalSession(for: tab).issue = terminalUpdateNotice }
            } catch {
                guard stillCurrent() else { return }
                // Hosts before 2026-10-17 refused a launch whose update failed; newer ones start the installed version
                // and say so in `updateNotice`.
                if case let ClientError.server(code, _) = error, ["agent_update_failed", "agent_update_timeout"].contains(code) {
                    self.creationIssue = "No terminal was created. The agent couldn’t be updated. Retry or switch off automatic updates in Settings → Agents."
                    return
                }
                // The host's definite refusals: nothing was created, and its message says why (`agent_busy`: the agent
                // is being installed, removed or restored).
                if case let ClientError.server(code, message) = error,
                   ["terminal_limit", "terminal_path_too_long", "terminals_unavailable", "agent_busy"].contains(code) {
                    self.creationIssue = "No terminal was created. " + message
                    return
                }
                self.creationIssue = self.chatRefusal(error)
                    ?? "Could not confirm creation: \(error.localizedDescription). Check Search before trying again."
            }
        }
    }

    private func prepareSessionPresentation(for tab: WorkspaceTab) {
        guard let hostID, reachable else { return }
        sessionPresentationTicket = WorkspacePresentationTicket(hostID: hostID, tabID: tab.id)
    }
}
