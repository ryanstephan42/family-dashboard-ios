import Foundation

struct InventoryItem: Codable, Identifiable {
    let id: String
    let name: String
    let quantity: Double
    let unit: String?
    let category: String
    let location: String
    let purchaseDate: Date
    let trackExpiration: Bool
    let expirationDate: Date?
    let notes: String?
    let parLevel: Double?
    let lowStock: Bool
    let photoUrl: String?
    let barcode: String?

    var isRunningLow: Bool {
        lowStock || parLevel.map { quantity <= $0 } == true
    }
}

struct InventoryUnitOptions: Codable {
    let commonUnits: [String]
    let preferences: [InventoryUnitPreference]

    func preferredUnit(for name: String) -> String? {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return preferences.first { $0.itemName == key }?.unit
    }
}

struct InventoryUnitPreference: Codable {
    let itemName: String
    let unit: String
}

enum InventoryExpirationFilter: String, CaseIterable {
    case all = "All dates"
    case soon = "Expiring soon"
    case expired = "Expired"
}

struct InventoryFilter {
    var search = ""
    var location = ""
    var category = ""
    var runningLow = false
    var expiration: InventoryExpirationFilter = .all

    func matches(_ item: InventoryItem, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard location.isEmpty || item.location == location,
              category.isEmpty || item.category == category,
              !runningLow || item.isRunningLow else { return false }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.isEmpty || [item.name, item.category, item.location, item.notes ?? ""]
            .joined(separator: " ").localizedStandardContains(query) else { return false }
        if expiration != .all {
            guard item.trackExpiration, let date = item.expirationDate,
                  let days = calendar.dateComponents(
                    [.day], from: calendar.startOfDay(for: now),
                    to: calendar.startOfDay(for: date)
                  ).day else { return false }
            return expiration == .expired ? days < 0 : (0...14).contains(days)
        }
        return true
    }
}

struct InventoryDraft: Equatable {
    static let locations = ["Pantry", "Fridge", "Freezer", "Deep Freezer", "Kitchen Shelf"]
    var name = ""
    var quantity = "1"
    var unit = ""
    var category = "General"
    var location = "Pantry"
    var purchaseDate = Date()
    var trackExpiration = true
    var hasExpirationDate = false
    var expirationDate = Date()
    var notes = ""
    var parLevel = ""
    var barcode = ""

    init(item: InventoryItem? = nil) {
        guard let item else { return }
        name = item.name
        quantity = String(item.quantity)
        unit = item.unit ?? ""
        category = item.category
        location = item.location
        purchaseDate = item.purchaseDate
        trackExpiration = item.trackExpiration
        hasExpirationDate = item.expirationDate != nil
        expirationDate = item.expirationDate ?? Date()
        notes = item.notes ?? ""
        parLevel = item.parLevel.map { String($0) } ?? ""
        barcode = item.barcode ?? ""
    }

    var validationMessage: String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Enter an item name." }
        if barcode.count > 128 || barcode.rangeOfCharacter(from: .controlCharacters) != nil {
            return "Enter a barcode of up to 128 characters without control characters."
        }
        guard let count = Double(quantity), count.isFinite, count >= 0 else {
            return "Quantity must be a nonnegative number."
        }
        if !parLevel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let level = Double(parLevel), level.isFinite, level >= 0 else {
                return "Par level must be a nonnegative number."
            }
        }
        if location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Enter a storage location."
        }
        if category.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Enter a category."
        }
        return nil
    }

    func payload() throws -> InventoryWrite {
        if let message = validationMessage { throw InventoryValidationError(message: message) }
        guard let count = Double(quantity) else {
            throw InventoryValidationError(message: "Enter a valid quantity.")
        }
        return InventoryWrite(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            quantity: count,
            unit: unit.trimmingCharacters(in: .whitespacesAndNewlines),
            category: category.trimmingCharacters(in: .whitespacesAndNewlines),
            location: location.trimmingCharacters(in: .whitespacesAndNewlines),
            purchaseDate: purchaseDate,
            trackExpiration: trackExpiration,
            expirationDate: trackExpiration && hasExpirationDate ? expirationDate : nil,
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
            parLevel: Double(parLevel),
            barcode: barcode.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

struct InventoryValidationError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct InventoryWrite: Encodable {
    let name: String
    let quantity: Double
    let unit: String
    let category: String
    let location: String
    let purchaseDate: Date
    let trackExpiration: Bool
    let expirationDate: Date?
    let notes: String
    let parLevel: Double?
    let barcode: String

    enum CodingKeys: String, CodingKey {
        case name, quantity, unit, category, location, purchaseDate
        case trackExpiration, expirationDate, notes, parLevel, barcode
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        try c.encode(name, forKey: .name)
        try c.encode(quantity, forKey: .quantity)
        try c.encode(unit, forKey: .unit)
        try c.encode(category, forKey: .category)
        try c.encode(location, forKey: .location)
        try c.encode(formatter.string(from: purchaseDate), forKey: .purchaseDate)
        try c.encode(trackExpiration, forKey: .trackExpiration)
        // Explicit null clears an existing value on PUT; omission would preserve it.
        try c.encode(expirationDate.map { formatter.string(from: $0) }, forKey: .expirationDate)
        try c.encode(notes, forKey: .notes)
        try c.encode(parLevel, forKey: .parLevel)
        if !barcode.isEmpty { try c.encode(barcode, forKey: .barcode) }
    }
}
