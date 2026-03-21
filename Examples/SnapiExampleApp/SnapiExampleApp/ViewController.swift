import UIKit
import Snapi

struct User: Codable {
    let id: Int
    let name: String
    let email: String
}

class ViewController: UIViewController {
    
    @IBOutlet weak var logTextView: UITextView!
    
    private var apiService: APIServiceManager = .shared
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
    }
    
   
    
    private func setupUI() {
        title = "Snapi Example"
        logTextView.layer.cornerRadius = 8
        logTextView.font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    }
    
    private func log(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            let timestamp = DateFormatter.logFormatter.string(from: Date())
            let logMessage = "[\(timestamp)] \(message)\n"
            self?.logTextView.text += logMessage
            
            let bottom = NSMakeRange(self?.logTextView.text.count ?? 0, 0)
            self?.logTextView.scrollRangeToVisible(bottom)
        }
    }
    
    @IBAction func testGetRequest(_ sender: UIButton) {
        log("🔄 Starting GET request...")
        sender.isEnabled = false
        
        apiService.client.get<[User]>(
            path: "/users",
            queryParameters: ["_limit": "5"],
            headers: nil
        ) { [weak self] result in
            DispatchQueue.main.async {
                sender.isEnabled = true
                switch result {
                case .success(let users):
                    self?.log("✅ GET Success: Fetched \(users.count) users")
                    if let firstUser = users.first {
                        self?.log("   First user: \(firstUser.name) (\(firstUser.email))")
                    }
                case .failure(let error):
                    self?.log("❌ GET Failed: \(error.localizedDescription)")
                }
            }
        }
    }
    
    @IBAction func testPostRequest(_ sender: UIButton) {
        log("🔄 Starting POST request...")
        sender.isEnabled = false
        
        let requestBody: [String: Any] = [
            "name": "John Doe",
            "email": "john@example.com"
        ]
        
        apiService.client.post<User>(
            path: "/users",
            body: requestBody,
            headers: ["Content-Type": "application/json"]
        ) { [weak self] result in
            DispatchQueue.main.async {
                sender.isEnabled = true
                switch result {
                case .success(let user):
                    self?.log("✅ POST Success: Created user with ID \(user.id)")
                    self?.log("   User: \(user.name) (\(user.email))")
                case .failure(let error):
                    self?.log("❌ POST Failed: \(error.localizedDescription)")
                }
            }
        }
    }
    
    @IBAction func testFileUpload(_ sender: UIButton) {
        log("🔄 Starting file upload...")
        sender.isEnabled = false
        
        guard let sampleData = "Hello from Snapi! 🚀".data(using: .utf8) else {
            log("❌ Failed to create sample data")
            sender.isEnabled = true
            return
        }
        
        let uploadItem = UploadItem(
            data: sampleData,
            fileName: "sample.txt",
            mimeType: "text/plain"
        )
        
        apiService.client.uploadSerial<User>(
            path: "/posts",
            items: [uploadItem],
            additionalFields: ["description": "Sample upload from iOS app"],
            headers: nil,
            fileFieldName: "file",
            onProgress: { [weak self] progress in
                DispatchQueue.main.async {
                    switch progress {
                    case .uploading(let current, let total):
                        let percent = Int((Double(current) / Double(total)) * 100)
                        self?.log("📊 Upload progress: \(percent)%")
                    case .completed:
                        self?.log("📁 Upload completed")
                    case .failed(let error):
                        self?.log("❌ Upload failed: \(error)")
                    }
                }
            }
        ) { [weak self] result in
            DispatchQueue.main.async {
                sender.isEnabled = true
                switch result {
                case .success(let results):
                    self?.log("✅ Upload Success: Processed \(results.count) items")
                case .failure(let error):
                    self?.log("❌ Upload Failed: \(error.localizedDescription)")
                }
            }
        }
    }
    
    @IBAction func testImageDownload(_ sender: UIButton) {
        log("🔄 Starting image download...")
        sender.isEnabled = false
        
        apiService.client.downloadImage(
            from: "https://via.placeholder.com/300x200/007BFF/FFFFFF?text=Snapi+Test",
            headers: nil
        ) { [weak self] result in
            DispatchQueue.main.async {
                sender.isEnabled = true
                switch result {
                case .success(let image):
                    self?.log("✅ Image Download Success")
                    self?.log("   Image size: \(Int(image.size.width))x\(Int(image.size.height)) px")
                    self?.log("   Scale: \(image.scale)x")
                case .failure(let error):
                    self?.log("❌ Image Download Failed: \(error.localizedDescription)")
                }
            }
        }
    }
}

extension DateFormatter {
    static let logFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
