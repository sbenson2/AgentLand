import Foundation
import AgentLandCore

// The Files tab's changes: rename, move, new folder, Trash and permanent delete. Each captures the
// host and tab it was made for; a result for a closed tab or another host is dropped. Nothing is
// sent while offline, nothing is sent twice, and every change re-reads the folder, so an
// unconfirmed one shows what the host actually has.
extension FilesSession {
    // MARK: Rename

    public func beginRename(_ entry: FileEntry) {
        renameText = entry.name
        renaming = entry
    }

    public func cancelRename() {
        renaming = nil
        renameText = ""
    }

    /// Renames `entry` in its folder to the typed name.
    public func rename(_ entry: FileEntry, to typed: String) async {
        renaming = nil
        let name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name != entry.name else { return }
        let folder = Self.parent(of: entry.path)
        if let problem = Self.nameProblem(name, in: folder) {
            notice = FilesNotice("“\(entry.name)” wasn’t renamed", message: problem, tone: .warning)
            return
        }
        await moveItem(entry, to: Self.join(folder, name), change: .rename(entry))
    }

    // MARK: Move

    public func beginMove(_ entry: FileEntry) { moving = entry }

    /// Whether `folder` can take `entry`: not where it already is, and never inside itself.
    public func canMove(_ entry: FileEntry, to folder: String) -> Bool {
        guard Self.parent(of: entry.path) != folder else { return false }
        return !(entry.isDirectory && (folder == entry.path || folder.hasPrefix(entry.path + "/")))
    }

    /// Moves `entry` into `folder` (relative to the project; empty for its top), keeping its name.
    public func move(_ entry: FileEntry, toFolder folder: String) async {
        moving = nil
        guard canMove(entry, to: folder) else { return }
        await moveItem(entry, to: Self.join(folder, entry.name), change: .move(entry, folder: folder))
    }

    private func moveItem(_ entry: FileEntry, to target: String, change: FileNameConflict.Change) async {
        guard let (client, hostID) = changeClient() else { return }
        changing.insert(entry.path)
        let outcome = await client.moveFile(projectID: projectID, from: entry.path, to: target)
        changing.remove(entry.path)
        guard stillCurrent(hostID) else { return }
        switch outcome {
        case let .done(moved):
            workspace?.retargetEditorTabs(projectID: projectID, from: entry.path, to: moved.path)
            noteConfirmedChange()
            switch change {
            case .move(_, let folder):
                notice = FilesNotice("Moved “\(moved.name)” to \(folder.isEmpty ? "the workspace folder" : "“\(Self.name(of: folder))”")", tone: .success)
            default:
                notice = FilesNotice("Renamed to “\(moved.name)”", tone: .success)
            }
        case let .nameTaken(suggestion):
            nameConflict = FileNameConflict(change: change, name: Self.name(of: target), suggestedName: suggestion)
        case let .failed(error):
            notice = FilesNotice(isMove(change) ? "“\(entry.name)” wasn’t moved" : "“\(entry.name)” wasn’t renamed",
                                 message: error.localizedDescription, tone: .error)
        case .uncertain:
            notice = FilesNotice(isMove(change) ? "Move not confirmed" : "Rename not confirmed",
                                 message: "The connection ended before your Mac answered. The folder was read again; check it before trying again.",
                                 tone: .warning)
        }
        await refreshVisibleTree()
    }

    private func isMove(_ change: FileNameConflict.Change) -> Bool {
        if case .move = change { return true }
        return false
    }

    // MARK: New folder

    public func beginNewFolder() {
        newFolderName = "New Folder"
        creatingFolder = true
    }

    /// Makes a folder named `typed` in the folder shown.
    public func makeFolder(named typed: String) async {
        creatingFolder = false
        let name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        let parent = path
        if let problem = Self.nameProblem(name, in: parent) {
            notice = FilesNotice("The folder wasn’t made", message: problem, tone: .warning)
            return
        }
        guard let (client, hostID) = changeClient() else { return }
        let target = Self.join(parent, name)
        changing.insert(target)
        let outcome = await client.makeFolder(projectID: projectID, path: target)
        changing.remove(target)
        guard stillCurrent(hostID) else { return }
        switch outcome {
        case let .done(folder):
            noteConfirmedChange()
            notice = FilesNotice("Made “\(folder.name)”", tone: .success)
        case let .nameTaken(suggestion):
            nameConflict = FileNameConflict(change: .newFolder(parent: parent), name: name, suggestedName: suggestion)
        case let .failed(error):
            notice = FilesNotice("The folder wasn’t made", message: error.localizedDescription, tone: .error)
        case .uncertain:
            notice = FilesNotice("New folder not confirmed",
                                 message: "The connection ended before your Mac answered. The folder was read again; check it before trying again.",
                                 tone: .warning)
        }
        await refreshVisibleTree()
    }

