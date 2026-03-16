# 🧩 Snapi

> *Snap it together. Ship it faster.*

A lightweight, production-ready iOS networking library built on top of `URLSession` and `Codable`. No third-party dependencies.

---

## Requirements

| | |
|---|---|
| iOS | 15.0+ |
| Swift | 5.9+ |
| Xcode | 15.0+ |
| Dependencies | None |

---

## Installation

### Swift Package Manager

Add the package to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/yourorg/Snapi.git", from: "1.0.0")
]
```

Or in Xcode: **File → Add Package Dependencies** and enter the repository URL.

---

## Setup

Configure once at app launch — `AppDelegate` or your DI container.

```swift
import Snapi

final class APIServiceManager {

    static let shared = APIServiceManager()

    let configuration: NetworkConfiguration
    let client: APIClient

    private init() {
        configuration = NetworkConfiguration(
            baseURL: URL(string: "https://api.example.com")!,
            defaultHeaders: [
                "Accept"        : "application/json",
                "Content-Type"  : "application/json",
                "X-App-Version" : "1.0.0"
            ],
            timeoutInterval: 30
        )
        client = APIClient(configuration: configuration)
    }
}
```

### Enable Logging (Debug only)

```swift
let logger = NetworkLogger(isEnabled: true, level: .verbose)
let client = APIClient(configuration: configuration, logger: logger)
```

| Level | Output |
|---|---|
| `.none` | Nothing |
| `.basic` | Method · URL · Status · Duration |
| `.headers` | + Request and response headers |
| `.verbose` | + Full request body and pretty-printed response JSON |

---

## Authentication

```swift
// After login — injects Authorization header into every request
// and persists token to UserDefaults automatically
APIServiceManager.shared.configuration.setAuthToken(response.token)

// On logout — removes from headers and storage
APIServiceManager.shared.configuration.clearAuthToken()

// Check state
APIServiceManager.shared.configuration.hasAuthToken   // Bool
APIServiceManager.shared.configuration.currentToken   // String?
```

The token is restored automatically on the next app launch — no extra code needed.

### Switch to Keychain (recommended for production)

```swift
NetworkConfiguration(
    baseURL: URL(string: "https://api.example.com")!,
    tokenStore: KeychainTokenStore()    // one line change
)
```

---

## Defining Endpoints

Define endpoints as typed structs conforming to `Endpoint`. Parameters are routed automatically based on HTTP method.

```swift
// GET — parameters go to URL query string automatically
struct GetUsersEndpoint: Endpoint {
    let page: Int
    let limit: Int

    var path: String { "/api/users" }
    var method: HTTPMethod { .GET }
    var parameters: [String: Any]? {
        ["page": page, "limit": limit]
    }
}

// POST — parameters go to JSON body automatically
struct LoginEndpoint: Endpoint {
    let email: String
    let password: String

    var path: String { "/api/login" }
    var method: HTTPMethod { .POST }
    var parameters: [String: Any]? {
        ["email": email, "password": password]
    }
}
```

> **Rule:** `GET`, `HEAD`, `DELETE` → `.queryString` (auto).  
> `POST`, `PUT`, `PATCH` → `.jsonBody` (auto).  
> Override with `var parameterEncoding: ParameterEncoding { .queryString }` when needed.

---

## Response Models

Plain `Codable` structs. No SDK-specific types needed.

```swift
struct User: Decodable {
    let id: Int
    let name: String
    let email: String
    let avatarURL: String?

    enum CodingKeys: String, CodingKey {
        case id, name, email
        case avatarURL = "avatar_url"
    }
}

struct LoginResponse: Decodable {
    let token: String
    let userId: Int
}
```

---

## GET Request

### Callback

```swift
APIServiceManager.shared.client.get(
    path: "/api/users",
    queryParameters: ["page": "1", "limit": "20"]
) { (result: Result<[User], NetworkError>) in
    switch result {
    case .success(let users):
        print("Loaded \(users.count) users")
    case .failure(let error):
        print(error.localizedDescription)
    }
}
```

### Async / Await

```swift
func loadUsers() async {
    do {
        let users: [User] = try await APIServiceManager.shared.client.get(
            path: "/api/users",
            queryParameters: ["page": "1"]
        )
        print("Loaded \(users.count) users")
    } catch let error as NetworkError {
        print(error.localizedDescription)
    }
}
```

### Using a Typed Endpoint

```swift
let endpoint = GetUsersEndpoint(page: 1, limit: 20)

