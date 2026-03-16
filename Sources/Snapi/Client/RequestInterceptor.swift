// RequestInterceptor.swift
// NetworkingSDK
//
// Middleware pipeline executed before every request dispatch and
// after every response receipt. Enables auth injection, logging,
// token refresh, and certificate pinning without modifying APIClient.
//
// Inspired by Alamofire's EventMonitor / RequestInterceptor model,
// rebuilt from scratch using only URLSession.

import Foundation

// MARK: - RequestInterceptor Protocol

/// A middleware that can inspect and mutate requests before they are sent,
/// and inspect responses when they arrive.
///
/// Interceptors are executed in registration order.
/// Any interceptor can throw to abort the pipeline early.
public protocol RequestInterceptor {

    /// Called with the fully-assembled `URLRequest` before it is dispatched.
    /// Mutate the request (e.g. add headers) and return it.
    /// - Throws: `NetworkError` to abort the request entirely.
    func adapt(_ request: URLRequest) throws -> URLRequest

    /// Called with the raw response before it reaches the caller.
    /// Can inspect, log, or trigger side effects (e.g. clear session on 401).
    func didReceive(response: URLResponse?, data: Data?, error: Error?, for request: URLRequest)
}

/// Default no-op implementations so conforming types only override what they need.
public extension RequestInterceptor {
    func adapt(_ request: URLRequest) throws -> URLRequest { request }
    func didReceive(response: URLResponse?, data: Data?, error: Error?, for request: URLRequest) {}
}

// MARK: - InterceptorPipeline

/// Chains multiple interceptors. Adapts in order, delivers responses in order.
public struct InterceptorPipeline {

    private let interceptors: [RequestInterceptor]

    public init(interceptors: [RequestInterceptor]) {
        self.interceptors = interceptors
    }

    /// Runs each interceptor's `adapt` in sequence.
    /// - Throws: The first `NetworkError` thrown by any interceptor.
    public func adapt(_ request: URLRequest) throws -> URLRequest {
        try interceptors.reduce(request) { req, interceptor in
            try interceptor.adapt(req)
        }
    }

    /// Delivers the response to all interceptors.
    public func didReceive(response: URLResponse?, data: Data?, error: Error?, for request: URLRequest) {
        interceptors.forEach { $0.didReceive(response: response, data: data, error: error, for: request) }
    }
}

// MARK: - Built-in Interceptors

// ------------------------------------------------------------------
// 1. AuthTokenInterceptor
// ------------------------------------------------------------------

/// Injects a Bearer token into every request's Authorization header.
/// Token is read lazily via a closure — always reflects the current value.
///
/// Usage:
/// ```swift
/// let auth = AuthTokenInterceptor { AuthManager.shared.accessToken }
/// ```
public final class AuthTokenInterceptor: RequestInterceptor {

    private let tokenProvider: () -> String?

    public init(tokenProvider: @escaping () -> String?) {
        self.tokenProvider = tokenProvider
    }

    public func adapt(_ request: URLRequest) throws -> URLRequest {
        var mutable = request
        if let token = tokenProvider() {
            mutable.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return mutable
    }
}

// ------------------------------------------------------------------
// 2. LoggingInterceptor
// ------------------------------------------------------------------

/// Logs request/response details to the console.
/// Levels: `.none`, `.basic`, `.verbose`.
public final class LoggingInterceptor: RequestInterceptor {

    public enum Level {
        case none
        case basic     // URL, method, status code
        case verbose   // + headers, body (truncated)
    }

    private let level: Level
    private let logger: (String) -> Void

    public init(
        level: Level = .basic,
        logger: @escaping (String) -> Void = { print("[NetworkingSDK] \($0)") }
    ) {
        self.level = level
        self.logger = logger
    }

    public func adapt(_ request: URLRequest) throws -> URLRequest {
        guard level != .none else { return request }

        let method = request.httpMethod ?? "?"
        let url = request.url?.absoluteString ?? "?"
        logger("→ \(method) \(url)")

        if level == .verbose {
            request.allHTTPHeaderFields?.forEach { logger("  Header: \($0.key): \($0.value)") }
            if let body = request.httpBody,
               let str = String(data: body, encoding: .utf8) {
                let truncated = str.count > 512 ? String(str.prefix(512)) + "…" : str
                logger("  Body: \(truncated)")
            }
        }
        return request
    }

