// APIClient+Async.swift
// NetworkingSDK
//
// Swift concurrency (async/await) surface over the completion-handler core.
// Requires iOS 15+. The callback core remains intact for older targets.
// Uses withCheckedThrowingContinuation — no Combine dependency.

import Foundation
import UIKit

// MARK: - Async GET / POST / Execute

public extension APIClient {

    /// Async GET. Throws `NetworkError` on failure.
    ///
    /// - Parameters:
    ///   - path: Endpoint path relative to base URL.
    ///   - queryParameters: Optional URL query items.
    ///   - headers: Optional per-request headers.
    /// - Returns: Decoded model of type `T`.
    @discardableResult
    func get<T: Decodable>(
        path: String,
        queryParameters: [String: String]? = nil,
        headers: [String: String]? = nil
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            self.get(
                path: path,
                queryParameters: queryParameters,
                headers: headers
            ) { (result: Result<T, NetworkError>) in
                continuation.resume(with: result.toSwiftResult())
            }
        }
    }

    /// Async POST. Throws `NetworkError` on failure.
    ///
    /// - Parameters:
    ///   - path: Endpoint path relative to base URL.
    ///   - body: Optional JSON body dictionary.
    ///   - headers: Optional per-request headers.
    /// - Returns: Decoded model of type `T`.
    @discardableResult
    func post<T: Decodable>(
        path: String,
        body: [String: Any]? = nil,
        headers: [String: String]? = nil
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            self.post(
                path: path,
                body: body,
                headers: headers
            ) { (result: Result<T, NetworkError>) in
                continuation.resume(with: result.toSwiftResult())
            }
        }
    }

    /// Async endpoint execution. Throws `NetworkError` on failure.
    @discardableResult
    func execute<T: Decodable>(endpoint: Endpoint) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            self.execute(endpoint: endpoint) { (result: Result<T, NetworkError>) in
                continuation.resume(with: result.toSwiftResult())
            }
        }
    }

    /// Async image download. Throws `NetworkError` on failure.
    func downloadImage(
        from urlString: String,
        headers: [String: String]? = nil
    ) async throws -> UIImage {
        try await withCheckedThrowingContinuation { continuation in
            self.downloadImage(from: urlString, headers: headers) { result in
                continuation.resume(with: result.toSwiftResult())
            }
        }
    }

    /// Async serial upload with an `AsyncStream<UploadProgressState>` for progress.
    ///
    /// Usage:
    /// ```swift
    /// let (stream, result) = try await client.uploadSerialAsync(...)
    /// for await state in stream {
    ///     progressView.progress = Float(state.overallProgress)
    /// }
    /// let batch = await result
    /// ```
    ///
    /// - Returns: A tuple of a progress `AsyncStream` and a `Task` resolving to `UploadBatchResult<T>`.
    func uploadSerialAsync<T: Decodable>(
        path: String,
        items: [UploadItem],
        additionalFields: [String: String]? = nil,
        headers: [String: String]? = nil,
        fileFieldName: String = "file"
    ) -> (
        progress: AsyncStream<UploadProgressState>,
        result: Task<UploadBatchResult<T>, Never>
    ) {
        var progressContinuation: AsyncStream<UploadProgressState>.Continuation?

        let progressStream = AsyncStream<UploadProgressState> { cont in
            progressContinuation = cont
        }

        let resultTask = Task {
            await withCheckedContinuation { (continuation: CheckedContinuation<UploadBatchResult<T>, Never>) in
                self.uploadSerial(
                    path: path,
                    items: items,
                    additionalFields: additionalFields,
                    headers: headers,
                    fileFieldName: fileFieldName,
                    onProgress: { state in
                        progressContinuation?.yield(state)
                    },
                    completion: { batch in
                        progressContinuation?.finish()
                        continuation.resume(returning: batch)
                    }
                )
            }
        }

        return (progress: progressStream, result: resultTask)
    }
}

// MARK: - Result Bridge

private extension Result where Failure == NetworkError {
    /// Converts `Result<T, NetworkError>` to a Swift `Result<T, Error>` for use
    /// with `CheckedContinuation.resume(with:)`.
    func toSwiftResult() -> Result<Success, Error> {
        switch self {
        case .success(let value): return .success(value)
        case .failure(let error): return .failure(error)
        }
    }
}
