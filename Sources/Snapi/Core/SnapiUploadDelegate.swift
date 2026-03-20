// SnapiUploadDelegate.swift
// Snapi
//
// Smooth per-item upload progress using a chunked InputStream.
//
// WHY NOT didSendBodyData:
// URLSessionTaskDelegate.didSendBodyData fires at the TCP/network layer —
// for small files on fast connections, iOS sends all bytes in one burst,
// so the callback fires only once (100%). Not useful as a progress indicator.
//
// THE FIX — ChunkedInputStream + uploadTask(withStreamedRequest:):
// We stream the multipart body in fixed-size chunks (default 64 KB).
// Progress is reported after each chunk is read from the stream, giving
// smooth 0.0 → 0.1 → 0.2 → ... → 1.0 regardless of network speed or
// file size.

import Foundation

// MARK: - ChunkedInputStream

/// Wraps a Data buffer and reads it in fixed-size chunks.
/// Reports progress to a closure after each chunk is consumed.
final class ChunkedInputStream: InputStream {

    // MARK: - Config

    /// Bytes read per chunk. Smaller = more progress callbacks, more overhead.
    /// 64 KB is a good balance for most image sizes.
    static let defaultChunkSize = 65_536  // 64 KB

    // MARK: - Private

    private let data:      Data
    private let chunkSize: Int
    private var offset:    Int = 0

    private var _streamStatus: Stream.Status = .notOpen
    private var _streamError:  Error?        = nil

    /// Called on URLSession's internal queue after each chunk.
    /// Reports fraction of bytes read so far (0.0 → 1.0).
    var onProgress: ((Double) -> Void)?

    // MARK: - Init

    init(data: Data, chunkSize: Int = ChunkedInputStream.defaultChunkSize) {
        self.data      = data
        self.chunkSize = chunkSize
        super.init(data: data)   // required — superclass needs a valid init
    }

    // MARK: - InputStream overrides

    override var streamStatus: Stream.Status { _streamStatus }
    override var streamError:  Error?        { _streamError  }

    override func open() {
        _streamStatus = .open
        offset        = 0
    }

    override func close() {
        _streamStatus = .closed
    }

    override var hasBytesAvailable: Bool {
        offset < data.count
    }

    override func read(_ buffer: UnsafeMutablePointer<UInt8>, maxLength len: Int) -> Int {
        guard offset < data.count else { return 0 }

        let remaining  = data.count - offset
        let toRead     = min(min(len, chunkSize), remaining)

        data.copyBytes(to: buffer, from: offset ..< offset + toRead)
        offset += toRead

        // Report progress after each chunk
        let progress = Double(offset) / Double(data.count)
        DispatchQueue.main.async { [weak self] in
            self?.onProgress?(min(1.0, progress))
        }

        return toRead
    }

    override func getBuffer(
        _ buffer: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>,
        length len: UnsafeMutablePointer<Int>
    ) -> Bool {
        return false   // We do not support zero-copy buffer access
    }
}

// MARK: - SnapiUploadDelegate

/// URLSession delegate that collects response data and fires the completion closure.
/// Progress is reported by ChunkedInputStream — not by this delegate.
final class SnapiUploadDelegate: NSObject, URLSessionTaskDelegate, URLSessionDataDelegate {

    var onCompletion: ((Data?, URLResponse?, Error?) -> Void)?

    private var receivedData = Data()

    // Collect response body pieces
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        receivedData.append(data)
    }

    // Task finished
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let response = task.response
        let data     = receivedData.isEmpty ? nil : receivedData
        let captured = onCompletion
        DispatchQueue.global(qos: .userInitiated).async {
            captured?(data, response, error)
        }
    }
}

// MARK: - SnapiStreamDelegate

/// Provides the body stream to URLSession for uploadTask(withStreamedRequest:).
final class SnapiStreamDelegate: NSObject, URLSessionTaskDelegate, URLSessionDataDelegate {

    let stream:      ChunkedInputStream
    var onCompletion: ((Data?, URLResponse?, Error?) -> Void)?

    private var receivedData = Data()

    init(stream: ChunkedInputStream) {
        self.stream = stream
    }

    // URLSession asks for the body stream
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        needNewBodyStream completionHandler: @escaping (InputStream?) -> Void
    ) {
        stream.open()
        completionHandler(stream)
    }

    // Collect response body
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        receivedData.append(data)
    }

    // Task finished
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let response = task.response
        let data     = receivedData.isEmpty ? nil : receivedData
        let captured = onCompletion
        DispatchQueue.global(qos: .userInitiated).async {
            captured?(data, response, error)
        }
    }
}

// MARK: - ProgressUploadSession

/// One-shot upload with smooth chunked progress.
///
/// When `onProgress` is provided, the body is streamed through
/// `ChunkedInputStream` using `uploadTask(withStreamedRequest:)`.
/// Progress is reported after each 64 KB chunk regardless of network speed.
///
/// When `onProgress` is nil, falls back to the standard
/// `uploadTask(with:from:)` completion-handler form.
struct ProgressUploadSession {

    static func upload(
        request: URLRequest,
        bodyData: Data,
        onProgress: ((Double) -> Void)?,
        onCompletion: @escaping (Data?, URLResponse?, Error?) -> Void
    ) {
        guard let onProgress = onProgress else {
            // No progress needed — simple completion-handler upload
            let delegate = SnapiUploadDelegate()
            delegate.onCompletion = onCompletion
            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            session.uploadTask(with: request, from: bodyData) { data, response, error in
                onCompletion(data, response, error)
                session.invalidateAndCancel()
            }.resume()
            return
        }

        // Chunked stream upload for smooth progress
        let stream = ChunkedInputStream(data: bodyData)
        stream.onProgress = onProgress

        let delegate = SnapiStreamDelegate(stream: stream)
        delegate.onCompletion = { data, response, error in
            onCompletion(data, response, error)
        }

        var streamedRequest       = request
        streamedRequest.httpBody  = nil   // body comes from the stream

        let session = URLSession(
            configuration: .default,
            delegate: delegate,
            delegateQueue: nil
        )

        // uploadTask(withStreamedRequest:) asks delegate for the stream
        // via needNewBodyStream — SnapiStreamDelegate provides our ChunkedInputStream
        let task = session.uploadTask(withStreamedRequest: streamedRequest)
        task.resume()
        session.finishTasksAndInvalidate()
    }
}
