import XCTest

/// P3.7 gate evidence: opens each base game, plays a few legal intents, and
/// attaches a mid-deal screenshot of the dev play screen. The attachment is
/// exported after the run (`xcresulttool export attachments`) and stored in
/// docs/screenshots/ — this is the only way the loop caught the app in-play
/// reliably (host-side `simctl io screenshot` races the test end).
@MainActor
final class ScreenshotUITests: XCTestCase {
    func testScreenshotHeartsMidDeal() throws {
        try snapMidDeal("hearts.standard", taps: 4, name: "p37-dev-hearts")
    }

    func testScreenshotEuchreMidDeal() throws {
        try snapMidDeal("euchre.standard", taps: 5, name: "p37-dev-euchre")
    }

    func testScreenshotBridgeMidDeal() throws {
        try snapMidDeal("contract-bridge.rubber", taps: 6, name: "p37-dev-bridge")
    }

    func testScreenshotCribbageMidDeal() throws {
        try snapMidDeal("cribbage.six-card", taps: 6, name: "p37-dev-cribbage")
    }

    private func snapMidDeal(_ game: String, taps: Int, name: String) throws {
        let app = XCUIApplication()
        app.launch()
        let row = app.buttons["game_\(game)"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "launcher row for \(game)")
        row.tap()
        // The play screen must reach the human at least once.
        let intent = app.buttons["intent_0"]
        XCTAssertTrue(intent.waitForExistence(timeout: 20), "\(game): intent_0 appeared")
        // Play a few legal intents so the shot shows real mid-deal state.
        for _ in 0..<taps {
            let next = app.buttons["intent_0"]
            guard next.waitForExistence(timeout: 20) else { break }
            next.tap()
        }
        let counter = app.staticTexts["dealsCounter"]
        XCTAssertTrue(counter.waitForExistence(timeout: 10), "\(game): play screen alive")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
