// RequestBuilder.swift
// NetworkingSDK

import Foundation

public struct RequestBuilder {

    private let configuration: NetworkConfigurationProtocol

    public init(configuration: NetworkConfigurationProtocol) {
        self.configuration = configuration
    }

    // MARK: - Primary Build

    public func build(from endpoint: Endpoint) throws -> URLRequest {
        let bodyForbiddenMethods: Set<HTTPMethod> = [.GET, .HEAD, .DELETE, .OPTIONS]
        if bodyForbiddenMethods.contains(endpoint.method),
           let body = endpoint.bodyParameters, !body.isEmpty {
            throw NetworkError.invalidRequest(
                "'\(endpoint.method.rawValue) \(endpoint.path)' has bodyParameters " +
                "but \(endpoint.method.rawValue) must not carry a body. " +
                "Fix: set parameterEncoding = .queryString, or use POST/PUT/PATCH."
            )
        }

        let url = try makeURL(for: endpoint)
        var request = URLRequest(
            url: url,
            cachePolicy: configuration.cachePolicy,
            timeoutInterval: configuration.timeoutInterval
        )
        request.httpMethod          = endpoint.method.rawValue
        request.allHTTPHeaderFields = mergedHeaders(for: endpoint)

        if let body = endpoint.bodyParameters, !body.isEmpty {
            request.httpBody = try encodeBody(body)
            if request.value(forHTTPHeaderField: "Content-Type") == nil {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
        }

        return request
    }

    // MARK: - Convenience builders

    public func buildGET(
        path: String,
        queryParameters: [String: String]? = nil,
        headers: [String: String]? = nil
    ) throws -> URLRequest {
        let params: [String: Any]? = queryParameters.map { $0 as [String: Any] }
        let endpoint = AnyEndpoint(
            path: path,
            method: .GET,
            parameterEncoding: .queryString,
            parameters: params,
            headers: headers ?? [:]
        )
        return try build(from: endpoint)
    }

    public func buildPOST(
        path: String,
        body: [String: Any]?,
        headers: [String: String]? = nil
    ) throws -> URLRequest {
        let endpoint = AnyEndpoint(
            path: path,
            method: .POST,
            parameterEncoding: .jsonBody,
            parameters: body,
            headers: headers ?? [:]
        )
        return try build(from: endpoint)
    }

    // MARK: - Multipart Upload Builder
    //
    // Key difference from buildPOST:
    // queryParameters go through URLComponents.queryItems — NEVER through
    // appendingPathComponent. This prevents ? from being encoded to %3F.
    //
    // Use this for any multipart upload that also needs URL query params.

    public func buildMultipartPOST(
        path: String,
        queryParameters: [String: String]?,
        multipartContentType: String,
        headers: [String: String]? = nil
    ) throws -> URLRequest {

        // Step 1 — clean path → appendingPathComponent (no ? here, safe)
        let base    = configuration.baseURL
        let trimmed = path.hasPrefix("/") ? path : "/" + path

        guard var components = URLComponents(
            url: base.appendingPathComponent(trimmed),
            resolvingAgainstBaseURL: true
        ) else {
            throw NetworkError.invalidURL(path)
        }

        // Step 2 — query params via URLComponents.queryItems
        // URLComponents adds the ? separator itself. It also percent-encodes
        // values correctly (once). The path is already set and untouched.
        if let params = queryParameters, !params.isEmpty {
            components.queryItems = params
                .sorted { $0.key < $1.key }
                .map { URLQueryItem(name: $0.key, value: $0.value) }
        }

        guard let finalURL = components.url else {
            throw NetworkError.invalidURL(path)
        }

        // Step 3 — build URLRequest
        var request = URLRequest(
            url: finalURL,
            cachePolicy: configuration.cachePolicy,
            timeoutInterval: configuration.timeoutInterval
        )
        request.httpMethod = HTTPMethod.POST.rawValue

        // Merge global defaults + per-request headers
        var merged = configuration.defaultHeaders
        headers?.forEach { merged[$0.key] = $0.value }
        // Content-Type always set last — must include the multipart boundary
        merged["Content-Type"] = multipartContentType
        request.allHTTPHeaderFields = merged

        return request
    }

    // MARK: - Private

    private func makeURL(for endpoint: Endpoint) throws -> URL {
        let base    = configuration.baseURL
        let trimmed = endpoint.path.hasPrefix("/") ? endpoint.path : "/" + endpoint.path
        guard var components = URLComponents(
            url: base.appendingPathComponent(trimmed),
            resolvingAgainstBaseURL: true
        ) else {
            throw NetworkError.invalidURL(endpoint.path)
        }

        if let params = endpoint.queryParameters, !params.isEmpty {
            components.queryItems = params
                .sorted { $0.key < $1.key }
                .map { URLQueryItem(name: $0.key, value: $0.value) }
        }

        guard let finalURL = components.url else {
            throw NetworkError.invalidURL(endpoint.path)
        }
        return finalURL
    }

    private func mergedHeaders(for endpoint: Endpoint) -> [String: String] {
        var merged = configuration.defaultHeaders
        endpoint.headers.forEach { merged[$0.key] = $0.value }
        return merged
    }

    private func encodeBody(_ body: [String: Any]) throws -> Data {
        do {
            return try JSONSerialization.data(withJSONObject: body, options: [])
        } catch {
            throw NetworkError.encodingFailed(error)
        }
    }
}
