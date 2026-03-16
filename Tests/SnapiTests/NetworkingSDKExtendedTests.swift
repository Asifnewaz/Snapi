// NetworkingSDKExtendedTests.swift
// NetworkingSDK — Tests
//
// Unit tests for: RetryPolicy, CancellationToken, ResponseCache,
// PaginatedLoader, Combine publishers, and RequestInterceptors.

import XCTest
import Combine
@testable import NetworkingSDK
import NetworkingSDKTestSupport

// MARK: - Test Models

private struct Post: Codable, Equatable {
    let id: Int
    let title: String
}

private struct PostPage: Codable, Decodable {
    let data: [Post]
    let next_cursor: String?
    let total: Int?
}

// MARK: - RetryPolicyTests

final class RetryPolicyTests: XCTestCase {

    func test_delay_increasesExponentially() {
        let policy = RetryPolicy(
            maxRetries: 3,
            baseDelay: 1.0,
            backoffMultiplier: 2.0,
            maxDelay: 100.0,
            addJitter: false
        )
        XCTAssertEqual(policy.delay(forAttempt: 0), 1.0,  accuracy: 0.001)  // 1s
        XCTAssertEqual(policy.delay(forAttempt: 1), 2.0,  accuracy: 0.001)  // 2s
        XCTAssertEqual(policy.delay(forAttempt: 2), 4.0,  accuracy: 0.001)  // 4s
    }

    func test_delay_cappedAtMaxDelay() {
        let policy = RetryPolicy(
            maxRetries: 10,
            baseDelay: 1.0,
            backoffMultiplier: 10.0,
            maxDelay: 5.0,
            addJitter: false
        )
        XCTAssertEqual(policy.delay(forAttempt: 5), 5.0, accuracy: 0.001)
    }

    func test_jitter_addsVariance() {
        let policy = RetryPolicy(baseDelay: 1.0, backoffMultiplier: 1.0, addJitter: true)
        let delays = (0..<20).map { _ in policy.delay(forAttempt: 0) }
        // With jitter, delays should not all be identical
        let allSame = delays.dropFirst().allSatisfy { $0 == delays[0] }
        XCTAssertFalse(allSame, "Jitter should produce varying delays")
    }

    func test_defaultRetryable_timeout_isRetryable() {
        XCTAssertTrue(RetryPolicy.defaultRetryableErrors(.timeout))
    }

    func test_defaultRetryable_decodingFailed_isNotRetryable() {
        let err = NSError(domain: "test", code: -1)
        XCTAssertFalse(RetryPolicy.defaultRetryableErrors(.decodingFailed(err)))
    }

    func test_defaultRetryable_503_isRetryable() {
        XCTAssertTrue(RetryPolicy.defaultRetryableErrors(.serverError(statusCode: 503, data: nil)))
    }

    func test_defaultRetryable_404_isNotRetryable() {
        XCTAssertFalse(RetryPolicy.defaultRetryableErrors(.serverError(statusCode: 404, data: nil)))
    }

    func test_retryExecutor_succeedsOnSecondAttempt() async throws {
        var callCount = 0
        let policy = RetryPolicy(
            maxRetries: 2,
            baseDelay: 0.01,
            addJitter: false,
            retryableErrors: { _ in true }
        )
        let executor = RetryExecutor(policy: policy)

        let result: String = try await executor.execute {
            callCount += 1
            if callCount < 2 { throw NetworkError.timeout }
            return "success"
        }

        XCTAssertEqual(result, "success")
        XCTAssertEqual(callCount, 2)
    }

    func test_retryExecutor_exhaustsAllRetries_thenThrows() async {
        var callCount = 0
        let policy = RetryPolicy(
            maxRetries: 2,
            baseDelay: 0.01,
            addJitter: false,
            retryableErrors: { _ in true }
        )
        let executor = RetryExecutor(policy: policy)

        do {
            let _: String = try await executor.execute {
                callCount += 1
                throw NetworkError.timeout
            }
            XCTFail("Should have thrown")
        } catch {
            XCTAssertEqual(callCount, 3) // original + 2 retries
        }
    }
}

