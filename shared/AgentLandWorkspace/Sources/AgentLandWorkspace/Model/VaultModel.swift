import Foundation
import Observation
import AgentLandCore

/// A change to the vault, one at a time.
public enum VaultChange: Equatable, Sendable {
    /// The switch.
    case enabled(Bool)
    /// The folder the vault writes in; "" is the host's default.
    case folder(String)
    /// Whether terminals get notes.
    case terminals(Bool)
    /// Try Again: `enabled: true` again, which restarts a paused writer.
    case tryAgain
    /// Use a folder another archive's marker names anyway (`adopt`, once).
    case adopt
    /// Rebuild: write every note again (deletes nothing).
    case rebuild
}

/// Settings → Vault on the Mac (docs/HOST-API.md "Vault"): the Markdown copy of the archive the host keeps in a
/// folder, from `GET /v1/vault`, with its switch, folder, terminal notes, Try Again, adopt and Rebuild. Hosts list
/// `capabilities.vault` only for the Mac's own session; nothing is asked of a host that does not list it.
///
/// Every request captures the host and client it was made for, and an answer for another is dropped; a newer read
/// replaces an older one, and a confirmed change makes reads begun before it count no more. One change is on its way
/// at a time. Changes need the host now and are never sent again by themselves: one whose answer was lost is reported
/// as not confirmed, and the status is read again. While the pane shows, `follow()` reads the status every
/// `pollInterval`.
@MainActor @Observable public final class VaultModel {
    /// The vault as last read or answered; nil before the first answer.
    public private(set) var status: VaultStatus?
    /// Why the last read failed; what was read before stays shown.
    public private(set) var loadIssue: String?
    public var notice: WorkspaceNotice?
    /// The change on its way to the host.
    public private(set) var changing: VaultChange?
    /// How often `follow()` reads the status; tests shorten it.
    @ObservationIgnored public var pollInterval: Duration = .seconds(2)

    @ObservationIgnored public private(set) weak var workspace: WorkspaceModel?
    /// Changes with each read and each confirmed change; an answer to an older read is dropped.
    @ObservationIgnored private var readToken = UUID()
    /// The change on its way, so only its own answer clears it.
    @ObservationIgnored private var changeToken: UUID?

    public init(workspace: WorkspaceModel) {
        self.workspace = workspace
    }

    // MARK: What the host offers

    /// The pane has something to show: the host lists `capabilities.vault` (version 1) for this session.
    public var isAvailable: Bool { workspace?.capabilities?.vault != nil }
    /// The host answers now; changes are refused otherwise.
    public var canChange: Bool { workspace?.client != nil && workspace?.reachable == true }

    /// What the pane follows the status again for: the host and its connection (`paneReadKey`), and whether it lists
    /// the vault, since `refresh` asks nothing while it does not.
    public var readKey: String { "\(workspace?.paneReadKey ?? "")|\(isAvailable)" }

    var hostName: String { workspace?.hostName ?? "your Mac" }

    // MARK: What the controls show

    /// The switch: what was asked while that change is on its way, else what the host keeps (off until read).
    public var enabled: Bool {
        if case let .enabled(value) = changing { return value }
        return status?.enabled ?? false
    }

    /// Terminal notes: what was asked while that change is on its way, else what the host keeps (on until read).
    public var terminals: Bool {
        if case let .terminals(value) = changing { return value }
        return status?.terminals ?? true
    }

    /// The folder: the one asked for while that change is on its way (the default for ""), else the host's.
    public var folder: String {
        if case let .folder(value) = changing { return value.isEmpty ? status?.defaultFolder ?? "" : value }
        return status?.folder ?? ""
    }

    /// A change is on its way; the controls wait for it.
    public var isChanging: Bool { changing != nil }

    // MARK: Reading

    /// Keeps the status current while the pane shows: reads it now, then every `pollInterval`, except while a change
    /// is on its way (its answer is the status) or the host does not answer. Ends when the task is cancelled.
    public func follow() async {
        await refresh()
        while !Task.isCancelled {
            do { try await Task.sleep(for: pollInterval) } catch { return }
            guard changing == nil else { continue }
            await refresh()
        }
    }

