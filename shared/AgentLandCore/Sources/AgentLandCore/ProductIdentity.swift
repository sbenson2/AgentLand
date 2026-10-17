import Foundation

/// AgentLand storage never reads, migrates, or overwrites another app's pairings, tabs, or drafts.
public enum ProductIdentity {
    public static let displayName = "AgentLand"
    public static let bundleIdentifier = "dev.agentland.client"
    public static let keychainService = "dev.agentland.client.device-token"
    public static let connectionsDefaultsKey = "agentland.connections.v1"
    public static let selectedConnectionDefaultsKey = "agentland.selected-connection.v1"
    public static let tabsDefaultsPrefix = "agentland.tabs."
}
