import Foundation
import AgentLandCore
import AgentLandChat
import AgentLandArchive

/// Names chats with this device's own language model (Apple Intelligence, through a `ChatNamer`) for
/// hosts that take names (`title` in `chatFeatures`), and sends each name with `POST /v1/chat/title`. It
/// names:
/// - a chat this device streams, when a turn finishes there (`turn.finished`);
/// - when the app comes to the foreground, once this device's copy of the archive has caught up: its
///   chats active in the last 7 days whose title describes an older message than their newest, unless a
///   device already named them for that message.
///
/// One name at a time, the model at utility priority; at most 20 per foreground period; never in Low
/// Power Mode, while the app is locked or in the background, or without Apple Intelligence. Naming is best
/// effort: a failure is dropped without a notice and waits for the next trigger, and a stale answer
/// (`title_stale`) is taken as the host's current title.
@MainActor public final class ChatNaming {
    /// Names made at most in one foreground period.
    public static let foregroundLimit = 20
    /// Chats active this recently are named when the app comes to the foreground.
    public static let recentWindow: TimeInterval = 7 * 24 * 60 * 60
    /// How many of a chat's newest messages the foreground pass reads from the copy.
    static let messagesRead = 40

    weak var workspace: WorkspaceModel?
    /// The model. Tests give a fake. UI-test runs name nothing on the device unless launched with
    /// `-AgentLandUITestsChatNaming`, so their chats keep the host's names, which do not depend on a model.
    public var namer: any ChatNamer = ChatNaming.appNamer()

    static let uiTestsChatNamingArgument = "-AgentLandUITestsChatNaming"

    /// Apple's on-device model; in UI-test runs (`workspaceUITestHooks`) a namer that is never available,
    /// unless the run asks for naming.
    static func appNamer(uiTestHooks: Bool = workspaceUITestHooks,
                         arguments: [String] = ProcessInfo.processInfo.arguments) -> any ChatNamer {
        if uiTestHooks && !arguments.contains(uiTestsChatNamingArgument) {
            return FoundationModelsChatNamer(isAvailable: { false })
        }
        return FoundationModelsChatNamer()
    }
    /// Whether Low Power Mode is on. Tests give their own.
    public var lowPowerMode: @MainActor () -> Bool = { ProcessInfo.processInfo.isLowPowerModeEnabled }
    /// The time "the last 7 days" end at. Tests give their own.
    public var now: @MainActor () -> Date = { Date() }

    /// The app is in the foreground: its scene is active (the Mac: the app is active).
    public private(set) var inForeground = false
    /// Times the model ran in this foreground period.
    public private(set) var namesThisPeriod = 0

    struct Job {
        let hostID: String
        let client: APIClient
        let projectID: String
        let chatID: String
        let input: ChatNamingInput
    }

    private enum ModelResult: Sendable {
        case unavailable
        case answered(String?)
    }

    private var queue: [Job] = []
    private var worker: Task<Void, Never>?
    private var workerGeneration = -1
    private var modelTask: Task<ModelResult, Never>?
    private var passTask: Task<Void, Never>?
    /// The foreground pass ran for this period and host.
    private var passDone = false
    /// Changes whenever work stops (the background, the lock, another host): older work drops its results.
    private var generation = 0

    public init() {}

    // MARK: Triggers

    /// The app came to the foreground: a new period, with its own 20 names and one foreground pass.
    /// Repeating it while in the foreground changes nothing.
    public func foregroundBegan() {
        guard !inForeground else { return }
        inForeground = true
        namesThisPeriod = 0
        passDone = false
        if workspace?.archive?.status?.phase == .upToDate { archiveCaughtUp() }
    }

    /// The app went to the background: work stops at once and nothing is named until it comes back.
    public func backgroundBegan() {
        inForeground = false
        stop()
    }

    /// Stops the work under way and drops what waits (the lock covered the workspace).
    public func stop() {
        generation += 1
        queue.removeAll()
        worker?.cancel()
        modelTask?.cancel()
        passTask?.cancel()
    }

    /// Another host, or none: its chats get their own foreground pass.
    func hostChanged() {
        stop()
        passDone = false
    }

    /// A turn finished in `store`'s chat, which streams on this device: the chat is named for its newest
    /// exchange, unless a device already named it for that message.
    func turnFinished(in store: ChatSessionStore) {
        guard canName, let workspace, let hostID = workspace.hostID, let client = workspace.client,
              store.identity.hostID == hostID, let input = ChatNamingInput.latest(in: store.state.messages) else { return }
        if store.info?.titleSource == .device, store.info?.titleBasis == input.newestMessageID { return }
        enqueue(Job(hostID: hostID, client: client, projectID: store.identity.projectID, chatID: store.identity.sessionID, input: input))
    }

    /// This device's copy caught up with the host. The first time in a foreground period, its recent chats
    /// whose title is behind are named.
    func archiveCaughtUp() {
        guard !passDone, canName, workspace?.archive != nil else { return }
        passDone = true
        passTask = Task { [weak self] in await self?.foregroundPass() }
    }

    // MARK: Conditions

