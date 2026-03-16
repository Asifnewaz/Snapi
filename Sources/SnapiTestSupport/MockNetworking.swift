// MockNetworking.swift
// NetworkingSDK — TestSupport
//
// Drop-in test doubles for all injectable SDK dependencies.
// Import only in test targets. Never ship in production.

import Foundation
import UIKit

// MARK: - MockURLSessionDataTask

public final class MockURLSessionDataTask: URLSessionDataTaskProtocol {
    public var didResume = false
    public var didCancel = false

    public func resume() { didResume = true }
    public func cancel() { didCancel = true }
}

// MARK: - MockURLSessionUploadTask

public final class MockURLSessionUploadTask: URLSessionUploadTaskProtocol {
    public var didResume = false
    public var didCancel = false

    public func resume() { didResume = true }
    public func cancel() { didCancel = true }
}

// MARK: - MockURLSession

/// Stubs out URLSession responses for unit testing.
///
/// Usage:
/// ```swift
/// let mock = MockURLSession()
/// mock.stubbedData = try JSONEncoder().encode(myModel)
/// mock.stubbedResponse = HTTPURLResponse(url: url, statusCode: 200, ...)
/// let client = APIClient(configuration: config, session: mock)
/// ```
public final class MockURLSession: URLSessionProtocol {

    // MARK: - Stubs

    public var stubbedData: Data?
    public var stubbedResponse: URLResponse?
    public var stubbedError: Error?

    /// Override per-request if you need different responses for different URLs.
    public var requestHandler: ((URLRequest) -> (Data?, URLResponse?, Error?))?

    // MARK: - Captured Requests

    public private(set) var capturedDataRequests: [URLRequest] = []
    public private(set) var capturedUploadRequests: [URLRequest] = []

    public init() {}

    // MARK: - URLSessionProtocol

    public func dataTask(
        with request: URLRequest,
        completionHandler: @escaping @Sendable (Data?, URLResponse?, Error?) -> Void
    ) -> URLSessionDataTaskProtocol {
        capturedDataRequests.append(request)

        let (data, response, error): (Data?, URLResponse?, Error?)
        if let handler = requestHandler {
            (data, response, error) = handler(request)
        } else {
            (data, response, error) = (stubbedData, stubbedResponse, stubbedError)
        }

        let task = MockURLSessionDataTask()
        // Dispatch async to mimic real URLSession behaviour
        DispatchQueue.global().async {
            completionHandler(data, response, error)
        }
        return task
    }

    public func uploadTask(
        with request: URLRequest,
        from bodyData: Data,
        completionHandler: @escaping @Sendable (Data?, URLResponse?, Error?) -> Void
    ) -> URLSessionUploadTaskProtocol {
        capturedUploadRequests.append(request)

        let (data, response, error): (Data?, URLResponse?, Error?)
        if let handler = requestHandler {
            (data, response, error) = handler(request)
        } else {
            (data, response, error) = (stubbedData, stubbedResponse, stubbedError)
        }

        let task = MockURLSessionUploadTask()
        DispatchQueue.global().async {
            completionHandler(data, response, error)
        }
        return task
    }

    // MARK: - Helpers

    /// Resets all captured state and stubs between tests.
    public func reset() {
        stubbedData = nil
        stubbedResponse = nil
        stubbedError = nil
        requestHandler = nil
        capturedDataRequests.removeAll()
        capturedUploadRequests.removeAll()
    }

    /// Convenience: stub a successful JSON-encoded response.
    public func stubSuccess<T: Encodable>(
        _ value: T,
        statusCode: Int = 200,
        url: URL = URL(string: "https://example.com")!,
        encoder: JSONEncoder = JSONEncoder()
    ) throws {
        stubbedData = try encoder.encode(value)
        stubbedResponse = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )
        stubbedError = nil
    }

    /// Convenience: stub an HTTP error response.
    public func stubHTTPError(
        statusCode: Int,
        url: URL = URL(string: "https://example.com")!
    ) {
        stubbedData = Data("{\"error\":\"Server error\"}".utf8)
        stubbedResponse = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )
        stubbedError = nil
    }

    /// Convenience: stub a transport-level error (e.g. no network).
    public func stubTransportError(_ error: Error) {
        stubbedData = nil
        stubbedResponse = nil
        stubbedError = error
    }
}

// MARK: - MockImageDownloader

public final class MockImageDownloader: ImageDownloaderProtocol {
    public var stubbedResult: Result<UIImage, NetworkError> = .failure(.noData)
    public private(set) var capturedURLStrings: [String] = []

    public init() {}

    public func downloadImage(
        from urlString: String,
        headers: [String: String]?,
        completion: @escaping (Result<UIImage, NetworkError>) -> Void
    ) {
        capturedURLStrings.append(urlString)
        DispatchQueue.main.async {
            completion(self.stubbedResult)
        }
    }
}

// MARK: - MockResponseDecoder

public final class MockResponseDecoder: ResponseDecoderProtocol {
    public var stubbedResult: Any?
    public var stubbedError: Error?

    public init() {}

    public func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        if let error = stubbedError { throw NetworkError.decodingFailed(error) }
        guard let result = stubbedResult as? T else {
            throw NetworkError.decodingFailed(
                NSError(domain: "MockDecoder", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "Stubbed result type mismatch"
                ])
            )
        }
        return result
    }
}
