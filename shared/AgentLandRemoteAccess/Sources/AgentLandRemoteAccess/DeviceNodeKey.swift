import AgentLandCore
import AgentLandIroh
import Foundation
import Security

/// This device's iroh key (docs/HOST-API.md "Node IDs, keys and proofs"): its node ID, what the phone's
/// endpoint binds with, and the proofs the device gives the host when it pairs or registers.
public struct DeviceNodeKey: Sendable {
    public let nodeID: IrohNodeID
    /// The 32-byte secret key (`EndpointOptions.secretKey`).
    public let secretKey: Data
    private let signer: @Sendable (Data) -> Data?

    /// A key and how it signs (tests pass their own signer).
    public init(nodeID: IrohNodeID, secretKey: Data, sign: @escaping @Sendable (Data) -> Data?) {
        self.nodeID = nodeID; self.secretKey = secretKey; signer = sign
    }

    /// The key of 32 secret bytes, signing with iroh's `SecretKey.sign(message:)`; nil when iroh does not
    /// take the bytes or their node ID is one no device may hold.
    public init?(secretKey: Data) {
        guard secretKey.count == 32, let key = try? SecretKey.fromBytes(bytes: secretKey),
              let nodeID = IrohNodeID(publicKey: key.public().toBytes()) else { return nil }
        self.init(nodeID: nodeID, secretKey: secretKey, sign: { message in
            (try? SecretKey.fromBytes(bytes: secretKey))?.sign(message: message).toBytes()
        })
    }

    /// The node ID with its proof for `purpose` (`pair`: the pairing code exactly as sent; `register`:
    /// the device ID the host gave).
    public func claim(_ purpose: IrohNodeProof.Purpose, binding: String) -> IrohNodeClaim? {
        signer(IrohNodeProof.message(purpose: purpose, binding: binding, nodeID: nodeID)).flatMap { IrohNodeClaim(nodeID: nodeID, signature: $0) }
    }
}

/// Where the device keeps its iroh key.
public protocol DeviceNodeKeyProviding: Sendable {
    /// This device's key, made once and then the same across launches, updates and reinstalls; nil when
    /// the Keychain cannot keep one.
    func deviceKey() -> DeviceNodeKey?
}

/// The device's iroh key in its own Keychain: one generic password item for this device only
/// (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, never synchronizable), made with
/// `SecretKey.generate()` the first time it is asked for. A Keychain that does not come along to a new
/// phone means a new node ID there.
public final class KeychainDeviceNodeKeys: DeviceNodeKeyProviding, @unchecked Sendable {
    public static let service = "dev.agentland.client.iroh-node-key"
    private let service: String
    private let account: String
    private let lock = NSLock()
    private var cached: DeviceNodeKey?

    public init(service: String = KeychainDeviceNodeKeys.service, account: String = "device") {
        self.service = service; self.account = account
    }

    public func deviceKey() -> DeviceNodeKey? {
        lock.withLock {
            if let cached { return cached }
            if let stored = read(), let key = DeviceNodeKey(secretKey: stored) {
                cached = key
                return key
            }
            // A new key; a key no device may hold (vanishingly unlikely) is made again.
            for _ in 0..<3 {
                let bytes = SecretKey.generate().toBytes()
                guard let key = DeviceNodeKey(secretKey: bytes) else { continue }
                switch add(bytes) {
                case errSecSuccess:
                    cached = key
                    return key
                case errSecDuplicateItem:
                    // Another process of this app made one first: use it.
                    guard let stored = read(), let existing = DeviceNodeKey(secretKey: stored) else { return nil }
                    cached = existing
                    return existing
                default:
                    return nil
                }
            }
            return nil
        }
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }

    private func read() -> Data? {
        var query = self.query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data, data.count == 32 else { return nil }
        return data
    }

    private func add(_ bytes: Data) -> OSStatus {
        var item = query
        item[kSecValueData as String] = bytes
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil)
    }
}
