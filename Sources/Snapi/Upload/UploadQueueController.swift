// UploadQueueController.swift
// NetworkingSDK
//
// Stateful handle for a running serial upload.
// Lets you cancel() or pause() mid-batch.
//
//   cancel() → stops after current file. Partial results only. No resume.
//   pause()  → stops after current file. Remaining items saved. Call resume() later.
//   resume() → picks up exactly where pause() left off.

import Foundation
import UIKit

// MARK: - Upload Queue State

public enum UploadQueueState: Equatable {
    case idle
    case uploading
    case paused
    case cancelled
    case completed

    public static func == (lhs: UploadQueueState, rhs: UploadQueueState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.uploading, .uploading),
             (.paused, .paused), (.cancelled, .cancelled),
             (.completed, .completed): return true
        default: return false
        }
    }
}

// MARK: - Upload Queue Completion

/// Delivered when the queue stops for any reason.
public struct UploadQueueCompletion<T: Decodable> {

    /// Results for files that were actually attempted.
    public let attempted: UploadBatchResult<T>

    /// Items that were queued but never started.
    /// On `.paused` — pass to `controller.resume()` or a new `uploadQueue()`.
    /// On `.cancelled` — discard or show user.
    public let remainingItems: [UploadItem]

    /// Why the queue stopped.
    public let reason: StopReason

    public enum StopReason: Equatable {
        case finished    // all files attempted
        case cancelled   // cancel() was called
        case paused      // pause() was called — resume is possible
    }

    public var fullySucceeded: Bool {
        reason == .finished && attempted.allSucceeded
    }
}

// MARK: - UploadConfig (internal, carries all params needed for resume)

struct UploadConfig {
    let path: String
    let additionalFields: [String: String]?
    let headers: [String: String]?
    let fileFieldName: String
}

// MARK: - UploadQueueController

public final class UploadQueueController<T: Decodable> {

    // MARK: - Public

    public private(set) var state: UploadQueueState = .idle

    /// How many files have completed (success or failure) so far.
    public private(set) var completedCount: Int = 0

    /// Total files in the original batch.
    public let totalCount: Int

    // MARK: - Private

    private let lock = NSLock()
    private var _stopFlag: StopFlag = .none

    private enum StopFlag { case none, cancel, pause }

    // Stored for resume
    private weak var client: APIClient?
    internal let config: UploadConfig
    private var remainingForResume: [UploadItem] = []

    internal let onProgress:   ((UploadProgressState) -> Void)?
    internal let onCompletion: (UploadQueueCompletion<T>) -> Void

    // MARK: - Init

    internal init(
        client: APIClient,
        totalCount: Int,
        config: UploadConfig,
        onProgress: ((UploadProgressState) -> Void)?,
        onCompletion: @escaping (UploadQueueCompletion<T>) -> Void
    ) {
        self.client       = client
        self.totalCount   = totalCount
        self.config       = config
        self.onProgress   = onProgress
        self.onCompletion = onCompletion
    }

    // MARK: - Public Controls

    /// Stops after the current file finishes. Cannot be resumed.
    public func cancel() {
        lock.lock(); defer { lock.unlock() }
        guard state == .uploading else { return }
        _stopFlag = .cancel
        state = .cancelled
    }

    /// Stops after the current file finishes. Call `resume()` to continue.
    public func pause() {
        lock.lock(); defer { lock.unlock() }
        guard state == .uploading else { return }
        _stopFlag = .pause
    }

    /// Continues a paused queue from where it stopped.
    public func resume() {
        lock.lock()
        guard state == .paused else { lock.unlock(); return }
        let remaining = remainingForResume
        _stopFlag = .none
        state = .uploading
        lock.unlock()

        client?.runQueue(controller: self, remaining: remaining, accumulated: [])
    }

    // MARK: - Internal

    internal var shouldStop: Bool {
        lock.lock(); defer { lock.unlock() }
        return _stopFlag != .none
    }

    internal var stopReason: UploadQueueCompletion<T>.StopReason {
        lock.lock(); defer { lock.unlock() }
        return _stopFlag == .cancel ? .cancelled : .paused
    }

    internal func setUploading() {
        lock.lock(); defer { lock.unlock() }
        state = .uploading
    }

    internal func setCompleted() {
        lock.lock(); defer { lock.unlock() }
        state = .completed
    }

    internal func setPaused(remaining: [UploadItem]) {
        lock.lock(); defer { lock.unlock() }
        state = .paused
        remainingForResume = remaining
    }

