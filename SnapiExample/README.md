# Snapi Example

This example demonstrates how to use the Snapi networking library for common HTTP operations.

## Features Demonstrated

- **GET Requests**: Fetching data from REST APIs
- **POST Requests**: Sending data to create resources
- **File Uploads**: Serial upload with progress tracking
- **Image Downloads**: Downloading and processing images

## Running the Example

```bash
cd Examples/SnapiExample
swift run
```

## Code Overview

The example covers:

1. **Configuration**: Setting up `NetworkConfiguration` with base URL and timeout
2. **API Client**: Creating an `APIClient` instance
3. **GET Request**: Fetching a list of users from JSONPlaceholder API
4. **POST Request**: Creating a new user resource
5. **File Upload**: Uploading a sample text file with progress tracking
6. **Image Download**: Downloading an image and handling the result

## API Endpoints Used

- `GET /users` - Fetch users (JSONPlaceholder)
- `POST /users` - Create user (JSONPlaceholder) 
- `POST /upload` - File upload endpoint (mock)
- Image download from placeholder service

## Error Handling

All requests include proper error handling demonstrating how to work with `NetworkError` types returned by the Snapi library.