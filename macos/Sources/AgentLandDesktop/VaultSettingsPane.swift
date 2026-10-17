import AppKit
import Darwin
import SwiftUI
import AgentLandCore
import AgentLandDesign
import AgentLandWorkspace

/// Settings → Vault (docs/HOST-API.md "Vault"): the switch, the folder (Change…, Show in Finder, Open in Obsidian when
/// Obsidian is installed, Use Default Folder), terminal transcripts, and the writer's status with Try Again, Use This
/// Folder Anyway and Rebuild. Everything goes through `WorkspaceModel.vault` (`VaultModel`) on this Mac's own session,
/// the one session the host lists `capabilities.vault` for; while the host isn't connected the pane shows the status
/// as last read and nothing changes. A plain success shows only in the rows; a change that didn't happen is the
/// system's alert, and a state (not connected, a read that failed) a line in place.
struct VaultSettingsPane: View {
    @Environment(WorkspaceModel.self) private var workspace
    /// The Obsidian app, when it is installed; read when the pane appears.
    @State private var obsidianApp: URL?
    /// A chosen folder inside an Obsidian vault, waiting for the person to say which folder the vault takes.
    @State private var obsidianOffer: VaultFolderChoice.Offer?
    /// The chosen folder is being checked (`VaultFolderChoice.probe`) before it goes to the host.
    @State private var probing = false
    @State private var confirmingRebuild = false
    @State private var confirmingAdopt = false

    private var vault: VaultModel { workspace.vault }

    var body: some View {
        content
            // Read now and every 2 s while the pane shows, again after each reconnect, and once the host lists the
            // vault: its capabilities can arrive after the pane shows (the pane open while the host starts).
            .task(id: vault.readKey) { await vault.follow() }
            .onAppear { obsidianApp = NSWorkspace.shared.urlForApplication(withBundleIdentifier: ObsidianLink.bundleIdentifier) }
            .macSettingsNoticeAlert(vault.notice) { vault.notice = nil }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if !vault.isAvailable {
            unavailable {
                ContentUnavailableView("The Vault Isn’t Available", systemImage: "books.vertical",
                                       description: Text("\(workspace.hostName) offers the vault while it runs and keeps its archive."))
            }
        } else if let status = vault.status {
            form(status)
        } else if let issue = vault.loadIssue {
            unavailable {
                ContentUnavailableView {
                    Label("Couldn’t Read the Vault", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(issue)
                } actions: {
                    Button("Try Again") { Task { await vault.refresh() } }
                }
            }
        } else if !vault.canChange {
            unavailable {
                ContentUnavailableView("\(workspace.hostName) Isn’t Connected", systemImage: "wifi.exclamationmark",
                                       description: Text("The vault’s settings show here once it’s connected."))
            }
        } else {
            unavailable { ProgressView("Loading the Vault") }
        }
    }

    /// A state in the pane's place, as tall as a short pane.
    private func unavailable<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content().frame(maxWidth: .infinity).frame(height: 240)
    }

    private var controlsEnabled: Bool { vault.canChange && !vault.isChanging && !probing }

    private func form(_ status: VaultStatus) -> some View {
        Form {
            states
            Section {
                LabeledContent("Vault:") {
                    Toggle(isOn: Binding(get: { vault.enabled }, set: { value in Task { await vault.setEnabled(value) } })) {
                        Text(VaultText.switchTitle)
                        Text(VaultText.switchDetail(enabled: vault.enabled, terminals: vault.terminals))
                    }
                    .disabled(!controlsEnabled)
                    .accessibilityIdentifier("vaultEnabled")
                }
                Toggle(isOn: Binding(get: { vault.terminals }, set: { value in Task { await vault.setTerminals(value) } })) {
                    Text(VaultText.terminalsTitle)
                    Text(VaultText.terminalsDetail)
                }
                .disabled(!controlsEnabled)
                .accessibilityIdentifier("vaultTerminals")
                MacSettingsFootnote(VaultText.footer)
            }
            folderSection(status)
            if status.enabled || status.state != .off {
                statusSection(status)
            }
        }
        .formStyle(.columns)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("vaultSettings")
    }