    internal func incrementCompleted() {
        lock.lock(); defer { lock.unlock() }
        completedCount += 1
    }

    internal func deliverProgress(_ progress: UploadProgressState) {
        DispatchQueue.main.async { [weak self] in
            self?.onProgress?(progress)
        }
    }

    internal func deliverCompletion(_ result: UploadQueueCompletion<T>) {
        DispatchQueue.main.async { [weak self] in
            self?.onCompletion(result)
        }
    }
}

// MARK: - APIClient + uploadQueue

public extension APIClient {

    /// Starts a serial upload with full cancel/pause/resume control.
    ///
    /// - Returns: `UploadQueueController` — hold a strong reference while uploading.
    @discardableResult
    func uploadQueue<T: Decodable>(
        path: String,
        items: [UploadItem],
        additionalFields: [String: String]? = nil,
        headers: [String: String]? = nil,
        fileFieldName: String = "file",
        onProgress: ((UploadProgressState) -> Void)? = nil,
        onCompletion: @escaping (UploadQueueCompletion<T>) -> Void
    ) -> UploadQueueController<T> {

        let config = UploadConfig(
            path: path,
            additionalFields: additionalFields,
            headers: headers,
            fileFieldName: fileFieldName
        )

        let controller = UploadQueueController<T>(
            client: self,
            totalCount: items.count,
            config: config,
            onProgress: onProgress,
            onCompletion: onCompletion
        )
        controller.setUploading()
        runQueue(controller: controller, remaining: items, accumulated: [])
        return controller
    }

    // MARK: - Core recursive runner

    internal func runQueue<T: Decodable>(
        controller: UploadQueueController<T>,
        remaining: [UploadItem],
        accumulated: [Result<T, NetworkError>]
    ) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            self._runQueue(controller: controller, remaining: remaining, accumulated: accumulated)
        }
    }

    private func _runQueue<T: Decodable>(
        controller: UploadQueueController<T>,
        remaining: [UploadItem],
        accumulated: [Result<T, NetworkError>]
    ) {
        // ── Check stop flag before touching the next file ──────────────
        if controller.shouldStop {
            let reason = controller.stopReason
            if reason == .paused {
                controller.setPaused(remaining: remaining)
            } else {
                controller.setCompleted()
            }
            controller.deliverCompletion(UploadQueueCompletion(
                attempted: UploadBatchResult(results: accumulated),
                remainingItems: remaining,
                reason: reason
            ))
            return
        }

        // ── All files processed ────────────────────────────────────────
        guard let item = remaining.first else {
            controller.setCompleted()
            controller.deliverCompletion(UploadQueueCompletion(
                attempted: UploadBatchResult(results: accumulated),
                remainingItems: [],
                reason: .finished
            ))
            return
        }

        let rest      = Array(remaining.dropFirst())
        let fileIndex = accumulated.count
        let total     = controller.totalCount
        let cfg       = controller.config

        // ── Resolve UploadItem → raw Data ─────────────────────────────
        let resolved: UploadItemResolver.ResolvedItem
        do {
            resolved = try UploadItemResolver.resolve(item)
        } catch let e as NetworkError {
            controller.incrementCompleted()
            _runQueue(controller: controller, remaining: rest,
                      accumulated: accumulated + [.failure(e)])
            return
        } catch {
            controller.incrementCompleted()
            _runQueue(controller: controller, remaining: rest,
                      accumulated: accumulated + [.failure(.unknown(error))])
            return
        }

        // ── Progress: file starting ────────────────────────────────────
        controller.deliverProgress(UploadProgressState(
            currentFileIndex: fileIndex,
            totalFiles: total,
            currentFileProgress: 0.0,
            currentFileName: resolved.fileName
        ))

        // ── Build multipart body ───────────────────────────────────────
        var form = MultipartFormDataBuilder()
        cfg.additionalFields?.forEach { form.addField(name: $0.key, value: $0.value) }
        form.addFilePart(
            name: cfg.fileFieldName,
            data: resolved.data,
            fileName: resolved.fileName,
            mimeType: resolved.mimeType
        )
        let bodyData = form.build()

        // ── Build URLRequest ───────────────────────────────────────────
        let request: URLRequest
        do {
            var hdrs = cfg.headers ?? [:]
            hdrs["Content-Type"] = form.contentTypeHeaderValue
            request = try requestBuilder.buildPOST(path: cfg.path, body: nil, headers: hdrs)
        } catch let e as NetworkError {
            controller.incrementCompleted()
            _runQueue(controller: controller, remaining: rest,
                      accumulated: accumulated + [.failure(e)])
            return
        } catch {
            controller.incrementCompleted()
            _runQueue(controller: controller, remaining: rest,
                      accumulated: accumulated + [.failure(.unknown(error))])
            return
        }

        logger.logRequest(request)
        let startTime = Date()

        // ── Execute ────────────────────────────────────────────────────
        let task = session.uploadTask(with: request, from: bodyData) { [weak self] data, response, err in
            guard let self = self else { return }

            self.logger.logResponse(for: request, response: response,
                                    data: data, error: err, duration: Date().timeIntervalSince(startTime))

            // Progress: file done
            controller.deliverProgress(UploadProgressState(
                currentFileIndex: fileIndex,
                totalFiles: total,
                currentFileProgress: 1.0,
                currentFileName: resolved.fileName
            ))

            let fileResult: Result<T, NetworkError>
            if let err = err {
                let code = (err as NSError).code
                if code == NSURLErrorTimedOut        { fileResult = .failure(.timeout) }
                else if code == NSURLErrorCancelled  { fileResult = .failure(.cancelled) }
                else                                  { fileResult = .failure(.transportError(err)) }
            } else {
                fileResult = self.processResponse(data: data, response: response)
            }

            controller.incrementCompleted()

            // Recurse — stop flag checked again at the top of next call
            self._runQueue(
                controller: controller,
                remaining: rest,
                accumulated: accumulated + [fileResult]
            )
        }
        task.resume()
    }
}

