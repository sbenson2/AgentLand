import Foundation
import Observation
import AgentLandCore

/// A line of an editor tab's file to show, once.
public struct EditorLineRequest: Equatable, Sendable {
    public let id: UUID
    /// Counted from 1.
    public let line: Int

    public init(line: Int) {
        id = UUID()
        self.line = line
    }
}

/// An editor tab's document: the text being edited, the revision it was loaded at, and the draft
/// kept with the revision it was based on. UIKit owns the live text within `documentGeneration`;
/// only a completed load or reload starts a new generation.
@MainActor @Observable public final class EditorSession: WorkspaceSession {
    public let tabID: UUID
    public let projectID: String
    public let path: String

    /// The text in the editor.
    public var content = ""
    /// The host revision the text was loaded at, or the draft's base revision.
    public private(set) var revision = ""
    /// The host's text at `revision`.
    public private(set) var original = ""
    public private(set) var loading = true
    public private(set) var saving = false
    public var issue: String?
    /// The draft and the host's file both changed since the draft's base revision. Nothing settles it
    /// but the person's confirmed choice: the Mac's version (the draft is thrown away) or theirs (saved over
    /// the Mac's current file). Copy keeps the draft at hand either way.
    public private(set) var conflicted = false
    public private(set) var isNewFile = false
    /// Changes only when a load or reload completes.
    public private(set) var documentGeneration = UUID()
    /// Set after a save the host confirmed; the view plays the success haptic when it changes.
    public private(set) var savedCount = 0
    /// A line to show and select once the document is on screen, as a content search result asks.
    public private(set) var lineRequest: EditorLineRequest?
    /// The line the caret is on, once the file was opened at a line or the person moved the caret.
    public private(set) var caretLine: Int?

    @ObservationIgnored private weak var workspace: WorkspaceModel?
    @ObservationIgnored private var draftSaveTask: Task<Void, Never>?
    @ObservationIgnored private var firstLoadResolved = false
    @ObservationIgnored private var resolvedRefreshGeneration: UUID?
    /// The last read failed (offline, the host unavailable, an error): the next connection epoch reads it again.
    public private(set) var loadFailed = false
    @ObservationIgnored private var resolvedConnectionEpoch: Int?

    public init(tab: WorkspaceTab, workspace: WorkspaceModel) {
        tabID = tab.id
        projectID = tab.projectID
        path = tab.resourceID
        self.workspace = workspace
    }

    public var edited: Bool { content != original }
    public var canSave: Bool { !loading && !saving && (content != original || isNewFile) }

    /// Shows `line` (counted from 1) and puts the caret at its start once the text is on screen.
    public func reveal(line: Int) {
        let line = max(1, line)
        lineRequest = EditorLineRequest(line: line)
        caretLine = line
    }

    /// The editor showed the request; a rebuilt view does not move the caret back to it.
    public func lineRequestShown(_ id: UUID) {
        if lineRequest?.id == id { lineRequest = nil }
    }

    /// The caret moved to `line`.
    public func noteCaretLine(_ line: Int) {
        if caretLine != line { caretLine = line }
    }

    public func end() {
        draftSaveTask?.cancel()
        draftSaveTask = nil
    }

    /// Loads the document unless this refresh generation already resolved, so a rebuilt view does
    /// not reload it.
    public func loadIfNeeded() async {
        guard let workspace else { return }
        // A read that failed is read again once the host has come back (a new connection epoch), also when the
        // editor was not on screen at that moment to see it come back.
        let failedBeforeRecovery = loadFailed && resolvedConnectionEpoch != workspace.connectionEpoch
        if firstLoadResolved && !loading && resolvedRefreshGeneration == workspace.tabRefreshGeneration[tabID],
           !failedBeforeRecovery {
            reportPresentationIfReady()
            return
        }
        await load()
    }

