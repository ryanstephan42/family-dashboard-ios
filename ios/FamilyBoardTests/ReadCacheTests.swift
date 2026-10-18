import XCTest
@testable import FamilyBoard

@MainActor
final class ReadCacheTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private var network: URLSession!
    private var cache: ReadCache!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        suite = "ReadCacheTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set("https://family.example.com", forKey: "serverURL")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CacheURLProtocol.self]
        network = URLSession(configuration: configuration)
        cache = ReadCache(directory: directory)
    }

    override func tearDown() async throws {
        try cache.clear()
        defaults.removePersistentDomain(forName: suite)
        network.invalidateAndCancel()
        CacheURLProtocol.handler = nil
    }

    func testKeyScopesServerUserAndExactQueryWithoutTokenOrUnsafeFilename() throws {
        let client = APIClient(baseURL: URL(string: "https://family.example.com")!, token: "secret-one")
        let key = try ReadCache.key(client: client, userID: "../user", path: "/tasks?status=DONE")
        var refreshed = client
        refreshed.token = "secret-two"
        XCTAssertEqual(key, try ReadCache.key(client: refreshed, userID: "../user", path: "/tasks",
                                             query: [URLQueryItem(name: "status", value: "DONE")]))
        XCTAssertNotEqual(key, try ReadCache.key(client: client, userID: "other", path: "/tasks?status=DONE"))
        XCTAssertNotEqual(key, try ReadCache.key(client: client, userID: "../user", path: "/tasks"))
        XCTAssertNotEqual(key, try ReadCache.key(
            client: APIClient(baseURL: URL(string: "https://other.example.com")!),
            userID: "../user", path: "/tasks?status=DONE"))
        XCTAssertNotEqual(key, try ReadCache.key(
            client: APIClient(baseURL: URL(string: "https://family.example.com/other")!),
            userID: "../user", path: "/tasks?status=DONE"))
        XCTAssertEqual(key.count, 64)
        XCTAssertTrue(key.allSatisfy { $0.isHexDigit })
    }

    func testSnapshotSurvivesNewCacheInstanceAndPreservesTimestampAndEmptySuccess() throws {
        let date = Date(timeIntervalSince1970: 1234)
        try cache.save([String](), key: "entry", at: date)
        let restored = try XCTUnwrap(ReadCache(directory: directory).load([String].self, key: "entry"))
        XCTAssertEqual(restored.value, [])
        XCTAssertEqual(restored.status.savedAt, date)
        XCTAssertTrue(restored.status.isStale)
        try cache.clear()
        XCTAssertNil(try cache.load([String].self, key: "entry"))
    }

    func testOnlineFirstThenOfflineFallbackThenOnlineReplacement() async throws {
        let session = try makeSession()
        let first = try await session.read(path: "/grocery") { ["Milk"] }
        XCTAssertFalse(first.status.isStale)
        let fallback: CachedRead<[String]> = try await session.read(path: "/grocery") {
            throw URLError(.notConnectedToInternet)
        }
        XCTAssertEqual(fallback.value, ["Milk"])
        XCTAssertTrue(fallback.status.isStale)
        XCTAssertEqual(fallback.status.savedAt, first.status.savedAt)
        let refreshed = try await session.read(path: "/grocery") { ["Bread"] }
        XCTAssertEqual(refreshed.value, ["Bread"])
        XCTAssertFalse(refreshed.status.isStale)
        XCTAssertGreaterThanOrEqual(refreshed.status.savedAt, first.status.savedAt)
    }

    func testNoSnapshotDoesNotConvertFailureToEmptySuccess() async throws {
        let session = try makeSession()
        do {
            let _: CachedRead<[String]> = try await session.read(path: "/inventory") {
                throw URLError(.notConnectedToInternet)
            }
            XCTFail("Expected the network failure")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .notConnectedToInternet)
        }
    }

    func testFailuresThatMustNotUseSnapshots() async throws {
        let session = try makeSession()
        _ = try await session.read(path: "/tasks") { ["Private task"] }
        let errors: [Error] = [
            APIError.unauthorized, APIError.server(status: 403, message: nil),
            APIError.server(status: 500, message: "Rejected"), APIError.invalidResponse,
            URLError(.cancelled), URLError(.serverCertificateUntrusted),
            DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid data")),
            CancellationError()
        ]
        for error in errors {
            do {
                let _: CachedRead<[String]> = try await session.read(path: "/tasks") { throw error }
                XCTFail("Must not use a snapshot for \(error)")
            } catch {}
        }
    }

    func testCorruptSnapshotIsAnExplicitError() async throws {
        let session = try makeSession()
        let key = try ReadCache.key(client: XCTUnwrap(session.client), userID: "one", path: "/tasks")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("invalid json".utf8).write(to: directory.appendingPathComponent(key))
        do {
            let _: CachedRead<[String]> = try await session.read(path: "/tasks") {
                throw URLError(.timedOut)
            }
            XCTFail("Expected a visible decoding failure")
        } catch is DecodingError {}
    }

    func testRestoredAccountCannotReadAnotherUsersSnapshot() async throws {
        let first = try makeSession(userID: "one")
        _ = try await first.read(path: "/tasks") { ["Private to one"] }
        let second = try makeSession(userID: "two")
        do {
            let _: CachedRead<[String]> = try await second.read(path: "/tasks") {
                throw URLError(.notConnectedToInternet)
            }
            XCTFail("Another user's snapshot leaked")
        } catch is URLError {}
    }

    func testLogoutAndServerChangeRemoveSnapshots() async throws {
        let session = try makeSession()
        let key = try ReadCache.key(client: XCTUnwrap(session.client), userID: "one", path: "/tasks")
        _ = try await session.read(path: "/tasks") { ["Saved"] }
        session.logout()
        XCTAssertNil(try cache.load([String].self, key: key))
        let restored = try makeSession()
        _ = try await restored.read(path: "/tasks") { ["Saved again"] }
        CacheURLProtocol.handler = { _ in (200, Data(#"{"apiVersion":1}"#.utf8)) }
        try await restored.connect(to: "https://other.example.com")
        XCTAssertFalse(restored.isLoggedIn)
        XCTAssertNil(try cache.load([String].self, key: key))
    }

    func testLoginClearsOldSnapshots() async throws {
        let session = try makeSession()
        let key = try ReadCache.key(client: XCTUnwrap(session.client), userID: "one", path: "/tasks")
        _ = try await session.read(path: "/tasks") { ["Saved"] }
        CacheURLProtocol.handler = { _ in
            (200, Data(#"{"token":"new-token","user":{"id":"two","username":"two","name":"Two"}}"#.utf8))
        }
        try await session.login(username: "two", password: "test-password")
        XCTAssertEqual(session.user?.id, "two")
        XCTAssertNil(try cache.load([String].self, key: key))
    }

    func testAuthenticatedRejectionClearsCacheAndDoesNotFallback() async throws {
        for code in [401, 403] {
            let session = try makeSession()
            let client = try XCTUnwrap(session.client)
            let key = try ReadCache.key(client: client, userID: "one", path: "/tasks")
            _ = try await session.read(path: "/tasks") { ["Saved"] }
            CacheURLProtocol.handler = { _ in (code, Data()) }
            do {
                let _: CachedRead<[String]> = try await session.read(path: "/tasks") {
                    try await client.request("GET", "/tasks")
                }
                XCTFail("Unauthorized response must not show a snapshot")
            } catch is CancellationError {}
            XCTAssertFalse(session.isLoggedIn)
            XCTAssertNil(try cache.load([String].self, key: key))
        }
    }

    func testSuccessfulWritesInvalidateReadsButRejectedWritesDoNotSucceed() async throws {
        let session = try makeSession()
        let client = try XCTUnwrap(session.client)
        let key = try ReadCache.key(client: client, userID: "one", path: "/inventory")
        _ = try await session.read(path: "/inventory") { ["Saved"] }
        CacheURLProtocol.handler = { _ in (500, Data()) }
        do {
            _ = try await client.send("POST", "/inventory")
            XCTFail("Expected server failure")
        } catch APIError.server {}
        XCTAssertNotNil(try cache.load([String].self, key: key))
        CacheURLProtocol.handler = { _ in (200, Data()) }
        _ = try await client.send("POST", "/inventory")
        XCTAssertNil(try cache.load([String].self, key: key))
    }

    func testInflightReadsCannotRepopulateAfterLogoutOrMutation() async throws {
        for logout in [true, false] {
            let session = try makeSession()
            let client = try XCTUnwrap(session.client)
            let key = try ReadCache.key(client: client, userID: "one", path: "/tasks")
            CacheURLProtocol.handler = { _ in (200, Data()) }
            do {
                _ = try await session.read(path: "/tasks") {
                    if logout { session.logout() }
                    else { _ = try await client.send("PUT", "/tasks/one") }
                    return ["Late response"]
                }
                XCTFail("Expected obsolete read cancellation")
            } catch is CancellationError {}
            XCTAssertNil(try cache.load([String].self, key: key))
        }
    }

    func testOldClientCannotInvalidateNewSessionsCache() async throws {
        let session = try makeSession()
        let oldClient = try XCTUnwrap(session.client)
        session.logout()
        CacheURLProtocol.handler = { _ in
            (200, Data(#"{"token":"new-token","user":{"id":"two","username":"two","name":"Two"}}"#.utf8))
        }
        try await session.login(username: "two", password: "test-password")
        _ = try await session.read(path: "/tasks") { ["New account"] }
        CacheURLProtocol.handler = { _ in (200, Data()) }
        _ = try await oldClient.send("PUT", "/tasks/one")
        let key = try ReadCache.key(client: XCTUnwrap(session.client), userID: "two", path: "/tasks")
        XCTAssertNotNil(try cache.load([String].self, key: key))
    }

    func testNoIdentityCannotFetchOrReadSnapshots() async throws {
        let session = try makeSession()
        session.user = nil
        do {
            _ = try await session.read(path: "/tasks") {
                XCTFail("Must not fetch without authenticated identity")
                return [String]()
            }
            XCTFail("Expected unauthorized")
        } catch APIError.unauthorized {}
    }

    private func makeSession(userID: String = "one") throws -> Session {
        let credentials = CacheCredentials()
        let saved: [String: Any] = [
            "serverURL": "https://family.example.com", "token": "test-token",
            "user": ["id": userID, "username": userID, "name": userID]
        ]
        credentials.saved = String(decoding: try JSONSerialization.data(withJSONObject: saved), as: UTF8.self)
        return Session(defaults: defaults, credentialStore: credentials, networkSession: network, readCache: cache)
    }
}

private final class CacheCredentials: CredentialStore {
    var saved: String?
    func get(_ key: String) throws -> String? { key == "session" ? saved : nil }
    func set(_ value: String, for key: String) throws { if key == "session" { saved = value } }
    func delete(_ key: String) throws { if key == "session" { saved = nil } }
}

private final class CacheURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try XCTUnwrap(Self.handler)(request)
            let response = try XCTUnwrap(HTTPURLResponse(
                url: XCTUnwrap(request.url), statusCode: status, httpVersion: nil, headerFields: nil))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}
