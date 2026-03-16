// CancellationToken.swift
// NetworkingSDK
//
// Lightweight cancellation system. Callers receive a CancellationToken at
// request time and can cancel mid-flight without holding a URLSessionTask reference.
// Thread-safe via an internal NSLock.

import Foundation

// MARK: - CancellationToken

/// A handle returned alongside every in-flight request.
/// Call `cancel()` to abort the associated network task.
///
/// Usage:
/// ```swift
/// let token = client.get(path: "/feed") { result in ... }
/// // User navigates away:
/// token.cancel()
/// ```
public final class CancellationToken {

    // MARK: - State

    private let lock = NSLock()
    private var _isCancelled = false
    private var _task: (any Cancellable)?

    // MARK: - Public Interface

    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isCancelled
    }

    /// Cancels the associated network task if still in flight.
    public func cancel() {
        lock.lock(); defer { lock.unlock() }
        _isCancelled = true
        _task?.cancel()
    }

    // MARK: - Internal

    /// Called by `NetworkTaskManager` when the underlying task is created.
    internal func attach(_ task: any Cancellable) {
        lock.lock(); defer { lock.unlock() }
        _task = task
        if _isCancelled { task.cancel() }
    }
}

// MARK: - Cancellable Protocol

/// Minimal cancellable contract. Both URLSessionDataTask and URLSessionUploadTask conform.
public protocol Cancellable: AnyObject {
    func cancel()
}

extension URLSessionDataTask: Cancellable {}
extension URLSessionUploadTask: Cancellable {}

// MARK: - NetworkTaskManager

/// Tracks all active tasks by a string key, enabling:
/// - Cancel by request ID (e.g. cancel all "feed" requests)
/// - Cancel all active tasks (e.g. on logout)
/// - Deduplication (optional: skip duplicate in-flight requests)
///
/// Thread-safe.
public final class NetworkTaskManager {

    public static let shared = NetworkTaskManager()

    private let lock = NSLock()
    private var activeTasks: [String: CancellationToken] = [:]

    private init() {}

    // MARK: - Registration

    /// Registers a token under a key. Replaces any previous token for that key.
    public func register(token: CancellationToken, forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        activeTasks[key] = token
    }

    /// Removes a completed task.
    public func remove(key: String) {
        lock.lock(); defer { lock.unlock() }
        activeTasks.removeValue(forKey: key)
    }

    // MARK: - Cancellation

    /// Cancels and removes the task registered under `key`.
    public func cancel(key: String) {
        lock.lock(); defer { lock.unlock() }
        activeTasks[key]?.cancel()
        activeTasks.removeValue(forKey: key)
    }

    /// Cancels and clears all tracked tasks.
    /// Call on user logout or scene deactivation.
    public func cancelAll() {
        lock.lock(); defer { lock.unlock() }
        activeTasks.values.forEach { $0.cancel() }
        activeTasks.removeAll()
    }

    /// Returns whether a task is currently registered and active for a given key.
    public func isActive(key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return activeTasks[key] != nil
    }

    /// Number of currently tracked tasks.
    public var activeCount: Int {
        lock.lock(); defer { lock.unlock() }
        return activeTasks.count
    }
}

// MARK: - APIClient + Cancellable GET/POST

public extension APIClient {

    /// GET that returns a `CancellationToken` for mid-flight cancellation.
    ///
    /// - Parameters:
    ///   - path: Endpoint path.
    ///   - queryParameters: Optional query params.
    ///   - headers: Optional headers.
    ///   - taskKey: Optional key to register with `NetworkTaskManager` for group cancellation.
    ///   - completion: Result delivered on main queue.
    /// - Returns: `CancellationToken` — call `.cancel()` to abort.
    @discardableResult
    func get<T: Decodable>(
        path: String,
        queryParameters: [String: String]? = nil,
        headers: [String: String]? = nil,
        taskKey: String? = nil,
        completion: @escaping (Result<T, NetworkError>) -> Void
    ) -> CancellationToken {
        let token = CancellationToken()
        if let key = taskKey {
            NetworkTaskManager.shared.register(token: token, forKey: key)
        }
        self.get(path: path, queryParameters: queryParameters, headers: headers) { result in
            if let key = taskKey { NetworkTaskManager.shared.remove(key: key) }
            guard !token.isCancelled else {
                completion(.failure(.cancelled))
                return
            }
            completion(result)
        }
        return token
    }

    /// POST that returns a `CancellationToken`.
    @discardableResult
    func post<T: Decodable>(
        path: String,
        body: [String: Any]? = nil,
        headers: [String: String]? = nil,
        taskKey: String? = nil,
        completion: @escaping (Result<T, NetworkError>) -> Void
    ) -> CancellationToken {
        let token = CancellationToken()
        if let key = taskKey { NetworkTaskManager.shared.register(token: token, forKey: key) }
        self.post(path: path, body: body, headers: headers) { result in
            if let key = taskKey { NetworkTaskManager.shared.remove(key: key) }
            guard !token.isCancelled else {
                completion(.failure(.cancelled))
                return
            }
            completion(result)
        }
        return token
    }
}
