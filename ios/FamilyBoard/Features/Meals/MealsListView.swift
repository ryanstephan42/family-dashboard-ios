import SwiftUI

struct MealsListView: View {
    @EnvironmentObject private var session: Session
    @State private var status: MealStatus?
    @State private var meals: [MealSummary] = []
    @State private var search = ""
    @State private var loading = false
    @State private var loaded = false
    @State private var errorMessage: String?

    private var visibleMeals: [MealSummary] {
        MealSummary.filtered(meals, search: search)
    }

    var body: some View {
        NavigationStack {
            List {
                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                        Button("Retry loading meals") { Task { await load() } }
                            .disabled(loading)
                    }
                }
                if loading {
                    ProgressView("Checking recipes and inventory")
                }
                if let status, !status.configured {
                    ContentUnavailableView(
                        "Mealie isn't connected yet", systemImage: "fork.knife",
                        description: Text("Ask your server administrator to configure Mealie. The rest of the app is still available.")
                    )
                } else if let status, !status.online {
                    ContentUnavailableView {
                        Label("Mealie is offline", systemImage: "wifi.slash")
                    } description: {
                        Text(status.error ?? "Couldn't reach Mealie. The rest of the app is still available.")
                    } actions: {
                        Button("Retry") { Task { await load() } }
                    }
                } else if loaded && errorMessage == nil && visibleMeals.isEmpty {
                    ContentUnavailableView(
                        search.isEmpty ? "No recipes in Mealie" : "No matching recipes",
                        systemImage: "fork.knife",
                        description: Text(search.isEmpty ? "Save recipes in Mealie, then refresh." : "Try a different search.")
                    )
                } else if status?.online == true {
                    Section {
                        ForEach(visibleMeals) { meal in
                            NavigationLink {
                                MealDetailView(slug: meal.slug) { await load() }
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(meal.name).font(.headline)
                                    Text(meal.availability)
                                        .foregroundStyle(meal.missingCount == 0 ? .green : .secondary)
                                    if let missing = meal.missingCount, meal.totalIngredients > 0 {
                                        Text("\(meal.totalIngredients - missing)/\(meal.totalIngredients) ingredients on hand")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    } header: {
                        Text("What can I make?")
                    } footer: {
                        Text("Fewest missing ingredients first. Matches indicate items on hand, not enough quantity for a recipe.")
                    }
                }
            }
            .navigationTitle("Meals")
            .searchable(text: $search, prompt: "Search recipes")
            .toolbar {
                Button {
                    Task { await load() }
                } label: {
                    Label("Refresh meals", systemImage: "arrow.clockwise")
                }
                .disabled(loading)
            }
            .refreshable { await load() }
            .task { if !loaded { await load() } }
        }
    }

    @MainActor private func load() async {
        guard !loading else { return }
        loading = true
        errorMessage = nil
        defer { loading = false }
        do {
            guard let client = session.client else { throw APIError.unauthorized }
            let service = MealsService(client: client)
            let currentStatus = try await service.status()
            status = currentStatus
            if currentStatus.configured && currentStatus.online {
                meals = try await service.meals()
            } else {
                meals = []
            }
            loaded = true
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
