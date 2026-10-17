// agentland-remote-access-loopback: the Mac side of remote access for the phone's simulator UI test
// (integration/check-ios-product.py, testConnectsThroughIrohTunnel), built from the Mac app's own code.
//
// It runs AgentLandDesktopCore's `RemoteAccessService` as the app does with "Reach this Mac from
// anywhere" on: the Mac endpoint (`IrohMacEndpoint`, `presetMinimal()`, no relay, `IrohPeerGate` fed
// by the host's peers route), the bridge to the host's tunnel socket (`MacTunnelBridge`), the UDP
// mapping (`RemoteAccessMapping` over `PortMapper`) and the reports to the host. What differs from the
// app, so that nothing leaves this Mac:
// - the key is made in memory for this run (`InMemoryRemoteAccessKeyStore`), never the Keychain;
// - the endpoint binds the UDP port given (a free one), not 38842;
// - `PortMapper` asks `LoopbackRouter` on 127.0.0.1, never the router; its records go to the folder
//   given;
// - no iCloud address record (no record database).
// Run it only under shared/AgentLandIroh/Tests/router-ports-denied.sb. It prints one JSON object per
// line (`status` whenever the service's status changes, `peers` whenever the host's peer list does)
// and shuts the service down on SIGTERM or SIGINT, as Quit does.
import AgentLandCore
import AgentLandDesktopCore
import Darwin
import Foundation
import Synchronization

struct Options {
    var hostPort: UInt16 = 0
    var fingerprint = ""
    var certificateName = ""
    var tunnelSocket = ""
    var udpPort: UInt16 = 0
    var externalAddress = ""
    var stateDirectory = ""

    static func parse(_ arguments: [String]) -> Options {
        var options = Options()
        var index = 0
        func value() -> String {
            index += 1
            guard index < arguments.count else { fail("\(arguments[index - 1]) needs a value") }
            return arguments[index]
        }
        while index < arguments.count {
            switch arguments[index] {
            case "--host-port": options.hostPort = UInt16(value()) ?? 0
            case "--fingerprint": options.fingerprint = value()
            case "--certificate-name": options.certificateName = value()
            case "--tunnel-socket": options.tunnelSocket = value()
            case "--udp-port": options.udpPort = UInt16(value()) ?? 0
            case "--external-address": options.externalAddress = value()
            case "--state-directory": options.stateDirectory = value()
            default: fail("unknown argument \(arguments[index])")
            }
            index += 1
        }
        guard options.hostPort > 0, !options.fingerprint.isEmpty, !options.certificateName.isEmpty,
              options.tunnelSocket.hasPrefix("/"), options.udpPort > 0, !options.externalAddress.isEmpty,
              options.stateDirectory.hasPrefix("/") else {
            fail("usage: agentland-remote-access-loopback --host-port N --fingerprint HEX --certificate-name NAME "
                 + "--tunnel-socket PATH --udp-port N --external-address IPV4 --state-directory DIR "
                 + "(the host's local session token in AGENTLAND_LOCAL_SESSION_TOKEN)")
        }
        return options
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("agentland-remote-access-loopback: \(message)\n".utf8))
    exit(64)
}

/// One JSON object per line on standard output.
let lastLines = Mutex<[String: String]>([:])
func emit(_ kind: String, _ object: [String: Any]) {
    var object = object
    object["event"] = kind
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
          let line = String(data: data, encoding: .utf8) else { return }
    let changed = lastLines.withLock { lines -> Bool in
        defer { lines[kind] = line }
        return lines[kind] != line
    }
    if changed { FileHandle.standardOutput.write(Data((line + "\n").utf8)) }
}

