// ResponseCache.swift
// NetworkingSDK
//
// Two-tier response cache: NSCache (memory) + FileManager (disk).
// Keyed by request URL + method. Supports per-entry TTL, explicit
// invalidation, and automatic eviction on memory pressure (NSCache).
// Thread-safe.

import Foundation

// MARK: - CachePolicy

/// Controls whether a request reads from / writes to the SDK's response cache.
/// Distinct from URLRequest.CachePolicy — this operates at the decoded-model level.
public enum SDKCachePolicy {
    /// Never use cache. Always hit the network. Do not store response.
    case noCache

    /// Return cached response if valid (within TTL). Fetch and store if not.
    case returnCacheIfValid

    /// Return cached response immediately (even if stale), then refresh in background.
    /// Callers receive two completions: one from cache, one from network.
    case returnCacheThenRefresh

    /// Ignore cache for reading, but store the fresh response for future use.
    case refreshAndStore
}

// MARK: - CachedResponse

private struct CachedResponse: Codable {
    let data: Data
    let storedAt: Date
    let ttl: TimeInterval // seconds

    var isExpired: Bool {
        Date().timeIntervalSince(storedAt) > ttl
    }
}

// MARK: - ResponseCache

/// Thread-safe, TTL-aware two-tier response cache.
public final class ResponseCache {

    // MARK: - Singleton / Injection

    public static let shared = ResponseCache()

    // MARK: - Storage

    private let memoryCache = NSCache<NSString, NSData>()
    private let diskQueue = DispatchQueue(label: "com.networkingsdk.cache.disk", qos: .utility)
    private let diskCacheURL: URL

    // MARK: - Configuration

    /// Default TTL for cached entries (5 minutes).
    public var defaultTTL: TimeInterval = 300

    /// Maximum number of objects held in memory cache.
    public var memoryCountLimit: Int = 100 {
        didSet { memoryCache.countLimit = memoryCountLimit }
    }

    // MARK: - Init

    public init(diskCacheFolderName: String = "NetworkingSDKCache") {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        diskCacheURL = caches.appendingPathComponent(diskCacheFolderName)
        try? FileManager.default.createDirectory(at: diskCacheURL, withIntermediateDirectories: true)
        memoryCache.countLimit = memoryCountLimit
    }

    // MARK: - Public Interface

    /// Stores `data` under the given `key` with an optional TTL override.
    public func store(data: Data, forKey key: String, ttl: TimeInterval? = nil) {
        let entry = CachedResponse(data: data, storedAt: Date(), ttl: ttl ?? defaultTTL)
        guard let encoded = try? JSONEncoder().encode(entry) else { return }

        // Memory
        memoryCache.setObject(encoded as NSData, forKey: key as NSString)

        // Disk (background)
        let fileURL = diskFileURL(for: key)
        diskQueue.async {
            try? encoded.write(to: fileURL, options: .atomic)
        }
    }

    /// Retrieves cached `Data` for `key`. Returns `nil` if not found or expired.
    public func retrieve(forKey key: String) -> Data? {
        // 1. Memory hit
        if let nsData = memoryCache.object(forKey: key as NSString) {
            return decode(nsData as Data)
        }

        // 2. Disk hit (sync on disk queue)
        var result: Data?
        diskQueue.sync {
            let fileURL = diskFileURL(for: key)
            guard let raw = try? Data(contentsOf: fileURL) else { return }
            result = decode(raw)
            if result == nil {
                // Expired — remove stale file
                try? FileManager.default.removeItem(at: fileURL)
            } else {
                // Warm memory cache
                memoryCache.setObject(raw as NSData, forKey: key as NSString)
            }
        }
        return result
    }

    /// Removes cached entry for `key` from both tiers.
    public func invalidate(forKey key: String) {
        memoryCache.removeObject(forKey: key as NSString)
        diskQueue.async { [weak self] in
            guard let self = self else { return }
            try? FileManager.default.removeItem(at: self.diskFileURL(for: key))
        }
    }

