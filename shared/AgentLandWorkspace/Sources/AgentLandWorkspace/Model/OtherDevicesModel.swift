import Foundation
import Observation
import AgentLandCore

/// One running terminal of another device, or of the Mac, as "On <device>" lists it.
public struct OtherTerminalRow: Identifiable, Equatable {
    public let id: String
    /// What runs in it, named as its tab is (`RemoteTerminal.displayTitle`): its task, else the program's title without
    /// its spinner, else the program's name.
    let title: String
    /// "Claude Code · Alpha": the program and its workspace, or its folder outside any.
    let subtitle: String
    /// "Working", "Waiting for you", "Quiet · 5m".
    let status: String
    /// The program it was opened with, for its icon.
    let programID: String
    let terminal: SharedTerminal
}

/// One device's running terminals: "On Sam's iPad", "On Mac mini".
public struct OtherDeviceSection: Identifiable, Equatable {
    /// The device's ID on the host.
    public let id: String
    let title: String
    /// The SF Symbol of the device: `desktopcomputer`, `ipad` or `iphone`.
    let glyph: String
    let rows: [OtherTerminalRow]
}

/// "On <device>" on the Workspace tab (iPhone) and Home (iPad): the terminals open on the owner's other devices and
/// on the Mac (a coding agent typed in Terminal.app, a terminal of the Mac's web app), as `GET /v1/terminals/others`
/// lists them for hosts that list `shared` in `terminalFeatures` (owner, 2026-10-15: "think safari open tabs from
/// another device"). One model for as long as its workspace model; it follows the attached host.
@Observable @MainActor public final class OtherDevicesModel {
    public private(set) var sections: [OtherDeviceSection] = []

    @ObservationIgnored weak var workspace: WorkspaceModel?
    /// Reads started, and the newest whose answer applied: an older read that answers later never undoes a newer one.
    @ObservationIgnored private var reads = 0
    /// Workspace IDs the host's list named that this device's projects did not hold, which one projects read has been
    /// made for: a workspace added on another device since this device last read the projects. Once each, per host.
    @ObservationIgnored private var unknownProjectsRead = Set<String>()

    init() {}

    /// Reads the host's list again. Nothing is asked of a host that does not share its terminals, and its sections go
    /// (a read already on its way then no longer applies); a failed read keeps the last list, which the next read
    /// replaces. An answer for another host is dropped. Nothing is read under the lock (the list stays mounted beneath
    /// it) or while the host doesn't answer: the list keeps what it showed, and the next read after goes.
    public func refresh() async {
        guard let workspace, let client = workspace.client else { return }
        guard workspace.capabilities?.sharesTerminals == true else {
            reads += 1
            sections = []
            return
        }
        guard workspace.reachable, !workspace.locked else { return }
        reads += 1
        let read = reads
        let hostID = workspace.hostID
        let asked = Date()
        guard let terminals = try? await client.otherTerminals(),
              read == reads, workspace.hostID == hostID, workspace.client === client else { return }
        let capabilities = workspace.capabilities
        sections = Self.sections(from: terminals, hostName: workspace.hostName, ownDeviceID: workspace.identity?.deviceID,
                                 programName: { TerminalProgram.named($0, by: capabilities).displayName }, now: Date())
        // The tabs and standalone screens that follow these terminals take the same names as their rows.
        workspace.followSharedTerminals(terminals, asked: asked)
        await readProjectsForUnknownWorkspaces(in: terminals, read: read, hostID: hostID, client: client)
    }

    /// A row naming a workspace this device has not read yet would open the "isn't a workspace" screen: the projects
    /// are read once for each such ID (not on every 4 s read), and a read that has been overtaken or whose host went
    /// changes nothing (`refreshProjects` guards its own attachment).
    private func readProjectsForUnknownWorkspaces(in terminals: [SharedTerminal], read: Int, hostID: String?, client: APIClient) async {
        guard let workspace, read == reads, workspace.hostID == hostID, workspace.client === client else { return }
        let known = Set(workspace.projects.map(\.id))
        let unknown = Set(terminals.compactMap(\.projectID)).subtracting(known).subtracting(unknownProjectsRead)
        guard !unknown.isEmpty else { return }
        unknownProjectsRead.formUnion(unknown)
        await workspace.refreshProjects()
    }

    /// Everything goes with the host.
    func reset() {
        reads += 1
        unknownProjectsRead = []
        sections = []
    }

    // MARK: Rows

