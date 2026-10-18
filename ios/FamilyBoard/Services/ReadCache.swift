import CryptoKit
import Foundation

struct ReadCacheStatus {
    let savedAt: Date
    var isStale: Bool
    var warning: String?
}

struct CachedRead<Value> {
    let value: Value
    let status: ReadCacheStatus
}

/// Stores only explicitly selected, decoded read models, never requests or credentials.
@MainActor
final class ReadCache {
    private let directory: URL
    private let files: FileManager

    private struct Entry<Value: Codable>: Codable {
        let savedAt: Date
        let value: Value
    }

    init(directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("FamilyBoardReads-v1", isDirectory: true),
         files: FileManager = .default) {
        self.directory = directory
        self.files = files
    }

    static func key(client: APIClient, userID: String, path: String,
                    query: [URLQueryItem] = []) throws -> String {
        let request = try client.makeRequest("GET", path, query: query)
        guard let url = request.url else { throw APIError.invalidURL }
        // Structured encoding avoids separator collisions; neither the token nor headers enter the key.
        let identity = try JSONEncoder().encode([userID, url.absoluteString])
        return SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
    }

    func load<Value: Codable>(_ type: Value.Type, key: String) throws -> CachedRead<Value>? {
        let url = directory.appendingPathComponent(key)
        guard files.fileExists(atPath: url.path) else { return nil }
        let entry = try JSONDecoder().decode(Entry<Value>.self, from: Data(contentsOf: url))
        return CachedRead(value: entry.value,
                          status: ReadCacheStatus(savedAt: entry.savedAt, isStale: true))
    }

    func save<Value: Codable>(_ value: Value, key: String, at date: Date) throws {
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(Entry(savedAt: date, value: value))
        try data.write(to: directory.appendingPathComponent(key),
                       options: [.atomic, .completeFileProtection])
    }

    func clear() throws {
        if files.fileExists(atPath: directory.path) { try files.removeItem(at: directory) }
    }

    static func allowsFallback(for error: Error) -> Bool {
        guard let error = error as? URLError else { return false }
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .timedOut,
             .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return true
        default:
            return false
        }
    }
}
