import Foundation

struct InventoryBarcodeProduct: Decodable {
    let barcode: String
    let name: String
    let category: String?
    let unit: String?
    let source: String?
}

extension InventoryDraft {
    mutating func apply(_ product: InventoryBarcodeProduct) {
        barcode = product.barcode
        name = product.name
        if let category = product.category, !category.isEmpty { self.category = category }
        if let unit = product.unit { self.unit = unit }
    }
}

enum InventoryPhoto {
    static let maximumBytes = 10 * 1024 * 1024

    // Uploads are origin-relative, never relative to /api or a configured base path.
    static func url(_ path: String?, server: URL) -> URL? {
        guard let path, path.hasPrefix("/uploads/"),
              let upload = URLComponents(string: path),
              upload.scheme == nil, upload.host == nil,
              upload.query == nil, upload.fragment == nil else { return nil }
        let parts = upload.path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].isEmpty, parts[1] == "uploads",
              !parts[2].isEmpty, parts[2] != ".", parts[2] != "..",
              !parts[2].contains("%"), !parts[2].contains("\\"),
              upload.path.rangeOfCharacter(from: .controlCharacters) == nil,
              var origin = URLComponents(url: server, resolvingAgainstBaseURL: false),
              origin.scheme == "https" || origin.scheme == "http",
              origin.host != nil, origin.user == nil, origin.password == nil else { return nil }
        origin.percentEncodedPath = upload.percentEncodedPath
        origin.query = nil
        origin.fragment = nil
        return origin.url
    }
}
