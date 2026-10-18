import Foundation

struct GroceryItem: Codable, Identifiable, Hashable {
    let id: String
    var name: String
    var quantity: String?
    var details: String?
    var category: String?
    var completed: Bool
    var createdAt: Date?
    var updatedAt: Date?
}

struct GroceryCategoryPreference: Codable, Hashable {
    let itemName: String
    let category: String
}

struct GrocerySuggestion: Codable, Hashable {
    let name: String
    let category: String?
    let quantity: String?
    let reason: String
}

struct GroceryItemInput: Encodable {
    let name: String
    let quantity: String?
    let details: String?
    let category: String?
}

private struct GroceryItemsRequest: Encodable {
    let items: [GroceryItemInput]
}

private struct GroceryItemUpdate: Encodable {
    let name: String
    let quantity: String
    let details: String
    let category: String
    let completed: Bool
}

struct GroceryAPI {
    let client: APIClient

    func fetchItems() async throws -> [GroceryItem] {
        try await client.request("GET", "/grocery")
    }

    func fetchPreferences() async throws -> [GroceryCategoryPreference] {
        try await client.request("GET", "/grocery/preferences")
    }

    func fetchSuggestions() async throws -> [GrocerySuggestion] {
        try await client.request("GET", "/grocery/suggestions")
    }

    func createItems(_ items: [GroceryItemInput]) async throws {
        let _: [GroceryItem] = try await client.request(
            "POST", "/grocery", body: GroceryItemsRequest(items: items)
        )
    }

    func update(_ item: GroceryItem) async throws {
        let body = GroceryItemUpdate(
            name: item.name,
            quantity: item.quantity ?? "",
            details: item.details ?? "",
            category: item.category ?? "",
            completed: item.completed
        )
        let _: GroceryItem = try await client.request(
            "PUT", "/grocery/\(item.id)", body: body
        )
    }

    func delete(id: String) async throws {
        _ = try await client.send("DELETE", "/grocery/\(id)")
    }

    func purchase(id: String) async throws {
        _ = try await client.send("POST", "/grocery/\(id)/purchase")
    }
}
