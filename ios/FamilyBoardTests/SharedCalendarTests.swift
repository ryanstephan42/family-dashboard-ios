import XCTest
@testable import FamilyBoard

final class SharedCalendarTests: XCTestCase {
    func testConfigurationDecodesConfiguredAndLegacyServers() throws {
        let configuration = try decode(#"{"apiVersion":1,"nextcloudCalendarEmbedUrl":"https://family.example.com/calendar/embed/share"}"#)
        XCTAssertEqual(try configuration.calendarLinks()?.embedURL.absoluteString,
                       "https://family.example.com/calendar/embed/share")
        for json in ["{}", #"{"nextcloudCalendarEmbedUrl":null}"#,
                     #"{"nextcloudCalendarEmbedUrl":""}"#,
                     #"{"nextcloudCalendarEmbedUrl":" \n "}"#] {
            XCTAssertNil(try decode(json).calendarLinks())
        }
    }

    func testMalformedConfigurationDoesNotBecomeAnEmptyCalendar() {
        XCTAssertThrowsError(try decode(#"{"nextcloudCalendarEmbedUrl":42}"#))
        XCTAssertThrowsError(try decode(#"{"nextcloudCalendarEmbedUrl":"javascript:alert(1)"}"#).calendarLinks())
    }

    func testShareLinkRemovesOnlyFirstLiteralEmbedPathSegment() throws {
        let links = try SharedCalendarLinks(
            "https://family.example.com/nextcloud/apps/calendar/embed/share?return=/embed/page#month"
        )
        XCTAssertEqual(links.nextcloudURL.absoluteString,
                       "https://family.example.com/nextcloud/apps/calendar/share?return=/embed/page#month")
        let unchanged = try SharedCalendarLinks("https://family.example.com/calendar/share?return=/embed/page")
        XCTAssertEqual(unchanged.embedURL, unchanged.nextcloudURL)
        let encoded = try SharedCalendarLinks("https://family.example.com/calendar/%65mbed/share")
        XCTAssertEqual(encoded.embedURL, encoded.nextcloudURL)
    }

    func testAcceptsAbsoluteHTTPAndHTTPSWithOuterWhitespace() throws {
        for scheme in ["http", "https", "HTTPS"] {
            let links = try SharedCalendarLinks(" \n\(scheme)://family.example.com:8443/calendar/embed/share\n ")
            XCTAssertEqual(links.embedURL.host, "family.example.com")
            XCTAssertEqual(links.embedURL.port, 8443)
            XCTAssertEqual(links.nextcloudURL.path, "/calendar/share")
        }
    }

    func testRejectsUnsafeOrMalformedConfiguredURLs() {
        for input in [
            "", "/calendar/embed/share", "//family.example.com/calendar", "family.example.com",
            "javascript:alert(1)", "data:text/html,hello", "file:///tmp/calendar",
            "ftp://family.example.com/calendar", "https:///calendar", "https://",
            "https://user:password@family.example.com/calendar",
            "https://user@family.example.com/calendar", "https://family.example.com/a b",
            "https://family.example.com/\ncalendar", "https://family.example.com\\@elsewhere.example",
            "https://family.example.com:0/calendar", "https://family.example.com:65536/calendar"
        ] {
            XCTAssertThrowsError(try SharedCalendarLinks(input), input)
        }
    }

    func testWebNavigationRejectsNonWebSchemesAndCredentials() throws {
        for input in ["javascript:alert(1)", "about:blank", "file:///tmp/calendar",
                      "mailto:user@example.com", "https://user@family.example.com"] {
            XCTAssertFalse(SharedCalendarLinks.isSafeWebURL(try XCTUnwrap(URL(string: input))), input)
        }
        XCTAssertTrue(SharedCalendarLinks.isSafeWebURL(
            try XCTUnwrap(URL(string: "https://family.example.com/login"))
        ))
    }

    func testServiceRequestsConfig() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CalendarURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let service = SharedCalendarService(client: APIClient(
            baseURL: try XCTUnwrap(URL(string: "https://family.example.com")),
            session: session
        ))
        let links = try await service.load()
        XCTAssertEqual(links?.nextcloudURL.path, "/calendar/share")
    }

    func testServicePreservesServerAndAuthorizationErrors() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CalendarURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let url = try XCTUnwrap(URL(string: "https://family.example.com"))
        for token in ["expired-token", "error-token"] {
            let service = SharedCalendarService(client: APIClient(
                baseURL: url, token: token, session: session
            ))
            do {
                _ = try await service.load()
                XCTFail("Expected config request to fail")
            } catch APIError.unauthorized {
                XCTAssertEqual(token, "expired-token")
            } catch APIError.server(let status, let message) {
                XCTAssertEqual(token, "error-token")
                XCTAssertEqual(status, 503)
                XCTAssertEqual(message, "Calendar configuration is unavailable")
            }
        }
    }

    private func decode(_ json: String) throws -> SharedCalendarConfiguration {
        try JSONDecoder().decode(SharedCalendarConfiguration.self, from: Data(json.utf8))
    }
}

private final class CalendarURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let authorization = request.value(forHTTPHeaderField: "Authorization")
        let status: Int
        let body: String
        switch authorization {
        case "Bearer expired-token":
            status = 403
            body = #"{"error":"Not authorized"}"#
        case "Bearer error-token":
            status = 503
            body = #"{"error":"Calendar configuration is unavailable"}"#
        default:
            status = 200
            body = #"{"nextcloudCalendarEmbedUrl":"https://family.example.com/calendar/embed/share"}"#
        }
        guard request.httpMethod == "GET", request.url?.path == "/api/config",
              let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                                             headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
