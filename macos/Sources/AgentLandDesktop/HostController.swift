import AppKit
import SwiftUI
import SystemConfiguration
import Security
import Darwin
import AgentLandDesktopCore
import AgentLandPairing
import AgentLandCore
import AgentLandNotifications

protocol OpenCodeRuntimeRunning: Sendable {
    /// Starts the host's managed OpenCode, or the previous version it keeps when the current one does not
    /// start. Throws `ManagedOpenCodeError.unavailable` when none starts.
    func start(directory: String, password: String, providerEnvironment: [String: String], model: String?) async throws -> URL
    func stop() async throws
    func isRunning() async -> Bool
    func endpoint() async -> URL?
    /// What runs: the host's current OpenCode or its previous version, its version, and why the previous one runs.
    func report() async -> OpenCodeRuntimeReport?
    /// A start now would run another managed OpenCode than the one running (the host installed one).
    func restartWouldChangeBinary() async -> Bool
    /// The host's current OpenCode passes the checks, so a start needs nothing downloaded.
    func hasValidManagedOpenCode() async -> Bool
    /// Versions that did not start on this Mac and that the host has not heard about.
    func pendingFailureReports() async -> [OpenCodeFailureReport]
    func noteFailureReported(_ report: OpenCodeFailureReport) async
    /// Try Again: every version the host keeps is tried again.
    func forgetFailures() async
}
extension OpenCodeRuntimeRunning {
    func report() async -> OpenCodeRuntimeReport? { nil }
    func restartWouldChangeBinary() async -> Bool { false }
    func hasValidManagedOpenCode() async -> Bool { true }
    func pendingFailureReports() async -> [OpenCodeFailureReport] { [] }
    func noteFailureReported(_ report: OpenCodeFailureReport) async {}
    func forgetFailures() async {}
}
extension ManagedOpenCodeRuntime: OpenCodeRuntimeRunning {}

@MainActor
final class HostController: ObservableObject {
    static let shared = HostController()
    enum ConnectionMode: String, CaseIterable, Identifiable, Codable {
        case developmentHTTP
        case trustedHTTPS
        var id: String { rawValue }
    }

    /// Setup's steps: the folder, the local service (and OpenCode) getting ready, Claude Code and Codex as this Mac is
    /// signed in to them (Chat's sign-ins, whatever OpenCode does; owner, 2026-10-17), then pairing.
    enum OnboardingStage { case folder, preparing, agents, ready }
    @Published private(set) var onboardingStage: OnboardingStage = .folder
    @Published private(set) var setupProgress: String?
    @Published var managedOpenCode = true { didSet { persistPreferences() } }
    @Published private(set) var connectionDesired = false { didSet { persistPreferences() } }
    @Published private(set) var isOpeningWeb = false
    private var openWebTask: Task<Void, Never>?
    @Published var providerOptions: [OpenCodeProviderOption] = []
    @Published var selectedProviderID = ""
    @Published var selectedModelID = ""
    @Published var providerAPIKey = ""
    @Published private(set) var providerIsWorking = false
    @Published private(set) var providerMessage: String?
    /// Every provider the running managed OpenCode lists (`GET /provider`), for Settings → AI Providers;
    /// kept from its last read while it does not run.
    @Published private(set) var providerCatalog: [OpenCodeProviderOption] = []
    /// Why the provider list could not be read.
    @Published private(set) var providerCatalogMessage: String?
    /// What the managed runtime runs: the host's current OpenCode or its previous version, its version, and
    /// why the previous one runs. Nil while it does not run.
    @Published private(set) var openCodeReport: OpenCodeRuntimeReport?
    /// Getting OpenCode through the host (`install-opencode`) during a start, when it has none that passes
    /// the checks: the step and the download's progress. Nil otherwise.
    @Published private(set) var openCodeInstall: OpenCodeInstallProgress?
    /// Why no OpenCode runs while the host does: AgentLand could not get it, or none the host keeps started.
    /// Devices keep terminals and files meanwhile. Nil otherwise.
    @Published private(set) var openCodeUnavailable: OpenCodeUnavailability?
    /// Provider keys or the default model changed since the running OpenCode started; they apply when it
    /// restarts (`OpenCodeRestartPolicy`).
    @Published private(set) var openCodeSettingsPending = false
    /// The last restart AgentLand made on its own, when and why (Settings → AI Providers).
    @Published private(set) var openCodeActivity: String?
    /// Whether AgentLand learns when the running host is idle (`idleForSeconds` in its `GET /v1/agents`),
    /// so it restarts OpenCode on its own: false for a host without the catalog, and when AgentLand does
    /// not read it (development HTTP); nil until asked.
    @Published private(set) var hostReportsIdle: Bool?
    private var onboardingComplete = false
    private var savedProviderID = ""
    private var savedModelID = ""
    private var providerCredentialNames: [String: String] = [:]
    private var providerRequestID = UUID()
    private var managedRuntimeActive = false
    // Managed OpenCode and its Go host share this only while both are owned.
    // The legacy external-loopback password remains in Keychain separately.
    private var managedServicePassword: String?
    private var finishAfterConnecting = false
    var needsOnboarding: Bool { !onboardingComplete }
    var requiresShutdown: Bool { startTask != nil || status != .stopped || managedRuntimeActive || remoteAccess.needsShutdown }

    @Published var projectDirectory = "" { didSet { persistPreferences() } }
    @Published var projectName = "" { didSet { persistPreferences() } }
    @Published var projectID = "workspace" { didSet { persistPreferences() } }
    @Published var openCodeURL = "http://127.0.0.1:4197" { didSet { persistPreferences() } }
    @Published var openCodePassword = ""
    @Published var listenAddress = "0.0.0.0:9841" { didSet { persistPreferences() } }
    @Published var terminalEnabled = false { didSet { persistPreferences() } }
    /// Coding agents typed in Terminal open in AgentLand (Settings → Terminals): the saved switch. `setTerminalRouting`
    /// changes it and the shell setup together; while terminal access is off it stays on, paused (`terminals hook pause`).
    @Published var terminalRoutingEnabled = false { didSet { persistPreferences() } }
    /// Why the last `terminals hook` failed, in the command's own words (a damaged block in ~/.zshrc says which lines to
    /// remove); shown under the switch. The next one that works clears it.
    @Published private(set) var terminalRoutingIssue: String?
    /// True while a `terminals hook` command runs.
    @Published private(set) var changingTerminalRouting = false
    @Published var connectionMode: ConnectionMode = .trustedHTTPS {
        didSet {
            persistPreferences()
            // Remote access carries the host's HTTPS: in development HTTP its endpoint and mapping stop.
            remoteAccess.setTunnelServed(connectionMode == .trustedHTTPS)
        }
    }
    @Published var certificatePath = "" { didSet { persistPreferences() } }
    @Published var keyPath = "" { didSet { persistPreferences() } }
    @Published var advertisedHost = HostController.defaultAdvertisedHost() { didSet { persistPreferences() } }
    @Published var certificateFingerprint: String? { didSet { persistPreferences() } }
    @Published var configuration: HostConfiguration?
    @Published var devices: [ManagedDevice] = []
    @Published var status: HostStatus = .stopped
    @Published var pairingCode: String?
    @Published private(set) var pairingInvitation: PairingInvitation?
    @Published private(set) var activeAdvertisement: HostAdvertisement?
    @Published private(set) var activeListenAddress: String?
    @Published private(set) var sessionClient: APIClient?
    /// The routes the running host lists (docs/HOST-API.md, "Routes"): its local name and, while
    /// Tailscale runs on this Mac, its Tailscale name. Nil until read, or when the host lists none.
    @Published private(set) var advertisedRoutes: [HostRoute]?
    /// What the host last read of Tailscale beside its routes (`running`, `notListening`, `off`,
    /// `notFound`, `unknown`); nil until read, or from a host that does not say.
    @Published private(set) var advertisedTailscale: String?
    /// The running host lists `remoteAccess` in capabilities (it takes node IDs), so its QR invitations
    /// carry `remoteAccess: {"version": 1}` (docs/HOST-API.md "Pairing with a node ID"). False until read.
    @Published private(set) var advertisedRemoteAccess = false
    @Published private(set) var nearbyDiscoveryAvailable = false
    @Published private(set) var nearbyDiscoveryFailed = false
    @Published var errorMessage: String?
    @Published var isWorking = false
    /// Push notifications through the owner's iCloud; it relays this host's
    /// notices while the host runs.
    let notifications: NotificationRelayController
    /// Remote access over iroh (off by default): the Mac endpoint, the router mapping and the address
    /// record follow its switch; the host's starts and stops reach it from here.
    let remoteAccess: RemoteAccessController
    /// Names every terminal on the host with Apple's on-device model while Settings → General's Apple Intelligence is
    /// on (`HostTerminalNaming`); the host's starts and stops reach it from here.
    let terminalNaming: HostTerminalNaming

    private let statePath: String
    private let runner: any HostCommandRunning
    private let secrets: any SecretStoring
    private let lifecycle: HostLifecycle
    private let runtime: any OpenCodeRuntimeRunning
    /// Gets the host's managed OpenCode when a start has none (`install-opencode`).
    private let openCodeInstaller: any OpenCodeInstalling
    /// The install whose progress `openCodeInstall` shows; its events after it ended are dropped.
    private var openCodeInstallID: UUID?
    /// Try Again: the next start tries every version the host keeps again.
    private var retryingOpenCode = false
    private var failureReportTask: Task<Void, Never>?
    private let passwordAccount = "opencode.password"
    private let preferences: UserDefaults
    private var isRestoringPreferences = true
    private let discovery = HostDiscoveryPublisher()
    private var startTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private var routesTask: Task<Void, Never>?
    private var startupID = UUID()
    private var pairingID = UUID()
    private var loaded = false
    private enum WorkKind { case other, pairing }
    private var workKind: WorkKind?
    /// The pairing code being made, until the host's answer arrives (`createPairingCode`, `keepPairingCodeFresh`).
    private var pairingRequest: UUID?
    private var lastPairingAttempt: Date?
    /// What the last completed Connect started, kept while those services should run; the monitor
    /// restarts from it when the host or the managed runtime exits on its own.
    private var ownedLaunch: OwnedLaunch?
    private var restartBackoff: RestartBackoff
    private let monitorInterval: Duration
    /// Reads the host's agent catalog for the restart rule. Tests pass their own; the app reads the host
    /// with its local session (trusted HTTPS only).
    private let makeAgentsFeed: (@MainActor (_ sessionToken: String) -> (any HostAgentsReading)?)?
    private let agentsPollInterval: Duration
    /// How long a failure report the host did not take waits before it is sent again while the host runs
    /// (`reportOpenCodeFailures`).
    private let failureReportRetry: Duration
    private var agentsTask: Task<Void, Never>?
    private var agentsFeed: (any HostAgentsReading)?
    /// The host's Mac-only terminal routes, for this session; tests pass their own.
    private let makeTerminalsFeed: (@MainActor (_ sessionToken: String) -> (any HostTerminalsReading)?)?
    private(set) var terminalsFeed: (any HostTerminalsReading)?
    /// Set by the Quit buttons only: logout, restart and system shutdown never ask about terminals.
    var deliberateQuit = false
    /// The Terminals pane's list, kept current by `followTerminals` while the pane shows.
    @Published private(set) var terminalList: HostTerminalList?
    /// Set when the host answered 403 `terminal_disabled`: the pane says terminals are off.
    @Published private(set) var terminalsOff = false
    /// Why the last list failed, for the pane; nil after a good read.
    @Published private(set) var terminalsIssue: String?
    /// Why the last End or Clear failed. Polling never clears it; the next successful action or `dismissTerminalActionError` does.
    @Published private(set) var terminalActionError: String?
    /// What `terminalActionError` is titled: the pane's action failure, or Open in Terminal's.
    @Published private(set) var terminalActionErrorTitle = TerminalsText.actionFailedTitle
    /// Shown in Devices after a revoke that went through while ending the device's terminals did not.
    @Published private(set) var revokeNotice: String?
    var terminalsPollInterval: Duration = .seconds(2)
    /// True while "End Terminals" from the switch runs.
    @Published private(set) var endingTerminals = false
    /// The last `terminals hook` command asked for. They run one at a time in the order asked, so the last one asked is
    /// what the shell setup ends up as.
    private var hookTask: Task<Bool, Never>?
    private var routingChangeTask: Task<Void, Never>?
    private var hookGeneration = 0
    private var openCodeCheckRunning = false
    /// Provider keys and the default model change this; the running OpenCode started with `appliedSettings`.
    private var settingsGeneration = 0
    private var appliedSettings = 0

