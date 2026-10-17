import Foundation

/// The one port of remote access over iroh (docs/HOST-API.md "Remote access (iroh)"): the Mac's
/// endpoint binds UDP 38842 on every address, and with "Reach this Mac from anywhere" on the app
/// maps that port on the router and nothing else. It is none of iroh's defaults and not Tailscale's
/// 41641, so the mapping AgentLand makes never touches another program's. There is no relay on the
/// Mac and no TCP port.
public enum RemoteAccessPorts {
    public static let endpointUDP: UInt16 = 38842

    /// The router mapping remote access asks for: the endpoint's UDP port.
    public static func endpointMapping(port: UInt16 = endpointUDP) throws -> PortMappingRequest {
        try PortMappingRequest(.udp, internalPort: port)
    }
}
