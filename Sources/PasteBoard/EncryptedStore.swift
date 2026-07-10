import CryptoKit
import Foundation
import Security

/// AES-GCM encryption for the on-disk clipboard history. The key lives in the
/// user's login Keychain — native OS secret storage, never written to disk
/// alongside the data it protects, never leaves the device.
enum EncryptedStore {
    static func encrypt(_ data: Data, key: SymmetricKey) throws -> Data {
        guard let combined = try AES.GCM.seal(data, using: key).combined else {
            throw CocoaError(.coderInvalidValue)
        }
        return combined
    }

    static func decrypt(_ data: Data, key: SymmetricKey) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key)
    }

    // MARK: - Keychain-backed key

    private static let service = "com.local.pasteboard.historykey"
    private static let account = "history"

    /// The persistent history key: loads it from Keychain, or generates and
    /// stores a new one on first run.
    static func persistentKey() throws -> SymmetricKey {
        if let data = try? readKeychain() { return SymmetricKey(data: data) }
        let key = SymmetricKey(size: .bits256)
        try writeKeychain(key.withUnsafeBytes { Data($0) })
        return key
    }

    private static func query() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private static func readKeychain() throws -> Data {
        var q = query()
        q[kSecReturnData as String] = true
        var result: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw CocoaError(.coderValueNotFound)
        }
        return data
    }

    private static func writeKeychain(_ data: Data) throws {
        var q = query()
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw CocoaError(.coderInvalidValue) }
    }
}