APIServiceManager.shared.client.execute(endpoint: endpoint) { (result: Result<[User], NetworkError>) in
    // handle result
}
```

---

## POST Request

### Callback

```swift
APIServiceManager.shared.client.post(
    path: "/api/users",
    body: ["name": "Alice", "email": "alice@example.com"]
) { (result: Result<User, NetworkError>) in
    switch result {
    case .success(let user):
        print("Created user: \(user.id)")
    case .failure(let error):
        print(error.localizedDescription)
    }
}
```

### Async / Await

```swift
func createUser(name: String, email: String) async throws -> User {
    return try await APIServiceManager.shared.client.post(
        path: "/api/users",
        body: ["name": name, "email": email]
    )
}
```

### Login Example

```swift
func login(email: String, password: String) {
    let endpoint = LoginEndpoint(email: email, password: password)

    APIServiceManager.shared.client.execute(endpoint: endpoint) { (result: Result<LoginResponse, NetworkError>) in
        switch result {
        case .success(let response):
            // Persist token — all future requests carry it automatically
            APIServiceManager.shared.configuration.setAuthToken(response.token)
        case .failure(let error):
            print(error.localizedDescription)
        }
    }
}
```

---

## Image Download

```swift
APIServiceManager.shared.client.downloadImage(
    from: "https://cdn.example.com/avatar/42.jpg"
) { result in
    // Called on main queue
    switch result {
    case .success(let image):
        self.imageView.image = image
    case .failure(let error):
        print(error.localizedDescription)
    }
}
```

### Async / Await

```swift
let image = try await APIServiceManager.shared.client.downloadImage(
    from: "https://cdn.example.com/avatar/42.jpg"
)
self.imageView.image = image
```

---

## File / Image Upload

### Single Image

```swift
let image = UIImage(named: "avatar")!

APIServiceManager.shared.client.uploadSerial(
    path: "/api/upload",
    items: [
        .image(image, fileName: "avatar.jpg", compressionQuality: 0.85)
    ],
    additionalFields: ["userId": "42"],
    fileFieldName: "photo",
    onProgress: { state in
        print("Progress: \(Int(state.overallProgress * 100))%")
    },
    completion: { (batch: UploadBatchResult<UploadResponse>) in
        if batch.allSucceeded {
            print("Uploaded: \(batch.successes.first?.url ?? "")")
        }
    }
)
```

### Multiple Images with Cancel / Pause / Resume

```swift
// Build one UploadTask per file — each has its own metadata
let tasks: [UploadTask] = images.enumerated().map { index, image in
    let params: [String: Any] = ["name": "photo_\(index + 1).jpg", "albumId": "42"]
    let jsonData = try! JSONSerialization.data(withJSONObject: params)   // no .prettyPrinted
    let jsonString = String(data: jsonData, encoding: .utf8)!

    return UploadTask(
        item: .image(image, fileName: "photo_\(index + 1).jpg", compressionQuality: 0.85),
        fields: ["data": jsonString],
        fieldEncoding: .queryString,   // fields go in URL query string
        fileFieldName: "Filedata"      // file binary always goes as multipart
    )
}

// Keep strong reference — stores remaining items for resume
var queueController: UploadQueueController<UploadResponse>?

queueController = APIServiceManager.shared.client.uploadTaskQueue(
    path: "/api/upload",            // clean path — no ? or query string here
    tasks: tasks,
    onProgress: { state in
        print("[\(state.currentFileIndex + 1)/\(state.totalFiles)] \(state.currentFileName)")
        print("File: \(Int(state.currentFileProgress * 100))%  Overall: \(Int(state.overallProgress * 100))%")
    },
    onCompletion: { (completion: UploadTaskQueueCompletion<UploadResponse>) in
        switch completion.reason {
        case .finished:
            print("Done. \(completion.attempted.successes.count) uploaded.")
        case .cancelled:
            print("Cancelled. \(completion.remainingTasks.count) discarded.")
        case .paused:
            print("Paused. \(completion.remainingTasks.count) remaining.")
        }
    }
)

// Cancel — stops after current file, cannot resume
queueController?.cancel()

// Pause — stops after current file, resume available
queueController?.pause()

// Resume — continues from exact pause point
queueController?.resume()
```

### Upload Item Types

```swift
// UIImage — compressed to JPEG automatically
.image(uiImage, fileName: "photo.jpg", compressionQuality: 0.85)

// File on disk — MIME type detected from extension
.file(url: fileURL, fileName: nil)      // nil = keep original filename

// Raw Data — you control the MIME type
.data(rawData, fileName: "file.bin", mimeType: "application/octet-stream")
```

### Field Encoding Options

```swift
// Fields inside multipart body (default)
fieldEncoding: .multipartBody
// POST /api/upload
// Body: name="data" → value  +  name="photo"; filename="..." → binary

// Fields in URL query string
fieldEncoding: .queryString
// POST /api/upload?data={"name":"photo.jpg"}
// Body: name="photo"; filename="..." → binary

