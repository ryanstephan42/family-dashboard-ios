import XCTest

final class OnboardingSmokeTests: XCTestCase {
    @MainActor
    func testFreshInstallRequiresServerAndRejectsInvalidAddress() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()

        let address = app.textFields["family.example.com"]
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        let connect = app.buttons["Connect"]
        XCTAssertFalse(connect.isEnabled)
        XCTAssertFalse(app.tabBars.firstMatch.exists)

        address.tap()
        address.typeText("https://")
        XCTAssertTrue(connect.isEnabled)
        connect.tap()
        XCTAssertTrue(app.staticTexts["Invalid server address."].waitForExistence(timeout: 5))
        XCTAssertTrue(address.isEnabled)
        XCTAssertFalse(app.secureTextFields["Password"].exists)
        XCTAssertFalse(app.tabBars.firstMatch.exists)
    }
}
