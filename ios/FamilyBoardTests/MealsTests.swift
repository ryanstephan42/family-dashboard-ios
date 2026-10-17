import XCTest
@testable import FamilyBoard

final class MealsTests: XCTestCase {
    private var session: URLSession!
    private var service: MealsService!

    override func setUpWithError() throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MealsStubURLProtocol.self]
        session = URLSession(configuration: configuration)
        service = MealsService(client: APIClient(
            baseURL: try XCTUnwrap(URL(string: "https://family.example.com")),
            token: "meals-test", session: session
        ))
    }

    override func tearDown() {
        session.invalidateAndCancel()
        session = nil
        service = nil
        MealsStubURLProtocol.handler = nil
        super.tearDown()
    }

    func testConfiguredOfflineAndOnlineStatuses() async throws {
        for (configured, online) in [(false, false), (true, false), (true, true)] {
            MealsStubURLProtocol.handler = { request in
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(request.url?.path, "/api/meals/status")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer meals-test")
                return (200, """
                {"configured":\(configured),"online":\(online),"error":"Optional integration unavailable"}
                """)
            }
            let status = try await service.status()
            XCTAssertEqual(status.configured, configured)
            XCTAssertEqual(status.online, online)
            XCTAssertEqual(status.error, "Optional integration unavailable")
        }
    }

    func testRankedListNullMeansUnknownNotReadyAndSearchIgnoresCase() async throws {
        MealsStubURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/meals/what-can-i-make")
            return (200, """
            [
              {"slug":"unknown","name":"Apple pie","image":null,"missingCount":null,"totalIngredients":0},
              {"slug":"two","name":"Chili","image":null,"missingCount":2,"totalIngredients":5},
              {"slug":"ready","name":"Soup","image":null,"missingCount":0,"totalIngredients":2},
              {"slug":"one","name":"Bean soup","image":null,"missingCount":1,"totalIngredients":3}
            ]
            """)
        }
        let meals = try await service.meals()
        XCTAssertNil(meals[0].missingCount)
        XCTAssertEqual(meals[0].availability, "Ingredients not checked")
        XCTAssertEqual(MealSummary.filtered(meals, search: "").map(\.slug), ["ready", "one", "two", "unknown"])
        XCTAssertEqual(MealSummary.filtered(meals, search: "SOUP").map(\.slug), ["ready", "one"])
        XCTAssertTrue(MealSummary.filtered(meals, search: "pasta").isEmpty)
        XCTAssertEqual(meals[2].availability, "Ready to cook")
        XCTAssertEqual(meals[1].availability, "2 missing")
    }

    func testDetailEncodesSlugAndDecodesMatchesWithoutInventingQuantities() async throws {
        MealsStubURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(
                URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.percentEncodedPath,
                "/api/meals/recipes/soup%2F100%25%3F%23/match"
            )
            return (200, Self.detailJSON)
        }
        let detail = try await service.detail(slug: "soup/100%?#")
        XCTAssertEqual(detail.recipe.slug, "soup")
        XCTAssertNil(detail.recipe.image)
        XCTAssertEqual(detail.recipe.externalURL?.host, "family.example.com")
        XCTAssertEqual(detail.missingCount, 1)
        XCTAssertFalse(detail.canMake)
        XCTAssertEqual(detail.matches[0].matchedItem?.quantity, 0.5)
        XCTAssertNil(detail.matches[0].matchedItem?.unit)
        XCTAssertTrue(detail.matches[0].isManualLink)
        XCTAssertEqual(detail.matches[0].confidence, 1)
        XCTAssertNil(detail.matches[1].matchedItem)
        XCTAssertFalse(detail.matches[1].haveIt)
        XCTAssertEqual(detail.matches[1].originalText, "")
    }

    func testLinkUsesExactServerFieldNames() async throws {
        MealsStubURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(
                URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.percentEncodedPath,
                "/api/meals/recipes/a%2Fb/link"
            )
            let body = try Self.body(request)
            XCTAssertEqual(body.count, 2)
            XCTAssertEqual(body["ingredientName"] as? String, "Salt / 100%")
            XCTAssertEqual(body["inventoryItemName"] as? String, "Sea salt")
            return (201, #"{"id":"link-1"}"#)
        }
        try await service.link(slug: "a/b", ingredient: "Salt / 100%", inventoryItemName: "Sea salt")
    }

    func testUnlinkSurvivesExpressAndExplicitServerDecoding() async throws {
        let ingredient = "Salt / 100% + lemon?#"
        MealsStubURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "DELETE")
            let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
            XCTAssertNil(components.query)
            XCTAssertNil(components.fragment)
            let path = components.percentEncodedPath
            XCTAssertTrue(path.hasPrefix("/api/meals/recipes/a%2Fb/link/"))
            let encodedIngredient = try XCTUnwrap(path.split(separator: "/").last).description
            let expressDecoded = try XCTUnwrap(encodedIngredient.removingPercentEncoding)
            XCTAssertEqual(expressDecoded.removingPercentEncoding, ingredient)
            return (200, #"{"message":"Link removed"}"#)
        }
        try await service.unlink(slug: "a/b", ingredient: ingredient)
    }

    func testExternalRecipeLinksOnlyAllowWebURLs() throws {
        for (url, allowed) in [
            ("https://family.example.com/g/home/r/soup", true),
            ("http://family.example.com/g/home/r/soup", true),
            ("file:///etc/passwd", false),
            ("javascript:alert(1)", false),
            ("https://user:password@family.example.com/", false),
            ("/g/home/r/soup", false)
        ] {
            let data = try JSONSerialization.data(withJSONObject: ["slug": "soup", "name": "Soup", "url": url])
            let recipe = try JSONDecoder().decode(MealRecipe.self, from: data)
            XCTAssertEqual(recipe.externalURL != nil, allowed, url)
        }
        let recipe = try JSONDecoder().decode(MealRecipe.self, from: Data(#"{"slug":"soup","name":"Soup","url":null}"#.utf8))
        XCTAssertNil(recipe.externalURL)
    }

    func testStatusFailureDoesNotMasqueradeAsUnconfigured() async throws {
        MealsStubURLProtocol.handler = { _ in (500, #"{"error":"Status check failed"}"#) }
        do {
            _ = try await service.status()
            XCTFail("Expected server error")
        } catch APIError.server(let status, let message) {
            XCTAssertEqual(status, 500)
            XCTAssertEqual(message, "Status check failed")
        }
    }

    func testOptionalIntegrationErrorsAndUnauthorizedPropagate() async throws {
        for status in [401, 403, 502, 503] {
            MealsStubURLProtocol.handler = { _ in (status, #"{"error":"Mealie unavailable"}"#) }
            do {
                _ = try await service.meals()
                XCTFail("Expected error")
            } catch APIError.unauthorized {
                XCTAssertTrue([401, 403].contains(status))
            } catch APIError.server(let code, let message) {
                XCTAssertEqual(code, status)
                XCTAssertEqual(message, "Mealie unavailable")
            }
        }
    }

    private static let detailJSON = """
    {"recipe":{"slug":"soup","name":"Soup","image":null,"url":"https://family.example.com/g/home/r/soup"},
     "matches":[
       {"ingredient":"Salt","originalText":"1 tsp salt","haveIt":true,
        "matchedItem":{"id":"salt","name":"Sea salt","quantity":0.5,"unit":null},"confidence":1,"isManualLink":true},
       {"ingredient":"Beans","originalText":"","haveIt":false,"matchedItem":null,"confidence":0,"isManualLink":false}
     ],"missingCount":1,"canMake":false}
    """

    private static func body(_ request: URLRequest) throws -> [String: Any] {
        let data: Data
        if let body = request.httpBody { data = body }
        else {
            let stream = try XCTUnwrap(request.httpBodyStream)
            stream.open()
            defer { stream.close() }
            var result = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count < 0 { throw try XCTUnwrap(stream.streamError) }
                if count == 0 { break }
                result.append(contentsOf: buffer.prefix(count))
            }
            data = result
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private final class MealsStubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, String))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, body) = try XCTUnwrap(Self.handler)(request)
            let response = try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap(request.url), statusCode: status,
                httpVersion: nil, headerFields: ["Content-Type": "application/json"]
            ))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