// Split — named keys go to URL, rest go to body
fieldEncoding: .mixed(queryKeys: ["userId", "version"])
// POST /api/upload?userId=42&version=2
// Body: name="caption" → value  +  name="photo" → binary
```

---

## Error Handling

All methods return or throw `NetworkError`:

```swift
switch error {
case .invalidURL(let path):
    print("Bad URL: \(path)")
case .serverError(let code, let data):
    print("HTTP \(code)")
case .decodingFailed(let underlying):
    print("Decode error: \(underlying)")
case .timeout:
    print("Request timed out")
case .cancelled:
    print("Request was cancelled")
case .noData:
    print("Server returned empty body")
case .transportError(let underlying):
    print("Network error: \(underlying)")
default:
    print(error.localizedDescription)
}
```

---

## Advanced Features

### Retry with Exponential Backoff

```swift
// Async — 3 retries, 1s → 2s → 4s, jitter added automatically
let users: [User] = try await client.get(
    path: "/api/users",
    retryPolicy: .default           // .none / .default / .aggressive
)

// Custom policy
let policy = RetryPolicy(
    maxRetries: 5,
    baseDelay: 0.5,
    backoffMultiplier: 2.0,
    maxDelay: 30.0,
    addJitter: true
)
```

### Pagination

```swift
let loader = PaginatedLoader<User>(
    client: client,
    path: "/api/users",
    strategy: .pageNumber(limit: 20)    // or .cursor(limit: 20)
)

// Load next page
loader.loadNext { result in
    if case .success(let page) = result {
        self.users.append(contentsOf: page.items)
    }
}

// Async — load all pages at once (small datasets only)
let allUsers = try await loader.loadAll()
```

### Response Caching

```swift
client.getCached(
    path: "/api/config",
    cachePolicy: .returnCacheIfValid,   // return cache if not expired
    ttl: 300                            // 5 minutes
) { (result: Result<Config, NetworkError>, fromCache: Bool) in
    print("From cache: \(fromCache)")
}
```

| Policy | Behaviour |
|---|---|
| `.noCache` | Always hit network, never store |
| `.returnCacheIfValid` | Return cache if fresh, fetch if expired |
| `.returnCacheThenRefresh` | Return cache immediately, then fetch fresh |
| `.refreshAndStore` | Always fetch, store result for next time |

### Combine Publishers

```swift
client.getPublisher(path: "/api/users")
    .retryOnTransientError(2, delay: 1.0)
    .receive(on: DispatchQueue.main)
    .sink(
        receiveCompletion: { _ in },
        receiveValue: { (users: [User]) in
            self.users = users
        }
    )
    .store(in: &cancellables)
```

### Network Reachability

```swift
NetworkReachability.shared.onStatusChange = { status in
    if !status.isConnected {
        showOfflineBanner()
    }
    print(status.connectionType)   // .wifi / .cellular / .wiredEthernet
    print(status.isExpensive)      // true on cellular hotspot
    print(status.isConstrained)    // true in Low Data Mode
}
NetworkReachability.shared.startMonitoring()
```

---

## Testing

Inject `MockURLSession` to test without hitting the network:

```swift
let mock = MockURLSession()
let client = APIClient(configuration: config, session: mock)

// Stub a success response
try mock.stubSuccess(User(id: 1, name: "Alice", email: "alice@example.com"))

// Stub an error
mock.stubHTTPError(statusCode: 404)
mock.stubTransportError(NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut))

// Assert the request that was sent
XCTAssertEqual(mock.capturedDataRequests.first?.url?.path, "/api/users")
XCTAssertEqual(mock.capturedDataRequests.first?.allHTTPHeaderFields?["Authorization"], "Bearer token")
```

---

## Common Mistakes

| Mistake | Fix |
|---|---|
| `path: "rest/locations?"` — `?` in path | Remove `?`. Use `queryParameters` or `fieldEncoding: .queryString` |
| Passing pre-encoded JSON string to fields | Pass raw JSON. SDK encodes once via `URLComponents` |
| `options: .prettyPrinted` for query values | Use `options: []` for compact, clean output |
| `Body: (empty)` in logger during upload | Normal. Upload body goes in `from:` arg of `uploadTask`, not `httpBody` |
| `UploadQueueController` deallocated | Hold strong reference — it stores remaining items for resume |

---

## Architecture Overview

```
NetworkConfiguration   — baseURL, headers, token, timeout, cache policy
        │
   RequestBuilder      — assembles URLRequest from Endpoint or inline params
        │
    APIClient          — public interface: GET, POST, upload, download
        │
 URLSessionProtocol    — seam for injecting MockURLSession in tests
        │
  ResponseDecoder      — JSON → Decodable, status code validation
```

---

## License

MIT License. See `LICENSE` for details.
