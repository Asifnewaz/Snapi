# Snapi Example App

A complete iOS example app demonstrating the Snapi networking library features.

## Features

This example app demonstrates all major Snapi functionality:

- **GET Requests** - Fetch user data from JSONPlaceholder API
- **POST Requests** - Create new users with JSON data
- **File Upload** - Upload files with progress tracking
- **Image Download** - Download and display images
- **Real-time Logging** - See all network activity in the app

## Getting Started

1. Open the Xcode project:
   ```
   Examples/SnapiExampleApp/SnapiExampleApp.xcodeproj
   ```

2. Build and run the app (⌘+R)

3. Tap the buttons to test different networking operations

## Project Structure

```
SnapiExampleApp/
├── SnapiExampleApp.xcodeproj/     # Xcode project file
└── SnapiExampleApp/
    ├── AppDelegate.swift          # App lifecycle
    ├── SceneDelegate.swift        # Scene management
    ├── ViewController.swift       # Main view controller with examples
    ├── Main.storyboard           # UI layout
    ├── LaunchScreen.storyboard   # Launch screen
    ├── Assets.xcassets/          # App icons and colors
    └── Info.plist               # App configuration
```

## API Endpoints Used

- **JSONPlaceholder API** (https://jsonplaceholder.typicode.com)
  - `GET /users` - Fetch users list
  - `POST /users` - Create new user
  - `POST /posts` - Mock upload endpoint
- **Placeholder Image Service** (https://via.placeholder.com)
  - Custom branded test image

## Code Examples

### Basic GET Request
```swift
apiClient.get<[User]>(
    path: "/users",
    queryParameters: ["_limit": "5"],
    headers: nil
) { result in
    // Handle response
}
```

### POST with JSON Body
```swift
let requestBody = ["name": "John", "email": "john@example.com"]
apiClient.post<User>(
    path: "/users",
    body: requestBody,
    headers: ["Content-Type": "application/json"]
) { result in
    // Handle response  
}
```

### File Upload with Progress
```swift
let uploadItem = UploadItem(
    data: data,
    fileName: "sample.txt",
    mimeType: "text/plain"
)

apiClient.uploadSerial<User>(
    path: "/posts",
    items: [uploadItem],
    onProgress: { progress in
        // Handle upload progress
    }
) { result in
    // Handle completion
}
```

## Requirements

- iOS 15.0+
- Xcode 14.0+
- Swift 5.0+

## Notes

- All network calls are made to real APIs for authentic testing
- The app includes comprehensive logging to see exactly what's happening
- Error handling demonstrates best practices with the Snapi library
- UI is built with Storyboard for easy modification