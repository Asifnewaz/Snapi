// NetworkLogger.swift
// NetworkingSDK
//
// Standalone request/response logger injected into APIClient.
// Single isEnabled flag — flip it anywhere, takes effect immediately.
// Thread-safe. Zero cost when disabled (guard short-circuits).

import Foundation

// MARK: - Log Level

/// Controls how much detail is printed per request/response cycle.
public enum NetworkLogLevel: Int, Comparable {

    /// No output at all.
    case none    = 0

    /// One line per request/response: method, URL, status code, duration.
    case basic   = 1

    /// + request/response headers.
    case headers = 2

    /// + full request body and pretty-printed response JSON.
    case verbose = 3

    public static func < (lhs: NetworkLogLevel, rhs: NetworkLogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - NetworkLogger

/// Drop-in logger for `APIClient`. Prints structured request/response info
/// to the console. Controlled by `isEnabled` and `level`.
///
/// **Setup:**
/// ```swift
/// let logger = NetworkLogger(isEnabled: true, level: .verbose)
/// let client = APIClient(configuration: config, logger: logger)
/// ```
///
/// **Toggle at runtime (e.g. from Debug menu):**
/// ```swift
/// NetworkLogger.shared.isEnabled.toggle()
/// ```
public final class NetworkLogger {

    // MARK: - Shared

    /// Convenience shared instance. Use this OR inject per-client. Not both.
    public static let shared = NetworkLogger()

    // MARK: - Configuration

    /// Master switch. When `false`, all logging is a no-op.
    public var isEnabled: Bool

    /// Controls the verbosity of each log entry.
    public var level: NetworkLogLevel

    /// Override the output destination. Defaults to `print`.
    /// Inject a custom closure to redirect to OSLog, Crashlytics, etc.
    public var output: (String) -> Void

    // MARK: - Init

    public init(
        isEnabled: Bool = false,      // OFF by default — flip to true in DEBUG
        level: NetworkLogLevel = .verbose,
        output: @escaping (String) -> Void = { print($0) }
    ) {
        self.isEnabled = isEnabled
        self.level     = level
        self.output    = output
    }

    // MARK: - Request Logging

    /// Called by APIClient immediately before dispatching a URLRequest.
    internal func logRequest(_ request: URLRequest) {
        guard isEnabled, level >= .basic else { return }

        let method  = request.httpMethod ?? "?"
        let url     = request.url?.absoluteString ?? "?"
        let time    = timestamp()

        var lines: [String] = []
        lines.append("")
        lines.append("┌─── 📤 REQUEST [\(time)] ──────────────────────────")
        lines.append("│ \(method) \(url)")

        if level >= .headers {
            let headers = request.allHTTPHeaderFields ?? [:]
            if headers.isEmpty {
                lines.append("│ Headers: (none)")
            } else {
                lines.append("│ Headers:")
                headers.sorted { $0.key < $1.key }
                    .forEach { lines.append("│   \($0.key): \($0.value)") }
            }
        }

        if level >= .verbose {
            if let body = request.httpBody, !body.isEmpty {
                lines.append("│ Body:")
                lines.append(prettyJSON(body, prefix: "│   "))
            } else {
                lines.append("│ Body: (empty)")
            }
        }

        lines.append("└────────────────────────────────────────────────")
        output(lines.joined(separator: "\n"))
    }

    // MARK: - Response Logging

    /// Called by APIClient when a response (or error) arrives.
    internal func logResponse(
        for request: URLRequest,
        response: URLResponse?,
        data: Data?,
        error: Error?,
        duration: TimeInterval
    ) {
        guard isEnabled, level >= .basic else { return }

        let method    = request.httpMethod ?? "?"
        let url       = request.url?.absoluteString ?? "?"
        let durationMs = String(format: "%.0fms", duration * 1000)

        var lines: [String] = []
        lines.append("")

        if let http = response as? HTTPURLResponse {
            let icon   = successIcon(for: http.statusCode)
            let status = http.statusCode

            lines.append("┌─── \(icon) RESPONSE [\(durationMs)] ──────────────────────────")
            lines.append("│ \(method) \(url)")
            lines.append("│ Status: \(status) \(HTTPURLResponse.localizedString(forStatusCode: status).capitalized)")

            if level >= .headers {
                let headers = http.allHeaderFields
                if headers.isEmpty {
                    lines.append("│ Headers: (none)")
                } else {
                    lines.append("│ Headers:")
                    headers.sorted { "\($0.key)" < "\($1.key)" }
                        .forEach { lines.append("│   \($0.key): \($0.value)") }
                }
            }

            if level >= .verbose {
                if let data = data, !data.isEmpty {
                    lines.append("│ Body (\(data.count) bytes):")
                    lines.append(prettyJSON(data, prefix: "│   "))
                } else {
                    lines.append("│ Body: (empty)")
                }
            }

        } else if let error = error {
            lines.append("┌─── ❌ ERROR [\(durationMs)] ──────────────────────────")
            lines.append("│ \(method) \(url)")
            lines.append("│ Error: \(error.localizedDescription)")

            let nsErr = error as NSError
            lines.append("│ Domain: \(nsErr.domain)  Code: \(nsErr.code)")

        } else {
            lines.append("┌─── ⚠️ RESPONSE [\(durationMs)] ──────────────────────────")
            lines.append("│ \(method) \(url)")
            lines.append("│ No HTTPURLResponse received")
        }

        lines.append("└────────────────────────────────────────────────")
        output(lines.joined(separator: "\n"))
    }

    // MARK: - Private Helpers

    private func successIcon(for statusCode: Int) -> String {
        switch statusCode {
        case 200...299: return "✅"
        case 300...399: return "↩️"
        case 400...499: return "⚠️"
        case 500...599: return "🔥"
        default:        return "❓"
        }
    }

    private func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: Date())
    }

    /// Attempts to pretty-print JSON; falls back to raw UTF-8 string.
    private func prettyJSON(_ data: Data, prefix: String) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(withJSONObject: obj, options: .prettyPrinted),
           let str = String(data: pretty, encoding: .utf8) {
            return str
                .components(separatedBy: "\n")
                .map { prefix + $0 }
                .joined(separator: "\n")
        }
        // Not JSON — show raw string (truncated at 1000 chars)
        let raw = String(data: data, encoding: .utf8) ?? "<binary data>"
        let truncated = raw.count > 1000 ? String(raw.prefix(1000)) + "\n\(prefix)… [\(raw.count) chars total]" : raw
        return prefix + truncated
    }
}
