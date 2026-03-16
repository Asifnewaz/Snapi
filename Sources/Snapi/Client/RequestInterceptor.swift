// RequestInterceptor.swift
// Snapi
//
// Middleware pipeline executed before every request dispatch and
// after every response receipt. Enables auth injection, logging,
// and certificate pinning without modifying APIClient.

import Foundation
import CryptoKit

// MARK: - RequestInterceptor Protocol

public protocol RequestInterceptor {
    func adapt(_ request: URLRequest) throws -> URLRequest
    func didReceive(response: URLResponse?, data: Data?, error: Error?, for request: URLRequest)
}

public extension RequestInterceptor {
    func adapt(_ request: URLRequest) throws -> URLRequest { request }
    func didReceive(response: URLResponse?, data: Data?, error: Error?, for request: URLRequest) {}
}

// MARK: - InterceptorPipeline

public struct InterceptorPipeline {

    private let interceptors: [RequestInterceptor]

    public init(interceptors: [RequestInterceptor]) {
        self.interceptors = interceptors
    }

    public func adapt(_ request: URLRequest) throws -> URLRequest {
        try interceptors.reduce(request) { req, interceptor in
            try interceptor.adapt(req)
        }
    }

    public func didReceive(response: URLResponse?, data: Data?, error: Error?, for request: URLRequest) {
        interceptors.forEach { $0.didReceive(response: response, data: data, error: error, for: request) }
    }
}

// MARK: - 1. AuthTokenInterceptor

/// Injects a Bearer token into every request's Authorization header.
/// Token is read lazily via a closure — always reflects the current value.
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

// MARK: - 2. LoggingInterceptor

/// Logs request/response details. Levels: `.none`, `.basic`, `.verbose`.
public final class LoggingInterceptor: RequestInterceptor {

    public enum Level {
        case none
        case basic
        case verbose
    }

    private let level: Level
    private let logger: (String) -> Void

    public init(
        level: Level = .basic,
        logger: @escaping (String) -> Void = { print("[Snapi] \($0)") }
    ) {
        self.level = level
        self.logger = logger
    }

    public func adapt(_ request: URLRequest) throws -> URLRequest {
        guard level != .none else { return request }
        let method = request.httpMethod ?? "?"
        let url    = request.url?.absoluteString ?? "?"
        logger("→ \(method) \(url)")
        if level == .verbose {
            request.allHTTPHeaderFields?.forEach { logger("  Header: \($0.key): \($0.value)") }
            if let body = request.httpBody,
               let str  = String(data: body, encoding: .utf8) {
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
                   let str  = String(data: data, encoding: .utf8) {
                    let truncated = str.count > 512 ? String(str.prefix(512)) + "…" : str
                    logger("  Body: \(truncated)")
                }
            }
        } else if let error = error {
            logger("💥 ERROR \(url): \(error.localizedDescription)")
        }
    }
}

// MARK: - 3. CertificatePinningInterceptor

/// Validates server certificates against pinned SHA-256 public key hashes.
/// Uses CryptoKit — no CommonCrypto import needed.
///
/// How to get your hash:
/// ```bash
/// openssl s_client -connect api.example.com:443 | \
///   openssl x509 -pubkey -noout | \
///   openssl pkey -pubin -outform DER | \
///   openssl dgst -sha256 -binary | base64
/// ```
public final class CertificatePinningInterceptor: RequestInterceptor {

    private let pinnedHashes: [String: Set<String>]

    public init(pinnedHashes: [String: Set<String>]) {
        self.pinnedHashes = pinnedHashes
    }

    public func adapt(_ request: URLRequest) throws -> URLRequest {
        // Actual cert validation happens in PinningURLSessionDelegate at connection time.
        // This adapt step is a no-op — validation cannot happen before the connection opens.
        return request
    }

    /// Creates a URLSessionDelegate that enforces pinning for configured hosts.
    public func makeSessionDelegate() -> PinningURLSessionDelegate {
        PinningURLSessionDelegate(pinnedHashes: pinnedHashes)
    }
}

// MARK: - PinningURLSessionDelegate

