import Foundation

public struct ProjectConfiguration: Sendable, Equatable, Codable, Identifiable {
    public var id: String
    public var name: String
    public var directory: String

    public init(id: String, name: String, directory: String) {
        self.id = id
        self.name = name
        self.directory = directory
    }

    public static func replacing(_ projects: [ProjectConfiguration], with updated: ProjectConfiguration) -> [ProjectConfiguration] {
        guard let index = projects.firstIndex(where: { $0.id == updated.id }) else { return projects + [updated] }
        var result = projects
        result[index] = updated
        return result
    }
}

public enum TLSConfiguration: Sendable, Equatable {
    case developmentHTTP
    case certificate(certificatePath: String, keyPath: String)
}

public struct HostCommand: Sendable, Equatable {
    public var arguments: [String]
    public var environment: [String: String]

    public init(arguments: [String], environment: [String: String] = [:]) {
        self.arguments = arguments
        self.environment = environment
    }
}

/// What `terminals hook` does: `on` writes the hook and its block in ~/.zshrc and turns routing on, `off` turns it off and
/// removes them, `pause` turns routing off and keeps them (terminal access is off).
public enum TerminalHookAction: String, Sendable {
    case on, off, pause
}

public enum HostCommandError: LocalizedError, Equatable {
    case invalidProject
    case invalidOpenCodeURL
    case invalidListenAddress
    case developmentHTTPRequiresLoopback
    case missingCertificateFiles
    case previewRequiresHTTPS
    case invalidPreviewPort

    public var errorDescription: String? {
        switch self {
        case .invalidProject: "Choose an existing project directory and provide an identifier."
        case .invalidOpenCodeURL: "OpenCode must use a loopback HTTP URL without credentials."
        case .invalidListenAddress: "Enter a host and port, for example 127.0.0.1:9841."
        case .developmentHTTPRequiresLoopback: "Development HTTP is available only on a loopback address."
        case .missingCertificateFiles: "Choose both a TLS certificate and private key."
        case .previewRequiresHTTPS: "Web previews need the HTTPS connection."
        case .invalidPreviewPort: "Choose a web preview port other than the connection's port."
        }
    }
}

public enum HostCommandBuilder {
    public static func initCommand(
        statePath: String,
        project: ProjectConfiguration,
        openCodeURL: String,
        passwordEnvironment: String
    ) throws -> HostCommand {
        try validate(project: project)
        guard isLoopbackOpenCodeURL(openCodeURL), !passwordEnvironment.isEmpty else {
            throw HostCommandError.invalidOpenCodeURL
        }
        return HostCommand(arguments: [
            "init", "--state", statePath,
            "--opencode-url", openCodeURL,
            "--password-env", passwordEnvironment,
            "--project", "\(project.id)=\(project.name)=\(project.directory)"
        ])
    }

    public static func configureCommand(
        statePath: String,
        project: ProjectConfiguration,
        openCodeURL: String,
        passwordEnvironment: String
    ) throws -> HostCommand {
        try configureCommand(statePath: statePath, projects: [project], openCodeURL: openCodeURL, passwordEnvironment: passwordEnvironment)
    }

    public static func configureCommand(
        statePath: String,
        projects: [ProjectConfiguration],
        openCodeURL: String,
        passwordEnvironment: String
    ) throws -> HostCommand {
        guard !projects.isEmpty else { throw HostCommandError.invalidProject }
        try projects.forEach(validate)
        guard isLoopbackOpenCodeURL(openCodeURL), !passwordEnvironment.isEmpty else {
            throw HostCommandError.invalidOpenCodeURL
        }
        var arguments = [
            "config", "set", "--state", statePath,
            "--opencode-url", openCodeURL,
            "--password-env", passwordEnvironment
        ]
        for project in projects { arguments += ["--project", "\(project.id)=\(project.name)=\(project.directory)"] }
        return HostCommand(arguments: arguments)
    }

