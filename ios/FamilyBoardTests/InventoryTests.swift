import XCTest
@testable import FamilyBoard

final class InventoryTests: XCTestCase {
    private var session: URLSession!
    private var service: InventoryService!

    override func setUpWithError() throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InventoryStubURLProtocol.self]
        session = URLSession(configuration: configuration)
        service = InventoryService(client: APIClient(
            baseURL: try XCTUnwrap(URL(string: "https://family.example.com")),
            token: "inventory-test", session: session
        ))
    }

    override func tearDown() {
        session.invalidateAndCancel()
        session = nil
        service = nil
        InventoryStubURLProtocol.handler = nil
        super.tearDown()
    }

    func testListDecodesFractionalQuantitiesNullableFieldsAndBothDateFormats() async throws {
        for date in ["2026-10-20T00:00:00.000Z", "2026-10-20T00:00:00Z"] {
            InventoryStubURLProtocol.handler = { request in
                XCTAssertEqual(request.url?.path, "/api/inventory")
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer inventory-test")
                return (200, "[\(Self.itemJSON(purchaseDate: date))]")
            }
            let items = try await service.items()
            let item = try XCTUnwrap(items.first)
            XCTAssertEqual(item.quantity, 1.5)
            XCTAssertEqual(item.purchaseDate.timeIntervalSince1970, 1_792_454_400)
            XCTAssertNil(item.unit)
            XCTAssertNil(item.expirationDate)
            XCTAssertNil(item.photoUrl)
            XCTAssertNil(item.barcode)
            XCTAssertTrue(item.isRunningLow)
        }
    }

    func testCreateUsesBulkEnvelopeAndISODateStrings() async throws {
        let draft = InventoryDraft()
        var filled = draft
        filled.name = " Rice "
        filled.unit = " bags "
        filled.purchaseDate = Date(timeIntervalSince1970: 1_792_454_400)
        InventoryStubURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/inventory")
            let json = try Self.body(request)
            XCTAssertNil(json["name"])
            let items = try XCTUnwrap(json["items"] as? [[String: Any]])
            XCTAssertEqual(items.count, 1)
            XCTAssertEqual(items[0]["name"] as? String, "Rice")
            XCTAssertEqual(items[0]["unit"] as? String, "bags")
            XCTAssertEqual(items[0]["purchaseDate"] as? String, "2026-10-20T00:00:00.000Z")
            XCTAssertTrue(items[0]["parLevel"] is NSNull)
            XCTAssertTrue(items[0]["expirationDate"] is NSNull)
            return (201, "[\(Self.itemJSON())]")
        }
        let saved = try await service.create(filled)
        XCTAssertEqual(saved.count, 1)
    }

    func testUpdateClearsNullableValuesAndPreservesFractionalQuantity() async throws {
        var draft = InventoryDraft()
        draft.name = "Rice"
        draft.quantity = "0.5"
        draft.trackExpiration = false
        draft.hasExpirationDate = true
        InventoryStubURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(request.url?.path, "/api/inventory/item-1")
            let body = try Self.body(request)
            XCTAssertEqual(body["quantity"] as? Double, 0.5)
            XCTAssertEqual(body["trackExpiration"] as? Bool, false)
            XCTAssertTrue(body["expirationDate"] is NSNull)
            XCTAssertTrue(body["parLevel"] is NSNull)
            return (200, Self.itemJSON())
        }
        _ = try await service.update(id: "item-1", draft: draft)
    }

    func testUpdateWritesChosenExpirationAndParLevel() throws {
        var draft = InventoryDraft()
        draft.name = "Milk"
        draft.hasExpirationDate = true
        draft.expirationDate = Date(timeIntervalSince1970: 1_792_454_400)
        draft.parLevel = "2.5"
        let json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(draft.payload())
        ) as? [String: Any])
        XCTAssertEqual(json["expirationDate"] as? String, "2026-10-20T00:00:00.000Z")
        XCTAssertEqual(json["parLevel"] as? Double, 2.5)
    }

    func testQuantityAndDeleteRequests() async throws {
        InventoryStubURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "PATCH")
            XCTAssertEqual(request.url?.path, "/api/inventory/item-1/quantity")
            XCTAssertEqual(try Self.body(request)["delta"] as? Double, -1)
            return (200, Self.itemJSON())
        }
        _ = try await service.adjust(id: "item-1", delta: -1)
        InventoryStubURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertEqual(request.url?.path, "/api/inventory/item-1")
            return (200, #"{"message":"Inventory item removed"}"#)
        }
        try await service.delete(id: "item-1")
    }

    func testUnitPreferencesAndLearnedOptions() async throws {
        InventoryStubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/inventory/unit-options")
            return (200, #"{"commonUnits":["each","bag"],"preferences":[{"id":"p1","itemName":"rice","unit":"bag"}]}"#)
        }
        let options = try await service.unitOptions()
        XCTAssertEqual(options.commonUnits, ["each", "bag"])
        XCTAssertEqual(options.preferredUnit(for: " Rice "), "bag")
        XCTAssertNil(options.preferredUnit(for: "Milk"))
    }

    func testValidationRejectsEmptyNegativeAndNonfiniteInput() throws {
        var draft = InventoryDraft()
        XCTAssertNotNil(draft.validationMessage)
        draft.name = "Rice"
        for quantity in ["", "-1", "nan", "inf", "1,5"] {
            draft.quantity = quantity
            XCTAssertThrowsError(try draft.payload(), quantity)
        }
        draft.quantity = "0"
        XCTAssertNil(draft.validationMessage)
        for parLevel in ["-1", "nan", "inf", "many"] {
            draft.parLevel = parLevel
            XCTAssertThrowsError(try draft.payload(), parLevel)
        }
        draft.parLevel = ""
        draft.location = " "
        XCTAssertThrowsError(try draft.payload())
    }

    func testInvalidAdjustmentDoesNotSendRequest() async {
        InventoryStubURLProtocol.handler = { _ in
            XCTFail("Invalid input must not reach server")
            return (200, Self.itemJSON())
        }
        for delta in [0, Double.nan, Double.infinity] {
            do {
                _ = try await service.adjust(id: "item-1", delta: delta)
                XCTFail("Expected validation error")
            } catch is InventoryValidationError {}
            catch { XCTFail("Unexpected error: \(error)") }
        }
    }

    func testFiltersSearchAllWebappFieldsAndHonorParBoundary() async throws {
        InventoryStubURLProtocol.handler = { _ in (200, "[\(Self.itemJSON())]") }
        let items = try await service.items()
        let item = try XCTUnwrap(items.first)
        var filter = InventoryFilter()
        for query in ["rice", "GENERAL", "pantry", "sealed"] {
            filter.search = query
            XCTAssertTrue(filter.matches(item))
        }
        filter.search = "milk"
        XCTAssertFalse(filter.matches(item))
        filter.search = ""
        filter.runningLow = true
        XCTAssertTrue(filter.matches(item))
        filter.location = "Fridge"
        XCTAssertFalse(filter.matches(item))
        filter.location = ""
        filter.category = "Dairy"
        XCTAssertFalse(filter.matches(item))
    }

    func testExpirationFiltersHaveInclusiveFourteenDayBoundary() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = Date(timeIntervalSince1970: 1_792_454_400)
        for (offset, soon, expired) in [(-1, false, true), (0, true, false), (14, true, false), (15, false, false)] {
            let date = try XCTUnwrap(calendar.date(byAdding: .day, value: offset, to: now))
            let string = ISO8601DateFormatter().string(from: date)
            let json = Self.itemJSON().replacingOccurrences(of: #""expirationDate":null"#, with: "\"expirationDate\":\"\(string)\"")
            InventoryStubURLProtocol.handler = { _ in (200, "[\(json)]") }
            let items = try await service.items()
            let item = try XCTUnwrap(items.first)
            var filter = InventoryFilter()
            filter.expiration = .soon
            XCTAssertEqual(filter.matches(item, now: now, calendar: calendar), soon)
            filter.expiration = .expired
            XCTAssertEqual(filter.matches(item, now: now, calendar: calendar), expired)
        }
    }

    func testUnauthorizedAndServerErrorsPropagate() async throws {
        for status in [401, 403, 422] {
            InventoryStubURLProtocol.handler = { _ in (status, #"{"error":"Inventory unavailable"}"#) }
            do {
                _ = try await service.items()
                XCTFail("Expected error")
            } catch APIError.unauthorized {
                XCTAssertTrue([401, 403].contains(status))
            } catch APIError.server(let code, let message) {
                XCTAssertEqual(code, 422)
                XCTAssertEqual(message, "Inventory unavailable")
            }
        }
    }

    private static func itemJSON(purchaseDate: String = "2026-10-20T00:00:00.000Z") -> String {
        """
        {"id":"item-1","name":"Rice","quantity":1.5,"unit":null,"category":"General",
         "location":"Pantry","purchaseDate":"\(purchaseDate)","trackExpiration":true,
         "expirationDate":null,"notes":"sealed","parLevel":1.5,"lowStock":false,
         "photoUrl":null,"barcode":null}
        """
    }

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

private final class InventoryStubURLProtocol: URLProtocol {
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
