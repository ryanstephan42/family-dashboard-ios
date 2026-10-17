import XCTest
import UIKit
@testable import FamilyBoard

final class ReceiptTests: XCTestCase {
    private var session: URLSession!
    private var client: APIClient!

    override func setUpWithError() throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReceiptURLProtocol.self]
        session = URLSession(configuration: configuration)
        client = APIClient(baseURL: try XCTUnwrap(URL(string: "https://family.example.com")),
                           token: "test-token", session: session)
    }

    override func tearDown() {
        session.invalidateAndCancel()
        ReceiptURLProtocol.handler = nil
        super.tearDown()
    }

    func testDecodeParserOptionalFieldsAndReviewDefaults() throws {
        let result = try JSONDecoder().decode(ReceiptScanResult.self, from: Data("""
        {"method":"local","items":[
          {"name":"Milk","quantity":2.5,"price":3.49,"category":"Dairy","unit":"litre"},
          {"name":"Bread"},{"name":"Apples","quantity":0,"unit":"","category":""}
        ]}
        """.utf8))
        XCTAssertEqual(result.method, "local")
        XCTAssertEqual(result.items[0].price, 3.49)
        let review = result.items.map(ReceiptReviewItem.init)
        XCTAssertEqual(review[0].quantity, "2.5")
        XCTAssertEqual(review[1].quantity, "1.0")
        XCTAssertEqual(review[2].unit, "count")
        XCTAssertEqual(review[2].category, "General")
        XCTAssertNotEqual(review[1].id, review[2].id)
    }

    func testSelectionValidationAndExactImportShape() throws {
        var selected = item(" Milk ")
        selected.quantity = "2.5"
        selected.unit = " litre "
        selected.category = " Dairy "
        var excluded = item("")
        excluded.selected = false
        excluded.quantity = "invalid"
        let payload = try ReceiptImport(review: [selected, excluded], location: " Fridge ")
        let data = try JSONEncoder().encode(payload)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: [[String: Any]]])
        let row = try XCTUnwrap(json["items"]?.first)
        XCTAssertEqual(json["items"]?.count, 1)
        XCTAssertEqual(Set(row.keys), ["name", "quantity", "unit", "category", "location"])
        XCTAssertEqual(row["name"] as? String, "Milk")
        XCTAssertEqual(row["quantity"] as? Double, 2.5)
        XCTAssertEqual(row["location"] as? String, "Fridge")
        XCTAssertEqual(row["unit"] as? String, "litre")
        XCTAssertEqual(row["category"] as? String, "Dairy")
    }

    func testInvalidSelectedItemsCannotBeSaved() {
        XCTAssertThrowsError(try ReceiptImport(review: [], location: "Pantry"))
        for quantity in ["", "abc", "-1", "0", "nan", "inf"] {
            var review = item("Milk")
            review.quantity = quantity
            XCTAssertThrowsError(try ReceiptImport(review: [review], location: "Pantry"), quantity)
        }
        for keyPath in [\ReceiptReviewItem.name, \.unit, \.category] {
            var review = item("Milk")
            review[keyPath: keyPath] = " "
            XCTAssertThrowsError(try ReceiptImport(review: [review], location: "Pantry"))
        }
        XCTAssertThrowsError(try ReceiptImport(review: [item("Milk")], location: " "))
    }

    func testImageUploadSizeBoundaries() throws {
        XCTAssertThrowsError(try ReceiptImage(jpegData: Data()))
        _ = try ReceiptImage(jpegData: Data(repeating: 0, count: ReceiptImage.maximumBytes))
        XCTAssertThrowsError(try ReceiptImage(
            jpegData: Data(repeating: 0, count: ReceiptImage.maximumBytes + 1)
        ))
    }

    @MainActor
    func testCapturedImageIsNormalizedToBoundedJPEG() throws {
        XCTAssertThrowsError(try ReceiptScanView.receiptImage(UIImage()))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let original = UIGraphicsImageRenderer(size: CGSize(width: 4500, height: 100), format: format)
            .image { context in
                UIColor.white.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 4500, height: 100))
            }
        let receipt = try ReceiptScanView.receiptImage(original)
        let decoded = try XCTUnwrap(UIImage(data: receipt.data))
        XCTAssertEqual(decoded.size.width, 4096)
        XCTAssertEqual(decoded.imageOrientation, .up)
        XCTAssertEqual(Array(receipt.data.prefix(2)), [0xFF, 0xD8])
        XCTAssertLessThanOrEqual(receipt.data.count, ReceiptImage.maximumBytes)
    }

    func testScanUsesReceiptMultipartContract() async throws {
        ReceiptURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/receipt/scan")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")?
                .hasPrefix("multipart/form-data; boundary=") == true)
            let body = String(decoding: try Self.body(request), as: UTF8.self)
            XCTAssertTrue(body.contains("name=\"receipt\"; filename=\"receipt.jpg\""))
            XCTAssertTrue(body.contains("Content-Type: image/jpeg\r\n\r\nimage-bytes"))
            return (200, #"{"method":"cloud","items":[{"name":"Milk","quantity":1,"category":"Dairy","unit":"count"}]}"#)
        }
        let result = try await ReceiptService(client: client).scan(ReceiptImage(jpegData: Data("image-bytes".utf8)))
        XCTAssertEqual(result.method, "cloud")
        XCTAssertEqual(result.items.first?.name, "Milk")
    }

    @MainActor
    func testImageSelectionDoesNotUploadAndSuccessCannotBeSubmittedTwice() async throws {
        let model = ReceiptScanModel(client: client)
        ReceiptURLProtocol.handler = { _ in
            XCTFail("Selecting an image must not upload it")
            return (500, "{}")
        }
        await model.loadImage { try ReceiptImage(jpegData: Data([1])) }
        XCTAssertNotNil(model.image)
        XCTAssertTrue(model.items.isEmpty)
        model.items = [item("Milk")]
        var calls = 0
        ReceiptURLProtocol.handler = { request in
            calls += 1
            XCTAssertEqual(request.url?.path, "/api/inventory")
            XCTAssertEqual(request.httpMethod, "POST")
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.body(request)) as? [String: [[String: Any]]])
            XCTAssertEqual(json["items"]?.first?["name"] as? String, "Milk")
            return (201, "[]")
        }
        async let first: Void = model.save()
        async let second: Void = model.save()
        _ = await (first, second)
        await model.save()
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(model.savedCount, 1)
    }

    @MainActor
    func testEmptyScanAndServerFailuresAreVisibleAndRetryable() async throws {
        let model = ReceiptScanModel(client: client)
        await model.loadImage { try ReceiptImage(jpegData: Data([1])) }
        ReceiptURLProtocol.handler = { _ in (200, #"{"method":"local","items":[]}"#) }
        await model.scan()
        XCTAssertTrue(model.error?.contains("No items detected") == true)
        XCTAssertFalse(model.busy)
        ReceiptURLProtocol.handler = { _ in (500, #"{"error":"Scanner unavailable"}"#) }
        await model.scan()
        XCTAssertEqual(model.error, "Scanner unavailable")
        ReceiptURLProtocol.handler = { _ in (200, #"{"method":"local","items":[{"name":"Milk"}]}"#) }
        await model.scan()
        XCTAssertNil(model.error)
        XCTAssertEqual(model.items.count, 1)
        ReceiptURLProtocol.handler = { _ in (400, #"{"error":"Failed to create inventory items"}"#) }
        await model.save()
        XCTAssertNil(model.savedCount)
        XCTAssertTrue(model.error?.contains("Check inventory") == true)
        XCTAssertEqual(model.items.count, 1)
    }

    @MainActor
    func testUnauthorizedUsesCentralHandlerAndCancelledSelectionPreservesImage() async throws {
        var signedOut = false
        client.onUnauthorized = { signedOut = true }
        let model = ReceiptScanModel(client: client)
        await model.loadImage { try ReceiptImage(jpegData: Data([1])) }
        let loading = Task {
            await model.loadImage {
                try await Task.sleep(for: .seconds(30))
                return try ReceiptImage(jpegData: Data([2]))
            }
        }
        await Task.yield()
        loading.cancel()
        await loading.value
        XCTAssertEqual(model.image?.data, Data([1]))
        XCTAssertNil(model.error)
        ReceiptURLProtocol.handler = { _ in (403, #"{"error":"Forbidden"}"#) }
        await model.scan()
        XCTAssertTrue(signedOut)
        XCTAssertNotNil(model.error)
    }

    private func item(_ name: String) -> ReceiptReviewItem {
        ReceiptReviewItem(ReceiptParsedItem(name: name, quantity: nil, price: nil, category: nil, unit: nil))
    }

    private static func body(_ request: URLRequest) throws -> Data {
        if let data = request.httpBody { return data }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw try XCTUnwrap(stream.streamError) }
            if count == 0 { return result }
            result.append(contentsOf: buffer.prefix(count))
        }
    }
}

private final class ReceiptURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, String))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let (status, body) = try XCTUnwrap(Self.handler)(request)
            let response = try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap(request.url), statusCode: status, httpVersion: nil, headerFields: nil
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