    // MARK: Name conflicts

    /// Keep Both: the change again, with the host's free name. The dialog passes the conflict it
    /// shows: dismissing it clears `nameConflict` before its button's action runs.
    public func keepBoth(_ conflict: FileNameConflict) async {
        nameConflict = nil
        guard let suggested = conflict.suggestedName else { return }
        switch conflict.change {
        case let .rename(entry):
            await moveItem(entry, to: Self.join(Self.parent(of: entry.path), suggested), change: conflict.change)
        case let .move(entry, folder):
            await moveItem(entry, to: Self.join(folder, suggested), change: conflict.change)
        case let .newFolder(parent):
            guard parent == path else { return }
            await makeFolder(named: suggested)
        }
    }

    // MARK: Trash and delete

    /// Items can go to the Trash (macOS hosts), or at least be deleted for good.
    public var canDelete: Bool { supports(.trash) || supports(.delete) }

    /// Asks first: Move to Trash where the host has one, otherwise Delete Permanently, which names the path.
    public func requestDelete(_ entry: FileEntry) {
        if supports(.trash) {
            pendingTrash = entry
        } else if supports(.delete) {
            pendingPermanentDelete = entry
        }
    }

    /// Moves the confirmed item to the Trash. An item the host can't move there (another volume) asks
    /// again, for a permanent delete that names its path. The dialog passes the item it shows:
    /// dismissing it clears `pendingTrash` before its button's action runs.
    public func confirmTrash(_ entry: FileEntry) async {
        pendingTrash = nil
        guard let (client, hostID) = changeClient() else { return }
        changing.insert(entry.path)
        let outcome = await client.deleteFile(projectID: projectID, path: entry.path)
        changing.remove(entry.path)
        guard stillCurrent(hostID) else { return }
        switch outcome {
        case let .trashed(trashName):
            noteConfirmedChange()
            let renamed = trashName.flatMap { $0 == entry.name ? nil : $0 }
            notice = FilesNotice("Moved “\(entry.name)” to the Trash",
                                 message: renamed.map { "It’s in the Trash on your Mac as “\($0)”." }, tone: .success)
        case .deleted:
            noteConfirmedChange()
            notice = FilesNotice("Deleted “\(entry.name)”", tone: .success)
        case let .trashUnavailable(permanentDeleteAllowed):
            if permanentDeleteAllowed && supports(.delete) {
                pendingPermanentDelete = entry
            } else {
                notice = FilesNotice("“\(entry.name)” can’t be moved to the Trash", message: "Nothing was deleted.", tone: .warning)
            }
        case let .failed(error):
            notice = FilesNotice("“\(entry.name)” wasn’t moved to the Trash", message: error.localizedDescription, tone: .error)
        case .uncertain:
            notice = FilesNotice("Not confirmed",
                                 message: "The connection ended before your Mac answered. The folder was read again; check it before trying again.",
                                 tone: .warning)
        }
        await refreshVisibleTree()
    }

    /// Deletes the confirmed item for good, repeating its path as the host requires.
    public func confirmPermanentDelete(_ entry: FileEntry) async {
        pendingPermanentDelete = nil
        guard let (client, hostID) = changeClient() else { return }
        changing.insert(entry.path)
        let outcome = await client.deleteFile(projectID: projectID, path: entry.path, permanent: true)
        changing.remove(entry.path)
        guard stillCurrent(hostID) else { return }
        switch outcome {
        case .deleted, .trashed:
            noteConfirmedChange()
            notice = FilesNotice("Deleted “\(entry.name)”", tone: .success)
        case .trashUnavailable:
            notice = FilesNotice("“\(entry.name)” wasn’t deleted", tone: .error)
        case let .failed(error):
            notice = FilesNotice("“\(entry.name)” wasn’t deleted", message: error.localizedDescription, tone: .error)
        case .uncertain:
            notice = FilesNotice("Delete not confirmed",
                                 message: "The connection ended before your Mac answered. The folder was read again; check it before trying again.",
                                 tone: .warning)
        }
        await refreshVisibleTree()
    }

    // MARK: Content search results

    /// Opens a content search result in the editor at its line.
    public func openMatch(path: String, line: Int) {
        workspace?.openFile(projectID: projectID, path: path, line: line)
    }
}
