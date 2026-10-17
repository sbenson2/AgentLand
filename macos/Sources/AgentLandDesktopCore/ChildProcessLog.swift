import Foundation
import Darwin

/// A child process's output (the host's, OpenCode's) in its own file, so an incident can be read afterwards
/// (2026-10-14: a terminal died with nothing on record): `~/Library/Logs/AgentLand/<name>.log`, mode 0600 in a
/// 0700 folder. Past `limit` bytes the file moves to `<name>.log.1`, replacing the copy there. Output is written
/// in whole lines with the given secrets replaced by `[redacted]` (and their base64 forms); each stream (stdout,
/// stderr: every `drain`) keeps its own unfinished line, so the two never mix in one line. A line over 64 KiB is
/// written in pieces, redacted before it is cut and cut short of the bytes where a secret not yet whole could
/// start, so no cut splits one. A write that fails is dropped: the child's output is always read, so it never
/// stalls.
public final class ChildProcessLog: @unchecked Sendable {
    public static let defaultLimit = 5 * 1024 * 1024
    static let lineLimit = 64 * 1024

    /// `~/Library/Logs/AgentLand`.
    public static var defaultFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/AgentLand", isDirectory: true)
    }

    public let url: URL
    private let limit: Int
    /// The secrets' bytes, longest first.
    private let secrets: [Data]
    /// How many bytes a long line keeps back at a cut: one less than the longest secret.
    private let overlap: Int
    private static let marker = Data("[redacted]".utf8)
    private let lock = NSLock()
    private var descriptor: Int32 = -1
    private var size = 0
    /// Each stream's unfinished line; `append`'s default stream is 0, each `drain` gets its own.
    private var partials: [Int: Data] = [:]
    private var streams = 0

    public init(folder: URL = ChildProcessLog.defaultFolder, name: String, limit: Int = ChildProcessLog.defaultLimit, secrets: [String] = []) {
        url = folder.appendingPathComponent(name + ".log")
        self.limit = max(1, limit)
        var expanded: [String] = []
        for secret in secrets where secret.count >= 4 {
            expanded.append(secret)
            expanded.append(Data(secret.utf8).base64EncodedString())
            expanded.append(Data("opencode:\(secret)".utf8).base64EncodedString())
        }
        // Longest first, so a secret inside another is never left half replaced.
        self.secrets = expanded.map { Data($0.utf8) }.sorted { $0.count > $1.count }
        overlap = max(0, (self.secrets.first?.count ?? 0) - 1)
    }

    deinit { if descriptor >= 0 { close(descriptor) } }

    /// Writes a line saying a new process started, so each run is easy to find.
    public func started(_ program: String, pid: Int32) {
        let stamp = Date().formatted(.iso8601)
        lock.lock(); defer { lock.unlock() }
        writeLocked(redacted(Data("--- \(stamp) AgentLand started \(program) (pid \(pid)) ---\n".utf8)))
    }

    /// Reads `handle` on a utility queue until it ends, writing every whole line and passing each chunk to
    /// `also` first. The handle is a stream of its own: its unfinished line never takes another's output.
    public func drain(_ handle: FileHandle, also: (@Sendable (Data) -> Void)? = nil, finished: (@Sendable () -> Void)? = nil) {
        let stream = newStream()
        DispatchQueue.global(qos: .utility).async { [self] in
            defer { finished?() }
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                also?(chunk)
                append(chunk, stream: stream)
            }
            flush(stream: stream)
        }
    }

    private func newStream() -> Int {
        lock.lock(); defer { lock.unlock() }
        streams += 1
        return streams
    }

    /// Adds `stream`'s next output: its whole lines are written, the rest waits for its end.
    public func append(_ chunk: Data, stream: Int = 0) {
        lock.lock(); defer { lock.unlock() }
        var partial = partials[stream] ?? Data()
        partial.append(chunk)
        while let newline = partial.firstIndex(of: 0x0A) {
            writeLocked(redacted(Data(partial[partial.startIndex...newline])))
            partial = Data(partial[partial.index(after: newline)...])
        }
        // A line too long to wait for is written in pieces. Its secrets are replaced first; one not yet whole can
        // only begin in its last `overlap` bytes, which every cut keeps back, so a cut never splits a secret.
        if partial.count > Self.lineLimit + overlap {
            partial = redacted(partial)
            while partial.count > Self.lineLimit + overlap {
                let cut = Self.cut(partial, before: Self.lineLimit)
                writeLocked(Data(partial.prefix(cut)) + Data("\n".utf8))
                partial = Data(partial.dropFirst(cut))
            }
        }
        partials[stream] = partial.isEmpty ? nil : partial
    }

    /// Writes what is left of an unfinished line: `stream`'s, or every stream's.
    public func flush(stream: Int? = nil) {
        lock.lock(); defer { lock.unlock() }
        for key in partials.keys.sorted() where stream == nil || key == stream {
            if let partial = partials.removeValue(forKey: key), !partial.isEmpty {
                writeLocked(redacted(partial) + Data("\n".utf8))
            }
        }
    }

    /// `data` with every secret replaced by the marker, byte for byte (output need not be valid UTF-8).
    private func redacted(_ data: Data) -> Data {
        var data = Data(data)
        for secret in secrets {
            var start = data.startIndex
            while start < data.endIndex, let found = data.range(of: secret, in: start..<data.endIndex) {
                data.replaceSubrange(found, with: Self.marker)
                start = found.lowerBound + Self.marker.count
            }
        }
        return data
    }

    /// Where a long line's piece ends: at `limit`, or before a `[redacted]` or UTF-8 character that `limit` falls
    /// inside, so neither is split. `data` is longer than `limit`.
    static func cut(_ data: Data, before limit: Int) -> Int {
        var cut = limit
        let near = data.index(data.startIndex, offsetBy: max(0, limit - marker.count + 1))..<data.index(data.startIndex, offsetBy: min(data.count, limit + marker.count - 1))
        if let marker = data.range(of: marker, in: near), marker.lowerBound - data.startIndex < limit, marker.upperBound - data.startIndex > limit,
           marker.lowerBound > data.startIndex {
            cut = marker.lowerBound - data.startIndex
        }
        var character = cut
        while character > cut - 3, character > 1, data[data.startIndex + character] & 0xC0 == 0x80 { character -= 1 }
        return data[data.startIndex + character] & 0xC0 == 0x80 ? cut : character
    }

    private func writeLocked(_ data: Data) {
        if descriptor < 0 { openLocked() }
        if descriptor >= 0, size > 0, size + data.count > limit {
            close(descriptor)
            descriptor = -1
            _ = rename(url.path, url.path + ".1")
            openLocked()
        }
        guard descriptor >= 0 else { return }
        let written = data.withUnsafeBytes { buffer in write(descriptor, buffer.baseAddress, buffer.count) }
        if written > 0 { size += written }
    }

    private func openLocked() {
        let folder = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let opened = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard opened >= 0 else { return }
        var info = stat()
        guard fstat(opened, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else {
            close(opened)
            return
        }
        // A file made before by someone else's umask is this user's alone again.
        _ = fchmod(opened, 0o600)
        descriptor = opened
        size = Int(info.st_size)
    }
}