    /// The host not answering, and a read that failed after one that worked.
    @ViewBuilder private var states: some View {
        if !vault.canChange {
            MacSettingsStateLine("\(workspace.hostName) isn’t connected. The vault can’t be changed until it is.", systemImage: "wifi.exclamationmark")
                .accessibilityIdentifier("vaultOffline")
        } else if let issue = vault.loadIssue {
            HStack(alignment: .firstTextBaseline) {
                MacSettingsStateLine("Couldn’t read the vault’s status again. \(issue)")
                    .accessibilityIdentifier("vaultReadIssue")
                Spacer()
                Button("Try Again") { Task { await vault.refresh() } }
                    .controlSize(.small)
                    .accessibilityIdentifier("vaultRetry")
            }
        }
    }

    // MARK: Folder

    private func folderSection(_ status: VaultStatus) -> some View {
        let folder = vault.folder
        return Section {
            LabeledContent("Folder:") {
                Text(VaultText.folderLine(folder))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(folder)
                    .accessibilityLabel("Folder")
                    .accessibilityValue(VaultText.folderLine(folder))
                    .accessibilityIdentifier("vaultFolder")
            }
            .macSettingsGroupStart()
            HStack(spacing: 8) {
                Button("Change…") { chooseFolder() }
                    .disabled(!controlsEnabled)
                    .accessibilityIdentifier("vaultChangeFolder")
                    .confirmationDialog(obsidianOffer.map(VaultText.offerTitle) ?? "", isPresented: offerShown,
                                        titleVisibility: .visible, presenting: obsidianOffer) { offer in
                        Button(VaultText.useSuggested(offer)) { use(offer.suggested) }
                            .keyboardShortcut(.defaultAction)
                        Button(VaultText.useChosen(offer)) { use(offer.chosen) }
                        Button("Cancel", role: .cancel) {}
                    } message: { offer in
                        Text(VaultText.offerMessage(offer))
                    }
                Button("Show in Finder") { showInFinder(folder) }
                    .disabled(folder.isEmpty)
                    .accessibilityIdentifier("vaultShowInFinder")
                if let obsidianApp {
                    Button("Open in Obsidian") { openInObsidian(folder, app: obsidianApp, obsidianVault: status.obsidianVault) }
                        .disabled(folder.isEmpty || vault.isChanging)
                        .accessibilityIdentifier("vaultOpenInObsidian")
                }
                if probing || vault.changing.map(Self.isFolderChange) == true {
                    ProgressView().controlSize(.small).accessibilityLabel("Changing the folder")
                }
            }
            if !status.defaultFolder.isEmpty, status.folder != status.defaultFolder {
                Button("Use Default Folder (\(VaultText.folderLine(status.defaultFolder)))") { Task { await vault.useDefaultFolder() } }
                    .disabled(!controlsEnabled)
                    .accessibilityIdentifier("vaultUseDefaultFolder")
            }
            MacSettingsFootnote(VaultText.folderFooter)
        }
    }

    private var offerShown: Binding<Bool> {
        Binding(get: { obsidianOffer != nil }, set: { if !$0 { obsidianOffer = nil } })
    }

    private static func isFolderChange(_ change: VaultChange) -> Bool {
        if case .folder = change { return true }
        return false
    }

