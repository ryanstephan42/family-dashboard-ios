import Foundation

struct SharedCalendarConfiguration: Decodable {
    let nextcloudCalendarEmbedUrl: String?

    func calendarLinks() throws -> SharedCalendarLinks? {
        guard let value = nextcloudCalendarEmbedUrl,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return try SharedCalendarLinks(value)
    }
}

enum SharedCalendarError: LocalizedError {
    case invalidURL
    case unsafeNavigation

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "The server's calendar link is invalid. Ask the server administrator to configure a public HTTP or HTTPS Nextcloud calendar share link."
        case .unsafeNavigation:
            return "The calendar tried to open an unsupported link. Use Open in Nextcloud to continue outside the app."
        }
    }
}

struct SharedCalendarLinks: Equatable {
    let embedURL: URL
    let nextcloudURL: URL

    init(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains("\\"),
              trimmed.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
              let components = URLComponents(string: trimmed),
              let url = components.url,
              Self.isSafeWebURL(url) else {
            throw SharedCalendarError.invalidURL
        }
        embedURL = url
        var external = components
        // Match the web client's share link without changing query values or encoded path segments.
        if let range = external.percentEncodedPath.range(of: "/embed/") {
            external.percentEncodedPath.replaceSubrange(range, with: "/")
        }
        guard let externalURL = external.url else { throw SharedCalendarError.invalidURL }
        nextcloudURL = externalURL
    }

    static func isSafeWebURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              ["https", "http"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.port.map({ (1...65535).contains($0) }) ?? true else {
            return false
        }
        return true
    }
}

struct SharedCalendarService {
    let client: APIClient

    func load() async throws -> SharedCalendarLinks? {
        let configuration: SharedCalendarConfiguration = try await client.request("GET", "/config")
        return try configuration.calendarLinks()
    }
}