    /// The terminals grouped by device, the device active most recently first, and each device's rows newest first.
    /// This device's own (`ownDeviceID`) are left out; no terminals, no sections.
    static func sections(from terminals: [SharedTerminal], hostName: String, ownDeviceID: String?,
                         programName: (String) -> String, now: Date) -> [OtherDeviceSection] {
        let listed = terminals.filter { ownDeviceID == nil || $0.deviceID != ownDeviceID }.sorted(by: newestFirst)
        var order: [String] = []
        var byDevice: [String: [SharedTerminal]] = [:]
        for terminal in listed {
            if byDevice[terminal.deviceID] == nil { order.append(terminal.deviceID) }
            byDevice[terminal.deviceID, default: []].append(terminal)
        }
        // `listed` is newest first, so each device first appears with its newest terminal.
        return order.compactMap { device in
            guard let terminals = byDevice[device], let first = terminals.first else { return nil }
            let rows = terminals.map { terminal in
                let program = programName(terminal.program)
                return OtherTerminalRow(id: terminal.id,
                                        title: rowTitle(programTitle: terminal.programTitle, contextTitle: terminal.contextTitle,
                                                        programName: program),
                                        subtitle: subtitle(terminal, programName: program),
                                        status: statusText(terminal, now: now), programID: terminal.program, terminal: terminal)
            }
            return OtherDeviceSection(id: device, title: sectionTitle(first, hostName: hostName), glyph: glyph(first), rows: rows)
        }
    }

    private static func newestFirst(_ left: SharedTerminal, _ right: SharedTerminal) -> Bool {
        left.lastActiveAt != right.lastActiveAt ? left.lastActiveAt > right.lastActiveAt : left.id < right.id
    }

    /// "On Mac mini" for the Mac's own, by the host's name; "On Sam's iPad" for a device's.
    static func sectionTitle(_ terminal: SharedTerminal, hostName: String) -> String {
        terminal.onMac ? "On \(hostName)" : "On \(deviceLabel(terminal.deviceName))"
    }

    /// A paired device as the words name it: its own name, or "another iPhone" for one that has only the model's
    /// name (iOS 16 on gives apps "iPhone" or "iPad", not the name the owner gave it, so "On iPhone" read as this
    /// iPhone; owner, 2026-10-16), and "another device" for one without a name.
    nonisolated static func deviceLabel(_ name: String) -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return "another device" }
        if let generic = ["iPhone", "iPad", "iPod touch"].first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            return "another \(generic)"
        }
        return name
    }

    static func glyph(_ terminal: SharedTerminal) -> String {
        if terminal.onMac { return "desktopcomputer" }
        return terminal.deviceName.localizedCaseInsensitiveContains("iPad") ? "ipad" : "iphone"
    }

    /// Its task (`contextTitle`: a device's name, else the program's last useful title), else the program's title, each
    /// without the spinner or mark it leads with (Claude Code's "✳ ", a Braille spinner frame), else the program's name:
    /// the order a tab's name takes (`RemoteTerminal.displayTitle`), so the row and the tab say the same.
    nonisolated static func rowTitle(programTitle: String?, contextTitle: String?, programName: String) -> String {
        for title in [contextTitle, programTitle] {
            let title = String((title ?? "").drop(while: isLeadingMark)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { return title }
        }
        return programName
    }

    /// A symbol (`So`, `Sm`), a Braille pattern, `*`, `·` or whitespace: what a program's title leads with before its words.
    private nonisolated static func isLeadingMark(_ character: Character) -> Bool {
        if character.isWhitespace || character == "*" || character == "·" { return true }
        guard let scalar = character.unicodeScalars.first else { return false }
        if (0x2800...0x28FF).contains(scalar.value) { return true }
        switch scalar.properties.generalCategory {
        case .otherSymbol, .mathSymbol: return true
        default: return false
        }
    }

    /// "Claude Code · Alpha": the program and its workspace, or its folder outside any.
    static func subtitle(_ terminal: SharedTerminal, programName: String) -> String {
        let place = terminal.workspace ?? terminal.displayFolder
        return place.isEmpty ? programName : "\(programName) · \(place)"
    }

    /// What it is doing: "Working", "Waiting for you", or quiet for how long since its last output.
    static func statusText(_ terminal: SharedTerminal, now: Date) -> String {
        switch terminal.activity {
        case .working: return "Working"
        case .waiting: return "Waiting for you"
        case .quiet:
            guard let output = terminal.lastOutputAt else { return "Quiet" }
            let seconds = Int(max(0, now.timeIntervalSince(output)))
            switch seconds {
            case ..<60: return "Quiet · <1m"
            case ..<3_600: return "Quiet · \(seconds / 60)m"
            case ..<86_400: return "Quiet · \(seconds / 3_600)h"
            default: return "Quiet · \(seconds / 86_400)d"
            }
        }
    }
}