    /// In the foreground, unlocked, with the host reachable and taking names, and not in Low Power Mode.
    private var canName: Bool {
        guard inForeground, let workspace, !workspace.locked, workspace.reachable,
              workspace.capabilities?.supports(.title) == true else { return false }
        return !lowPowerMode()
    }

    /// Still the host and connection `job` was made for, and naming may go on.
    private func allowed(_ job: Job, generation: Int) -> Bool {
        generation == self.generation && canName && workspace?.hostID == job.hostID && workspace?.client === job.client
    }

    // MARK: The foreground pass

    private func foregroundPass() async {
        guard let workspace, let archive = workspace.archive, let hostID = workspace.hostID, let client = workspace.client else { return }
        let generation = self.generation
        let namer = self.namer
        // Without Apple Intelligence nothing is read from the host or the copy.
        guard await Task.detached(priority: .utility, operation: { namer.isAvailable }).value else { return }
        func current() -> Bool {
            generation == self.generation && canName && self.workspace?.hostID == hostID && self.workspace?.client === client
        }
        guard current(), let chats = try? await archive.store.chats(ArchiveChatFilter(from: now().addingTimeInterval(-Self.recentWindow), limit: 200)) else { return }
        var listed: [String: [String: Session]] = [:]
        var jobs: [Job] = []
        for chat in chats {
            guard current(), namesThisPeriod + jobs.count < Self.foregroundLimit else { break }
            if listed[chat.projectID] == nil {
                let sessions = (try? await client.sessions(projectID: chat.projectID)) ?? []
                listed[chat.projectID] = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            }
            guard let session = listed[chat.projectID]?[chat.id],
                  let messages = try? await archive.store.messages(chatID: chat.id, limit: Self.messagesRead).messages.map(\.message),
                  let input = ChatNamingInput.latest(in: messages),
                  await needsName(session, input: input, newestOrder: messages.last?.ord, store: archive.store) else { continue }
            jobs.append(Job(hostID: hostID, client: client, projectID: chat.projectID, chatID: chat.id, input: input))
        }
        guard current() else { return }
        for job in jobs { enqueue(job) }
    }

    /// Whether `session`'s title describes an older message than `input`'s newest, and no device named it
    /// for that one. A title for a message this copy lacks is newer than the copy: it is left alone.
    private func needsName(_ session: Session, input: ChatNamingInput, newestOrder: Int64?, store: ArchiveStore) async -> Bool {
        let newest = input.newestMessageID
        if session.titleSource == .device, session.titleBasis == newest { return false }
        guard let basis = session.titleBasis else { return true }
        guard basis != newest, let newestOrder,
              let basisOrder = try? await store.messageOrder(chatID: session.id, messageID: basis) else { return false }
        return basisOrder <= newestOrder
    }

    // MARK: One name at a time

    private func enqueue(_ job: Job) {
        // A chat waits once, with its newest exchange.
        queue.removeAll { $0.chatID == job.chatID && $0.hostID == job.hostID }
        queue.append(job)
        guard worker == nil || workerGeneration != generation else { return }
        let generation = self.generation
        workerGeneration = generation
        worker = Task { [weak self] in
            while let self, self.generation == generation, !self.queue.isEmpty {
                let job = self.queue.removeFirst()
                await self.name(job, generation: generation)
            }
            if let self, self.workerGeneration == generation { self.worker = nil }
        }
    }

    private func name(_ job: Job, generation: Int) async {
        guard allowed(job, generation: generation), namesThisPeriod < Self.foregroundLimit else { return }
        let namer = self.namer
        let input = job.input
        let model = Task.detached(priority: .utility) { () -> ModelResult in
            guard namer.isAvailable else { return .unavailable }
            return .answered(await namer.name(for: input))
        }
        modelTask = model
        let result = await model.value
        if modelTask == model { modelTask = nil }
        guard case let .answered(raw) = result else { return }
        namesThisPeriod += 1
        guard allowed(job, generation: generation), let raw, let title = ChatNameRules.clean(raw) else { return }
        // Another device may have named the chat for this message meanwhile; its stream says so.
        if let info = openStore(job.chatID)?.info, info.titleSource == .device, info.titleBasis == input.newestMessageID { return }
        let outcome = await job.client.nameChat(projectID: job.projectID, sessionID: job.chatID, title: title, basedOn: input.newestMessageID)
        guard generation == self.generation, workspace?.hostID == job.hostID, workspace?.client === job.client else { return }
        switch outcome {
        case let .named(answer), let .stale(answer?):
            workspace?.chatTitleAnswered(chatID: job.chatID, answer)
        case .stale(nil), .failed, .uncertain:
            // Best effort: nothing is said, and nothing is sent again before the next trigger.
            break
        }
    }

    private func openStore(_ chatID: String) -> ChatSessionStore? {
        guard let workspace, let tab = workspace.chatTab(sessionID: chatID) else { return nil }
        return workspace.existingChatStore(tab.id)
    }

    /// Waits for the work started so far (tests).
    func settle() async {
        await passTask?.value
        await worker?.value
    }
}
