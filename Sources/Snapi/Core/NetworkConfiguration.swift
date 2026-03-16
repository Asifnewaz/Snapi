// NetworkConfiguration.swift
// NetworkingSDK
//
// Central configuration. Now handles auth token persistence automatically.
// When setAuthToken() is called, the token is:
//   1. Injected into defaultHeaders["Authorization"] immediately
//   2. Saved to TokenStore (UserDefaults by default)
//
// On next app launch, init() auto-loads the saved token so the
// user stays authenticated without any extra code from the caller.

import Foundation

// MARK: - Protocol

public protocol NetworkConfigurationProtocol {
    var baseURL: URL { get }
    var defaultHeaders: [String: String] { get }
    var timeoutInterval: TimeInterval { get }
    var cachePolicy: URLRequest.CachePolicy { get }
    var jsonEncoder: JSONEncoder { get }
    var jsonDecoder: JSONDecoder { get }
}

// MARK: - NetworkConfiguration

public final class NetworkConfiguration: NetworkConfigurationProtocol {

    // MARK: - Storage key

    /// UserDefaults / Keychain key for the persisted auth token.
    /// Override if your app uses a different key.
    public var tokenStorageKey: String = "com.networkingsdk.auth_token"

    /// Header name the token is injected into. Default: "Authorization".
    public var authorizationHeaderKey: String = "Authorization"

    // MARK: - Properties

    public private(set) var baseURL: URL
    public private(set) var defaultHeaders: [String: String]
    public let timeoutInterval: TimeInterval
    public let cachePolicy: URLRequest.CachePolicy
    public let jsonEncoder: JSONEncoder
    public let jsonDecoder: JSONDecoder

    /// The backing token store. Swap to KeychainTokenStore for production.
    private let tokenStore: TokenStoreProtocol

    // MARK: - Init

    /// - Parameters:
    ///   - baseURL: Root URL for all requests.
    ///   - defaultHeaders: Headers applied to every request.
    ///   - timeoutInterval: Request timeout in seconds. Default: 30.
    ///   - cachePolicy: URL cache policy. Default: `.useProtocolCachePolicy`.
    ///   - jsonEncoder: Custom JSON encoder.
    ///   - jsonDecoder: Custom JSON decoder.
    ///   - tokenStore: Where tokens are persisted. Default: `UserDefaultsTokenStore`.
    ///                 Pass `KeychainTokenStore()` for encrypted storage.
    public init(
        baseURL: URL,
        defaultHeaders: [String: String] = [:],
        timeoutInterval: TimeInterval = 30,
        cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy,
        jsonEncoder: JSONEncoder = NetworkConfiguration.defaultEncoder(),
        jsonDecoder: JSONDecoder = NetworkConfiguration.defaultDecoder(),
        tokenStore: TokenStoreProtocol = UserDefaultsTokenStore()
    ) {
        self.baseURL        = baseURL
        self.defaultHeaders = defaultHeaders
        self.timeoutInterval = timeoutInterval
        self.cachePolicy    = cachePolicy
        self.jsonEncoder    = jsonEncoder
        self.jsonDecoder    = jsonDecoder
        self.tokenStore     = tokenStore

        // ── Auto-restore persisted token on launch ─────────────────────
        // If a token was saved in a previous session, inject it into
        // headers immediately — the user is already authenticated.
        self.restoreTokenIfAvailable()
    }

    // MARK: - Auth Token Management

    /// Sets the auth token, injects it into every request header,
    /// and **persists it to storage** for the next app launch.
    ///
    /// Call this right after a successful login response.
    ///
    /// ```swift
    /// configuration.setAuthToken(response.token)
    /// // From now on, every request automatically carries:
    /// // Authorization: Bearer <token>
    /// // And it survives app restarts.
    /// ```
    public func setAuthToken(_ token: String) {
        let headerValue = token.hasPrefix("Bearer ") ? token : "Bearer \(token)"
        defaultHeaders[authorizationHeaderKey] = headerValue
        tokenStore.save(token: token, forKey: tokenStorageKey)
    }

    /// Removes the auth token from headers **and** deletes it from storage.
    ///
    /// Call this on logout.
    public func clearAuthToken() {
        defaultHeaders.removeValue(forKey: authorizationHeaderKey)
        tokenStore.delete(forKey: tokenStorageKey)
    }

    /// Returns the raw stored token (without the "Bearer " prefix), or `nil` if not set.
    public var currentToken: String? {
        tokenStore.load(forKey: tokenStorageKey)
    }

    /// `true` if a valid token is currently stored and injected.
    public var hasAuthToken: Bool {
        currentToken != nil
    }

    // MARK: - Other Header Helpers

    /// Sets any default header (non-auth). e.g. locale, device-id.
    public func setDefaultHeader(_ value: String, forKey key: String) {
        defaultHeaders[key] = value
    }

    /// Removes a default header by key.
    public func removeDefaultHeader(forKey key: String) {
        defaultHeaders.removeValue(forKey: key)
    }

    /// Updates the base URL at runtime (e.g. switching staging ↔ production).
    public func updateBaseURL(_ url: URL) {
        self.baseURL = url
    }

    // MARK: - Private

    /// Called once during init. Reads the persisted token and injects it
    /// into defaultHeaders so all requests are authenticated from the first call.
    private func restoreTokenIfAvailable() {
        guard let saved = tokenStore.load(forKey: tokenStorageKey) else {
            return      // No token saved — user not logged in yet
        }
        let headerValue = saved.hasPrefix("Bearer ") ? saved : "Bearer \(saved)"
        defaultHeaders[authorizationHeaderKey] = headerValue
    }

    // MARK: - Encoder / Decoder Defaults

    public static func defaultEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting     = [.sortedKeys]
        return encoder
    }

    public static func defaultDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
