/*
Fetches restaurant list from the TacTech backend.
*/

import Foundation
import os

struct Restaurant: Identifiable, Codable, Hashable {
    let id: String
    let name: String

    enum CodingKeys: String, CodingKey {
        case id
        case restaurantId = "restaurant_id"
        case name
    }

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let id = try container.decodeIfPresent(String.self, forKey: .id) {
            self.id = id
        } else {
            self.id = try container.decode(String.self, forKey: .restaurantId)
        }
        self.name = try container.decode(String.self, forKey: .name)
    }
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
        request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw RestaurantServiceError.invalidResponse
        }

        guard 200...299 ~= httpResponse.statusCode else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw RestaurantServiceError.serverError(httpResponse.statusCode, message)
        }

        let restaurants = try decodeRestaurants(from: data)
        Self.logger.info("Fetched \(restaurants.count) restaurants")
        return restaurants
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

        let preview = String(data: data.prefix(200), encoding: .utf8) ?? ""
        Self.logger.error("Restaurant decode failed. Body preview: \(preview)")
        throw RestaurantServiceError.decodingFailed
    }
}