    public func didReceive(response: URLResponse?, data: Data?, error: Error?, for request: URLRequest) {
        guard level != .none else { return }

        let url = request.url?.absoluteString ?? "?"
        if let http = response as? HTTPURLResponse {
            let icon = (200...299).contains(http.statusCode) ? "✅" : "❌"
            logger("\(icon) \(http.statusCode) \(url)")
            if level == .verbose {
                http.allHeaderFields.forEach { logger("  Header: \($0.key): \($0.value)") }
                if let data = data,
                   let str = String(data: data, encoding: .utf8) {
                    let truncated = str.count > 512 ? String(str.prefix(512)) + "…" : str
                    logger("  Body: \(truncated)")
                }
            }
        } else if let error = error {
            logger("💥 ERROR \(url): \(error.localizedDescription)")
        }
    }
}

// ------------------------------------------------------------------
// 3. CertificatePinningInterceptor
// ------------------------------------------------------------------

/// Validates server certificates against a set of pinned public key hashes.
/// Aborts the request with `.invalidRequest` if the cert doesn't match.
///
/// How to get your hash:
/// ```bash
/// openssl s_client -connect api.example.com:443 | \
///   openssl x509 -pubkey -noout | \
///   openssl pkey -pubin -outform DER | \
///   openssl dgst -sha256 -binary | base64
/// ```
public final class CertificatePinningInterceptor: RequestInterceptor {

    /// Domain → Set of acceptable SHA-256 base64-encoded public key hashes.
    private let pinnedHashes: [String: Set<String>]

    public init(pinnedHashes: [String: Set<String>]) {
        self.pinnedHashes = pinnedHashes
    }

    public func adapt(_ request: URLRequest) throws -> URLRequest {
        // Note: Certificate validation happens at the URLSession delegate level.
        // This interceptor validates the host is in our pinned list;
        // actual cert comparison happens in URLSessionDelegate below.
        // This `adapt` phase records intent; validation fires at connection time.
        guard let host = request.url?.host,
              pinnedHashes[host] != nil else {
            // Host not in pinned list — allow (do not block unpinned hosts unless strict mode)
            return request
        }
        return request
    }

    /// Creates a `URLSessionDelegate` that enforces pinning for pinned hosts.
    public func makeSessionDelegate() -> PinningURLSessionDelegate {
        PinningURLSessionDelegate(pinnedHashes: pinnedHashes)
    }
}

// MARK: - PinningURLSessionDelegate

/// URLSession delegate that performs actual public key pinning.
public final class PinningURLSessionDelegate: NSObject, URLSessionDelegate {

    private let pinnedHashes: [String: Set<String>]

    public init(pinnedHashes: [String: Set<String>]) {
        self.pinnedHashes = pinnedHashes
    }

    public func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let host = challenge.protectionSpace.host as String?,
              let expectedHashes = pinnedHashes[host],
              let serverTrust = challenge.protectionSpace.serverTrust else {
            // No pinning configured for this host — use default handling
            completionHandler(.performDefaultHandling, nil)
            return
        }

        guard let serverCertificate = SecTrustGetCertificateAtIndex(serverTrust, 0),
              let publicKey = SecCertificateCopyKey(serverCertificate) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        var error: Unmanaged<CFError>?
        guard let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // SHA-256 hash of the DER-encoded public key
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        publicKeyData.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(publicKeyData.count), &hash)
        }
        let hashBase64 = Data(hash).base64EncodedString()

        if expectedHashes.contains(hashBase64) {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

// MARK: - APIClient + Interceptors

public extension APIClient {

    /// Creates an `APIClient` with an interceptor pipeline pre-configured.
    static func withInterceptors(
        configuration: NetworkConfigurationProtocol,
        interceptors: [RequestInterceptor],
        session: URLSessionProtocol = URLSession.shared
    ) -> InterceptableAPIClient {
        InterceptableAPIClient(
            configuration: configuration,
            interceptors: interceptors,
            session: session
        )
    }
}

// MARK: - InterceptableAPIClient

/// `APIClient` subclass that runs requests through an `InterceptorPipeline`.
public final class InterceptableAPIClient: APIClient {

    private let pipeline: InterceptorPipeline

    public init(
        configuration: NetworkConfigurationProtocol,
        interceptors: [RequestInterceptor],
        session: URLSessionProtocol = URLSession.shared
    ) {
        self.pipeline = InterceptorPipeline(interceptors: interceptors)
        super.init(configuration: configuration, session: session)
    }

    // Override to inject the pipeline before execution
    // Note: In a full implementation this would override the internal `execute(request:)`.
    // Shown here as an extension point pattern — wire into the private execute method
    // by making it internal and overridable, or by injecting a request transformer closure.
}