// MARK: - CancellationTokenTests

final class CancellationTokenTests: XCTestCase {

    func test_token_initiallyNotCancelled() {
        let token = CancellationToken()
        XCTAssertFalse(token.isCancelled)
    }

    func test_cancel_setsCancelledFlag() {
        let token = CancellationToken()
        token.cancel()
        XCTAssertTrue(token.isCancelled)
    }

    func test_cancel_idempotent() {
        let token = CancellationToken()
        token.cancel()
        token.cancel() // Should not crash
        XCTAssertTrue(token.isCancelled)
    }
}

// MARK: - NetworkTaskManagerTests

final class NetworkTaskManagerTests: XCTestCase {

    func test_register_andIsActive() {
        let manager = NetworkTaskManager.shared
        let token = CancellationToken()
        manager.register(token: token, forKey: "test_key_1")
        XCTAssertTrue(manager.isActive(key: "test_key_1"))
        manager.remove(key: "test_key_1")
    }

    func test_remove_clearsKey() {
        let manager = NetworkTaskManager.shared
        let token = CancellationToken()
        manager.register(token: token, forKey: "test_key_2")
        manager.remove(key: "test_key_2")
        XCTAssertFalse(manager.isActive(key: "test_key_2"))
    }

    func test_cancel_cancelTokenAndRemovesKey() {
        let manager = NetworkTaskManager.shared
        let token = CancellationToken()
        manager.register(token: token, forKey: "test_key_3")
        manager.cancel(key: "test_key_3")
        XCTAssertTrue(token.isCancelled)
        XCTAssertFalse(manager.isActive(key: "test_key_3"))
    }

    func test_cancelAll_cancelsAllTokens() {
        let manager = NetworkTaskManager.shared
        let t1 = CancellationToken()
        let t2 = CancellationToken()
        manager.register(token: t1, forKey: "all_test_1")
        manager.register(token: t2, forKey: "all_test_2")
        manager.cancelAll()
        XCTAssertTrue(t1.isCancelled)
        XCTAssertTrue(t2.isCancelled)
    }
}

// MARK: - ResponseCacheTests

final class ResponseCacheTests: XCTestCase {

    private var cache: ResponseCache!

    override func setUp() {
        super.setUp()
        cache = ResponseCache(diskCacheFolderName: "TestCache_\(UUID().uuidString)")
        cache.defaultTTL = 60
    }

    override func tearDown() {
        cache.purgeAll()
        super.tearDown()
    }

    func test_store_andRetrieve_returnsData() {
        let key = "test:key:1"
        let data = Data("hello world".utf8)
        cache.store(data: data, forKey: key)
        let retrieved = cache.retrieve(forKey: key)
        XCTAssertEqual(retrieved, data)
    }

    func test_retrieve_expiredEntry_returnsNil() {
        let key = "test:key:expired"
        let data = Data("expires fast".utf8)
        cache.store(data: data, forKey: key, ttl: 0.001) // 1ms TTL

        // Wait for expiry
        Thread.sleep(forTimeInterval: 0.01)
        let retrieved = cache.retrieve(forKey: key)
        XCTAssertNil(retrieved)
    }

    func test_invalidate_removesEntry() {
        let key = "test:key:invalidate"
        cache.store(data: Data("data".utf8), forKey: key)
        cache.invalidate(forKey: key)
        let result = cache.retrieve(forKey: key)
        XCTAssertNil(result)
    }

    func test_purgeAll_clearsEverything() {
        cache.store(data: Data("a".utf8), forKey: "p1")
        cache.store(data: Data("b".utf8), forKey: "p2")
        cache.purgeAll()
        // Disk ops are async, give a short grace period
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertNil(cache.retrieve(forKey: "p1"))
        XCTAssertNil(cache.retrieve(forKey: "p2"))
    }

