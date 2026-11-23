import XCTest

/// P3.7 accept: XCUITest plays one full deal of each base game to
/// completion on the iPad simulator. Deal completion is read from the
/// header's deals counter text (identifier `dealsCompleted`); the counter
/// shows the engine's dealIndex, which `finishDeal` bumps at every deal
/// boundary, so it leaves 0 exactly when the first deal has ended.
@MainActor
final class DevPlayUITests: XCTestCase {
    /// The four base game stems, matching LauncherView.games.
    static let games = [
        "hearts.standard", "euchre.standard",
        "contract-bridge.rubber", "cribbage.six-card",
    ]

    func testPlaysOneFullDealOfEachGame() throws {
        let app = XCUIApplication()
        app.launch()

        for game in Self.games {
            let gameButton = app.buttons["game_\(game)"]
            XCTAssertTrue(gameButton.waitForExistence(timeout: 10), "\(game): launcher missing")
            gameButton.tap()

            // Drive the deal: tap a legal intent whenever the human is on
            // turn; the session's bots cover the other seats. Stop as soon
            // as one deal completes (the header counter leaves 0) or the
            // match ends.
            var taps = 0
            let tapCap = 220
            var dealDone = false
            while taps < tapCap && !dealDone {
                let counter = app.staticTexts["dealsCounter"].firstMatch
                XCTAssertTrue(
                    counter.waitForExistence(timeout: 20),
                    "\(game): play screen never appeared after tapping the launcher row")
                if counter.label != "Deals completed: 0" {
                    // dealIndex > 0: the first deal has ended.
                    dealDone = true
                    break
                }

                // Buttons carry intent_N identifiers; tap the first.
                let button = app.buttons["intent_0"].firstMatch
                if button.waitForExistence(timeout: 10) {
                    button.tap()
                    taps += 1
                } else {
                    // Zones visible but no button yet: bots are moving. If
                    // nothing appears while the deal is still live, fail.
                    let stillWaiting = app.staticTexts["waiting"].firstMatch
                    _ = stillWaiting.waitForExistence(timeout: 5)
                    if !button.exists && !stillWaiting.exists {
                        XCTFail("\(game): neither intent buttons nor waiting indicator; deal appears stuck")
                        return
                    }
                }
            }
            XCTAssertTrue(dealDone, "\(game): tap cap \(tapCap) reached before the first deal ended")
            taps = 0

            // Back to the launcher for the next game.
            let back = app.navigationBars.buttons.firstMatch
            if back.exists { back.tap() }
        }
    }
}
