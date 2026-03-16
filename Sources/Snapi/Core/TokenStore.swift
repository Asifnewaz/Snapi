// TokenStore.swift
// NetworkingSDK
//
// Handles reading and writing the auth token to persistent storage.
// Default implementation uses UserDefaults.
// Swap to KeychainTokenStore for production apps (more secure).
//
// NetworkConfiguration talks to this — callers never touch storage directly.

import Foundation

// MARK: - Protocol

/// Contract for token persistence. Swap implementations without touching any other SDK code.
public protocol TokenStoreProtocol {

    /// Saves a token. Pass `nil` to delete.
    func save(token: String?, forKey key: String)

    /// Reads the stored token. Returns `nil` if not found.
    func load(forKey key: String) -> String?

    /// Removes the token.
    func delete(forKey key: String)
}

// MARK: - UserDefaultsTokenStore (default)

/// Stores the token in UserDefaults.
/// Simple and works out of the box. Not encrypted — fine for non-sensitive tokens.
/// For sensitive tokens use `KeychainTokenStore` below.
public final class UserDefaultsTokenStore: TokenStoreProtocol {

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func save(token: String?, forKey key: String) {
        if let token = token {
            defaults.set(token, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    public func load(forKey key: String) -> String? {
        defaults.string(forKey: key)
    }

    public func delete(forKey key: String) {
        defaults.removeObject(forKey: key)
    }
}

// MARK: - KeychainTokenStore (recommended for production)

/// Stores the token in the iOS Keychain.
/// Encrypted, survives app reinstall (if accessibility allows), hardware-backed on modern devices.
/// Drop-in replacement for UserDefaultsTokenStore.
public final class KeychainTokenStore: TokenStoreProtocol {

    private let service: String

    /// - Parameter service: Your app's bundle ID or a unique service name.
    public init(service: String = Bundle.main.bundleIdentifier ?? "com.networkingsdk") {
        self.service = service
    }

    public func save(token: String?, forKey key: String) {
        guard let token = token else {
            delete(forKey: key)
            return
        }
        guard let data = token.data(using: .utf8) else { return }

        // Delete existing before writing — Keychain does not update in place
        delete(forKey: key)

        let query: [CFString: Any] = [
            kSecClass:            kSecClassGenericPassword,
            kSecAttrService:      service,
            kSecAttrAccount:      key,
            kSecValueData:        data,
            kSecAttrAccessible:   kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    public func load(forKey key: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass:            kSecClassGenericPassword,
            kSecAttrService:      service,
            kSecAttrAccount:      key,
            kSecReturnData:       true,
            kSecMatchLimit:       kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else {
            return nil
        }
        return token
    }

    public func delete(forKey key: String) {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}
