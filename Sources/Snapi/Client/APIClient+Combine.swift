// APIClient+Combine.swift
// NetworkingSDK
//
// Combine publisher wrappers for all APIClient operations.
// Requires iOS 13+. Zero added dependencies — uses only Combine.framework.
// The completion-handler core is unchanged; publishers bridge over it.

import Foundation
import Combine
import UIKit

// MARK: - APIClient + Combine Publishers

public extension APIClient {

    // MARK: GET

    /// Returns a publisher that emits a single decoded value or a `NetworkError`.
    ///
    /// The publisher:
    /// - Never retains `self` past completion
    /// - Delivers on `DispatchQueue.main` (matches callback behavior)
    /// - Is cold — work starts only on `subscribe`
    func getPublisher<T: Decodable>(
        path: String,
        queryParameters: [String: String]? = nil,
        headers: [String: String]? = nil
    ) -> AnyPublisher<T, NetworkError> {
        Deferred {
            Future<T, NetworkError> { [weak self] promise in
                guard let self = self else {
                    promise(.failure(.cancelled))
                    return
                }
                self.get(
                    path: path,
                    queryParameters: queryParameters,
                    headers: headers
                ) { (result: Result<T, NetworkError>) in
                    promise(result)
                }
            }
        }
        .eraseToAnyPublisher()
    }

    // MARK: POST

    /// Returns a publisher for a POST request.
    func postPublisher<T: Decodable>(
        path: String,
        body: [String: Any]? = nil,
        headers: [String: String]? = nil
    ) -> AnyPublisher<T, NetworkError> {
        Deferred {
            Future<T, NetworkError> { [weak self] promise in
                guard let self = self else {
                    promise(.failure(.cancelled))
                    return
                }
                self.post(
                    path: path,
                    body: body,
                    headers: headers
                ) { (result: Result<T, NetworkError>) in
                    promise(result)
                }
            }
        }
        .eraseToAnyPublisher()
    }

    // MARK: Image Download

    /// Returns a publisher for an image download.
    func imagePublisher(
        from urlString: String,
        headers: [String: String]? = nil
    ) -> AnyPublisher<UIImage, NetworkError> {
        Deferred {
            Future<UIImage, NetworkError> { [weak self] promise in
                guard let self = self else {
                    promise(.failure(.cancelled))
                    return
                }
                self.downloadImage(from: urlString, headers: headers) { result in
                    promise(result)
                }
            }
        }
        .eraseToAnyPublisher()
    }

    // MARK: Upload Batch

    /// Returns a publisher that emits `UploadProgressState` values during upload
    /// and completes with `UploadBatchResult<T>`.
    ///
    /// Two subjects are used internally:
    /// - A `PassthroughSubject` for progress events
    /// - A `Future` for the terminal batch result
    ///
    /// Usage:
    /// ```swift
    /// client.uploadPublisher(path: "/upload", items: items)
    ///     .progress
    ///     .sink { print($0.overallProgress) }
    ///     .store(in: &cancellables)
    /// ```
    func uploadPublisher<T: Decodable>(
        path: String,
        items: [UploadItem],
        additionalFields: [String: String]? = nil,
        headers: [String: String]? = nil,
        fileFieldName: String = "file"
    ) -> (
        progress: AnyPublisher<UploadProgressState, Never>,
        result: AnyPublisher<UploadBatchResult<T>, NetworkError>
    ) {
        let progressSubject = PassthroughSubject<UploadProgressState, Never>()
        let resultSubject = PassthroughSubject<UploadBatchResult<T>, NetworkError>()

        let progressPublisher = progressSubject.eraseToAnyPublisher()
        let resultPublisher = resultSubject.eraseToAnyPublisher()

        uploadSerial(
            path: path,
            items: items,
            additionalFields: additionalFields,
            headers: headers,
            fileFieldName: fileFieldName,
            onProgress: { state in
                progressSubject.send(state)
            },
            completion: { batch in
                resultSubject.send(batch)
                resultSubject.send(completion: .finished)
                progressSubject.send(completion: .finished)
            }
        )

        return (progress: progressPublisher, result: resultPublisher)
    }
}

// MARK: - Operator: retry on NetworkError

public extension Publisher where Failure == NetworkError {

    /// Retries the publisher up to `count` times on transient `NetworkError`s.
    /// Non-retryable errors (e.g. `.decodingFailed`) pass through immediately.
    func retryOnTransientError(
        _ count: Int,
        delay: TimeInterval = 1.0
    ) -> AnyPublisher<Output, Failure> {
        self.catch { error -> AnyPublisher<Output, Failure> in
            guard RetryPolicy.defaultRetryableErrors(error), count > 0 else {
                return Fail(error: error).eraseToAnyPublisher()
            }
            return Just(())
                .delay(for: .seconds(delay), scheduler: DispatchQueue.global())
                .flatMap { _ in
                    self.retryOnTransientError(count - 1, delay: delay * 2)
                }
                .eraseToAnyPublisher()
        }
        .eraseToAnyPublisher()
    }
}
