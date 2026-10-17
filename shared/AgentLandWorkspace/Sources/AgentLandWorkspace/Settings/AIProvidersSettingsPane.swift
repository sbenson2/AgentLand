import SwiftUI
import AgentLandCore
import AgentLandDesign

/// iPhone and iPad Settings → AI Providers (`AIProvidersModel`), read-only: the providers OpenCode speaks on
/// the Mac, the connected ones first with how many models each offers, the others under Available. Keys are
/// added on the Mac, which has its own pane; this one is not shown there.
public struct AIProvidersSettingsPane: View {
    @Environment(WorkspaceModel.self) private var workspace

    public init() {}

    private var model: AIProvidersModel { workspace.aiProviders }

    public var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .groupedPageBackground()
            .task(id: workspace.paneReadKey) { await model.refresh() }
    }

    @ViewBuilder private var content: some View {
        if let providers = model.providers, !providers.isEmpty {
            list
        } else if model.providers != nil {
            ContentUnavailable("No Providers", systemImage: "key", description: "OpenCode on \(workspace.hostName) lists none.")
        } else if let issue = model.issue {
            ContentUnavailable("Couldn’t Load Providers", systemImage: "exclamationmark.triangle", description: issue,
                               actionTitle: "Try Again") { Task { await model.refresh() } }
        } else if !model.canRead {
            ContentUnavailable("\(workspace.hostName) Isn’t Connected", systemImage: "wifi.exclamationmark",
                               description: "Its providers show here once it’s connected.")
        } else {
            ProgressView("Loading Providers")
        }
    }

    private var list: some View {
        let connected = model.connected
        return List {
            // States in place, as their own sections (2026-10-06).
            if !model.canRead {
                SettingsStatusSection("\(workspace.hostName) isn’t connected", systemImage: "wifi.exclamationmark",
                                      message: "This list is from when it last answered.", identifier: "providersOffline")
            } else if let issue = model.issue {
                SettingsStatusSection("Couldn’t read the providers again", systemImage: "exclamationmark.triangle", message: issue,
                                      identifier: "providersIssue", actionTitle: "Try Again", actionIdentifier: "providersRetry") {
                    Task { await model.refresh() }
                }
            }
            Section {
                if connected.isEmpty {
                    Text("No provider is connected yet.")
                        .agentLandFont(.body)
                        .foregroundStyle(AgentLandColor.textSecondary)
                        .agentLandRowHeight()
                        .listRowFill(.surface)
                } else {
                    ForEach(connected) { provider in row(provider, showsModels: true) }
                }
            } header: {
                Text("Connected")
            } footer: {
                if model.available.isEmpty { footer }
            }
            if !model.available.isEmpty {
                Section {
                    ForEach(model.available) { provider in row(provider, showsModels: false) }
                } header: {
                    Text("Available")
                } footer: {
                    footer
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .hidesListPageBackground()
        .refreshable { await model.refresh() }
        .accessibilityIdentifier("providersList")
    }

    private var footer: some View {
        Text("Add keys in AgentLand on your Mac")
            .agentLandFont(.metadata)
            .foregroundStyle(AgentLandColor.textSecondary)
            .accessibilityIdentifier("providersFooter")
    }

    private func row(_ provider: ModelProvider, showsModels: Bool) -> some View {
        ProviderRow(provider: provider, showsModels: showsModels)
            .accessibilityIdentifier("provider-\(provider.id)")
            .listRowFill(.surface, separator: true)
    }
}

/// A provider's name, and for a connected one how many models it offers: beside the name, or under it at
/// accessibility text sizes so the name is not broken up.
private struct ProviderRow: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let provider: ModelProvider
    let showsModels: Bool

    var body: some View {
        // One layout swapped for the other, so the texts keep their identity when the text size changes.
        let stacked = typeSize.isAccessibilitySize
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: AgentLandSpacing.xxxSmall))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: AgentLandSpacing.small))
        layout {
            name.frame(maxWidth: .infinity, alignment: .leading)
            if showsModels { count }
        }
        .padding(.vertical, stacked ? AgentLandSpacing.xSmall : 0)
        .agentLandRowHeight()
        .accessibilityElement(children: .combine)
    }

    private var name: some View {
        Text(provider.name)
            .agentLandFont(.body)
            .foregroundStyle(AgentLandColor.text)
    }

    private var count: some View {
        Text(AIProvidersModel.modelCount(provider))
            .agentLandFont(.metadata)
            .foregroundStyle(AgentLandColor.textSecondary)
    }
}
