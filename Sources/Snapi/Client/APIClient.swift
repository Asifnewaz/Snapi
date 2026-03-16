// APIClient.swift
// NetworkingSDK

import Foundation
import UIKit

// MARK: - Protocol

public protocol APIClientProtocol {
    func get<T: Decodable>(
        path: String,
        queryParameters: [String: String]?,
        headers: [String: String]?,
        completion: @escaping (Result<T, NetworkError>) -> Void
    )
    func post<T: Decodable>(
        path: String,
        body: [String: Any]?,
        headers: [String: String]?,
        completion: @escaping (Result<T, NetworkError>) -> Void
    )
    func uploadSerial<T: Decodable>(
        path: String,
        items: [UploadItem],
        additionalFields: [String: String]?,
        headers: [String: String]?,
        fileFieldName: String,
        onProgress: ((UploadProgressState) -> Void)?,
        completion: @escaping (UploadBatchResult<T>) -> Void
    )
    func downloadImage(
        from urlString: String,
        headers: [String: String]?,
        completion: @escaping (Result<UIImage, NetworkError>) -> Void
    )
}

// MARK: - APIClient

public final class APIClient: APIClientProtocol {

    // MARK: - Dependencies

    internal let configuration: NetworkConfigurationProtocol
    internal let session: URLSessionProtocol
    internal let requestBuilder: RequestBuilder
    internal let responseDecoder: ResponseDecoder
    internal let imageDownloader: ImageDownloaderProtocol

    /// Injected logger. Set `logger.isEnabled = true` to activate.
    public let logger: NetworkLogger

    private let configQueue = DispatchQueue(label: "com.networkingsdk.apiclient.config")

    // MARK: - Init

    public init(
        configuration: NetworkConfigurationProtocol,
        session: URLSessionProtocol = URLSession.shared,
        responseDecoder: ResponseDecoder? = nil,
        imageDownloader: ImageDownloaderProtocol? = nil,
        logger: NetworkLogger = NetworkLogger()         // disabled by default
    ) {
        self.configuration   = configuration
        self.session         = session
        self.requestBuilder  = RequestBuilder(configuration: configuration)
        self.responseDecoder = responseDecoder ?? ResponseDecoder(decoder: configuration.jsonDecoder)
        self.imageDownloader = imageDownloader ?? ImageDownloader(session: session, configuration: configuration)
        self.logger          = logger
    }

    // MARK: - GET

    public func get<T: Decodable>(
        path: String,
        queryParameters: [String: String]? = nil,
        headers: [String: String]? = nil,
        completion: @escaping (Result<T, NetworkError>) -> Void
    ) {
        let request: URLRequest
        do {
            request = try requestBuilder.buildGET(path: path, queryParameters: queryParameters, headers: headers)
        } catch let error as NetworkError {
            deliver(completion, with: .failure(error)); return
        } catch {
            deliver(completion, with: .failure(.unknown(error))); return
        }
        execute(request: request, completion: completion)
    }

    // MARK: - POST

    public func post<T: Decodable>(
        path: String,
        body: [String: Any]? = nil,
        headers: [String: String]? = nil,
        completion: @escaping (Result<T, NetworkError>) -> Void
    ) {
        let request: URLRequest
        do {
            request = try requestBuilder.buildPOST(path: path, body: body, headers: headers)
        } catch let error as NetworkError {
            deliver(completion, with: .failure(error)); return
        } catch {
            deliver(completion, with: .failure(.unknown(error))); return
        }
        execute(request: request, completion: completion)
    }

    // MARK: - Typed Endpoint

    public func execute<T: Decodable>(
        endpoint: Endpoint,
        completion: @escaping (Result<T, NetworkError>) -> Void
    ) {
        let request: URLRequest
        do {
            request = try requestBuilder.build(from: endpoint)
        } catch let error as NetworkError {
            deliver(completion, with: .failure(error)); return
        } catch {
            deliver(completion, with: .failure(.unknown(error))); return
        }
        execute(request: request, completion: completion)
    }

    // MARK: - Image Download

    public func downloadImage(
        from urlString: String,
        headers: [String: String]? = nil,
        completion: @escaping (Result<UIImage, NetworkError>) -> Void
    ) {
        imageDownloader.downloadImage(from: urlString, headers: headers, completion: completion)
    }

    // MARK: - Serial Upload

    public func uploadSerial<T: Decodable>(
        path: String,
        items: [UploadItem],
        additionalFields: [String: String]? = nil,
        headers: [String: String]? = nil,
        fileFieldName: String = "file",
        onProgress: ((UploadProgressState) -> Void)? = nil,
        completion: @escaping (UploadBatchResult<T>) -> Void
    ) {
        guard !items.isEmpty else {
            deliver(completion, with: UploadBatchResult(results: [])); return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            self.uploadNext(
                index: 0, items: items, path: path,
                additionalFields: additionalFields, headers: headers,
                fileFieldName: fileFieldName, accumulated: [],
                onProgress: onProgress, completion: completion
            )
        }
    }

    // MARK: - Private: Core Execute (logging lives here)

    private func execute<T: Decodable>(
        request: URLRequest,
        completion: @escaping (Result<T, NetworkError>) -> Void
    ) {
        // ── Log the outgoing request ──────────────────────────────────
        logger.logRequest(request)
        let startTime = Date()
        // ─────────────────────────────────────────────────────────────

        let task = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }

            // ── Log the incoming response ─────────────────────────────
            let duration = Date().timeIntervalSince(startTime)
            self.logger.logResponse(
                for: request,
                response: response,
                data: data,
                error: error,
                duration: duration
            )
            // ─────────────────────────────────────────────────────────

