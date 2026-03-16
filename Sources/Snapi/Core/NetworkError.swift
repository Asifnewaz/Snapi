// NetworkError.swift
// NetworkingSDK
//
// Single exhaustive error type for the entire SDK.
// All public API surfaces return or throw NetworkError.

import Foundation

/// Comprehensive error type covering every failure mode in the SDK.
/// Conforms to `LocalizedError` for human-readable messages in UI layers.
public enum NetworkError: Error {

    // MARK: - Configuration Errors

    /// The base URL stored in NetworkConfiguration is malformed.
    case invalidBaseURL

    /// A constructed URL (base + path + params) could not be formed.
    case invalidURL(String)

    /// A URLRequest could not be assembled (missing required components).
    case invalidRequest(String)

    // MARK: - Encoding / Decoding

    /// JSON serialization of the request body failed.
    case encodingFailed(Error)

    /// Decoding the server response into the expected `Decodable` type failed.
    case decodingFailed(Error)

    // MARK: - Response Errors

    /// The URLResponse is not an HTTPURLResponse or is otherwise unreadable.
    case invalidResponse

    /// The response body was empty where data was expected.
    case noData

    /// A non-2xx HTTP status code was returned.
    case serverError(statusCode: Int, data: Data?)

    /// A generic logical failure returned by the server (mapped from error body).
    case requestFailed(String)

    // MARK: - Transport Errors

    /// The underlying `URLSession` or network stack threw an error.
    case transportError(Error)

    /// The request exceeded the configured timeout interval.
    case timeout

    // MARK: - Upload Errors

    /// A multipart/serial upload operation failed.
    case uploadFailed(String)

    /// A local file URL could not be read or accessed.
    case fileReadFailed(URL)

    // MARK: - Image Errors

    /// Raw bytes from the server could not be converted into a `UIImage`.
    case imageConversionFailed

    /// The image download request itself failed.
    case imageDownloadFailed(String)

    // MARK: - Lifecycle

    /// The request was explicitly cancelled (e.g. via `URLSessionTask.cancel()`).
    case cancelled

    /// A catch-all for errors that don't map to any known category.
    case unknown(Error)
}

// MARK: - LocalizedError

extension NetworkError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "The configured base URL is invalid. Check NetworkConfiguration."

        case .invalidURL(let path):
            return "Could not form a valid URL from path: \(path)"

        case .invalidRequest(let reason):
            return "Request could not be built: \(reason)"

        case .encodingFailed(let error):
            return "Failed to encode request body: \(error.localizedDescription)"

        case .decodingFailed(let error):
            return "Failed to decode server response: \(error.localizedDescription)"

        case .invalidResponse:
            return "Received an invalid or unreadable HTTP response."

        case .noData:
            return "Server returned an empty response body where data was expected."

        case .serverError(let code, _):
            return "Server returned HTTP \(code)."

        case .requestFailed(let message):
            return "Request failed: \(message)"

        case .transportError(let error):
            return "Network transport error: \(error.localizedDescription)"

        case .timeout:
            return "The request timed out. Check your network connection and retry."

        case .uploadFailed(let message):
            return "Upload failed: \(message)"

        case .fileReadFailed(let url):
            return "Could not read file at path: \(url.path)"

        case .imageConversionFailed:
            return "Downloaded bytes could not be converted into a valid image."

        case .imageDownloadFailed(let message):
            return "Image download failed: \(message)"

        case .cancelled:
            return "The request was cancelled."

        case .unknown(let error):
            return "An unexpected error occurred: \(error.localizedDescription)"
        }
    }
}

// MARK: - Equatable (for unit testing)

extension NetworkError: Equatable {
    public static func == (lhs: NetworkError, rhs: NetworkError) -> Bool {
        switch (lhs, rhs) {
        case (.invalidBaseURL, .invalidBaseURL): return true
        case (.invalidURL(let a), .invalidURL(let b)): return a == b
        case (.invalidRequest(let a), .invalidRequest(let b)): return a == b
        case (.invalidResponse, .invalidResponse): return true
        case (.noData, .noData): return true
        case (.timeout, .timeout): return true
        case (.cancelled, .cancelled): return true
        case (.imageConversionFailed, .imageConversionFailed): return true
        case (.uploadFailed(let a), .uploadFailed(let b)): return a == b
        case (.imageDownloadFailed(let a), .imageDownloadFailed(let b)): return a == b
        case (.requestFailed(let a), .requestFailed(let b)): return a == b
        case (.serverError(let a, _), .serverError(let b, _)): return a == b
        case (.fileReadFailed(let a), .fileReadFailed(let b)): return a == b
        // Errors wrapping underlying Error are compared by domain/code
        case (.encodingFailed(let a), .encodingFailed(let b)):
            return (a as NSError).domain == (b as NSError).domain
        case (.decodingFailed(let a), .decodingFailed(let b)):
            return (a as NSError).domain == (b as NSError).domain
        case (.transportError(let a), .transportError(let b)):
            return (a as NSError).domain == (b as NSError).domain
        case (.unknown(let a), .unknown(let b)):
            return (a as NSError).domain == (b as NSError).domain
        default: return false
        }
    }
}
