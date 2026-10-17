import Foundation
import XCTest
@testable import AgentLandCore

/// A saved workspace must survive tabs this version cannot read, such as a
/// tab kind added by a newer version: only those tabs are dropped.
final class SavedTabDecodingTests: XCTestCase {
    private let identity = ConnectionIdentity(host: "https://one.example", deviceID: "device-1")
    private let chat = WorkspaceTab(kind: .chat, projectID: "p", resourceID: "chat", title: "Chat", draft: "unsent")
    private let files = WorkspaceTab(kind: .files, projectID: "p", title: "Files")
    private let unknownID = UUID()

    func testUnknownTabKindDropsOnlyThatTab() throws {
        let restored = try restore(state([encoded(chat), unknownKind(), encoded(files)], selected: files.id))
        XCTAssertEqual(restored.tabs, [chat, files])
        XCTAssertEqual(restored.selectedTabID, files.id)
    }

    func testSelectionIsClearedWhenItsTabIsDropped() throws {
        let restored = try restore(state([encoded(chat), unknownKind(), encoded(files)], selected: unknownID))
        XCTAssertEqual(restored.tabs, [chat, files])
        XCTAssertNil(restored.selectedTabID)
    }

    func testLegacyArrayKeepsItsReadableTabs() throws {
        let restored = try restore(JSONSerialization.data(withJSONObject: [encoded(chat), unknownKind(), encoded(files)]))
        XCTAssertEqual(restored.tabs, [chat, files])
        XCTAssertEqual(restored.selectedTabID, chat.id, "Array-only workspaces still reopen on their first tab")
    }

    func testMalformedEntriesAreDroppedLikeUnknownKinds() throws {
        var missingID = try encoded(files)
        missingID["id"] = nil
        let readable = try encoded(chat)
        let entries: [Any] = [NSNull(), 42, "tab", missingID, readable]
        XCTAssertEqual(try restore(state(entries, selected: chat.id)), WorkspaceState(tabs: [chat], selectedTabID: chat.id))
        XCTAssertEqual(try restore(JSONSerialization.data(withJSONObject: entries)), WorkspaceState(tabs: [chat], selectedTabID: chat.id))
    }

    func testDecodingAStateDirectlyAppliesTheSameRules() throws {
        let data = try state([encoded(chat), unknownKind()], selected: unknownID)
        XCTAssertEqual(try JSONDecoder().decode(WorkspaceState.self, from: data), WorkspaceState(tabs: [chat]))
    }

    func testSavingAfterARestoreKeepsTheReadableTabs() throws {
        let suite = "agentland-saved-tabs-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(try state([encoded(chat), unknownKind(), encoded(files)], selected: files.id), forKey: key)
        let store = WorkspacePersistence(defaults: defaults)
        store.save(store.loadState(for: identity), for: identity)
        XCTAssertEqual(WorkspacePersistence(defaults: defaults).loadState(for: identity), WorkspaceState(tabs: [chat, files], selectedTabID: files.id))
    }

    private var key: String { ProductIdentity.tabsDefaultsPrefix + "workspace." + Data(identity.storageKey.utf8).base64EncodedString() }

    private func restore(_ data: Data) throws -> WorkspaceState {
        let suite = "agentland-saved-tabs-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(data, forKey: key)
        return WorkspacePersistence(defaults: defaults).loadState(for: identity)
    }

