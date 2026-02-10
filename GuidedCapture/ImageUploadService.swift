/*
Image Upload Service for iOS Guided Capture

Abstract:
A reusable networking service that uploads multiple captured images to a FastAPI backend
using multipart/form-data POST requests with URLSession.
*/

import Foundation
import os
import Combine

class ImageUploadService: ObservableObject {
    static let logger = Logger(subsystem: GuidedCaptureSampleApp.subsystem,
                                category: "ImageUploadService")
    
    private let logger = ImageUploadService.logger
    private let session: URLSession
    private let uploadURL: URL
    
    // Published properties for UI updates
    @Published var uploadProgress: Double = 0.0
    @Published var isUploading: Bool = false
    @Published var uploadStatus: String = ""
    
    init(baseURL: String = "http://localhost:8000") {
        // Configure URLSession with appropriate timeout for large uploads
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300 // 5 minutes
        config.timeoutIntervalForResource = 600 // 10 minutes
        config.waitsForConnectivity = true
        
        self.session = URLSession(configuration: config)
        self.uploadURL = URL(string: "\(baseURL)/api/v1/scans/upload")!
        
        logger.info("ImageUploadService initialized with URL: \(self.uploadURL)")
    }
    
    /// Uploads multiple image files to the backend using multipart/form-data
    /// - Parameters:
    ///   - imageUrls: Array of local file URLs for the images to upload
    ///   - completion: Completion handler with success/failure result
    func uploadImages(imageUrls: [URL], completion: @escaping (Result<Void, Error>) -> Void) {
        logger.info("Starting upload of \(imageUrls.count) images")
        print("[ImageUploadService] Starting upload of \(imageUrls.count) images to \(uploadURL.absoluteString)")
        
        guard !imageUrls.isEmpty else {
            logger.error("No images provided for upload")
            completion(.failure(UploadError.noImages))
            return
        }
        
        // Validate all image files exist
        for imageUrl in imageUrls {
            guard FileManager.default.fileExists(atPath: imageUrl.path) else {
                logger.error("Image file not found: \(imageUrl.path)")
                completion(.failure(UploadError.fileNotFound(imageUrl)))
                return
            }
        }
        
        DispatchQueue.main.async {
            self.isUploading = true
            self.uploadProgress = 0.0
            self.uploadStatus = "Preparing upload..."
            print("[ImageUploadService] Upload state: preparing...")
        }
        
        Task {
            do {
                let request = try createMultipartRequest(imageUrls: imageUrls)
                try await performUpload(request: request, imageUrls: imageUrls, completion: completion)
            } catch {
                logger.error("Upload failed with error: \(error.localizedDescription)")
                print("[ImageUploadService] Upload failed before request: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.isUploading = false
                    self.uploadStatus = "Upload failed"
                }
                completion(.failure(error))
            }
        }
    }
    
    /// Creates a multipart/form-data request with all images
    private func createMultipartRequest(imageUrls: [URL]) throws -> URLRequest {
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "POST"
        
        // Create boundary string
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        print("[ImageUploadService] Creating multipart request to: \(uploadURL.absoluteString)")
        print("[ImageUploadService] Boundary: \(boundary)")
        
        // Build multipart body
        var body = Data()
        
        for (index, imageUrl) in imageUrls.enumerated() {
            let imageData = try Data(contentsOf: imageUrl)
            let filename = imageUrl.lastPathComponent
            
            // Add file boundary
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"images\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: image/heic\r\n\r\n".data(using: .utf8)!)
            body.append(imageData)
            body.append("\r\n".data(using: .utf8)!)
            
            print("[ImageUploadService] Added image \(index + 1)/\(imageUrls.count): \(filename) (\(imageData.count) bytes)")
        }
        
        // Add closing boundary
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        
        request.httpBody = body
        
        logger.info("Created multipart request with total size: \(body.count) bytes")
        print("[ImageUploadService] Request body size: \(body.count) bytes")
        print("[ImageUploadService] Content-Type: multipart/form-data; boundary=\(boundary)")
        
        return request
    }
    
    /// Performs the actual upload with progress tracking using async/await
    private func performUpload(request: URLRequest, imageUrls: [URL], completion: @escaping (Result<Void, Error>) -> Void) async throws {
        // Use async upload(for:from:) API.
        // Important: the URLRequest passed to upload(for:from:) must NOT also have httpBody set,
        // otherwise URLSession logs a warning and may ignore/override the body.
        guard let bodyData = request.httpBody else {
            print("[ImageUploadService] No HTTP body set on request; aborting upload")
            throw UploadError.invalidResponse
        }

        print("[ImageUploadService] Calling URLSession.upload(for:from:) ...")

        do {
            var uploadRequest = request
            uploadRequest.httpBody = nil
            let (data, response) = try await session.upload(for: uploadRequest, from: bodyData)

            DispatchQueue.main.async {
                self.isUploading = false
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                self.logger.error("Invalid response received")
                print("[ImageUploadService] Invalid response (not HTTPURLResponse)")
                throw UploadError.invalidResponse
            }

            self.logger.info("Upload completed with status code: \(httpResponse.statusCode)")
            print("[ImageUploadService] Response status code: \(httpResponse.statusCode)")

            if 200...299 ~= httpResponse.statusCode {
                self.logger.info("All images uploaded successfully")
                DispatchQueue.main.async {
                    self.uploadStatus = "Upload completed successfully"
                    print("[ImageUploadService] Upload completed successfully")
                }
                completion(.success(()))
            } else {
                let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
                self.logger.error("Server returned error: \(httpResponse.statusCode) - \(errorMessage)")
                print("[ImageUploadService] Server error: \(httpResponse.statusCode) - \(errorMessage)")
                let error = UploadError.serverError(httpResponse.statusCode, errorMessage)
                completion(.failure(error))
                throw error
            }
        } catch {
            self.logger.error("Upload task failed: \(error.localizedDescription)")
            print("[ImageUploadService] Upload task failed: \(error.localizedDescription)")
            DispatchQueue.main.async {
                self.isUploading = false
                self.uploadStatus = "Upload failed"
            }
            completion(.failure(error))
            throw error
        }
    }
}

// MARK: - Error Types
enum UploadError: LocalizedError {
    case noImages
    case fileNotFound(URL)
    case invalidResponse
    case serverError(Int, String)
    
    var errorDescription: String? {
        switch self {
        case .noImages:
            return "No images provided for upload"
        case .fileNotFound(let url):
            return "Image file not found: \(url.lastPathComponent)"
        case .invalidResponse:
            return "Invalid response from server"
        case .serverError(let code, let message):
            return "Server error \(code): \(message)"
        }
    }
}

// MARK: - Upload Progress Extension
extension ImageUploadService {
    /// Resets upload state for new uploads
    func resetUploadState() {
        DispatchQueue.main.async {
            self.uploadProgress = 0.0
            self.isUploading = false
            self.uploadStatus = ""
        }
    }
}
