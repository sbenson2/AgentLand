import AppKit
import Combine
import Foundation
import Observation
import AgentLandChat
import AgentLandCore
import AgentLandDesign
import AgentLandDesktopCore
import AgentLandWorkspace

extension WorkspaceStorageKeys {
    /// The Mac's keys. The workspace it opened keeps the key the Mac has always used.
    static let desktop = WorkspaceStorageKeys(currentWorkspace: "agentland.desktop.workspace.current.",
                                              tabSelections: "agentland.desktop.workspace.selection.",
                                              lastUsed: "agentland.desktop.workspace.lastUsed.")
}

/// The Mac's workspace: the shared `WorkspaceModel`, attached to this Mac's own host through the local
/// session `HostController` publishes. It lives as long as the app, never as long as a window: the
/// host's lifecycle and the desired connection stay in `HostController`, and this only follows the
/// session the host publishes while it runs.
///
/// - A new session (the host started) attaches the workspace to it: the saved tabs come back and each
///   tab's session starts afresh, as on a host change. A restarted host has none of the old terminals.
/// - No session (the host stopped) pauses the workspace: the tabs keep what they show, input is
///   refused, and the banner says the host is stopped.
/// - A read that failed while the host runs starts a short health check; the workspace resumes (a new
///   connection epoch) once the host answers.
/// - The Mac has no opening cover: once the host's workspaces are known, the opening completes.
/// - Workspaces renamed or removed on the host, from this Mac or a paired device, reach the saved
///   default workspace (`followProjects`), so a start never adds a removed one back or undoes a rename.
/// - Chat naming (`ChatNaming`) runs while the app is active: its foreground period begins when the app
///   becomes active and ends when it resigns. Without Apple Intelligence on this Mac it does nothing.
/// - While the session runs it follows the host's pulse for what it names of the capabilities: another plain
///   chats revision reads them again (the host lists plain chats once OpenCode's `chat` agent answers).
@MainActor final class DesktopWorkspace {
    static let shared = DesktopWorkspace(host: .shared)

