import XCTest
@testable import FamilyBoard

final class GroceryAPITests: XCTestCase {
    private var session: URLSession!
    private var api: GroceryAPI!

    override func setUpWithError() throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GroceryStubURLProtocol.self]
        session = URLSession(configuration: configuration)
        let client = APIClient(
            baseURL: try XCTUnwrap(URL(string: "https://family.example.com")),
            token: "test-token",
            session: session
        )
        api = GroceryAPI(client: client)
    }

    override func tearDown() {
        session.invalidateAndCancel()
        session = nil
        api = nil
        GroceryStubURLProtocol.handler = nil
        super.tearDown()
    }

    func testFetchItemsDecodesOptionalFieldsAndDates() async throws {
        GroceryStubURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/grocery")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "******")
            return (200, """
            [{"id":"grocery-1","name":"Milk","quantity":"2 cartons","details":null,
              "category":"Dairy","completed":false,
              "createdAt":"2026-10-17T12:00:00.000Z","updatedAt":"2026-10-17T12:00:00Z"}]
            """)
        }

        let items = try await api.fetchItems()

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].id, "grocery-1")
        XCTAssertEqual(items[0].name, "Milk")
        XCTAssertEqual(items[0].quantity, "2 cartons")
        XCTAssertNil(items[0].details)
        XCTAssertEqual(items[0].category, "Dairy")
        XCTAssertFalse(items[0].completed)
        XCTAssertNotNil(items[0].createdAt)
        XCTAssertNotNil(items[0].updatedAt)
    }

    func testFetchPreferencesAndSuggestionsUseTheirRoutes() async throws {
        GroceryStubURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            switch request.url?.path {
            case "/api/grocery/preferences":
                return (200, #"[{"itemName":"milk","category":"Dairy"}]"#)
            case "/api/grocery/suggestions":
                return (200, #"[{"name":"Rice","category":"Grains","quantity":"2 bags","reason":"Running low"}]"#)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                return (500, #"{"error":"Unexpected request"}"#)
            }
        }

        let preferences = try await api.fetchPreferences()
        let suggestions = try await api.fetchSuggestions()

        XCTAssertEqual(preferences, [GroceryCategoryPreference(itemName: "milk", category: "Dairy")])
        XCTAssertEqual(suggestions, [
            GrocerySuggestion(name: "Rice", category: "Grains", quantity: "2 bags", reason: "Running low")
        ])
    }

    func testCreateItemsSendsBulkPayload() async throws {
        GroceryStubURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/grocery")
            let body = try XCTUnwrap(request.httpBody)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let items = try XCTUnwrap(json["items"] as? [[String: Any]])
            XCTAssertEqual(items.count, 2)
            XCTAssertEqual(items[0]["name"] as? String, "Milk")
            XCTAssertEqual(items[0]["category"] as? String, "Dairy")
            XCTAssertEqual(items[1]["name"] as? String, "Eggs")
            return (201, """
            [{"id":"grocery-1","name":"Milk","quantity":null,"details":null,"category":"Dairy",
              "completed":false},{"id":"grocery-2","name":"Eggs","quantity":null,"details":null,
              "category":"General","completed":false}]
            """)
        }

        try await api.createItems([
            GroceryItemInput(name: "Milk", quantity: nil, details: nil, category: "Dairy"),
            GroceryItemInput(name: "Eggs", quantity: nil, details: nil, category: "General")
        ])
    }

    func testUpdateSendsAllEditableFieldsAndCompletionState() async throws {
        GroceryStubURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(request.url?.path, "/api/grocery/grocery-1")
            let body = try XCTUnwrap(request.httpBody)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["name"] as? String, "Oat milk")
            XCTAssertEqual(json["quantity"] as? String, "1 carton")
            XCTAssertEqual(json["category"] as? String, "Dairy")
            XCTAssertEqual(json["completed"] as? Bool, true)
            XCTAssertEqual(json["details"] as? String, "Unsweetened")
            return (200, """
            {"id":"grocery-1","name":"Oat milk","quantity":"1 carton",
             "details":"Unsweetened","category":"Dairy","completed":true}
            """)
        }

        try await api.update(GroceryItem(
            id: "grocery-1",
            name: "Oat milk",
            quantity: "1 carton",
            details: "Unsweetened",
            category: "Dairy",
            completed: true,
            createdAt: nil,
            updatedAt: nil
        ))
    }

    func testPurchaseDeletesOnlyThroughServerPurchaseRoute() async throws {
        GroceryStubURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/grocery/grocery-1/purchase")
            return (201, #"{"id":"inventory-1","name":"Milk"}"#)
        }

        try await api.purchase(id: "grocery-1")
    }
}

private final class GroceryStubURLProtocol: URLProtocol {
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
