import Foundation

public struct OpenCodeModelOption: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct OpenCodeProviderOption: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let environmentKeys: [String]
    public let models: [OpenCodeModelOption]
    public let defaultModelID: String?
    public let isConnected: Bool

    public init(id: String, name: String, environmentKeys: [String], models: [OpenCodeModelOption], defaultModelID: String?, isConnected: Bool) {
        self.id = id
        self.name = name
        self.environmentKeys = environmentKeys
        self.models = models
        self.defaultModelID = defaultModelID
        self.isConnected = isConnected
    }

    /// The variable a key for this provider is saved under and given to OpenCode as: the first of its
    /// models.dev variables that AgentLand may set (`<X>_API_KEY` or `<X>_TOKEN`,
    /// `ManagedOpenCodeRuntime.supportsProviderEnvironmentKey`). OpenCode takes the first variable it finds
    /// set. Nil when there is none.
    public var keyVariable: String? {
        environmentKeys.first(where: ManagedOpenCodeRuntime.supportsProviderEnvironmentKey)
    }

    /// Its other variables, which AgentLand does not set (an Azure resource name, AWS credentials).
    public var otherVariables: [String] {
        environmentKeys.filter { !ManagedOpenCodeRuntime.supportsProviderEnvironmentKey($0) }
    }
}

public enum OpenCodeClientError: LocalizedError, Sendable {
    case invalidEndpoint
    case invalidDirectory
    case invalidResponse
    case responseTooLarge
    case httpStatus(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "OpenCode must use a local loopback HTTP address."
        case .invalidDirectory: "Choose an existing project directory."
        case .invalidResponse: "OpenCode returned an unreadable response."
        case .responseTooLarge: "OpenCode returned more data than this screen can safely load."
        case let .httpStatus(status): "OpenCode returned HTTP \(status)."
        }
    }
}

public struct OpenCodeProviderClient: Sendable {
    private let endpoint: URL
    private let password: String

    public init(endpoint: URL, password: String) {
        self.endpoint = endpoint
        self.password = password
    }

    public func providers(directory: String) async throws -> [OpenCodeProviderOption] {
        guard !directory.isEmpty, directory.hasPrefix("/"),
              FileManager.default.fileExists(atPath: directory) else { throw OpenCodeClientError.invalidDirectory }
        let data = try await OpenCodeHTTPClient(endpoint: endpoint, password: password).get(path: "/provider", directory: directory, limit: 12 * 1024 * 1024)
        return try Self.parse(data)
    }

    /// OpenCode 1.18.31's `GET /provider`: `{"all": [provider], "default": {providerID: modelID},
    /// "connected": [providerID]}`, each provider with `id`, `name`, its models.dev `env` names and
    /// `models` keyed by ID (as the host's `desktop/chat_options.go` reads it). Only those fields are read;
    /// `options`, which can hold a key, never is. A provider without an ID or a model that does not decode
    /// is skipped; a provider without `env` or `name` gets none or its ID. Sorted by name.
    public static func parse(_ data: Data) throws -> [OpenCodeProviderOption] {
        let payload: ProviderPayload
        do { payload = try JSONDecoder().decode(ProviderPayload.self, from: data) }
        catch { throw OpenCodeClientError.invalidResponse }
        let connected = Set(payload.connected ?? [])
        return payload.all.compactMap(\.value).map { provider in
            OpenCodeProviderOption(
                id: provider.id,
                name: provider.name ?? provider.id,
                environmentKeys: provider.env ?? [],
                models: (provider.models ?? [:]).values.compactMap(\.value).map { OpenCodeModelOption(id: $0.id, name: $0.name) }
                    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
                defaultModelID: payload.defaultModels?[provider.id],
                isConnected: connected.contains(provider.id)
            )
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

private struct ProviderPayload: Decodable {
    let all: [Lossy<Provider>]
    let defaultModels: [String: String]?
    let connected: [String]?

    enum CodingKeys: String, CodingKey { case all, connected; case defaultModels = "default" }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        all = try container.decode([Lossy<Provider>].self, forKey: .all)
        defaultModels = try? container.decodeIfPresent([String: String].self, forKey: .defaultModels)
        connected = try? container.decodeIfPresent([String].self, forKey: .connected)
    }

    struct Provider: Decodable {
        let id: String
        let name: String?
        let env: [String]?
        let models: [String: Lossy<Model>]?

        enum CodingKeys: String, CodingKey { case id, name, env, models }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            name = try? container.decodeIfPresent(String.self, forKey: .name)
            env = try? container.decodeIfPresent([String].self, forKey: .env)
            models = try? container.decodeIfPresent([String: Lossy<Model>].self, forKey: .models)
        }
    }

    struct Model: Decodable {
        let id: String
        let name: String
    }
}

struct OpenCodeHTTPClient: Sendable {
    let endpoint: URL
    let password: String

