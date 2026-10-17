import Foundation

/// API version this build understands; compared with /api/config apiVersion.
let supportedAPIVersion = 1

enum APIError: LocalizedError {
    case invalidURL
    case unauthorized
    case server(status: Int, message: String?)
    case incompatible

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid server address."
        case .unauthorized: return "Session expired. Please sign in again."
        case .server(let status, let message): return message ?? "Server error (\(status))."
        case .incompatible: return "This server is not compatible with this app version."
        }
    }
}

struct APIClient {
    let baseURL: URL
    var token: String?

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        d.dateDecodingStrategy = .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            if let date = withFraction.date(from: s) ?? plain.date(from: s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                     debugDescription: "Bad date \(s)"))
        }
        return d
    }()

    /// Normalizes user input like "family.example.com" to an https URL.
    static func normalize(_ input: String) -> URL? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        if !s.contains("://") { s = "https://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        guard let url = URL(string: s), url.scheme == "https" || url.scheme == "http",
              url.host != nil else { return nil }
        return url
    }

    func request<T: Decodable>(_ method: String, _ path: String,
                               body: Encodable? = nil) async throws -> T {
        let data = try await send(method, path, body: body)
        return try Self.decoder.decode(T.self, from: data)
    }

    func send(_ method: String, _ path: String, body: Encodable? = nil) async throws -> Data {
        guard let url = URL(string: baseURL.absoluteString + "/api" + path) else {
            throw APIError.invalidURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(AnyEncodable(body))
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw APIError.unauthorized }
        guard (200..<300).contains(status) else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw APIError.server(status: status, message: msg)
        }
        return data
    }

    func checkCompatibility() async throws {
        let config: ServerConfig = try await request("GET", "/config")
        if let min = config.minClientApiVersion, supportedAPIVersion < min {
            throw APIError.incompatible
        }
    }
}

private struct AnyEncodable: Encodable {
    let value: Encodable
    init(_ value: Encodable) { self.value = value }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}
