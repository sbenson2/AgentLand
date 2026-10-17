import Foundation

/// A row of Settings → AI Providers: a provider the running OpenCode lists, or one with a key saved in
/// AgentLand that OpenCode does not list now (it is not running, or no longer lists that provider).
public struct OpenCodeProviderRow: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    /// Whether OpenCode lists it as connected; nil when OpenCode does not list it.
    public let connected: Bool?
    /// Its models in OpenCode; nil when OpenCode does not list it.
    public let models: [OpenCodeModelOption]?
    /// The variable a key for it is saved under (`<X>_API_KEY` or `<X>_TOKEN`); nil when AgentLand cannot
    /// add one.
    public let keyVariable: String?
    /// The variable of the key saved for it in AgentLand's Keychain items, if there is one.
    public let savedKeyVariable: String?
    /// Every variable OpenCode reads for it (models.dev's `env`).
    public let variables: [String]

    public var modelCount: Int? { models?.count }
    /// Its variables that AgentLand does not set (an Azure resource name, AWS credentials).
    public var otherVariables: [String] { variables.filter { !ManagedOpenCodeRuntime.supportsProviderEnvironmentKey($0) } }
}

/// Builds Settings → AI Providers' rows from OpenCode's catalog and the keys saved in AgentLand.
public enum OpenCodeProviderList {
    /// "In use": connected, or with a saved key. "Available": the rest. Each by name, and only those whose
    /// name, ID or variables contain `search` (ignoring case; blank shows all).
    public static func rows(catalog: [OpenCodeProviderOption], savedKeys: [String: String],
                            search: String) -> (inUse: [OpenCodeProviderRow], available: [OpenCodeProviderRow]) {
        var rows = catalog.map { provider in
            OpenCodeProviderRow(id: provider.id, name: provider.name, connected: provider.isConnected, models: provider.models,
                                keyVariable: provider.keyVariable, savedKeyVariable: savedKeys[provider.id],
                                variables: provider.environmentKeys)
        }
        let listed = Set(catalog.map(\.id))
        for (id, variable) in savedKeys where !listed.contains(id) {
            rows.append(OpenCodeProviderRow(id: id, name: id, connected: nil, models: nil,
                                            keyVariable: ManagedOpenCodeRuntime.supportsProviderEnvironmentKey(variable) ? variable : nil,
                                            savedKeyVariable: variable, variables: [variable]))
        }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let shown = rows.filter { row in
            query.isEmpty || row.name.localizedStandardContains(query) || row.id.localizedStandardContains(query)
                || row.variables.contains { $0.localizedStandardContains(query) }
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let inUse = shown.filter { $0.connected == true || $0.savedKeyVariable != nil }
        return (inUse, shown.filter { !($0.connected == true || $0.savedKeyVariable != nil) })
    }

    /// The other providers with a key saved under `variable`, by name (the ID of one OpenCode does not
    /// list): OpenCode reads one value per variable, so a key saved under it for `providerID` replaces
    /// theirs. Built from every saved key, never from the rows a search shows.
    public static func sharingKey(providerID: String, variable: String?, catalog: [OpenCodeProviderOption],
                                  savedKeys: [String: String]) -> [OpenCodeProviderRow] {
        guard let variable else { return [] }
        // Every provider with a saved key is in use.
        return rows(catalog: catalog, savedKeys: savedKeys, search: "").inUse
            .filter { $0.id != providerID && $0.savedKeyVariable == variable }
    }
}
