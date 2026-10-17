import Foundation
import Observation
import UniformTypeIdentifiers
import AgentLandCore
import AgentLandChat

/// One file going up to the host from a Files tab.
public struct FileUpload: Identifiable, Equatable, Sendable {
    public enum State: Equatable, Sendable {
        /// The local copy is being made (a photo re-encoded, a picked file copied).
        case preparing
        /// Waiting for one of the two uploads a device may run at once.
        case waiting
        /// Going up; `fraction` of the bytes are sent.
        case sending(fraction: Double)
        case done(FileEntry)
        /// An item with this name is in the folder: Replace or Keep Both, never overwritten silently.
        case nameTaken(suggestedName: String?)
        case failed(String)
        /// The connection ended before the host answered: it may be there. The folder was read again.
        case notConfirmed
        case canceled
    }

    public let id: UUID
    /// The name it gets on the host.
    public var name: String
    /// The folder it goes into, relative to the project.
    public let folder: String
    public var size: Int64
    public var state: State
    /// The prepared copy on this device.
    var file: URL?

    public var targetPath: String { FilesSession.join(folder, name) }

    /// Still being worked on or waiting for the person.
    public var isActive: Bool {
        switch state {
        case .preparing, .waiting, .sending: true
        default: false
        }
    }

    public var needsAttention: Bool {
        switch state {
        case .nameTaken, .failed, .notConfirmed: true
        default: false
        }
    }
}

/// The Files tab's uploads: at most two at once (the host's limit per device), each with its
/// progress. A taken name waits for Replace (the existing item goes to the Trash first) or Keep
/// Both (the host's free name). A failed or unconfirmed upload is sent again only when the person
/// asks. Photos are re-encoded first, as chat attachments are, so their location never leaves the
/// device.
@MainActor @Observable public final class FileUploadQueue {
    public static let concurrentUploads = 2

    public private(set) var items: [FileUpload] = []
    /// The upload whose taken name the person is deciding about.
    public var conflict: FileUpload?
    /// Bumped when an upload finishes on the host, for the success haptic.
    public private(set) var completed = 0

    @ObservationIgnored weak var session: FilesSession?
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var canceled: Set<UUID> = []
    @ObservationIgnored private let folder = FileManager.default.temporaryDirectory.appending(path: "AgentLandUploads/\(UUID().uuidString)", directoryHint: .isDirectory)

    init() {}

    public var isEmpty: Bool { items.isEmpty }
    public var hasActive: Bool { items.contains(where: \.isActive) }

    // MARK: Adding

    /// Uploads files picked from Files into the folder the tab shows. Each is copied first (through
    /// file coordination, so a file still in iCloud downloads), then sent as it is.
    public func addFiles(_ urls: [URL]) {
        guard let session else { return }
        let target = session.path
        for url in urls {
            let id = UUID()
            items.append(FileUpload(id: id, name: ChatAttachmentPolicy.sanitizedName(url.lastPathComponent), folder: target, size: 0, state: .preparing))
            let destination = folder.appending(path: id.uuidString, directoryHint: .isDirectory)
            Task {
                let copied = await Task.detached(priority: .userInitiated) { () -> Result<(URL, Int64), Error> in
                    Result { try FileUploadQueue.copy(url, into: destination) }
                }.value
                self.prepared(id, copied)
            }
        }
    }

    /// Uploads a photo into the folder the tab shows, re-encoded like a chat attachment (at most
    /// 2048 px, no location or other metadata). GIFs go as they are.
    public func addPhoto(data: Data, name: String, type: UTType?) {
        guard let session else { return }
        let id = UUID()
        items.append(FileUpload(id: id, name: ChatAttachmentPolicy.sanitizedName(name), folder: session.path, size: 0, state: .preparing))
        let destination = folder.appending(path: id.uuidString, directoryHint: .isDirectory)
        Task {
            let written = await Task.detached(priority: .userInitiated) { () -> Result<(URL, Int64), Error> in
                Result {
                    let prepared = try ChatAttachmentPolicy.prepare(name: name, data: data, type: type)
                    return try FileUploadQueue.write(prepared.data, named: prepared.name, into: destination)
                }
            }.value
            self.prepared(id, written)
        }
    }

