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

        XCTAssertTrue(app.staticTexts.matching(identifier: "dashboard-title").firstMatch.waitForExistence(timeout: 5))
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
        let selectedTile = app.buttons["Selected item for deletion"].firstMatch
        XCTAssertTrue(selectedTile.waitForExistence(timeout: 3))
        selectedTile.tap()
        XCTAssertTrue(app.staticTexts["0 selected for deletion"].waitForExistence(timeout: 3))
        app.buttons["Kept item"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["1 selected for deletion"].waitForExistence(timeout: 3))
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
        XCTAssertTrue(app.buttons["close-media-viewer"].waitForExistence(timeout: 3))
        let favoriteButton = app.buttons["favorite-media"]
        XCTAssertTrue(favoriteButton.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["share-media"].waitForExistence(timeout: 3))
        favoriteButton.tap()
        XCTAssertTrue(app.buttons["Remove from Favorites"].waitForExistence(timeout: 3))
        app.buttons["Remove from Favorites"].tap()
        XCTAssertTrue(app.buttons["Add to Favorites"].waitForExistence(timeout: 3))
        app.buttons["close-media-viewer"].tap()
        XCTAssertTrue(app.buttons["decision-keep"].waitForExistence(timeout: 3))
    }

    func testCleanupPreviewDismissesWithSwipesAndKeepsDecision() {
        let app = XCUIApplication()
        app.launchArguments.append("--ui-testing")
        app.launch()

        let photoGroup = app.buttons["group-row-month:2026-08"]
        XCTAssertTrue(photoGroup.waitForExistence(timeout: 5))
        photoGroup.tap()
        app.buttons["clean-selected"].tap()
        let openViewer = app.buttons["open-media-viewer"]
        XCTAssertTrue(openViewer.waitForExistence(timeout: 3))

        for direction in 0..<4 {
            openViewer.tap()
            XCTAssertTrue(app.buttons["close-media-viewer"].waitForExistence(timeout: 3))
            switch direction {
            case 0: app.swipeLeft()
            case 1: app.swipeRight()
            case 2: app.swipeUp()
            default: app.swipeDown()
            }
            XCTAssertTrue(openViewer.waitForExistence(timeout: 3))
            XCTAssertFalse(app.buttons["close-media-viewer"].exists)
            XCTAssertFalse(app.buttons["undo-button"].isEnabled)
        }

        openViewer.tap()
        let close = app.buttons["close-media-viewer"]
        XCTAssertTrue(close.waitForExistence(timeout: 3))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleTap()
        app.swipeLeft()
        XCTAssertTrue(close.exists, "Dragging a zoomed photo should pan instead of dismissing")
        close.tap()
    }

    func testPhotoTapUndoesButControlsAndMarginsDoNot() {
        let app = XCUIApplication()
        app.launchArguments.append("--ui-testing")
        app.launch()

        for month in ["2026-08", "2026-07"] {
            let group = app.buttons["group-row-month:\(month)"]
            XCTAssertTrue(group.waitForExistence(timeout: 5))
            group.tap()
        }
        app.buttons["clean-selected"].tap()
        let keep = app.buttons["decision-keep"]
        XCTAssertTrue(keep.waitForExistence(timeout: 3))
        keep.tap()
        let undo = app.buttons["undo-button"]
        XCTAssertTrue(waitUntilEnabled(undo))

        app.buttons["open-media-viewer"].tap()
        app.buttons["close-media-viewer"].tap()
        XCTAssertTrue(undo.isEnabled)

        let photo = app.descendants(matching: .any)["cleanup-photo-surface"].firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 3))
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: -0.5)).tap()
        XCTAssertTrue(undo.isEnabled, "Tapping the black margin must not undo")
        photo.tap()
        XCTAssertTrue(waitUntilEnabled(app.buttons["redo-button"]))
        XCTAssertFalse(undo.isEnabled)
    }

    func testDashboardRestoresVisibleMonthAfterCompletion() {
        let app = XCUIApplication()
        app.launchArguments.append("--ui-testing")
        app.launch()

        let olderYear = app.buttons["Jump to 2025"]
        XCTAssertTrue(olderYear.waitForExistence(timeout: 5))
        olderYear.tap()
        let target = app.buttons["group-row-month:2025-10"]
        XCTAssertTrue(target.waitForExistence(timeout: 3))
        XCTAssertTrue(target.isHittable)
        target.tap()
        app.buttons["clean-selected"].tap()
        app.buttons["decision-keep"].tap()
        XCTAssertTrue(app.staticTexts["Freshly slashed"].waitForExistence(timeout: 3))
        app.buttons["Back to library"].tap()
        XCTAssertTrue(target.waitForExistence(timeout: 3))
        XCTAssertTrue(target.isHittable, "The previously visible month should remain on screen")
    }

    func testDashboardRestoresVisibleLocationAfterCompletionAndGroupingSwitch() {
        let app = XCUIApplication()
        app.launchArguments.append("--ui-testing")
        app.launch()

        let locationTab = app.buttons["Location"]
        XCTAssertTrue(locationTab.waitForExistence(timeout: 5))
        locationTab.tap()
        let locationList = app.scrollViews["location-group-list"]
        XCTAssertTrue(locationList.waitForExistence(timeout: 5))
        let firstResolved = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'group-row-location:resolved:'")
        ).firstMatch
        XCTAssertTrue(firstResolved.waitForExistence(timeout: 5))

        let target = app.buttons["group-row-location:resolved:demo place 9|thailand"]
        for _ in 0..<6 where !target.isHittable { locationList.swipeUp() }
        XCTAssertTrue(target.isHittable)
        target.tap()
        app.buttons["clean-selected"].tap()
        app.buttons["decision-keep"].tap()
        XCTAssertTrue(app.staticTexts["Freshly slashed"].waitForExistence(timeout: 3))
        app.buttons["Back to library"].tap()
        XCTAssertTrue(target.waitForExistence(timeout: 3))
        XCTAssertTrue(target.isHittable)

        app.buttons["Month"].tap()
        app.buttons["Location"].tap()
        XCTAssertTrue(target.waitForExistence(timeout: 3))
        XCTAssertTrue(target.isHittable)
    }

    private func waitUntilEnabled(_ element: XCUIElement) -> Bool {
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: element)
        return XCTWaiter.wait(for: [enabled], timeout: 3) == .completed
    }
}
