import Foundation
import Observation
import AgentLandCore

/// Settings → Agents on iPhone, iPad and the Mac (docs/AGENT-CATALOG-PLAN.md, "The apps"): the host's agents
/// from `GET /v1/agents`, split into installed and available, with Install, Update Now and Uninstall through
/// the routes the host lists in `capabilities.agents`.
///
/// Every request captures the host and client it was made for, and an answer for another is dropped; a
/// newer read replaces an older one. Changes need the host now and are never sent again by themselves: an
/// outcome the host did not confirm is reported and the list is read again. The host does the work in the
/// background, so while an install, update or uninstall runs the list is read every `pollInterval` for as
/// long as the pane follows it, and the pane says how the work ended.
@MainActor @Observable public final class AgentsModel {
    /// The host's catalog as last read; nil before the first answer.
    public private(set) var savingAutomaticUpdates = false
    @ObservationIgnored private var settingsToken: UUID?
    public private(set) var catalog: AgentCatalog?
    /// Why the last read failed; what was read before stays shown.
    public private(set) var loadIssue: String?
    public var notice: WorkspaceNotice?
    /// The search field's text: it filters both lists by name, id and description.
    public var search = ""
    /// The question for a download the host cannot check, naming the website it comes from: Install's, or
    /// Update Now's when the registry moved an installed agent to such a download.
    public var pendingUnverified: UnverifiedDownload?
    /// Uninstall's question.
    public var pendingUninstall: AgentInfo?
    /// Agents with a change on its way to the host.
    public private(set) var changing: Set<String> = []
    /// Agents whose uninstall this device sent and the host took, until the list shows how it ended, with
    /// when to stop waiting and the error they had before. While the host reports `uninstalling` it is
    /// followed for as long as it does; hosts before that state show an uninstall only by the agent going.
    public private(set) var uninstalling: [String: PendingUninstall] = [:]
    /// Registry icons through the host, kept for as long as the host is attached.
    public let icons = AgentIconStore()
    /// How often the list is read while work runs; tests shorten it.
    @ObservationIgnored public var pollInterval: Duration = .seconds(2)
    /// How long an uninstall the host took is waited for, while the host does not report `uninstalling`,
    /// before the pane says it may still be running.
    @ObservationIgnored public var uninstallWait: TimeInterval = 120

    public struct PendingUninstall: Hashable, Sendable {
        public let deadline: Date
        /// The agent's `lastError` when the uninstall was sent: only a newer one is this uninstall's.
        public let earlierError: String?
    }

    /// A download the host cannot check (`unverified_download`), waiting for the person's word before the
    /// change is sent again with `allowUnverified`.
    public struct UnverifiedDownload: Hashable, Identifiable, Sendable {
        public let agent: AgentInfo
        /// Update Now asked, rather than Install.
        public let isUpdate: Bool
        public var id: String { agent.id }
    }

    @ObservationIgnored public private(set) weak var workspace: WorkspaceModel?
    /// Changes with each read and each accepted change; an answer to an older read is dropped.
    @ObservationIgnored private var readToken = UUID()
    /// Each change on its way, so only its own answer clears its agent from `changing`.
    @ObservationIgnored private var changeTokens: [String: UUID] = [:]
    /// The agents that could be used at the last read, to tell when New Terminal change.
    @ObservationIgnored private var lastUsable: Set<String>?

    public init(workspace: WorkspaceModel) {
        self.workspace = workspace
        icons.model = self
    }

    // MARK: What the host offers

    /// The pane shows only for hosts that list their agents (`agents` with `catalog`).
    public var isAvailable: Bool { workspace?.capabilities?.supportsAgents(.catalog) == true }
    /// Install, Update Now and Uninstall, for hosts that take them.
    public var canInstall: Bool { workspace?.capabilities?.supportsAgents(.install) == true }
    /// The host answers now; changes are refused otherwise.
    public var canChange: Bool { workspace?.client != nil && workspace?.reachable == true }

    public var automaticUpdates: Bool? { catalog?.automaticUpdates }
    public var canConfigureAutomaticUpdates: Bool {
        workspace?.capabilities?.supportsAgents(.updateSettings) == true && automaticUpdates != nil
    }