    /// Change…: the system's folder panel, then the Obsidian offer when the folder is in a vault, then the probe.
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = VaultText.panelMessage
        let current = vault.folder
        if !current.isEmpty, VaultFolderChoice.isDirectory(current) {
            panel.directoryURL = URL(fileURLWithPath: current)
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            switch VaultFolderChoice.resolve(url.path) {
            case let .folder(path): use(path)
            case let .obsidian(offer): obsidianOffer = offer
            }
        }
    }

    /// Writes and removes a file where the vault will be, so a folder-access prompt comes now, while the person
    /// chooses, rather than later for the host; then moves the vault there.
    private func use(_ path: String) {
        obsidianOffer = nil
        guard path != vault.status?.folder else { return }
        probing = true
        Task {
            let problem = await Task.detached(priority: .userInitiated) { VaultFolderChoice.probe(path) }.value
            probing = false
            if let problem {
                vault.notice = WorkspaceNotice(VaultText.probeFailedTitle, message: problem, tone: .error)
                return
            }
            await vault.setFolder(path)
        }
    }

    private func showInFinder(_ folder: String) {
        guard VaultFolderChoice.isDirectory(folder) else { return folderMissing() }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder)])
    }

    /// Opens the folder's Obsidian vault at it when Obsidian knows the vault, else gives Obsidian the folder to open.
    private func openInObsidian(_ folder: String, app: URL, obsidianVault: String?) {
        guard VaultFolderChoice.isDirectory(folder) else { return folderMissing() }
        switch ObsidianLink.opening(folder: folder, knownVaults: ObsidianLink.knownVaults(), obsidianVault: obsidianVault) {
        case let .url(url):
            if !NSWorkspace.shared.open(url) { obsidianDidNotOpen(nil) }
        case let .folder(url):
            let model = vault
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                guard let error else { return }
                let message = error.localizedDescription
                Task { @MainActor in
                    model.notice = WorkspaceNotice(VaultText.obsidianFailedTitle, message: message, tone: .error)
                }
            }
        }
    }

    private func obsidianDidNotOpen(_ message: String?) {
        vault.notice = WorkspaceNotice(VaultText.obsidianFailedTitle, message: message, tone: .error)
    }

    private func folderMissing() {
        vault.notice = WorkspaceNotice(VaultText.folderMissingTitle, message: VaultText.folderMissingMessage(enabled: vault.enabled),
                                       tone: .warning)
    }

    // MARK: Status

    private func statusSection(_ status: VaultStatus) -> some View {
        Section {
            LabeledContent("Status:") {
                HStack(spacing: 6) {
                    MacStatusLight(status: Self.dot(status.state))
                    Text(VaultText.stateLine(status)).textSelection(.enabled)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Status")
                .accessibilityValue(VaultText.stateLine(status))
                .accessibilityIdentifier("vaultStatus")
            }
            .macSettingsGroupStart()
            ForEach(Self.lines(status), id: \.self) { line in
                MacSettingsFootnote(line).textSelection(.enabled)
            }
            HStack(spacing: 8) {
                if status.state == .paused {
                    Button("Try Again") { Task { await vault.tryAgain() } }
                        .disabled(!controlsEnabled)
                        .accessibilityHint("Looks at the folder again now.")
                        .accessibilityIdentifier("vaultTryAgain")
                }
                if status.state == .paused, status.reason == .otherArchive {
                    Button("Use This Folder Anyway…") { confirmingAdopt = true }
                        .disabled(!controlsEnabled)
                        .accessibilityIdentifier("vaultAdopt")
                        .confirmationDialog(VaultText.adoptTitle, isPresented: $confirmingAdopt, titleVisibility: .visible) {
                            Button("Use This Folder") { Task { await vault.adoptFolder() } }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text(VaultText.adoptMessage)
                        }
                }
                if status.enabled {
                    Button("Rebuild…") { confirmingRebuild = true }
                        .disabled(!controlsEnabled)
                        .accessibilityIdentifier("vaultRebuild")
                        .confirmationDialog(VaultText.rebuildTitle, isPresented: $confirmingRebuild, titleVisibility: .visible) {
                            Button("Rebuild") { Task { await vault.rebuild() } }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text(VaultText.rebuildMessage)
                        }
                }
            }
        }
    }

    /// Under the status: what to do about a pause, what is written, notes left alone and the last write.
    private static func lines(_ status: VaultStatus) -> [String] {
        [VaultText.detail(status), VaultText.summary(status), VaultText.skippedLine(status), VaultText.lastWriteLine(status)]
            .compactMap { $0 }
    }

    private static func dot(_ state: VaultState) -> StatusDot.Status {
        switch state {
        case .off, .unknown: .idle
        case .writing: .working
        case .current: .online
        case .paused: .attention
        }
    }
}

// MARK: Choosing the folder

/// Where the vault goes once a folder is chosen in Change…: the folder itself, or, when the folder is an Obsidian vault
/// or inside one (it or a folder above it holds `.obsidian`), the choice between it and a folder of the vault's own in
/// that Obsidian vault, `<vault>/AgentLand`.
enum VaultFolderChoice: Equatable {
    case folder(String)
    case obsidian(Offer)