    init(
        statePath: String = HostController.defaultStatePath(),
        runner: any HostCommandRunning = ProcessCommandRunner(),
        secrets: any SecretStoring = KeychainSecretStore(),
        lifecycle: HostLifecycle = HostLifecycle(),
        preferences: UserDefaults = .standard,
        runtime: (any OpenCodeRuntimeRunning)? = nil,
        openCodeInstaller: (any OpenCodeInstalling)? = nil,
        notifications: NotificationRelayController? = nil,
        remoteAccess: RemoteAccessController? = nil,
        restartBackoff: RestartBackoff = RestartBackoff(),
        monitorInterval: Duration = .seconds(2),
        agentsFeed: (@MainActor (_ sessionToken: String) -> (any HostAgentsReading)?)? = nil,
        agentsPollInterval: Duration = OpenCodeRestartPolicy.pollInterval,
        failureReportRetry: Duration = .seconds(30),
        terminalsFeed: (@MainActor (_ sessionToken: String) -> (any HostTerminalsReading)?)? = nil,
        terminalNaming: HostTerminalNaming? = nil
    ) {
        self.statePath = statePath
        self.runner = runner
        self.secrets = secrets
        self.lifecycle = lifecycle
        self.preferences = preferences
        // The host installs its OpenCode in `<state>.agents`, and each start runs it once it passes the
        // checks; the app bundles none.
        // OpenCode's output goes to ~/Library/Logs/AgentLand/opencode.log (the host's to host.log, HostLifecycle).
        self.runtime = runtime ?? ManagedOpenCodeRuntime(
            agentsFolder: HostCommandBuilder.agentsFolderPath(statePath: statePath).map { URL(fileURLWithPath: $0, isDirectory: true) },
            logFolder: ChildProcessLog.defaultFolder)
        self.openCodeInstaller = openCodeInstaller ?? HostOpenCodeInstaller()
        self.restartBackoff = restartBackoff
        self.monitorInterval = monitorInterval
        self.makeAgentsFeed = agentsFeed
        self.makeTerminalsFeed = terminalsFeed
        self.agentsPollInterval = agentsPollInterval
        self.failureReportRetry = failureReportRetry
        self.notifications = notifications ?? NotificationRelayController(preferences: preferences)
        self.remoteAccess = remoteAccess ?? RemoteAccessController(statePath: statePath, preferences: preferences)
        self.terminalNaming = terminalNaming ?? HostTerminalNaming(preferences: preferences)
        let existingState = FileManager.default.fileExists(atPath: statePath)
        managedOpenCode = !existingState
        onboardingComplete = existingState
        if let saved = Self.readPreferences(from: preferences) {
            projectDirectory = saved.projectDirectory
            projectName = saved.projectName
            projectID = saved.projectID
            openCodeURL = saved.openCodeURL
            listenAddress = saved.listenAddress
            terminalEnabled = saved.terminalEnabled
            terminalRoutingEnabled = saved.terminalRouting ?? false
            connectionMode = saved.connectionMode
            certificatePath = saved.certificatePath
            keyPath = saved.keyPath
            advertisedHost = saved.advertisedHost
            certificateFingerprint = saved.certificateFingerprint
            managedOpenCode = saved.managedOpenCode ?? !existingState
            connectionDesired = saved.connectionDesired ?? false
            onboardingComplete = saved.onboardingComplete ?? existingState
            savedProviderID = saved.providerID ?? ""
            savedModelID = saved.modelID ?? ""
            providerCredentialNames = saved.providerCredentialNames ?? [:]
            selectedProviderID = savedProviderID
            selectedModelID = savedModelID
        }
        if !existingState { onboardingComplete = false; connectionDesired = false }
        onboardingStage = onboardingComplete ? .ready : .folder
        isRestoringPreferences = false
        self.remoteAccess.setTunnelServed(connectionMode == .trustedHTTPS)
        discovery.onPublicationChange = { [weak self] available, failed in
            self?.nearbyDiscoveryAvailable = available
            self?.nearbyDiscoveryFailed = failed
        }
    }