    public func setAutomaticUpdates(_ enabled: Bool) async {
        guard canConfigureAutomaticUpdates, !savingAutomaticUpdates, let stamp = changeStamp() else { return }
        let token = UUID()
        settingsToken = token
        savingAutomaticUpdates = true
        readToken = UUID()
        let outcome = await stamp.client.setAgentAutomaticUpdates(enabled)
        if settingsToken == token { settingsToken = nil; savingAutomaticUpdates = false }
        guard workspace?.isCurrent(stamp) == true else { return }
        readToken = UUID()
        switch outcome {
        case let .saved(value):
            notice = nil
            if let catalog { self.catalog = AgentCatalog(registry: catalog.registry, agents: catalog.agents, automaticUpdates: value) }
            await refresh()
        case .uncertain:
            notice = WorkspaceNotice("Automatic update setting wasn’t confirmed",
                                     message: "The answer didn’t arrive. Check the setting after reconnecting before trying again.", tone: .warning)
            await refresh()
        case let .failed(error):
            if error == .unreachable { workspace?.noteConnectionFailure() }
            notice = WorkspaceNotice("Couldn’t change automatic updates", message: error.localizedDescription, tone: .error)
        }
    }

    var hostName: String { workspace?.hostName ?? "your Mac" }

    // MARK: Lists

    /// Installed on the host, by name: registry agents AgentLand keeps (OpenCode among them) and agents found
    /// on the Mac, each only while it is there (`AgentInfo.isPresent`; an older host's OpenCode from inside
    /// the Mac app too). Claude Code or Codex that the Mac does not have is in neither list: AgentLand cannot
    /// install them.
    public var installed: [AgentInfo] { filtered.filter(\.isPresent) }

    /// Registry agents not installed yet (a failed install included), by name: OpenCode too, before the
    /// host's first install of it.
    public var available: [AgentInfo] { filtered.filter { !$0.isInstalled && $0.source == .registry } }

    /// An install, update or uninstall runs on the host.
    public var hasWorkRunning: Bool { catalog?.agents.contains { $0.state.isRunning } == true || !uninstalling.isEmpty }

    /// Something this device asked for is under way for the agent: a change on its way, or an uninstall the
    /// host is doing.
    public func isBusy(_ agent: AgentInfo) -> Bool {
        changing.contains(agent.id) || uninstalling[agent.id] != nil || agent.state.isRunning
    }

    /// What this device waits for on the agent, in words: its change on its way, or the uninstall the host
    /// is doing.
    public func pendingText(_ agent: AgentInfo) -> String? {
        if changing.contains(agent.id) { return "Sending…" }
        if uninstalling[agent.id] != nil { return "Uninstalling…" }
        return nil
    }

    private var filtered: [AgentInfo] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return (catalog?.agents ?? [])
            .filter { query.isEmpty || $0.name.localizedStandardContains(query) || $0.id.localizedStandardContains(query)
                || $0.description?.localizedStandardContains(query) == true }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func agent(_ id: String) -> AgentInfo? { catalog?.agents.first { $0.id == id } }

    // MARK: Reading

    /// Keeps the list current while the pane shows: reads it now, then again every `pollInterval` while work
    /// runs on the host and it answers. Ends when the task is cancelled.
    public func follow() async {
        await refresh()
        while !Task.isCancelled {
            do { try await Task.sleep(for: pollInterval) } catch { return }
            guard hasWorkRunning, canChange else { continue }
            await refresh()
        }
    }

    /// Reads the host's agents again. Nothing is asked while it does not answer: what was read stays.
    public func refresh() async {
        guard canChange, let stamp = workspace?.requestStamp() else { return }
        let token = UUID()
        readToken = token
        let result: Result<AgentCatalog, Error>
        do { result = .success(try await stamp.client.agents()) } catch { result = .failure(error) }
        // Another host, another connection or a newer read: this answer no longer counts.
        guard workspace?.isCurrent(stamp) == true, readToken == token else { return }
        switch result {
        case let .success(value):
            let before = catalog
            catalog = value
            loadIssue = nil
            reportFinishedWork(before: before, after: value)
            settleUninstalls(value)
            await followUsableAgents(value)
        case let .failure(error):
            // The pane went away while it read: nothing failed.
            if isCancellation(error) { return }
            loadIssue = error.localizedDescription
            if ClientError.isConnectionFailure(error) { workspace?.noteConnectionFailure() }
        }
    }

