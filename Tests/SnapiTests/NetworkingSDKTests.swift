// NetworkingSDKTests.swift
// NetworkingSDK — Tests
//
// Full unit test suite. All tests use mocks — zero real network calls.

import XCTest
@testable import NetworkingSDK
import NetworkingSDKTestSupport

// MARK: - Test Models

private struct UserProfile: Codable, Equatable {
    let id: Int
    let name: String
    let email: String
}

private struct CreateUserRequest: Codable {
    let name: String
    let email: String
}

private struct UploadResponse: Codable, Equatable {
    let fileId: String
    let url: String
}

// MARK: - NetworkConfigurationTests

final class NetworkConfigurationTests: XCTestCase {

    func test_defaultHeaders_canBeUpdated() {
        let config = NetworkConfiguration(
            baseURL: URL(string: "https://api.example.com")!,
            defaultHeaders: ["X-App-Version": "1.0"]
        )
        config.setDefaultHeader("Bearer token123", forKey: "Authorization")
        XCTAssertEqual(config.defaultHeaders["Authorization"], "Bearer token123")
        XCTAssertEqual(config.defaultHeaders["X-App-Version"], "1.0")
    }

    func test_defaultHeaders_canBeRemoved() {
        let config = NetworkConfiguration(
            baseURL: URL(string: "https://api.example.com")!,
            defaultHeaders: ["Authorization": "Bearer old"]
        )
        config.removeDefaultHeader(forKey: "Authorization")
        XCTAssertNil(config.defaultHeaders["Authorization"])
    }

    func test_baseURL_canBeUpdated() {
        let config = NetworkConfiguration(baseURL: URL(string: "https://staging.api.example.com")!)
        let prod = URL(string: "https://api.example.com")!
        config.updateBaseURL(prod)
        XCTAssertEqual(config.baseURL, prod)
    }
}

// MARK: - RequestBuilderTests

final class RequestBuilderTests: XCTestCase {

    private var config: NetworkConfiguration!
    private var builder: RequestBuilder!

    override func setUp() {
        super.setUp()
        config = NetworkConfiguration(
            baseURL: URL(string: "https://api.example.com")!,
            defaultHeaders: ["X-Api-Key": "secret", "Accept": "application/json"]
        )
        builder = RequestBuilder(configuration: config)
    }

    func test_GET_buildsCorrectURL() throws {
        let request = try builder.buildGET(path: "/users")
        XCTAssertEqual(request.url?.absoluteString, "https://api.example.com/users")
        XCTAssertEqual(request.httpMethod, "GET")
    }

    func test_GET_appendsQueryParameters() throws {
        let request = try builder.buildGET(
            path: "/users",
            queryParameters: ["page": "2", "limit": "20"]
        )
        let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
        let items = components?.queryItems ?? []
        XCTAssertTrue(items.contains(URLQueryItem(name: "page", value: "2")))
        XCTAssertTrue(items.contains(URLQueryItem(name: "limit", value: "20")))
    }

    func test_headers_perRequestOverridesGlobal() throws {
        let request = try builder.buildGET(
            path: "/me",
            headers: ["X-Api-Key": "per-request-override"]
        )
        XCTAssertEqual(request.allHTTPHeaderFields?["X-Api-Key"], "per-request-override")
        // Global header should still be present
        XCTAssertEqual(request.allHTTPHeaderFields?["Accept"], "application/json")
    }

    func test_POST_setsContentTypeHeader() throws {
        let request = try builder.buildPOST(path: "/users", body: ["name": "Alice"])
        XCTAssertEqual(request.allHTTPHeaderFields?["Content-Type"], "application/json")
    }

    func test_POST_encodesBody() throws {
        let request = try builder.buildPOST(path: "/login", body: ["email": "a@b.com", "password": "1234"])
        XCTAssertNotNil(request.httpBody)
        let decoded = try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: String]
        XCTAssertEqual(decoded?["email"], "a@b.com")
    }

    func test_POST_nilBody_hasNoBody() throws {
        let request = try builder.buildPOST(path: "/ping", body: nil)
        XCTAssertNil(request.httpBody)
    }

    func test_path_withoutLeadingSlash_isHandled() throws {
        let request = try builder.buildGET(path: "users/me")
        XCTAssertEqual(request.url?.path, "/users/me")
    }
}

// MARK: - ResponseDecoderTests

final class ResponseDecoderTests: XCTestCase {

    func test_decodes_validJSON() throws {
        let decoder = ResponseDecoder()
        let json = """
        {"id": 1, "name": "Alice", "email": "alice@example.com"}
        """.data(using: .utf8)!
        let user = try decoder.decode(UserProfile.self, from: json)
        XCTAssertEqual(user.name, "Alice")
    }

