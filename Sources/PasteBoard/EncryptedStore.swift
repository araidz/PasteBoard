import CryptoKit
import Foundation
import Security

/// Errors thrown by EncryptedStore operations.
enum EncryptedStoreError: Error, CustomStringConvertible {
    case encryptionFailed
    case keychainReadFailed(OSStatus)
    case keychainWriteFailed(OSStatus)

    var description: String {
        switch self {
        case .encryptionFailed: return "AES-GCM encryption produced no combined box"
        case .keychainReadFailed(let s): return "Keychain read failed (\(s))"
        case .keychainWriteFailed(let s): return "Keychain write failed (\(s))"
        }
    }
}

/// AES-GCM encryption for the on-disk clipboard history. The key lives in the
/// user's login Keychain — native OS secret storage, never written to disk
/// alongside the data it protects, never leaves the device.
enum EncryptedStore {
    static func encrypt(_ data: Data, key: SymmetricKey) throws -> Data {
        guard let combined = try AES.GCM.seal(data, using: key).combined else {
            throw EncryptedStoreError.encryptionFailed
        }
        return combined
    }

    static func decrypt(_ data: Data, key: SymmetricKey) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key)
    }

    // MARK: - Keychain-backed key

    private static let defaultService = "com.local.pasteboard.historykey"
    private static let account = "history"

    /// The persistent history key: loads it from Keychain, or generates and
    /// stores a new one on first run. Only creates a new key when the keychain
    /// genuinely has no entry (errSecItemNotFound) — transient read failures
    /// propagate instead of silently overwriting the existing key.
    static func persistentKey(service: String = defaultService) throws -> SymmetricKey {
        do {
            let data = try readKeychain(service: service)
            return SymmetricKey(data: data)
        } catch let EncryptedStoreError.keychainReadFailed(status) where status == errSecItemNotFound {
            let key = SymmetricKey(size: .bits256)
            let stored = try writeKeychain(key.withUnsafeBytes { Data($0) }, service: service)
            return SymmetricKey(data: stored)
        }
    }

    private static func query(service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private static func readKeychain(service: String) throws -> Data {
        var q = query(service: service)
        q[kSecReturnData as String] = true
        var result: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw EncryptedStoreError.keychainReadFailed(status)
        }
        return data
    }

    private static func writeKeychain(_ data: Data, service: String) throws -> Data {
        var q = query(service: service)
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        if status == errSecDuplicateItem {
            // Another process won first-run creation. Its key may already encrypt
            // history, so use it rather than replacing it.
            return try readKeychain(service: service)
        } else {
            guard status == errSecSuccess else {
                throw EncryptedStoreError.keychainWriteFailed(status)
            }
        }
        return data
    }
}
