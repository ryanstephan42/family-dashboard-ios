import XCTest
@testable import FamilyBoard

final class APIClientRequestTests: XCTestCase {
    private var session: URLSession!
    private var client: APIClient!

    override func setUpWithError() throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: configuration)
        client = APIClient(
            baseURL: try XCTUnwrap(URL(string: "https://family.example.com")),
            token: "test-token",
            session: session
        )
    }

    override func tearDown() {
        session.invalidateAndCancel()
        session = nil
        client = nil
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    func testRequestIncludesMethodAPIPathAndBearerToken() async throws {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.absoluteString, "https://family.example.com/api/users")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            return (200, #"[{"id":"1","username":"user","name":"Name"}]"#)
        }
        let users: [User] = try await client.request("GET", "/users")
        XCTAssertEqual(users.first?.name, "Name")
    }

    func testLoginSendsJSONWithoutAuthorizationWhenLoggedOut() async throws {
        client.token = nil
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            let data: Data
            if let body = request.httpBody {
                data = body
            } else {
                let stream = try XCTUnwrap(request.httpBodyStream)
                stream.open()
                defer { stream.close() }
                var body = Data()
                var buffer = [UInt8](repeating: 0, count: 1024)
                while true {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count < 0 { throw try XCTUnwrap(stream.streamError) }
                    if count == 0 { break }
                    body.append(contentsOf: buffer.prefix(count))
                }
                data = body
            }
            let body = try JSONDecoder().decode([String: String].self, from: data)
            XCTAssertEqual(body, ["username": "user", "password": "test-password"])
            return (200, #"{"token":"test-token","user":{"id":"1","username":"user","name":"Name"}}"#)
        }
        let response: LoginResponse = try await client.request(
            "POST", "/users/login", body: ["username": "user", "password": "test-password"]
        )
        XCTAssertEqual(response.token, "test-token")
    }

    func testUnauthorizedResponses() async throws {
        for status in [401, 403] {
            StubURLProtocol.handler = { _ in (status, #"{"error":"Not authorized"}"#) }
            do {
                _ = try await client.send("GET", "/tasks")
                XCTFail("Expected unauthorized for HTTP \(status)")
            } catch APIError.unauthorized {
                // Both missing and invalid tokens require signing in again.
            }
        }
    }

    func testServerErrorPreservesMessage() async throws {
        StubURLProtocol.handler = { _ in (422, #"{"error":"Title is required"}"#) }
        do {
            _ = try await client.send("POST", "/tasks")
            XCTFail("Expected server error")
        } catch APIError.server(let status, let message) {
            XCTAssertEqual(status, 422)
            XCTAssertEqual(message, "Title is required")
        }
    }

    func testDecodeTaskDatesAndNestedModels() async throws {
        for date in ["2026-10-20T00:00:00.000Z", "2026-10-20T00:00:00Z"] {
            StubURLProtocol.handler = { _ in (200, Self.tasksJSON(dueDate: "\"\(date)\"")) }
            let tasks: [FamilyTask] = try await client.request("GET", "/tasks")
            let task = try XCTUnwrap(tasks.first)
            XCTAssertEqual(task.id, "task-1")
            XCTAssertEqual(task.title, "Dishes")
            XCTAssertEqual(task.dueDate?.timeIntervalSince1970, 1_792_454_400)
            XCTAssertNil(task.description)
            XCTAssertNil(task.assignee)
            XCTAssertEqual(task.creator?.name, "Name")
            XCTAssertEqual(task.steps.first?.content, "Load")
            XCTAssertEqual(task.steps.first?.completed, false)
            XCTAssertFalse(task.isRepeating)
        }
    }

    func testDecodeTaskWithNullDate() async throws {
        StubURLProtocol.handler = { _ in (200, Self.tasksJSON(dueDate: "null")) }
        let tasks: [FamilyTask] = try await client.request("GET", "/tasks")
        XCTAssertEqual(tasks.count, 1)
        XCTAssertNil(tasks.first?.dueDate)
    }

    func testInvalidDateFailsDecoding() async throws {
        StubURLProtocol.handler = { _ in (200, Self.tasksJSON(dueDate: #""not-a-date""#)) }
        do {
            let _: [FamilyTask] = try await client.request("GET", "/tasks")
            XCTFail("Expected invalid date to fail decoding")
        } catch DecodingError.dataCorrupted(let context) {
            XCTAssertEqual(context.codingPath.last?.stringValue, "dueDate")
        }
    }

    func testCompatibilityAcceptsSupportedAndLegacyServers() async throws {
        for config in [#"{"apiVersion":1,"minClientApiVersion":1}"#, "{}"] {
            StubURLProtocol.handler = { request in
                XCTAssertEqual(request.url?.path, "/api/config")
                return (200, config)
            }
            try await client.checkCompatibility()
        }
    }

    func testCompatibilityRejectsNewerMinimumVersion() async throws {
        StubURLProtocol.handler = { _ in
            (200, #"{"apiVersion":2,"minClientApiVersion":2}"#)
        }
        do {
            try await client.checkCompatibility()
            XCTFail("Expected incompatible server error")
        } catch APIError.incompatible {
            // The server requires a newer app.
        }
    }

    private static func tasksJSON(dueDate: String) -> String {
        """
        [{"id":"task-1","title":"Dishes","description":null,"status":"TODO",
          "type":"FAMILY","priority":"MEDIUM","dueDate":\(dueDate),
          "isRepeating":false,"repeatFrequency":null,
          "steps":[{"id":"step-1","content":"Load","completed":false,"taskId":"task-1"}],
          "creator":{"id":"user-1","name":"Name"},"assignee":null}]
        """
    }
}

private final class StubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, String))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let handler = try XCTUnwrap(Self.handler)
            let (status, body) = try handler(request)
            let response = try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            ))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