    /// Reads the status again. Nothing is asked while the host does not answer or does not list the vault: what was
    /// read stays.
    public func refresh() async {
        guard isAvailable, canChange, let stamp = workspace?.requestStamp() else { return }
        let token = UUID()
        readToken = token
        let result: Result<VaultStatus, Error>
        do { result = .success(try await stamp.client.vault()) } catch { result = .failure(error) }
        // Another host, another connection, a newer read or a confirmed change: this answer no longer counts.
        guard workspace?.isCurrent(stamp) == true, readToken == token else { return }
        switch result {
        case let .success(value):
            status = value
            loadIssue = nil
        case let .failure(error):
            // The pane went away while it read: nothing failed.
            if isCancellation(error) { return }
            loadIssue = (error as? ClientError)?.isVaultUnavailable == true
                ? "The vault isn’t available on \(hostName) right now." : error.localizedDescription
            if ClientError.isConnectionFailure(error) { workspace?.noteConnectionFailure() }
        }
    }

    // MARK: Changes

    /// Turns the vault on or off. On makes the folder when it is missing and checks that the host can write there.
    @discardableResult
    public func setEnabled(_ enabled: Bool) async -> Bool {
        await change(.enabled(enabled)) { await $0.setVault(enabled: enabled) }
    }

    /// Moves the vault to `folder` (an absolute path). The folder left behind keeps its notes; the new one gets every
    /// note, or goes on where the vault left off there.
    @discardableResult
    public func setFolder(_ folder: String) async -> Bool {
        await change(.folder(folder)) { await $0.setVault(folder: folder) }
    }

    /// Moves the vault back to the host's default folder.
    @discardableResult
    public func useDefaultFolder() async -> Bool {
        await change(.folder("")) { await $0.setVault(folder: "") }
    }

    /// Turns terminal notes on or off. Turned on again, terminals that ended meanwhile get their notes.
    @discardableResult
    public func setTerminals(_ terminals: Bool) async -> Bool {
        await change(.terminals(terminals)) { await $0.setVault(terminals: terminals) }
    }

    /// Try Again for a paused vault: restarts the writer, which looks at the folder again at once.
    @discardableResult
    public func tryAgain() async -> Bool {
        await change(.tryAgain) { await $0.setVault(enabled: true) }
    }

    /// Writes in a folder another archive's marker names anyway, once (`other_archive`).
    @discardableResult
    public func adoptFolder() async -> Bool {
        await change(.adopt) { await $0.setVault(adopt: true) }
    }

    /// Writes every note again: notes and images deleted in the folder come back; nothing is deleted.
    @discardableResult
    public func rebuild() async -> Bool {
        await change(.rebuild) { await $0.rebuildVault() }
    }

    /// Sends one change. True once the host confirmed it; the status is then its answer.
    private func change(_ change: VaultChange, _ send: (APIClient) async -> VaultChangeOutcome) async -> Bool {
        guard isAvailable, changing == nil, let stamp = changeStamp() else { return false }
        let token = UUID()
        changeToken = token
        changing = change
        let outcome = await send(stamp.client)
        if changeToken == token {
            changeToken = nil
            changing = nil
        }
        guard workspace?.isCurrent(stamp) == true else { return false }
        if case let .changed(value) = outcome {
            // Reads made before the change no longer count.
            readToken = UUID()
            status = value
            loadIssue = nil
            return true
        }
        await report(outcome, of: change)
        return false
    }

    /// What a change that did not happen, or may have, says; the status is read again when the host may know better.
    private func report(_ outcome: VaultChangeOutcome, of change: VaultChange) async {
        switch outcome {
        case let .refused(.invalidFolder, message):
            notice = WorkspaceNotice("That folder can’t hold the vault", message: message.isEmpty ? nil : message, tone: .error)
        case let .refused(.folderUnwritable, message):
            notice = WorkspaceNotice("AgentLand can’t write in that folder", message: message.isEmpty ? nil : message, tone: .error)
        case let .refused(.off, message):
            notice = WorkspaceNotice("The vault is off", message: message.isEmpty ? nil : message, tone: .warning)
            await refresh()
        case .refused(.unavailable, _):
            notice = WorkspaceNotice("The vault isn’t available on \(hostName) right now", message: "Nothing was changed.", tone: .warning)
        case let .refused(.localOnly, message):
            notice = WorkspaceNotice(VaultText.failedTitle(change), message: message.isEmpty ? nil : message, tone: .error)
        case let .failed(error):
            if error == .unreachable { workspace?.noteConnectionFailure() }
            notice = WorkspaceNotice(VaultText.failedTitle(change), message: error.localizedDescription, tone: .error)
        case .uncertain:
            notice = WorkspaceNotice(VaultText.uncertainTitle(change),
                                     message: "The answer didn’t arrive. The vault’s status was read again; check it before trying again.",
                                     tone: .warning)
            await refresh()
        case .changed:
            break
        }
    }

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
        status = nil
        loadIssue = nil
        notice = nil
        changing = nil
        changeToken = nil
    }
}