    /// The same for a photo the picker handed over as a file. The queue owns `file` and removes its
    /// folder once the photo is re-encoded (or couldn't be).
    public func addPhoto(at file: URL, type: UTType?) {
        guard let session else { return }
        let id = UUID()
        let name = file.lastPathComponent
        items.append(FileUpload(id: id, name: ChatAttachmentPolicy.sanitizedName(name), folder: session.path, size: 0, state: .preparing))
        let destination = folder.appending(path: id.uuidString, directoryHint: .isDirectory)
        Task {
            let written = await Task.detached(priority: .userInitiated) { () -> Result<(URL, Int64), Error> in
                defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
                return Result {
                    let data = try Data(contentsOf: file)
                    let prepared = try ChatAttachmentPolicy.prepare(name: name, data: data, type: type)
                    return try FileUploadQueue.write(prepared.data, named: prepared.name, into: destination)
                }
            }.value
            self.prepared(id, written)
        }
    }

    private func prepared(_ id: UUID, _ result: Result<(URL, Int64), Error>) {
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            if case let .success((url, _)) = result { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            return
        }
        switch result {
        case let .success((url, size)):
            items[index].file = url
            items[index].name = url.lastPathComponent
            items[index].size = size
            items[index].state = .waiting
        case let .failure(error):
            items[index].state = .failed(Self.preparationProblem(error, name: items[index].name))
        }
        pump()
    }

    nonisolated static func preparationProblem(_ error: Error, name: String) -> String {
        switch error as? ChatAttachmentPolicy.Problem {
        case .tooLarge?: "“\(name)” is too large."
        case .unsupported?: "“\(name)” isn’t a picture this device can read."
        case .unreadable?: "“\(name)” couldn’t be read."
        case nil: "“\(name)” couldn’t be read. \(error.localizedDescription)"
        }
    }

    /// Copies a picked file into `destination` under its own name, coordinating the read.
    nonisolated static func copy(_ source: URL, into destination: URL) throws -> (URL, Int64) {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let target = destination.appending(path: ChatAttachmentPolicy.sanitizedName(source.lastPathComponent))
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: source, options: .withoutChanges, error: &coordinationError) { readable in
            do {
                let values = try readable.resourceValues(forKeys: [.isRegularFileKey])
                guard values.isRegularFile == true else { throw CocoaError(.fileReadUnsupportedScheme) }
                try FileManager.default.copyItem(at: readable, to: target)
            } catch { copyError = error }
        }
        if let error = coordinationError ?? copyError { throw error }
        let size = (try target.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        return (target, size)
    }

    nonisolated static func write(_ data: Data, named name: String, into destination: URL) throws -> (URL, Int64) {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let target = destination.appending(path: name)
        try data.write(to: target, options: .completeFileProtection)
        return (target, Int64(data.count))
    }

    // MARK: Sending

    /// Starts waiting uploads while fewer than two are going.
    private func pump() {
        while items.filter({ if case .sending = $0.state { return true } else { return false } }).count < Self.concurrentUploads,
              let next = items.first(where: { $0.state == .waiting }) {
            send(next.id)
        }
    }