    let model: WorkspaceModel
    /// The host's current session; nil while it is stopped.
    private(set) var client: APIClient?
    private let hostName: () -> String
    private let archiveOpener: @MainActor (ConnectionIdentity, APIClient?) async -> WorkspaceArchive?
    /// Hands each list the host answered (with the workspace open here) to the saved default workspace.
    private let followProjects: @MainActor ([Project], String?) -> Void
    private var subscription: AnyCancellable?
    private var reachabilityTask: Task<Void, Never>?
    private var pulseTask: Task<Void, Never>?
    /// How long a pulse that ended or failed waits before it opens again; tests shorten it.
    var pulseRetryDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(5), .seconds(15)]
    private var activation: [NSObjectProtocol] = []

    convenience init(host: HostController) {
        self.init(clients: host.$sessionClient.eraseToAnyPublisher(), hostName: { [unowned host] in host.advertisedHost },
                  followProjects: { [unowned host] projects, open in host.followWorkspaces(projects, preferred: open) })
    }

    init(model: WorkspaceModel = WorkspaceModel(keys: .desktop), clients: AnyPublisher<APIClient?, Never>,
         hostName: @escaping () -> String,
         archiveOpener: @escaping @MainActor (ConnectionIdentity, APIClient?) async -> WorkspaceArchive? = {
             await WorkspaceArchive.open(for: $0, client: $1)
         },
         followProjects: @escaping @MainActor ([Project], String?) -> Void = { _, _ in }) {
        self.model = model
        self.hostName = hostName
        self.archiveOpener = archiveOpener
        self.followProjects = followProjects
        model.hostName = "this Mac"
        model.onConnectionFailure = { [weak self] in self?.checkReachability() }
        subscription = clients
            .removeDuplicates { $0 === $1 }
            .sink { [weak self] client in MainActor.assumeIsolated { self?.connect(client) } }
        observeOpening()
        observeProjects()
        observeActivation()
    }

    /// The app's activation is chat naming's foreground: it names only while the app is active.
    private func observeActivation() {
        let center = NotificationCenter.default
        activation = [
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.model.naming.foregroundBegan() }
            },
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.model.naming.backgroundBegan() }
            },
        ]
    }

    /// Follows the host's list while its session runs: an empty list (none read yet, or a host that
    /// stopped) changes nothing.
    private func observeProjects() {
        withObservationTracking {
            _ = model.projects
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.model.client != nil, !self.model.projects.isEmpty {
                    self.followProjects(self.model.projects, self.model.selectedProjectID)
                }
                self.observeProjects()
            }
        }
    }

    /// The identity the Mac's tabs are saved under: its advertised name and the local device.
    var identity: ConnectionIdentity { ConnectionIdentity(host: hostName(), deviceID: "local-mac") }

    // MARK: The host's session

    func connect(_ client: APIClient?) {
        reachabilityTask?.cancel()
        reachabilityTask = nil
        pulseTask?.cancel()
        pulseTask = nil
        self.client = client
        guard let client else {
            if model.hostID == nil {
                // At launch, before the host runs: the saved tabs show, paused.
                attach(client: nil)
            } else {
                // The host stopped: every surface keeps what it shows and refuses input.
                keepDrafts()
                model.client = nil
                model.reachable = false
            }
            updateArchiveSync()
            return
        }
        attach(client: client)
    }

    private func attach(client: APIClient?) {
        let identity = self.identity
        keepDrafts()
        model.attach(hostID: identity.storageKey, identity: identity, client: client)
        model.reachable = client != nil
        guard let client else { return }
        let opener = archiveOpener
        model.openArchive({ await opener(identity, client) }, opened: { [weak self] archive in
            guard let self else { return }
            archive.update(client: self.model.client, capabilities: self.model.capabilities)
            self.updateArchiveSync()
        })
        Task { [weak self] in
            await self?.model.refreshProjects()
            guard let self else { return }
            // The copy follows the host's changes only when its capabilities list archive sync.
            self.model.archive?.update(client: self.model.client, capabilities: self.model.capabilities)
            self.updateArchiveSync()
        }
        followPulse(client)
    }

    /// Follows the host's pulse while this session runs, for the plain chats revision it names (after `ready`
    /// and on every change): another one reads the capabilities again (`notePlainChatsRevision`). A pulse the
    /// host ended, or one that failed, opens again after a growing pause; the health check, not the pulse,
    /// says whether the local host answers.
    private func followPulse(_ client: APIClient) {
        pulseTask?.cancel()
        let delays = pulseRetryDelays
        pulseTask = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                do {
                    for try await event in try await client.pulse() {
                        guard let self, !Task.isCancelled, self.model.client === client else { return }
                        failures = 0
                        if case let .plainChats(revision) = event { self.model.notePlainChatsRevision(revision) }
                    }
                } catch is CancellationError {
                    return
                } catch {
                    failures += 1
                }
                guard !Task.isCancelled, let self, self.model.client === client else { return }
                let delay = failures == 0 ? delays[0] : delays[min(failures, delays.count) - 1]
                do { try await Task.sleep(for: delay) } catch { return }
            }
        }
    }

    /// Saves the open editors' and chats' drafts before their sessions end.
    private func keepDrafts() {
        for id in model.sessions.tabIDs {
            switch model.sessions.existing(id) {
            case let editor as EditorSession: editor.flushDraft()
            case let chat as ChatSessionStore: chat.flushDraft()
            default: break
            }
        }
    }

    // MARK: Reachability

    /// A surface's read failed. The host is local, so a health check says whether it still answers:
    /// until it does the workspace is offline; once it does, surfaces resume from their cursors.
    private func checkReachability() {
        guard reachabilityTask == nil, let client, model.client === client else { return }
        reachabilityTask = Task { [weak self] in
            var delay = 1.0
            while !Task.isCancelled {
                let answered = (try? await client.health(timeout: 4)) != nil
                guard let self, self.model.client === client, !Task.isCancelled else { return }
                if answered {
                    if !self.model.reachable {
                        self.model.reachable = true
                        self.model.connectionEpoch &+= 1
                        self.model.archive?.resume(connectionEpoch: self.model.connectionEpoch)
                        self.updateArchiveSync()
                    }
                    self.reachabilityTask = nil
                    return
                }
                if self.model.reachable {
                    self.model.reachable = false
                    self.updateArchiveSync()
                }
                try? await Task.sleep(for: .seconds(delay))
                delay = min(delay * 2, 8)
            }
        }
    }

    // MARK: Opening and the archive's sync

    /// The iPhone and iPad hide the workspace behind the opening cover until the selected surface is
    /// ready. The Mac shows its window as it is, so once the host's workspaces are known the opening
    /// completes: surfaces take input and Resume Work's lists load.
    private func observeOpening() {
        withObservationTracking {
            _ = model.presentationTicket
            _ = model.metadataResolved
            _ = model.selectedTabID
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.completeOpening()
                self?.observeOpening()
            }
        }
        completeOpening()
    }

    private func completeOpening() {
        guard let ticket = model.presentationTicket, model.metadataResolved else { return }
        model.reportPresentationReady(ticket)
        if model.completePresentation(ticket) { updateArchiveSync() }
    }

    /// The device's copy follows the host while it runs and answers, once the opening completed.
    private func updateArchiveSync() {
        model.archive?.setRunning(client != nil && model.client === client && model.reachable && !model.presentationPending)
    }
}

extension DesktopWorkspace {
    /// What the workspace's connection banner says about this Mac's host: nothing while it runs and
    /// answers; connecting; stopped (Connect starts it); or not answering (checked again by itself).
    static func connectionStatus(host: HostStatus, reachable: Bool) -> ConnectionStatus {
        switch host {
        case .running where reachable:
            .online
        case .running:
            .offline(title: "Not responding", detail: "AgentLand’s host on this Mac isn’t answering. It’s checked again automatically.",
                     systemImage: "exclamationmark.triangle")
        case .starting:
            .offline(title: "Connecting…", detail: "AgentLand is starting its host on this Mac.", systemImage: "bolt.horizontal.circle")
        case .stopped:
            .offline(title: "Disconnected", detail: "AgentLand’s host on this Mac is stopped.", systemImage: "bolt.horizontal.circle")
        }
    }
}