    static func defaultStatePath() -> String {
        if Bundle.main.bundleIdentifier == "dev.agentland.desktop.uitest",
           let isolated = ProcessInfo.processInfo.environment["AGENTLAND_TEST_STATE_PATH"],
           isolated.hasPrefix("/") {
            return isolated
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appending(path: "agentland/host.json").path
    }

    static func defaultAdvertisedHost() -> String {
        if let localName = SCDynamicStoreCopyLocalHostName(nil) as String?, !localName.isEmpty {
            return "\(localName).local"
        }
        let firstLabel = ProcessInfo.processInfo.hostName.split(separator: ".").first.map(String.init) ?? "agentland-mac"
        return "\(firstLabel).local"
    }

    private static func bonjourServiceName() -> String {
        var name = Host.current().localizedName ?? "AgentLand Mac"
        while name.utf8.count > 63 { name.removeLast() }
        return name.isEmpty ? "AgentLand Mac" : name
    }

    var hasState: Bool { FileManager.default.fileExists(atPath: statePath) }

    /// Keeps the saved default workspace (the project every start merges into the host's state and runs
    /// the managed runtime in) in step with the host's own list, which devices now change while it runs:
    /// a rename there is kept at the next start, and a removed default is replaced by `preferred` or the
    /// first workspace listed rather than added back. Only lists with details (folders) are followed.
    /// A restart after a child exits reads the host's list itself (`startServices(followingHost:)`).
    func followWorkspaces(_ projects: [Project], preferred: String? = nil) {
        let listed = projects.compactMap { project in
            project.directory.map { ProjectConfiguration(id: project.id, name: project.name, directory: $0) }
        }
        guard !listed.isEmpty, listed.count == projects.count else { return }
        adoptDefault(from: listed, preferred: preferred)
    }

    /// Makes the saved default the listed workspace with its ID (its name and folder as listed), or
    /// `preferred` or the first one when its ID is no longer listed. Returns the default.
    @discardableResult
    private func adoptDefault(from listed: [ProjectConfiguration], preferred: String?) -> ProjectConfiguration? {
        if let current = listed.first(where: { $0.id == projectID }) {
            if projectName != current.name { projectName = current.name }
            if projectDirectory != current.directory { projectDirectory = current.directory }
            return current
        }
        guard let replacement = listed.first(where: { $0.id == preferred }) ?? listed.first else { return nil }
        projectID = replacement.id
        projectName = replacement.name
        projectDirectory = replacement.directory
        return replacement
    }

    var connectionSummary: String {
        switch connectionMode {
        case .developmentHTTP: "Local development only"
        case .trustedHTTPS: "Trusted HTTPS for a phone or tablet"
        }
    }

    func load() {
        guard !loaded else { return }
        loaded = true
        guard hasState else { return }
        // The hook names this app's agentland-host, which may have moved since it was written: on writes it again.
        if terminalRoutingEnabled { enqueueHook(terminalEnabled ? .on : .pause) }
        begin()
        let id = UUID()
        startupID = id
        startTask = Task {
            do {
                let output = try await execute(HostCommandBuilder.showConfiguration(statePath: statePath), id: id)
                applyConfiguration(.success(try HostOutputParser.configuration(output.standardOutput)))
                startTask = nil
                refreshDevices(showActivity: false)
                if connectionDesired { start() }
            } catch {
                guard startupID == id else { return }
                present(error)
                startTask = nil
            }
        }
    }

    private func reloadConfiguration() {
        // Only legacy manual saves use this path. Loading never changes connection intent.
        loaded = false
        load()
    }

    func startMonitoring() {
        guard monitorTask == nil else { return }
        let interval = monitorInterval
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                guard let self else { return }
                // A start, stop or restart in progress owns the children until it ends.
                if self.isWorking || self.startTask != nil { continue }
                await self.lifecycle.refreshStatus()
                let hostRunning = await self.lifecycle.currentStatus == .running
                let runtimeRunning = await self.runtime.isRunning()
                if self.isWorking || self.startTask != nil { continue }
                if let launch = self.ownedLaunch, self.connectionDesired {
                    // A child exited on its own while the connection is wanted: start it again
                    // (the managed runtime takes the host with it, since the host binds its address).
                    // A host that runs without OpenCode (none was available) is not restarted for it.
                    let runtimeExited = launch.request.managed && launch.openCodeRuns && !runtimeRunning
                    if !hostRunning || runtimeExited {
                        self.restartOwnedServices(self.terminalEnabled ? launch : launch.withoutTerminals, runtimeExited: runtimeExited)
                        continue
                    }
                    // Terminal access went off while a start was under way: that host came up with terminals on.
                    if launch.request.terminal, !self.terminalEnabled {
                        self.restartOwnedServices(launch.withoutTerminals, runtimeExited: false, immediate: true)
                        continue
                    }
                } else if self.managedRuntimeActive && (!hostRunning || !runtimeRunning) {
                    self.clearPublishedHost()
                    do { try await self.stopOwnedServices() }
                    catch { self.present(error); continue }
                    self.present(DesktopError.commandFailed("The local service stopped. Choose Connect to start it again."))
                }
                await self.updateLifecycleStatus()
                if self.status == .running {
                    self.refreshDevices(showActivity: false)
                }
            }
        }
    }

    func chooseWorkspaceAndSetUp() {
        guard !isWorking else { return }
        chooseFile(directoryOnly: true) { self.chooseWorkspace(at: URL(fileURLWithPath: $0)) }
    }

    /// Shared by the native folder picker and disposable integration tests.
    func chooseWorkspace(at directory: URL) {
        guard !isWorking else { return }
        do {
            try Self.validateWorkspace(directory.path)
            projectDirectory = directory.path
            projectName = directory.lastPathComponent.replacingOccurrences(of: "=", with: " ")
            if projectName.isEmpty { projectName = "Workspace" }
            managedOpenCode = true
            if !hasState {
                terminalEnabled = true
                connectionMode = .trustedHTTPS
                listenAddress = try Self.availableInitialListener(preferred: listenAddress)
            }
            connect(reconfigure: true)
        } catch { present(error) }
    }

    func retrySetup() { connect(reconfigure: true) }

    /// Try Again after OpenCode wasn't available: stops the host (`install-opencode` takes the host's state
    /// only while no host serves it), gets OpenCode when the host has none, tries every version it keeps
    /// again, then starts OpenCode and the host.
    func retryOpenCode() {
        guard managedOpenCode, !isWorking else { return }
        retryingOpenCode = true
        connect(reconfigure: true)
    }

    func saveConfiguration() {
        guard !isWorking else { return }
        if managedOpenCode { connect(reconfigure: true); return }
        do {
            let project = try currentProject()
            _ = try passwordForSave()
            if !openCodePassword.isEmpty {
                try secrets.save(openCodePassword, account: passwordAccount)
                openCodePassword = ""
            }
            let command = try hasState
                ? HostCommandBuilder.configureCommand(statePath: statePath, projects: ProjectConfiguration.replacing(configuration?.projects ?? [], with: project), openCodeURL: openCodeURL, passwordEnvironment: "AGENTLAND_OPENCODE_PASSWORD")
                : HostCommandBuilder.initCommand(statePath: statePath, project: project, openCodeURL: openCodeURL, passwordEnvironment: "AGENTLAND_OPENCODE_PASSWORD")
            begin()
            let id = UUID()
            startupID = id
            startTask = Task {
                do {
                    _ = try await execute(command, id: id)
                    let output = try await execute(HostCommandBuilder.showConfiguration(statePath: statePath), id: id)
                    applyConfiguration(.success(try HostOutputParser.configuration(output.standardOutput)))
                    onboardingComplete = true
                    onboardingStage = .ready
                    persistPreferences()
                } catch { if startupID == id { present(error) } }
                if startupID == id { startTask = nil; isWorking = false }
            }
        } catch { present(error) }
    }

    func start() { connect(reconfigure: false) }

    private func connect(reconfigure: Bool) {
        guard !isWorking, reconfigure || status == .stopped else { return }
        do {
            let project = try currentProject()
            let request = ConnectionRequest(project: project, managed: managedOpenCode, mode: connectionMode,
                certificate: certificatePath, key: keyPath, hostname: advertisedHost,
                listener: listenAddress, terminal: terminalEnabled, externalURL: openCodeURL)
            begin()
            clearPublishedHost()
            providerRequestID = UUID()
            providerIsWorking = false
            // A restart waiting out its backoff is the only operation that runs without `isWorking`;
            // this Connect replaces it and waits for it to let go of the children.
            let pending = startTask
            pending?.cancel()
            restartBackoff.reset()
            let id = UUID()
            startupID = id
            connectionDesired = true
            if needsOnboarding { onboardingStage = .preparing }
            status = .starting
            startTask = Task {
                await pending?.value
                do {
                    let launch = try await startServices(request, reconfigure: reconfigure, id: id)
                    ownedLaunch = launch
                    if finishAfterConnecting {
                        onboardingComplete = true
                        onboardingStage = .ready
                        finishAfterConnecting = false
                        persistPreferences()
                    } else if needsOnboarding {
                        // Chat's sign-ins come from the host, never from OpenCode: the step shows with OpenCode
                        // running, missing or external. Settings and the menu say why OpenCode isn't there.
                        onboardingStage = .agents
                    }
                    setupProgress = nil
                    isWorking = false
                    workKind = nil
                    startTask = nil
                    refreshDevices(showActivity: false)
                    if request.managed, openCodeUnavailable == nil { refreshProviders() }
                } catch {
                    guard startupID == id else { return } // Stop owns cleanup after cancellation.
                    do { try await stopOwnedServices() }
                    catch { present(error) }
                    if !(error is CancellationError) { present(error) }
                    await updateLifecycleStatus()
                    isWorking = false
                    startTask = nil
                }
            }
        } catch { present(error) }
    }

    /// Stops what runs, then starts the managed runtime (when `request.managed`) and the host.
    /// Returns what a restart of the same connection needs, with the certificate it used.
    ///
    /// A restart (`followingHost`) never applies the workspace captured at Connect: devices may have
    /// renamed or removed workspaces since. It reads the host's list as it is now, makes the saved
    /// default that list's entry (by ID, or the first when it was removed), starts the runtime there,
    /// and writes the list back unchanged with only the runtime's new address.
    private func startServices(_ request: ConnectionRequest, reconfigure: Bool, followingHost: Bool = false,
                               id: UUID) async throws -> OwnedLaunch {
        var project = request.project
        try await stopOwnedServices()
        try checkOperation(id)
        status = .starting
        setupProgress = "Securing the connection…"
        let password = try adapterPassword(managed: request.managed)
        let identity = try await certificateIdentity(request: request, id: id)
        try checkOperation(id)
        // Read the authoritative file before merging; never drop other projects or device records.
        var previous: HostConfiguration?
        if hasState {
            let output = try await execute(HostCommandBuilder.showConfiguration(statePath: statePath), id: id)
            previous = try HostOutputParser.configuration(output.standardOutput)
        }
        var projects = previous.map { ProjectConfiguration.replacing($0.projects, with: project) }
        if followingHost, let listed = previous?.projects, let current = adoptDefault(from: listed, preferred: nil) {
            try Self.validateWorkspace(current.directory)
            project = current
            projects = listed
        }
        var endpoint = request.externalURL
        var openCodeRuns = false
        if request.managed {
            managedRuntimeActive = true
            let installFailure = try await prepareOpenCode(id: id)
            setupProgress = "Starting OpenCode…"
            let settings = settingsGeneration
            do {
                let url = try await runtime.start(directory: project.directory, password: password,
                    providerEnvironment: providerEnvironment(), model: savedModel())
                try checkOperation(id)
                // What changed while it started applies at the next restart.
                appliedSettings = settings
                openCodeSettingsPending = settingsGeneration != settings
                openCodeReport = await runtime.report()
                endpoint = url.absoluteString
                openCodeRuns = true
            } catch let ManagedOpenCodeError.unavailable(reason, short) {
                try checkOperation(id)
                // The host starts without OpenCode, so devices keep terminals and files; the host keeps the
                // OpenCode address it had. Try Again, or a new OpenCode from the host, starts it later.
                managedRuntimeActive = false
                openCodeReport = nil
                openCodeUnavailable = installFailure.map { OpenCodeUnavailability(install: $0) }
                    ?? OpenCodeUnavailability(message: reason, shortReason: short)
                endpoint = previous?.openCodeURL ?? request.externalURL
            }
        }
        if request.managed || reconfigure || previous == nil {
            setupProgress = "Preparing your workspace…"
            let command = try projects.map {
                try HostCommandBuilder.configureCommand(statePath: statePath, projects: $0,
                    openCodeURL: endpoint, passwordEnvironment: "AGENTLAND_OPENCODE_PASSWORD")
            } ?? HostCommandBuilder.initCommand(statePath: statePath, project: project,
                    openCodeURL: endpoint, passwordEnvironment: "AGENTLAND_OPENCODE_PASSWORD")
            _ = try await execute(command, id: id)
        }
        let output = try await execute(HostCommandBuilder.showConfiguration(statePath: statePath), id: id)
        let configured = try HostOutputParser.configuration(output.standardOutput)
        configuration = configured
        openCodeURL = configured.openCodeURL
        let launch = OwnedLaunch(request: request.with(project: project, certificate: identity.certificate, key: identity.key),
                                 passwordEnvironment: configured.passwordEnvironment, openCodeRuns: openCodeRuns)
        try await launchHost(launch, password: password, id: id)
        return launch
    }

    /// Before OpenCode starts: when the host has no managed OpenCode that passes the checks, gets one with
    /// `install-opencode` (the host is stopped, so the command can take its state) and shows its progress.
    /// Nothing downloads while a valid one exists. Returns why getting it failed: the start goes on, with the
    /// previous version the host keeps or without OpenCode.
    private func prepareOpenCode(id: UUID) async throws -> OpenCodeInstallFailure? {
        if retryingOpenCode {
            retryingOpenCode = false
            await runtime.forgetFailures()
        }
        guard !(await runtime.hasValidManagedOpenCode()) else { return nil }
        try checkOperation(id)
        let installID = UUID()
        openCodeInstallID = installID
        let progress = OpenCodeInstallProgress()
        openCodeInstall = progress
        setupProgress = progress.title
        defer {
            if openCodeInstallID == installID {
                openCodeInstallID = nil
                openCodeInstall = nil
            }
        }
        let outcome = try await openCodeInstaller.install(statePath: statePath) { [weak self] event in
            // The events come in order on the command's reader; the main queue keeps that order.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.noteInstall(event, installID: installID) } }
        }
        try checkOperation(id)
        switch outcome {
        case .ready: return nil
        case let .failed(failure): return failure
        }
    }

    private func noteInstall(_ event: OpenCodeInstallEvent, installID: UUID) {
        guard openCodeInstallID == installID, var progress = openCodeInstall else { return }
        progress.apply(event)
        openCodeInstall = progress
        setupProgress = progress.title
    }

    /// How long a started host has to answer before Connect gives up: clearly longer than the host's worst
    /// start, which restores the terminals its keeper holds (at most 5 s) before it listens.
    static let readinessTries = 50
    static let readinessPause: Duration = .milliseconds(200)
    static var readinessWindow: Duration { readinessPause * readinessTries }

    /// Starts the host with a new local session, waits until it answers and publishes it.
    private func launchHost(_ launch: OwnedLaunch, password: String, id: UUID) async throws {
        let request = launch.request
        setupProgress = "Making this Mac available…"
        let plan: HostAdvertisingConfiguration? = request.mode == .trustedHTTPS
            ? try HostAdvertisingConfiguration(name: Self.bonjourServiceName(), listenAddress: request.listener,
                advertisedHost: request.hostname, certificatePath: request.certificate)
            : nil
        let tls: TLSConfiguration = request.mode == .developmentHTTP ? .developmentHTTP
            : .certificate(certificatePath: request.certificate, keyPath: request.key)
        // The advertised name turns on the host's routes: devices learn its Tailscale name too. The
        // tunnel socket is passed at every HTTPS start, whether or not remote access is on, so its switch
        // never restarts the host.
        let tunnelSocket = request.mode == .trustedHTTPS ? remoteAccess.tunnelSocketPath : nil
        // Plain chats' web search: the host names the search service to devices only when the app runs the
        // OpenCode it uses, with that service set.
        let webSearchProvider = request.managed && launch.openCodeRuns ? ManagedOpenCodeRuntime.webSearchProvider : nil
        var command = try HostCommandBuilder.serveCommand(statePath: statePath, listenAddress: request.listener,
            tls: tls, terminalEnabled: request.terminal,
            advertisedHost: request.mode == .trustedHTTPS ? request.hostname : nil, tunnelSocket: tunnelSocket,
            webSearchProvider: webSearchProvider,
            openCodeHome: request.managed && launch.openCodeRuns ? ManagedOpenCodeRuntime.defaultStorageRoot() : nil)
        command.environment[launch.passwordEnvironment] = password
        var sessionTokenBytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, sessionTokenBytes.count, &sessionTokenBytes) == errSecSuccess else {
            throw DesktopError.commandFailed("Could not secure the local session.")
        }
        let sessionToken = sessionTokenBytes.map { String(format: "%02x", $0) }.joined()
        command.arguments += ["--local-session-env", "AGENTLAND_LOCAL_SESSION_TOKEN"]
        command.environment["AGENTLAND_LOCAL_SESSION_TOKEN"] = sessionToken
        if let resources = Bundle.main.resourceURL {
            let web = resources.appendingPathComponent("AgentLandWeb", isDirectory: true)
            if FileManager.default.fileExists(atPath: web.appendingPathComponent("index.html").path) {
                command.arguments += ["--web-assets", web.path]
            } else if Bundle.main.bundleIdentifier == "dev.agentland.desktop" {
                throw DesktopError.commandFailed("The web workspace is missing from this app. Reinstall the complete AgentLand app.")
            }
        }
        try checkOperation(id)
        try await lifecycle.start(command)
        if let plan {
            var ready = false
            for _ in 0..<Self.readinessTries {
                try checkOperation(id)
                await lifecycle.refreshStatus()
                guard await lifecycle.currentStatus == .running else { break }
                if await HostReadinessProbe.isReady(plan.advertisement, localListener: request.listener) { ready = true; break }
                try await Task.sleep(for: Self.readinessPause)
            }
            try checkOperation(id)
            guard ready else { throw DesktopError.commandFailed("This Mac could not open its secure connection. Check the network and try Connect again.") }
            activeAdvertisement = plan.advertisement
            discovery.publish(plan.advertisement, port: plan.port)
        }
        activeListenAddress = request.listener
        await updateLifecycleStatus()
        guard status == .running else { throw DesktopError.commandFailed("The local host stopped during startup.") }
        var agents = makeAgentsFeed?(sessionToken)
        terminalsFeed = makeTerminalsFeed?(sessionToken)
        if request.mode == .trustedHTTPS,
           let fingerprint = activeAdvertisement?.certificateSHA256,
           let port = request.listener.split(separator: ":").last,
           let address = try? ServerAddress(validating: "https://127.0.0.1:\(port)") {
            let client = APIClient(address: address, token: sessionToken,
                transport: URLSessionTransport(expectedHost: "127.0.0.1", certificateSHA256: fingerprint,
                    validatedCertificateHost: request.hostname))
            sessionClient = client
            followRoutes(client)
            // The restart rule reads the host's agent catalog with this session.
            if agents == nil {
                agents = HostAgentsFeed(baseURL: address.url, token: sessionToken,
                    transport: URLSessionTransport(expectedHost: "127.0.0.1", certificateSHA256: fingerprint,
                        validatedCertificateHost: request.hostname))
            }
            if terminalsFeed == nil {
                terminalsFeed = HostTerminalsFeed(baseURL: address.url, token: sessionToken,
                    transport: URLSessionTransport(expectedHost: "127.0.0.1", certificateSHA256: fingerprint,
                        validatedCertificateHost: request.hostname))
            }
            // Every terminal is named with this session: the Mac-only list, and the routes devices name them with.
            if let feed = terminalsFeed {
                terminalNaming.hostStarted(LocalTerminalNamingHost(feed: feed, client: client))
            }
            // Remote access reports to this session and follows its peer list.
            if tunnelSocket != nil {
                remoteAccess.hostStarted(client: client, hostID: NoticeHostID.make(certificateSHA256: fingerprint))
            }
            // The relay reads this host's notices with the same local
            // session over its own pinned connection.
            if let hostID = NoticeHostID.make(certificateSHA256: fingerprint) {
                notifications.hostStarted(hostID: hostID, feed: HostNoticeFeed(baseURL: address.url, token: sessionToken,
                    transport: URLSessionTransport(expectedHost: "127.0.0.1", certificateSHA256: fingerprint,
                        validatedCertificateHost: request.hostname)))
            }
        }
        // While the managed OpenCode runs, the host's catalog says when to restart it (`OpenCodeRestartPolicy`).
        // Without it (development HTTP) nothing does: changes wait for the next start, as for a host
        // that does not report idleness. The host hears about a version that did not start once it runs.
        if request.managed {
            if let agents {
                followAgents(agents)
                reportOpenCodeFailures(to: agents)
            } else {
                hostReportsIdle = false
            }
        }
    }

    /// Tells the running host about each version that did not start on this Mac (`POST
    /// /v1/agents/opencode/failed`), so it goes back to the version it keeps and records why. A report the
    /// host did not take (409 `agent_busy` while it changes OpenCode, or no answer) is sent again every
    /// `failureReportRetry` while the host runs, up to `failureReportAttempts` times, then at the next
    /// start; a host without the route never gets it.
    private func reportOpenCodeFailures(to feed: any HostAgentsReading) {
        failureReportTask?.cancel()
        let runtime = runtime
        let retry = failureReportRetry
        failureReportTask = Task {
            for report in await runtime.pendingFailureReports() {
                for attempt in 1...Self.failureReportAttempts {
                    guard !Task.isCancelled else { return }
                    do {
                        _ = try await feed.reportOpenCodeFailure(version: report.version, reason: report.reason)
                        await runtime.noteFailureReported(report)
                        break
                    } catch {
                        if HostAgentsFeed.meansNoCatalog(error) {
                            await runtime.noteFailureReported(report)
                            break
                        }
                        guard attempt < Self.failureReportAttempts else { break }
                        do { try await Task.sleep(for: retry) } catch { return }
                    }
                }
            }
        }
    }

    /// How many times a failure report is sent while the host runs.
    static let failureReportAttempts = 5

    /// Starts again what exited on its own while the connection is wanted: the host alone when only
    /// it exited (the runtime keeps its sessions), or the runtime and the host when the runtime
    /// exited (the host binds the runtime's address at start), in the workspace the host lists now.
    /// Attempts follow `restartBackoff`, so a child that keeps exiting is never restarted in a tight
    /// loop; past its limit everything owned stops and the error shows with the last attempt's
    /// error, with the connection still wanted for the next launch. Disconnect, Quit and Connect
    /// cancel a restart like any other operation.
    ///
    /// `planned` is a restart of OpenCode and the host that the idle rule asked for (a new managed
    /// OpenCode, or changed provider settings): its first attempt starts at once and is no failure;
    /// attempts after a failed one follow `restartBackoff` like the others. `immediate` is a host-only
    /// restart the owner asked for (terminal access switched off), started at once the same way.
    private func restartOwnedServices(_ launch: OwnedLaunch, runtimeExited: Bool, planned: PlannedRestart? = nil,
                                      immediate: Bool = false) {
        var decision = planned == nil && !immediate ? restartBackoff.recordFailure() : .retry(after: 0)
        let id = UUID()
        startupID = id
        clearPublishedHost()
        status = .starting
        startTask = Task {
            var restartRuntime = runtimeExited
            var lastError: Error?
            while true {
                guard case let .retry(delay) = decision else {
                    await giveUpRestarting(id: id, lastError: lastError)
                    return
                }
                do {
                    try await Task.sleep(for: .seconds(delay))
                    try checkOperation(id)
                    begin()
                    if !restartRuntime {
                        // The exited host is already reaped; its replacement gets a new local session.
                        try await lifecycle.stop()
                        try checkOperation(id)
                        if let password = try restartPassword(for: launch) {
                            try await launchHost(launch, password: password, id: id)
                            ownedLaunch = launch
                            finishRestart(id: id)
                            return
                        }
                        // The runtime's credential is gone: start both instead.
                        restartRuntime = true
                    }
                    ownedLaunch = try await startServices(launch.request, reconfigure: false, followingHost: true, id: id)
                    if let planned, startupID == id { noteRestart(planned) }
                    finishRestart(id: id)
                    return
                } catch {
                    guard startupID == id else { return } // Stop or Connect owns cleanup after cancellation.
                    lastError = error
                    // Take down what this attempt left half started before waiting again.
                    clearPublishedHost()
                    do {
                        if restartRuntime { try await stopOwnedServices() } else { try await lifecycle.stop() }
                    } catch let stopError {
                        await giveUpRestarting(id: id, lastError: error, stopError: stopError)
                        return
                    }
                    guard startupID == id else { return }
                    isWorking = false
                    workKind = nil
                    status = .starting
                    // The runtime may have exited during a host-only attempt too.
                    if launch.request.managed, launch.openCodeRuns, !(await runtime.isRunning()) { restartRuntime = true }
                    decision = restartBackoff.recordFailure()
                }
            }
        }
    }

    private func finishRestart(id: UUID) {
        guard startupID == id else { return }
        setupProgress = nil
        isWorking = false
        workKind = nil
        startTask = nil
        refreshDevices(showActivity: false)
        if ownedLaunch?.request.managed == true { refreshProviders() }
    }

    /// The host's OpenCode password for a host-only restart: the managed runtime's in-memory one
    /// (nil once it is gone) or the external service's saved one.
    private func restartPassword(for launch: OwnedLaunch) throws -> String? {
        if launch.request.managed { return managedServicePassword.flatMap { $0.isEmpty ? nil : $0 } }
        return try passwordForSave()
    }

    /// Past the restart limit (or when what a failed attempt started cannot be stopped): stop
    /// everything owned and show why, with the last attempt's error. The connection stays wanted,
    /// so Connect (or the next launch) starts it again.
    private func giveUpRestarting(id: UUID, lastError: Error?, stopError: Error? = nil) async {
        guard startupID == id else { return }
        let failures = restartBackoff.failures.count
        ownedLaunch = nil
        clearPublishedHost()
        var stopFailure = stopError
        if stopFailure == nil {
            do { try await stopOwnedServices() } catch { stopFailure = error }
        }
        guard startupID == id else { return }
        await updateLifecycleStatus()
        let window = restartBackoff.windowDescription
        restartBackoff.reset()
        setupProgress = nil
        startTask = nil
        present(DesktopError.commandFailed(Self.restartFailureMessage(failures: failures, window: window,
                                                                      lastError: lastError, stopError: stopFailure)))
    }

    static func restartFailureMessage(failures: Int, window: String, lastError: Error?, stopError: Error?) -> String {
        func sentence(_ error: Error) -> String {
            let text = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.hasSuffix(".") ? text : text + "."
        }
        var parts = [stopError.map { "The local service could not be stopped after a failed restart: \(sentence($0))" }
            ?? "The local service stopped \(failures) times in \(window)."]
        if let lastError, !(lastError is CancellationError) { parts.append("Last error: \(sentence(lastError))") }
        parts.append("Choose Connect to start it again.")
        return parts.joined(separator: " ")
    }

    /// Launches only a host-minted loopback URL. The browser never gets the companion credential.
    func openWebWorkspace() {
        guard !isOpeningWeb, !needsOnboarding else { return }
        guard connectionMode == .trustedHTTPS else {
            present(DesktopError.commandFailed("Choose secure HTTPS in Settings → Advanced to open the web workspace."))
            return
        }
        isOpeningWeb = true
        if status == .stopped && !isWorking { start() }
        openWebTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isOpeningWeb = false; self.openWebTask = nil }
            do {
                let deadline = ContinuousClock.now.advanced(by: .seconds(120))
                while sessionClient == nil && (isWorking || status == .starting) && ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(100))
                }
                try Task.checkCancellation()
                guard let client = sessionClient else {
                    throw DesktopError.commandFailed("The server is not ready. Check its status in Settings and try Open AgentLand again.")
                }
                let identity = ConnectionIdentity(host: advertisedHost, deviceID: "local-mac")
                let legacy = LocalWebLegacy(projectID: preferences.string(forKey: "agentland.desktop.workspace.current." + identity.storageKey),
                    workspace: WorkspacePersistence(defaults: preferences).loadState(for: identity))
                try await client.importLocalWebLegacy(legacy)
                let url = try await client.localWebLaunch()
                try Task.checkCancellation()
                guard sessionClient === client else { throw CancellationError() }
                guard NSWorkspace.shared.open(url) else {
                    throw DesktopError.commandFailed("macOS could not open your browser. Choose a default browser, then try Open AgentLand again.")
                }
            } catch is CancellationError { }
            catch { present(error) }
        }
    }

    func stop() {
        openWebTask?.cancel()
        connectionDesired = false
        cancelOperation()
        let pending = startTask
        isWorking = true
        startTask = Task {
            await pending?.value
            do { try await stopOwnedServices() } catch { present(error) }
            await updateLifecycleStatus()
            isWorking = false
            setupProgress = nil
            if needsOnboarding { onboardingStage = .folder }
            startTask = nil
        }
    }

    func stopForApplicationTermination() async throws {
        openWebTask?.cancel()
        // Quit preserves the user's connection intent; Disconnect is the explicit opt-out.
        // The notice relay stops first and never waits more than about a second.
        await notifications.shutdown()
        cancelOperation()
        await startTask?.value
        try await stopOwnedServices()
        await updateLifecycleStatus()
        isWorking = false
        startTask = nil
        // Only once the app is sure to end: remote access removes its router mapping and closes its
        // endpoint, without a report, and cannot start again. A Quit whose stop failed is cancelled
        // and leaves it running as the switch says.
        await remoteAccess.shutdown()
    }

    // MARK: Terminals at Quit and when switched off

    /// The Quit buttons: the owner means to quit, so the app may ask about running terminals.
    func quitDeliberately() {
        deliberateQuit = true
        NSApp.terminate(nil)
    }

    /// Asks the owner what to do with running terminals before the host stops; true when the app may
    /// quit. It asks only after a deliberate Quit, and a host that does not answer within a second, has
    /// terminals off or has none running never holds Quit up. Must run before `stopForApplicationTermination`,
    /// which clears the session.
    func prepareQuit(ask: @MainActor (HostRunningCount) async -> QuitTerminalsChoice) async -> Bool {
        guard deliberateQuit, let feed = terminalsFeed else { return true }
        guard let count = try? await feed.runningCount(within: 1), count.running > 0 else { return true }
        switch await ask(count) {
        case .keepRunning:
            return true
        case .endTerminals:
            _ = try? await feed.endAll()
            return true
        case .cancel:
            deliberateQuit = false
            return false
        }
    }

    /// What turning the terminal-access switch off does first.
    enum TerminalsOffStep: Equatable {
        /// Ask before ending them: how many run, or nil when the host could not say (restarting, slow, or its
        /// terminal service unusable), which is never taken for none; and how many of those are agents typed in
        /// Terminal, which keep running there.
        case ask(Int?, routed: Int = 0)
        /// None runs, or no host serves terminals: turn off now (`turnTerminalsOffNow`).
        case turnOff
    }

    /// The switch's first step: a host serving terminals is asked how many run. None, or a host that says terminals
    /// are already off, turns off now; any other answer asks first. With no host serving terminals it just turns off.
    func terminalsOffStep() async -> TerminalsOffStep {
        guard status == .running, ownedLaunch?.request.terminal == true else { return .turnOff }
        // An unreadable count is also an unknown number of agents in Terminal: with routing on, say they keep running.
        let unknown = TerminalsOffStep.ask(nil, routed: terminalRoutingEnabled ? 1 : 0)
        guard let feed = terminalsFeed else { return unknown }
        do {
            let count = try await feed.runningCount(within: 1)
            return count.running > 0 ? .ask(count.running, routed: count.routed) : .turnOff
        } catch {
            return HostTerminalsFeed.meansTerminalsOff(error) ? .turnOff : unknown
        }
    }

    /// Ends every running terminal, then switches terminals off. When they do not all end (the host
    /// refused, timed out, or some still run), the switch stays on and the error shows; a host that says
    /// terminals are already off, or no host, just turns off. False when it did not turn off or another
    /// call is already ending them. A running host restarts with terminals off (`switchTerminalsOff`).
    @discardableResult
    func turnOffTerminals() async -> Bool {
        guard !endingTerminals else { return false }
        endingTerminals = true
        defer { endingTerminals = false }
        if let feed = terminalsFeed {
            do {
                _ = try await feed.endAll()
                let left = try await feed.runningCount(within: 5).running
                guard left == 0 else {
                    present(DesktopError.commandFailed("\(left) \(left == 1 ? "terminal is" : "terminals are") still running, so terminals stay on. Try again."))
                    return false
                }
            } catch {
                if !HostTerminalsFeed.meansTerminalsOff(error) {
                    present(error)
                    return false
                }
            }
        }
        await switchTerminalsOff()
        return true
    }

    /// Switches terminals off when none runs: the preference is saved, and a running host restarts with
    /// terminals off. The switch shows progress until it is back.
    func turnTerminalsOffNow() async {
        guard !endingTerminals else { return }
        endingTerminals = true
        defer { endingTerminals = false }
        await switchTerminalsOff()
    }

    /// Saves the switch off and applies it at once: a host this app runs with terminals on restarts with them off,
    /// OpenCode left running, so devices can open no more. Waits for that restart. With no host running only the
    /// preference changes; a host that starts with terminals off ends what its keeper still runs. A start already under
    /// way when the switch goes off is restarted by the monitor once it is up. Coding agents from Terminal pause first
    /// (`terminals hook pause`): they run in Terminal as they would without AgentLand until terminal access is back.
    private func switchTerminalsOff() async {
        // Before the switch goes off: nothing waits between it and the restart below, which the monitor would otherwise
        // start itself while the hook runs.
        // A routing change under way settles first (and may revert the switch), so the pause is for what really is on.
        await waitForTerminalRouting()
        if terminalRoutingEnabled { await enqueueHook(.pause).value }
        terminalEnabled = false
        guard !isWorking, startTask == nil, status == .running, let launch = ownedLaunch, launch.request.terminal else { return }
        restartOwnedServices(launch.withoutTerminals, runtimeExited: false, immediate: true)
        await startTask?.value
    }

    /// Turns terminal access on; a running host takes it at its next start, as before. Coding agents from Terminal that
    /// paused with it open in AgentLand again (`terminals hook on`, which runs after this returns).
    func turnTerminalsOn() {
        terminalEnabled = true
        if terminalRoutingEnabled { enqueueHook(.on) }
    }

    // MARK: Coding agents from Terminal

    /// The Terminals pane's routing switch: `terminals hook on` (or `pause` while terminal access is off) or `off`. The switch shows the
    /// new state while the command runs and goes back when it fails, with the command's words under it. A failed off
    /// never shows off: off can fail after routing already stopped, and the shell setup may still be there.
    func setTerminalRouting(_ on: Bool) async {
        let was = terminalRoutingEnabled
        terminalRoutingIssue = nil
        terminalRoutingEnabled = on
        let hook = enqueueHook(on ? (terminalEnabled ? .on : .pause) : .off)
        // Its own task, so `waitForTerminalRouting` also waits for the revert below.
        let change = Task { if await !hook.value { terminalRoutingEnabled = was } }
        routingChangeTask = change
        await change.value
    }

    /// The routing switch: off is always allowed (it removes the shell setup); on needs terminal access.
    var terminalRoutingSwitchDisabled: Bool {
        (!terminalEnabled && !terminalRoutingEnabled) || isWorking || changingTerminalRouting
    }

    func dismissTerminalRoutingIssue() { terminalRoutingIssue = nil }

    /// Waits for the hook commands asked for so far.
    func waitForTerminalRouting() async {
        _ = await hookTask?.value
        await routingChangeTask?.value
    }

    /// Runs `terminals hook <action>` off the main actor, after the one asked for before it; the task says whether it
    /// worked. A failure's words go to `terminalRoutingIssue`; one that works clears them.
    @discardableResult
    private func enqueueHook(_ action: TerminalHookAction) -> Task<Bool, Never> {
        let previous = hookTask
        let runner = runner
        let command = HostCommandBuilder.terminalHookCommand(statePath: statePath, action: action)
        hookGeneration += 1
        let generation = hookGeneration
        changingTerminalRouting = true
        let task = Task { [weak self] () -> Bool in
            _ = await previous?.value
            let result = await Task.detached { Result { try runner.run(command) } }.value
            guard let self else { return false }
            if generation == self.hookGeneration { self.changingTerminalRouting = false }
            switch result {
            case .success:
                self.terminalRoutingIssue = nil
                return true
            case let .failure(error):
                self.terminalRoutingIssue = Self.hookIssue(error)
                return false
            }
        }
        hookTask = task
        return task
    }

    /// What `terminals hook` printed when it failed (its message to stderr, without a prefix), or the error.
    static func hookIssue(_ error: any Error) -> String {
        if case let .commandFailed(message)? = error as? DesktopError {
            return redact(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return redact(error.localizedDescription)
    }

    func waitForCurrentOperation() async { await startTask?.value }

    private func cancelOperation() {
        startupID = UUID()
        restartBackoff.reset()
        providerRequestID = UUID()
        providerIsWorking = false
        startTask?.cancel()
        clearPublishedHost()
    }

    private func stopOwnedServices() async throws {
        // What stops here is no longer restarted by the monitor.
        ownedLaunch = nil
        // Attempt both shutdowns even if one fails, retaining ownership until each exits.
        var failure: Error?
        do { try await lifecycle.stop() } catch { failure = error }
        do {
            try await runtime.stop()
            managedRuntimeActive = false
            // The next start applies every setting, and says again whether OpenCode is available.
            openCodeReport = nil
            openCodeSettingsPending = false
            openCodeUnavailable = nil
        } catch { if failure == nil { failure = error } }
        if let failure { throw failure }
        managedServicePassword = nil
    }

    func refreshLifecycleStatus() {
        guard !isWorking, status != .starting else { return }
        Task { await lifecycle.refreshStatus(); await updateLifecycleStatus() }
    }

    func refreshProviders() {
        guard managedOpenCode, status == .running, !providerIsWorking else { return }
        providerRequestID = UUID()
        let id = providerRequestID
        let directory = projectDirectory
        providerIsWorking = true
        providerMessage = nil
        Task {
            do {
                guard let endpoint = await runtime.endpoint(), let password = managedServicePassword, !password.isEmpty else {
                    if providerRequestID == id { providerCatalogMessage = "OpenCode is not running." }
                    throw DesktopError.secretUnavailable
                }
                let options = try await OpenCodeProviderClient(endpoint: endpoint, password: password).providers(directory: directory)
                guard providerRequestID == id else { return }
                // Settings → AI Providers lists every one.
                providerCatalog = options
                providerCatalogMessage = nil
                // First setup supports providers with one API key/token. Complex cloud credentials
                // remain available through an explicitly configured external OpenCode service.
                providerOptions = options.filter {
                    !$0.models.isEmpty && (($0.environmentKeys.count == 1 && Self.isCredentialName($0.environmentKeys[0])) || ($0.environmentKeys.isEmpty && $0.isConnected))
                }
                if !providerOptions.contains(where: { $0.id == selectedProviderID }) {
                    selectedProviderID = providerOptions.first(where: { $0.id == "deepseek" })?.id ?? providerOptions.first?.id ?? ""
                }
                selectProvider(selectedProviderID)
                if providerOptions.isEmpty { providerMessage = "No supported providers are available. Files and terminal are ready; try refreshing later." }
            } catch {
                guard providerRequestID == id else { return }
                providerMessage = redact(error.localizedDescription)
                if !(error is DesktopError) { providerCatalogMessage = redact(error.localizedDescription) }
            }
            if providerRequestID == id { providerIsWorking = false }
        }
    }

    func selectProvider(_ id: String) {
        guard let option = providerOptions.first(where: { $0.id == id }) else { return }
        if selectedProviderID != id { selectedProviderID = id }
        if !option.models.contains(where: { $0.id == selectedModelID }) {
            selectedModelID = option.defaultModelID.flatMap { model in option.models.first(where: { $0.id == model })?.id } ?? option.models.first?.id ?? ""
        }
        providerAPIKey = ""
        providerMessage = nil
    }

    /// Saves the selected provider's key and model, then reconnects and finishes setup. Setup's provider step that
    /// called it is gone (2026-10-17: setup shows Claude Code and Codex instead; keys are Settings → API Keys (Later));
    /// only the opt-in `OnboardingIntegrationTests` call it now. `replacing` is the providers whose key saved under the
    /// same variable (`providersSharingKey`); a key saved here deletes only those.
    func saveProvider(replacing confirmed: Set<String> = []) {
        guard !isWorking, !providerIsWorking, managedOpenCode,
              let provider = providerOptions.first(where: { $0.id == selectedProviderID }),
              provider.models.contains(where: { $0.id == selectedModelID }) else { return }
        do {
            if let name = provider.environmentKeys.first {
                guard Self.isCredentialName(name) else { throw ManagedOpenCodeError.invalidProviderEnvironment }
                let value = providerAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty {
                    try storeProviderKey(value, providerID: provider.id, variable: name, replacing: confirmed)
                } else if try secrets.load(account: Self.providerAccount(provider.id)) == nil && !provider.isConnected {
                    throw DesktopError.commandFailed("Enter an API key for this provider.")
                }
            }
            savedProviderID = selectedProviderID
            savedModelID = selectedModelID
            providerAPIKey = ""
            persistPreferences()
            providerMessage = "Saved in Keychain. The provider will verify the key when you send a message."
            finishAfterConnecting = true
            connect(reconfigure: true)
        } catch { providerMessage = redact(error.localizedDescription) }
    }

    /// Setup's Claude Code and Codex step goes on to pairing; setup finishes there.
    func continueToPairing() {
        guard needsOnboarding, onboardingStage == .agents else { return }
        onboardingStage = .ready
    }

    func finishOnboarding() {
        guard status == .running, !isWorking else { return }
        onboardingComplete = true
        onboardingStage = .ready
        persistPreferences()
    }

    // MARK: Provider keys (Settings → AI Providers)

    /// The providers with a key saved in AgentLand and the variable each is given to OpenCode as. Never the keys.
    var savedProviderKeys: [String: String] { providerCredentialNames.filter { Self.isCredentialName($0.value) } }

    /// The default model of OpenCode's chats (`provider/model` in its configuration); nil leaves the choice
    /// to OpenCode.
    var defaultModel: (providerID: String, modelID: String)? {
        savedProviderID.isEmpty || savedModelID.isEmpty ? nil : (savedProviderID, savedModelID)
    }

    /// Add Key…: saves `key` for `providerID` under `variable`, its key variable (`<X>_API_KEY` or
    /// `<X>_TOKEN`), the way provider keys have always been saved (the Keychain item
    /// `provider.<id>.api-key`; the preferences keep only the variable). Saving does not check the key.
    /// OpenCode reads one value per variable, so the keys other providers saved under `variable` are
    /// deleted, and only when `replacing` holds each of them (the sheet named them and the owner
    /// confirmed); otherwise nothing is saved or deleted (`ProviderKeyError.replacedKeysChanged`).
    /// It reaches OpenCode when OpenCode restarts: at once when nothing runs on the host, otherwise as
    /// soon as nothing does (`OpenCodeRestartPolicy`).
    func saveProviderKey(_ key: String, providerID: String, variable: String, replacing confirmed: Set<String> = []) throws {
        guard managedOpenCode else { throw ProviderKeyError.externalOpenCode }
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw ProviderKeyError.empty }
        guard value.utf8.count <= 16 * 1024, !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ProviderKeyError.unusable
        }
        try storeProviderKey(value, providerID: providerID, variable: variable, replacing: confirmed)
        providerSettingsChanged()
    }

    /// The other providers with a key saved under `variable`: a key saved under it for `providerID`
    /// replaces theirs.
    func providersSharingKey(variable: String, with providerID: String) -> Set<String> {
        Set(providerCredentialNames.compactMap { $0.key != providerID && $0.value == variable ? $0.key : nil })
    }

    /// Remove Key: deletes the provider's Keychain item and its variable. OpenCode stops using the key when
    /// it restarts, by the same rule.
    func removeProviderKey(providerID: String) throws {
        try secrets.delete(account: Self.providerAccount(providerID))
        providerCredentialNames[providerID] = nil
        persistPreferences()
        providerSettingsChanged()
    }

    /// Sets the default model (nil for OpenCode's own choice); it applies when OpenCode restarts, like keys.
    func setDefaultModel(providerID: String?, modelID: String?) {
        let provider = providerID ?? "", model = modelID ?? ""
        guard provider.isEmpty == model.isEmpty, !provider.contains("/"), !"\(provider)\(model)".contains(where: \.isWhitespace),
              provider != savedProviderID || model != savedModelID else { return }
        savedProviderID = provider
        savedModelID = model
        selectedProviderID = provider
        selectedModelID = model
        persistPreferences()
        providerSettingsChanged()
    }

    /// Saves a key the way provider keys have always been saved. OpenCode reads one value per variable, so
    /// the keys other providers saved under the same variable are deleted, and only when `confirmed` holds
    /// each of them: another means the owner did not see it named, and nothing is saved or deleted.
    private func storeProviderKey(_ value: String, providerID: String, variable: String, replacing confirmed: Set<String>) throws {
        guard Self.isCredentialName(variable), !providerID.isEmpty, providerID.utf8.count <= 128,
              !providerID.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) else {
            throw ManagedOpenCodeError.invalidProviderEnvironment
        }
        let replaced = providersSharingKey(variable: variable, with: providerID)
        guard replaced.isSubset(of: confirmed) else { throw ProviderKeyError.replacedKeysChanged(variable) }
        try secrets.save(value, account: Self.providerAccount(providerID))
        for other in replaced {
            try? secrets.delete(account: Self.providerAccount(other))
            providerCredentialNames[other] = nil
        }
        providerCredentialNames[providerID] = variable
        persistPreferences()
    }

    /// Keys or the default model changed: they wait for OpenCode's next restart while it runs (checked
    /// at once), and the next start applies them otherwise.
    private func providerSettingsChanged() {
        settingsGeneration &+= 1
        openCodeSettingsPending = managedRuntimeActive && settingsGeneration != appliedSettings
        if openCodeSettingsPending { considerOpenCodeRestartSoon() }
    }

    /// Every provider key saved in AgentLand, for OpenCode's environment: one value per variable (the
    /// default model's provider first, then by provider ID), and only variables AgentLand may set.
    private func providerEnvironment() throws -> [String: String] {
        var environment: [String: String] = [:]
        let order = providerCredentialNames.keys.sorted { ($0 == savedProviderID ? 0 : 1, $0) < ($1 == savedProviderID ? 0 : 1, $1) }
        for id in order {
            guard let name = providerCredentialNames[id], Self.isCredentialName(name), environment[name] == nil,
                  let secret = try secrets.load(account: Self.providerAccount(id)), !secret.isEmpty else { continue }
            environment[name] = secret
        }
        return environment
    }
    private func savedModel() -> String? {
        savedProviderID.isEmpty || savedModelID.isEmpty ? nil : "\(savedProviderID)/\(savedModelID)"
    }
    private static func providerAccount(_ id: String) -> String { "provider.\(id).api-key" }
    private static func isCredentialName(_ name: String) -> Bool {
        ManagedOpenCodeRuntime.supportsProviderEnvironmentKey(name)
    }

    private func adapterPassword(managed: Bool) throws -> String {
        if !managed { return try passwordForSave() }
        if let password = managedServicePassword, !password.isEmpty { return password }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw DesktopError.commandFailed("macOS could not create a secure connection credential. Try again.")
        }
        let value = Data(bytes).base64EncodedString()
        managedServicePassword = value
        return value
    }

    private func certificateIdentity(request: ConnectionRequest, id: UUID) async throws -> (certificate: String, key: String) {
        if request.mode == .developmentHTTP { return ("", "") }
        if !request.certificate.isEmpty || !request.key.isEmpty {
            guard !request.certificate.isEmpty, !request.key.isEmpty else {
                throw DesktopError.commandFailed("The saved connection identity is incomplete. Restore its certificate and key in Settings.")
            }
            return (request.certificate, request.key)
        }
        guard request.managed else { throw DesktopError.commandFailed("Choose a certificate and private key in Settings.") }
        let directory = URL(fileURLWithPath: statePath).deletingLastPathComponent()
            .appendingPathComponent("certificates/\(UUID().uuidString)")
        let command = try HostCommandBuilder.tlsInitializeCommand(directory: directory.path, hosts: [request.hostname])
        let output = try await execute(command, id: id)
        let identity = try HostOutputParser.generatedCertificate(output.standardOutput)
        certificatePath = identity.certificateFile
        keyPath = identity.keyFile
        certificateFingerprint = identity.fingerprint
        return (identity.certificateFile, identity.keyFile)
    }

    private func execute(_ command: HostCommand, id: UUID) async throws -> CommandOutput {
        try checkOperation(id)
        let runner = runner
        let output = try await Task.detached { try runner.run(command) }.value
        try checkOperation(id)
        return output
    }
    private func checkOperation(_ id: UUID) throws {
        try Task.checkCancellation()
        if startupID != id { throw CancellationError() }
    }
    private static func validateWorkspace(_ path: String) throws {
        var directory: ObjCBool = false
        guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path, isDirectory: &directory), directory.boolValue,
              FileManager.default.isReadableFile(atPath: path), FileManager.default.isWritableFile(atPath: path) else {
            throw DesktopError.commandFailed("Choose a folder this Mac can read and write.")
        }
    }
    private static func availableInitialListener(preferred: String) throws -> String {
        guard preferred == "0.0.0.0:9841" else { return preferred }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DesktopError.commandFailed("macOS could not open a local connection.") }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(9841).bigEndian
        func bindAddress() -> Int32 {
            withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        }
        if bindAddress() == 0 { return preferred }
        guard errno == EADDRINUSE else { throw DesktopError.commandFailed("macOS could not open the local connection (\(errno)).") }
        address.sin_port = 0
        guard bindAddress() == 0 else { throw DesktopError.commandFailed("No local connection port is available.") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let found = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        guard found == 0 else { throw DesktopError.commandFailed("macOS could not determine the local port.") }
        return "0.0.0.0:\(UInt16(bigEndian: address.sin_port))"
    }

    func createPairingCode() {
        guard !isWorking else { return }
        guard status == .running, activeAdvertisement != nil else {
            present(DesktopError.commandFailed("Start a reachable HTTPS host before pairing a device.")); return
        }
        clearPairing()
        let requestID = pairingID
        let requestedAt = Date()
        begin(pairing: true)
        pairingRequest = requestID
        lastPairingAttempt = requestedAt
        runPairingCommand(requestID: requestID, requestedAt: requestedAt)
    }

    private func runPairingCommand(requestID: UUID, requestedAt: Date) {
        let runner = runner
        let command = HostCommandBuilder.pairingCommand(statePath: statePath, securePIN: true)
        Task.detached { [weak self, runner, command, requestID, requestedAt] in
            let result = Result { try runner.run(command).standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) }
            await self?.finishPairing(result, requestID: requestID, requestedAt: requestedAt)
        }
    }

    /// While a pairing QR code shows (QR-only pairing, 2026-10-16): makes its first code, and a new one
    /// `pairingRenewalLead` before the current one expires, which stays on screen meanwhile, so the QR never goes
    /// blank. Each code stays single use and expiring on the host; an older one still works until it expires.
    /// A failed attempt is tried again after `pairingRetryPause`. Never while other work runs.
    func keepPairingCodeFresh(now: Date = Date()) {
        guard status == .running, activeAdvertisement != nil, !isWorking, pairingRequest == nil else { return }
        if let invitation = validInvitation, invitation.expiresAt.timeIntervalSince(now) > Self.pairingRenewalLead { return }
        if let last = lastPairingAttempt, now.timeIntervalSince(last) < Self.pairingRetryPause { return }
        pairingID = UUID()
        let requestID = pairingID
        pairingRequest = requestID
        lastPairingAttempt = now
        runPairingCommand(requestID: requestID, requestedAt: now)
    }

    /// How long before a showing code expires the next is made, and how soon a failed attempt is tried again.
    static let pairingRenewalLead: TimeInterval = 30
    static let pairingRetryPause: TimeInterval = 10

    /// Reads the devices now, quietly (no activity, no error shown), and publishes them; nil when the read failed.
    /// The pairing QR reads them every 2 s while it shows, to see a device pair.
    func readDevices() async -> [ManagedDevice]? {
        guard hasState else { return nil }
        let runner = runner
        let command = HostCommandBuilder.devicesCommand(statePath: statePath)
        let result = await Task.detached { Result { HostOutputParser.devices(try runner.run(command).standardOutput) } }.value
        guard case let .success(devices) = result else { return nil }
        self.devices = devices
        return devices
    }

    var validInvitation: PairingInvitation? {
        guard status == .running, let pairingInvitation,
              pairingInvitation.expiresAt > Date() else { return nil }
        return pairingInvitation
    }

    func refreshDevices(showActivity: Bool = true) {
        guard hasState else { return }
        if showActivity { begin() }
        let runner = runner
        let command = HostCommandBuilder.devicesCommand(statePath: statePath)
        Task.detached { [weak self, runner, command] in
            let result = Result { HostOutputParser.devices(try runner.run(command).standardOutput) }
            await self?.finishDevices(result, clearActivity: showActivity)
        }
    }

    /// Removes the device. With `endingTerminals` the host ends and forgets its terminals first.
    func revoke(_ device: ManagedDevice, endingTerminals: Bool) {
        begin()
        let runner = runner
        let command = HostCommandBuilder.revokeCommand(statePath: statePath, deviceID: device.id)
        let feed = endingTerminals ? terminalsFeed : nil
        revokeNotice = nil
        Task.detached { [weak self, runner, command, feed] in
            var endFailure: String?
            if endingTerminals {
                if let feed {
                    do { _ = try await feed.endDevice(device.id) } catch { endFailure = error.localizedDescription }
                } else {
                    endFailure = "AgentLand isn’t running"
                }
            }
            let result = Result { try runner.run(command) }
            await self?.finishRevoking(result, endFailure: endFailure)
        }
    }

    // MARK: Terminals pane

    /// Reads the terminals now and every `terminalsPollInterval` until the task is cancelled (the pane closed) or the
    /// host stops. A failing read shows in the pane and is tried again at the same pace.
    func followTerminals() async {
        terminalActionError = nil
        while !Task.isCancelled {
            await refreshTerminals()
            do { try await Task.sleep(for: terminalsPollInterval) } catch { return }
        }
    }

    /// What the Terminals pane runs while it shows, for its list and the routing switch's older-keeper note: the
    /// terminals follow, after dropping a list left from an earlier visit so a stale one never shows a note. Panes show
    /// one at a time, so only one follow runs; the task ends with the pane.
    func followRoutingKeeper() async {
        terminalList = nil
        await followTerminals()
    }

    private func refreshTerminals() async {
        guard let feed = terminalsFeed else {
            terminalList = nil; terminalsOff = false; terminalsIssue = nil
            return
        }
        do {
            let list = try await feed.list()
            guard terminalsFeed != nil else { return }
            terminalList = list; terminalsOff = false; terminalsIssue = nil
        } catch {
            if Task.isCancelled { return }
            if HostTerminalsFeed.meansTerminalsOff(error) {
                terminalList = nil; terminalsOff = true; terminalsIssue = nil
            } else {
                terminalsIssue = redact(error.localizedDescription)
            }
        }
    }

    func endTerminal(_ id: String) async {
        await act { try await $0.end(terminalID: id) }
    }

    func clearTerminal(_ id: String) async {
        await act { try await $0.clear(terminalID: id) }
    }

    func dismissTerminalActionError() { terminalActionError = nil }

    /// Open in Terminal: a Terminal window attached to the running terminal (`terminals attach`, this app's host and
    /// state). A failure shows with the pane's other action errors.
    /// Where Open in Terminal writes its `.command` files and clears stale ones; a test points it at a folder of its own.
    var terminalAttachFolder = TerminalWindowOpener.folder

    func openInTerminal(_ id: String) async {
        do {
            try await TerminalWindowOpener.open(terminalID: id, binary: HostBinaryLocator.defaultURL(), statePath: statePath,
                                                in: terminalAttachFolder)
            terminalActionError = nil
        } catch {
            terminalActionErrorTitle = TerminalsText.openFailedTitle
            terminalActionError = TerminalsText.openFailed(redact(error.localizedDescription))
        }
    }

    private func act(_ action: (any HostTerminalsReading) async throws -> Void) async {
        if let feed = terminalsFeed {
            do { try await action(feed); terminalActionError = nil } catch { terminalActionErrorTitle = TerminalsText.actionFailedTitle; terminalActionError = redact(error.localizedDescription) }
        }
        await refreshTerminals()
    }

    /// How many terminals started from the device still run; 0 when the host cannot say.
    func runningTerminals(forDevice id: String) async -> Int {
        guard let list = try? await terminalsFeed?.list() else { return 0 }
        return list.terminals.filter { $0.deviceId == id && $0.status == "running" }.count
    }

    func chooseProjectDirectory() { chooseFile(directoryOnly: true) { self.projectDirectory = $0; if self.projectName.isEmpty { self.projectName = URL(fileURLWithPath: $0).lastPathComponent } } }
    func chooseCertificate() { chooseFile(directoryOnly: false) { self.certificatePath = $0 } }
    func chooseKey() { chooseFile(directoryOnly: false) { self.keyPath = $0 } }

    func generateCertificate() {
        do {
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appending(path: "AgentLand/certificates/\(UUID().uuidString)").path
            let command = try HostCommandBuilder.tlsInitializeCommand(directory: directory, hosts: [advertisedHost])
            begin()
            let runner = runner
            Task.detached { [weak self, runner, command] in
                let result = Result { try HostOutputParser.generatedCertificate(runner.run(command).standardOutput) }
                await self?.finishCertificateGeneration(result)
            }
        } catch {
            present(error)
        }
    }

    private func chooseFile(directoryOnly: Bool, set: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = directoryOnly
        panel.canChooseFiles = !directoryOnly
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        if directoryOnly {
            let suggested = projectDirectory.isEmpty
                ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Developer")
                : URL(fileURLWithPath: projectDirectory)
            if FileManager.default.fileExists(atPath: suggested.path) { panel.directoryURL = suggested }
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            if response == .OK, let url = panel.url { set(url.path) }
        }
    }

    private func currentProject() throws -> ProjectConfiguration {
        try Self.validateWorkspace(projectDirectory)
        return ProjectConfiguration(id: projectID, name: projectName, directory: projectDirectory)
    }

    private func passwordForSave() throws -> String {
        if !openCodePassword.isEmpty { return openCodePassword }
        guard let saved = try secrets.load(account: passwordAccount), !saved.isEmpty else { throw DesktopError.secretUnavailable }
        return saved
    }

    private func begin(pairing: Bool = false) {
        errorMessage = nil
        isWorking = true
        workKind = pairing ? .pairing : .other
    }
    private func present(_ error: Error) {
        errorMessage = redact(error.localizedDescription)
        isWorking = false
        workKind = nil
    }

    func presentTerminationError(_ error: Error) { present(error) }

    private func persistPreferences() {
        guard !isRestoringPreferences else { return }
        let saved = DesktopPreferences(
            projectDirectory: projectDirectory, projectName: projectName, projectID: projectID, openCodeURL: openCodeURL,
            listenAddress: listenAddress, terminalEnabled: terminalEnabled, terminalRouting: terminalRoutingEnabled,
            connectionMode: connectionMode,
            certificatePath: certificatePath, keyPath: keyPath, advertisedHost: advertisedHost,
            certificateFingerprint: certificateFingerprint, managedOpenCode: managedOpenCode,
            connectionDesired: connectionDesired, onboardingComplete: onboardingComplete,
            providerID: savedProviderID, modelID: savedModelID, providerCredentialNames: providerCredentialNames
        )
        if let data = try? JSONEncoder().encode(saved) { preferences.set(data, forKey: DesktopPreferences.storageKey) }
    }

    private static func readPreferences(from defaults: UserDefaults) -> DesktopPreferences? {
        guard let data = defaults.data(forKey: DesktopPreferences.storageKey) else { return nil }
        return try? JSONDecoder().decode(DesktopPreferences.self, from: data)
    }

    private func applyConfiguration(_ result: Result<HostConfiguration, Error>) {
        defer { isWorking = false }
        switch result {
        case let .success(configuration):
            self.configuration = configuration
            if let project = configuration.projects.first(where: { $0.id == projectID }) ?? configuration.projects.first {
                projectID = project.id; projectName = project.name; projectDirectory = project.directory
            }
            openCodeURL = configuration.openCodeURL
        case let .failure(error): present(error)
        }
    }

    private func finishSaving(_ result: Result<CommandOutput, Error>) {
        switch result {
        case .success: reloadConfiguration()
        case let .failure(error): present(error)
        }
    }

    private func finishPairing(_ result: Result<String, Error>, requestID: UUID, requestedAt: Date) {
        if pairingRequest == requestID { pairingRequest = nil }
        guard pairingID == requestID, status == .running, let activeAdvertisement else { return }
        defer {
            if workKind == .pairing { isWorking = false; workKind = nil }
        }
        switch result {
        case let .success(code) where !code.isEmpty:
            do {
                showPairing(try Self.invitation(advertisement: activeAdvertisement, code: code, requestedAt: requestedAt,
                                                routes: advertisedRoutes, remoteAccess: advertisedRemoteAccess))
            } catch { errorMessage = redact(error.localizedDescription) }
        case .success: errorMessage = DesktopError.commandFailed("The host did not return a pairing code.").localizedDescription
        case let .failure(error): errorMessage = redact(error.localizedDescription)
        }
    }

    /// Shows `invitation`'s QR code and PIN until it expires, another is made or the host stops. While it
    /// is valid, OpenCode is not restarted on its own.
    func showPairing(_ invitation: PairingInvitation) {
        pairingInvitation = invitation
        pairingCode = invitation.code
    }

    /// The QR invitation: it carries the host's routes, so a device learns the Tailscale name as it pairs,
    /// and `remoteAccess` version 1 when the host takes node IDs, so a device gives its node ID with its
    /// proof as it pairs (docs/HOST-API.md "Pairing with a node ID").
    static func invitation(advertisement: HostAdvertisement, code: String, requestedAt: Date, routes: [HostRoute]?,
                           remoteAccess: Bool) throws -> PairingInvitation {
        let pairingRoutes = (routes ?? []).compactMap {
            try? PairingRoute(kind: $0.kind, host: $0.host, addresses: $0.addresses, port: $0.port)
        }
        return try PairingInvitation(advertisement: advertisement, code: code, expiresAt: requestedAt.addingTimeInterval(600),
                                     routes: Array(pairingRoutes.prefix(PairingRoute.maximumRoutes)),
                                     remoteAccess: remoteAccess ? PairingRemoteAccess() : nil)
    }

    private func finishDevices(_ result: Result<[ManagedDevice], Error>, clearActivity: Bool) {
        if clearActivity { isWorking = false }
        switch result {
        case let .success(devices): self.devices = devices
        case let .failure(error): errorMessage = redact(error.localizedDescription)
        }
    }

    private func finishRevoking(_ result: Result<CommandOutput, Error>, endFailure: String? = nil) {
        switch result {
        case .success:
            if let endFailure {
                revokeNotice = redact("The device was removed, but its terminals couldn’t be ended: \(endFailure). End them in Settings → Terminals.")
            }
            refreshDevices()
        case let .failure(error): present(error)
        }
    }

    private func finishCertificateGeneration(_ result: Result<GeneratedCertificate, Error>) {
        defer { isWorking = false }
        switch result {
        case let .success(certificate):
            certificatePath = certificate.certificateFile
            keyPath = certificate.keyFile
            certificateFingerprint = certificate.fingerprint
            connectionMode = .trustedHTTPS
        case let .failure(error): present(error)
        }
    }

    private func updateLifecycleStatus() async {
        let current = await lifecycle.currentStatus
        if current == .stopped { clearPublishedHost() }
        status = current
    }

    private func clearPairing() {
        pairingID = UUID()
        pairingRequest = nil
        pairingCode = nil
        pairingInvitation = nil
        if workKind == .pairing { isWorking = false; workKind = nil }
    }

    /// Reads the running host's routes now and every minute while this session lasts (the host reads
    /// Tailscale's status every five). A failed read keeps what was read before.
    private func followRoutes(_ client: APIClient) {
        routesTask?.cancel()
        routesTask = Task { [weak self] in
            while !Task.isCancelled {
                let answer = try? await client.capabilities()
                guard let self, !Task.isCancelled, self.sessionClient === client else { return }
                if let answer { self.noteCapabilities(answer) }
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    /// What the Mac keeps of the running host's capabilities: its routes, what it read of Tailscale, and
    /// whether it takes node IDs at pairing.
    func noteCapabilities(_ answer: CapabilitiesResponse) {
        advertisedRoutes = answer.routes
        advertisedTailscale = answer.tailscale
        advertisedRemoteAccess = answer.supportsRemoteAccess
    }

    // MARK: OpenCode restarts on their own

    /// Reads the host's agent catalog every `agentsPollInterval` while this session lasts, and restarts
    /// OpenCode and the host when `OpenCodeRestartPolicy` says so.
    private func followAgents(_ feed: any HostAgentsReading) {
        agentsTask?.cancel()
        agentsFeed = feed
        let interval = agentsPollInterval
        agentsTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                guard let self, !Task.isCancelled else { return }
                await self.considerOpenCodeRestart()
            }
        }
    }

    /// Asks the host how long nothing has run and restarts OpenCode and the host when a restart applies
    /// something now (`OpenCodeRestartPolicy`: changed settings as soon as nothing runs, a new OpenCode
    /// after 10 idle minutes): the way a child that exited is restarted, in the workspace the host lists
    /// now. Nothing happens while another operation runs or a pairing code is shown (a restart clears it,
    /// perhaps while a phone scans it; the next poll asks again), and an answer that arrives after the
    /// host restarted or stopped is dropped.
    private func considerOpenCodeRestart() async {
        guard !openCodeCheckRunning, let feed = agentsFeed, ownedLaunch?.request.managed == true, connectionDesired,
              status == .running, !isWorking, startTask == nil else { return }
        let operation = startupID
        openCodeCheckRunning = true
        defer { openCodeCheckRunning = false }
        let entry: HostAgentStatus?
        do {
            entry = try await feed.agents().openCode
        } catch {
            guard startupID == operation else { return }
            // A host without the catalog (an older one, or one started with `--no-agents`) says nothing
            // about being idle; other failures are tried again.
            if HostAgentsFeed.meansNoCatalog(error) { hostReportsIdle = false }
            return
        }
        guard startupID == operation, agentsFeed != nil else { return }
        hostReportsIdle = entry?.idleForSeconds != nil
        guard validInvitation == nil else { return }
        let binaryChanges = OpenCodeRestartPolicy.shouldCheckBinary(entry, settingsPending: openCodeSettingsPending)
            ? await runtime.restartWouldChangeBinary() : false
        guard startupID == operation, let launch = ownedLaunch, launch.request.managed, connectionDesired,
              status == .running, !isWorking, startTask == nil, validInvitation == nil else { return }
        guard case let .restart(reasons) = OpenCodeRestartPolicy.decide(entry: entry, settingsPending: openCodeSettingsPending,
                                                                         binaryWouldChange: binaryChanges) else { return }
        restartOwnedServices(launch, runtimeExited: true,
                             planned: PlannedRestart(reasons: reasons, idleSeconds: entry?.idleForSeconds ?? 0))
    }

    /// Checks at once rather than at the next poll (a key or the default model just changed).
    private func considerOpenCodeRestartSoon() {
        guard agentsFeed != nil else { return }
        Task { [weak self] in await self?.considerOpenCodeRestart() }
    }

    /// Records a restart the idle rule made, for Settings → AI Providers.
    private func noteRestart(_ planned: PlannedRestart) {
        let time = Date().formatted(date: .omitted, time: .shortened)
        // Changed settings restart as soon as nothing runs, so the quiet time may be under a minute.
        let minutes = Int(planned.idleSeconds / 60)
        let quiet = minutes < 1 ? " while nothing was running."
            : ", after \(minutes == 1 ? "1 minute" : "\(minutes) minutes") with nothing running."
        var why: [String] = []
        if planned.reasons.contains(.update) {
            // A new OpenCode that did not start leaves the previous version running; the report says why.
            if let report = openCodeReport, case .managed = report.source {
                why.append("run OpenCode \(report.version) from the host")
            } else {
                why.append("try the host's new OpenCode")
            }
        }
        if planned.reasons.contains(.settings) { why.append("apply changed provider settings") }
        openCodeActivity = "Restarted OpenCode at \(time) to \(why.joined(separator: " and "))\(quiet)"
    }

    private func clearPublishedHost() {
        routesTask?.cancel()
        routesTask = nil
        agentsTask?.cancel()
        agentsTask = nil
        failureReportTask?.cancel()
        failureReportTask = nil
        agentsFeed = nil
        terminalsFeed = nil
        terminalList = nil; terminalsOff = false; terminalsIssue = nil; terminalActionError = nil
        hostReportsIdle = nil
        advertisedRoutes = nil
        advertisedTailscale = nil
        advertisedRemoteAccess = false
        sessionClient = nil
        notifications.hostStopped()
        remoteAccess.hostStopped()
        terminalNaming.hostStopped()
        discovery.stop()
        activeAdvertisement = nil
        activeListenAddress = nil
        clearPairing()
    }
}

