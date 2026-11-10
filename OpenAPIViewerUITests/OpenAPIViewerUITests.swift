import XCTest

final class OpenAPIViewerUITests: XCTestCase {
    func testDocumentWindowShowsNativeViewerControls() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Reload"].exists)
        XCTAssertTrue(app.textFields["Filter operations by path, method, tag, or summary"].exists)
    }
}