    /// The version `/global/health` reports while OpenCode says it is healthy; nil while it says it is not.
    func healthyVersion() async throws -> String? {
        let data = try await get(path: "/global/health", directory: nil, limit: 64 * 1024)
        struct Health: Decodable { let healthy: Bool; let version: String }
        guard let health = try? JSONDecoder().decode(Health.self, from: data), !health.version.isEmpty,
              health.version.utf8.count <= 128 else {
            throw OpenCodeClientError.invalidResponse
        }
        return health.healthy ? health.version : nil
    }

    func get(path: String, directory: String?, limit: Int) async throws -> Data {
        guard endpoint.scheme == "http", ["127.0.0.1", "::1"].contains(endpoint.host ?? ""),
              endpoint.port != nil, endpoint.user == nil, endpoint.password == nil,
              endpoint.query == nil, endpoint.fragment == nil,
              (endpoint.path.isEmpty || endpoint.path == "/") else { throw OpenCodeClientError.invalidEndpoint }
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.path = path
        guard let url = components.url else { throw OpenCodeClientError.invalidEndpoint }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Basic " + Data("opencode:\(password)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        if let directory { request.setValue(directory, forHTTPHeaderField: "X-OpenCode-Directory") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4
        configuration.timeoutIntervalForResource = 15
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.connectionProxyDictionary = [:]
        let collector = BoundedOpenCodeResponse(limit: limit)
        let session = URLSession(configuration: configuration, delegate: collector, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                collector.start(session: session, request: request, continuation: continuation)
            }
        } onCancel: {
            collector.cancel()
        }
        guard let response = response as? HTTPURLResponse else { throw OpenCodeClientError.invalidResponse }
        guard response.statusCode == 200 else { throw OpenCodeClientError.httpStatus(response.statusCode) }
        return data
    }
}

private final class BoundedOpenCodeResponse: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let limit: Int
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<(Data, URLResponse), Error>?
    private var data = Data()
    private var response: URLResponse?
    private var pendingError: Error?
    private var cancelled = false

    init(limit: Int) { self.limit = limit }

    func start(session: URLSession, request: URLRequest, continuation: CheckedContinuation<(Data, URLResponse), Error>) {
        lock.lock()
        if cancelled {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        let task = session.dataTask(with: request)
        self.task = task
        lock.unlock()
        task.resume()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        self.response = response
        if response.expectedContentLength > Int64(limit) {
            pendingError = OpenCodeClientError.responseTooLarge
            lock.unlock()
            completionHandler(.cancel)
        } else {
            lock.unlock()
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        lock.lock()
        let exceeds = data.count + chunk.count > limit
        if exceeds { pendingError = OpenCodeClientError.responseTooLarge }
        else { data.append(chunk) }
        lock.unlock()
        if exceeds { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let result = data
        let response = self.response
        let failure = pendingError ?? error
        lock.unlock()
        guard let continuation else { return }
        if let failure { continuation.resume(throwing: failure) }
        else if let response { continuation.resume(returning: (result, response)) }
        else { continuation.resume(throwing: OpenCodeClientError.invalidResponse) }
    }
}
