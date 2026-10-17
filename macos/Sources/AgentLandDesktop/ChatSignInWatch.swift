import AppKit
import Foundation
import Observation
import AgentLandDesign
import AgentLandWorkspace

/// Opens a Chat provider's own sign-in in the person's terminal (owner, 2026-10-17: "Each agent that isn't signed in
/// gets a Sign In… button. It opens Terminal running that CLI's own sign-in (claude auth login, codex login), which
/// opens your browser to sign in with your subscription. … AgentLand never sees your password or tokens."): a
/// `.command` script in a 0700 folder of the app's temporary directory, opened with the default app for `.command`
/// files (Terminal unless the person chose another). Its contents are fixed, the CLI's sign-in command from
/// `PlainChatSignIns.signInCommands` and a line saying the window can close; no host or user input goes in it, nor any
/// secret. No AppleScript or Apple Events, which would ask for Automation permission.
struct ChatSignInTerminal {
    /// The folder the scripts go in.
    var folder = FileManager.default.temporaryDirectory.appending(path: "AgentLandSignIn", directoryHint: .isDirectory)
    /// Opens a script in the default app for `.command` files.
    var open: @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) }

    static let closeLine = "You can close this window and go back to AgentLand."

    /// The script that runs `command`.
    static func script(command: String) -> String {
        "#!/bin/sh\n\(command)\necho\necho '\(closeLine)'\n"
    }

    /// Writes provider `id`'s script (0700, in the 0700 folder) and returns it; nil for a provider without a sign-in
    /// command. The name and contents come from the fixed list alone.
    func write(id: String) throws -> URL? {
        guard let entry = PlainChatSignIns.signInCommands.first(where: { $0.key == id }) else { return nil }
        let (known, command) = (entry.key, entry.value)
        let manager = FileManager.default
        // A link or a file where the folder goes, or one someone else owns, is refused.
        if let attributes = try? manager.attributesOfItem(atPath: folder.path) {
            guard attributes[.type] as? FileAttributeType == .typeDirectory,
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
                throw CocoaError(.fileWriteNoPermission)
            }
        } else {
            try manager.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        let file = folder.appending(path: "\(known)-sign-in.command", directoryHint: .notDirectory)
        if (try? manager.attributesOfItem(atPath: file.path)) != nil { try manager.removeItem(at: file) }
        guard manager.createFile(atPath: file.path, contents: Data(Self.script(command: command).utf8),
                                 attributes: [.posixPermissions: 0o700]) else { throw CocoaError(.fileWriteUnknown) }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        return file
    }

    /// Writes provider `id`'s script and opens it. False when it could not be written or opened.
    @MainActor
    func start(id: String) -> Bool {
        guard let file = try? write(id: id) else { return false }
        return open(file)
    }
}

/// A Sign In… under way on the Mac (setup's Claude Code and Codex step, Settings → Agents): after opening the CLI's
/// sign-in in Terminal, the host is asked to check the sign-ins (`POST /v1/chat/providers/check`, then the
/// capabilities) every `every`, until that agent is listed as signed in with a subscription, `limit` has passed, or the
/// view that started it goes away (`stop`). AgentLand going inactive does not stop it: Terminal and the browser are in
/// front while the person signs in. Signed in, VoiceOver hears "<Agent> signed in".
@MainActor
@Observable
final class ChatSignInWatch {
    struct Schedule: Sendable {
        var every: Duration = .seconds(3)
        var limit: Duration = .seconds(300)
        /// Waits `every` between checks (tests pass one that returns at once).
        var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    }

    /// Each row's Sign In…, by provider ID; absent is idle.
    var states: [String: MacChatSignInRow.SignIn] = [:]
    @ObservationIgnored private var watches: [String: (token: UUID, task: Task<Void, Never>)] = [:]
    @ObservationIgnored private let terminal: ChatSignInTerminal
    @ObservationIgnored private let schedule: Schedule
    @ObservationIgnored private let announce: @MainActor (String) -> Void

    init(terminal: ChatSignInTerminal = ChatSignInTerminal(), schedule: Schedule = Schedule(),
         announce: @escaping @MainActor (String) -> Void = { AgentLandAnnouncer.voiceOver.announce($0) }) {
        self.terminal = terminal
        self.schedule = schedule
        self.announce = announce
    }

    func state(_ id: String) -> MacChatSignInRow.SignIn { states[id] ?? .idle }

    /// Opens `row`'s sign-in in Terminal and watches for it, `check` asking the host and answering the sign-ins it then
    /// lists. Starting again (Terminal was closed) opens it again and starts the watch over.
    func signIn(_ row: PlainChatSignIns.Row, check: @escaping @MainActor () async -> PlainChatSignIns) {
        let id = row.id, name = row.name
        watches.removeValue(forKey: id)?.task.cancel()
        guard terminal.start(id: id) else {
            states[id] = .couldNotOpen
            return
        }
        states[id] = .waiting
        let token = UUID()
        let schedule = schedule
        let task = Task { [weak self] in
            var waited = Duration.zero
            while waited < schedule.limit {
                do { try await schedule.sleep(schedule.every) } catch { return }
                waited += schedule.every
                guard !Task.isCancelled else { return }
                let signIns = await check()
                guard !Task.isCancelled else { return }
                if signIns.rows.contains(where: { $0.id == id && $0.available }) {
                    self?.finish(id, token: token, announcement: "\(name) signed in")
                    return
                }
            }
            self?.finish(id, token: token, announcement: nil)
        }
        watches[id] = (token, task)
    }

    /// Ends every watch (the step or pane went away).
    func stop() {
        for watch in watches.values { watch.task.cancel() }
        watches = [:]
        states = [:]
    }

    private func finish(_ id: String, token: UUID, announcement: String?) {
        guard watches[id]?.token == token else { return }
        watches[id] = nil
        states[id] = nil
        if let announcement { announce(announcement) }
    }
}
