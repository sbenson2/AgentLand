import Foundation

/// What the switch's row and Settings say about remote access (docs/HOST-API.md "The Mac switches").
public struct RemoteAccessSummary: Equatable, Sendable {
    public enum Tone: Equatable, Sendable {
        case off
        case working
        case reachable
        case attention
    }

    public var tone: Tone
    /// One line: off, mapping, reachable at an address, relay fallback, or what failed.
    public var title: String
    /// Why, and what to do, when there is something to say.
    public var detail: String?

    public init(tone: Tone, title: String, detail: String? = nil) {
        self.tone = tone
        self.title = title
        self.detail = detail
    }

    /// How often the views read the summary again while it shows (the relay's countdown).
    public static let refreshInterval: TimeInterval = 15
    public static let switchTitle = "Reach this Mac from anywhere"
    public static let fallbackTitle = "Use a public relay if a direct connection fails"
    public static let switchExplanation = "Opens one port on your router (UDP \(RemoteAccessPorts.endpointUDP)) so your paired devices can connect to this Mac directly from other networks. Only devices you paired get in, and their connections stay encrypted end to end. Turning this off closes the port."
    public static let fallbackExplanation = "When no direct connection can be made, devices connect through one of n0's public relays (n0 makes iroh, which remote access uses). The relay passes on encrypted traffic it cannot read; it sees this Mac's network address, its device ID and how much is sent."
    static let relayAdvice = "Turn on “\(fallbackTitle)” to reach it anyway."
    /// The switch is on while the host's connection mode is local development HTTP.
    public static let needsHTTPSTitle = "Off while the connection is Local development HTTP"
    public static let needsHTTPSDetail = "Remote access carries the host's HTTPS, so it runs only with “Trusted HTTPS” (Settings → Advanced → Connection). The port on the router stays closed until then."
    static let notDirect = "Your network does not let other networks reach this Mac directly."
}

extension RemoteAccessService.Status {
    /// The summary for the switch's row and Settings.
    public func summary(now: Date = Date()) -> RemoteAccessSummary {
        guard enabled else { return RemoteAccessSummary(tone: .off, title: "Off") }
        guard tunnelServed else {
            return RemoteAccessSummary(tone: .attention, title: RemoteAccessSummary.needsHTTPSTitle,
                                       detail: RemoteAccessSummary.needsHTTPSDetail)
        }
        let port = RemoteAccessPorts.endpointUDP
        switch endpoint {
        case .off, .starting:
            return RemoteAccessSummary(tone: .working, title: "Starting…")
        case .portInUse:
            return RemoteAccessSummary(tone: .attention, title: "UDP port \(port) is in use",
                detail: "Another program on this Mac uses UDP port \(port), so AgentLand cannot open it on the router. AgentLand tries again, and at once when the network changes.")
        case let .failed(message):
            return RemoteAccessSummary(tone: .attention, title: "Remote access could not start", detail: message)
        case .running:
            break
        }
        let relayLine = relaySentence(now: now)
        switch mapping.state {
        case .idle, .attempting where !mapping.settled:
            return RemoteAccessSummary(tone: .working, title: "Opening port \(port) on the router…", detail: relayLine)
        default:
            break
        }
        if let kept = mapping.keptUntil, let address = mapping.directAddresses.first {
            let until = kept.formatted(date: .omitted, time: .shortened)
            return RemoteAccessSummary(tone: .reachable, title: "Reachable at \(address)",
                detail: join("The router did not open the port this time. AgentLand keeps trying, and devices keep the last address until the mapping's lease ends at \(until) (at most 2 hours).", relayLine))
        }
        if let address = mapping.directAddresses.first {
            return RemoteAccessSummary(tone: .reachable, title: "Reachable at \(address)", detail: relayLine)
        }
        // No direct address while the endpoint has its port.
        let why: String? = {
            switch mapping.state {
            case .mapped:
                let external = mapping.externalAddress.map { $0.split(separator: ":").dropLast().joined(separator: ":") } ?? "unknown"
                return "The router's external address (\(external)) is not a public one: another router, or your provider's carrier-grade NAT, is in front of it."
            case .notMapped(.noRouter):
                return "The port mapping failed: this Mac has no router to ask."
            case let .notMapped(.failed(error)):
                return "The port mapping failed: " + (error.errorDescription ?? "\(error)")
            case .expired:
                return "The port mapping ended: the router stopped renewing it. AgentLand keeps trying."
            case .idle, .attempting:
                return nil
            }
        }()
        if fallback, case let .using(url) = relay {
            return RemoteAccessSummary(tone: .reachable, title: "Reachable through a public relay (\(Self.host(of: url)))",
                                       detail: join(Self.notDirectSentence, why))
        }
        let title: String
        switch mapping.state {
        case .notMapped: title = "The port mapping failed"
        case .expired: title = "The port mapping ended"
        default: title = "Not reachable directly"
        }
        return RemoteAccessSummary(tone: .attention, title: title,
                                   detail: join(why, RemoteAccessSummary.notDirect, fallback ? relayLine : RemoteAccessSummary.relayAdvice))
    }

    static let notDirectSentence = RemoteAccessSummary.notDirect + " Devices connect through the relay."

    private func relaySentence(now: Date) -> String? {
        guard fallback else { return nil }
        switch relay {
        case .off: return nil
        case .picking: return "Picking a public relay for when a direct connection fails…"
        case let .using(url): return "Public relay if a direct connection fails: \(Self.host(of: url))."
        case let .unreachable(url, since):
            // An upper bound, rounded up: the last minute says 1, never 0. The views read it again
            // every few seconds (`TimelineView`), since the service publishes only when the state changes.
            let left = max(0, RemoteAccessService.relayPickAgainAfter - now.timeIntervalSince(since))
            let minutes = max(1, Int((left / 60).rounded(.up)))
            return "The public relay \(Self.host(of: url)) is not reachable; AgentLand picks another within \(minutes) min if it stays that way."
        }
    }

    static func host(of url: String) -> String {
        guard let host = URLComponents(string: url)?.host, !host.isEmpty else { return url }
        return host.hasSuffix(".") ? String(host.dropLast()) : host
    }

    private func join(_ parts: String?...) -> String? {
        let kept = parts.compactMap { $0 }.filter { !$0.isEmpty }
        return kept.isEmpty ? nil : kept.joined(separator: " ")
    }
}
