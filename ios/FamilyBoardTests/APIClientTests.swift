import XCTest
@testable import FamilyBoard

final class APIClientTests: XCTestCase {
    func testNormalizeAddsHTTPS() {
        XCTAssertEqual(APIClient.normalize("family.example.com")?.absoluteString,
                       "https://family.example.com")
    }

    func testNormalizeTrimsSlashesAndWhitespace() {
        XCTAssertEqual(APIClient.normalize("  http://host:3000//  ")?.absoluteString,
                       "http://host:3000")
    }

    func testNormalizeRejectsEmpty() {
        XCTAssertNil(APIClient.normalize("   "))
    }

    func testNormalizeRejectsOtherSchemes() {
        XCTAssertNil(APIClient.normalize("ftp://host"))
    }

    func testErrorDescriptions() {
        XCTAssertEqual(APIError.server(status: 500, message: nil).errorDescription,
                       "Server error (500).")
        XCTAssertEqual(APIError.server(status: 400, message: "Bad").errorDescription, "Bad")
    }

    func testDecodeLoginResponse() throws {
        let json = #"{"token":"t","user":{"id":"1","username":"u","name":"N"}}"#
        let res = try JSONDecoder().decode(LoginResponse.self, from: Data(json.utf8))
        XCTAssertEqual(res.user.username, "u")
    }
}
