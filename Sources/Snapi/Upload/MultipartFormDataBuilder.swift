// MultipartFormDataBuilder.swift
// NetworkingSDK
//
// Constructs RFC 2046 compliant multipart/form-data bodies.
// Used by the upload pipeline. No UIKit dependency here — UIImage
// is already converted to Data before reaching this builder.

import Foundation

// MARK: - MIMEType Lookup

/// Utility for resolving MIME types from file extensions.
public enum MIMEType {

    /// Returns a MIME type string for a given file extension.
    /// Falls back to `application/octet-stream` for unknown types.
    public static func from(fileExtension ext: String) -> String {
        switch ext.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png":         return "image/png"
        case "gif":         return "image/gif"
        case "webp":        return "image/webp"
        case "heic":        return "image/heic"
        case "pdf":         return "application/pdf"
        case "mp4":         return "video/mp4"
        case "mov":         return "video/quicktime"
        case "mp3":         return "audio/mpeg"
        case "json":        return "application/json"
        case "txt":         return "text/plain"
        case "zip":         return "application/zip"
        default:            return "application/octet-stream"
        }
    }

    public static func from(url: URL) -> String {
        return from(fileExtension: url.pathExtension)
    }
}

// MARK: - MultipartFormDataBuilder

/// Assembles a multipart/form-data body from structured parts.
///
/// Usage:
/// ```swift
/// var builder = MultipartFormDataBuilder()
/// builder.addField(name: "userId", value: "42")
/// builder.addFilePart(name: "photo", data: jpegData, fileName: "photo.jpg", mimeType: "image/jpeg")
/// let (data, contentTypeHeader) = builder.build()
/// ```
public struct MultipartFormDataBuilder {

    // MARK: - Types

    private struct Part {
        let headers: String
        let body: Data
    }

    // MARK: - Properties

    private let boundary: String
    private var parts: [Part] = []

    // MARK: - Init

    /// - Parameter boundary: Custom boundary string. Auto-generated if nil.
    public init(boundary: String? = nil) {
        self.boundary = boundary ?? "Boundary-\(UUID().uuidString)"
    }

    /// The `Content-Type` header value to set on the URLRequest.
    public var contentTypeHeaderValue: String {
        "multipart/form-data; boundary=\(boundary)"
    }

    // MARK: - Building Parts

    /// Adds a plain-text form field.
    public mutating func addField(name: String, value: String) {
        let headers = "Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n"
        let body = Data((value + "\r\n").utf8)
        parts.append(Part(headers: headers, body: body))
    }

    /// Adds a binary file part.
    /// - Parameters:
    ///   - name: The form field name (e.g. "file", "photo").
    ///   - data: The raw binary content.
    ///   - fileName: The filename declared in the Content-Disposition header.
    ///   - mimeType: The Content-Type of the file part.
    public mutating func addFilePart(
        name: String,
        data: Data,
        fileName: String,
        mimeType: String
    ) {
        let headers = [
            "Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(fileName)\"",
            "Content-Type: \(mimeType)",
            "",
            ""
        ].joined(separator: "\r\n")

        var partData = Data(headers.utf8)
        partData.append(data)
        partData.append(Data("\r\n".utf8))
        parts.append(Part(headers: "", body: partData))
    }

    // MARK: - Final Assembly

    /// Assembles all parts into the final multipart body `Data`.
    public func build() -> Data {
        var body = Data()

        for part in parts {
            body.append(Data("--\(boundary)\r\n".utf8))
            if !part.headers.isEmpty {
                body.append(Data(part.headers.utf8))
            }
            body.append(part.body)
        }

        body.append(Data("--\(boundary)--\r\n".utf8))
        return body
    }
}

// MARK: - UploadItem → Data Conversion

/// Resolves an `UploadItem` into raw `(Data, fileName, mimeType)`.
/// Throws `NetworkError` if the item source cannot be read.
public enum UploadItemResolver {

    public struct ResolvedItem {
        public let data: Data
        public let id :Int
        public let fileName: String
        public let mimeType: String
    }

    public static func resolve(_ item: UploadItem) throws -> ResolvedItem {
        switch item {
        case .image(let image, let id, let fileName, let quality):
            guard let data = image.jpegData(compressionQuality: quality) else {
                throw NetworkError.uploadFailed("UIImage could not be compressed to JPEG for file: \(fileName)")
            }
            return ResolvedItem(data: data, id: id, fileName: fileName, mimeType: "image/jpeg")

        case .file(let url, let id, let customName):
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw NetworkError.fileReadFailed(url)
            }
            do {
                let data = try Data(contentsOf: url)
                let name = customName ?? url.lastPathComponent
                let mime = MIMEType.from(url: url)
                return ResolvedItem(data: data,id: id, fileName: name, mimeType: mime)
            } catch {
                throw NetworkError.fileReadFailed(url)
            }

        case .data(let rawData, let id, let fileName, let mimeType):
            return ResolvedItem(data: rawData,id: id, fileName: fileName, mimeType: mimeType)
        }
    }
}