/// Why Add Key… did not save.
enum ProviderKeyError: LocalizedError, Equatable {
    case externalOpenCode
    case empty
    case unusable
    /// Saving would delete a key another provider saved under this variable that the owner did not see named.
    case replacedKeysChanged(String)

    var errorDescription: String? {
        switch self {
        case .externalOpenCode: "Keys here are for the OpenCode that AgentLand runs. Turn on “Manage OpenCode automatically” in Advanced to use them."
        case .empty: "Enter the key."
        case .unusable: "OpenCode can't take this key from its environment: it has line breaks or other control characters, or is longer than 16 KB."
        case let .replacedKeysChanged(variable): "The keys saved as \(variable) changed. Check which ones this key replaces, then save again."
        }
    }
}

private struct DesktopPreferences: Codable {
    static let storageKey = "dev.agentland.desktop.preferences.v1"
    let projectDirectory: String
    let projectName: String
    let projectID: String
    let openCodeURL: String
    let listenAddress: String
    let terminalEnabled: Bool
    /// Coding agents from Terminal; nil in preferences saved before the switch.
    let terminalRouting: Bool?
    let connectionMode: HostController.ConnectionMode
    let certificatePath: String
    let keyPath: String
    let advertisedHost: String
    let certificateFingerprint: String?
    // Optional fields preserve preferences written before automatic setup existed.
    let managedOpenCode: Bool?
    let connectionDesired: Bool?
    let onboardingComplete: Bool?
    let providerID: String?
    let modelID: String?
    let providerCredentialNames: [String: String]?
}

