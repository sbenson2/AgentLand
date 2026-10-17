import Foundation
import AgentLandCore
import AgentLandPairing

extension AppModel {
    /// What the pairing screen says about an invitation that has expired.
    nonisolated static let expiredPairingCode = "This code has expired. Your Mac shows a new one — scan again."

    /// Pairs with a scanned invitation, at once (QR-only pairing, 2026-10-16): the certificate fingerprint and the
    /// host's routes come with the code, out of band, so there is nothing to confirm. An invitation that expired
    /// while it waited is refused here; any other failure is the host's or the connection's, in `error`.
    func pair(invitation: PairingInvitation) async {
        guard !busy else { return }
        guard Date() < invitation.expiresAt else { error = Self.expiredPairingCode; return }
        error = nil
        pairingHostName = invitation.advertisement.name
        defer { pairingHostName = nil }
        await pair(address: invitation.advertisement.address,
                   code: invitation.code,
                   name: invitation.advertisement.name,
                   mode: .direct,
                   certificateSHA256: invitation.advertisement.certificateSHA256,
                   routes: invitation.routes.compactMap {
                       HostRoute(kind: $0.kind, host: $0.host, addresses: $0.addresses, port: $0.port)
                   },
                   remoteAccess: invitation.acceptsIrohNodeID)
    }

    // MARK: Pairing again (docs/HOST-API.md, "Pairing again"; owner, 2026-10-17)

    /// The saved host a pairing at `address` pairs again: one paired with the same certificate fingerprint at
    /// the same address, in any form (`SavedHost.sameAddress`), whose token this device still has. The selected
    /// host when it is one, else the one paired last. Nil without a fingerprint: only a pinned host gets a token.
    static func previousPairing(in hosts: [SavedHost], address: String, certificateSHA256: String?,
                                selectedID: String?, hasToken: (SavedHost) -> Bool) -> SavedHost? {
        guard let certificateSHA256 else { return nil }
        let candidates = hosts.filter { $0.certificateSHA256 == certificateSHA256 && $0.sameAddress(as: address) && hasToken($0) }
        return candidates.first { $0.id == selectedID } ?? candidates.last
    }

    /// The saved hosts once a pairing answered `paired`. When the host paired again over `previous`'s record (it
    /// answered the same device ID), `previous`'s row takes the pairing in its place, with its address as saved, so
    /// its ID, and with it the tabs, workspace and device copy kept under it, stay the same; it keeps the Mac's
    /// remote-access entry it learned. Any other answer (a host before pairing again, a record the host no longer
    /// takes) is a row of its own, as before: one with the same ID is replaced, else it is added.
    static func savingPairing(_ paired: SavedHost, previous: SavedHost?,
                              in hosts: [SavedHost]) -> (host: SavedHost, hosts: [SavedHost]) {
        var hosts = hosts
        guard let previous, previous.deviceID == paired.deviceID,
              let index = hosts.firstIndex(where: { $0.id == previous.id }) else {
            hosts.removeAll { $0.id == paired.id }
            hosts.append(paired)
            return (paired, hosts)
        }
        let host = SavedHost(address: previous.address, deviceID: paired.deviceID, name: paired.name, mode: paired.mode,
                             certificateSHA256: paired.certificateSHA256, routes: paired.routes, lastEndpoint: paired.lastEndpoint,
                             remoteAccess: previous.remoteAccess)
        hosts[index] = host
        return (host, hosts)
    }

    #if DEBUG && targetEnvironment(simulator)
    /// Simulator only, never in a release build: `-AgentLandPairingURL <agentland://pair?data=…>` pairs as a scan of
    /// that invitation would, at launch, when no host is selected or the invitation's host isn't saved
    /// (`scripts/sim-pair.sh` mints one from the Mac's running host). The simulator has no camera to scan with.
    func pairFromLaunchArgument(_ arguments: [String] = ProcessInfo.processInfo.arguments) {
        guard let index = arguments.firstIndex(of: "-AgentLandPairingURL"), arguments.indices.contains(index + 1) else { return }
        let invitation: PairingInvitation
        do { invitation = try PairingInvitation.parse(arguments[index + 1]) } catch {
            self.error = error as? PairingError == .expired ? Self.expiredPairingCode
                : "-AgentLandPairingURL: \(error.localizedDescription)"
            return
        }
        let address = (try? ServerAddress(validating: invitation.advertisement.address))?.url.absoluteString
        let saved = hosts.contains { $0.address == address }
        guard selectedHost == nil || !saved else { return }
        Task { await pair(invitation: invitation) }
    }
    #endif
}