            if let error = error {
                self.deliver(completion, with: .failure(self.mapTransportError(error)))
                return
            }
            let result: Result<T, NetworkError> = self.processResponse(data: data, response: response)
            self.deliver(completion, with: result)
        }
        task.resume()
    }

    // MARK: - Private: Response Processing

    internal func processResponse<T: Decodable>(data: Data?, response: URLResponse?) -> Result<T, NetworkError> {
        do {
            try HTTPResponseValidator.validate(response: response, data: data)
        } catch let networkError as NetworkError {
            return .failure(networkError)
        } catch {
            return .failure(.unknown(error))
        }

        if T.self == EmptyResponse.self {
            return .success(EmptyResponse() as! T)
        }

        guard let data = data, !data.isEmpty else {
            return .failure(.noData)
        }

        do {
            let decoded = try responseDecoder.decode(T.self, from: data)
            return .success(decoded)
        } catch let networkError as NetworkError {
            return .failure(networkError)
        } catch {
            return .failure(.decodingFailed(error))
        }
    }

    // MARK: - Private: Serial Upload Recursion

    private func uploadNext<T: Decodable>(
        index: Int, items: [UploadItem], path: String,
        additionalFields: [String: String]?, headers: [String: String]?,
        fileFieldName: String, accumulated: [Result<T, NetworkError>],
        onProgress: ((UploadProgressState) -> Void)?,
        completion: @escaping (UploadBatchResult<T>) -> Void
    ) {
        guard index < items.count else {
            let final = UploadProgressState(
                currentFileIndex: items.count - 1, totalFiles: items.count,
                currentFileProgress: 1.0, currentFileName: ""
            )
            DispatchQueue.main.async { onProgress?(final) }
            deliver(completion, with: UploadBatchResult(results: accumulated))
            return
        }

        let item = items[index]
        let resolved: UploadItemResolver.ResolvedItem
        do {
            resolved = try UploadItemResolver.resolve(item)
        } catch let e as NetworkError {
            uploadNext(index: index + 1, items: items, path: path, additionalFields: additionalFields,
                       headers: headers, fileFieldName: fileFieldName,
                       accumulated: accumulated + [.failure(e)],
                       onProgress: onProgress, completion: completion)
            return
        } catch {
            uploadNext(index: index + 1, items: items, path: path, additionalFields: additionalFields,
                       headers: headers, fileFieldName: fileFieldName,
                       accumulated: accumulated + [.failure(.unknown(error))],
                       onProgress: onProgress, completion: completion)
            return
        }

        DispatchQueue.main.async {
            onProgress?(UploadProgressState(currentFileIndex: index, totalFiles: items.count,
                                            currentFileProgress: 0.0, currentFileName: resolved.fileName))
        }

        var formBuilder = MultipartFormDataBuilder()
        additionalFields?.forEach { formBuilder.addField(name: $0.key, value: $0.value) }
        formBuilder.addFilePart(name: fileFieldName, data: resolved.data,
                                fileName: resolved.fileName, mimeType: resolved.mimeType)
        let bodyData = formBuilder.build()

        let request: URLRequest
        do {
            var uploadHeaders = headers ?? [:]
            uploadHeaders["Content-Type"] = formBuilder.contentTypeHeaderValue
            request = try requestBuilder.buildPOST(path: path, body: nil, headers: uploadHeaders)
        } catch let e as NetworkError {
            uploadNext(index: index + 1, items: items, path: path, additionalFields: additionalFields,
                       headers: headers, fileFieldName: fileFieldName,
                       accumulated: accumulated + [.failure(e)],
                       onProgress: onProgress, completion: completion)
            return
        } catch {
            uploadNext(index: index + 1, items: items, path: path, additionalFields: additionalFields,
                       headers: headers, fileFieldName: fileFieldName,
                       accumulated: accumulated + [.failure(.unknown(error))],
                       onProgress: onProgress, completion: completion)
            return
        }

        logger.logRequest(request)
        let startTime = Date()

        let uploadTask = session.uploadTask(with: request, from: bodyData) { [weak self] data, response, error in
            guard let self = self else { return }

            let duration = Date().timeIntervalSince(startTime)
            self.logger.logResponse(for: request, response: response, data: data, error: error, duration: duration)

            DispatchQueue.main.async {
                onProgress?(UploadProgressState(currentFileIndex: index, totalFiles: items.count,
                                                currentFileProgress: 1.0, currentFileName: resolved.fileName))
            }

            let fileResult: Result<T, NetworkError>
            if let error = error {
                let nsError = error as NSError
                if nsError.code == NSURLErrorTimedOut   { fileResult = .failure(.timeout) }
                else if nsError.code == NSURLErrorCancelled { fileResult = .failure(.cancelled) }
                else { fileResult = .failure(.transportError(error)) }
            } else {
                fileResult = self.processResponse(data: data, response: response)
            }

            self.uploadNext(index: index + 1, items: items, path: path, additionalFields: additionalFields,
                            headers: headers, fileFieldName: fileFieldName,
                            accumulated: accumulated + [fileResult],
                            onProgress: onProgress, completion: completion)
        }
        uploadTask.resume()
    }

    // MARK: - Private: Helpers

    private func mapTransportError(_ error: Error) -> NetworkError {
        let nsError = error as NSError
        switch nsError.code {
        case NSURLErrorTimedOut:  return .timeout
        case NSURLErrorCancelled: return .cancelled
        default:                  return .transportError(error)
        }
    }

    private func deliver<T>(_ completion: @escaping (T) -> Void, with value: T) {
        DispatchQueue.main.async { completion(value) }
    }
}