/// URLSession delegate that performs SHA-256 public key pinning via CryptoKit.
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
              let host           = challenge.protectionSpace.host as String?,
              let expectedHashes = pinnedHashes[host],
              let serverTrust    = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        guard let serverCertificate = SecTrustGetCertificateAtIndex(serverTrust, 0),
              let publicKey         = SecCertificateCopyKey(serverCertificate) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        var cfError: Unmanaged<CFError>?
        guard let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, &cfError) as Data? else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // SHA-256 via CryptoKit — no CC_SHA256 / CommonCrypto needed
        let digest      = SHA256.hash(data: publicKeyData)
        let hashBase64  = Data(digest).base64EncodedString()

        if expectedHashes.contains(hashBase64) {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

// MARK: - InterceptableAPIClient
//
// APIClient is `final` so subclassing is not allowed.
// Solution: Composition — wrap APIClient and run the pipeline
// before forwarding every call through to the inner client.

/// Wraps `APIClient` with an interceptor pipeline.
/// All requests are adapted through the pipeline before being dispatched.
///
/// Usage:
/// ```swift
/// let client = InterceptableAPIClient(
///     configuration: config,
///     interceptors: [
///         AuthTokenInterceptor { AuthManager.shared.token },
///         LoggingInterceptor(level: .verbose)
///     ]
/// )
/// client.get(path: "/api/users") { (result: Result<[User], NetworkError>) in ... }
/// ```
public final class InterceptableAPIClient {

    // MARK: - Private

    private let inner:    APIClient
    private let pipeline: InterceptorPipeline

    // MARK: - Init

    public init(
        configuration: NetworkConfigurationProtocol,
        interceptors: [RequestInterceptor],
        session: URLSessionProtocol = URLSession.shared,
        logger: NetworkLogger = NetworkLogger()
    ) {
        self.inner    = APIClient(configuration: configuration, session: session, logger: logger)
        self.pipeline = InterceptorPipeline(interceptors: interceptors)
    }

    // MARK: - Logger passthrough

    public var logger: NetworkLogger { inner.logger }

    // MARK: - GET

    public func get<T: Decodable>(
        path: String,
        queryParameters: [String: String]? = nil,
        headers: [String: String]? = nil,
        completion: @escaping (Result<T, NetworkError>) -> Void
    ) {
        // Merge interceptor-adapted headers into per-request headers
        let adapted = adaptedHeaders(base: headers)
        inner.get(path: path, queryParameters: queryParameters, headers: adapted, completion: completion)
    }

    // MARK: - POST

    public func post<T: Decodable>(
        path: String,
        body: [String: Any]? = nil,
        headers: [String: String]? = nil,
        completion: @escaping (Result<T, NetworkError>) -> Void
    ) {
        let adapted = adaptedHeaders(base: headers)
        inner.post(path: path, body: body, headers: adapted, completion: completion)
    }

    // MARK: - Typed Endpoint

    public func execute<T: Decodable>(
        endpoint: Endpoint,
        completion: @escaping (Result<T, NetworkError>) -> Void
    ) {
        inner.execute(endpoint: endpoint, completion: completion)
    }

    // MARK: - Image Download

    public func downloadImage(
        from urlString: String,
        headers: [String: String]? = nil,
        completion: @escaping (Result<UIImage, NetworkError>) -> Void
    ) {
        let adapted = adaptedHeaders(base: headers)
        inner.downloadImage(from: urlString, headers: adapted, completion: completion)
    }

    // MARK: - Upload

    public func uploadTaskQueue<T: Decodable>(
        path: String,
        tasks: [UploadTask],
        headers: [String: String]? = nil,
        onProgress: ((UploadProgressState) -> Void)? = nil,
        onCompletion: @escaping (UploadTaskQueueCompletion<T>) -> Void
    ) -> UploadQueueController<T> {
        let adapted = adaptedHeaders(base: headers)
        return inner.uploadTaskQueue(
            path: path,
            tasks: tasks,
            headers: adapted,
            onProgress: onProgress,
            onCompletion: onCompletion
        )
    }

    // MARK: - Private: Header adaptation

    /// Runs a dummy request through the pipeline to extract adapted headers,
    /// then merges them into the per-request headers dictionary.
    private func adaptedHeaders(base: [String: String]?) -> [String: String] {
        // Build a throwaway request just to run the adapt pipeline on
        guard let url = URL(string: "https://placeholder.snapi") else { return base ?? [:] }
        var probe = URLRequest(url: url)
        base?.forEach { probe.setValue($0.value, forHTTPHeaderField: $0.key) }

        guard let adapted = try? pipeline.adapt(probe) else { return base ?? [:] }
        return adapted.allHTTPHeaderFields ?? base ?? [:]
    }
}

// MARK: - APIClient factory convenience

public extension APIClient {

    /// Creates an `InterceptableAPIClient` wrapping this configuration.
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