    func test_throws_decodingFailed_onBadJSON() {
        let decoder = ResponseDecoder()
        let badData = Data("not json".utf8)
        XCTAssertThrowsError(try decoder.decode(UserProfile.self, from: badData)) { error in
            guard case NetworkError.decodingFailed = error else {
                XCTFail("Expected NetworkError.decodingFailed, got \(error)")
                return
            }
        }
    }
}

// MARK: - HTTPResponseValidatorTests

final class HTTPResponseValidatorTests: XCTestCase {

    func test_200_doesNotThrow() {
        let response = makeHTTPResponse(statusCode: 200)
        XCTAssertNoThrow(try HTTPResponseValidator.validate(response: response, data: nil))
    }

    func test_201_doesNotThrow() {
        let response = makeHTTPResponse(statusCode: 201)
        XCTAssertNoThrow(try HTTPResponseValidator.validate(response: response, data: nil))
    }

    func test_404_throwsServerError() {
        let response = makeHTTPResponse(statusCode: 404)
        XCTAssertThrowsError(try HTTPResponseValidator.validate(response: response, data: nil)) { error in
            guard case NetworkError.serverError(let code, _) = error else {
                XCTFail("Expected serverError(404)")
                return
            }
            XCTAssertEqual(code, 404)
        }
    }

    func test_500_throwsServerError() {
        let response = makeHTTPResponse(statusCode: 500)
        XCTAssertThrowsError(try HTTPResponseValidator.validate(response: response, data: nil)) { error in
            guard case NetworkError.serverError(let code, _) = error else {
                XCTFail("Expected serverError(500)")
                return
            }
            XCTAssertEqual(code, 500)
        }
    }

    func test_nilResponse_throwsInvalidResponse() {
        XCTAssertThrowsError(try HTTPResponseValidator.validate(response: nil, data: nil)) { error in
            XCTAssertEqual(error as? NetworkError, NetworkError.invalidResponse)
        }
    }

    private func makeHTTPResponse(statusCode: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://api.example.com")!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
    }
}

// MARK: - APIClientTests

final class APIClientTests: XCTestCase {

    private var mockSession: MockURLSession!
    private var config: NetworkConfiguration!
    private var client: APIClient!

    override func setUp() {
        super.setUp()
        mockSession = MockURLSession()
        config = NetworkConfiguration(
            baseURL: URL(string: "https://api.example.com")!,
            defaultHeaders: ["X-Api-Key": "test-key"]
        )
        client = APIClient(configuration: config, session: mockSession)
    }

    // MARK: - GET Tests

    func test_get_success_decodesModel() throws {
        let expectedUser = UserProfile(id: 1, name: "Alice", email: "alice@example.com")
        try mockSession.stubSuccess(expectedUser, url: URL(string: "https://api.example.com/users/1")!)

        let expectation = expectation(description: "GET completes")
        client.get(path: "/users/1", queryParameters: nil, headers: nil) { (result: Result<UserProfile, NetworkError>) in
            switch result {
            case .success(let user):
                XCTAssertEqual(user, expectedUser)
            case .failure(let error):
                XCTFail("Expected success, got \(error)")
            }
            expectation.fulfill()
        }
        waitForExpectations(timeout: 2)
    }

    func test_get_404_returnsServerError() {
        mockSession.stubHTTPError(statusCode: 404)

        let expectation = expectation(description: "GET 404")
        client.get(path: "/users/999", queryParameters: nil, headers: nil) { (result: Result<UserProfile, NetworkError>) in
            if case .failure(let error) = result,
               case .serverError(let code, _) = error {
                XCTAssertEqual(code, 404)
            } else {
                XCTFail("Expected serverError(404)")
            }
            expectation.fulfill()
        }
        waitForExpectations(timeout: 2)
    }

    func test_get_transportError_returnsTransportError() {
        let networkError = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorNotConnectedToInternet,
            userInfo: nil
        )
        mockSession.stubTransportError(networkError)

