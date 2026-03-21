// SnapiUploadDelegate.swift
// Snapi
//

import Foundation

// MARK: - SnapiStreamWriter

/// Feeds bodyData into an OutputStream in chunks, event-driven via StreamDelegate.
/// Runs on its own dedicated thread + RunLoop — no spin-waiting.
final class SnapiStreamWriter: NSObject, StreamDelegate {

    private let data:      Data
    private let chunkSize: Int
    private var offset:    Int = 0

    private let output:      OutputStream
    private var thread:      Thread?
    private var runLoop:     RunLoop?

    var onProgress:   ((Double) -> Void)?
    var onWriteError: (() -> Void)?

    init(data: Data, output: OutputStream, chunkSize: Int) {
        self.data      = data
        self.output    = output
        self.chunkSize = chunkSize
        super.init()
    }

    // MARK: - Start

    func start() {
        let t = Thread(target: self, selector: #selector(runOnThread), object: nil)
        t.qualityOfService = .userInitiated
        t.start()
        thread = t
    }

    @objc private func runOnThread() {
        let rl = RunLoop.current
        runLoop = rl

        output.delegate = self
        output.schedule(in: rl, forMode: .default)
        output.open()

        // Run until the stream closes itself
        rl.run(until: Date.distantFuture)
    }

    // MARK: - StreamDelegate

    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {

        case .hasSpaceAvailable:
            writeNextChunk()

        case .errorOccurred:
            closeStream()
            DispatchQueue.main.async { self.onWriteError?() }

        case .endEncountered:
            closeStream()

        default:
            break
        }
    }

    // MARK: - Write

    private func writeNextChunk() {
        guard offset < data.count else {
            // All bytes written — close stream
            closeStream()
            return
        }

        let remaining = data.count - offset
        let toWrite   = min(chunkSize, remaining)

        let written = data.withUnsafeBytes { ptr -> Int in
            guard let base = ptr.baseAddress else { return 0 }
            let bytePtr = base.assumingMemoryBound(to: UInt8.self)
            return output.write(bytePtr.advanced(by: offset), maxLength: toWrite)
        }

        if written > 0 {
            offset += written
            let progress = Double(offset) / Double(data.count)
            DispatchQueue.main.async { [weak self] in
                self?.onProgress?(min(1.0, progress))
            }
        } else if written < 0 {
            // Write error
            closeStream()
            DispatchQueue.main.async { self.onWriteError?() }
        }
        // written == 0 means buffer full — wait for next .hasSpaceAvailable event
    }

    // MARK: - Close

    private func closeStream() {
        output.delegate = nil
        output.remove(from: RunLoop.current, forMode: .default)
        output.close()
        // Stop the RunLoop so the thread exits cleanly
        CFRunLoopStop(CFRunLoopGetCurrent())
    }
}

// MARK: - SnapiUploadDelegate

/// Collects URLSession response data and fires completion closure.
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

struct ProgressUploadSession {

    /// Chunk size — 64 KB gives ~16 callbacks per 1 MB image
    static var chunkSize: Int = 65_536

    static func upload(
        request: URLRequest,
        bodyData: Data,
        onProgress: ((Double) -> Void)?,
        onCompletion: @escaping (Data?, URLResponse?, Error?) -> Void
    ) {
        guard let onProgress = onProgress else {
            // No progress — use simple completion-handler upload
            URLSession.shared.uploadTask(with: request, from: bodyData) { data, response, error in
                onCompletion(data, response, error)
            }.resume()
            return
        }

        streamedUpload(
            request: request,
            bodyData: bodyData,
            onProgress: onProgress,
            onCompletion: onCompletion
        )
    }

    private static func streamedUpload(
        request: URLRequest,
        bodyData: Data,
        onProgress: @escaping (Double) -> Void,
        onCompletion: @escaping (Data?, URLResponse?, Error?) -> Void
    ) {
        // 1. Create bound stream pair
        var inputStream:  InputStream?
        var outputStream: OutputStream?

        Stream.getBoundStreams(
            withBufferSize: chunkSize * 4,
            inputStream:  &inputStream,
            outputStream: &outputStream
        )

        guard let input = inputStream, let output = outputStream else {
            URLSession.shared.uploadTask(with: request, from: bodyData) { d, r, e in
                onCompletion(d, r, e)
            }.resume()
            return
        }

        // 2. URLSession delegate
        let delegate = SnapiUploadDelegate()
        delegate.onCompletion = { data, response, error in
            onCompletion(data, response, error)
        }

        let session = URLSession(
            configuration: .default,
            delegate: delegate,
            delegateQueue: nil
        )

        // 3. Build streamed request — body comes from the input stream
        var streamedRequest            = request
        streamedRequest.httpBody       = nil
        streamedRequest.httpBodyStream = input

        // 4. Writer — event-driven via RunLoop, no spin-wait
        let writer = SnapiStreamWriter(
            data: bodyData,
            output: output,
            chunkSize: chunkSize
        )
        writer.onProgress = onProgress

        // 5. Start upload task, then writer
        //    URLSession opens the input stream and starts reading
        //    Writer opens the output stream and writes on .hasSpaceAvailable events
        let task = session.uploadTask(withStreamedRequest: streamedRequest)
        task.resume()
        writer.start()     // starts its own thread + RunLoop

        session.finishTasksAndInvalidate()
    }
}
