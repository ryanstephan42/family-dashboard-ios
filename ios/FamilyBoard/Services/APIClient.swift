import Foundation

/// API version this build understands; compared with /api/config apiVersion.
let supportedAPIVersion = 1

enum APIError: LocalizedError {
    case invalidURL
    case unauthorized
    case server(status: Int, message: String?)
    case incompatible
    case invalidResponse
    case invalidUpload

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid server address."
        case .unauthorized: return "Session expired. Please sign in again."
        case .server(let status, let message): return message ?? "Server error (\(status))."
        case .incompatible: return "This server is not compatible with this app version."
        case .invalidResponse: return "The server returned an invalid response."
        case .invalidUpload: return "The upload contains an invalid field name, filename, or content type."
        }
    }
}

struct APIClient {
    let baseURL: URL
    var token: String?
    var session: URLSession = .shared
    var onUnauthorized: (@MainActor () -> Void)?

    private static func makeDecoder() -> JSONDecoder {
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
    }

    /// Normalizes user input like "family.example.com" to an https URL.
    static func normalize(_ input: String) -> URL? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        if !s.contains("://") { s = "https://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        guard let url = URL(string: s), url.scheme == "https" || url.scheme == "http",
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return nil }
        return url
    }

    /// Encodes each dynamic path component, including slashes inside identifiers.
    static func path(_ components: String...) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_~"))
        return "/" + components.map { $0.addingPercentEncoding(withAllowedCharacters: allowed)! }
            .joined(separator: "/")
    }

    func request<T: Decodable>(_ method: String, _ path: String,
                               body: Encodable? = nil, query: [URLQueryItem] = []) async throws -> T {
        let data = try await send(method, path, body: body, query: query)
        return try Self.makeDecoder().decode(T.self, from: data)
    }

    func send(_ method: String, _ path: String, body: Encodable? = nil,
              query: [URLQueryItem] = []) async throws -> Data {
        var req = try makeRequest(method, path, query: query)
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(AnyEncodable(body))
        }
        return try await perform(req)
    }

    func upload<T: Decodable>(_ method: String, _ path: String, fieldName: String,
                              filename: String, mimeType: String, data: Data) async throws -> T {
        let response = try await sendUpload(method, path, fieldName: fieldName,
                                           filename: filename, mimeType: mimeType, data: data)
        return try Self.makeDecoder().decode(T.self, from: response)
    }

    func sendUpload(_ method: String, _ path: String, fieldName: String,
                    filename: String, mimeType: String, data: Data) async throws -> Data {
        let forbidden = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "\"\\"))
        guard [fieldName, filename, mimeType].allSatisfy({
            !$0.isEmpty && $0.rangeOfCharacter(from: forbidden) == nil
        }) else { throw APIError.invalidUpload }
        let boundary = "FamilyBoard-\(UUID().uuidString)"
        var req = try makeRequest(method, path)
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data("--\(boundary)\r\n".utf8)
        body.append(Data("Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(filename)\"\r\n".utf8))
        body.append(Data("Content-Type: \(mimeType)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        req.httpBody = body
        return try await perform(req)
    }

    func makeRequest(_ method: String, _ path: String,
                     query: [URLQueryItem] = []) throws -> URLRequest {
        guard var base = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              base.scheme == "https" || base.scheme == "http",
              base.host != nil, base.user == nil, base.password == nil,
              base.query == nil, base.fragment == nil,
              let endpoint = URLComponents(string: path),
              endpoint.scheme == nil, endpoint.host == nil, endpoint.fragment == nil,
              path.hasPrefix("/"), !path.hasPrefix("//"),
              !endpoint.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw APIError.invalidURL
        }
        while base.percentEncodedPath.hasSuffix("/") { base.percentEncodedPath.removeLast() }
        base.percentEncodedPath += "/api" + endpoint.percentEncodedPath
        let items = (endpoint.queryItems ?? []) + query
        base.queryItems = items.isEmpty ? nil : items
        base.percentEncodedQuery = base.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = base.url else { throw APIError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        return req
    }

    private func perform(_ req: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: req)
        guard let response = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        let status = response.statusCode
        if status == 401 || status == 403 {
            if token != nil { await onUnauthorized?() }
            throw APIError.unauthorized
        }
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
