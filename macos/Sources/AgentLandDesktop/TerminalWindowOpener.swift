import AppKit
import AgentLandDesktopCore

/// Open in Terminal (Settings → Terminals): Terminal opens a `.command` file that attaches its new window to a running
/// terminal (`TerminalAttachScript`, `agentland-host terminals attach`). Opening a file with Terminal needs no
/// AppleEvents, so no automation permission is asked for.
@MainActor enum TerminalWindowOpener {
    static let terminalBundleIdentifier = "com.apple.Terminal"
    /// How long the file stays for Terminal to run it.
    static let lifetime: Duration = .seconds(30)

    enum OpenError: LocalizedError, Equatable {
        case noTerminal
        case badTerminalID

        var errorDescription: String? {
            switch self {
            case .noTerminal: "Terminal isn’t on this Mac."
            case .badTerminalID: "AgentLand doesn’t know this terminal."
            }
        }
    }

    static func open(terminalID: String, binary: URL, statePath: String, in folder: URL = folder) async throws {
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: terminalBundleIdentifier) else {
            throw OpenError.noTerminal
        }
        removeStale(in: folder)
        let file = try write(terminalID: terminalID, binary: binary, statePath: statePath, in: folder)
        removeLater(file)
        _ = try await NSWorkspace.shared.open([file.url], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    /// `AgentLand/` (0700) in this user's temporary folder.
    static var folder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("AgentLand", isDirectory: true)
    }

    /// Writes `attach-<id>.command` (0700) in `folder`; the time it was written tells it apart from a later one.
    static func write(terminalID: String, binary: URL, statePath: String,
                      in folder: URL = folder) throws -> (url: URL, written: Date?) {
        // The keeper's ID rule, so the ID is a file name and nothing else.
        guard (1...128).contains(terminalID.count),
              terminalID.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._:-".unicodeScalars.contains($0)) })
        else { throw OpenError.badTerminalID }
        let manager = FileManager.default
        try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        let url = folder.appendingPathComponent("attach-\(terminalID).command")
        let script = TerminalAttachScript.contents(binary: binary.path, statePath: statePath, terminalID: terminalID)
        try Data(script.utf8).write(to: url, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return (url, modified(url))
    }

    /// Removes `attach-*.command` files older than `lifetime`: the delete that would have is gone if the app quit first.
    static func removeStale(in folder: URL = folder, now: Date = Date()) {
        let manager = FileManager.default
        let seconds = Double(lifetime.components.seconds)
        for name in (try? manager.contentsOfDirectory(atPath: folder.path)) ?? []
        where name.hasPrefix("attach-") && name.hasSuffix(".command") {
            let url = folder.appendingPathComponent(name)
            if let written = modified(url), now.timeIntervalSince(written) > seconds { try? manager.removeItem(at: url) }
        }
    }

    /// Deletes the file after `lifetime`, unless Open in Terminal wrote it again meanwhile (that one deletes it later).
    private static func removeLater(_ file: (url: URL, written: Date?)) {
        Task {
            try? await Task.sleep(for: lifetime)
            guard modified(file.url) == file.written else { return }
            try? FileManager.default.removeItem(at: file.url)
        }
    }

    private static func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
