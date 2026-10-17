import Foundation

public final class TabPersistence: @unchecked Sendable {
    private let defaults: UserDefaults
    private let prefix = ProductIdentity.tabsDefaultsPrefix

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func load(for identity: ConnectionIdentity) -> [SessionTab] {
        guard let data = defaults.data(forKey: key(identity)) else { return [] }
        return (try? JSONDecoder().decode([SessionTab].self, from: data)) ?? []
    }
    public func save(_ tabs: [SessionTab], for identity: ConnectionIdentity) {
        guard let data = try? JSONEncoder().encode(tabs) else { return }
        defaults.set(data, forKey: key(identity))
    }
    public func close(tabID: UUID, for identity: ConnectionIdentity) {
        save(load(for: identity).filter { $0.id != tabID }, for: identity)
    }
    private func key(_ identity: ConnectionIdentity) -> String {
        prefix + identity.storageKey.data(using: .utf8)!.base64EncodedString()
    }
}

public final class WorkspacePersistence: @unchecked Sendable {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    private func key(_ identity: ConnectionIdentity) -> String {
        ProductIdentity.tabsDefaultsPrefix + "workspace." + Data(identity.storageKey.utf8).base64EncodedString()
    }
    public func load(for identity: ConnectionIdentity) -> [WorkspaceTab] {
        loadState(for: identity).tabs
    }

    /// The selected tab belongs to the same connection scope as its tabs.
    /// Earlier app versions stored only an array, so those workspaces reopen
    /// with their first tab selected, matching their prior behavior. In both
    /// forms a tab this version cannot read is dropped and the rest are kept.
    public func loadState(for identity: ConnectionIdentity) -> WorkspaceState {
        guard let data = defaults.data(forKey: key(identity)) else { return WorkspaceState() }
        if let state = try? JSONDecoder().decode(WorkspaceState.self, from: data) {
            return state.normalized()
        }
        if let tabs = try? JSONDecoder().decode(SavedTabs.self, from: data).tabs {
            return WorkspaceState(tabs: tabs, selectedTabID: tabs.first?.id)
        }
        return WorkspaceState()
    }

    public func save(_ tabs: [WorkspaceTab], for identity: ConnectionIdentity) {
        save(WorkspaceState(tabs: tabs, selectedTabID: tabs.first?.id), for: identity)
    }

    public func save(_ tabs: [WorkspaceTab], selectedTabID: UUID?, for identity: ConnectionIdentity) {
        save(WorkspaceState(tabs: tabs, selectedTabID: selectedTabID), for: identity)
    }

    public func save(_ state: WorkspaceState, for identity: ConnectionIdentity) {
        guard let data = try? JSONEncoder().encode(state.normalized()) else { return }
        defaults.set(data, forKey: key(identity))
    }
}

public struct WorkspaceState: Codable, Equatable, Sendable {
    public var tabs: [WorkspaceTab]
    public var selectedTabID: UUID?

    public init(tabs: [WorkspaceTab] = [], selectedTabID: UUID? = nil) {
        self.tabs = tabs
        self.selectedTabID = selectedTabID
    }

    enum CodingKeys: String, CodingKey { case tabs, selectedTabID }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tabs = try container.decodeIfPresent(SavedTabs.self, forKey: .tabs)?.tabs ?? []
        let selection = try container.decodeIfPresent(UUID.self, forKey: .selectedTabID)
        // A selection whose tab was dropped would point at nothing.
        selectedTabID = tabs.contains(where: { $0.id == selection }) ? selection : nil
    }

    fileprivate func normalized() -> WorkspaceState {
        var state = self
        if let selectedTabID, !tabs.contains(where: { $0.id == selectedTabID }) {
            state.selectedTabID = nil
        }
        return state
    }
}

/// Saved tabs are decoded one at a time, so a tab this version cannot read,
/// such as a kind added by a newer version, costs only that tab rather than
/// the whole workspace.
private struct SavedTabs: Decodable {
    let tabs: [WorkspaceTab]

    init(from decoder: Decoder) throws {
        tabs = try [Readable](from: decoder).compactMap(\.tab)
    }

    private struct Readable: Decodable {
        let tab: WorkspaceTab?
        init(from decoder: Decoder) throws { tab = try? WorkspaceTab(from: decoder) }
    }
}