    public func load() async {
        guard let workspace else { return }
        let refreshGeneration = workspace.tabRefreshGeneration[tabID]
        // Offline, the read is not sent to wait out its timeout: the editor says so at once and reads the file
        // with the next connection epoch.
        guard workspace.reachable, let client = workspace.client else {
            loading = false
            issue = workspace.client == nil ? "The host is unavailable." : Self.offlineLoad
            loadFailed = true
            firstLoadResolved = true
            resolvedRefreshGeneration = refreshGeneration
            resolvedConnectionEpoch = workspace.connectionEpoch
            reportPresentationIfReady()
            return
        }
        let hostID = workspace.hostID
        let connectionEpoch = workspace.connectionEpoch
        if content != original && !loading { flushDraft() }
        loading = true
        issue = nil
        loadFailed = false
        defer {
            if workspace.isCurrent(hostID: hostID, tabID: tabID),
               workspace.tabRefreshGeneration[tabID] == refreshGeneration {
                loading = false
                if !Task.isCancelled {
                    firstLoadResolved = true
                    resolvedRefreshGeneration = refreshGeneration
                    resolvedConnectionEpoch = connectionEpoch
                    reportPresentationIfReady()
                }
            }
        }

        do {
            let file = try await client.file(projectID: projectID, path: path)
            guard !Task.isCancelled,
                  workspace.isCurrent(hostID: hostID, tabID: tabID),
                  workspace.tabRefreshGeneration[tabID] == refreshGeneration else { return }
            original = file.content
            revision = file.revision
            isNewFile = false
            if let savedTab = workspace.tab(tabID), savedTab.editorDirty {
                content = savedTab.draft
                revision = EditorRevisionPolicy.saveRevision(for: savedTab, remoteRevision: file.revision)
                if EditorRevisionPolicy.remoteChanged(since: savedTab, remoteRevision: file.revision) {
                    conflicted = true
                    issue = Self.conflictSinceDraft
                }
            } else {
                content = file.content
                conflicted = false
            }
            documentGeneration = UUID()
        } catch let error as ClientError {
            guard !Task.isCancelled,
                  workspace.isCurrent(hostID: hostID, tabID: tabID),
                  workspace.tabRefreshGeneration[tabID] == refreshGeneration else { return }
            if case let .server(code, _) = error, code == "file_not_found" {
                isNewFile = true
                original = ""
                revision = ""
                if let savedTab = workspace.tab(tabID), savedTab.editorDirty {
                    content = savedTab.draft
                } else {
                    content = ""
                }
                documentGeneration = UUID()
                issue = "This file does not exist yet. Save to create it."
            } else {
                issue = error.localizedDescription
                loadFailed = true
            }
        } catch {
            guard !Task.isCancelled,
                  workspace.isCurrent(hostID: hostID, tabID: tabID),
                  workspace.tabRefreshGeneration[tabID] == refreshGeneration else { return }
            issue = error.localizedDescription
            loadFailed = true
        }
    }

    /// Readiness for the current opening, once this refresh generation resolved.
    public func reportPresentationIfReady() {
        guard let workspace, firstLoadResolved, !loading,
              resolvedRefreshGeneration == workspace.tabRefreshGeneration[tabID],
              let ticket = workspace.presentationRequest(for: tabID) else { return }
        workspace.reportPresentationReady(ticket)
    }

    /// The text changed: note it at once for close confirmation, and save the draft shortly after.
    public func scheduleDraftSave(_ value: String) {
        draftSaveTask?.cancel()
        guard !loading, let workspace else { return }
        let hostID = workspace.hostID
        let baseline = original
        let baseRevision = revision
        workspace.noteEditorEdit(tabID, value, dirty: value != baseline, baseRevision: baseRevision)
        draftSaveTask = Task { @MainActor [weak self, weak workspace] in
            try? await Task.sleep(for: .milliseconds(700))
            guard let self, let workspace, !Task.isCancelled,
                  self.content == value,
                  workspace.isCurrent(hostID: hostID, tabID: self.tabID) else { return }
            workspace.updateEditorDraft(self.tabID, value, dirty: value != baseline, baseRevision: baseRevision)
        }
    }