func describe(_ status: RemoteAccessService.Status) -> [String: Any] {
    let endpoint: String = switch status.endpoint {
    case .off: "off"
    case .starting: "starting"
    case .running: "running"
    case .portInUse: "portInUse"
    case let .failed(reason): "failed: \(reason)"
    }
    let mapping: String = switch status.mapping.state {
    case .idle: "idle"
    case .attempting: "attempting"
    case .mapped: "mapped"
    case let .notMapped(problem): "notMapped: \(problem)"
    case .expired: "expired"
    }
    var object: [String: Any] = [
        "enabled": status.enabled, "endpoint": endpoint, "mapping": mapping,
        "mappedAddresses": status.mapping.directAddresses, "hostSession": status.hostSession,
    ]
    if let node = status.nodeID { object["nodeId"] = node.hex }
    if let reported = status.reported {
        object["reported"] = ["enabled": reported.enabled, "directAddresses": reported.directAddresses,
                              "sequence": reported.sequence, "nodeId": reported.nodeID?.hex ?? NSNull()] as [String: Any]
    }
    if let problem = status.reportProblem { object["reportProblem"] = problem }
    return object
}

/// The host's local-only routes, with each peer list printed.
struct PrintingSession: RemoteAccessHostSession {
    let inner: APIClientRemoteAccessSession
    func peers(after version: String?, wait: TimeInterval?) async throws -> RemoteAccessPeers {
        let answer = try await inner.peers(after: version, wait: wait)
        emit("peers", ["nodeIds": answer.peers.map(\.nodeID.hex), "deviceIds": answer.peers.map(\.deviceID)])
        return answer
    }
    func report(_ report: RemoteAccessEndpointReport) async throws -> RemoteAccessCapabilities {
        try await inner.report(report)
    }
}

let options = Options.parse(Array(CommandLine.arguments.dropFirst()))
guard let token = ProcessInfo.processInfo.environment["AGENTLAND_LOCAL_SESSION_TOKEN"], !token.isEmpty else {
    fail("AGENTLAND_LOCAL_SESSION_TOKEN is not set")
}
let router: LoopbackRouter
do { router = try LoopbackRouter(externalAddress: options.externalAddress) } catch { fail("the loopback router did not start: \(error)") }
let records = URL(fileURLWithPath: options.stateDirectory).appendingPathComponent("port-mappings.json")
let udpPort = options.udpPort
let routerPort = router.port
let dependencies = RemoteAccessService.Dependencies(
    port: udpPort, socketPath: options.tunnelSocket, keyStore: InMemoryRemoteAccessKeyStore(),
    makeMapping: { plan, onChange in
        RemoteAccessMapping(request: try! RemoteAccessPorts.endpointMapping(port: udpPort), gateway: { "127.0.0.1" },
                            hardwareAddress: { _ in nil },
                            makeMapper: { _ in
                                var configuration = try PortMapper.Configuration(gateway: "127.0.0.1", recordsFile: records)
                                configuration.serverPort = routerPort
                                return PortMapper(configuration: configuration)
                            }, plan: plan, onChange: onChange)
    },
    recordDatabase: nil)
let service = RemoteAccessService(settings: .init(), dependencies: dependencies, onStatus: { emit("status", describe($0)) })
let address: ServerAddress
do { address = try ServerAddress(validating: "https://127.0.0.1:\(options.hostPort)") } catch { fail("bad host port") }
let client = APIClient(address: address, token: token,
                       transport: URLSessionTransport(expectedHost: "127.0.0.1", certificateSHA256: options.fingerprint,
                                                      validatedCertificateHost: options.certificateName))

signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
let stops = AsyncStream<Int32> { continuation in
    let sources = [SIGTERM, SIGINT].map { number in
        // The main queue: this top-level code, and the handler with it, belongs to the main actor.
        let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
        source.setEventHandler { continuation.yield(number) }
        source.resume()
        return source
    }
    continuation.onTermination = { _ in sources.forEach { $0.cancel() } }
}

await service.activate()
await service.hostStarted(PrintingSession(inner: APIClientRemoteAccessSession(client)), hostID: nil)
await service.setEnabled(true)
for await _ in stops { break }
// Quit: the mapping goes and the endpoint closes, without a report.
await service.shutdown()
router.stop()
emit("stopped", ["mappingsLeft": router.mappings.count])
exit(0)
