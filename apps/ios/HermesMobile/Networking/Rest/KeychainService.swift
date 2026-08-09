import Foundation
import Security

/// Stores the per-server session token in the iOS keychain.
///
/// Items are scoped to service `ai.hermes.mobile` with the server string as the
/// account, so each gateway the user connects to keeps its own token. Loads are
/// non-throwing (a missing or unreadable item simply yields `nil`).
enum KeychainService {
    private static let service = "ai.hermes.mobile"
    private static let providerPrefix = "nativeProvider:"

    /// Persist `token` for `server`, replacing any existing value.
    /// - Throws: ``KeychainError/unexpectedStatus(_:)`` if the keychain rejects the write.
    static func saveToken(_ token: String, server: String) throws {
        guard let data = token.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: server,
        ]
        let status = SecItemAdd(
            query.merging([
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ]) { _, new in new } as CFDictionary,
            nil
        )

        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let attributes: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ]
            let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(updateStatus)
            }
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Return the stored token for `server`, or `nil` if none exists or it is unreadable.
    static func loadToken(server: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: server,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8) else {
            return nil
        }
        return token
    }

    /// Remove the stored token for `server`. No-op if nothing is stored.
    static func deleteToken(server: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: server,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Stock native-session credential bundles

    /// Commit a rotated access/refresh pair as one Keychain value. The old
    /// per-server shared-token item is removed only after this write succeeds.
    static func saveProviderCredential(
        _ credential: ProviderCredentialBundle,
        server: String
    ) throws {
        guard credential.isUsable else { throw KeychainError.encodingFailed }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(credential)
        } catch {
            throw KeychainError.encodingFailed
        }
        try saveData(data, account: providerAccount(server))
        deleteToken(server: server)
    }

    static func loadProviderCredential(server: String) -> ProviderCredentialBundle? {
        guard let data = loadData(account: providerAccount(server)),
              let bundle = try? JSONDecoder().decode(ProviderCredentialBundle.self, from: data),
              bundle.isUsable else { return nil }
        return bundle
    }

    /// Provider sessions are preferred when present; legacy loopback/shared
    /// tokens remain readable for old gateways and existing installs.
    static func loadCredential(server: String) -> StoredGatewayCredential? {
        if let provider = loadProviderCredential(server: server) {
            return .provider(provider)
        }
        guard let token = loadToken(server: server), !token.isEmpty else { return nil }
        return .sharedToken(token)
    }

    static func deleteCredentials(server: String) {
        deleteValue(account: providerAccount(server))
        deleteToken(server: server)
    }

    /// Commit a verified legacy/shared credential before removing any stale
    /// provider bundle. This mirrors provider migration ordering in reverse:
    /// there is always at least one durable credential if the process stops
    /// between the two operations.
    static func saveSharedCredentialReplacingProvider(
        _ token: String,
        server: String
    ) throws {
        try saveToken(token, server: server)
        deleteValue(account: providerAccount(server))
    }

    private static func providerAccount(_ server: String) -> String {
        providerPrefix + server
    }

    // MARK: - Transient provider-key storage (ABH-183)
    //
    // A model-provider API key the user is entering is held in the Keychain
    // ONLY for the duration of the single POST that delivers it to the gateway,
    // then deleted via ``deleteProviderKey(slug:)`` (the gateway is the source
    // of truth). The account string is `"providerKey:" + slug` so provider keys
    // never collide with a server's pairing token (which uses the raw server
    // string as its account). Same service (`ai.hermes.mobile`) and the same
    // `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` accessibility as the
    // pairing token — parallel to ``saveToken(_:server:)``.

    /// Persist `key` transiently for the provider identified by `slug`,
    /// replacing any existing value. - Throws: ``KeychainError`` on a rejected
    /// write (same upsert semantics as ``saveToken(_:server:)``).
    static func saveProviderKey(_ key: String, slug: String) throws {
        try saveValue(key, account: providerKeyAccount(slug))
    }

    /// Return the transiently-stored provider key for `slug`, or `nil` if none
    /// exists or it is unreadable. Non-throwing — a missing item yields `nil`.
    static func loadProviderKey(slug: String) -> String? {
        loadValue(account: providerKeyAccount(slug))
    }

    /// Remove the transiently-stored provider key for `slug`. No-op if nothing
    /// is stored (the gateway remains the source of truth regardless).
    static func deleteProviderKey(slug: String) {
        deleteValue(account: providerKeyAccount(slug))
    }

    /// The Keychain account string for `slug`'s transient provider key.
    static func providerKeyAccount(_ slug: String) -> String { "providerKey:\(slug)" }

    // MARK: - Shared generic-password upsert/load/delete (account-keyed)

    private static func saveValue(_ value: String, account: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }
        try saveData(data, account: account)
    }

    private static func saveData(_ data: Data, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemAdd(
            query.merging([
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ]) { _, new in new } as CFDictionary,
            nil
        )
        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let attributes: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ]
            let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(updateStatus)
            }
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private static func loadValue(account: String) -> String? {
        guard let data = loadData(account: account) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func loadData(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return data
    }

    private static func deleteValue(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// Failures that can occur while writing to the keychain.
enum KeychainError: Error, LocalizedError, Sendable {
    /// The token string could not be UTF-8 encoded.
    case encodingFailed
    /// The Security framework returned an unexpected `OSStatus`.
    case unexpectedStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "Could not encode the token for secure storage"
        case .unexpectedStatus(let status):
            let message = SecCopyErrorMessageString(status, nil) as String?
            return "Keychain error \(status)" + (message.map { ": \($0)" } ?? "")
        }
    }
}
