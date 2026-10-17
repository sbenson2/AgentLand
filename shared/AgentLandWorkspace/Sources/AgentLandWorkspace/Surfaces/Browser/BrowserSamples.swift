import Foundation
import AgentLandCore

/// Sample data for the Browser previews: a workspace attached to a pretend host whose routes answer
/// with realistic ports, so previews exercise the same models and requests as the app.
@MainActor enum BrowserSamples {
    static let projects = [Project(id: "agentland", name: "AgentLand"), Project(id: "site", name: "Website")]

    static let capabilities = CapabilitiesResponse(
        interactions: true, terminal: true, terminalPrograms: ["opencode", "claude", "codex"],
        chatProviders: ["opencode", "claude", "codex"], chatFeatures: ["events", "modes", "effort"],
        preview: PreviewCapabilities(port: 9842, scheme: "https", features: PreviewFeature.allCases.map(\.rawValue)))

    /// Keeps the previews' models alive: views hold them weakly or through their shells.
    private static var retained: [AnyObject] = []

    /// A workspace on the pretend host with AgentLand open.
    static func workspace() -> WorkspaceModel {
        let defaults = UserDefaults(suiteName: "dev.agentland.previews") ?? .standard
        let workspace = WorkspaceModel(defaults: defaults)
        let client = APIClient(address: try! ServerAddress(validating: "https://studio.local:9841"), token: "preview", transport: SampleHost())
        workspace.attach(hostID: "preview-host", identity: ConnectionIdentity(host: "https://studio.local:9841", deviceID: "preview"),
                         client: client)
        workspace.projects = projects
        workspace.capabilities = capabilities
        workspace.selectedProjectID = "agentland"
        retained.append(workspace)
        return workspace
    }
}

/// The pretend host behind the previews. It answers each route at once, like a host on the same desk.
final class SampleHost: APITransport, @unchecked Sendable {
    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let object: Any
        var status = 200
        switch request.url?.path ?? "" {
        case "/v1/preview/ports":
            object = ["ports": [
                ["port": 3000, "address": "::1", "process": "next-server"],
                ["port": 5173, "address": "127.0.0.1", "process": "node"],
                ["port": 8000, "address": "*", "process": "python3"],
            ]]
        case "/v1/preview/sessions":
            status = 201
            object = ["sessionId": "preview", "previewPort": 9842,
                      "cookie": ["name": PreviewCookie.standardName, "value": "sample", "maxAgeSeconds": 43_200]]
        case "/v1/preview/sessions/revoke":
            object = ["revoked": true, "count": 0]
        default:
            status = 404
            object = ["error": ["code": "not_found", "message": "Not found"]]
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
}
