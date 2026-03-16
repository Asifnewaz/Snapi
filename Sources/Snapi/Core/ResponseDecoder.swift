// ResponseDecoder.swift
// NetworkingSDK
//
// Isolated decoding layer. All JSONDecoder logic lives here.
// Swappable and mockable in tests.

import Foundation

/// Contract for decoding raw `Data` into `Decodable` types.
public protocol ResponseDecoderProtocol {
    func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T
}

/// Production decoder wrapping a configurable `JSONDecoder`.
public struct ResponseDecoder: ResponseDecoderProtocol {

    private let decoder: JSONDecoder

    public init(decoder: JSONDecoder = NetworkConfiguration.defaultDecoder()) {
        self.decoder = decoder
    }

    /// Decodes `Data` into the requested `Decodable` type.
    /// - Throws: `NetworkError.decodingFailed` wrapping the original `DecodingError`.
    public func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw NetworkError.decodingFailed(error)
        }
    }
}

// MARK: - Empty Response Support

/// Sentinel type for endpoints that return no meaningful body (e.g. 204 No Content).
/// Use `EmptyResponse` as the generic type parameter when no body is expected.
public struct EmptyResponse: Decodable {
    public init() {}
}

// MARK: - Validated Response Helper

/// Validates an HTTP status code and extracts data, throwing typed errors.
public enum HTTPResponseValidator {

    /// Validates that `response` is an `HTTPURLResponse` with a 2xx status code.
    /// - Parameters:
    ///   - response: The raw `URLResponse` from `URLSession`.
    ///   - data: The response body (passed through for error context).
    /// - Throws: `NetworkError.invalidResponse`, `.timeout`, or `.serverError`.
    public static func validate(response: URLResponse?, data: Data?) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200...299:
            return
        case NSURLErrorTimedOut:
            throw NetworkError.timeout
        default:
            throw NetworkError.serverError(statusCode: httpResponse.statusCode, data: data)
        }
    }
}
