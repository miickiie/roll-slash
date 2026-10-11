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

    func testUnavailableVideoPreviewOffersRetry() {
        let app = XCUIApplication()
        app.launchArguments.append("--ui-testing")
        app.launch()
        let videoGroup = app.buttons["group-row-month:2026-09"]
        XCTAssertTrue(videoGroup.waitForExistence(timeout: 5))
        videoGroup.tap()
        app.buttons["clean-selected"].tap()
        XCTAssertTrue(app.buttons["open-media-viewer"].waitForExistence(timeout: 3))
        app.buttons["open-media-viewer"].tap()
        XCTAssertTrue(app.staticTexts["Preview unavailable"].waitForExistence(timeout: 3))
        let retry = app.buttons["Retry"]
        XCTAssertTrue(retry.exists)
        retry.tap()
        XCTAssertTrue(app.staticTexts["Preview unavailable"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["Loading preview…"].exists)
        app.buttons["close-media-viewer"].tap()
        XCTAssertTrue(app.buttons["decision-keep"].waitForExistence(timeout: 3))
    }

    func testFinishPartialKeepOnlySession() {
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
        XCTAssertTrue(app.staticTexts["1 left"].waitForExistence(timeout: 3))

        let finish = app.buttons["finish-session"]
        XCTAssertTrue(waitUntilEnabled(finish))
        XCTAssertTrue(finish.isHittable)
        finish.tap()
        XCTAssertTrue(app.staticTexts.matching(identifier: "dashboard-title").firstMatch.waitForExistence(timeout: 3))
        let unfinishedGroup = app.buttons["group-row-month:2026-07"]
        XCTAssertTrue(unfinishedGroup.waitForExistence(timeout: 3))
        XCTAssertEqual(unfinishedGroup.value as? String, "1 left to review")
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

    func testFinalReviewPreviewVerticalSwipesDismissAndPreserveChoices() {
        let app = XCUIApplication()
        app.launchArguments.append("--ui-testing")
        app.launch()
        for month in ["2026-08", "2026-07"] {
            let group = app.buttons["group-row-month:\(month)"]
            XCTAssertTrue(group.waitForExistence(timeout: 5))
            group.tap()
        }
        app.buttons["clean-selected"].tap()
        for _ in 0..<2 {
            let delete = app.buttons["decision-delete"]
            XCTAssertTrue(delete.waitForExistence(timeout: 3))
            XCTAssertTrue(waitUntilEnabled(delete))
            delete.tap()
        }
        XCTAssertTrue(app.navigationBars["Final review"].waitForExistence(timeout: 3))
        let preview = app.buttons["review-preview-demo-1"]
        XCTAssertTrue(preview.waitForExistence(timeout: 3))

        for direction in 0..<2 {
            preview.tap()
            let close = app.buttons["close-media-viewer"]
            XCTAssertTrue(close.waitForExistence(timeout: 3))
            XCTAssertEqual(app.staticTexts["review-viewer-position"].label, "1 of 2")
            if direction == 0 { app.buttons["review-viewer-toggle"].tap() }
            app.swipeLeft()
            XCTAssertEqual(app.staticTexts["review-viewer-position"].label, "2 of 2")
            XCTAssertTrue(close.exists, "Horizontal swipes must navigate without dismissing")
            app.swipeRight()
            XCTAssertEqual(app.staticTexts["review-viewer-position"].label, "1 of 2")
            XCTAssertEqual(app.buttons["review-viewer-toggle"].label, "Kept item")
            if direction == 0 { app.swipeUp() } else { app.swipeDown() }
            let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: close)
            XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 3), .completed)
            XCTAssertTrue(app.buttons["commit-deletion"].isHittable)
            XCTAssertEqual(app.buttons["review-selection-demo-1"].value as? String, "Not selected")
            XCTAssertEqual(app.buttons["review-selection-demo-2"].value as? String, "Selected")
            XCTAssertTrue(app.staticTexts["1 selected for deletion"].exists)
        }

        preview.tap()
        let close = app.buttons["close-media-viewer"]
        XCTAssertTrue(close.waitForExistence(timeout: 3))
        let center = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        center.doubleTap()
        app.swipeUp()
        XCTAssertTrue(close.exists, "Vertical swipes must pan a zoomed photo")
        app.swipeDown()
        XCTAssertTrue(close.exists)
        XCTAssertEqual(app.staticTexts["review-viewer-position"].label, "1 of 2")
        center.doubleTap()
        app.swipeDown()
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: close)
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 3), .completed)
        XCTAssertTrue(app.staticTexts["1 selected for deletion"].exists)

        preview.tap()
        XCTAssertTrue(close.waitForExistence(timeout: 3))
        saveScreenshot(app, name: "Final review photo preview with preserved choices")
        close.tap()
        let closedByButton = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: close)
        XCTAssertEqual(XCTWaiter.wait(for: [closedByButton], timeout: 3), .completed)
        XCTAssertTrue(app.staticTexts["1 selected for deletion"].exists)
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
            let closeDisappeared = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == false"),
                object: app.buttons["close-media-viewer"]
            )
            XCTAssertEqual(XCTWaiter.wait(for: [closeDisappeared], timeout: 3), .completed)
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

    func testPreloadedCardsRemainVisibleAfterKeepDeleteSwipesAndUndo() {
        let app = XCUIApplication()
        app.launchArguments.append("--ui-testing")
        app.launch()
        for month in ["2026-08", "2026-07", "2026-06"] {
            let group = app.buttons["group-row-month:\(month)"]
            XCTAssertTrue(group.waitForExistence(timeout: 5))
            group.tap()
        }
        app.buttons["clean-selected"].tap()
        let photo = app.descendants(matching: .any)["cleanup-photo-surface"].firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 3))
        photo.swipeRight()
        XCTAssertTrue(app.staticTexts["2 left"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["Loading preview…"].exists)
        XCTAssertTrue(waitUntilEnabled(app.buttons["decision-delete"]))
        photo.swipeLeft()
        XCTAssertTrue(app.staticTexts["1 left"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["Loading preview…"].exists)
        let undo = app.buttons["undo-button"]
        XCTAssertTrue(waitUntilEnabled(undo))
        undo.tap()
        XCTAssertTrue(waitUntilEnabled(app.buttons["redo-button"]))
        XCTAssertTrue(app.staticTexts["2 left"].exists)
        XCTAssertFalse(app.staticTexts["Loading preview…"].exists)
        XCTAssertEqual(app.buttons.matching(identifier: "open-media-viewer").count, 1)
        saveScreenshot(app, name: "Ready photo after keep, delete, and undo")
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

        XCTAssertEqual(app.buttons.matching(identifier: "open-media-viewer").count, 1)
        app.buttons["open-media-viewer"].tap()
        app.buttons["close-media-viewer"].tap()
        XCTAssertTrue(undo.isEnabled)

        let photo = app.descendants(matching: .any)["cleanup-photo-surface"].firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 3))
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "cleanup-photo-surface").count, 1)
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

    func testTypeOverlapComparisonPreviewResumeAndBatchUndo() {
        let app = XCUIApplication()
        app.launchArguments.append("--ui-testing")
        app.launch()
        XCTAssertTrue(app.buttons["Type"].waitForExistence(timeout: 5))
        app.buttons["Type"].tap()
        let similar = app.buttons["group-row-type:similarPhotos"]
        XCTAssertTrue(similar.waitForExistence(timeout: 5))
        let dashboard = XCTAttachment(screenshot: app.screenshot())
        dashboard.name = "Type dashboard"
        dashboard.lifetime = .keepAlways
        add(dashboard)
        app.buttons["group-row-type:screenshots"].tap()
        similar.tap()
        XCTAssertTrue(app.staticTexts["2 items to review"].exists)
        app.buttons["clean-selected"].tap()
        let confirm = app.buttons["comparison-confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["comparison-delete-demo-1"].value as? String, "Not selected to delete")
        let comparison = XCTAttachment(screenshot: app.screenshot())
        comparison.name = "Similar Photos comparison"
        comparison.lifetime = .keepAlways
        add(comparison)
        app.buttons["comparison-preview-demo-1"].tap()
        XCTAssertTrue(app.buttons["close-media-viewer"].waitForExistence(timeout: 3))
        app.buttons["close-media-viewer"].tap()
        let deletionChoice = app.buttons["comparison-delete-demo-2"]
        XCTAssertTrue(waitUntilHittable(deletionChoice))
        deletionChoice.tap()
        XCTAssertTrue(waitForValue(deletionChoice, "Selected to delete"))
        app.buttons["Close"].tap()
        XCTAssertTrue(app.buttons["Resume"].waitForExistence(timeout: 3))
        app.buttons["Resume"].tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        XCTAssertTrue(waitForValue(deletionChoice, "Selected to delete"))
        confirm.tap()
        XCTAssertTrue(app.navigationBars["Final review"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["1 selected for deletion"].exists)
        app.buttons["Undo Last"].tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        XCTAssertEqual(app.buttons["comparison-delete-demo-2"].value as? String, "Selected to delete")
        confirm.tap()
        XCTAssertTrue(app.buttons["commit-deletion"].waitForExistence(timeout: 3))
        app.buttons["commit-deletion"].tap()
        XCTAssertTrue(app.staticTexts["Freshly slashed"].waitForExistence(timeout: 5))
    }

    func testTypeScrollRestorationAndMetadataGroups() {
        let app = XCUIApplication()
        app.launchArguments.append("--ui-testing")
        app.launch()
        XCTAssertTrue(app.buttons["Type"].waitForExistence(timeout: 5))
        app.buttons["Type"].tap()
        let list = app.scrollViews["type-group-list"]
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["group-row-type:receipts"].exists)
        let target = app.buttons["group-row-type:selfies"]
        for _ in 0..<6 where !target.isHittable { list.swipeUp() }
        XCTAssertTrue(target.isHittable)
        target.tap()
        app.buttons["clean-selected"].tap()
        XCTAssertTrue(app.buttons["decision-keep"].waitForExistence(timeout: 3))
        app.buttons["decision-keep"].tap()
        XCTAssertTrue(app.staticTexts["Freshly slashed"].waitForExistence(timeout: 3))
        app.buttons["Back to library"].tap()
        XCTAssertTrue(target.waitForExistence(timeout: 3))
        XCTAssertTrue(target.isHittable)
        app.buttons["Month"].tap()
        app.buttons["Type"].tap()
        XCTAssertTrue(target.waitForExistence(timeout: 3))
        XCTAssertTrue(target.isHittable)
    }

    func testSimilarPreviewSelectionNavigationAndZoomStayWithinFrozenSet() {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-testing", "--comparison-fixtures"]
        app.launch()
        XCTAssertTrue(app.buttons["Type"].waitForExistence(timeout: 5))
        app.buttons["Type"].tap()
        let similar = app.buttons["group-row-type:similarPhotos"]
        XCTAssertTrue(similar.waitForExistence(timeout: 5))
        similar.tap()
        app.buttons["clean-selected"].tap()

        let portrait = app.buttons["comparison-preview-demo-1"]
        let landscape = app.buttons["comparison-preview-demo-2"]
        XCTAssertTrue(portrait.waitForExistence(timeout: 5))
        XCTAssertTrue(landscape.waitForExistence(timeout: 3))
        XCTAssertEqual(portrait.frame.width, landscape.frame.width, accuracy: 1)
        XCTAssertEqual(portrait.frame.width, portrait.frame.height, accuracy: 1)
        XCTAssertEqual(portrait.frame.minY, landscape.frame.minY, accuracy: 1)
        XCTAssertLessThan(portrait.frame.maxX, landscape.frame.minX)
        saveScreenshot(app, name: "Two columns with whole portrait and landscape photos")

        portrait.tap()
        let position = app.staticTexts["comparison-viewer-position"]
        XCTAssertTrue(position.waitForExistence(timeout: 3))
        XCTAssertEqual(position.label, "1 of 3")
        XCTAssertFalse(app.buttons["comparison-viewer-previous"].isEnabled)
        let toggle = app.buttons["comparison-viewer-toggle"]
        XCTAssertEqual(toggle.value as? String, "Not selected to delete")
        toggle.tap()
        XCTAssertEqual(toggle.value as? String, "Selected to delete")
        app.swipeRight()
        XCTAssertEqual(position.label, "1 of 3")
        app.swipeLeft()
        XCTAssertEqual(position.label, "2 of 3")
        XCTAssertEqual(toggle.value as? String, "Not selected to delete")
        saveScreenshot(app, name: "Full resolution similar preview with delete selection")

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleTap()
        app.swipeLeft()
        XCTAssertEqual(position.label, "2 of 3", "Zoomed swipes must pan instead of navigating")
        app.buttons["comparison-viewer-next"].tap()
        XCTAssertEqual(position.label, "3 of 3")
        XCTAssertFalse(app.buttons["comparison-viewer-next"].isEnabled)
        app.swipeLeft()
        XCTAssertEqual(position.label, "3 of 3", "The second similar set must never join this preview")
        app.swipeRight()
        XCTAssertEqual(position.label, "2 of 3", "Changing photos must reset zoom")
        app.buttons["comparison-viewer-previous"].tap()
        XCTAssertEqual(toggle.value as? String, "Selected to delete")
        let favorite = app.buttons["favorite-media"]
        XCTAssertTrue(favorite.waitForExistence(timeout: 3))
        XCTAssertTrue(waitUntilEnabled(favorite))
        favorite.tap()
        XCTAssertTrue(app.buttons["Remove from Favorites"].waitForExistence(timeout: 3))
        XCTAssertEqual(position.label, "1 of 3")
        saveScreenshot(app, name: "Similar preview status bar after favorite and selection")
        app.buttons["close-media-viewer"].tap()
        XCTAssertEqual(app.buttons["comparison-delete-demo-1"].value as? String, "Selected to delete")
        app.buttons["Close"].tap()
        XCTAssertTrue(app.buttons["Resume"].waitForExistence(timeout: 3))
        app.buttons["Resume"].tap()
        XCTAssertTrue(app.buttons["comparison-confirm"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.buttons["comparison-delete-demo-1"].value as? String, "Selected to delete")
        app.buttons["comparison-confirm"].tap()
        XCTAssertTrue(app.buttons["comparison-preview-demo-7"].waitForExistence(timeout: 3))
        app.buttons["comparison-delete-demo-7"].tap()
        app.buttons["comparison-undo"].tap()
        XCTAssertTrue(app.buttons["comparison-delete-demo-1"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.buttons["comparison-delete-demo-1"].value as? String, "Selected to delete")
        app.buttons["comparison-redo"].tap()
        XCTAssertTrue(app.buttons["comparison-delete-demo-7"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.buttons["comparison-delete-demo-7"].value as? String, "Selected to delete")
        app.buttons["comparison-keep-all"].tap()
        XCTAssertTrue(app.navigationBars["Final review"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["1 selected for deletion"].exists)
    }

    func testSimilarPreviewVerticalSwipesDismissAndPreserveChoices() {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-testing", "--comparison-fixtures"]
        app.launch()
        XCTAssertTrue(app.buttons["Type"].waitForExistence(timeout: 5))
        app.buttons["Type"].tap()
        let similar = app.buttons["group-row-type:similarPhotos"]
        XCTAssertTrue(similar.waitForExistence(timeout: 5))
        similar.tap()
        app.buttons["clean-selected"].tap()

        let firstPhoto = app.buttons["comparison-preview-demo-1"]
        let confirm = app.buttons["comparison-confirm"]
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 5))
        for direction in 0..<2 {
            firstPhoto.tap()
            let close = app.buttons["close-media-viewer"]
            XCTAssertTrue(close.waitForExistence(timeout: 3))
            if direction == 0 { app.buttons["comparison-viewer-toggle"].tap() }
            app.swipeLeft()
            XCTAssertEqual(app.staticTexts["comparison-viewer-position"].label, "2 of 3")
            if direction == 0 { app.swipeUp() } else { app.swipeDown() }
            let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: close)
            XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 3), .completed)
            XCTAssertTrue(confirm.isHittable)
            XCTAssertEqual(app.buttons["comparison-delete-demo-1"].value as? String, "Selected to delete")
            XCTAssertTrue(app.staticTexts["5 left"].exists, "Closing inspection must not advance the comparison")
            XCTAssertFalse(app.buttons["comparison-preview-demo-7"].exists)
        }

        firstPhoto.tap()
        let close = app.buttons["close-media-viewer"]
        XCTAssertTrue(close.waitForExistence(timeout: 3))
        let center = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        center.doubleTap()
        app.swipeUp()
        XCTAssertTrue(close.exists, "A vertical drag on a zoomed photo must pan")
        app.swipeDown()
        XCTAssertTrue(close.exists, "Both vertical directions must preserve a zoomed preview")
        XCTAssertEqual(app.staticTexts["comparison-viewer-position"].label, "1 of 3")
        center.doubleTap()
        app.swipeDown()
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: close)
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 3), .completed)
        XCTAssertTrue(confirm.isHittable)
        XCTAssertEqual(app.buttons["comparison-delete-demo-1"].value as? String, "Selected to delete")
    }

    func testSimilarTwoColumnsRemainBoundedAtAccessibilityTextSize() {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-testing", "--comparison-fixtures", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.buttons["Type"].waitForExistence(timeout: 5))
        app.buttons["Type"].tap()
        let similar = app.buttons["group-row-type:similarPhotos"]
        for _ in 0..<5 where !similar.isHittable { app.scrollViews["type-group-list"].swipeUp() }
        XCTAssertTrue(similar.isHittable)
        similar.tap()
        app.buttons["clean-selected"].tap()
        let first = app.buttons["comparison-preview-demo-1"]
        let second = app.buttons["comparison-preview-demo-2"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertTrue(second.waitForExistence(timeout: 3))
        let scroll = app.scrollViews["comparison-grid-scroll"]
        for _ in 0..<5 where !app.buttons["comparison-delete-demo-1"].isHittable { scroll.swipeUp() }
        XCTAssertTrue(app.buttons["comparison-delete-demo-1"].isHittable)
        XCTAssertTrue(app.buttons["comparison-delete-demo-2"].isHittable)
        XCTAssertLessThan(first.frame.maxX, second.frame.minX)
        XCTAssertGreaterThanOrEqual(first.frame.minX, 0)
        XCTAssertLessThanOrEqual(second.frame.maxX, app.frame.width)
        let firstToggle = app.buttons["comparison-delete-demo-1"]
        let secondToggle = app.buttons["comparison-delete-demo-2"]
        XCTAssertLessThan(firstToggle.frame.maxX, secondToggle.frame.minX)
        saveScreenshot(app, name: "Two-column comparison at accessibility text size")
    }

    func testMonthTitleTapsSelectOnlyTheirOwnCards() {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-testing", "--comparison-fixtures"]
        app.launch()
        let months = ["2026-09", "2026-08", "2026-07", "2026-06"]
        let cards = months.map { app.buttons["group-row-month:\($0)"] }
        XCTAssertTrue(cards[0].waitForExistence(timeout: 5))
        XCTAssertTrue(cards[3].waitForExistence(timeout: 3))
        let scroll = app.scrollViews["month-group-list"]
        for card in cards {
            XCTAssertGreaterThanOrEqual(card.frame.minX, scroll.frame.minX)
            XCTAssertLessThanOrEqual(card.frame.maxX, scroll.frame.maxX)
        }
        XCTAssertLessThanOrEqual(cards[0].frame.maxX, cards[1].frame.minX)
        XCTAssertLessThanOrEqual(cards[0].frame.maxY, cards[2].frame.minY)
        XCTAssertLessThanOrEqual(cards[1].frame.maxY, cards[3].frame.minY)

        for month in months {
            let title = app.staticTexts["group-title-month:\(month)"]
            XCTAssertTrue(title.waitForExistence(timeout: 3))
            let tap = app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: title.frame.midX, dy: title.frame.midY))
            tap.tap()
            let selected = app.buttons["group-row-month:\(month)"]
            let selection = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "label CONTAINS 'Selected'"), object: selected
            )
            XCTAssertEqual(XCTWaiter.wait(for: [selection], timeout: 3), .completed,
                           "Tapping \(month)'s title must select that card, not the row below")
            for otherMonth in months where otherMonth != month {
                XCTAssertFalse(app.buttons["group-row-month:\(otherMonth)"].label.contains("Selected"))
            }
            tap.tap()
            XCTAssertFalse(selected.label.contains("Selected"))
        }
        saveScreenshot(app, name: "Month title tap areas stay within their cards")
    }

    func testMonthGroupsAndConfirmationAdaptToAccessibilityTextSize() {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-testing", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let first = app.buttons["group-row-month:2026-09"]
        let second = app.buttons["group-row-month:2026-08"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertTrue(second.waitForExistence(timeout: 3))
        saveScreenshot(app, name: "Month cards at accessibility text size")
        XCTAssertGreaterThan(first.frame.width, app.frame.width / 2)
        XCTAssertEqual(first.frame.minX, second.frame.minX, accuracy: 1)
        XCTAssertLessThanOrEqual(first.frame.maxY, second.frame.minY,
                                 "Month card tap areas must not overlap the card below")
        let firstYear = app.buttons["Jump to 2026"]
        let secondYear = app.buttons["Jump to 2025"]
        XCTAssertTrue(firstYear.exists)
        XCTAssertTrue(secondYear.exists)
        XCTAssertEqual(firstYear.frame.minY, secondYear.frame.minY, accuracy: 1)
        XCTAssertGreaterThan(firstYear.frame.width, firstYear.frame.height)

        app.buttons["Settings"].tap()
        let reset = app.buttons["Reset Cleanup History"]
        for _ in 0..<8 where !reset.isHittable { app.swipeUp() }
        XCTAssertTrue(reset.isHittable)
        reset.tap()
        XCTAssertTrue(app.staticTexts["Reset cleanup history?"].waitForExistence(timeout: 3))
        let confirm = app.buttons["Reset History"]
        let popupScroll = app.scrollViews["popup-content-scroll"]
        XCTAssertTrue(popupScroll.exists)
        for _ in 0..<5 where confirm.frame.maxY > popupScroll.frame.maxY { popupScroll.swipeUp() }
        XCTAssertTrue(confirm.isHittable)
        XCTAssertGreaterThanOrEqual(confirm.frame.minX, 0)
        XCTAssertLessThanOrEqual(confirm.frame.maxX, app.frame.width)
        XCTAssertLessThanOrEqual(confirm.frame.maxY, popupScroll.frame.maxY)
        saveScreenshot(app, name: "Scrollable confirmation at accessibility text size")
        let cancel = app.buttons["Keep History"]
        for _ in 0..<5 where !cancel.isHittable { app.swipeDown() }
        XCTAssertTrue(cancel.isHittable)
        cancel.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 3))
    }

    func testSimilarPreviewPreservesReadOnlyReviewedSiblings() {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-testing", "--comparison-fixtures"]
        app.launch()
        XCTAssertTrue(app.buttons["Type"].waitForExistence(timeout: 5))
        app.buttons["Type"].tap()
        let screenshots = app.buttons["group-row-type:screenshots"]
        XCTAssertTrue(screenshots.waitForExistence(timeout: 5))
        screenshots.tap()
        app.buttons["clean-selected"].tap()
        for _ in 0..<2 {
            let keep = app.buttons["decision-keep"]
            XCTAssertTrue(keep.waitForExistence(timeout: 3))
            XCTAssertTrue(waitUntilEnabled(keep))
            keep.tap()
        }
        XCTAssertTrue(app.buttons["Back to library"].waitForExistence(timeout: 3))
        app.buttons["Back to library"].tap()
        let similar = app.buttons["group-row-type:similarPhotos"]
        XCTAssertTrue(similar.waitForExistence(timeout: 3))
        similar.tap()
        app.buttons["clean-selected"].tap()
        let preview = app.buttons["comparison-preview-demo-1"]
        XCTAssertTrue(preview.waitForExistence(timeout: 3))
        preview.tap()
        XCTAssertTrue(app.staticTexts["comparison-viewer-read-only"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.staticTexts["comparison-viewer-read-only"].label, "Previously kept")
        XCTAssertFalse(app.buttons["comparison-viewer-toggle"].exists)
        app.buttons["comparison-viewer-previous"].tap()
        XCTAssertTrue(app.buttons["comparison-viewer-toggle"].waitForExistence(timeout: 3))
        app.buttons["comparison-viewer-toggle"].tap()
        app.buttons["comparison-viewer-next"].tap()
        XCTAssertFalse(app.buttons["comparison-viewer-toggle"].exists)
        saveScreenshot(app, name: "Previously reviewed similar sibling remains read only")
        app.buttons["close-media-viewer"].tap()
        XCTAssertFalse(app.buttons["comparison-delete-demo-1"].exists)
        XCTAssertEqual(app.buttons["comparison-delete-demo-4"].value as? String, "Selected to delete")
    }

    func testSimilarPreviewShareSheetReturnsToSavedChoice() {
        let app = XCUIApplication()
        app.launchArguments.append("--ui-testing")
        app.launch()
        XCTAssertTrue(app.buttons["Type"].waitForExistence(timeout: 5))
        app.buttons["Type"].tap()
        let similar = app.buttons["group-row-type:similarPhotos"]
        XCTAssertTrue(similar.waitForExistence(timeout: 5))
        similar.tap()
        app.buttons["clean-selected"].tap()
        let preview = app.buttons["comparison-preview-demo-1"]
        XCTAssertTrue(preview.waitForExistence(timeout: 3))
        preview.tap()
        let toggle = app.buttons["comparison-viewer-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 3))
        toggle.tap()
        let share = app.buttons["share-media"]
        XCTAssertTrue(share.waitForExistence(timeout: 3))
        share.tap()
        let close = app.buttons["header.closeButton"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        saveScreenshot(app, name: "Similar preview with system share sheet")
        let closeIsHittable = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hittable == true"), object: close
        )
        XCTAssertEqual(XCTWaiter.wait(for: [closeIsHittable], timeout: 5), .completed)
        close.tap()
        XCTAssertTrue(toggle.waitForExistence(timeout: 3))
        XCTAssertEqual(toggle.value as? String, "Selected to delete")
        XCTAssertEqual(app.staticTexts["comparison-viewer-position"].label, "1 of 2")
        saveScreenshot(app, name: "Similar preview status bar after share dismissal")
        app.buttons["close-media-viewer"].tap()
        XCTAssertTrue(app.buttons["comparison-confirm"].waitForExistence(timeout: 3))
        saveScreenshot(app, name: "Comparison status bar after preview dismissal")
    }

    private func saveScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func waitUntilEnabled(_ element: XCUIElement) -> Bool {
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: element)
        return XCTWaiter.wait(for: [enabled], timeout: 3) == .completed
    }

    private func waitUntilHittable(_ element: XCUIElement) -> Bool {
        let hittable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: element)
        return XCTWaiter.wait(for: [hittable], timeout: 3) == .completed
    }

    private func waitForValue(_ element: XCUIElement, _ value: String) -> Bool {
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: element)
        return XCTWaiter.wait(for: [selected], timeout: 3) == .completed
    }
}
