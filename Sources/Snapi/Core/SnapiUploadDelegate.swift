// SnapiUploadDelegate.swift
// Snapi
//
// Smooth per-item upload progress using bound stream pairs.
//
// WHY NOT subclass InputStream:
// NSInputStream is an Objective-C abstract class cluster. Subclassing it
// directly causes "-setDelegate: only defined for abstract class" at runtime.
//
// THE FIX — Stream.getBoundStreams():
// Foundation gives us a paired (InputStream, OutputStream).
// We feed data in fixed chunks to the OutputStream on a background thread.
// URLSession reads from the InputStream — progress fires after each chunk.
// No subclassing, no Objective-C class cluster issues.

import Foundation

// MARK: - SnapiUploadDelegate

/// URLSession delegate that collects response data and fires the completion closure.
final class SnapiUploadDelegate: NSObject, URLSessionTaskDelegate, URLSessionDataDelegate {

    var onCompletion: ((Data?, URLResponse?, Error?) -> Void)?
    private var receivedData = Data()

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        receivedData.append(data)
    }

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

/// One-shot upload with smooth chunked progress via bound stream pair.
///
/// When `onProgress` is provided:
///   - Uses `Stream.getBoundStreams()` to create a paired (InputStream, OutputStream)
///   - Writes `bodyData` to the OutputStream in `chunkSize` chunks on a background thread
///   - URLSession reads from the InputStream — progress fires after each chunk
///   - Smooth 0.0 → 0.1 → ... → 1.0 regardless of network speed or file size
///
/// When `onProgress` is nil:
///   - Falls back to standard `uploadTask(with:from:completionHandler:)` — testable + simple
struct ProgressUploadSession {

    /// Chunk size in bytes. Smaller = more progress callbacks.
    /// Default 64 KB gives ~16 callbacks per 1 MB image.
    static var chunkSize: Int = 65_536   // 64 KB

    static func upload(
        request: URLRequest,
        bodyData: Data,
        onProgress: ((Double) -> Void)?,
        onCompletion: @escaping (Data?, URLResponse?, Error?) -> Void
    ) {
        guard let onProgress = onProgress else {
            // No progress needed — simple completion-handler upload
            let session = URLSession.shared
            session.uploadTask(with: request, from: bodyData) { data, response, error in
                onCompletion(data, response, error)
            }.resume()
            return
        }

        streamedUpload(
            request: request,
            bodyData: bodyData,
            chunkSize: chunkSize,
            onProgress: onProgress,
            onCompletion: onCompletion
        )
    }

    // MARK: - Private: Bound stream upload

    private static func streamedUpload(
        request: URLRequest,
        bodyData: Data,
        chunkSize: Int,
        onProgress: @escaping (Double) -> Void,
        onCompletion: @escaping (Data?, URLResponse?, Error?) -> Void
    ) {
        // 1. Create bound stream pair
        //    inputStream  → URLSession reads from this
        //    outputStream → we write chunks to this
        var inputStream:  InputStream?
        var outputStream: OutputStream?

        Stream.getBoundStreams(
            withBufferSize: chunkSize * 2,   // buffer = 2 chunks to avoid blocking
            inputStream:  &inputStream,
            outputStream: &outputStream
        )

        guard let input = inputStream, let output = outputStream else {
            // Fallback — should never happen
            URLSession.shared.uploadTask(with: request, from: bodyData) { d, r, e in
                onCompletion(d, r, e)
            }.resume()
            return
        }

        // 2. Set up URLSession with delegate to collect response
        let delegate = SnapiUploadDelegate()
        delegate.onCompletion = onCompletion

        let session = URLSession(
            configuration: .default,
            delegate: delegate,
            delegateQueue: nil
        )

        // 3. Build request that reads from the input stream
        var streamedRequest          = request
        streamedRequest.httpBody     = nil
        streamedRequest.httpBodyStream = input

        // 4. Start the upload task
        let task = session.uploadTask(withStreamedRequest: streamedRequest)

        // 5. Open the output stream and feed data in chunks on a background thread
        output.open()
        input.open()
        task.resume()

        DispatchQueue.global(qos: .userInitiated).async {
            let total     = bodyData.count
            var offset    = 0

            bodyData.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
                guard let base = ptr.baseAddress else { return }
                let bytePtr = base.assumingMemoryBound(to: UInt8.self)

                while offset < total {
                    // Check stream is still writable
                    guard output.hasSpaceAvailable else {
                        // Brief spin-wait — stream buffer is full, let URLSession drain it
                        Thread.sleep(forTimeInterval: 0.002)
                        continue
                    }

                    let remaining = total - offset
                    let toWrite   = min(chunkSize, remaining)
                    let written   = output.write(bytePtr.advanced(by: offset), maxLength: toWrite)

                    if written > 0 {
                        offset += written
                        let progress = Double(offset) / Double(total)
                        DispatchQueue.main.async {
                            onProgress(min(1.0, progress))
                        }
                    } else if written < 0 {
                        // Stream error — break and let the task fail naturally
                        break
                    }
                }
                output.close()
            }
        }

        session.finishTasksAndInvalidate()
    }
}