    func test_cacheKey_isDeterministic() {
        let url = URL(string: "https://api.example.com/users?page=1")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let k1 = ResponseCache.key(for: request)
        let k2 = ResponseCache.key(for: request)
        XCTAssertEqual(k1, k2)
    }
}

// MARK: - RequestInterceptorTests

final class RequestInterceptorTests: XCTestCase {

    func test_loggingInterceptor_doesNotMutateRequest() throws {
        let interceptor = LoggingInterceptor(level: .verbose)
        let url = URL(string: "https://api.example.com/users")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let adapted = try interceptor.adapt(request)
        XCTAssertEqual(adapted.url, request.url)
        XCTAssertEqual(adapted.httpMethod, "GET")
    }

    func test_authInterceptor_injectsToken() throws {
        let interceptor = AuthTokenInterceptor { "test_token_42" }
        let url = URL(string: "https://api.example.com/me")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let adapted = try interceptor.adapt(request)
        XCTAssertEqual(adapted.allHTTPHeaderFields?["Authorization"], "Bearer test_token_42")
    }

    func test_authInterceptor_nilToken_doesNotInject() throws {
        let interceptor = AuthTokenInterceptor { nil }
        let url = URL(string: "https://api.example.com/me")!
        var request = URLRequest(url: url)

        let adapted = try interceptor.adapt(request)
        XCTAssertNil(adapted.allHTTPHeaderFields?["Authorization"])
    }

    func test_pipeline_chainsInterceptors() throws {
        var log: [String] = []
        let i1 = AuthTokenInterceptor { "token" }
        let i2 = LoggingInterceptor(level: .basic, logger: { log.append($0) })
        let pipeline = InterceptorPipeline(interceptors: [i1, i2])

        let url = URL(string: "https://api.example.com/posts")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let adapted = try pipeline.adapt(request)
        XCTAssertEqual(adapted.allHTTPHeaderFields?["Authorization"], "Bearer token")
        XCTAssertFalse(log.isEmpty)
    }
}

// MARK: - PaginatedLoaderTests

final class PaginatedLoaderTests: XCTestCase {

    private var mockSession: MockURLSession!
    private var config: NetworkConfiguration!
    private var client: APIClient!

    override func setUp() {
        super.setUp()
        mockSession = MockURLSession()
        config = NetworkConfiguration(baseURL: URL(string: "https://api.example.com")!)
        client = APIClient(configuration: config, session: mockSession)
    }

    func test_loadNext_fetchesFirstPage() throws {
        struct PostsPage: Codable {
            let data: [Post]
            let next_cursor: String?
            let total: Int?
        }

        let page = PostsPage(
            data: [Post(id: 1, title: "Hello"), Post(id: 2, title: "World")],
            next_cursor: "cursor_abc",
            total: nil
        )
        try mockSession.stubSuccess(page)

        let loader = PaginatedLoader<Post>(
            client: client,
            path: "/posts",
            strategy: .cursor(limit: 2)
        )

        let exp = expectation(description: "First page")
        loader.loadNext { (result: Result<Page<Post>, NetworkError>) in
            switch result {
            case .success(let p):
                XCTAssertEqual(p.items.count, 2)
                XCTAssertEqual(p.nextCursor, "cursor_abc")
                XCTAssertTrue(loader.hasMorePages)
            case .failure(let e):
                XCTFail("Expected success, got \(e)")
            }
            exp.fulfill()
        }
        waitForExpectations(timeout: 2)
    }

    func test_reset_restoresInitialState() throws {
        struct PostsPage: Codable {
            let data: [Post]; let next_cursor: String?; let total: Int?
        }
        try mockSession.stubSuccess(PostsPage(data: [], next_cursor: nil, total: 0))

        let loader = PaginatedLoader<Post>(client: client, path: "/posts")

        let exp = expectation(description: "Load then reset")
        loader.loadNext { (_: Result<Page<Post>, NetworkError>) in
            loader.reset()
            XCTAssertTrue(loader.hasMorePages)
            exp.fulfill()
        }
        waitForExpectations(timeout: 2)
    }
}

