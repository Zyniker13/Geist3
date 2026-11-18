import XCTest

@MainActor
final class ParlorUITests: XCTestCase {
    func testAppLaunches() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertFalse(app.state == .notRunning)
    }
}
