import CloudKit
import Foundation
import AgentLandCore
import AgentLandNotifications
import AgentLandRemoteAccess

/// Reads the Mac's address record (docs/HOST-API.md "When the Mac's address changes", Reading it).
protocol RemoteAccessAddressFetching: Sendable {
    /// The record named `hostID` in zone `RemoteAccess` of the owner's private database, as far as a device
    /// takes anything from it; nil when there is none, CloudKit is off or unavailable, or it cannot be read.
    func record(hostID: String) async -> RemoteAccessAddressRecord?
}

/// The record in the private database of `iCloud.dev.agentland`, read by record ID with the container
/// made as the notices make it: only when this process may use CloudKit (`NoticeCloudKit`: the
/// entitlement check and `AGENTLAND_CLOUDKIT=0`), and only when asked, never at launch.
struct CloudKitRemoteAccessAddresses: RemoteAccessAddressFetching {
    func record(hostID: String) async -> RemoteAccessAddressRecord? {
        guard NoticeHostID.isValid(hostID), NoticeCloudKit.unavailability() == nil else { return nil }
        let database = CKContainer(identifier: NoticeRecord.containerIdentifier).privateCloudDatabase
        let zone = CKRecordZone.ID(zoneName: RemoteAccessAddressRecord.zoneName, ownerName: CKCurrentUserDefaultName)
        guard let record = try? await database.record(for: CKRecord.ID(recordName: hostID, zoneID: zone)),
              record.recordType == RemoteAccessAddressRecord.recordType else { return nil }
        let values = record.encryptedValues
        return Self.read { values[$0] }
    }

    /// What a device takes from the record's encrypted fields: `nodeId`, `directAddresses`, `relayUrl`
    /// and `sequence` (`RemoteAccessAddressRecord` keeps only what a device may dial).
    static func read(_ field: (String) -> Any?) -> RemoteAccessAddressRecord? {
        guard let nodeID = field("nodeId") as? String else { return nil }
        let sequence: Int64? = switch field("sequence") {
        case let value as Int64: value
        case let value as NSNumber: value.int64Value
        default: nil
        }
        return RemoteAccessAddressRecord(nodeID: nodeID, directAddresses: field("directAddresses") as? [String] ?? [],
                                         relayURL: field("relayUrl") as? String, sequence: sequence)
    }
}

/// What remote access needs from outside the app model: the device's iroh key, the phone's tunnel and
/// the Mac's address record. Tests pass fakes, so no endpoint is ever bound in them.
struct RemoteAccessServices {
    let nodeKeys: any DeviceNodeKeyProviding
    /// Makes the phone's tunnel with the device's key; nil keeps the tunnel off.
    let makeTunnel: @MainActor (DeviceNodeKey) -> (any RemoteAccessTunnelConnecting)?
    let addressRecords: any RemoteAccessAddressFetching

    /// `AGENTLAND_REMOTE_ACCESS=0` keeps the tunnel off (the unit tests' host app): no endpoint is bound.
    static let environmentSwitch = "AGENTLAND_REMOTE_ACCESS"

    static func live(environment: [String: String] = ProcessInfo.processInfo.environment) -> RemoteAccessServices {
        let off = environment[environmentSwitch] == "0"
        #if DEBUG
        // The simulator UI test's Mac side runs on loopback (`RemoteAccessLoopbackDial`).
        if !off, let loopback = RemoteAccessLoopbackDial(environment: environment) {
            return RemoteAccessServices(nodeKeys: KeychainDeviceNodeKeys(),
                                        makeTunnel: { loopback.wrap(IrohPhoneTunnel(secretKey: $0.secretKey)) },
                                        addressRecords: CloudKitRemoteAccessAddresses())
        }
        #endif
        return RemoteAccessServices(nodeKeys: KeychainDeviceNodeKeys(),
                                    makeTunnel: { off ? nil : IrohPhoneTunnel(secretKey: $0.secretKey) },
                                    addressRecords: CloudKitRemoteAccessAddresses())
    }
}