    private func encoded(_ tab: WorkspaceTab) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(tab)) as? [String: Any])
    }

    /// A tab as a newer version might save it, with a kind this version lacks.
    private func unknownKind() throws -> [String: Any] {
        var tab = try encoded(WorkspaceTab(id: unknownID, kind: .files, projectID: "p", resourceID: "hologram:1", title: "Hologram"))
        tab["kind"] = "hologram"
        return tab
    }

    // MARK: Browser tabs

    /// Tabs saved by versions before `browser` existed, in both saved forms and with the optional
    /// members those versions did or did not write, load whole.
    func testOlderClientsSavedTabsStillLoad() throws {
        let home = UUID(), chat = UUID(), terminal = UUID(), files = UUID(), editor = UUID()
        let saved: [[String: Any]] = [
            ["id": home.uuidString, "kind": "home", "projectID": "p", "resourceID": "", "title": "Home 2"],
            ["id": chat.uuidString, "kind": "chat", "projectID": "p", "resourceID": "ses_1", "title": "Fix login", "draft": "half",
             "chatModelID": "anthropic/sonnet", "chatAgent": "plan"],
            ["id": terminal.uuidString, "kind": "terminal", "projectID": "p", "resourceID": "pty_1", "title": "Terminal"],
            ["id": files.uuidString, "kind": "files", "projectID": "p", "resourceID": "", "title": "Files", "draft": ""],
            ["id": editor.uuidString, "kind": "editor", "projectID": "p", "resourceID": "a.txt", "title": "a.txt", "draft": "edited",
             "editorDirty": true, "editorBaseRevision": "r1"],
        ]
        for data in [try state(saved, selected: editor), try JSONSerialization.data(withJSONObject: saved)] {
            let restored = try restore(data)
            XCTAssertEqual(restored.tabs.map(\.id), [home, chat, terminal, files, editor])
            XCTAssertEqual(restored.tabs.map(\.kind), [.home, .chat, .terminal, .files, .editor])
            XCTAssertEqual(restored.tabs[1].chatModelID, "anthropic/sonnet")
            XCTAssertEqual(restored.tabs[4].editorBaseRevision, "r1")
            XCTAssertTrue(restored.tabs[4].editorDirty)
        }
        XCTAssertEqual(try restore(try state(saved, selected: editor)).selectedTabID, editor)
    }

    func testBrowserTabsSaveAndLoad() throws {
        let browser = WorkspaceTab(kind: .browser, projectID: "p", resourceID: "preview:5173", title: "localhost:5173", draft: "preview:5173/docs")
        let restored = try restore(try state([encoded(chat), encoded(browser), encoded(files)], selected: browser.id))
        XCTAssertEqual(restored.tabs, [chat, browser, files])
        XCTAssertEqual(restored.selectedTabID, browser.id)
        XCTAssertEqual(try encoded(browser)["kind"] as? String, "browser")
    }

    /// A client from before `browser` reads a workspace this version saved: it drops the browser tab
    /// alone, keeps the rest, and loses the selection only if it was the browser tab. The legacy
    /// decoder below is the earlier version's saved-tab reading with its five kinds.
    func testAClientWithoutBrowserDropsOnlyTheBrowserTab() throws {
        let browser = WorkspaceTab(kind: .browser, projectID: "p", resourceID: "https://example.com", title: "Example")
        let data = try JSONEncoder().encode(WorkspaceState(tabs: [chat, browser, files], selectedTabID: browser.id))
        let legacy = try JSONDecoder().decode(LegacyWorkspaceState.self, from: data)
        XCTAssertEqual(legacy.tabIDs, [chat.id, files.id])
        XCTAssertNil(legacy.selectedTabID)
        let keptSelection = try JSONDecoder().decode(LegacyWorkspaceState.self, from: JSONEncoder().encode(WorkspaceState(tabs: [chat, browser, files], selectedTabID: files.id)))
        XCTAssertEqual(keptSelection.selectedTabID, files.id)
    }

    // MARK: Terminals from other devices

    /// Terminal tabs saved before `sharedFrom` existed load whole, as this device's own; such a tab still saves
    /// without the key, so nothing changes for a version that reads it.
    func testSavedTabsWithoutSharedFromStillDecode() throws {
        let terminal = UUID()
        let saved: [String: Any] = ["id": terminal.uuidString, "kind": "terminal", "projectID": "p", "resourceID": "pty_1",
                                    "title": "Fix login", "creationLabel": "Claude Code"]
        let restored = try restore(try state([saved, encoded(files)], selected: terminal))
        XCTAssertEqual(restored.tabs.map(\.id), [terminal, files.id])
        XCTAssertEqual(restored.selectedTabID, terminal)
        XCTAssertNil(restored.tabs[0].sharedFrom)
        XCTAssertEqual(restored.tabs[0].creationLabel, "Claude Code")
        XCTAssertNil(try encoded(restored.tabs[0])["sharedFrom"])
        let own = WorkspaceTab.terminal(RemoteTerminal(id: "pty_2", title: "Terminal", projectID: "p", status: .running, exitCode: nil), projectID: "p")
        XCTAssertNil(own.sharedFrom, "A terminal this device opened is its own")
    }

    /// A tab opened on a terminal of another device keeps where it came from across a save, and a version from
    /// before `sharedFrom` still reads it, as one of its own terminals.
    func testSharedFromRoundTrips() throws {
        let iPad = SharedOrigin(deviceName: "Sam’s iPad", onMac: false, routed: false)
        let mac = SharedOrigin(deviceName: "", onMac: true, routed: true)
        let fromIPad = WorkspaceTab.terminal(RemoteTerminal(id: "pty_7", title: "Claude Code", projectID: "p", status: .running, exitCode: nil,
                                                            contextTitle: "Fix the login bug"), projectID: "p", sharedFrom: iPad)
        let fromMac = WorkspaceTab.terminal(RemoteTerminal(id: "pty_8", title: "Codex", projectID: "", status: .running, exitCode: nil),
                                            projectID: "p", sharedFrom: mac)
        XCTAssertEqual(fromIPad.sharedFrom, iPad)
        XCTAssertEqual(fromIPad.title, "Fix the login bug")
        XCTAssertEqual(fromIPad.creationLabel, "Claude Code")
        let savedOrigin = try XCTUnwrap(try encoded(fromIPad)["sharedFrom"] as? [String: Any])
        XCTAssertEqual(savedOrigin["deviceName"] as? String, "Sam’s iPad")
        XCTAssertEqual(savedOrigin["onMac"] as? Bool, false)
        XCTAssertEqual(savedOrigin["routed"] as? Bool, false)
        let restored = try restore(try state([encoded(fromIPad), encoded(fromMac), encoded(chat)], selected: fromMac.id))
        XCTAssertEqual(restored.tabs, [fromIPad, fromMac, chat])
        XCTAssertEqual(restored.tabs.map(\.sharedFrom), [iPad, mac, nil])
        XCTAssertEqual(restored.selectedTabID, fromMac.id)
        let legacy = try JSONDecoder().decode(LegacyWorkspaceState.self, from: JSONEncoder().encode(restored))
        XCTAssertEqual(legacy.tabIDs, [fromIPad.id, fromMac.id, chat.id])
        XCTAssertEqual(legacy.selectedTabID, fromMac.id)
    }

    private func state(_ tabs: [Any], selected: UUID?) throws -> Data {
        var object: [String: Any] = ["tabs": tabs]
        if let selected { object["selectedTabID"] = selected.uuidString }
        return try JSONSerialization.data(withJSONObject: object)
    }
}

/// How a version from before `browser` reads a saved workspace: its five kinds, each tab on its own,
/// and a selection that must name a tab it kept (`WorkspaceState` and `SavedTabs` as they were).
private struct LegacyWorkspaceState: Decodable {
    private enum Kind: String, Decodable { case home, chat, terminal, files, editor }
    private struct Tab: Decodable {
        let id: UUID
        let kind: Kind
        let projectID: String
        let resourceID: String
        let title: String
    }
    private struct Readable: Decodable {
        let tab: Tab?
        init(from decoder: Decoder) throws { tab = try? Tab(from: decoder) }
    }
    private enum CodingKeys: String, CodingKey { case tabs, selectedTabID }

    let tabIDs: [UUID]
    let selectedTabID: UUID?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tabIDs = (try container.decodeIfPresent([Readable].self, forKey: .tabs) ?? []).compactMap(\.tab?.id)
        let selection = try container.decodeIfPresent(UUID.self, forKey: .selectedTabID)
        selectedTabID = tabIDs.contains { $0 == selection } ? selection : nil
    }
}
