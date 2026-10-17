import Foundation
import Security

public protocol SecretStoring: Sendable {
    func save(_ secret: String, account: String) throws
    func load(account: String) throws -> String?
    /// Deletes the item; an item that is not there is already deleted.
    func delete(account: String) throws
}

public final class KeychainSecretStore: SecretStoring, @unchecked Sendable {
    public static let service = "dev.agentland.desktop"
    private let service: String

    public init(service: String = KeychainSecretStore.service) {
        self.service = service
    }

    public func save(_ secret: String, account: String) throws {
        let data = Data(secret.utf8)
        let lookup: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        let attributes: [CFString: Any] = [kSecValueData: data, kSecAttrAccessible: kSecAttrAccessibleWhenUnlocked]
        let update = SecItemUpdate(lookup as CFDictionary, attributes as CFDictionary)
        if update == errSecItemNotFound {
            var create = lookup
            attributes.forEach { create[$0.key] = $0.value }
            let status = SecItemAdd(create as CFDictionary, nil)
            guard status == errSecSuccess else { throw KeychainError(status) }
        } else if update != errSecSuccess {
            throw KeychainError(update)
        }
    }

    public func load(account: String) throws -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let secret = String(data: data, encoding: .utf8) else {
            throw KeychainError(status)
        }
        return secret
    }

    public func delete(account: String) throws {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status) }
    }
}

public struct KeychainError: LocalizedError {
    private let status: OSStatus
    init(_ status: OSStatus) { self.status = status }
    public var errorDescription: String? { "The macOS Keychain could not access the saved credential (status \(status))." }
}