// MARK: - APIClient + uploadTaskQueue (per-item fields)

public extension APIClient {

    /// Starts a serial upload where each file carries its own metadata fields.
    ///
    /// Use this instead of `uploadQueue` when files in the batch have
    /// different field values, field names, or file field names.
    ///
    /// - Returns: `UploadQueueController` — hold a strong reference while uploading.
    @discardableResult
    func uploadTaskQueue<T: Decodable>(
        path: String,
        tasks: [UploadTask],
        headers: [String: String]? = nil,
        onProgress: ((UploadProgressState) -> Void)? = nil,
        onCompletion: @escaping (UploadTaskQueueCompletion<T>) -> Void
    ) -> UploadQueueController<T> {

        let config = UploadConfig(
            path: path,
            additionalFields: nil,   // not used — each task has its own fields
            headers: headers,
            fileFieldName: "file"    // not used — each task has its own fileFieldName
        )

        let controller = UploadQueueController<T>(
            client: self,
            totalCount: tasks.count,
            config: config,
            onProgress: onProgress,
            onCompletion: { _ in }   // unused — task queue has its own completion type
        )

        controller.setUploading()
        _runTaskQueue(
            controller: controller,
            remaining: tasks,
            accumulated: [],
            onCompletion: onCompletion
        )
        return controller
    }

    // MARK: - Task Queue Runner

