import XCTest

@MainActor
final class RollSlashUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testKeepFlowCompletes() {
        let app = XCUIApplication()
        app.launchArguments.append("--ui-testing")
        app.launch()

        XCTAssertTrue(app.navigationBars["Roll Slash"].waitForExistence(timeout: 5))
        let firstGroup = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'group-row-'")).firstMatch
        XCTAssertTrue(firstGroup.waitForExistence(timeout: 3))
        firstGroup.tap()
        app.buttons["clean-selected"].tap()
        XCTAssertTrue(app.buttons["decision-keep"].waitForExistence(timeout: 3))
        app.buttons["decision-keep"].tap()
        XCTAssertTrue(app.staticTexts["Freshly slashed"].waitForExistence(timeout: 3))
    }

    func testDeletionReviewFlowCompletes() {
        let app = XCUIApplication()
        app.launchArguments.append("--ui-testing")
        app.launch()

        let firstGroup = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'group-row-'")).firstMatch
        XCTAssertTrue(firstGroup.waitForExistence(timeout: 5))
        firstGroup.tap()
        app.buttons["clean-selected"].tap()
        XCTAssertTrue(app.buttons["decision-delete"].waitForExistence(timeout: 3))
        app.buttons["decision-delete"].tap()
        XCTAssertTrue(app.navigationBars["Final review"].waitForExistence(timeout: 3))
        app.buttons["commit-deletion"].tap()
        XCTAssertTrue(app.staticTexts["Freshly slashed"].waitForExistence(timeout: 3))
    }

    func testFullScreenViewerOpensAndDismisses() {
        let app = XCUIApplication()
        app.launchArguments.append("--ui-testing")
        app.launch()

        let firstGroup = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'group-row-'" )).firstMatch
        XCTAssertTrue(firstGroup.waitForExistence(timeout: 5))
        firstGroup.tap()
        app.buttons["clean-selected"].tap()

        XCTAssertTrue(app.buttons["open-media-viewer"].waitForExistence(timeout: 3))
        app.buttons["open-media-viewer"].tap()
        XCTAssertTrue(app.otherElements["media-viewer"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["close-media-viewer"].waitForExistence(timeout: 3))
        app.buttons["close-media-viewer"].tap()
        XCTAssertTrue(app.buttons["decision-keep"].waitForExistence(timeout: 3))
    }
}