    /// An install, update or uninstall that ended between two reads says how it went.
    private func reportFinishedWork(before: AgentCatalog?, after: AgentCatalog) {
        guard let before else { return }
        for earlier in before.agents where earlier.state.isRunning {
            let agent = after.agents.first { $0.id == earlier.id }
            if agent?.state.isRunning == true { continue }
            switch earlier.state {
            case .installing:
                guard let agent else { continue }
                notice = agent.isInstalled
                    ? WorkspaceNotice("Installed \(agent.name)", message: installedMessage(agent), tone: .success)
                    : WorkspaceNotice("Couldn’t install \(agent.name)", message: agent.lastError, tone: .error)
            case .updating:
                guard let agent else { continue }
                if let error = agent.lastError {
                    notice = WorkspaceNotice("Couldn’t update \(agent.name)", message: error + " It keeps its current version.", tone: .warning)
                } else {
                    notice = WorkspaceNotice("Updated \(agent.name)", message: agent.installedVersion.map { "Version \($0)." }, tone: .success)
                }
            case .uninstalling:
                // The host said how it ended, so this device no longer waits for it. An agent the registry no
                // longer lists leaves the list with its uninstall.
                uninstalling[earlier.id] = nil
                if let agent, agent.isInstalled {
                    notice = WorkspaceNotice("Couldn’t uninstall \(agent.name)",
                                             message: agent.lastError == earlier.lastError ? nil : agent.lastError, tone: .error)
                } else {
                    notice = WorkspaceNotice("Uninstalled \((agent ?? earlier).name)", tone: .success)
                }
            default:
                break
            }
        }
    }

    /// An uninstall this device sent ends when the list no longer has the agent installed, or shows a new
    /// error for it. While the host reports `uninstalling` it is followed with no limit, as installs and
    /// updates are, and `reportFinishedWork` says how it ended; for a host that does not report it, the pane
    /// stops waiting after `uninstallWait` and says it may still be running.
    private func settleUninstalls(_ catalog: AgentCatalog) {
        for (id, pending) in uninstalling {
            let agent = catalog.agents.first { $0.id == id }
            if agent?.state == .uninstalling { continue }
            let name = agent?.name ?? id
            if agent?.isInstalled != true {
                uninstalling[id] = nil
                notice = WorkspaceNotice("Uninstalled \(name)", tone: .success)
            } else if let error = agent?.lastError, error != pending.earlierError {
                uninstalling[id] = nil
                notice = WorkspaceNotice("Couldn’t uninstall \(name)", message: error, tone: .error)
            } else if Date() >= pending.deadline {
                uninstalling[id] = nil
                notice = WorkspaceNotice("\(name) may still be uninstalling",
                                         message: "It’s still listed as installed. Check the list before trying again.", tone: .warning)
            }
        }
    }

    private func installedMessage(_ agent: AgentInfo) -> String? {
        agent.terminal ? "It’s in New Terminal." : nil
    }

    /// New Terminal list the host's `agentCatalog`: when the agents that can be used differ
    /// from the last read's (an install finished, an uninstall), the host's capabilities are read again.
    private func followUsableAgents(_ catalog: AgentCatalog) async {
        let usable = Set(catalog.agents.filter(\.isPresent).map(\.id))
        let previous = lastUsable
        lastUsable = usable
        guard let previous, previous != usable else { return }
        await workspace?.refreshProjects()
    }

    // MARK: Changes

    /// Install: a download the host cannot check asks first, naming where it comes from. An agent with nothing
    /// for this Mac (`supported` false) offers no Install and is never asked about.
    public func install(_ agent: AgentInfo) async {
        guard canInstall, agent.supported else { return }
        guard agent.verified else {
            pendingUnverified = UnverifiedDownload(agent: agent, isUpdate: false)
            return
        }
        await send(.install, agent)
    }

    /// Update Now: the latest version at once, for managed agents and supported local self-updaters. When the registry moved the agent
    /// to a download the host cannot check, the host refuses (`unverified_download`) and the person is asked,
    /// as for Install.
    public func update(_ agent: AgentInfo) async {
        guard canInstall, agent.canUpdate else { return }
        await send(.update, agent)
    }

    /// Install or Update Now again, after the person confirmed a download the host cannot check
    /// (`allowUnverified`). Only this sends it again.
    public func confirmUnverified(_ download: UnverifiedDownload) async {
        pendingUnverified = nil
        guard canInstall else { return }
        if download.isUpdate {
            guard download.agent.isManaged else { return }
            await send(.update, download.agent, allowUnverified: true)
        } else {
            guard download.agent.supported else { return }
            await send(.install, download.agent, allowUnverified: true)
        }
    }

    /// Uninstall asks first. Only for agents AgentLand can remove (`AgentInfo.canUninstall`): never OpenCode,
    /// which AgentLand's chats need.
    public func requestUninstall(_ agent: AgentInfo) {
        guard canInstall, agent.canUninstall else { return }
        pendingUninstall = agent
    }

    public func uninstall(_ agent: AgentInfo) async {
        pendingUninstall = nil
        guard canInstall, agent.canUninstall else { return }
        await send(.uninstall, agent)
    }

    /// The questions close (the lock, the sheet going away).
    public func dismissQuestions() {
        pendingUnverified = nil
        pendingUninstall = nil
    }