    /// Clears the entire cache (memory + disk).
    public func purgeAll() {
        memoryCache.removeAllObjects()
        diskQueue.async { [weak self] in
            guard let self = self else { return }
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: self.diskCacheURL,
                includingPropertiesForKeys: nil
            )) ?? []
            contents.forEach { try? FileManager.default.removeItem(at: $0) }
        }
    }

    // MARK: - Key Generation

    /// Generates a deterministic cache key from a URLRequest.
    public static func key(for request: URLRequest) -> String {
        let url = request.url?.absoluteString ?? ""
        let method = request.httpMethod ?? "GET"
        return "\(method):\(url)".sha256Hash
    }

    // MARK: - Private

    private func decode(_ raw: Data) -> Data? {
        guard let entry = try? JSONDecoder().decode(CachedResponse.self, from: raw),
              !entry.isExpired else { return nil }
        return entry.data
    }

    private func diskFileURL(for key: String) -> URL {
        let safe = key.sha256Hash
        return diskCacheURL.appendingPathComponent(safe).appendingPathExtension("cache")
    }
}

// MARK: - String SHA256 Helper

private extension String {
    var sha256Hash: String {
        // Simple djb2 hash — sufficient for file naming. For cryptographic keys,
        // use CryptoKit.SHA256 (available iOS 13+).
        var hash: UInt64 = 5381
        for char in self.unicodeScalars {
            hash = 127 &* (hash &<< 5) &+ UInt64(char.value)
        }
        return String(hash)
    }
}

// MARK: - APIClient + Cache Extension

public extension APIClient {

    /// GET with SDK-level response caching.
    ///
    /// - Parameters:
    ///   - path: Endpoint path.
    ///   - queryParameters: Optional query params.
    ///   - headers: Optional per-request headers.
    ///   - cachePolicy: Cache read/write strategy. Default: `.returnCacheIfValid`.
    ///   - ttl: Time-to-live in seconds. Defaults to `ResponseCache.shared.defaultTTL`.
    ///   - completion: Delivered on main queue. May be called twice with `.returnCacheThenRefresh`.
    func getCached<T: Decodable>(
        path: String,
        queryParameters: [String: String]? = nil,
        headers: [String: String]? = nil,
        cachePolicy: SDKCachePolicy = .returnCacheIfValid,
        ttl: TimeInterval? = nil,
        completion: @escaping (Result<T, NetworkError>, _ fromCache: Bool) -> Void
    ) {
        let requestURL = buildURLString(path: path, queryParameters: queryParameters)
        let cacheKey = "\(HTTPMethod.GET.rawValue):\(requestURL)"

        switch cachePolicy {

        case .noCache:
            performFreshFetch(path: path, queryParameters: queryParameters, headers: headers, cacheKey: nil, ttl: nil, completion: completion)

        case .returnCacheIfValid:
            if let cached = ResponseCache.shared.retrieve(forKey: cacheKey),
               let decoded = try? ResponseDecoder().decode(T.self, from: cached) {
                DispatchQueue.main.async { completion(.success(decoded), true) }
            } else {
                performFreshFetch(path: path, queryParameters: queryParameters, headers: headers, cacheKey: cacheKey, ttl: ttl, completion: completion)
            }

        case .returnCacheThenRefresh:
            if let cached = ResponseCache.shared.retrieve(forKey: cacheKey),
               let decoded = try? ResponseDecoder().decode(T.self, from: cached) {
                DispatchQueue.main.async { completion(.success(decoded), true) }
            }
            // Always fetch fresh, even if cache hit
            performFreshFetch(path: path, queryParameters: queryParameters, headers: headers, cacheKey: cacheKey, ttl: ttl, completion: completion)

        case .refreshAndStore:
            performFreshFetch(path: path, queryParameters: queryParameters, headers: headers, cacheKey: cacheKey, ttl: ttl, completion: completion)
        }
    }

    // MARK: - Private

    private func performFreshFetch<T: Decodable>(
        path: String,
        queryParameters: [String: String]?,
        headers: [String: String]?,
        cacheKey: String?,
        ttl: TimeInterval?,
        completion: @escaping (Result<T, NetworkError>, Bool) -> Void
    ) {
        self.get(path: path, queryParameters: queryParameters, headers: headers) { (result: Result<T, NetworkError>) in
            if case .success(let model) = result,
               let key = cacheKey,
               let data = try? JSONEncoder().encode(model) {
                ResponseCache.shared.store(data: data, forKey: key, ttl: ttl)
            }
            completion(result, false)
        }
    }

    private func buildURLString(path: String, queryParameters: [String: String]?) -> String {
        var str = path
        if let params = queryParameters, !params.isEmpty {
            let query = params.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "&")
            str += "?\(query)"
        }
        return str
    }
}
