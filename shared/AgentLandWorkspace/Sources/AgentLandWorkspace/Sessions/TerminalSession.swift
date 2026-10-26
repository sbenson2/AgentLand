import Foundation
import Observation
import AgentLandCore
#if os(iOS)
import SwiftUI
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// One read of terminal output waiting to be fed to the renderer.
public struct TerminalPacket: Identifiable, Sendable {
    public let id = UUID()
    public let data: Data
    /// How many of `data`'s first bytes a renderer of this device already drew, in an earlier run of the
    /// app or before the host reset the output: the queries in them (cursor position, device attributes)
    /// were answered then, so they are drawn again without answering.
    public let answeredPrefix: Int

    public init(data: Data, answeredPrefix: Int = 0) {
        self.data = data
        self.answeredPrefix = min(max(0, answeredPrefix), data.count)
    }
}

/// What the terminal menu and key bar ask a terminal to do.
public enum TerminalAction: String, CaseIterable, Sendable {
    case keyboard, hideKeyboard, paste, escape, tab, interrupt, up, down, left, right, reconnect, end
}

/// A terminal tab's live state: its output cursor and the packets not yet drawn, the ordered and
/// bounded input queue, its connection state, and the retained SwiftTerm renderer (UIKit on iPhone and
/// iPad, AppKit on the Mac). The remote process lives on the host; ending this session never ends it.
@MainActor @Observable public final class TerminalSession: WorkspaceSession {
    public let tabID: UUID
    public let projectID: String
    public let terminalID: String
    /// Shown on a screen of its own (a terminal of another device outside any workspace this device knows), not as a
    /// tab: it is active while that screen shows it, whatever tab is selected.
    public let standalone: Bool
    /// The label the terminal was created with (OpenCode, Claude Code, Codex, Terminal). A title that is
    /// only this label counts as no title.
    public let label: String
    /// When this device last saw the program set a window title. The host's list, when it was asked for
    /// before then, does not undo it.
    @ObservationIgnored public private(set) var liveTitleAt: Date?
    @ObservationIgnored private var lastProgramTitle: String?
    /// The name a standalone terminal's own screen shows (`StandaloneTerminalView`), following the program and the
    /// host as a tab's name does; nil while it is still the name it was opened with.
    public internal(set) var shownTitle: String?

    public private(set) var packets: [TerminalPacket] = []
    /// Changes when the host resets the output, which starts a new renderer.
    public private(set) var rendererID = UUID()
    public private(set) var status: TerminalStatus = .running
    public private(set) var exitCode: Int?
    /// A notice about input or an action; the terminal keeps running.
    public var issue: String?
    /// Why output stopped; the terminal shows it instead of the screen.
    public private(set) var connectionIssue: String?
    /// The terminal ended: its program exited, the host lost it, or the host no longer has it (it was ended
    /// elsewhere, or the host started again). Reconnecting cannot bring it back; `connectionIssue` says how it
    /// ended, from `howEnded` when the host recorded it (docs/HOST-API.md "How terminals end").
    public private(set) var terminalGone = false
    /// How the terminal ended, when the host says.
    public private(set) var howEnded: TerminalEnd?
    /// Why Resume did not open a terminal (ending the old one on the host failed or is uncertain); the ended
    /// state shows it.
    public var resumeIssue: String?
    /// The host still lists this ended terminal (it answered its output, not `terminal_not_found`), so Resume ends
    /// it there first.
    @ObservationIgnored private var hostListsEnded = false
    /// Delivery of earlier input is uncertain; typing waits for an explicit Resume Typing.
    public private(set) var inputBlocked = false
    /// How much of the terminal the key bar covers at the bottom (landscape on iPhone); the notice sits
    /// above it. Reported by the renderer's mount.
    public internal(set) var keyBarCover: CGFloat = 0
    /// Increments on Reconnect, which restarts the output reads.
    public private(set) var generation = 0
    public private(set) var focusRequest = 0
    public private(set) var showKeyboard = true
    public private(set) var pasteRequest = 0
    public var showEndConfirmation = false
    public private(set) var ending = false
    /// A standalone terminal (`standalone`) was ended from here: its screen goes, as a tab would close.
    public private(set) var endedHere = false
    #if os(iOS)
    /// The dominant background a full-screen program paints, so phone chrome and margins match it.
    public var paintedEdge: UIColor?
    #elseif os(macOS)
    /// The color a full-screen program paints behind every edge, so the margins match it.
    public var paintedEdge: NSColor?
    #endif