        let expectation = expectation(description: "Transport error")
        client.get(path: "/users", queryParameters: nil, headers: nil) { (result: Result<UserProfile, NetworkError>) in
            if case .failure(let error) = result,
               case .transportError = error {
                // pass
            } else {
                XCTFail("Expected transportError")
            }
            expectation.fulfill()
        }
        waitForExpectations(timeout: 2)
    }

    func test_get_timeout_returnsTimeoutError() {
        let timeoutError = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorTimedOut,
            userInfo: nil
        )
        mockSession.stubTransportError(timeoutError)

        let expectation = expectation(description: "Timeout")
        client.get(path: "/slow", queryParameters: nil, headers: nil) { (result: Result<UserProfile, NetworkError>) in
            XCTAssertEqual(result, .failure(.timeout))
            expectation.fulfill()
        }
        waitForExpectations(timeout: 2)
    }

    func test_get_includesGlobalHeaders() throws {
        let expectedUser = UserProfile(id: 1, name: "Alice", email: "alice@example.com")
        try mockSession.stubSuccess(expectedUser)

        let expectation = expectation(description: "Headers check")
        client.get(path: "/me", queryParameters: nil, headers: nil) { (_: Result<UserProfile, NetworkError>) in
            let captured = self.mockSession.capturedDataRequests.first
            XCTAssertEqual(captured?.allHTTPHeaderFields?["X-Api-Key"], "test-key")
            expectation.fulfill()
        }
        waitForExpectations(timeout: 2)
    }

    func test_get_perRequestHeaderOverridesGlobal() throws {
        let expectedUser = UserProfile(id: 1, name: "Alice", email: "alice@example.com")
        try mockSession.stubSuccess(expectedUser)

        let expectation = expectation(description: "Header override")
        client.get(
            path: "/me",
            queryParameters: nil,
            headers: ["X-Api-Key": "override-key"]
        ) { (_: Result<UserProfile, NetworkError>) in
            let captured = self.mockSession.capturedDataRequests.first
            XCTAssertEqual(captured?.allHTTPHeaderFields?["X-Api-Key"], "override-key")
            expectation.fulfill()
        }
        waitForExpectations(timeout: 2)
    }

    // MARK: - POST Tests

    func test_post_success_decodesResponse() throws {
        let expectedUser = UserProfile(id: 99, name: "Bob", email: "bob@example.com")
        try mockSession.stubSuccess(expectedUser)

        let expectation = expectation(description: "POST success")
        client.post(
            path: "/users",
            body: ["name": "Bob", "email": "bob@example.com"],
            headers: nil
        ) { (result: Result<UserProfile, NetworkError>) in
            if case .success(let user) = result {
                XCTAssertEqual(user, expectedUser)
            } else {
                XCTFail("Expected success")
            }
            expectation.fulfill()
        }
        waitForExpectations(timeout: 2)
    }

    func test_post_nilBody_succeeds() throws {
        let expectedUser = UserProfile(id: 1, name: "Alice", email: "alice@example.com")
        try mockSession.stubSuccess(expectedUser)

        let expectation = expectation(description: "POST nil body")
        client.post(path: "/ping", body: nil, headers: nil) { (result: Result<UserProfile, NetworkError>) in
            if case .success = result { /* pass */ } else { XCTFail("Expected success") }
            expectation.fulfill()
        }
        waitForExpectations(timeout: 2)
    }

    // MARK: - Captured Request Verification

    func test_get_capturesRequest() throws {
        let user = UserProfile(id: 1, name: "Alice", email: "a@b.com")
        try mockSession.stubSuccess(user)

        let exp = expectation(description: "Capture")
        client.get(path: "/users", queryParameters: ["q": "alice"], headers: nil) { (_: Result<UserProfile, NetworkError>) in
            XCTAssertEqual(self.mockSession.capturedDataRequests.count, 1)
            let url = self.mockSession.capturedDataRequests.first?.url?.absoluteString ?? ""
            XCTAssertTrue(url.contains("q=alice"))
            exp.fulfill()
        }
        waitForExpectations(timeout: 2)
    }
}

// MARK: - MultipartFormDataBuilderTests

final class MultipartFormDataBuilderTests: XCTestCase {

    func test_build_containsBoundary() {
        var builder = MultipartFormDataBuilder(boundary: "test-boundary")
        builder.addField(name: "key", value: "value")
        let data = builder.build()
        let body = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("--test-boundary"))
        XCTAssertTrue(body.contains("--test-boundary--"))
    }

    func test_build_containsFormField() {
        var builder = MultipartFormDataBuilder(boundary: "b1")
        builder.addField(name: "username", value: "alice")
        let data = builder.build()
        let body = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("name=\"username\""))
        XCTAssertTrue(body.contains("alice"))
    }

    func test_build_containsFilePart() {
        var builder = MultipartFormDataBuilder(boundary: "b2")
        let fileData = Data("file content".utf8)
        builder.addFilePart(name: "photo", data: fileData, fileName: "photo.jpg", mimeType: "image/jpeg")
        let data = builder.build()
        let body = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("filename=\"photo.jpg\""))
        XCTAssertTrue(body.contains("Content-Type: image/jpeg"))
    }

    func test_contentTypeHeaderValue_containsBoundary() {
        let builder = MultipartFormDataBuilder(boundary: "my-boundary")
        XCTAssertEqual(builder.contentTypeHeaderValue, "multipart/form-data; boundary=my-boundary")
    }
}

