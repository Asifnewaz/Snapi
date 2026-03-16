// RetryPolicy.swift
// NetworkingSDK
//
// Configurable retry engine with exponential backoff and optional jitter.
// Integrates with APIClient via a middleware/interceptor pattern.
// Retries are transparent to callers — they receive only the final result.

import Foundation

// MARK: - RetryPolicy

/// Defines whether and how a failed request should be retried.
public struct RetryPolicy {

    // MARK: - Properties

    /// Maximum number of retry attempts (not counting the original request).
    public let maxRetries: Int

    /// Base delay in seconds between attempts.
    public let baseDelay: TimeInterval

    /// Multiplier applied to delay on each successive retry (exponential backoff).
    /// Set to 1.0 for constant delay.
    public let backoffMultiplier: Double

    /// Maximum delay cap regardless of backoff calculation.
    public let maxDelay: TimeInterval

    /// Whether to add random jitter to prevent thundering-herd on retry storms.
    public let addJitter: Bool

    /// The set of `NetworkError` cases that should trigger a retry.
    /// Defaults to transient errors: timeout, transport errors.
    public let retryableErrors: (NetworkError) -> Bool

    // MARK: - Presets

    /// No retries. Requests fail immediately on first error.
    public static let none = RetryPolicy(maxRetries: 0)

    /// 3 retries, 1s → 2s → 4s exponential backoff with jitter. Retries transient errors only.
    public static let `default` = RetryPolicy(
        maxRetries: 3,
        baseDelay: 1.0,
        backoffMultiplier: 2.0,
        maxDelay: 30.0,
        addJitter: true
    )

    /// Aggressive retry for unreliable connections: 5 retries, fast start.
    public static let aggressive = RetryPolicy(
        maxRetries: 5,
        baseDelay: 0.5,
        backoffMultiplier: 1.5,
        maxDelay: 10.0,
        addJitter: true
    )

    // MARK: - Init

    public init(
        maxRetries: Int = 0,
        baseDelay: TimeInterval = 1.0,
        backoffMultiplier: Double = 2.0,
        maxDelay: TimeInterval = 30.0,
        addJitter: Bool = true,
        retryableErrors: @escaping (NetworkError) -> Bool = RetryPolicy.defaultRetryableErrors
    ) {
        self.maxRetries = maxRetries
        self.baseDelay = baseDelay
        self.backoffMultiplier = backoffMultiplier
        self.maxDelay = maxDelay
        self.addJitter = addJitter
        self.retryableErrors = retryableErrors
    }

    // MARK: - Delay Calculation

    /// Computes the delay before attempt number `attemptIndex` (0-based, where 0 = first retry).
    public func delay(forAttempt attemptIndex: Int) -> TimeInterval {
        let exponential = baseDelay * pow(backoffMultiplier, Double(attemptIndex))
        let capped = min(exponential, maxDelay)
        if addJitter {
            let jitter = Double.random(in: 0..<(capped * 0.25))
            return capped + jitter
        }
        return capped
    }

    // MARK: - Default Retry Predicate

    /// Retries transient network errors only. Server errors (4xx, 5xx) are not retried
    /// by default — they represent intentional server responses.
    public static func defaultRetryableErrors(_ error: NetworkError) -> Bool {
        switch error {
        case .timeout, .transportError:
            return true
        case .serverError(let code, _):
            // Retry 503 Service Unavailable and 429 Too Many Requests
            return code == 503 || code == 429
        default:
            return false
        }
    }
}

// MARK: - RetryExecutor

/// Wraps any async throwing operation with retry logic defined by a `RetryPolicy`.
public struct RetryExecutor {

    private let policy: RetryPolicy

    public init(policy: RetryPolicy = .default) {
        self.policy = policy
    }

    /// Executes `operation`, retrying on eligible errors per the configured policy.
    ///
    /// - Parameter operation: An `async throws` closure returning `T`.
    /// - Returns: The result from the first successful attempt.
    /// - Throws: The last `NetworkError` if all attempts are exhausted.
    public func execute<T>(_ operation: () async throws -> T) async throws -> T {
        var lastError: NetworkError = .unknown(NSError(domain: "RetryExecutor", code: -1))
        var attempt = 0

        while attempt <= policy.maxRetries {
            do {
                return try await operation()
            } catch let error as NetworkError {
                lastError = error

                guard attempt < policy.maxRetries,
                      policy.retryableErrors(error) else {
                    throw error
                }

                let delay = policy.delay(forAttempt: attempt)
                attempt += 1

                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                // Non-NetworkError — don't retry
                throw error
            }
        }

        throw lastError
    }
}

// MARK: - APIClient + Retry

public extension APIClient {

    /// GET with automatic retry on transient errors.
    ///
    /// - Parameters:
    ///   - path: Endpoint path.
    ///   - queryParameters: Optional query parameters.
    ///   - headers: Optional per-request headers.
    ///   - retryPolicy: Retry behaviour. Defaults to `.default` (3 retries, exponential backoff).
    @discardableResult
    func get<T: Decodable>(
        path: String,
        queryParameters: [String: String]? = nil,
        headers: [String: String]? = nil,
        retryPolicy: RetryPolicy
    ) async throws -> T {
        let executor = RetryExecutor(policy: retryPolicy)
        return try await executor.execute {
            try await self.get(path: path, queryParameters: queryParameters, headers: headers)
        }
    }

    /// POST with automatic retry on transient errors.
    @discardableResult
    func post<T: Decodable>(
        path: String,
        body: [String: Any]? = nil,
        headers: [String: String]? = nil,
        retryPolicy: RetryPolicy
    ) async throws -> T {
        let executor = RetryExecutor(policy: retryPolicy)
        return try await executor.execute {
            try await self.post(path: path, body: body, headers: headers)
        }
    }
}
