/*
Restaurant picker shown before starting a scan.
*/

import SwiftUI

@available(iOS 17.0, *)
struct RestaurantSelectionView: View {
    @EnvironmentObject var appModel: AppDataModel

    @State private var restaurants: [Restaurant] = []
    @State private var selectedRestaurantId: String?
    @State private var isLoading = true
    @State private var errorMessage: String?

    private let restaurantService = RestaurantService()

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    loadingView
                } else if let errorMessage {
                    errorView(message: errorMessage)
                } else if restaurants.isEmpty {
                    emptyView
                } else {
                    restaurantList
                }
            }
            .navigationTitle("Select Restaurant")
            .safeAreaInset(edge: .bottom) {
                startScanButton
            }
        }
        .task {
            await loadRestaurants()
        }
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Loading restaurants…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: 16) {
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            Button("Retry") {
                Task { await loadRestaurants() }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Text("No restaurants found")
                .font(.headline)
            Text("Add a restaurant in the backend, then tap Retry.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button("Retry") {
                Task { await loadRestaurants() }
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var restaurantList: some View {
        List(restaurants) { restaurant in
            Button {
                selectedRestaurantId = restaurant.id
            } label: {
                HStack {
                    Text(restaurant.name)
                        .foregroundStyle(.primary)
                    Spacer()
                    if selectedRestaurantId == restaurant.id {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.blue)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var startScanButton: some View {
        Button {
            guard let id = selectedRestaurantId,
                  let restaurant = restaurants.first(where: { $0.id == id }) else { return }
            appModel.selectRestaurant(id: id, name: restaurant.name)
            appModel.startScan()
        } label: {
            Text("Start Scan")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent)
        .disabled(selectedRestaurantId == nil)
        .padding()
        .background(.bar)
    }

    @MainActor
    private func loadRestaurants() async {
        isLoading = true
        errorMessage = nil

        do {
            restaurants = try await restaurantService.fetchRestaurants()
            if let existingId = appModel.selectedRestaurantId,
               restaurants.contains(where: { $0.id == existingId }) {
                selectedRestaurantId = existingId
            }
            isLoading = false
        } catch {
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }
}
