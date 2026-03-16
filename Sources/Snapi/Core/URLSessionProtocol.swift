// URLSessionProtocol.swift
// NetworkingSDK
//
// Thin protocol wrapper over URLSession for dependency injection.
// Mock this in unit tests to avoid real network calls.

import Foundation

/// Abstracts URLSession so tests can inject a mock session.
/// Production code uses the real `URLSession`; tests use `MockURLSession`.
public protocol URLSessionProtocol {

    /// Mirrors URLSession.data(for:delegate:) — completion-handler variant for broad iOS support.
    func api_dataTask(
        with request: URLRequest,
        completionHandler: @escaping @Sendable (Data?, URLResponse?, Error?) -> Void
    ) -> URLSessionDataTaskProtocol

    /// Used for upload tasks (multipart, file upload).
    func api_uploadTask(
        with request: URLRequest,
        from bodyData: Data,
        completionHandler: @escaping @Sendable (Data?, URLResponse?, Error?) -> Void
    ) -> URLSessionUploadTaskProtocol
}

/// Abstracts `URLSessionDataTask` to allow mock cancellation.
public protocol URLSessionDataTaskProtocol {
    func resume()
    func cancel()
}

/// Abstracts `URLSessionUploadTask`.
public protocol URLSessionUploadTaskProtocol {
    func resume()
    func cancel()
}

// MARK: - URLSession Conformance

extension URLSession: URLSessionProtocol {

    public func api_dataTask(
        with request: URLRequest,
        completionHandler: @escaping @Sendable (Data?, URLResponse?, Error?) -> Void
    ) -> URLSessionDataTaskProtocol {
        return (dataTask(with: request, completionHandler: completionHandler) as URLSessionDataTask)
    }

    public func api_uploadTask(
        with request: URLRequest,
        from bodyData: Data,
        completionHandler: @escaping @Sendable (Data?, URLResponse?, Error?) -> Void
    ) -> URLSessionUploadTaskProtocol {
        return (uploadTask(with: request, from: bodyData, completionHandler: completionHandler) as URLSessionUploadTask)
    }
}

extension URLSessionDataTask: URLSessionDataTaskProtocol {}
extension URLSessionUploadTask: URLSessionUploadTaskProtocol {}