    private func send(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), let file = items[index].file,
              let session, let workspace = session.workspace else { return }
        guard workspace.reachable, let client = workspace.client else {
            items[index].state = .failed("You’re offline, so it wasn’t uploaded.")
            return
        }
        let target = items[index].targetPath
        let projectID = session.projectID
        let hostID = workspace.hostID
        items[index].state = .sending(fraction: 0)
        tasks[id] = Task { [weak self] in
            let outcome = await client.uploadFile(projectID: projectID, path: target, from: file) { sent, total in
                Task { @MainActor in self?.progress(id, sent: sent, total: total) }
            }
            self?.finish(id, outcome: outcome, hostID: hostID)
        }
    }

    private func progress(_ id: UUID, sent: Int64, total: Int64) {
        guard let index = items.firstIndex(where: { $0.id == id }), case let .sending(old) = items[index].state, total > 0 else { return }
        let fraction = min(1, max(0, Double(sent) / Double(total)))
        // Whole percents only, so a large file doesn't redraw the list thousands of times.
        if fraction - old >= 0.01 || (fraction == 1 && old < 1) { items[index].state = .sending(fraction: fraction) }
    }

    private func finish(_ id: UUID, outcome: FileChangeOutcome<FileEntry>, hostID: String?) {
        tasks[id] = nil
        defer { pump() }
        guard let session, session.stillCurrent(hostID), let index = items.firstIndex(where: { $0.id == id }) else { return }
        if canceled.remove(id) != nil {
            items[index].state = .canceled
            discardCopy(index)
            Task { await session.refreshVisibleTree() }
            return
        }
        switch outcome {
        case let .done(entry):
            items[index].state = .done(entry)
            discardCopy(index)
            completed &+= 1
            session.noteConfirmedChange()
            let doneID = id
            Task {
                // A finished upload leaves the list after a moment; the file is in the folder.
                try? await Task.sleep(for: .seconds(3))
                self.removeIfDone(doneID)
            }
        case let .nameTaken(suggestion):
            items[index].state = .nameTaken(suggestedName: suggestion)
            if conflict == nil { conflict = items[index] }
        case let .failed(error):
            items[index].state = .failed(error.localizedDescription)
        case .uncertain:
            items[index].state = .notConfirmed
        }
        Task { await session.refreshVisibleTree() }
    }

    private func removeIfDone(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), case .done = items[index].state else { return }
        items.remove(at: index)
    }

    // MARK: The person's choices

    /// Keep Both: the upload again, under the host's free name.
    public func keepBoth(_ id: UUID) {
        conflict = nil
        guard let index = items.firstIndex(where: { $0.id == id }), case let .nameTaken(suggestion?) = items[index].state else {
            showNextConflict()
            return
        }
        items[index].name = suggestion
        items[index].state = .waiting
        pump()
        showNextConflict()
    }

    /// Replace: the item already there goes to the Trash on the host, then the upload goes again under
    /// the same name. Offered only where the host has a Trash.
    public func replace(_ id: UUID) async {
        conflict = nil
        guard let session, let index = items.firstIndex(where: { $0.id == id }), case .nameTaken = items[index].state else {
            showNextConflict()
            return
        }
        guard let (client, hostID) = session.changeClient() else {
            items[index].state = .failed("You’re offline, so it wasn’t uploaded.")
            showNextConflict()
            return
        }
        let target = items[index].targetPath
        let name = items[index].name
        items[index].state = .preparing
        let outcome = await client.deleteFile(projectID: session.projectID, path: target)
        guard session.stillCurrent(hostID), let current = items.firstIndex(where: { $0.id == id }) else { return }
        switch outcome {
        case .trashed, .deleted:
            items[current].state = .waiting
            pump()
        case .trashUnavailable:
            items[current].state = .failed("The existing “\(name)” can’t be moved to the Trash, so it wasn’t replaced.")
        case let .failed(error):
            items[current].state = .failed("The existing “\(name)” wasn’t replaced. \(error.localizedDescription)")
        case .uncertain:
            items[current].state = .notConfirmed
            Task { await session.refreshVisibleTree() }
        }
        showNextConflict()
    }

    /// Leaves the item on the host as it is and drops this upload.
    public func skip(_ id: UUID) {
        conflict = nil
        remove(id)
        showNextConflict()
    }

    private func showNextConflict() {
        guard conflict == nil else { return }
        conflict = items.first { if case .nameTaken = $0.state { return true } else { return false } }
    }

    /// Stops an upload. One that already reached the host stays there; the folder is read again.
    public func cancel(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        switch items[index].state {
        case .sending:
            canceled.insert(id)
            tasks[id]?.cancel()
        case .preparing, .waiting:
            items[index].state = .canceled
            discardCopy(index)
            pump()
        default:
            break
        }
    }

    /// Sends a failed or unconfirmed upload again, because the person asked.
    public func uploadAgain(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].file != nil else { return }
        switch items[index].state {
        case .failed, .notConfirmed:
            items[index].state = .waiting
            pump()
        default:
            break
        }
    }

    /// Removes a finished, failed or canceled upload from the list.
    public func remove(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), !items[index].isActive || items[index].state == .preparing else { return }
        discardCopy(index)
        items.remove(at: index)
    }

    /// Clears everything that is no longer going.
    public func clearFinished() {
        for item in items where !item.isActive { remove(item.id) }
    }

    private func discardCopy(_ index: Int) {
        guard let file = items[index].file else { return }
        items[index].file = nil
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    /// The tab closed or the host changed: uploads stop and their copies go.
    func end() {
        for task in tasks.values { task.cancel() }
        tasks = [:]
        items = []
        conflict = nil
        try? FileManager.default.removeItem(at: folder)
    }
}
