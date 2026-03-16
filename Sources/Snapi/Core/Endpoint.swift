// Endpoint.swift
// NetworkingSDK
//
// Endpoint is the single source of truth for describing an HTTP request.
// RequestBuilder consumes it to produce a URLRequest.

import Foundation

// MARK: - ParameterEncoding

/// Defines WHERE and HOW the endpoint's parameters are sent.
///
/// Use this to explicitly control whether data goes as URL query items
/// or as a JSON body — regardless of HTTP method.
///
/// Rules of thumb:
///   GET / DELETE / HEAD  → always use `.queryString`
///   POST / PUT / PATCH   → use `.jsonBody`
///   POST with filters    → can use `.both` (body + extra query params)
///
/// Example:
/// ```swift
/// // Search endpoint — params go in the URL
/// struct SearchUsers: Endpoint {
///     var method: HTTPMethod     { .GET }
///     var parameterEncoding: ParameterEncoding { .queryString }
///     var parameters: [String: Any]? { ["q": query, "page": page] }
/// }
///
/// // Login endpoint — credentials go in the JSON body
/// struct Login: Endpoint {
///     var method: HTTPMethod     { .POST }
///     var parameterEncoding: ParameterEncoding { .jsonBody }
///     var parameters: [String: Any]? { ["email": email, "password": password] }
/// }
/// ```
public enum ParameterEncoding {

    /// Parameters are URL-encoded as query items: `/users?page=1&limit=20`
    /// Required for GET, HEAD, DELETE. Safe for POST when no body is needed.
    case queryString

    /// Parameters are JSON-encoded into the request body.
    /// Sets `Content-Type: application/json` automatically.
    /// Must NOT be used with GET/HEAD — URLSession will reject it.
    case jsonBody

    /// Query items go to the URL; body params go to the JSON body.
    /// Useful for POST endpoints that also accept filter/version query params.
    /// - Parameters:
    ///   - queryKeys: Keys routed to the URL. Remaining keys go to the body.
    case both(queryKeys: Set<String>)
}

// MARK: - Endpoint Protocol

/// Contract describing everything needed to build one HTTP request.
/// Conforming types represent specific API endpoints in the consuming app.
public protocol Endpoint {

    /// Path component appended to the base URL (e.g. "/users/profile").
    var path: String { get }

    /// HTTP method for this endpoint.
    var method: HTTPMethod { get }

    /// Controls whether `parameters` are sent as query items, JSON body, or both.
    /// Default: `.queryString` for GET/HEAD/DELETE, `.jsonBody` for POST/PUT/PATCH.
    var parameterEncoding: ParameterEncoding { get }

    /// All parameters for this request. Routing is determined by `parameterEncoding`.
    var parameters: [String: Any]? { get }

    /// Headers specific to this endpoint. Merged with global defaults.
    var headers: [String: String] { get }
}

// MARK: - Smart Defaults

public extension Endpoint {

    /// Automatically picks the right encoding based on HTTP method:
    /// - GET / HEAD / DELETE → `.queryString`
    /// - POST / PUT / PATCH  → `.jsonBody`
    var parameterEncoding: ParameterEncoding {
        switch method {
        case .GET, .HEAD, .DELETE, .OPTIONS:
            return .queryString
        default:
            return .jsonBody
        }
    }

    var parameters: [String: Any]? { nil }
    var headers: [String: String] { [:] }
}

// MARK: - Derived Query / Body helpers (used by RequestBuilder)

public extension Endpoint {

    /// Parameters destined for the URL query string.
    var queryParameters: [String: String]? {
        switch parameterEncoding {
        case .queryString:
            return parameters?.compactMapValues { "\($0)" }
        case .jsonBody:
            return nil
        case .both(let queryKeys):
            let filtered = parameters?.filter { queryKeys.contains($0.key) }
            return filtered?.compactMapValues { "\($0)" }
        }
    }

    /// Parameters destined for the JSON body.
    var bodyParameters: [String: Any]? {
        switch parameterEncoding {
        case .queryString:
            return nil
        case .jsonBody:
            return parameters
        case .both(let queryKeys):
            return parameters?.filter { !queryKeys.contains($0.key) }
        }
    }
}

// MARK: - AnyEndpoint (ad-hoc / test convenience)

/// A concrete, value-type endpoint for quick construction without defining a new type.
/// Use typed endpoint structs in production; use this in tests or rapid prototyping.
public struct AnyEndpoint: Endpoint {
    public let path: String
    public let method: HTTPMethod
    public let parameterEncoding: ParameterEncoding
    public let parameters: [String: Any]?
    public let headers: [String: String]

    public init(
        path: String,
        method: HTTPMethod = .GET,
        parameterEncoding: ParameterEncoding? = nil,      // nil = auto-detect from method
        parameters: [String: Any]? = nil,
        headers: [String: String] = [:]
    ) {
        self.path = path
        self.method = method
        self.parameters = parameters
        self.headers = headers

        // Auto-detect encoding if not explicitly set
        if let explicit = parameterEncoding {
            self.parameterEncoding = explicit
        } else {
            switch method {
            case .GET, .HEAD, .DELETE, .OPTIONS:
                self.parameterEncoding = .queryString
            default:
                self.parameterEncoding = .jsonBody
            }
        }
    }
}