    public static func showConfiguration(statePath: String) -> HostCommand {
        HostCommand(arguments: ["config", "show", "--state", statePath])
    }

    /// Makes sure the host has a valid managed OpenCode, getting the registry's when it has none, and prints
    /// its progress as JSON lines (`HostOpenCodeInstaller`). It fails at once while a host serves the state.
    public static func installOpenCodeCommand(statePath: String) -> HostCommand {
        HostCommand(arguments: ["install-opencode", "--state", statePath])
    }

    /// The host's tunnel socket for remote access: `tunnel.sock` in the folder of the state file
    /// (docs/HOST-API.md "The tunnel socket"). Nil when it would not fit a Unix socket's path (at most
    /// 103 bytes, its folder at most 92), which the host would refuse at start.
    public static func tunnelSocketPath(statePath: String) -> String? {
        guard statePath.hasPrefix("/") else { return nil }
        let folder = URL(fileURLWithPath: statePath).deletingLastPathComponent().path
        let path = URL(fileURLWithPath: folder).appendingPathComponent("tunnel.sock").path
        guard folder.utf8.count <= 92, path.utf8.count <= TunnelSocket.maximumPathBytes else { return nil }
        return path
    }

    /// Where the host installs agents: `<state>.agents`, beside its other stores (`<state>.archive`,
    /// `<state>.chats.json`), with OpenCode's `current.json` in `opencode/` (docs/AGENT-CATALOG-PLAN.md
    /// "Installs"). Nil for a relative state path.
    public static func agentsFolderPath(statePath: String) -> String? {
        guard statePath.hasPrefix("/") else { return nil }
        return statePath + ".agents"
    }

    /// `previewPort` turns on web previews: a second HTTPS listener with the
    /// same certificate on the listener's host. The companion leaves it off.
    /// `advertisedHost` (HTTPS only) is the name devices on the local network
    /// reach the host by; with it the host lists its routes, Tailscale's too
    /// while Tailscale runs (docs/HOST-API.md, "Routes"). `tunnelSocket` (HTTPS
    /// only; the host also needs `--local-session-env`) serves the API to paired
    /// devices bridged through remote access (`tunnelSocketPath(statePath:)`). `webSearchProvider` names the
    /// service the OpenCode the host uses sends web searches to, when the app runs that OpenCode itself with the
    /// provider set (`ManagedOpenCodeRuntime.webSearchProvider`); the host names it to devices only then.
    /// `openCodeHome` is the managed OpenCode's root (`ManagedOpenCodeRuntime.defaultStorageRoot()`), passed only when the app
    /// runs that OpenCode: the host's OpenCode terminals share its config and storage.
    public static func serveCommand(
        statePath: String,
        listenAddress: String,
        tls: TLSConfiguration,
        terminalEnabled: Bool,
        previewPort: UInt16? = nil,
        advertisedHost: String? = nil,
        tunnelSocket: String? = nil,
        webSearchProvider: String? = nil,
        openCodeHome: URL? = nil
    ) throws -> HostCommand {
        guard let host = listenHost(listenAddress) else { throw HostCommandError.invalidListenAddress }
        var arguments = ["serve", "--state", statePath, "--listen", listenAddress]
        switch tls {
        case .developmentHTTP:
            guard isLoopback(host) else { throw HostCommandError.developmentHTTPRequiresLoopback }
            arguments.append("--dev-http")
        case let .certificate(certificatePath, keyPath):
            guard !certificatePath.isEmpty, !keyPath.isEmpty else { throw HostCommandError.missingCertificateFiles }
            arguments += ["--cert", certificatePath, "--key", keyPath]
        }
        if terminalEnabled { arguments.append("--enable-terminal") }
        if let previewPort {
            guard case .certificate = tls else { throw HostCommandError.previewRequiresHTTPS }
            guard let address = previewListenAddress(listenAddress, port: previewPort) else {
                throw HostCommandError.invalidPreviewPort
            }
            arguments += ["--enable-preview", "--preview-listen", address]
        }
        if case .certificate = tls, let advertisedHost = advertisedHost?.trimmingCharacters(in: .whitespacesAndNewlines),
           !advertisedHost.isEmpty {
            guard !advertisedHost.contains(":"), !advertisedHost.contains("/"), !advertisedHost.contains(" ") else {
                throw HostCommandError.invalidListenAddress
            }
            arguments += ["--advertised-host", advertisedHost]
        }
        if case .certificate = tls, let tunnelSocket {
            arguments += ["--tunnel-socket", tunnelSocket]
        }
        if let webSearchProvider, !webSearchProvider.isEmpty {
            arguments += ["--websearch-provider", webSearchProvider]
        }
        if let openCodeHome {
            arguments += ["--opencode-home", openCodeHome.path]
        }
        return HostCommand(arguments: arguments)
    }

