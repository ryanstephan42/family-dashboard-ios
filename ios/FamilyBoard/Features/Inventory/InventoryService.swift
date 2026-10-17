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

    func lookupBarcode(_ code: String) async throws -> InventoryBarcodeProduct {
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty, code.count <= 128,
              code.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw InventoryValidationError(message: "Enter a barcode of up to 128 characters.")
        }
        return try await client.request("GET", APIClient.path("inventory", "barcode", code))
    }

    func uploadPhoto(id: String, data: Data) async throws -> InventoryItem {
        guard !data.isEmpty, data.count <= InventoryPhoto.maximumBytes else {
            throw InventoryValidationError(message: "Choose a photo smaller than 10 MB.")
        }
        return try await client.upload(
            "POST", path(id) + "/photo", fieldName: "photo",
            filename: "inventory.jpg", mimeType: "image/jpeg", data: data
        )
    }

    func deletePhoto(id: String) async throws -> InventoryItem {
        try await client.request("DELETE", path(id) + "/photo")
    }

    private func path(_ id: String) throws -> String {
        guard !id.isEmpty else {
            throw InventoryValidationError(message: "The inventory item has an invalid identifier.")
        }
        return APIClient.path("inventory", id)
    }
}
