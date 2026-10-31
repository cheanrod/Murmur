import Foundation
import Security

/// Storage for connection secrets (broker password, client certificate passphrase).
public protocol CredentialStore: AnyObject {
    func secret(for account: String) throws -> String?
    func setSecret(_ secret: String?, for account: String) throws
}

public struct KeychainError: LocalizedError, Equatable {
    public let status: OSStatus
    public let operation: String

    public var errorDescription: String? {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return "Keychain \(operation) failed: \(message)"
    }
}

/// Stores secrets as generic passwords in the user's login keychain.
public final class KeychainCredentialStore: CredentialStore {
    public let service: String

    public init(service: String = "app.murmur.Murmur") {
        self.service = service
    }

    private func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func secret(for account: String) throws -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError(status: status, operation: "read")
        }
    }

    public func setSecret(_ secret: String?, for account: String) throws {
        guard let secret, !secret.isEmpty else {
            let status = SecItemDelete(query(account) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainError(status: status, operation: "delete")
            }
            return
        }
        let data = Data(secret.utf8)
        let update = [kSecValueData as String: data]
        var status = SecItemUpdate(query(account) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(account)
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "Murmur MQTT (\(account))"
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status, operation: "write") }
    }
}

/// Non-persistent store, used by tests.
public final class InMemoryCredentialStore: CredentialStore {
    public private(set) var secrets: [String: String] = [:]
    public init() {}
    public func secret(for account: String) throws -> String? { secrets[account] }
    public func setSecret(_ secret: String?, for account: String) throws {
        if let secret, !secret.isEmpty { secrets[account] = secret } else { secrets.removeValue(forKey: account) }
    }
}
