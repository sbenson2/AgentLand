import Foundation
import Security
import AgentLandCore
import AgentLandIroh

/// Where the Mac endpoint's iroh secret key lives (docs/HOST-API.md "Node IDs, keys and proofs"):
/// 32 bytes made once with `SecretKey.generate()`, kept for this device only, so the Mac's node ID
/// stays the same across launches, updates and reinstalls, and a Keychain that does not come along
/// (Migration Assistant, a reset) means a new node ID.
public protocol RemoteAccessKeyStoring: Sendable {
    /// The saved key, or a new one saved first.
    func secretKey() throws -> Data
}

extension RemoteAccessKeyStoring {
    /// The node ID of the key: the hex of `SecretKey.public().toBytes()`.
    public func nodeID() throws -> IrohNodeID {
        try IrohNodeID(secretKey: try secretKey())
    }
}

extension IrohNodeID {
    /// The node ID of a 32-byte iroh secret key: the hex of `SecretKey.public().toBytes()`.
    public init(secretKey: Data) throws {
        let key = try SecretKey.fromBytes(bytes: secretKey)
        guard let node = IrohNodeID(publicKey: key.public().toBytes()) else { throw RemoteAccessKeyError.unusableKey }
        self = node
    }
}

public enum RemoteAccessKeyError: LocalizedError, Equatable {
    case unusableKey
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .unusableKey: "This Mac's remote access key cannot be used."
        case let .keychain(status): "The macOS Keychain could not keep this Mac's remote access key (status \(status))."
        }
    }
}

/// The key in the Keychain as a generic password, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
/// and never synchronizable. It goes to the data protection Keychain, whose "this device only" items
/// Migration Assistant and backups leave behind; that Keychain needs the app's signed application
/// identifier, which an ad-hoc build lacks, and there the key goes to the login Keychain (not
/// synchronized either).
public final class KeychainRemoteAccessKeyStore: RemoteAccessKeyStoring, @unchecked Sendable {
    public static let account = "iroh.secret-key"
    private let service: String
    private let lock = NSLock()

    public init(service: String = KeychainSecretStore.service) {
        self.service = service
    }

    public func secretKey() throws -> Data {
        try lock.withLock {
            for dataProtection in [true, false] {
                switch load(dataProtection: dataProtection) {
                case let .found(key): return key
                case .missingEntitlement: continue
                case .notFound: break
                case let .failed(status): throw RemoteAccessKeyError.keychain(status)
                }
                let key = SecretKey.generate().toBytes()
                let status = add(key, dataProtection: dataProtection)
                if status == errSecSuccess { return key }
                if status == errSecMissingEntitlement { continue }
                if status == errSecDuplicateItem, case let .found(saved) = load(dataProtection: dataProtection) { return saved }
                throw RemoteAccessKeyError.keychain(status)
            }
            throw RemoteAccessKeyError.keychain(errSecMissingEntitlement)
        }
    }

    private enum Lookup { case found(Data), notFound, missingEntitlement, failed(OSStatus) }

    private func baseQuery(dataProtection: Bool) -> [CFString: Any] {
        var query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                      kSecAttrAccount: Self.account, kSecAttrSynchronizable: false]
        if dataProtection { query[kSecUseDataProtectionKeychain] = true }
        return query
    }

    private func load(dataProtection: Bool) -> Lookup {
        var query = baseQuery(dataProtection: dataProtection)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, data.count == 32 else { return .failed(errSecDecode) }
            return .found(data)
        case errSecItemNotFound: return .notFound
        case errSecMissingEntitlement: return .missingEntitlement
        default: return .failed(status)
        }
    }

    private func add(_ key: Data, dataProtection: Bool) -> OSStatus {
        var item = baseQuery(dataProtection: dataProtection)
        item[kSecValueData] = key
        item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecAttrLabel] = "AgentLand remote access key"
        return SecItemAdd(item as CFDictionary, nil)
    }
}

/// A key kept in memory (tests).
public final class InMemoryRemoteAccessKeyStore: RemoteAccessKeyStoring, @unchecked Sendable {
    private let key: Data

    public init(key: Data = SecretKey.generate().toBytes()) {
        self.key = key
    }

    public func secretKey() throws -> Data { key }
}