    /// A folder chosen inside an Obsidian vault.
    struct Offer: Equatable, Identifiable {
        /// The folder the person chose.
        let chosen: String
        /// The Obsidian vault it is in: the chosen folder or the nearest folder above it that holds `.obsidian`.
        let vault: String
        /// `<vault>/AgentLand`.
        let suggested: String
        var id: String { chosen }
    }

    /// The folder AgentLand offers inside an Obsidian vault.
    static let folderName = "AgentLand"

    /// The choice for `chosen` (an absolute path). A folder already `<vault>/AgentLand`, or inside it, is taken as it is.
    /// `.obsidian` counts only as a folder of its own, not a link to one, as the host looks for it.
    static func resolve(_ chosen: String, isFolder: (String) -> Bool = VaultFolderChoice.isFolderNoFollow) -> VaultFolderChoice {
        let chosen = trimmed(chosen)
        guard let vault = obsidianVault(containing: chosen, isFolder: isFolder) else { return .folder(chosen) }
        let suggested = (vault == "/" ? "" : vault) + "/" + folderName
        if chosen == suggested || chosen.hasPrefix(suggested + "/") { return .folder(chosen) }
        return .obsidian(Offer(chosen: chosen, vault: vault, suggested: suggested))
    }

    /// The folder, or the nearest folder above it, that holds a `.obsidian` folder.
    static func obsidianVault(containing folder: String, isFolder: (String) -> Bool) -> String? {
        var current = folder
        while true {
            if isFolder((current == "/" ? "" : current) + "/.obsidian") { return current }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current || parent.isEmpty { return nil }
            current = parent
        }
    }

    /// The path without a trailing slash (the top folder stays "/").
    static func trimmed(_ path: String) -> String {
        var path = path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// `path` is a folder itself, not a link to one.
    nonisolated static func isFolderNoFollow(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    /// `path` is a folder, links followed.
    nonisolated static func isDirectory(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    /// Writes and removes an empty file in `folder`, or in the nearest folder above it that exists while it doesn't
    /// yet (the host makes it), so that macOS asks for access to the folder now if it asks at all. Nil when that worked;
    /// otherwise why not, in words. Never makes a folder.
    nonisolated static func probe(_ folder: String) -> String? {
        var current = trimmed(folder)
        var info = stat()
        while stat(current, &info) != 0 {
            let failure = errno
            guard failure == ENOENT || failure == ENOTDIR else { return describe(errno: failure) }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current || parent.isEmpty { return describe(errno: failure) }
            current = parent
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR else { return "“\(current)” is a file. Choose a folder for the vault." }
        // The host's own temporary names, so a probe a crash left behind in the vault is cleaned up with them.
        let name = ".agentland-tmp-probe-" + UUID().uuidString.prefix(8).lowercased()
        let path = (current == "/" ? "" : current) + "/" + name
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return describe(errno: errno) }
        close(descriptor)
        guard unlink(path) == 0 else { return describe(errno: errno) }
        return nil
    }

    /// A failure in words: macOS's privacy refusal with what to do, anything else as the system says it.
    nonisolated static func describe(errno failure: Int32) -> String {
        if failure == EPERM || failure == EACCES { return VaultText.probePermission }
        return String(cString: strerror(failure)) + "."
    }
}

// MARK: Obsidian

/// How Open in Obsidian opens the vault's folder.
enum ObsidianOpening: Equatable {
    /// `obsidian://open?path=<folder>`: Obsidian knows the vault the folder is in and opens it there.
    case url(URL)
    /// Obsidian is given a folder to open: the Obsidian vault the folder is in, else the folder itself.
    case folder(URL)
}

enum ObsidianLink {
    static let bundleIdentifier = "md.obsidian"

    /// Where Obsidian lists the vaults it knows.
    static var configuration: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/obsidian/obsidian.json")
    }

    /// How to open `folder`. Obsidian knows its vault when `knownVaults` (Obsidian's list) has a vault that is the folder
    /// or a folder above it; without the list, when the host found one (`obsidianVault`).
    static func opening(folder: String, knownVaults: [String]?, obsidianVault: String?) -> ObsidianOpening {
        let folder = VaultFolderChoice.trimmed(folder)
        let known: Bool
        if let knownVaults {
            known = knownVaults.map(VaultFolderChoice.trimmed).contains { folder == $0 || folder.hasPrefix($0 == "/" ? "/" : $0 + "/") }
        } else {
            known = obsidianVault != nil
        }
        if known, let url = openURL(path: folder) { return .url(url) }
        return .folder(URL(fileURLWithPath: obsidianVault ?? folder, isDirectory: true))
    }

    /// `obsidian://open?path=` with the path encoded as a URI component.
    static func openURL(path: String) -> URL? {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard let encoded = path.addingPercentEncoding(withAllowedCharacters: unreserved) else { return nil }
        return URL(string: "obsidian://open?path=" + encoded)
    }

    /// The vaults Obsidian knows, from its `obsidian.json`; nil when it can't be read.
    static func knownVaults(at url: URL = configuration) -> [String]? {
        (try? Data(contentsOf: url)).flatMap(knownVaults(from:))
    }

    /// The `path` of each entry of `vaults` in Obsidian's `obsidian.json`; nil when it isn't that file.
    static func knownVaults(from data: Data) -> [String]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let vaults = json["vaults"] as? [String: Any] else { return nil }
        return vaults.values.compactMap { ($0 as? [String: Any])?["path"] as? String }.filter { $0.hasPrefix("/") }.sorted()
    }
}

// MARK: Words

/// The Mac pane's own words, beside the model's (`VaultText` in AgentLandWorkspace).
extension VaultText {
    static let switchTitle = "Keep a vault of notes"