    /// Saves the draft with the revision it was based on now, as on leaving the tab or the app.
    public func flushDraft() {
        draftSaveTask?.cancel()
        draftSaveTask = nil
        guard !loading, let workspace, workspace.tab(tabID) != nil else { return }
        workspace.updateEditorDraft(tabID, content, dirty: content != original, baseRevision: revision)
    }

    static let conflictOnSave = "The file changed on the Mac while you edited it. Your edits are kept until you choose: use the Mac's version, or save yours over it."
    static let conflictSinceDraft = "The file changed on the Mac since this draft began. Your draft is kept until you choose: use the Mac's version, or save yours over it."
    /// A save asked for while the host can't be reached: refused at once and said in place, never sent later.
    static let offlineSave = "You’re offline, so the file wasn’t saved. Your edits are kept."
    /// A read asked for while the host can't be reached: said at once, and read again when the host is back.
    static let offlineLoad = "You’re offline. The file opens once the host is back."

    /// The person chose the Mac's version (and confirmed it): the draft is thrown away and the host's
    /// current file opens.
    public func useHostVersion() async {
        guard let workspace else { return }
        draftSaveTask?.cancel()
        draftSaveTask = nil
        conflicted = false
        workspace.updateEditorDraft(tabID, "", dirty: false, baseRevision: "")
        // Nothing of the draft is left for the load to keep.
        content = original
        await load()
    }

    /// The person chose to save their version over the Mac's (and confirmed that it replaces the Mac's
    /// changes): the draft is saved against the host's current revision. A change on the Mac after that read
    /// conflicts again, so nothing is replaced that the person has not been shown.
    public func saveMineAnyway() async {
        guard let workspace else { return }
        guard workspace.reachable, let client = workspace.client else {
            issue = Self.offlineSave
            return
        }
        let hostID = workspace.hostID
        do {
            let current = try await client.file(projectID: projectID, path: path)
            guard workspace.isCurrent(hostID: hostID, tabID: tabID) else { return }
            revision = current.revision
            original = current.content
            isNewFile = false
        } catch let error as ClientError {
            guard workspace.isCurrent(hostID: hostID, tabID: tabID) else { return }
            if case let .server(code, _) = error, code == "file_not_found" {
                // The Mac removed the file: saving makes it again.
                revision = ""
                original = ""
                isNewFile = true
            } else {
                issue = error.localizedDescription
                return
            }
        } catch {
            if workspace.isCurrent(hostID: hostID, tabID: tabID) { issue = error.localizedDescription }
            return
        }
        await save()
    }

    public func save() async {
        guard let workspace else { return }
        guard workspace.reachable, let client = workspace.client else {
            issue = Self.offlineSave
            return
        }
        let hostID = workspace.hostID
        guard Data(content.utf8).count <= 1_048_576 else {
            issue = "Files must be 1 MiB or smaller."
            return
        }
        flushDraft()
        saving = true
        defer { saving = false }
        let submitted = content

        switch await client.saveFile(projectID: projectID, path: path, content: submitted, revision: revision) {
        case .success(let file):
            guard workspace.isCurrent(hostID: hostID, tabID: tabID) else { return }
            draftSaveTask?.cancel()
            revision = file.revision
            original = submitted
            isNewFile = false
            issue = nil
            conflicted = false
            savedCount &+= 1
            workspace.updateEditorDraft(tabID, content == submitted ? "" : content,
                                        dirty: content != submitted, baseRevision: file.revision)
        case .failure(.conflict):
            if workspace.isCurrent(hostID: hostID, tabID: tabID) {
                conflicted = true
                issue = Self.conflictOnSave
            }
        case .failure(.uncertain):
            if workspace.isCurrent(hostID: hostID, tabID: tabID) {
                issue = "Save could not be confirmed. Check the host file before saving again. Your edits are kept."
            }
        case .failure(.client(let error)):
            if workspace.isCurrent(hostID: hostID, tabID: tabID) {
                issue = error.localizedDescription
            }
        }
    }
}