    public static func pairingCommand(statePath: String, expiresInSeconds: Int = 600, securePIN: Bool = false) -> HostCommand {
        var arguments = ["pair", "--state", statePath, "--expires", "\(max(1, min(expiresInSeconds, 3600)))s"]
        if securePIN { arguments.append("--pin") }
        return HostCommand(arguments: arguments)
    }

    public static func devicesCommand(statePath: String) -> HostCommand {
        HostCommand(arguments: ["devices", "--state", statePath])
    }

    public static func revokeCommand(statePath: String, deviceID: String) -> HostCommand {
        HostCommand(arguments: ["revoke", "--state", statePath, "--device", deviceID])
    }

    /// Settings → Advanced's switch for coding agents typed in Terminal: `terminals hook` writes or removes the marked
    /// block in ~/.zshrc and the switch the hook reads, beside `statePath` (the same state file `serve` gets). The hook
    /// runs this program, which the command finds itself.
    public static func terminalHookCommand(statePath: String, action: TerminalHookAction) -> HostCommand {
        HostCommand(arguments: ["terminals", "hook", action.rawValue, "--state", statePath])
    }

    public static func tlsInitializeCommand(directory: String, hosts: [String]) throws -> HostCommand {
        let cleanedHosts = hosts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard directory.hasPrefix("/"), !cleanedHosts.isEmpty,
              cleanedHosts.allSatisfy({ !$0.contains(",") && !$0.contains("://") && !$0.contains("/") && !$0.contains(":") }) else {
            throw HostCommandError.invalidListenAddress
        }
        return HostCommand(arguments: ["tls", "init", "--directory", directory, "--hosts", cleanedHosts.joined(separator: ",")])
    }

    private static func validate(project: ProjectConfiguration) throws {
        guard !project.id.isEmpty, !project.name.isEmpty, !project.id.contains("="), !project.name.contains("="),
              project.directory.hasPrefix("/") else {
            throw HostCommandError.invalidProject
        }
    }

    private static func isLoopbackOpenCodeURL(_ value: String) -> Bool {
        guard let url = URL(string: value), url.scheme == "http", url.user == nil,
              url.query == nil, url.fragment == nil, let host = url.host else { return false }
        return isLoopback(host)
    }

    private static func listenHost(_ address: String) -> String? {
        guard let separator = address.lastIndex(of: ":"), separator != address.startIndex else { return nil }
        let host = String(address[..<separator])
        let port = String(address[address.index(after: separator)...])
        guard !host.isEmpty, UInt16(port) != nil else { return nil }
        return host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    }

    /// The listener's host (brackets kept) with the preview port, which must
    /// differ from the listener's own port.
    private static func previewListenAddress(_ listenAddress: String, port: UInt16) -> String? {
        guard port != 0, let separator = listenAddress.lastIndex(of: ":"),
              UInt16(listenAddress[listenAddress.index(after: separator)...]) != port else { return nil }
        return "\(listenAddress[..<separator]):\(port)"
    }

    private static func isLoopback(_ host: String) -> Bool {
        host == "localhost" || host == "127.0.0.1" || host == "::1"
    }
}