    /// A view shows the terminal, its scene is active and nothing covers the workspace. Each view
    /// reports for itself (`setViewActive`): a view rebuilt in place appears before the old one
    /// disappears. The session adds the tab selection, the lock and the opening cover.
    public var viewActive: Bool { !activeViews.isEmpty }
    @ObservationIgnored private var activeViews: Set<UUID> = []

    @ObservationIgnored private weak var workspace: WorkspaceModel?
    @ObservationIgnored private var cursor: UInt64 = 0
    @ObservationIgnored private lazy var naming = TerminalNaming(session: self, workspace: workspace)
    /// Output before this cursor was drawn, and its queries (cursor position, device attributes) answered,
    /// by an earlier renderer on this device: in an earlier run of the app (up to the host's end at the first
    /// read), in an earlier session of this run, or before the host reset the output. Nil until known.
    @ObservationIgnored private var answeredUntil: UInt64?
    /// The terminal was made in an earlier run of the app: its history's end is learned from the first read.
    @ObservationIgnored private var restored: Bool
    @ObservationIgnored private var operations: [Operation] = []
    @ObservationIgnored private var queuedInputBytes = 0
    @ObservationIgnored private var inputDraining = false
    @ObservationIgnored private var initialOutputRequestComplete = false
    @ObservationIgnored private var resolvedRefreshGeneration: UUID?
    @ObservationIgnored private var rendererLaidOut = false
    @ObservationIgnored private var initialPacketIDs: Set<UUID> = []
    @ObservationIgnored private var ended = false
    /// The renderer's grid, as it last reported it, sent again before typing (`enqueue`).
    @ObservationIgnored private var size: (rows: Int, cols: Int)?
    /// When this device last typed here; nil until it does.
    @ObservationIgnored private var lastInputAt: Date?

    private enum Operation {
        case input(Data)
        case resize(Int, Int)
    }

    private static let outputWait: TimeInterval = 15
    /// The terminal's state when no address of the host answered before its first read (B-14).
    static let terminalsUnavailableIssue = "AgentLand's terminal service on the Mac isn't answering. The terminal reconnects once it does."
    static let hostAwayIssue = "Can’t reach the host. The terminal reconnects once it answers."
    /// Typing after this long without typing here sends this device's size first: another device may have sized the
    /// terminal meanwhile, and the viewer who typed last sets it.
    static let sizeAgainAfter: TimeInterval = 1

    public init(tab: WorkspaceTab, workspace: WorkspaceModel, standalone: Bool = false) {
        tabID = tab.id
        projectID = tab.projectID
        terminalID = tab.resourceID
        label = tab.label
        self.standalone = standalone
        self.workspace = workspace
        answeredUntil = workspace.terminalOutputReadHere[tab.resourceID]
        restored = answeredUntil == nil
    }

    /// Selected (or shown on its own screen), unlocked and on screen: output is read and parser replies go out.
    public var active: Bool {
        guard let workspace, !ended else { return false }
        return viewActive && (standalone || workspace.selectedTabID == tabID) && !workspace.locked
    }

    /// Active and uncovered: the person's typing, paste and menu keys are accepted.
    public var inputActive: Bool { active && workspace?.presentationPending == false }

    /// The renderer takes the keyboard: input is active and the terminal has not ended. Nothing can be typed
    /// into an ended terminal, so its keyboard and key bar go away.
    public var rendererTakesInput: Bool { inputActive && !terminalGone }

    public func end() {
        ended = true
        naming.stop()
        activeViews.removeAll()
        operations.removeAll()
        queuedInputBytes = 0
        releaseRenderer()
    }

    // MARK: Actions

