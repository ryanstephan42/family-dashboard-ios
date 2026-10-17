import Foundation

struct ReceiptScanResult: Decodable {
    let method: String
    let items: [ReceiptParsedItem]
}

struct ReceiptParsedItem: Decodable {
    let name: String
    let quantity: Double?
    let price: Double?
    let category: String?
    let unit: String?
}

struct ReceiptReviewItem: Identifiable {
    let id = UUID()
    var selected = true
    var name: String
    var quantity: String
    var unit: String
    var category: String

    init(_ item: ReceiptParsedItem) {
        name = item.name
        quantity = String(item.quantity.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 1)
        unit = item.unit.flatMap { $0.isEmpty ? nil : $0 } ?? "count"
        category = item.category.flatMap { $0.isEmpty ? nil : $0 } ?? "General"
    }
}

struct ReceiptInventoryItem: Encodable {
    let name: String
    let quantity: Double
    let unit: String
    let category: String
    let location: String
}

struct ReceiptImport: Encodable {
    let items: [ReceiptInventoryItem]

    init(review: [ReceiptReviewItem], location: String) throws {
        let selected = review.filter(\.selected)
        guard !selected.isEmpty else { throw ReceiptError.validation("Select at least one item.") }
        let location = location.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !location.isEmpty else { throw ReceiptError.validation("Choose a storage location.") }
        items = try selected.map { item in
            let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let unit = item.unit.trimmingCharacters(in: .whitespacesAndNewlines)
            let category = item.category.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !unit.isEmpty, !category.isEmpty else {
                throw ReceiptError.validation("Each selected item needs a name, unit, and category.")
            }
            guard let quantity = Double(item.quantity), quantity.isFinite, quantity > 0 else {
                throw ReceiptError.validation("Each selected item needs a quantity greater than zero.")
            }
            return ReceiptInventoryItem(name: name, quantity: quantity, unit: unit,
                                        category: category, location: location)
        }
    }
}

enum ReceiptError: LocalizedError {
    case validation(String)

    var errorDescription: String? {
        switch self {
        case .validation(let message): return message
        }
    }
}

struct ReceiptImage {
    static let maximumBytes = 15 * 1024 * 1024
    let data: Data

    init(jpegData: Data) throws {
        guard !jpegData.isEmpty, jpegData.count <= Self.maximumBytes else {
            throw ReceiptError.validation("Choose a nonempty receipt image smaller than 15 MB.")
        }
        data = jpegData
    }
}

struct ReceiptService {
    let client: APIClient

    func scan(_ image: ReceiptImage) async throws -> ReceiptScanResult {
        try await client.upload("POST", APIClient.path("receipt", "scan"), fieldName: "receipt",
                                filename: "receipt.jpg", mimeType: "image/jpeg", data: image.data)
    }

    func save(_ payload: ReceiptImport) async throws {
        // Do not decode created items: a decoding failure after a successful write must not invite a retry.
        _ = try await client.send("POST", APIClient.path("inventory"), body: payload)
    }
}
