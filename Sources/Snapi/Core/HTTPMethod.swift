// HTTPMethod.swift
// NetworkingSDK
//
// Type-safe representation of HTTP methods.
// Extend with PATCH, DELETE, HEAD, OPTIONS as needed.

import Foundation

/// Strongly typed HTTP methods. Extend when new verbs are required.
public enum HTTPMethod: String {
    case GET     = "GET"
    case POST    = "POST"
    case PUT     = "PUT"
    case PATCH   = "PATCH"
    case DELETE  = "DELETE"
    case HEAD    = "HEAD"
    case OPTIONS = "OPTIONS"
}
