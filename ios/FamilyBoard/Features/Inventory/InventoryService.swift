import Foundation

struct InventoryService {
    let client: APIClient

    func items() async throws -> [InventoryItem] {
        try await client.request("GET", "/inventory")
    }

    func unitOptions() async throws -> InventoryUnitOptions {
        try await client.request("GET", "/inventory/unit-options")
    }

    func create(_ draft: InventoryDraft) async throws -> [InventoryItem] {
        struct Envelope: Encodable { let items: [InventoryWrite] }
        return try await client.request("POST", "/inventory", body: Envelope(items: [try draft.payload()]))
    }

    func update(id: String, draft: InventoryDraft) async throws -> InventoryItem {
        try await client.request("PUT", path(id), body: draft.payload())
    }

    func adjust(id: String, delta: Double) async throws -> InventoryItem {
        guard delta.isFinite, delta != 0 else {
            throw InventoryValidationError(message: "Quantity adjustment must be a finite, nonzero number.")
        }
        struct Adjustment: Encodable { let delta: Double }
        return try await client.request("PATCH", path(id) + "/quantity", body: Adjustment(delta: delta))
    }

    func delete(id: String) async throws {
        _ = try await client.send("DELETE", path(id))
    }

    private func path(_ id: String) throws -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#%")
        guard !id.isEmpty, let encoded = id.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw InventoryValidationError(message: "The inventory item has an invalid identifier.")
        }
        return "/inventory/" + encoded
    }
}