private struct ConnectionRequest {
    let project: ProjectConfiguration
    let managed: Bool
    let mode: HostController.ConnectionMode
    let certificate: String
    let key: String
    let hostname: String
    let listener: String
    let terminal: Bool
    let externalURL: String

    func with(project: ProjectConfiguration, certificate: String, key: String) -> ConnectionRequest {
        ConnectionRequest(project: project, managed: managed, mode: mode, certificate: certificate, key: key,
                          hostname: hostname, listener: listener, terminal: terminal, externalURL: externalURL)
    }

    /// The same connection with terminal access off.
    var withoutTerminals: ConnectionRequest {
        ConnectionRequest(project: project, managed: managed, mode: mode, certificate: certificate, key: key,
                          hostname: hostname, listener: listener, terminal: false, externalURL: externalURL)
    }
}

/// A started connection: the request with the certificate it used, the environment variable the host reads
/// the OpenCode password from, and whether the managed OpenCode started with it (none was available when it
/// did not; the host then runs without it and nothing restarts for it on its own).
private struct OwnedLaunch {
    let request: ConnectionRequest
    let passwordEnvironment: String
    let openCodeRuns: Bool

    /// The same launch with terminal access off.
    var withoutTerminals: OwnedLaunch {
        OwnedLaunch(request: request.withoutTerminals, passwordEnvironment: passwordEnvironment, openCodeRuns: openCodeRuns)
    }
}

/// A restart of OpenCode and the host that the idle rule asked for: why, and how long the host had been idle.
private struct PlannedRestart {
    let reasons: Set<OpenCodeRestartPolicy.Reason>
    let idleSeconds: Double
}
