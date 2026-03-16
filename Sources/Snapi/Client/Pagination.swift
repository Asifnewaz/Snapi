// Pagination.swift
// NetworkingSDK
//
// Type-safe pagination support for REST APIs.
// Supports both page-number (offset) and cursor (keyset) pagination.
// PaginatedLoader is a stateful object that manages next-page fetching.

import Foundation

// MARK: - PaginationStrategy

/// Defines how successive pages are requested.
public enum PaginationStrategy {

    /// Traditional page-number pagination: `?page=1&limit=20`
    case pageNumber(pageKey: String = "page", limitKey: String = "limit", limit: Int = 20)

    /// Cursor-based pagination: `?after=cursor123&limit=20`
    case cursor(afterKey: String = "after", limitKey: String = "limit", limit: Int = 20)
}

// MARK: - Page

/// A single page of results with metadata for requesting the next.
public struct Page<T: Decodable>: Decodable {
    public let items: [T]
    public let nextCursor: String?  // Populated for cursor pagination
    public let totalCount: Int?     // Populated for page-number pagination

    private enum CodingKeys: String, CodingKey {
        case items = "data"
        case nextCursor = "next_cursor"
        case totalCount = "total"
    }
}

// MARK: - PaginationState

private struct PaginationState {
    var currentPage: Int = 1
    var nextCursor: String? = nil
    var hasMore: Bool = true
    var isLoading: Bool = false
}

// MARK: - PaginatedLoader

/// Stateful page loader. Manages page tracking and prevents duplicate fetches.
///
/// Usage:
/// ```swift
/// let loader = PaginatedLoader<Post>(
///     client: client,
///     path: "/posts",
///     strategy: .pageNumber(limit: 20)
/// )
///
/// loader.loadNext { result in
///     switch result {
///     case .success(let page):
///         self.posts.append(contentsOf: page.items)
///         if page.nextCursor == nil { self.reachedEnd = true }
///     case .failure(let error):
///         print(error)
///     }
/// }
/// ```
public final class PaginatedLoader<T: Decodable> {

    // MARK: - Properties

    private let client: APIClient
    private let path: String
    private let strategy: PaginationStrategy
    private let baseQueryParameters: [String: String]
    private let headers: [String: String]?

    private var state = PaginationState()
    private let lock = NSLock()

    // MARK: - Public State

    public var hasMorePages: Bool {
        lock.lock(); defer { lock.unlock() }
        return state.hasMore
    }

    public var isLoading: Bool {
        lock.lock(); defer { lock.unlock() }
        return state.isLoading
    }

    // MARK: - Init

    public init(
        client: APIClient,
        path: String,
        strategy: PaginationStrategy = .pageNumber(),
        baseQueryParameters: [String: String] = [:],
        headers: [String: String]? = nil
    ) {
        self.client = client
        self.path = path
        self.strategy = strategy
        self.baseQueryParameters = baseQueryParameters
        self.headers = headers
    }

    // MARK: - Public Interface

    /// Fetches the next page of results.
    /// Does nothing and returns `.failure(.requestFailed)` if `hasMorePages` is false.
    /// Prevents re-entrant calls while a fetch is in flight.
    public func loadNext(completion: @escaping (Result<Page<T>, NetworkError>) -> Void) {
        lock.lock()
        guard state.hasMore, !state.isLoading else {
            let reason = state.hasMore ? "Fetch already in progress" : "No more pages"
            lock.unlock()
            DispatchQueue.main.async { completion(.failure(.requestFailed(reason))) }
            return
        }
        state.isLoading = true
        let params = buildQueryParameters()
        lock.unlock()

        client.get(
            path: path,
            queryParameters: params,
            headers: headers
        ) { [weak self] (result: Result<Page<T>, NetworkError>) in
            guard let self = self else { return }
            self.lock.lock()
            self.state.isLoading = false
            if case .success(let page) = result {
                self.advanceState(with: page)
            }
            self.lock.unlock()
            completion(result)
        }
    }

    /// Resets loader back to page 1. Call when applying new filters.
    public func reset() {
        lock.lock(); defer { lock.unlock() }
        state = PaginationState()
    }

    // MARK: - Private

    private func buildQueryParameters() -> [String: String] {
        var params = baseQueryParameters
        switch strategy {
        case .pageNumber(let pageKey, let limitKey, let limit):
            params[pageKey] = "\(state.currentPage)"
            params[limitKey] = "\(limit)"

        case .cursor(let afterKey, let limitKey, let limit):
            if let cursor = state.nextCursor {
                params[afterKey] = cursor
            }
            params[limitKey] = "\(limit)"
        }
        return params
    }

    private func advanceState<U: Decodable>(with page: Page<U>) {
        switch strategy {
        case .pageNumber(_, _, let limit):
            state.currentPage += 1
            state.hasMore = (page.items.count == limit)

        case .cursor:
            state.nextCursor = page.nextCursor
            state.hasMore = page.nextCursor != nil
        }
    }
}

// MARK: - Async PaginatedLoader

public extension PaginatedLoader {

    /// Async wrapper for `loadNext`.
    func loadNext() async throws -> Page<T> {
        try await withCheckedThrowingContinuation { continuation in
            loadNext { result in
                continuation.resume(with: result.mapError { $0 as Error })
            }
        }
    }

    /// Loads all pages automatically, accumulating results.
    /// Useful for small datasets. For large datasets, prefer page-by-page loading.
    func loadAll() async throws -> [T] {
        var allItems: [T] = []
        while hasMorePages {
            let page = try await loadNext()
            allItems.append(contentsOf: page.items)
        }
        return allItems
    }
}

// MARK: - Result Error Bridge

private extension Result where Failure == NetworkError {
    func mapError(transform: (NetworkError) -> Error) -> Result<Success, Error> {
        switch self {
        case .success(let v): return .success(v)
        case .failure(let e): return .failure(transform(e))
        }
    }
}