    public func perform(_ action: TerminalAction) {
        guard inputActive else { return }
        switch action {
        case .keyboard: showKeyboard = true; focusRequest &+= 1
        case .hideKeyboard: showKeyboard = false; focusRequest &+= 1
        case .paste: if !inputBlocked { pasteRequest &+= 1 }
        case .escape: enqueue(Data([0x1b]))
        case .tab: enqueue(Data([0x09]))
        case .interrupt: enqueue(Data([0x03]))
        case .up: enqueue(Data("\u{1b}[A".utf8))
        case .down: enqueue(Data("\u{1b}[B".utf8))
        case .right: enqueue(Data("\u{1b}[C".utf8))
        case .left: enqueue(Data("\u{1b}[D".utf8))
        case .reconnect: reconnect()
        case .end: if !ending { showEndConfirmation = true }
        }
    }

    /// Records whether the view `view` shows this terminal on screen, in an active scene and uncovered.
    public func setViewActive(_ active: Bool, view: UUID) {
        if active { activeViews.insert(view) } else { activeViews.remove(view) }
    }

    /// Recovery is explicit: the person checked the output and chooses to type again.
    public func resumeTyping() {
        inputBlocked = false
        issue = nil
    }

    public func reconnect() {
        issue = nil
        connectionIssue = nil
        terminalGone = false
        howEnded = nil
        resumeIssue = nil
        hostListsEnded = false
        inputBlocked = false
        resetInitialPresentation()
        generation &+= 1
    }

    // MARK: Renderer callbacks

    /// The renderer drew `id`; the next packet can go.
    public func fed(_ id: UUID) {
        guard packets.first?.id == id else { return }
        packets.removeFirst()
        if packets.isEmpty { naming.outputDrawn() }
        initialPacketIDs.remove(id)
        reportPresentationIfReady()
    }

    public func rendererDidLayout(_ id: UUID) {
        guard id == rendererID else { return }
        rendererLaidOut = true
        reportPresentationIfReady()
    }

    /// The program set a window title (OSC 0 or 2). It is cleaned as the host cleans it and names the tab
    /// at once; a title that cleans to nothing leaves the tab to the host's command or the label. A name a
    /// device gave stays, as the host keeps it (docs/HOST-API.md "Contextual terminal names").
    func programTitleChanged(_ raw: String) {
        guard !ended else { return }
        let title = TerminalTitle.clean(raw, label: label)
        guard title != lastProgramTitle else { return }
        lastProgramTitle = title
        guard workspace?.terminalNameSources[terminalID] != .device else { return }
        liveTitleAt = Date()
        workspace?.terminalTitleChanged(tabID: tabID, programTitle: title)
    }

    // Read a bounded tail of the active buffer, independent of scroll position.
    // SwiftTerm has already interpreted escape sequences and redraws here.
    func namingSnapshot() -> (lines: [String], cursor: UInt64, at: Date)? {
        guard cursor > 0, packets.isEmpty, let terminal = retainedRenderer?.getTerminal() else { return nil }
        var low = 0, high = 512
        while high < 1_048_576, terminal.bufferLine(atRow: high) != nil { high *= 2 }
        while low < high {
            let middle = (low + high) / 2
            if terminal.bufferLine(atRow: middle) != nil { low = middle + 1 } else { high = middle }
        }
        let lines = (max(0, low - 60)..<low).compactMap { terminal.bufferLine(atRow: $0)?.translateToString(trimRight: true) }
        return lines.contains(where: { !$0.allSatisfy(\.isWhitespace) }) ? (lines, cursor, Date()) : nil
    }

    /// The host took this device's name for the terminal (`TerminalNaming`): the tab shows it, and keeps it over
    /// the program's later titles, as the host does.
    func contextTitleAnswered(_ title: String, readAt: Date) {
        guard !ended, liveTitleAt.map({ $0 <= readAt }) ?? true else { return }
        liveTitleAt = Date()
        workspace?.terminalNameSources[terminalID] = .device
        workspace?.terminalTitleChanged(tabID: tabID, programTitle: title)
    }

    private func resetInitialPresentation(rendererChanged: Bool = false) {
        initialOutputRequestComplete = false
        resolvedRefreshGeneration = nil
        if rendererChanged {
            rendererLaidOut = false
            paintedEdge = nil
        }
        initialPacketIDs.removeAll()
    }