/// A terminal outside any workspace this device knows, shown on its own screen: its tab (`projectID` "") never joins
/// the workspace's tabs.
public struct StandaloneTerminalRoute: Hashable {
    public let tab: WorkspaceTab
    /// Its working folder on the Mac, which Add as Workspace adds.
    public let folder: String
    /// The same with the home folder as `~`.
    public let displayFolder: String
}

/// Where tapping a terminal of another device goes: its tab in its workspace, or a screen of its own.
public enum SharedTerminalRoute: Equatable {
    case tab(UUID)
    case standalone(StandaloneTerminalRoute)
}

extension WorkspaceModel {
    /// Opens a terminal of another device, or of the Mac. In a workspace this device knows, that workspace becomes the
    /// one in use and the terminal opens as its tab, following it (`sharedFrom`): one already open is shown, never
    /// opened twice. Outside any, it opens on a screen of its own (`StandaloneTerminalRoute`), apart from the tabs.
    public func openShared(_ terminal: SharedTerminal) -> SharedTerminalRoute {
        let origin = SharedOrigin(deviceName: terminal.deviceName, onMac: terminal.onMac, routed: terminal.routed)
        if let existing = tabs.first(where: { $0.kind == .terminal && $0.resourceID == terminal.id }),
           let projectID = workspaceID(for: existing), projects.contains(where: { $0.id == projectID }) {
            useWorkspace(projectID)
            selectedTabID = existing.id
            return .tab(existing.id)
        }
        if let projectID = terminal.projectID, projects.contains(where: { $0.id == projectID }) {
            return .tab(openSharedTab(.terminal(terminal.remoteTerminal, projectID: projectID, sharedFrom: origin)))
        }
        if let open = standaloneTabs.values.first(where: { $0.resourceID == terminal.id }) {
            return .standalone(StandaloneTerminalRoute(tab: open, folder: terminal.folder, displayFolder: terminal.displayFolder))
        }
        let tab = WorkspaceTab.terminal(terminal.remoteTerminal, projectID: "", sharedFrom: origin)
        standaloneTabs[tab.id] = tab
        return .standalone(StandaloneTerminalRoute(tab: tab, folder: terminal.folder, displayFolder: terminal.displayFolder))
    }

    /// Add as Workspace: the standalone terminal's folder becomes a workspace (or the one it already is opens), and
    /// the terminal opens there as that workspace's tab. Its own screen's session stops at once, so only the tab reads
    /// and types; the screen, on its way out, forgets it (`endStandalone`).
    public func addAsWorkspace(_ route: StandaloneTerminalRoute) async -> WorkspaceAddResult {
        // A route of another host, or one whose screen went: its folder is no folder of this host to add.
        guard standaloneTabs[route.tab.id] != nil else { return .dropped }
        let hostID = self.hostID
        let result = await workspaces.add(directory: route.folder)
        guard case let .open(projectID) = result, self.hostID == hostID, projects.contains(where: { $0.id == projectID }) else {
            return result
        }
        // The same terminal, its name and origin kept, as a tab of the workspace.
        var tab = route.tab
        tab.id = UUID()
        tab.projectID = projectID
        openSharedTab(tab)
        // Stopped, but kept for its screen until that goes: a lookup from the screen meanwhile makes no new session.
        (sessions.existing(route.tab.id) as? TerminalSession)?.end()
        return result
    }

    /// The screen of a standalone terminal went (nothing shows it any more): its session ends and is forgotten. The
    /// terminal keeps running on the host.
    public func endStandalone(_ tabID: UUID) {
        standaloneTabs.removeValue(forKey: tabID)
        guard !tabs.contains(where: { $0.id == tabID }) else { return }
        sessions.end(tabID)
    }

    /// Whether the header's X asks before closing `tab`: only this device's own terminal that still runs, which closing
    /// ends (2026-10-10). A tab that follows a terminal of another device or of the Mac (`sharedFrom`) closes at once and
    /// leaves the terminal running; other tabs ask their own questions.
    static func asksBeforeClosing(_ tab: WorkspaceTab, running: Bool) -> Bool {
        tab.kind == .terminal && tab.sharedFrom == nil && running
    }

    /// Makes the tab's workspace the one in use (on iPhone with its remembered task, as choosing a workspace there does)
    /// and opens the tab in it.
    @discardableResult
    private func openSharedTab(_ tab: WorkspaceTab) -> UUID {
        useWorkspace(tab.projectID)
        open(tab)
        return selectedTabID ?? tab.id
    }

    private func useWorkspace(_ projectID: String) {
        if phoneNavigation.drawerHoldsBrowsers { phoneNavigation.switchWorkspace(projectID, model: self) }
        else { openWorkspace(projectID, openFilesIfEmpty: false) }
    }
}