// MARK: - MIMETypeTests

final class MIMETypeTests: XCTestCase {
    func test_jpeg_extension() { XCTAssertEqual(MIMEType.from(fileExtension: "jpg"), "image/jpeg") }
    func test_png_extension()  { XCTAssertEqual(MIMEType.from(fileExtension: "png"), "image/png") }
    func test_pdf_extension()  { XCTAssertEqual(MIMEType.from(fileExtension: "pdf"), "application/pdf") }
    func test_unknown_extension() { XCTAssertEqual(MIMEType.from(fileExtension: "xyz"), "application/octet-stream") }
}

// MARK: - NetworkErrorTests

final class NetworkErrorTests: XCTestCase {

    func test_localizedDescriptions_areNotEmpty() {
        let errors: [NetworkError] = [
            .invalidBaseURL,
            .invalidURL("/bad"),
            .invalidRequest("missing field"),
            .invalidResponse,
            .noData,
            .timeout,
            .cancelled,
            .imageConversionFailed,
            .uploadFailed("chunk failed"),
            .imageDownloadFailed("bad url"),
            .requestFailed("server said no"),
            .serverError(statusCode: 503, data: nil)
        ]
        for error in errors {
            XCTAssertFalse(error.errorDescription?.isEmpty ?? true, "Empty description for \(error)")
        }
    }

    func test_equatable() {
        XCTAssertEqual(NetworkError.invalidBaseURL, NetworkError.invalidBaseURL)
        XCTAssertEqual(NetworkError.timeout, NetworkError.timeout)
        XCTAssertEqual(NetworkError.serverError(statusCode: 404, data: nil),
                       NetworkError.serverError(statusCode: 404, data: nil))
        XCTAssertNotEqual(NetworkError.serverError(statusCode: 404, data: nil),
                          NetworkError.serverError(statusCode: 500, data: nil))
    }
}

// MARK: - UploadProgressStateTests

final class UploadProgressStateTests: XCTestCase {

    func test_overallProgress_firstFileHalfway() {
        // 3 files total, uploading file 0, 50% through it
        let state = UploadProgressState(
            currentFileIndex: 0,
            totalFiles: 3,
            currentFileProgress: 0.5,
            currentFileName: "a.jpg"
        )
        // (0 + 0.5) / 3 ≈ 0.167
        XCTAssertEqual(state.overallProgress, 0.5 / 3.0, accuracy: 0.001)
    }

    func test_overallProgress_secondFileComplete() {
        // 3 files, file index 1, 100%
        let state = UploadProgressState(
            currentFileIndex: 1,
            totalFiles: 3,
            currentFileProgress: 1.0,
            currentFileName: "b.jpg"
        )
        // (1 + 1.0) / 3 ≈ 0.667
        XCTAssertEqual(state.overallProgress, 2.0 / 3.0, accuracy: 0.001)
    }

    func test_overallProgress_neverExceedsOne() {
        let state = UploadProgressState(
            currentFileIndex: 2,
            totalFiles: 3,
            currentFileProgress: 1.0,
            currentFileName: "c.jpg"
        )
        XCTAssertLessThanOrEqual(state.overallProgress, 1.0)
    }
}

// MARK: - UploadBatchResultTests

final class UploadBatchResultTests: XCTestCase {

    func test_allSucceeded_true_whenNoFailures() {
        let results: [Result<UploadResponse, NetworkError>] = [
            .success(UploadResponse(fileId: "1", url: "https://cdn.example.com/1.jpg")),
            .success(UploadResponse(fileId: "2", url: "https://cdn.example.com/2.jpg"))
        ]
        let batch = UploadBatchResult(results: results)
        XCTAssertTrue(batch.allSucceeded)
        XCTAssertEqual(batch.successes.count, 2)
    }

    func test_failures_capturedCorrectly() {
        let results: [Result<UploadResponse, NetworkError>] = [
            .success(UploadResponse(fileId: "1", url: "https://cdn.example.com/1.jpg")),
            .failure(.uploadFailed("quota exceeded")),
            .success(UploadResponse(fileId: "3", url: "https://cdn.example.com/3.jpg"))
        ]
        let batch = UploadBatchResult(results: results)
        XCTAssertFalse(batch.allSucceeded)
        XCTAssertEqual(batch.failures.count, 1)
        XCTAssertEqual(batch.failures.first?.index, 1)
        XCTAssertEqual(batch.successes.count, 2)
    }
}