/// What the vault's pane says, in words.
public enum VaultText {
    /// The writer's state in a line: "Writing notes: 120 of 340", "Up to date", "Paused: the folder is missing".
    public static func stateLine(_ status: VaultStatus) -> String {
        switch status.state {
        case .off: return "Off"
        case .writing:
            if status.backfill.isRunning {
                return "Writing notes: \(status.backfill.done.formatted()) of \(status.backfill.total.formatted())"
            }
            return status.pending > 0 ? "Writing \(notes(status.pending))" : "Writing notes"
        case .current: return "Up to date"
        case .paused: return pausedLine(status.reason)
        case .unknown: return "Status unknown"
        }
    }

    /// Why a paused vault waits, in a line.
    public static func pausedLine(_ reason: VaultPauseReason?) -> String {
        switch reason {
        case .folderMissing: "Paused: the folder is missing"
        case .permission: "Paused: AgentLand isn’t allowed to use the folder"
        case .lowSpace: "Paused: less than 1 GB free"
        case .otherArchive: "Paused: another Mac’s AgentLand writes in this folder"
        case .error: "Paused: something went wrong"
        case .unknown, nil: "Paused"
        }
    }

    /// What to do about a pause (the host's words when nothing better is known), or the host's words about a state
    /// this version does not know; nil otherwise.
    public static func detail(_ status: VaultStatus) -> String? {
        switch status.state {
        case .paused:
            let retry = "The vault tries again every 30 seconds."
            switch status.reason {
            case .folderMissing: return "Connect the disk it’s on, or choose another folder. " + retry
            case .permission: return "Allow AgentLand to use the folder in System Settings → Privacy & Security, then try again."
            case .lowSpace: return "Free some space on the folder’s disk. " + retry
            case .otherArchive: return "Choose another folder, or use this one anyway: this Mac’s notes then go in it."
            case .error, .unknown, nil: return status.message ?? retry
            }
        case .unknown: return status.message
        case .off, .writing, .current: return nil
        }
    }

    /// "120 notes · 1.5 MB"; nil while nothing is written.
    public static func summary(_ status: VaultStatus) -> String? {
        guard status.notes > 0 || status.bytes > 0 else { return nil }
        let size = status.bytes > 0 ? " · " + status.bytes.formatted(.byteCount(style: .file)) : ""
        return notes(status.notes) + size
    }

    /// The notes left alone, in a sentence; nil when there are none.
    public static func skippedLine(_ status: VaultStatus) -> String? {
        switch status.skipped {
        case 0: nil
        case 1: "1 note left alone: edited without its end marker, or another file is in its place."
        default: "\(status.skipped.formatted()) notes left alone: edited without their end marker, or another file is in their place."
        }
    }

    /// "Last written 5 minutes ago"; nil before the first write since the host started.
    @MainActor public static func lastWriteLine(_ status: VaultStatus, now: Date = Date()) -> String? {
        status.lastWriteAt.map { "Last written " + WorkspaceRowLabel.relative($0, now: now) }
    }

    /// `path` with the home folder shown as `~`.
    public static func folderLine(_ path: String, home: String = NSHomeDirectory()) -> String {
        let home = home.hasSuffix("/") && home.count > 1 ? String(home.dropLast()) : home
        guard !home.isEmpty, home != "/" else { return path }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// The title of a notice for a change that did not happen.
    public static func failedTitle(_ change: VaultChange) -> String {
        switch change {
        case let .enabled(on): "The vault wasn’t turned \(on ? "on" : "off")"
        case .folder: "The vault’s folder wasn’t changed"
        case let .terminals(on): "Terminal notes weren’t turned \(on ? "on" : "off")"
        case .tryAgain: "The vault didn’t start again"
        case .adopt: "The vault didn’t take over the folder"
        case .rebuild: "The vault wasn’t rebuilt"
        }
    }

    /// The title of a notice for a change whose answer was lost.
    public static func uncertainTitle(_ change: VaultChange) -> String {
        switch change {
        case let .enabled(on): "The vault may have been turned \(on ? "on" : "off")"
        case .folder: "The vault’s folder may have been changed"
        case let .terminals(on): "Terminal notes may have been turned \(on ? "on" : "off")"
        case .tryAgain: "The vault may have started again"
        case .adopt: "The vault may have taken over the folder"
        case .rebuild: "The vault may have been rebuilt"
        }
    }

    /// "1 note", "120 notes".
    static func notes(_ count: Int) -> String { count == 1 ? "1 note" : "\(count.formatted()) notes" }
}
