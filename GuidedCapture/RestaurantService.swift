/*
Fetches restaurant list from the TacTech backend.
*/

import Foundation
import os

struct Restaurant: Identifiable, Codable, Hashable {
    let id: String
    let name: String
}

enum RestaurantServiceError: LocalizedError {
    case invalidResponse
    case serverError(Int, String)
    case decodingFailed

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from server"
        case .serverError(let code, let message):
            return "Server error \(code): \(message)"
        case .decodingFailed:
            return "Could not read restaurant list from server"
        }
    }
}

final class RestaurantService {
    static let logger = Logger(subsystem: GuidedCaptureSampleApp.subsystem,
                               category: "RestaurantService")

    private let session: URLSession
    private let restaurantsURL: URL

    init(baseURL: String = BackendConfig.baseURL, session: URLSession = .shared) {
        self.session = session
        self.restaurantsURL = URL(string: "\(baseURL)/api/v1/restaurants")!
        Self.logger.info("RestaurantService initialized with URL: \(self.restaurantsURL)")
    }

    func fetchRestaurants() async throws -> [Restaurant] {
        var request = URLRequest(url: restaurantsURL)
        request.httpMethod = "GET"

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw RestaurantServiceError.invalidResponse
        }

        guard 200...299 ~= httpResponse.statusCode else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw RestaurantServiceError.serverError(httpResponse.statusCode, message)
        }

        return try decodeRestaurants(from: data)
    }

    private func decodeRestaurants(from data: Data) throws -> [Restaurant] {
        let decoder = JSONDecoder()

        if let restaurants = try? decoder.decode([Restaurant].self, from: data) {
            return restaurants
        }

        struct WrappedList: Codable {
            let restaurants: [Restaurant]?
            let items: [Restaurant]?
            let data: [Restaurant]?
        }

        if let wrapped = try? decoder.decode(WrappedList.self, from: data) {
            if let restaurants = wrapped.restaurants { return restaurants }
            if let items = wrapped.items { return items }
            if let data = wrapped.data { return data }
        }

        throw RestaurantServiceError.decodingFailed
    }
}
