//
//  SnapiUploadDelegate.swift
//  Snapi
//
//  Created by Asif Newaz on 19.03.26.
//


// SnapiUploadDelegate.swift
// Snapi
//
// URLSessionTaskDelegate that delivers real byte-level upload progress
// per file. Used internally by __runTaskQueue when onItemProgress is set.
//
// Each upload task gets its own SnapiUploadDelegate instance.
// The delegate is retained by the URLSession until the task completes.

import Foundation

// MARK: - SnapiUploadDelegate

/// Handles progress + completion for a single URLSession upload task.
/// Bridges the delegate-based URLSession API back into a closure-based interface.
final class SnapiUploadDelegate: NSObject, URLSessionTaskDelegate, URLSessionDataDelegate {

    // MARK: - Closures

    /// Called repeatedly as bytes are sent. progress: 0.0 → 1.0.
    var onProgress: ((Double) -> Void)?

    /// Called once when the task finishes (data, response, error).
    var onCompletion: ((Data?, URLResponse?, Error?) -> Void)?

    // MARK: - Private

    private var receivedData = Data()

    // MARK: - URLSessionTaskDelegate — progress

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        let progress = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
        DispatchQueue.main.async { [weak self] in
            self?.onProgress?(min(1.0, progress))
        }
    }

    // MARK: - URLSessionDataDelegate — collect response body

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        receivedData.append(data)
    }

    // MARK: - URLSessionTaskDelegate — completion

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let response  = task.response
        let data      = receivedData.isEmpty ? nil : receivedData
        let captured  = onCompletion
        // Fire on a background queue — caller dispatches to main
        DispatchQueue.global(qos: .userInitiated).async {
            captured?(data, response, error)
        }
    }
}

// MARK: - ProgressUploadSession

/// Creates a one-shot URLSession backed by a SnapiUploadDelegate.
/// Each file upload gets its own session so delegates don't cross-contaminate.
///
/// The session is invalidated automatically after the task completes.
struct ProgressUploadSession {

    /// Executes a single upload with real byte-level progress.
    ///
    /// - Parameters:
    ///   - request: The fully-built URLRequest (Content-Type already set).
    ///   - bodyData: The multipart body data.
    ///   - onProgress: Called on main queue with 0.0 → 1.0 as bytes are sent.
    ///   - onCompletion: Called on background queue when done (data, response, error).
    static func upload(
        request: URLRequest,
        bodyData: Data,
        onProgress: ((Double) -> Void)?,
        onCompletion: @escaping (Data?, URLResponse?, Error?) -> Void
    ) {
        let delegate = SnapiUploadDelegate()
        delegate.onProgress   = onProgress
        delegate.onCompletion = { data, response, error in
            onCompletion(data, response, error)
        }

        // Each upload gets its own ephemeral session tied to the delegate
        let session = URLSession(
            configuration: .default,
            delegate: delegate,
            delegateQueue: nil      // nil = URLSession's own serial queue
        )

        // Use the non-completion-handler form — delegate receives everything
        let task = session.uploadTask(with: request, from: bodyData)
        task.resume()

        // Invalidate after completion so the session doesn't linger
        // finishTasksAndInvalidate waits for the task to complete first
        session.finishTasksAndInvalidate()
    }
}