// MARK: - Combine Publisher Tests

final class CombinePublisherTests: XCTestCase {

    private var mockSession: MockURLSession!
    private var config: NetworkConfiguration!
    private var client: APIClient!
    private var cancellables = Set<AnyCancellable>()

    override func setUp() {
        super.setUp()
        mockSession = MockURLSession()
        config = NetworkConfiguration(baseURL: URL(string: "https://api.example.com")!)
        client = APIClient(configuration: config, session: mockSession)
    }

    func test_getPublisher_emitsDecodedValue() throws {
        let expected = Post(id: 99, title: "Combine Post")
        try mockSession.stubSuccess(expected)

        let exp = expectation(description: "Publisher emits value")
        client.getPublisher(path: "/posts/99")
            .sink(
                receiveCompletion: { completion in
                    if case .failure(let e) = completion { XCTFail("\(e)") }
                },
                receiveValue: { (post: Post) in
                    XCTAssertEqual(post, expected)
                    exp.fulfill()
                }
            )
            .store(in: &cancellables)
        waitForExpectations(timeout: 2)
    }

    func test_getPublisher_failure_propagatesError() {
        mockSession.stubHTTPError(statusCode: 500)

        let exp = expectation(description: "Publisher emits error")
        client.getPublisher(path: "/broken")
            .sink(
                receiveCompletion: { completion in
                    if case .failure(let error) = completion,
                       case .serverError(let code, _) = error {
                        XCTAssertEqual(code, 500)
                        exp.fulfill()
                    }
                },
                receiveValue: { (_: Post) in XCTFail("Should not emit value") }
            )
            .store(in: &cancellables)
        waitForExpectations(timeout: 2)
    }

    func test_getPublisher_isCold_doesNotFetchBeforeSubscription() throws {
        let expected = Post(id: 1, title: "Cold")
        try mockSession.stubSuccess(expected)

        let publisher: AnyPublisher<Post, NetworkError> = client.getPublisher(path: "/posts/1")

        // Before subscription — no request should have been made
        XCTAssertEqual(mockSession.capturedDataRequests.count, 0)

        let exp = expectation(description: "Subscribed")
        publisher
            .sink(receiveCompletion: { _ in }, receiveValue: { _ in exp.fulfill() })
            .store(in: &cancellables)

        waitForExpectations(timeout: 2)
        // After subscription — exactly one request
        XCTAssertEqual(mockSession.capturedDataRequests.count, 1)
    }
}

// MARK: - Async Extension Tests

final class AsyncExtensionTests: XCTestCase {

    private var mockSession: MockURLSession!
    private var config: NetworkConfiguration!
    private var client: APIClient!

    override func setUp() {
        super.setUp()
        mockSession = MockURLSession()
        config = NetworkConfiguration(baseURL: URL(string: "https://api.example.com")!)
        client = APIClient(configuration: config, session: mockSession)
    }

    func test_asyncGET_success() async throws {
        let expected = Post(id: 1, title: "Async Post")
        try mockSession.stubSuccess(expected)

        let post: Post = try await client.get(path: "/posts/1")
        XCTAssertEqual(post, expected)
    }

    func test_asyncGET_throws_onError() async {
        mockSession.stubHTTPError(statusCode: 401)

        do {
            let _: Post = try await client.get(path: "/protected")
            XCTFail("Should have thrown")
        } catch let error as NetworkError {
            if case .serverError(let code, _) = error {
                XCTAssertEqual(code, 401)
            } else {
                XCTFail("Unexpected error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func test_asyncPOST_success() async throws {
        let expected = Post(id: 2, title: "Created")
        try mockSession.stubSuccess(expected)

        let post: Post = try await client.post(path: "/posts", body: ["title": "Created"])
        XCTAssertEqual(post.title, "Created")
    }
}
