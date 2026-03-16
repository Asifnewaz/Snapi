// UploadModels.swift
// NetworkingSDK
//
// All value types related to file upload: items, progress, and results.
// UIKit-dependent (UIImage) — import only in UIKit targets.

import Foundation
import UIKit

// MARK: - UploadItem

/// Represents a single uploadable item. Supports images, file URLs, and raw data.
public enum UploadItem {

    /// A UIImage compressed to JPEG before upload.
    /// - Parameters:
    ///   - image: The source UIImage.
    ///   - fileName: Desired file name in the multipart form (e.g. "avatar.jpg").
    ///   - compressionQuality: JPEG compression 0.0 (most) to 1.0 (least). Default: 0.8.
    case image(UIImage, fileName: String, compressionQuality: CGFloat)

    /// A local file referenced by URL.
    /// - Parameters:
    ///   - url: The file's local URL. Must be accessible.
    ///   - fileName: Override name; if nil, uses the URL's last path component.
    case file(url: URL, fileName: String?)

    /// Raw `Data` with an explicit MIME type.
    case data(Data, fileName: String, mimeType: String)
}

// MARK: - UploadProgressState

/// Snapshot of upload progress at a point in time.
/// Delivered via a callback on the calling thread (dispatched to main by APIClient).
public struct UploadProgressState {

    /// Index of the file currently uploading (0-based).
    public let currentFileIndex: Int

    /// Total number of files in the batch.
    public let totalFiles: Int

    /// Progress of the file currently uploading: 0.0 → 1.0.
    public let currentFileProgress: Double

    /// Aggregate progress across all files: 0.0 → 1.0.
    /// Calculated as: (completedFiles + currentFileProgress) / totalFiles
    public let overallProgress: Double

    /// Name of the file currently uploading.
    public let currentFileName: String

    public init(
        currentFileIndex: Int,
        totalFiles: Int,
        currentFileProgress: Double,
        currentFileName: String
    ) {
        self.currentFileIndex = currentFileIndex
        self.totalFiles = totalFiles
        self.currentFileProgress = currentFileProgress
        self.currentFileName = currentFileName

        let completed = Double(currentFileIndex)
        self.overallProgress = min(1.0, (completed + currentFileProgress) / Double(max(1, totalFiles)))
    }
}

// MARK: - UploadBatchResult

/// The final outcome of a serial batch upload.
public struct UploadBatchResult<T: Decodable> {

    /// Individual result for each file, in upload order.
    public let results: [Result<T, NetworkError>]

    /// Files that completed successfully.
    public var successes: [T] {
        results.compactMap { if case .success(let v) = $0 { return v } else { return nil } }
    }

    /// Files that failed, with their associated error.
    public var failures: [(index: Int, error: NetworkError)] {
        results.enumerated().compactMap { index, result in
            if case .failure(let e) = result { return (index, e) } else { return nil }
        }
    }

    /// True if every file in the batch succeeded.
    public var allSucceeded: Bool { failures.isEmpty }

    public init(results: [Result<T, NetworkError>]) {
        self.results = results
    }
}

// MARK: - UploadFieldEncoding

/// Controls where the `fields` of an `UploadTask` are sent in the request.
public enum UploadFieldEncoding {

    /// Fields are added as multipart text parts inside the request body.
    /// This is the standard way to send metadata alongside a file upload.
    /// Server reads them from the form data, same as the file.
    ///
    /// Resulting request body:
    /// ```
    /// --boundary
    /// Content-Disposition: form-data; name="category"
    /// invoice
    /// --boundary
    /// Content-Disposition: form-data; name="photo"; filename="file.jpg"
    /// <binary>
    /// --boundary--
    /// ```
    case multipartBody

    /// Fields are appended to the URL as query parameters.
    /// Useful when your server reads metadata from the URL
    /// and the file from the body.
    ///
    /// Resulting URL:
    /// ```
    /// POST /api/upload?category=invoice&userId=42
    /// ```
    case queryString

    /// Split fields between URL and multipart body using key sets.
    /// Keys listed in `queryKeys` go to the URL.
    /// All remaining keys go into the multipart body.
    ///
    /// Example: `queryKeys: ["userId", "version"]`
    /// - `userId`, `version` → URL query params
    /// - everything else     → multipart form fields
    case mixed(queryKeys: Set<String>)
}

// MARK: - UploadTask

/// Pairs one `UploadItem` with its own metadata fields and encoding strategy.
///
/// Use `fieldEncoding` to tell the SDK whether fields go into
/// the multipart body, the URL query string, or both.
///
/// ```swift
/// // Fields in multipart body (default)
/// UploadTask(
///     item: .image(photo, fileName: "avatar.jpg", compressionQuality: 0.9),
///     fields: ["userId": "42", "category": "avatar"],
///     fieldEncoding: .multipartBody,
///     fileFieldName: "photo"
/// )
///
/// // Fields in URL query string
/// UploadTask(
///     item: .image(photo, fileName: "doc.jpg", compressionQuality: 0.9),
///     fields: ["userId": "42", "category": "invoice"],
///     fieldEncoding: .queryString,
///     fileFieldName: "document"
/// )
///
/// // Mixed — userId in URL, caption in body
/// UploadTask(
///     item: .image(photo, fileName: "gallery.jpg", compressionQuality: 0.85),
///     fields: ["userId": "42", "caption": "Sunset photo"],
///     fieldEncoding: .mixed(queryKeys: ["userId"]),
///     fileFieldName: "photo"
/// )
/// ```
public struct UploadTask {

    /// The file to upload.
    public let item: UploadItem

    /// Key-value metadata for this file.
    /// Where they are sent is determined by `fieldEncoding`.
    public let fields: [String: String]?

    /// Controls whether `fields` go into the multipart body,
    /// the URL query string, or split between both.
    /// Default: `.multipartBody`
    public let fieldEncoding: UploadFieldEncoding

    /// The multipart form field name for the file binary part.
    /// Default: `"file"`
    public let fileFieldName: String

    public init(
        item: UploadItem,
        fields: [String: String]? = nil,
        fieldEncoding: UploadFieldEncoding = .multipartBody,
        fileFieldName: String = "file"
    ) {
        self.item          = item
        self.fields        = fields
        self.fieldEncoding = fieldEncoding
        self.fileFieldName = fileFieldName
    }

    // MARK: - Internal derived helpers

    /// Fields that should go into the URL query string.
    internal var queryFields: [String: String]? {
        guard let fields = fields else { return nil }
        switch fieldEncoding {
        case .queryString:
            return fields
        case .multipartBody:
            return nil
        case .mixed(let queryKeys):
            let filtered = fields.filter { queryKeys.contains($0.key) }
            return filtered.isEmpty ? nil : filtered
        }
    }

    /// Fields that should go into the multipart body.
    internal var bodyFields: [String: String]? {
        guard let fields = fields else { return nil }
        switch fieldEncoding {
        case .multipartBody:
            return fields
        case .queryString:
            return nil
        case .mixed(let queryKeys):
            let filtered = fields.filter { !queryKeys.contains($0.key) }
            return filtered.isEmpty ? nil : filtered
        }
    }
}
