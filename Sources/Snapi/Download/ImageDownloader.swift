// ImageDownloader.swift
// NetworkingSDK
//
// Dedicated component for downloading UIImages.
// Separated from APIClient because image loading has distinct caching
// and lifecycle requirements in production apps.

import Foundation
import UIKit

// MARK: - Protocol

/// Contract for image downloading. Mock in unit tests.
public protocol ImageDownloaderProtocol {
    func downloadImage(
        from urlString: String,
        headers: [String: String]?,
        completion: @escaping (Result<UIImage, NetworkError>) -> Void
    )
}

// MARK: - ImageDownloader

public final class ImageDownloader: ImageDownloaderProtocol {

    // MARK: - Dependencies

    private let session: URLSessionProtocol
    private let configuration: NetworkConfigurationProtocol

    // MARK: - Init

    public init(
        session: URLSessionProtocol = URLSession.shared,
        configuration: NetworkConfigurationProtocol
    ) {
        self.session = session
        self.configuration = configuration
    }

    // MARK: - Public API

    /// Downloads an image from an absolute URL string.
    ///
    /// - Parameters:
    ///   - urlString: Full URL to the image (not relative to base URL).
    ///   - headers: Optional per-request headers merged with defaults.
    ///   - completion: Called on the main queue with the result.
    public func downloadImage(
        from urlString: String,
        headers: [String: String]? = nil,
        completion: @escaping (Result<UIImage, NetworkError>) -> Void
    ) {
        guard let url = URL(string: urlString) else {
            complete(completion, with: .failure(.invalidURL(urlString)))
            return
        }

        var request = URLRequest(
            url: url,
            cachePolicy: configuration.cachePolicy,
            timeoutInterval: configuration.timeoutInterval
        )

        // Merge global defaults with per-request headers
        var merged = configuration.defaultHeaders
        headers?.forEach { merged[$0.key] = $0.value }
        request.allHTTPHeaderFields = merged

        let task = session.api_dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }

            if let error = error {
                let mapped = self.mapTransportError(error)
                self.complete(completion, with: .failure(mapped))
                return
            }

            do {
                try HTTPResponseValidator.validate(response: response, data: data)
            } catch let networkError as NetworkError {
                self.complete(completion, with: .failure(networkError))
                return
            } catch {
                self.complete(completion, with: .failure(.unknown(error)))
                return
            }

            guard let data = data else {
                self.complete(completion, with: .failure(.noData))
                return
            }

            guard let image = UIImage(data: data) else {
                self.complete(completion, with: .failure(.imageConversionFailed))
                return
            }

            self.complete(completion, with: .success(image))
        }
        task.resume()
    }

    // MARK: - Helpers

    private func mapTransportError(_ error: Error) -> NetworkError {
        let nsError = error as NSError
        if nsError.code == NSURLErrorTimedOut {
            return .timeout
        }
        if nsError.code == NSURLErrorCancelled {
            return .cancelled
        }
        return .transportError(error)
    }

    private func complete<T>(
        _ completion: @escaping (Result<T, NetworkError>) -> Void,
        with result: Result<T, NetworkError>
    ) {
        DispatchQueue.main.async {
            completion(result)
        }
    }
}
