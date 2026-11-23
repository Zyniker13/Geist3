import XCTest

/// One-off probe (P3.7 debug): dumps the accessibility tree on the play
/// screen so identifier visibility can be verified host-side.
@MainActor
final class ScreenshotUITests: XCTestCase {
    func testOpenGameAndPause() throws {
        let app = XCUIApplication()
        app.launch()
        let game = app.buttons["game_hearts.standard"]
        XCTAssertTrue(game.waitForExistence(timeout: 10))
        game.tap()
        _ = app.buttons["intent_0"].firstMatch.waitForExistence(timeout: 15)
        print("PROBE TREE BEGIN")
        for e in app.staticTexts.allElementsBoundByIndex {
            print("PROBE text id='\(e.identifier)' label='\(e.label.prefix(60))'")
        }
        for e in app.buttons.allElementsBoundByIndex.prefix(20) {
            print("PROBE button id='\(e.identifier)' label='\(e.label.prefix(30))'")
        }
        print("PROBE TREE END")
    }
}