    /// Under the switch: what it does now.
    static func switchDetail(enabled: Bool, terminals: Bool) -> String {
        guard enabled else { return "Off: nothing is written" }
        return terminals ? "Chats and terminals are written to the folder as Markdown notes"
                         : "Chats are written to the folder as Markdown notes"
    }

    static let terminalsTitle = "Terminal transcripts"
    static let terminalsDetail = "A note for each terminal, with its commands and output"

    static let footer = "A folder of Markdown notes that Obsidian and other notes apps open: one for each chat and terminal, with notes by workspace, by provider and by day. Text you add below a note’s end marker stays. Keys and tokens are masked, but the vault isn’t a secure store."

    static let folderFooter = "Each folder is a vault of its own: a new folder gets every note, and the folder left behind keeps its notes."

    static let panelMessage = "Choose the vault’s folder. In an Obsidian vault, AgentLand can use a folder of its own."

    /// The Obsidian offer's title.
    static func offerTitle(_ offer: VaultFolderChoice.Offer) -> String {
        "Use a folder of its own in “\(name(offer.vault))”?"
    }

    /// The Obsidian offer's message.
    static func offerMessage(_ offer: VaultFolderChoice.Offer) -> String {
        let vault = name(offer.vault)
        if offer.chosen == offer.vault {
            return "“\(vault)” is an Obsidian vault. AgentLand can write its notes in “\(vault)/\(VaultFolderChoice.folderName)”, apart from yours."
        }
        return "“\(name(offer.chosen))” is in the Obsidian vault “\(vault)”. AgentLand can write its notes in “\(vault)/\(VaultFolderChoice.folderName)” instead."
    }

    static func useSuggested(_ offer: VaultFolderChoice.Offer) -> String {
        "Use “\(name(offer.vault))/\(VaultFolderChoice.folderName)”"
    }

    static func useChosen(_ offer: VaultFolderChoice.Offer) -> String {
        "Use “\(name(offer.chosen))”"
    }

    static let probeFailedTitle = "AgentLand can’t write in that folder"
    static let probePermission = "macOS didn’t allow it. Allow AgentLand to use the folder in System Settings → Privacy & Security, or choose another folder."

    static let folderMissingTitle = "The folder isn’t there"
    static func folderMissingMessage(enabled: Bool) -> String {
        enabled ? "Connect the disk it’s on, or choose another folder." : "AgentLand makes it when you turn the vault on."
    }

    static let obsidianFailedTitle = "Obsidian didn’t open"

    static let rebuildTitle = "Write every note again?"
    static let rebuildMessage = "Notes and images deleted from the folder come back. Nothing is deleted, and text below a note’s end marker stays."

    static let adoptTitle = "Use this folder anyway?"
    static let adoptMessage = "Another Mac’s AgentLand writes its notes here. This Mac’s notes go here too, and the other Mac’s vault pauses."

    /// A folder's last name, for the dialogs.
    static func name(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }
}
