import XCTest
@testable import FamilyBoard

final class FoundationTests: XCTestCase {
    func testEncodedComponentsAndQueriesStayInsideAPI() throws {
        let client = APIClient(baseURL: try XCTUnwrap(APIClient.normalize("family.example.com/board/")))
        let path = APIClient.path("inventory", "a/b ?#%+", "photo")
        let request = try client.makeRequest("GET", path, query: [
            URLQueryItem(name: "search", value: "bread & milk+#"),
            URLQueryItem(name: "status", value: "DONE")
        ])
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url),
                                                    resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.percentEncodedPath, "/board/api/inventory/a%2Fb%20%3F%23%25%2B/photo")
        XCTAssertEqual(components.queryItems?.first?.value, "bread & milk+#")
        XCTAssertEqual(components.queryItems?.last?.value, "DONE")
        XCTAssertTrue(components.percentEncodedQuery?.contains("%2B") == true)
    }

    func testLegacyInlineQueryRemainsSupported() throws {
        let client = APIClient(baseURL: try XCTUnwrap(APIClient.normalize("family.example.com")))
        let request = try client.makeRequest("GET", "/tasks?status=DONE")
        XCTAssertEqual(request.url?.absoluteString, "https://family.example.com/api/tasks?status=DONE")
    }

    func testRejectsCredentialsQueriesAndFragmentsInServerAddress() {
        for address in ["https://user:password@family.example.com",
                        "https://family.example.com?token=value",
                        "https://family.example.com#fragment"] {
            XCTAssertNil(APIClient.normalize(address))
        }
    }

    func testRejectsEndpointEscapes() throws {
        let client = APIClient(baseURL: try XCTUnwrap(APIClient.normalize("family.example.com")))
        for path in ["https://other.example.com/users", "//other.example.com/users",
                     "/../users", "/%2E%2E/users", "/tasks#fragment", "tasks"] {
            XCTAssertThrowsError(try client.makeRequest("GET", path))
        }
    }

    func testUploadRejectsHeaderInjectionBeforeSending() async throws {
        let client = APIClient(baseURL: try XCTUnwrap(APIClient.normalize("family.example.com")))
        do {
            _ = try await client.sendUpload("POST", "/inventory/1/photo", fieldName: "photo",
                                            filename: "photo\r\nInjected: true", mimeType: "image/jpeg",
                                            data: Data())
            XCTFail("Expected upload rejection")
        } catch APIError.invalidUpload {}
    }
}
