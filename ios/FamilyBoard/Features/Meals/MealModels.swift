import Foundation

struct MealStatus: Codable {
    let configured: Bool
    let online: Bool
    let error: String?
}

struct MealSummary: Codable, Identifiable {
    let slug: String
    let name: String
    let image: String?
    let missingCount: Int?
    let totalIngredients: Int

    var id: String { slug }
    var availability: String {
        guard let missingCount else { return "Ingredients not checked" }
        return missingCount == 0 ? "Ready to cook" : "\(missingCount) missing"
    }

    static func filtered(_ meals: [MealSummary], search: String) -> [MealSummary] {
        meals.filter {
            search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)
        }.sorted {
            switch ($0.missingCount, $1.missingCount) {
            case (nil, nil): return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            case (nil, _): return false
            case (_, nil): return true
            case (let left?, let right?):
                if left != right { return left < right }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }
    }
}

struct MealRecipe: Decodable {
    let slug: String
    let name: String
    let image: String?
    let url: String?

    var externalURL: URL? {
        guard let url, let parsed = URL(string: url),
              ["https", "http"].contains(parsed.scheme?.lowercased() ?? ""),
              parsed.host != nil, parsed.user == nil, parsed.password == nil else { return nil }
        return parsed
    }
}

struct MealIngredientMatch: Decodable {
    let ingredient: String
    let originalText: String
    let haveIt: Bool
    let matchedItem: MealMatchedItem?
    let confidence: Double
    let isManualLink: Bool
}

struct MealMatchedItem: Decodable {
    let id: String
    let name: String
    let quantity: Double
    let unit: String?
}

struct MealMatchDetail: Decodable {
    let recipe: MealRecipe
    let matches: [MealIngredientMatch]
    let missingCount: Int
    let canMake: Bool
}