    enum Change {
        case install, update, uninstall

        var doing: String {
            switch self {
            case .install: "installed"
            case .update: "updated"
            case .uninstall: "uninstalled"
            }
        }

        var verb: String {
            switch self {
            case .install: "install"
            case .update: "update"
            case .uninstall: "uninstall"
            }
        }
    }

    private func send(_ change: Change, _ agent: AgentInfo, allowUnverified: Bool = false) async {
        guard !changing.contains(agent.id), uninstalling[agent.id] == nil, let stamp = changeStamp() else { return }
        let token = UUID()
        changeTokens[agent.id] = token
        changing.insert(agent.id)
        let outcome: AgentChangeOutcome
        switch change {
        case .install: outcome = await stamp.client.installAgent(id: agent.id, allowUnverified: allowUnverified)
        case .update: outcome = await stamp.client.updateAgent(id: agent.id, allowUnverified: allowUnverified)
        case .uninstall: outcome = await stamp.client.uninstallAgent(id: agent.id)
        }
        // This change is no longer on its way, whatever became of the host meanwhile.
        if changeTokens[agent.id] == token {
            changeTokens[agent.id] = nil
            changing.remove(agent.id)
        }
        guard workspace?.isCurrent(stamp) == true else { return }
        switch outcome {
        case let .accepted(answered):
            // Reads made before the change no longer count; the host's answer shows at once.
            readToken = UUID()
            if let answered, let catalog { self.catalog = catalog.replacing(answered) }
            // The host uninstalls in the background: the list says when it is done.
            if case .uninstall = change {
                uninstalling[agent.id] = PendingUninstall(deadline: Date().addingTimeInterval(uninstallWait), earlierError: agent.lastError)
            }
            await refresh()
        case .refused(.unverifiedDownload, _) where change != .uninstall && !allowUnverified:
            // The host cannot check this download (after all, or since the registry changed it): the person
            // is asked first, and only their confirmation sends it again.
            pendingUnverified = UnverifiedDownload(agent: agent, isUpdate: change == .update)
        case let .refused(reason, message):
            notice = refusalNotice(reason, message: message, agent: agent, change: change)
            if reason == .unknownAgent || reason == .notManaged { await refresh() }
        case let .failed(error):
            if error == .unreachable { workspace?.noteConnectionFailure() }
            notice = WorkspaceNotice("Couldn’t \(change.verb) \(agent.name)", message: error.localizedDescription, tone: .error)
        case .uncertain:
            notice = WorkspaceNotice("\(agent.name) may have been \(change.doing)",
                                     message: "The answer didn’t arrive. The list was read again; check it before trying again.",
                                     tone: .warning)
            await refresh()
        }
    }

    private func refusalNotice(_ reason: AgentRefusal, message: String, agent: AgentInfo, change: Change) -> WorkspaceNotice {
        switch reason {
        case .busy:
            WorkspaceNotice("\(agent.name) is in use",
                            message: "A chat or terminal of it is running on \(hostName). Try again once it has finished.", tone: .warning)
        case .notManaged:
            WorkspaceNotice("AgentLand doesn’t \(change.verb) \(agent.name)",
                            message: "It’s updated by its own installer on \(hostName).", tone: .warning)
        case .required:
            WorkspaceNotice("AgentLand needs \(agent.name), so it can’t be uninstalled.", tone: .warning)
        case .unsupportedPlatform:
            WorkspaceNotice("\(agent.name) isn’t available for \(hostName)", message: message.isEmpty ? nil : message, tone: .error)
        case .unknownAgent:
            WorkspaceNotice("\(agent.name) is no longer listed", message: "The list was read again.", tone: .warning)
        case .unverifiedDownload:
            WorkspaceNotice("Couldn’t \(change.verb) \(agent.name)", message: message.isEmpty ? nil : message, tone: .error)
        }
    }

    // MARK: Requests

    /// The host, when it answers now; otherwise the notice says nothing was changed.
    private func changeStamp() -> HostRequestStamp? {
        guard canChange, let stamp = workspace?.requestStamp() else {
            notice = WorkspaceNotice("\(hostName) isn’t connected", message: "Nothing was changed. Try again once it’s connected.",
                                     tone: .warning)
            return nil
        }
        return stamp
    }

    /// Everything goes with the host.
    func reset() {
        readToken = UUID()
        lastUsable = nil
        catalog = nil
        settingsToken = nil
        savingAutomaticUpdates = false
        loadIssue = nil
        notice = nil
        search = ""
        pendingUnverified = nil
        pendingUninstall = nil
        changing = []
        changeTokens = [:]
        uninstalling = [:]
        icons.reset()
    }
}
