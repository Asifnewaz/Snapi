import Foundation
import Snapi

struct User: Codable {
    let id: Int
    let name: String
    let email: String
}

struct CreateUserRequest: Codable {
    let name: String
    let email: String
}

@main
struct SnapiExampleApp {
    static func main() async {
        print("🚀 Snapi Example App")
        
        let config = NetworkConfiguration(
            baseURL: "https://jsonplaceholder.typicode.com",
            timeout: 30
        )
        
        let client = APIClient(configuration: config)
        
        await runExamples(client: client)
    }
    
    static func runExamples(client: APIClient) async {
        print("\n📡 Running Snapi Examples...")
        
        await getExample(client: client)
        await postExample(client: client)
        await uploadExample(client: client)
        await downloadImageExample(client: client)
    }
}

extension SnapiExampleApp {
    
    static func getExample(client: APIClient) async {
        print("\n🔍 GET Request Example")
        
        await withCheckedContinuation { continuation in
            client.get<[User]>(
                path: "/users",
                queryParameters: nil,
                headers: nil
            ) { result in
                switch result {
                case .success(let users):
                    print("✅ Successfully fetched \(users.count) users")
                    if let firstUser = users.first {
                        print("   First user: \(firstUser.name) (\(firstUser.email))")
                    }
                case .failure(let error):
                    print("❌ GET request failed: \(error)")
                }
                continuation.resume()
            }
        }
    }
    
    static func postExample(client: APIClient) async {
        print("\n📤 POST Request Example")
        
        let requestBody: [String: Any] = [
            "name": "John Doe",
            "email": "john@example.com"
        ]
        
        await withCheckedContinuation { continuation in
            client.post<User>(
                path: "/users",
                body: requestBody,
                headers: ["Content-Type": "application/json"]
            ) { result in
                switch result {
                case .success(let user):
                    print("✅ Successfully created user: \(user.name)")
                case .failure(let error):
                    print("❌ POST request failed: \(error)")
                }
                continuation.resume()
            }
        }
    }
    
    static func uploadExample(client: APIClient) async {
        print("\n📁 Upload Example")
        
        guard let sampleData = "Hello, World!".data(using: .utf8) else {
            print("❌ Failed to create sample data")
            return
        }
        
        let uploadItem = UploadItem(
            data: sampleData,
            fileName: "sample.txt",
            mimeType: "text/plain"
        )
        
        await withCheckedContinuation { continuation in
            client.uploadSerial<User>(
                path: "/upload",
                items: [uploadItem],
                additionalFields: ["description": "Sample upload"],
                headers: nil,
                fileFieldName: "file",
                onProgress: { progress in
                    switch progress {
                    case .uploading(let current, let total):
                        let percent = Int((Double(current) / Double(total)) * 100)
                        print("   📊 Upload progress: \(percent)%")
                    case .completed:
                        print("   ✅ Upload completed")
                    case .failed(let error):
                        print("   ❌ Upload failed: \(error)")
                    }
                }
            ) { result in
                switch result {
                case .success(let results):
                    print("✅ Upload batch completed with \(results.count) results")
                case .failure(let error):
                    print("❌ Upload failed: \(error)")
                }
                continuation.resume()
            }
        }
    }
    
    static func downloadImageExample(client: APIClient) async {
        print("\n🖼️ Image Download Example")
        
        await withCheckedContinuation { continuation in
            client.downloadImage(
                from: "https://via.placeholder.com/150",
                headers: nil
            ) { result in
                switch result {
                case .success(let image):
                    print("✅ Successfully downloaded image: \(image.size)")
                case .failure(let error):
                    print("❌ Image download failed: \(error)")
                }
                continuation.resume()
            }
        }
    }
}