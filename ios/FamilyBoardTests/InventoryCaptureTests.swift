import XCTest
@testable import FamilyBoard

final class InventoryCaptureTests: XCTestCase {
    func testPhotoURLsUseServerOriginAndPortNotAPIOrConfiguredPath() throws {
        let server = try XCTUnwrap(URL(string: "https://family.example.com:8443/hub"))
        XCTAssertEqual(
            InventoryPhoto.url("/uploads/item%20photo.jpg", server: server)?.absoluteString,
            "https://family.example.com:8443/uploads/item%20photo.jpg"
        )
        XCTAssertNil(InventoryPhoto.url(nil, server: server))
    }

    func testPhotoURLsRejectOtherOriginsTraversalQueriesAndMalformedPaths() throws {
        let server = try XCTUnwrap(URL(string: "https://family.example.com"))
        for path in [
            "", "uploads/photo.jpg", "//other.example.com/uploads/photo.jpg",
            "https://other.example.com/uploads/photo.jpg", "/api/uploads/photo.jpg",
            "/uploads/../photo.jpg", "/uploads/%2e%2e", "/uploads/%2Fother.jpg",
            "/uploads/%252e%252e", "/uploads/photo.jpg?token=example",
            "/uploads/photo.jpg#fragment", "/uploads/", "/uploads/sub/photo.jpg",
            "/uploads/..", "/uploads/.", "/uploads/photo%0A.jpg", "/uploads/a%5Cb.jpg"
        ] {
            XCTAssertNil(InventoryPhoto.url(path, server: server), path)
        }
    }

    func testNullableBarcodeProductFillsReviewDraftWithoutLosingUserStorageChoices() throws {
        let product = try JSONDecoder().decode(InventoryBarcodeProduct.self, from: Data(
            #"{"barcode":"0012345678905","name":"Rice","category":null,"unit":null,"source":"memory"}"#.utf8
        ))
        var draft = InventoryDraft()
        draft.location = "Fridge"
        draft.quantity = "2.5"
        draft.notes = "Keep sealed"
        draft.apply(product)
        XCTAssertEqual(draft.name, "Rice")
        XCTAssertEqual(draft.barcode, "0012345678905")
        XCTAssertEqual(draft.category, "General")
        XCTAssertEqual(draft.location, "Fridge")
        XCTAssertEqual(draft.quantity, "2.5")
        XCTAssertEqual(draft.notes, "Keep sealed")
        draft.name = "Edited rice"
        let body = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(draft.payload())
        ) as? [String: Any])
        XCTAssertEqual(body["name"] as? String, "Edited rice")
        XCTAssertEqual(body["barcode"] as? String, "0012345678905")
    }

    func testProductCategoryAndUnitAreEditableAndManualFallbackRequiresAName() throws {
        var draft = InventoryDraft()
        draft.apply(InventoryBarcodeProduct(
            barcode: "012345", name: "Milk", category: "Dairy", unit: "carton", source: "openfoodfacts"
        ))
        XCTAssertEqual(draft.category, "Dairy")
        XCTAssertEqual(draft.unit, "carton")
        draft.apply(InventoryBarcodeProduct(barcode: "098765", name: "", category: nil, unit: nil, source: nil))
        XCTAssertThrowsError(try draft.payload())
        draft.name = "Manually named product"
        XCTAssertNoThrow(try draft.payload())
        draft.barcode = String(repeating: "1", count: 129)
        XCTAssertThrowsError(try draft.payload())
        draft.barcode = "123\n45"
        XCTAssertThrowsError(try draft.payload())
    }
}
