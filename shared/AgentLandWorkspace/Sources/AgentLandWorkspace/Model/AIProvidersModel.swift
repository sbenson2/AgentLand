import Foundation
import Observation
import AgentLandCore

/// iPhone and iPad Settings → AI Providers (docs/AGENT-CATALOG-PLAN.md, "The Mac app"): the model providers
/// OpenCode speaks on the Mac, from `GET /v1/providers`, read-only. Connected providers come first with their
/// model counts, the others under Available. Keys are added in AgentLand on the Mac and never leave it; the
/// Mac has its own pane.
///
/// A read captures the host and client it was made for, and an answer for another, or for an older read, is
/// dropped. Nothing is asked while the host does not answer: what was read stays.
@MainActor @Observable public final class AIProvidersModel {
    /// The providers as last read; nil before the first answer.
    public private(set) var providers: [ModelProvider]?
    /// Why the last read failed; what was read before stays shown.
    public private(set) var issue: String?

    @ObservationIgnored public private(set) weak var workspace: WorkspaceModel?
    @ObservationIgnored private var readToken = UUID()

    public init(workspace: WorkspaceModel) {
        self.workspace = workspace
    }

    /// Hosts with the agent catalog serve the provider list with it (the same round of the contract).
    public var isAvailable: Bool { workspace?.capabilities?.agents.isEmpty == false }

    /// The host answers now.
    public var canRead: Bool { workspace?.client != nil && workspace?.reachable == true }

    /// Providers with a key or sign-in on the Mac, by name.
    public var connected: [ModelProvider] { sorted((providers ?? []).filter(\.connected)) }

    /// The others, by name.
    public var available: [ModelProvider] { sorted((providers ?? []).filter { !$0.connected }) }

    private func sorted(_ providers: [ModelProvider]) -> [ModelProvider] {
        providers.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// "12 models", "1 model", "No models".
    public static func modelCount(_ provider: ModelProvider) -> String {
        switch provider.models {
        case 0: "No models"
        case 1: "1 model"
        default: "\(provider.models) models"
        }
    }

    public func refresh() async {
        guard canRead, let workspace, let stamp = workspace.requestStamp() else { return }
        let token = UUID()
        readToken = token
        let result: Result<[ModelProvider], Error>
        do { result = .success(try await stamp.client.modelProviders()) } catch { result = .failure(error) }
        // Another host, another connection or a newer read: this answer no longer counts.
        guard workspace.isCurrent(stamp), readToken == token else { return }
        switch result {
        case let .success(value):
            providers = value
            issue = nil
        case let .failure(error):
            // The pane went away while it read: nothing failed.
            if isCancellation(error) { return }
            if case let .server(code, _) = error as? ClientError, code == ModelProviderErrorCode.catalogUnavailable {
                issue = "OpenCode isn’t answering on \(workspace.hostName). Try again once it’s running."
            } else {
                issue = error.localizedDescription
            }
            if ClientError.isConnectionFailure(error) { workspace.noteConnectionFailure() }
        }
    }

    /// Everything goes with the host.
    func reset() {
        readToken = UUID()
        providers = nil
        issue = nil
    }
}
