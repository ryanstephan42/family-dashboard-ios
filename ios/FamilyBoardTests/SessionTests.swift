import XCTest
@testable import FamilyBoard

@MainActor
final class SessionTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private var network: URLSession!
    private var store: TestCredentialStore!

    override func setUp() async throws {
        suite = "FoundationTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set("https://family.example.com", forKey: "serverURL")
        store = TestCredentialStore()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FoundationURLProtocol.self]
        network = URLSession(configuration: configuration)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        network.invalidateAndCancel()
        FoundationURLProtocol.handler = nil
    }

    func testAuthenticatedRejectionClearsSessionAndSavedToken() async throws {
        for status in [401, 403] {
            store.value = "test-token"
            let session = makeSession()
            FoundationURLProtocol.handler = { _ in (status, Data()) }
            do {
                _ = try await XCTUnwrap(session.client).send("GET", "/users")
                XCTFail("Expected unauthorized")
            } catch APIError.unauthorized {}
            XCTAssertFalse(session.isLoggedIn)
            XCTAssertNil(store.value)
            XCTAssertNil(session.user)
            XCTAssertNotNil(session.errorMessage)
        }
    }

    func testOldClientCannotSignOutNewLogin() async throws {
        store.value = "old-token"
        let session = makeSession()
        let oldClient = try XCTUnwrap(session.client)
        session.logout()
        FoundationURLProtocol.handler = { _ in
            (200, Data(#"{"token":"new-token","user":{"id":"1","username":"u","name":"Name"}}"#.utf8))
        }
        try await session.login(username: "u", password: "test-password")
        FoundationURLProtocol.handler = { _ in (401, Data()) }
        do {
            _ = try await oldClient.send("GET", "/users")
            XCTFail("Expected unauthorized")
        } catch APIError.unauthorized {}
        XCTAssertEqual(session.token, "new-token")
        XCTAssertEqual(store.value, "new-token")
    }

    func testFailedCredentialSaveDoesNotLogIn() async throws {
        let session = makeSession()
        store.failure = TestCredentialStore.Failure.unavailable
        FoundationURLProtocol.handler = { _ in
            (200, Data(#"{"token":"test-token","user":{"id":"1","username":"u","name":"Name"}}"#.utf8))
        }
        do {
            try await session.login(username: "u", password: "test-password")
            XCTFail("Expected credential failure")
        } catch TestCredentialStore.Failure.unavailable {}
        XCTAssertFalse(session.isLoggedIn)
    }

    func testCredentialReadAndDeleteFailuresAreVisible() {
        store.failure = TestCredentialStore.Failure.unavailable
        let session = makeSession()
        XCTAssertNotNil(session.errorMessage)
        XCTAssertFalse(session.logout())
        session.changeServer()
        XCTAssertNotNil(session.serverURL)
        XCTAssertNotNil(defaults.string(forKey: "serverURL"))
        XCTAssertNotNil(session.errorMessage)
    }

    func testRestoresIdentityScopedToServer() {
        store.value = "test-token"
        let session = makeSession()
        XCTAssertEqual(session.token, "test-token")
        XCTAssertEqual(session.user?.id, "1")
        XCTAssertEqual(session.user?.username, "u")
        session.changeServer()
        XCTAssertNil(session.user)
        XCTAssertNil(store.value)
        XCTAssertNil(session.serverURL)
    }

    func testRejectsSavedIdentityForDifferentServer() {
        store.value = "test-token"
        defaults.set("https://other.example.com", forKey: "serverURL")
        let session = makeSession()
        XCTAssertFalse(session.isLoggedIn)
        XCTAssertNil(session.user)
        XCTAssertNil(store.value)
        XCTAssertNotNil(session.errorMessage)
    }

    func testLegacyTokenRequiresExplicitSignIn() {
        store.values["token"] = "legacy-token"
        let session = makeSession()
        XCTAssertFalse(session.isLoggedIn)
        XCTAssertNil(session.user)
        XCTAssertNil(store.values["token"])
        XCTAssertNotNil(session.errorMessage)
    }

    func testLoginRejectionDoesNotTriggerGlobalExpiryNotice() async throws {
        let session = makeSession()
        FoundationURLProtocol.handler = { _ in (401, Data()) }
        do {
            try await session.login(username: "u", password: "wrong-password")
            XCTFail("Expected unauthorized")
        } catch APIError.unauthorized {}
        XCTAssertNil(session.errorMessage)
    }

    func testMultipartUploadUsesSharedTransportAndDecodesResponse() async throws {
        store.value = "test-token"
        let session = makeSession()
        FoundationURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/inventory/1/photo")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            let contentType = try XCTUnwrap(request.value(forHTTPHeaderField: "Content-Type"))
            XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary=FamilyBoard-"))
            let boundary = String(try XCTUnwrap(contentType.components(separatedBy: "boundary=").last))
            let body: Data
            if let data = request.httpBody {
                body = data
            } else {
                let stream = try XCTUnwrap(request.httpBodyStream)
                stream.open()
                defer { stream.close() }
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 1024)
                while true {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count < 0 { throw try XCTUnwrap(stream.streamError) }
                    if count == 0 { break }
                    data.append(contentsOf: buffer.prefix(count))
                }
                body = data
            }
            let expected = "--\(boundary)\r\n"
                + "Content-Disposition: form-data; name=\"photo\"; filename=\"test.jpg\"\r\n"
                + "Content-Type: image/jpeg\r\n\r\n"
                + "test-image\r\n--\(boundary)--\r\n"
            XCTAssertEqual(body, Data(expected.utf8))
            return (200, Data(#"{"photoUrl":"/uploads/test.jpg"}"#.utf8))
        }
        let result: [String: String] = try await XCTUnwrap(session.client).upload(
            "POST", "/inventory/1/photo", fieldName: "photo", filename: "test.jpg",
            mimeType: "image/jpeg", data: Data("test-image".utf8))
        XCTAssertEqual(result["photoUrl"], "/uploads/test.jpg")
    }

    private func makeSession() -> Session {
        Session(defaults: defaults, credentialStore: store, networkSession: network)
    }
}

private final class TestCredentialStore: CredentialStore {
    enum Failure: Error { case unavailable }
    var values: [String: String] = [:]
    var value: String? {
        get {
            guard let saved = values["session"],
                  let json = try? JSONSerialization.jsonObject(with: Data(saved.utf8)) as? [String: Any]
            else { return nil }
            return json["token"] as? String
        }
        set {
            guard let newValue else { values["session"] = nil; return }
            let json: [String: Any] = [
                "serverURL": "https://family.example.com", "token": newValue,
                "user": ["id": "1", "username": "u", "name": "Name"]
            ]
            values["session"] = String(decoding: try! JSONSerialization.data(withJSONObject: json), as: UTF8.self)
        }
    }
    var failure: Failure?

    func get(_ key: String) throws -> String? {
        if let failure { throw failure }
        return values[key]
    }

    func set(_ value: String, for key: String) throws {
        if let failure { throw failure }
        values[key] = value
    }

    func delete(_ key: String) throws {
        if let failure { throw failure }
        values[key] = nil
    }
}

private final class FoundationURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let (status, body) = try XCTUnwrap(Self.handler)(request)
            let response = try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url),
                                                        statusCode: status, httpVersion: nil,
                                                        headerFields: nil))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
