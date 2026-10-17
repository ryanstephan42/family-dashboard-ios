import Foundation

struct MealsService {
    let client: APIClient

    func status() async throws -> MealStatus {
        try await client.request("GET", "/meals/status")
    }

    func meals() async throws -> [MealSummary] {
        try await client.request("GET", "/meals/what-can-i-make")
    }

    func detail(slug: String) async throws -> MealMatchDetail {
        try await client.request("GET", APIClient.path("meals", "recipes", slug, "match"))
    }

    func link(slug: String, ingredient: String, inventoryItemName: String) async throws {
        struct Link: Encodable {
            let ingredientName: String
            let inventoryItemName: String
        }
        _ = try await client.send(
            "POST", APIClient.path("meals", "recipes", slug, "link"),
            body: Link(ingredientName: ingredient, inventoryItemName: inventoryItemName)
        )
    }

    func unlink(slug: String, ingredient: String) async throws {
        // This route decodes again after Express's parameter decoding.
        let encoded = String(APIClient.path(ingredient).dropFirst())
        _ = try await client.send(
            "DELETE", APIClient.path("meals", "recipes", slug, "link", encoded)
        )
    }
}