    /// Terminal readiness includes native layout and delivery of the initial output packets, or an
    /// actionable connection state.
    public func reportPresentationIfReady() {
        guard let workspace, let ticket = workspace.presentationRequest(for: tabID) else { return }
        guard initialOutputRequestComplete,
              resolvedRefreshGeneration == workspace.tabRefreshGeneration[tabID],
              connectionIssue != nil || (rendererLaidOut && initialPacketIDs.isEmpty)
        else { return }
        workspace.reportPresentationReady(ticket)
    }

    // MARK: Output

    /// Reads output until cancelled, the tab stops being active, or the terminal ends. The host holds
    /// each request until the shell writes, so echo and redraws arrive without a client-side delay.
    /// `viewActive` is the calling view's state when it started the read.
    public func poll(view: UUID, viewActive: Bool) async {
        setViewActive(viewActive, view: view)
        guard active, let workspace else { return }
        // While the host is unreachable the workspace banner explains it; the terminal keeps its last
        // screen and resumes from its cursor on return.
        guard workspace.reachable || !initialOutputRequestComplete else { return }
        let refreshGeneration = workspace.tabRefreshGeneration[tabID]
        // No address answers before the first read: say so now rather than wait out the request's timeout
        // (B-14). The read starts again with the connection epoch once the host is back.
        if !workspace.reachable {
            connectionIssue = Self.hostAwayIssue
            initialOutputRequestComplete = true
            resolvedRefreshGeneration = refreshGeneration
            reportPresentationIfReady()
            return
        }
        guard let client = workspace.client else {
            connectionIssue = "The host is unavailable."
            initialOutputRequestComplete = true
            resolvedRefreshGeneration = refreshGeneration
            reportPresentationIfReady()
            return
        }
        let hostID = workspace.hostID
        let pollGeneration = generation
        let isCurrent: @MainActor @Sendable () -> Bool = { [weak self, weak workspace] in
            guard let self, let workspace else { return false }
            return self.generation == pollGeneration && workspace.tabRefreshGeneration[self.tabID] == refreshGeneration &&
                self.active && workspace.client === client && workspace.isCurrent(hostID: hostID, tabID: self.tabID)
        }
        while !Task.isCancelled && isCurrent() {
            let result = await TerminalPollDelivery.fetch(isCurrent: isCurrent) {
                try await client.terminalOutput(projectID: projectID, terminalID: terminalID, cursor: cursor, wait: Self.outputWait)
            }
            guard let result else { return }
            switch result {
            case .success(let output):
                connectionIssue = nil
                let readFrom = cursor
                cursor = output.cursor
                workspace.terminalOutputReadHere[terminalID] = max(workspace.terminalOutputReadHere[terminalID] ?? 0, output.cursor)
                status = output.status
                exitCode = output.exitCode
                if restored {
                    restored = false
                    answeredUntil = output.end
                }
                if output.reset {
                    packets.removeAll()
                    rendererID = UUID()
                    resetInitialPresentation(rendererChanged: true)
                    // The new renderer draws again what the old one had read and answered.
                    answeredUntil = max(answeredUntil ?? 0, readFrom)
                }
                if let data = output.decodedData, !data.isEmpty {
                    let start = output.cursor >= UInt64(data.count) ? output.cursor - UInt64(data.count) : 0
                    let answered = answeredUntil.map { $0 > start ? Int(min($0 - start, UInt64(data.count))) : 0 } ?? 0
                    let packet = TerminalPacket(data: data, answeredPrefix: answered)
                    packets.append(packet)
                    if !initialOutputRequestComplete { initialPacketIDs.insert(packet.id) }
                }
                initialOutputRequestComplete = true
                resolvedRefreshGeneration = refreshGeneration
                // The terminal ended (its program exited, or the host lost it): say when and why once its last
                // output is drawn. Neither comes back, so this is the ended state, not a retry.
                if output.status != .running && (output.decodedData?.isEmpty ?? true) {
                    showEnded(output.ended ?? (output.exitCode.map { TerminalEnd(reason: nil, at: nil, exitCode: $0) }), gone: false)
                }
                reportPresentationIfReady()
                if output.status != .running && (output.decodedData?.isEmpty ?? true) { return }
            case .failure(let error):
                let firstRead = !initialOutputRequestComplete
                initialOutputRequestComplete = true
                resolvedRefreshGeneration = refreshGeneration
                // The host answered, but its terminal service did not: keep the screen and the cursor, say so, and read
                // again. The host is reachable, so this is not a connection failure.
                if Self.isTerminalServiceUnavailable(error) {
                    connectionIssue = Self.terminalsUnavailableIssue
                    reportPresentationIfReady()
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    continue
                }
                guard ClientError.isConnectionFailure(error) else {
                    if let gone = error as? TerminalGoneError {
                        showEnded(gone.ended, gone: true)
                    } else if case let .server(code, _) = error as? ClientError, code == "terminal_not_found" || code == "not_found" {
                        showEnded(nil, gone: true)
                    } else {
                        connectionIssue = error.localizedDescription
                    }
                    reportPresentationIfReady()
                    return
                }
                // A dropped connection is the host's state, not this terminal's. Keep the screen,
                // let the connection monitor confirm the outage, and read again from the same cursor.
                if firstRead { connectionIssue = error.localizedDescription }
                reportPresentationIfReady()
                workspace.noteConnectionFailure()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    private static func isTerminalServiceUnavailable(_ error: Error) -> Bool {
        switch error as? ClientError {
        case .server(let code, _)?: code == "terminals_unavailable"
        case .unexpectedStatus(503)?: true
        default: false
        }
    }

    private func showEnded(_ end: TerminalEnd?, gone: Bool) {
        terminalGone = true
        hostListsEnded = !gone
        howEnded = end
        connectionIssue = TerminalEndText.description(end, label: label, gone: gone)
        // Nothing can be typed into it: the keyboard and key bar go away (`rendererTakesInput`).
        showKeyboard = false
        focusRequest &+= 1
        // It went on in another terminal: the tab follows it, once this read has returned. A standalone screen has no
        // tab to hand over and stays ended.
        if let next = end?.continuedIn, !standalone, let workspace {
            let tabID = tabID, terminalID = terminalID
            Task { @MainActor in workspace.followContinuation(of: tabID, from: terminalID, to: next) }
        }
    }

    /// What Resume continues: a Claude Code terminal that ended, on a host that resumes conversations
    /// (`resume` in `terminalFeatures`) and offers Claude Code. Its conversation when the host named one, else
    /// Claude Code's own picker of the workspace's conversations. A standalone terminal has no workspace to open the
    /// new terminal in, nor a tab for it to take the place of: it offers no Resume. Nor does an agent released to its
    /// Terminal window (`keptInTerminal`): it still runs there, and a second Claude Code would share its conversation.
    public var resumeTarget: TerminalResume? {
        guard !standalone, terminalGone, howEnded?.reason != .keptInTerminal, let capabilities = workspace?.capabilities, capabilities.terminalFeatures.contains("resume"),
              TerminalProgram.offered(by: capabilities).contains(.claude) else { return nil }
        let program = howEnded?.program ?? (label == TerminalProgram.claude.terminalTitle ? TerminalProgram.claude.id : nil)
        guard program == TerminalProgram.claude.id else { return nil }
        return howEnded?.conversationID.map { .conversation($0) } ?? .pick
    }

    /// Opens a new Claude Code terminal in the same workspace, continuing this one's conversation, in this tab's place.
    /// An ended terminal the host still lists is ended there first (`POST /v1/terminal/close`), so it stops counting
    /// toward the host's terminal limit and one conversation never runs in two terminals: a failed or uncertain end
    /// opens nothing and says so (`resumeIssue`).
    public func resume() async {
        guard let target = resumeTarget, let workspace, !ending else { return }
        resumeIssue = nil
        if hostListsEnded {
            guard let client = workspace.client else { return }
            ending = true
            defer { ending = false }
            let hostID = workspace.hostID
            let outcome = await client.closeTerminal(projectID: projectID, terminalID: terminalID)
            guard workspace.isCurrent(hostID: hostID, tabID: tabID), workspace.client === client else { return }
            switch outcome {
            case .accepted: break
            case let .failed(.server(code, _)) where code == "terminal_not_found": break // already gone
            case .uncertain:
                resumeIssue = "The ended terminal may still be on the Mac. Try Resume again."
                return
            case let .failed(error):
                resumeIssue = error.localizedDescription
                return
            }
            hostListsEnded = false
        }
        workspace.create(.terminal, program: .claude, projectID: projectID, resume: target, replacing: tabID)
    }

    // MARK: Input

    /// The person's typing, paste and keys. Refused while offline, never queued for later. Other devices and the
    /// Mac's Terminal window may show the terminal too, at their sizes, and the viewer who typed last sets it: this
    /// device's size goes first before its first typing here, and again after a second without typing
    /// (`sizeAgainAfter`).
    public func enqueue(_ data: Data) {
        guard inputActive, !inputBlocked, !data.isEmpty, let workspace else { return }
        guard workspace.reachable else {
            issue = "Not connected. Nothing was sent; typing resumes when the host is back."
            return
        }
        let now = Date()
        if let size, lastInputAt.map({ now.timeIntervalSince($0) >= Self.sizeAgainAfter }) ?? true {
            queueResize(rows: size.rows, cols: size.cols)
        }
        lastInputAt = now
        appendInput(data)
    }

    /// A reply the terminal's parser owes the program (a cursor or device-status report). It may go
    /// out while the terminal prepares behind the opening cover, through the same ordered queue.
    public func enqueueProtocolReply(_ data: Data) {
        guard active, !inputBlocked, !data.isEmpty else { return }
        appendInput(data)
    }

    private func appendInput(_ data: Data) {
        do {
            let chunks = try TerminalInputChunker.chunks(data)
            guard queuedInputBytes + data.count <= TerminalInputChunker.maximumPasteBytes,
                  operations.count + chunks.count <= 1024
            else { issue = "Terminal input queue is full. Wait for output before pasting more."; return }
            operations.append(contentsOf: chunks.map { .input($0) })
            queuedInputBytes += data.count
            startDrain()
        } catch TerminalInputChunkError.invalidUTF8 { issue = "Terminal input was not valid UTF-8 and was not sent." }
        catch { issue = "Paste is too large; use at most 256 KiB at once." }
    }

    private func startDrain() {
        guard !inputDraining else { return }
        inputDraining = true
        Task { await drainOperations() }
    }

    private func drainOperations() async {
        defer { inputDraining = false }
        guard let workspace, let client = workspace.client else { operations.removeAll(); queuedInputBytes = 0; return }
        let hostID = workspace.hostID
        while !operations.isEmpty && !ended && workspace.isCurrent(hostID: hostID, tabID: tabID) {
            var operation = operations.removeFirst()
            // Keys typed while an earlier request was in flight travel together, in order, as one
            // bounded request instead of one round trip each.
            if case .input(var data) = operation {
                while case .input(let next)? = operations.first, data.count + next.count <= TerminalInputChunker.maximumChunkBytes {
                    operations.removeFirst()
                    data.append(next)
                }
                operation = .input(data)
            }
            let outcome: SendOutcome
            switch operation {
            case .input(let data):
                queuedInputBytes -= data.count
                outcome = await client.sendTerminalInput(projectID: projectID, terminalID: terminalID, data: data)
            case .resize(let rows, let cols):
                outcome = await client.resizeTerminal(projectID: projectID, terminalID: terminalID, rows: rows, cols: cols)
            }
            guard !ended, workspace.isCurrent(hostID: hostID, tabID: tabID) else { operations.removeAll(); queuedInputBytes = 0; return }
            switch outcome {
            case .accepted: break
            case .failed(.unreachable):
                // Provably not delivered: nothing to reconcile, so typing is not blocked. Later keys
                // are dropped too so none arrive out of order.
                issue = "Not sent: the host isn't reachable."
                operations.removeAll(); queuedInputBytes = 0
                workspace.noteConnectionFailure()
                return
            case .uncertain:
                issue = "A terminal action may have reached the host. Check output before typing again."
                inputBlocked = true
                operations.removeAll(); queuedInputBytes = 0
                workspace.noteConnectionFailure()
                return
            case .failed(let error):
                issue = error.localizedDescription
                inputBlocked = true
                operations.removeAll(); queuedInputBytes = 0
                return
            }
        }
    }

    /// The renderer's grid changed. Only the latest size waits in the queue. A grid reported while the terminal is
    /// not active is kept for the next typing (`enqueue`).
    public func resize(rows: Int, cols: Int) {
        guard rows > 0, cols > 0 else { return }
        size = (rows, cols)
        guard active, !inputBlocked else { return }
        queueResize(rows: rows, cols: cols)
    }

    private func queueResize(rows: Int, cols: Int) {
        if let last = operations.last, case .resize = last { operations.removeLast() }
        if operations.count >= 1024 { issue = "Terminal operation queue is full. Wait before resizing again."; return }
        operations.append(.resize(rows, cols))
        startDrain()
    }

    /// Ends the process on the host after the person confirmed it, then closes the tab.
    public func endTerminal() async {
        guard inputActive, !ending, let workspace, let client = workspace.client else { return }
        ending = true
        defer { ending = false }
        let hostID = workspace.hostID
        let outcome = await client.closeTerminal(projectID: projectID, terminalID: terminalID)
        guard workspace.isCurrent(hostID: hostID, tabID: tabID), workspace.client === client else { return }
        switch outcome {
        case .accepted:
            if standalone { endedHere = true } else { workspace.close(tabID) }
        case .uncertain:
            issue = "The terminal may have ended. Refresh before ending it again."
            inputBlocked = true
        case .failed(let error): issue = error.localizedDescription
        }
    }

    // MARK: Renderer

    @ObservationIgnored private var retainedRenderer: AgentTerminalView?
    @ObservationIgnored private var retainedRendererID: UUID?
    /// The renderer's delegate and what it last applied. It outlives any one mounted view.
    @ObservationIgnored private(set) lazy var rendererLink: TerminalRendererLink = {
        let link = TerminalRendererLink(
            send: { [weak self] data in self?.enqueue(data) },
            sendProtocolReply: { [weak self] data in self?.enqueueProtocolReply(data) },
            resize: { [weak self] rows, cols in self?.resize(rows: rows, cols: cols) })
        // SwiftTerm can report a title while it feeds inside SwiftUI's update; the tab changes after it.
        link.titleChanged = { [weak self] title in DispatchQueue.main.async { self?.programTitleChanged(title) } }
        return link
    }()
    /// How many renderers this session made. A rebuilt view reuses the current one.
    @ObservationIgnored public private(set) var renderersMade = 0
    /// The current renderer's number among every renderer the app made. The UI tests compare it
    /// across a rebuilt view: a new session or renderer gets a new number.
    @ObservationIgnored public private(set) var rendererSerial: Int?
    private static var renderersMadeInApp = 0

    /// The retained renderer for `id`, made on first use. The host resetting the output starts a new
    /// one; anything else (tab switches, locks, rebuilt views) keeps it.
    public func renderer(for id: UUID) -> AgentTerminalView {
        if let view = retainedRenderer, retainedRendererID == id { return view }
        releaseRenderer()
        let view = TerminalRenderer.makeRenderer(link: rendererLink)
        view.onPaste = { [weak self] data in self?.enqueue(data) }
        view.onLayoutReady = { [weak self] in self?.rendererDidLayout(id) }
        #if os(iOS)
        view.takesInput = { [weak self] in self?.rendererTakesInput ?? false }
        #endif
        rendererLink.reset(focusRequest: focusRequest, pasteRequest: pasteRequest)
        retainedRenderer = view
        retainedRendererID = id
        renderersMade += 1
        Self.renderersMadeInApp += 1
        rendererSerial = Self.renderersMadeInApp
        return view
    }

    /// The current renderer, if a view made one.
    public var currentRenderer: AgentTerminalView? { retainedRenderer }

    private func releaseRenderer() {
        guard let view = retainedRenderer else { return }
        #if os(iOS)
        if view.isFirstResponder { _ = view.resignFirstResponder() }
        #else
        if let window = view.window, window.firstResponder === view { window.makeFirstResponder(nil) }
        #endif
        view.removeFromSuperview()
        view.terminalDelegate = nil
        view.onPaste = nil
        view.onLayoutReady = nil
        retainedRenderer = nil
        retainedRendererID = nil
        rendererSerial = nil
    }
}