    private func _runTaskQueue<T: Decodable>(
        controller: UploadQueueController<T>,
        remaining: [UploadTask],
        accumulated: [Result<T, NetworkError>],
        onCompletion: @escaping (UploadTaskQueueCompletion<T>) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            self.__runTaskQueue(
                controller: controller,
                remaining: remaining,
                accumulated: accumulated,
                onCompletion: onCompletion
            )
        }
    }

    private func __runTaskQueue<T: Decodable>(
        controller: UploadQueueController<T>,
        remaining: [UploadTask],
        accumulated: [Result<T, NetworkError>],
        onCompletion: @escaping (UploadTaskQueueCompletion<T>) -> Void
    ) {
        // ── Check stop flag before each new file ───────────────────────
        if controller.shouldStop {
            let reason: UploadQueueCompletion<T>.StopReason = controller.wasCancelled ? .cancelled : .paused
            if reason == .paused {
                controller.setPaused(remaining: remaining.map { $0.item })
            } else {
                controller.setCompleted()
            }
            let taskReason: UploadTaskQueueCompletion<T>.StopReason = reason == .cancelled ? .cancelled : .paused
            DispatchQueue.main.async {
                onCompletion(UploadTaskQueueCompletion(
                    attempted: UploadBatchResult(results: accumulated),
                    remainingTasks: remaining,
                    reason: taskReason
                ))
            }
            return
        }

        // ── All done ───────────────────────────────────────────────────
        guard let task = remaining.first else {
            controller.setCompleted()
            DispatchQueue.main.async {
                onCompletion(UploadTaskQueueCompletion(
                    attempted: UploadBatchResult(results: accumulated),
                    remainingTasks: [],
                    reason: .finished
                ))
            }
            return
        }

        let rest      = Array(remaining.dropFirst())
        let fileIndex = accumulated.count
        let total     = controller.totalCount
        let cfg       = controller.config

        // ── Resolve UploadItem → raw Data ─────────────────────────────
        let resolved: UploadItemResolver.ResolvedItem
        do {
            resolved = try UploadItemResolver.resolve(task.item)
        } catch let e as NetworkError {
            controller.incrementCompleted()
            __runTaskQueue(controller: controller, remaining: rest,
                           accumulated: accumulated + [.failure(e)],
                           onCompletion: onCompletion)
            return
        } catch {
            controller.incrementCompleted()
            __runTaskQueue(controller: controller, remaining: rest,
                           accumulated: accumulated + [.failure(.unknown(error))],
                           onCompletion: onCompletion)
            return
        }

        // ── Progress: file starting ────────────────────────────────────
        controller.deliverProgress(UploadProgressState(
            currentFileIndex: fileIndex,
            totalFiles: total,
            currentFileProgress: 0.0,
            currentFileName: resolved.fileName
        ))

        // ── Build multipart — body fields go in form, query fields go in URL ──
        var form = MultipartFormDataBuilder()
        // Only add fields destined for the multipart body
        task.bodyFields?.forEach { form.addField(name: $0.key, value: $0.value) }
        form.addFilePart(
            name: task.fileFieldName,
            data: resolved.data,
            fileName: resolved.fileName,
            mimeType: resolved.mimeType
        )
        let bodyData = form.build()

        // ── Build URLRequest via buildMultipartPOST ───────────────────
        // queryFields go through URLComponents.queryItems — NEVER through
        // appendingPathComponent — so ? is NEVER encoded to %3F.
        let request: URLRequest
        do {
            request = try requestBuilder.buildMultipartPOST(
                path: cfg.path,
                queryParameters: task.queryFields,
                multipartContentType: form.contentTypeHeaderValue,
                headers: cfg.headers
            )
        } catch let e as NetworkError {
            controller.incrementCompleted()
            __runTaskQueue(controller: controller, remaining: rest,
                           accumulated: accumulated + [.failure(e)],
                           onCompletion: onCompletion)
            return
        } catch {
            controller.incrementCompleted()
            __runTaskQueue(controller: controller, remaining: rest,
                           accumulated: accumulated + [.failure(.unknown(error))],
                           onCompletion: onCompletion)
            return
        }

        logger.logRequest(request)
        let startTime = Date()

        // ── Execute ────────────────────────────────────────────────────
        let uploadTask = session.uploadTask(with: request, from: bodyData) { [weak self] data, response, err in
            guard let self = self else { return }

            self.logger.logResponse(for: request, response: response,
                                    data: data, error: err,
                                    duration: Date().timeIntervalSince(startTime))

            controller.deliverProgress(UploadProgressState(
                currentFileIndex: fileIndex,
                totalFiles: total,
                currentFileProgress: 1.0,
                currentFileName: resolved.fileName
            ))

            let fileResult: Result<T, NetworkError>
            if let err = err {
                let code = (err as NSError).code
                if code == NSURLErrorTimedOut       { fileResult = .failure(.timeout) }
                else if code == NSURLErrorCancelled { fileResult = .failure(.cancelled) }
                else                                { fileResult = .failure(.transportError(err)) }
            } else {
                fileResult = self.processResponse(data: data, response: response)
            }

            controller.incrementCompleted()

            self.__runTaskQueue(
                controller: controller,
                remaining: rest,
                accumulated: accumulated + [fileResult],
                onCompletion: onCompletion
            )
        }
        uploadTask.resume()
    }
}

// MARK: - UploadTaskQueueCompletion

/// Completion type for `uploadTaskQueue` — carries remaining `UploadTask`
/// objects (not just `UploadItem`) so all per-task metadata is preserved on pause.
public struct UploadTaskQueueCompletion<T: Decodable> {

    public let attempted: UploadBatchResult<T>

    /// Tasks that were never started, with their original fields intact.
    /// On `.paused` — pass directly back to `uploadTaskQueue` to resume.
    public let remainingTasks: [UploadTask]

    public let reason: StopReason

    public enum StopReason: Equatable {
        case finished
        case cancelled
        case paused
    }

    public var fullySucceeded: Bool {
        reason == .finished && attempted.allSucceeded
    }
}

// Internal helper for wasCancelled (used above)
extension UploadQueueController {
    internal var wasCancelled: Bool {
        return state == .cancelled
    }
}
