import AVFoundation
import Foundation
import PhotosUI
import SwiftData
import Testing
import UIKit
@testable import RollSlash

@MainActor
@Suite("Cleanup flow")
struct AppModelTests {
    @Test("cleanup header tallies stay fast with a large action history")
    func cachedHeaderTallies() throws {
        let model = try makeHarness().model
        let sessionID = UUID()
        let history = (0..<5_000).map { index in
            CleanupActionRecord(sessionIdentifier: sessionID, sequence: index, assetIdentifier: "history-\(index)",
                decision: index.isMultiple(of: 2) ? .keep : .deletePending, isApplied: !index.isMultiple(of: 3))
        }
        model.actions = history
        let expectedKept = history.filter { $0.isApplied && $0.decision == .keep }.count
        let expectedDeleted = history.filter { $0.isApplied && $0.decision == .deletePending }.count
        #expect(model.keptCount == expectedKept)
        #expect(model.deleteCount == expectedDeleted)

        let cachedStart = ContinuousClock.now
        var cachedTotal = 0
        for _ in 0..<50 { cachedTotal += model.keptCount + model.deleteCount }
        let cachedDuration = cachedStart.duration(to: .now)
        let scanStart = ContinuousClock.now
        var scannedTotal = 0
        for _ in 0..<50 {
            scannedTotal += history.filter { $0.isApplied && $0.decision == .keep }.count
            scannedTotal += history.filter { $0.isApplied && $0.decision == .deletePending }.count
        }
        let scanDuration = scanStart.duration(to: .now)
        #expect(cachedTotal == scannedTotal)
        print("5,000-action header, 50 refreshes: cached \(cachedDuration), history scans \(scanDuration)")
        #expect(cachedDuration * 5 < scanDuration)

        model.actions.removeLast()
        #expect(model.keptCount == expectedKept)
        #expect(model.deleteCount == expectedDeleted - 1)
        model.actions = []
        #expect(model.keptCount == 0)
        #expect(model.deleteCount == 0)
    }

    @Test("horizontal swipes commit and vertical drags do not")
    func swipeCommitRules() {
        #expect(CleanupSwipe.decision(translation: CGSize(width: 120, height: 10), predictedEnd: CGSize(width: 120, height: 10)) == .keep)
        #expect(CleanupSwipe.decision(translation: CGSize(width: -120, height: 10), predictedEnd: CGSize(width: -120, height: 10)) == .deletePending)
        #expect(CleanupSwipe.decision(translation: CGSize(width: 80, height: 140), predictedEnd: CGSize(width: 200, height: 20)) == nil)
        #expect(CleanupSwipe.decision(translation: CGSize(width: 40, height: 8), predictedEnd: CGSize(width: 180, height: 8)) == .keep)
        #expect(CleanupSwipe.decision(translation: CGSize(width: 10, height: 0), predictedEnd: CGSize(width: 220, height: 0)) == nil)
    }

    @Test("comparison context copy distinguishes keep, delete, and photos outside this cleanup")
    func comparisonContextCopy() {
        #expect(ComparisonContextCopy.label(for: .deletePending) == String(localized: "Previously marked to delete"))
        #expect(ComparisonContextCopy.label(for: .keep) == String(localized: "Previously kept"))
        #expect(ComparisonContextCopy.label(for: nil) == String(localized: "Not in this cleanup"))
    }

    @Test("undo, redo, and branch replacement keep counts consistent")
    func undoRedo() async throws {
        let harness = try makeHarness()
        await harness.model.start()
        let january = try #require(harness.model.monthGroups.first { $0.key.value == "2026-01" })
        harness.model.toggleSelection(january)
        harness.model.beginSelectedCleanup()

        #expect(harness.model.sessionTotal == 2)
        await harness.model.decide(.keep)
        #expect(harness.model.keptCount == 1)
        harness.model.undo()
        #expect(harness.model.keptCount == 0)
        #expect(harness.model.canRedo)
        await harness.model.redo()
        #expect(harness.model.keptCount == 1)
        harness.model.undo()
        await harness.model.decide(.deletePending)
        #expect(!harness.model.canRedo)
        #expect(harness.model.deleteCount == 1)
    }

    @Test("finishing a partial keep-only session preserves undecided items")
    func finishPartialKeepOnlySession() async throws {
        let harness = try makeHarness()
        await harness.model.start()
        let january = try #require(harness.model.monthGroups.first { $0.key.value == "2026-01" })
        harness.model.toggleSelection(january)
        harness.model.beginSelectedCleanup()

        let keptID = try #require(harness.model.currentAsset?.id)
        await harness.model.decide(.keep)
        #expect(harness.model.sessionRemaining == 1)
        await harness.model.finishCurrentSession()

        #expect(harness.model.route == .dashboard)
        #expect(harness.model.activeSession == nil)
        let unfinishedJanuary = try #require(harness.model.monthGroups.first { $0.key.value == "2026-01" })
        #expect(unfinishedJanuary.unresolvedCount == 1)
        harness.model.toggleSelection(unfinishedJanuary)
        harness.model.beginSelectedCleanup()
        #expect(harness.model.sessionTotal == 1)
        #expect(harness.model.currentAsset?.id != keptID)
    }

    @Test("review decisions are global across grouping modes")
    func globalDecisions() async throws {
        let harness = try makeHarness()
        await harness.model.start()
        let january = try #require(harness.model.monthGroups.first { $0.key.value == "2026-01" })
        harness.model.toggleSelection(january)
        harness.model.beginSelectedCleanup()
        await harness.model.decide(.keep)
        await harness.model.decide(.keep)

        #expect(harness.model.route == .completion)
        let noLocation = try #require(harness.model.locationGroups.first { $0.key.value == "no-location" })
        #expect(noLocation.totalCount == 3)
        #expect(noLocation.unresolvedCount == 1)
    }

    @Test("failed deletion preserves review state for retry")
    func deletionRetry() async throws {
        let harness = try makeHarness(failDeletion: true)
        await harness.model.start()
        let february = try #require(harness.model.monthGroups.first { $0.key.value == "2026-02" })
        harness.model.toggleSelection(february)
        harness.model.beginSelectedCleanup()
        await harness.model.decide(.deletePending)

        #expect(harness.model.route == .review)
        await harness.model.commitDeletion()
        #expect(harness.model.route == .review)
        #expect(harness.model.activeSession?.status == .reviewing)
        #expect(harness.model.errorMessage != nil)

        harness.client.shouldFailDeletion = false
        harness.model.errorMessage = nil
        await harness.model.commitDeletion()
        #expect(harness.model.route == .completion)
        #expect(harness.model.activeSession == nil)
        #expect(harness.client.deletedIdentifiers == ["feb"])
    }

    @Test("a submitted deletion reconciles from the Photos library before resuming")
    func deletionRecovery() async throws {
        let harness = try makeHarness()
        await harness.model.start()
        let february = try #require(harness.model.monthGroups.first { $0.key.value == "2026-02" })
        harness.model.toggleSelection(february)
        harness.model.beginSelectedCleanup()
        await harness.model.decide(.deletePending)
        let session = try #require(harness.model.activeSession)
        session.status = .deleting
        harness.client.assets.removeAll { $0.id == "feb" }

        await harness.model.refreshAuthorization()

        #expect(harness.model.activeSession == nil)
        #expect(harness.model.route == .completion)
    }

    @Test("review undo preserves earlier items explicitly kept in final review")
    func reviewUndoPreservesKeeps() async throws {
        let harness = try makeHarness()
        await harness.model.start()
        let january = try #require(harness.model.monthGroups.first { $0.key.value == "2026-01" })
        harness.model.toggleSelection(january)
        harness.model.beginSelectedCleanup()
        await harness.model.decide(.deletePending)
        await harness.model.decide(.deletePending)
        harness.model.toggleReviewSelection("jan-new")

        harness.model.undoLastSwipeFromReview()

        #expect(harness.model.route == .cleanup)
        #expect(harness.model.decisionsByAssetID["jan-new"] == .keep)
        #expect(harness.model.keptCount == 1)
        await harness.model.decide(.keep)
        #expect(harness.model.route == .completion)
        #expect(harness.client.deletionCallCount == 0)
    }

    @Test("review undo and redo retain the edited deletion selection")
    func reviewUndoRedoPreservesSelection() async throws {
        let harness = try makeHarness()
        await harness.model.start()
        let january = try #require(harness.model.monthGroups.first { $0.key.value == "2026-01" })
        harness.model.toggleSelection(january)
        harness.model.beginSelectedCleanup()
        await harness.model.decide(.deletePending)
        await harness.model.decide(.deletePending)
        harness.model.toggleReviewSelection("jan-new")
        harness.model.undoLastSwipeFromReview()
        await harness.model.redo()
        #expect(harness.model.reviewSelectedIDs == ["jan-old"])
        await harness.model.commitDeletion()
        #expect(harness.client.deletedIdentifiers == ["jan-old"])
        #expect(harness.client.assets.contains { $0.id == "jan-new" })
    }

    @Test("hidden photos cannot be counted as recovered deletions")
    func deletionRecoveryPreservesHiddenPhotos() async throws {
        let harness = try makeHarness()
        await harness.model.start()
        let february = try #require(harness.model.monthGroups.first { $0.key.value == "2026-02" })
        harness.model.toggleSelection(february)
        harness.model.beginSelectedCleanup()
        await harness.model.decide(.deletePending)
        let session = try #require(harness.model.activeSession)
        session.status = .deleting
        let originalAssets = harness.client.assets
        harness.client.hiddenAssetIDs = ["feb"]
        harness.client.assets.removeAll { $0.id == "feb" }

        await harness.model.refreshAuthorization()

        #expect(harness.model.activeSession?.identifier == session.identifier)
        #expect(session.status == .deleting)
        #expect(harness.model.reviewSelectedIDs == ["feb"])
        #expect(harness.model.lifetimeCleanupSummary == .zero)
        #expect(harness.model.route == .dashboard)
        #expect(harness.client.deletionCallCount == 0)

        harness.client.hiddenAssetIDs = []
        harness.client.assets = originalAssets
        await harness.model.refreshAuthorization()
        #expect(session.status == .reviewing)
        #expect(harness.model.canEditReview)
        await harness.model.commitDeletion()
        #expect(harness.model.lifetimeCleanupSummary.itemCount == 1)
    }

    @Test("failed existence verification leaves a submitted deletion untouched")
    func deletionRecoveryVerificationFailure() async throws {
        let harness = try makeHarness()
        await harness.model.start()
        let february = try #require(harness.model.monthGroups.first { $0.key.value == "2026-02" })
        harness.model.toggleSelection(february)
        harness.model.beginSelectedCleanup()
        await harness.model.decide(.deletePending)
        let session = try #require(harness.model.activeSession)
        session.status = .deleting
        harness.client.shouldFailVerification = true
        harness.client.assets.removeAll { $0.id == "feb" }
        await harness.model.refreshAuthorization()
        #expect(session.status == .deleting)
        #expect(harness.model.activeSession != nil)
        #expect(harness.model.reviewSelectedIDs == ["feb"])
        #expect(harness.model.lifetimeCleanupSummary == .zero)
        #expect(harness.model.libraryLoadError != nil)
    }

    @Test("full access preserves decisions for photos hidden from the dashboard")
    func hiddenPhotosPreserveDecisions() async throws {
        let harness = try makeHarness()
        await harness.model.start()
        let originalAssets = harness.client.assets
        let january = try #require(harness.model.monthGroups.first { $0.key.value == "2026-01" })
        harness.model.toggleSelection(january)
        harness.model.beginSelectedCleanup()
        await harness.model.decide(.keep)
        harness.client.hiddenAssetIDs = ["jan-new"]
        harness.client.assets.removeAll { $0.id == "jan-new" }
        await harness.model.reloadLibrary()
        #expect(harness.model.decisionsByAssetID["jan-new"] == .keep)
        harness.client.hiddenAssetIDs = []
        harness.client.assets = originalAssets
        await harness.model.reloadLibrary()
        let restoredJanuary = try #require(harness.model.monthGroups.first { $0.key.value == "2026-01" })
        #expect(restoredJanuary.unresolvedCount == 1)
    }

    @Test("review selection supports keep all and select all")
    func reviewSelection() async throws {
        let harness = try makeHarness()
        await harness.model.start()
        let february = try #require(harness.model.monthGroups.first { $0.key.value == "2026-02" })
        harness.model.toggleSelection(february)
        harness.model.beginSelectedCleanup()
        await harness.model.decide(.deletePending)

        #expect(harness.model.reviewSelectedIDs == ["feb"])
        harness.model.keepAllFromReview()
        #expect(harness.model.reviewSelectedIDs.isEmpty)
        harness.model.selectAllForDeletion()
        #expect(harness.model.reviewSelectedIDs == ["feb"])
        harness.model.keepAllFromReview()
        await harness.model.commitDeletion()

        #expect(harness.client.deletedIdentifiers.isEmpty)
        #expect(harness.model.route == .completion)
    }

    @Test("live deletion remains locked through refresh and review mutations", arguments: [false, true])
    func liveDeletionIsLocked(suspendAtDeletion: Bool) async throws {
        let harness = try makeHarness()
        await harness.model.start()
        let february = try #require(harness.model.monthGroups.first { $0.key.value == "2026-02" })
        harness.model.toggleSelection(february)
        harness.model.beginSelectedCleanup()
        await harness.model.decide(.deletePending)
        let session = try #require(harness.model.activeSession)
        harness.client.suspendEstimates = !suspendAtDeletion
        harness.client.suspendDeletions = suspendAtDeletion
        let commit = Task { await harness.model.commitDeletion() }
        await harness.client.waitForSuspendedOperation()

        await harness.model.refreshAuthorization()
        #expect(session.status == .deleting)
        #expect(!harness.model.canEditReview)
        harness.model.toggleReviewSelection("feb")
        harness.model.keepAllFromReview()
        harness.model.selectAllForDeletion()
        harness.model.undoLastSwipeFromReview()
        await harness.model.discardActiveSession()
        let reset = await harness.model.resetHistory()
        #expect(!reset)
        await harness.model.commitDeletion()
        #expect(harness.model.isDeleting)
        #expect(harness.model.activeSession?.identifier == session.identifier)
        #expect(session.reviewSelectedIDs == ["feb"])
        #expect(harness.model.decisionsByAssetID["feb"] == .deletePending)

        harness.client.resumeOperation()
        await commit.value
        #expect(!harness.model.isDeleting)
        #expect(harness.model.activeSession == nil)
        #expect(harness.client.deletedIdentifiers == ["feb"])
        #expect(harness.client.deletionCallCount == 1)
        #expect(harness.model.route == .completion)
    }

    @Test("library changes during a cancelled deletion reload after the deletion lock is released")
    func cancelledDeletionDrainsLibraryChanges() async throws {
        let harness = try makeHarness()
        await harness.model.start()
        let group = try #require(harness.model.monthGroups.first { $0.key.value == "2026-02" })
        harness.model.toggleSelection(group)
        harness.model.beginSelectedCleanup()
        await harness.model.decide(.deletePending)
        let fetches = harness.client.fetchCallCount
        harness.client.suspendEstimates = true
        let commit = Task { await harness.model.commitDeletion() }
        await harness.client.waitForSuspendedOperation()
        let newAsset = makeAsset(id: "synced-during-deletion", date: Date())
        harness.client.assets.append(newAsset)
        harness.client.onLibraryChange?()
        #expect(harness.client.fetchCallCount == fetches)
        harness.client.shouldFailDeletion = true
        harness.client.resumeOperation()
        await commit.value
        let deadline = ContinuousClock.now + .seconds(5)
        while harness.model.assetIndex[newAsset.id] == nil, ContinuousClock.now < deadline { await Task.yield() }
        #expect(harness.client.fetchCallCount == fetches + 1)
        #expect(harness.model.assetIndex[newAsset.id] != nil)
        #expect(!harness.model.isDeleting)
        #expect(harness.model.activeSession?.status == .reviewing)
        #expect(harness.client.deletedIdentifiers.isEmpty)
    }

    @Test("limited access preserves a submitted deletion until full-access recovery")
    func limitedDeletionRecovery() async throws {
        let harness = try makeHarness()
        await harness.model.start()
        let february = try #require(harness.model.monthGroups.first { $0.key.value == "2026-02" })
        harness.model.toggleSelection(february)
        harness.model.beginSelectedCleanup()
        await harness.model.decide(.deletePending)
        let session = try #require(harness.model.activeSession)
        session.status = .deleting
        let fullLibrary = harness.client.assets
        harness.client.permission = .limited
        harness.client.assets.removeAll { $0.id == "feb" }

        await harness.model.refreshAuthorization()
        await harness.model.discardActiveSession()
        #expect(session.status == .deleting)
        #expect(session.reviewSelectedIDs == ["feb"])
        #expect(session.orderedAssetIDs == ["feb"])
        #expect(harness.model.activeSession?.identifier == session.identifier)

        harness.client.permission = .full
        harness.client.assets = fullLibrary
        await harness.model.refreshAuthorization()
        #expect(session.status == .reviewing)
        #expect(harness.model.reviewSelectedIDs == ["feb"])
        #expect(harness.model.canEditReview)
        #expect(harness.client.deletionCallCount == 0)
    }

    @Test("returning to the foreground skips an unchanged library and favoriting does not reload mid-cleanup")
    func foregroundAndFavoriteSkipFullReload() async throws {
        let harness = try makeHarness()
        await harness.model.start()
        let fetches = harness.client.fetchCallCount
        await harness.model.refreshForForeground()
        #expect(harness.client.fetchCallCount == fetches)

        let january = try #require(harness.model.monthGroups.first { $0.key.value == "2026-01" })
        harness.model.toggleSelection(january)
        harness.model.beginSelectedCleanup()
        try await harness.model.setFavorite(true, for: "jan-new")
        #expect(harness.model.assetIndex["jan-new"]?.isFavorite == true)
        #expect(harness.client.fetchCallCount == fetches)
        #expect(harness.model.route == .cleanup)

        await harness.model.refreshForForeground()
        #expect(harness.client.fetchCallCount == fetches + 1)
        #expect(harness.model.assetIndex["jan-new"]?.isFavorite == true)
    }

    @Test("coalesced library changes drain after a favorite update while staying in the foreground")
    func coalescedChangesDrainInTheForeground() async throws {
        let harness = try makeHarness()
        await harness.model.start()
        let initialFetches = harness.client.fetchCallCount
        harness.client.suspendFetches = true
        try await harness.model.setFavorite(true, for: "jan-new")
        harness.client.assets.append(makeAsset(id: "new-photo", date: .now))
        harness.client.onLibraryChange?()

        await harness.client.waitForPendingFetches(1)
        #expect(harness.client.fetchCallCount == initialFetches + 1)
        harness.client.suspendFetches = false
        harness.client.finishFetch(at: 0, returning: harness.client.assets)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while harness.model.isLoading && clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!harness.model.isLoading)
        #expect(harness.model.assetIndex["new-photo"] != nil)
    }

    @Test("a library reload clears coalesced callbacks without another foreground fetch")
    func reloadDrainsCoalescedChanges() async throws {
        let harness = try makeHarness()
        await harness.model.start()
        try await harness.model.setFavorite(true, for: "jan-new")
        await harness.model.reloadLibrary()
        let fetches = harness.client.fetchCallCount
        await harness.model.refreshForForeground()
        #expect(harness.client.fetchCallCount == fetches)
    }

    @Test("favorite reads reuse loaded metadata and local favorite changes")
    func favoriteMetadataCache() async throws {
        let harness = try makeHarness()
        await harness.model.start()
        #expect(await harness.model.isFavorite("jan-new") == false)
        try await harness.model.setFavorite(true, for: "jan-new")
        #expect(await harness.model.isFavorite("jan-new") == true)
        #expect(harness.client.favoriteLookupCount == 0)
    }

    @Test("location lookup pauses in the background and resumes without refetching Photos")
    func locationLookupResumesInForeground() async throws {
        let resolver = SuspendedLocationResolver()
        let harness = try makeHarness(locationResolver: resolver)
        harness.client.assets = [PhotoAssetDescriptor(
            id: "located-photo", creationDate: .now,
            coordinate: GeoCoordinate(latitude: 13.7563, longitude: 100.5018),
            mediaKind: .photo, duration: 0, pixelWidth: 100, pixelHeight: 100
        )]
        await harness.model.start()
        harness.model.setForeground(false)
        harness.model.grouping = .location
        await harness.model.reloadLibrary()
        #expect(await resolver.requestCount == 0)
        let fetches = harness.client.fetchCallCount

        harness.model.setForeground(true)
        try #require(await resolver.waitForRequest(count: 1))
        harness.model.setForeground(false)
        await resolver.finish(with: ResolvedLocation(city: "Discarded", country: "Thailand"))
        harness.model.setForeground(true)
        try #require(await resolver.waitForRequest(count: 2))
        await resolver.finish(with: ResolvedLocation(city: "Bangkok", country: "Thailand"))
        let deadline = ContinuousClock.now + .seconds(5)
        while !harness.model.locationGroups.contains(where: { $0.title == "Bangkok" }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(harness.model.locationGroups.contains { $0.title == "Bangkok" })
        #expect(!harness.model.locationGroups.contains { $0.title == "Discarded" })
        #expect(harness.client.fetchCallCount == fetches)
    }

    @Test("removed groups do not leave a selected empty cleanup on the dashboard")
    func removedGroupsClearSelection() async throws {
        let harness = try makeHarness()
        await harness.model.start()
        let january = try #require(harness.model.monthGroups.first { $0.key.value == "2026-01" })
        harness.model.toggleSelection(january)
        harness.client.assets.removeAll { january.assetIDs.contains($0.id) }
        await harness.model.reloadLibrary()
        #expect(harness.model.selectedGroupIDs.isEmpty)
        #expect(harness.model.selectedCandidateCount == 0)
    }

    @Test("a failed initial library load can be retried without a stale error")
    func failedLibraryLoadRetries() async throws {
        let harness = try makeHarness()
        harness.client.shouldFailFetch = true
        await harness.model.start()
        #expect(harness.model.libraryLoadError != nil)
        #expect(!harness.model.isLoading)
        #expect(harness.model.visibleGroups.isEmpty)
        harness.client.shouldFailFetch = false
        await harness.model.reloadLibrary()
        #expect(harness.model.libraryLoadError == nil)
        #expect(harness.model.errorMessage == nil)
        #expect(harness.model.assets.count == 3)
    }

    @Test("permission changes refresh and clear inaccessible dashboard state")
    func permissionRefresh() async throws {
        let harness = try makeHarness()
        await harness.model.start()
        #expect(harness.model.assets.count == 3)

        harness.client.permission = .limited
        await harness.model.refreshAuthorization()
        #expect(harness.model.isPartialAccess)
        #expect(harness.model.assets.count == 3)

        harness.client.permission = .denied
        await harness.model.refreshAuthorization()
        #expect(harness.model.assets.isEmpty)
        #expect(harness.model.monthGroups.isEmpty)
        #expect(harness.model.route == .dashboard)
    }

    @Test("a stale library fetch cannot replace a newer reload")
    func overlappingReloads() async throws {
        let harness = try makeHarness()
        await harness.model.start()
        harness.client.suspendFetches = true
        let oldAssets = harness.client.assets
        let newerAssets = oldAssets.filter { $0.id == "feb" }

        let older = Task { await harness.model.reloadLibrary() }
        await harness.client.waitForPendingFetches(1)
        let newer = Task { await harness.model.reloadLibrary() }
        await harness.client.waitForPendingFetches(2)

        harness.client.finishFetch(at: 1, returning: newerAssets)
        await newer.value
        harness.client.finishFetch(at: 0, returning: oldAssets)
        await older.value
        #expect(harness.model.assets.map(\.id) == ["feb"])
        #expect(harness.model.monthGroups.count == 1)
        #expect(!harness.model.isLoading)
    }

    @Test("revoked access invalidates an in-flight library fetch")
    func revokedAccessDuringReload() async throws {
        let harness = try makeHarness()
        await harness.model.start()
        harness.client.suspendFetches = true
        let reload = Task { await harness.model.reloadLibrary() }
        await harness.client.waitForPendingFetches(1)

        harness.client.permission = .denied
        await harness.model.refreshAuthorization()
        harness.client.finishFetch(at: 0, returning: harness.client.assets)
        await reload.value
        #expect(harness.model.assets.isEmpty)
        #expect(harness.model.monthGroups.isEmpty)
        #expect(!harness.model.isLoading)
    }

    @Test("groups cannot be selected while another cleanup is active")
    func activeSessionBlocksSelection() async throws {
        let harness = try makeHarness()
        await harness.model.start()
        let january = try #require(harness.model.monthGroups.first { $0.key.value == "2026-01" })
        let february = try #require(harness.model.monthGroups.first { $0.key.value == "2026-02" })
        harness.model.toggleSelection(january)
        harness.model.beginSelectedCleanup()
        let selectedBefore = harness.model.selectedGroupIDs
        harness.model.toggleSelection(february)
        #expect(harness.model.selectedGroupIDs == selectedBefore)
    }

    @Test("limited access does not purge hidden asset decisions")
    func limitedAccessPreservesDecisions() async throws {
        let harness = try makeHarness()
        await harness.model.start()
        let originalAssets = harness.client.assets
        let january = try #require(harness.model.monthGroups.first { $0.key.value == "2026-01" })
        harness.model.toggleSelection(january)
        harness.model.beginSelectedCleanup()
        await harness.model.decide(.keep)

        harness.client.permission = .limited
        harness.client.assets = originalAssets.filter { $0.id == "feb" }
        await harness.model.refreshAuthorization()

        harness.client.permission = .full
        harness.client.assets = originalAssets
        await harness.model.refreshAuthorization()
        let restoredJanuary = try #require(harness.model.monthGroups.first { $0.key.value == "2026-01" })
        #expect(restoredJanuary.unresolvedCount == 1)
    }

    @Test("new historical media invalidates a cleaned group")
    func historicalImportInvalidatesCompletion() async throws {
        let harness = try makeHarness()
        await harness.model.start()
        let january = try #require(harness.model.monthGroups.first { $0.key.value == "2026-01" })
        harness.model.toggleSelection(january)
        harness.model.beginSelectedCleanup()
        await harness.model.decide(.keep)
        await harness.model.decide(.keep)
        #expect(harness.model.monthGroups.first { $0.key.value == "2026-01" }?.isCleaned == true)

        let calendar = Calendar(identifier: .gregorian)
        harness.client.assets.append(makeAsset(
            id: "jan-import",
            date: calendar.date(from: DateComponents(year: 2026, month: 1, day: 10))!
        ))
        await harness.model.reloadLibrary()

        let updatedJanuary = try #require(harness.model.monthGroups.first { $0.key.value == "2026-01" })
        #expect(!updatedJanuary.isCleaned)
        #expect(updatedJanuary.unresolvedCount == 1)
    }

    @Test("a cleaned group can be selected to review every accessible item again")
    func cleanedGroupReviewAgain() async throws {
        let harness = try makeHarness()
        await harness.model.start()

        let january = try #require(harness.model.monthGroups.first { $0.key.value == "2026-01" })
        harness.model.toggleSelection(january)
        harness.model.beginSelectedCleanup()
        await harness.model.decide(.keep)
        await harness.model.decide(.keep)
        harness.model.finishCompletion()

        let cleanedJanuary = try #require(harness.model.monthGroups.first { $0.key.value == "2026-01" })
        #expect(cleanedJanuary.isCleaned)
        harness.model.toggleSelection(cleanedJanuary)
        #expect(harness.model.selectedCandidateCount == 2)
        harness.model.beginSelectedCleanup()
        #expect(harness.model.sessionTotal == 2)
    }

    @Test("cleaned and unfinished groups use the correct mixed candidate policy")
    func mixedCandidatePolicy() async throws {
        let harness = try makeHarness()
        await harness.model.start()

        let january = try #require(harness.model.monthGroups.first { $0.key.value == "2026-01" })
        harness.model.toggleSelection(january)
        harness.model.beginSelectedCleanup()
        await harness.model.decide(.keep)
        await harness.model.decide(.keep)
        harness.model.finishCompletion()

        let cleanedJanuary = try #require(harness.model.monthGroups.first { $0.key.value == "2026-01" })
        let february = try #require(harness.model.monthGroups.first { $0.key.value == "2026-02" })
        harness.model.toggleSelection(cleanedJanuary)
        harness.model.toggleSelection(february)
        #expect(harness.model.selectedCandidateCount == 3)
        harness.model.beginSelectedCleanup()
        #expect(harness.model.sessionTotal == 3)
    }

    @Test("undo and discard restore decisions that existed before review again")
    func reviewAgainRestoresBaseline() async throws {
        let harness = try makeHarness()
        await harness.model.start()

        let january = try #require(harness.model.monthGroups.first { $0.key.value == "2026-01" })
        harness.model.toggleSelection(january)
        harness.model.beginSelectedCleanup()
        await harness.model.decide(.keep)
        await harness.model.decide(.keep)
        harness.model.finishCompletion()

        let cleanedJanuary = try #require(harness.model.monthGroups.first { $0.key.value == "2026-01" })
        harness.model.toggleSelection(cleanedJanuary)
        harness.model.beginSelectedCleanup()
        await harness.model.decide(.deletePending)

        let repository = SwiftDataCleanupRepository(container: harness.container)
        #expect(try repository.decision(for: "jan-new") == .deletePending)
        harness.model.undo()
        #expect(try repository.decision(for: "jan-new") == .keep)
        await harness.model.redo()
        #expect(try repository.decision(for: "jan-new") == .deletePending)
        await harness.model.discardActiveSession()
        #expect(try repository.decision(for: "jan-new") == .keep)
        #expect(try repository.decision(for: "jan-old") == .keep)
    }

    @Test("baseline restoration survives app relaunch")
    func baselineSurvivesRelaunch() async throws {
        let harness = try makeHarness()
        await harness.model.start()

        let january = try #require(harness.model.monthGroups.first { $0.key.value == "2026-01" })
        harness.model.toggleSelection(january)
        harness.model.beginSelectedCleanup()
        await harness.model.decide(.keep)
        await harness.model.decide(.keep)
        harness.model.finishCompletion()

        let cleanedJanuary = try #require(harness.model.monthGroups.first { $0.key.value == "2026-01" })
        harness.model.toggleSelection(cleanedJanuary)
        harness.model.beginSelectedCleanup()
        await harness.model.decide(.deletePending)

        let relaunchedModel = AppModel(
            photoLibrary: harness.client,
            previewProvider: TestPreviewProvider(),
            locationResolver: TestLocationResolver(),
            modelContainer: harness.container
        )
        await relaunchedModel.start()
        #expect(relaunchedModel.activeSession != nil)
        await relaunchedModel.discardActiveSession()

        let repository = SwiftDataCleanupRepository(container: harness.container)
        #expect(try repository.decision(for: "jan-new") == .keep)
        #expect(try repository.decision(for: "jan-old") == .keep)
    }

    @Test("partial review deletes a batch and leaves the group unfinished")
    func partialReviewBatch() async throws {
        let harness = try makeHarness()
        await harness.model.start()

        let january = try #require(harness.model.monthGroups.first { $0.key.value == "2026-01" })
        harness.model.toggleSelection(january)
        harness.model.beginSelectedCleanup()
        await harness.model.decide(.deletePending)
        #expect(harness.model.reviewCandidateIDs == ["jan-new"])

        harness.model.reviewCurrentBatch()
        #expect(harness.model.activeSession?.status == .reviewing)
        #expect(harness.model.route == .review)

        await harness.model.commitDeletion()

        #expect(harness.model.activeSession == nil)
        #expect(harness.model.route == .dashboard)
        #expect(!harness.client.assets.contains { $0.id == "jan-new" })
        let remainingJanuary = try #require(harness.model.monthGroups.first { $0.key.value == "2026-01" })
        #expect(remainingJanuary.totalCount == 1)
        #expect(remainingJanuary.unresolvedCount == 1)
        #expect(!remainingJanuary.isCleaned)

        harness.model.toggleSelection(remainingJanuary)
        harness.model.beginSelectedCleanup()
        #expect(harness.model.sessionTotal == 1)
    }

    @Test("deletion keeps review state when Photos access hides a selected item")
    func deletionAccessMismatchKeepsReview() async throws {
        let harness = try makeHarness()
        await harness.model.start()

        let january = try #require(harness.model.monthGroups.first { $0.key.value == "2026-01" })
        harness.model.toggleSelection(january)
        harness.model.beginSelectedCleanup()
        await harness.model.decide(.deletePending)
        harness.model.reviewCurrentBatch()
        harness.client.deletionResultOverride = []

        await harness.model.commitDeletion()

        #expect(harness.model.activeSession?.status == .reviewing)
        #expect(harness.model.route == .review)
        #expect(harness.client.assets.contains { $0.id == "jan-new" })
        #expect(harness.model.reviewSelectedIDs == Set(["jan-new"]))
    }

    @Test("dashboard scroll anchors stay separate and choose nearby surviving groups")
    func dashboardScrollAnchors() {
        var memory = DashboardScrollMemory()
        memory.reconcileMonth(["month:2026-09", "month:2020-02", "month:2020-01"])
        memory.monthID = "month:2020-02"
        memory.reconcileLocation(["location:one", "location:two", "location:three"])
        memory.locationID = "location:two"

        memory.reconcileMonth(["month:2026-09", "month:2020-03", "month:2020-01"])
        #expect(memory.monthID == "month:2020-03")
        #expect(memory.locationID == "location:two")

        memory.reconcileLocation(["location:one", "location:three"])
        #expect(memory.locationID == "location:three")
        #expect(memory.monthID == "month:2020-03")
    }

    @Test("startup shows onboarding only before the first onboarding choice")
    func startupRespectsOnboardingChoice() async throws {
        let suiteName = "AppModelTests.startup.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstLaunch = try makeHarness(permission: .notDetermined, onboardingDefaults: defaults)
        #expect(firstLaunch.model.route == .onboarding)
        #expect(!firstLaunch.model.isLoading)
        firstLaunch.model.continueWithoutAccess()

        let returningLaunch = try makeHarness(permission: .notDetermined, onboardingDefaults: defaults)
        #expect(returningLaunch.model.route == .dashboard)
        #expect(!returningLaunch.model.isLoading)
        await returningLaunch.model.start()
        #expect(returningLaunch.model.route == .dashboard)
    }

    @Test("startup uses existing Photos permission before loading the library")
    func startupUsesCurrentPhotoPermission() throws {
        let suiteName = "AppModelTests.startup.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        for permission in [PhotoPermission.full, .limited, .denied, .restricted] {
            let harness = try makeHarness(permission: permission, onboardingDefaults: defaults)
            #expect(harness.model.route == .dashboard)
            #expect(harness.model.permission == permission)
            #expect(harness.model.isLoading == permission.canRead)
            #expect(harness.client.fetchCallCount == 0)
        }
    }

    @Test("startup clears loading when Photos access changes before startup completes")
    func startupRechecksPhotoPermission() async throws {
        let suiteName = "AppModelTests.startup.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let harness = try makeHarness(onboardingDefaults: defaults)
        #expect(harness.model.isLoading)
        harness.client.permission = .denied
        await harness.model.start()
        #expect(harness.model.route == .dashboard)
        #expect(harness.model.permission == .denied)
        #expect(!harness.model.isLoading)
        #expect(harness.client.fetchCallCount == 0)
    }

    private func makeHarness(
        failDeletion: Bool = false,
        permission: PhotoPermission = .full,
        onboardingDefaults: UserDefaults = .standard,
        locationResolver: any LocationResolver = TestLocationResolver()
    ) throws -> Harness {
        let calendar = Calendar(identifier: .gregorian)
        let assets = [
            makeAsset(id: "jan-new", date: calendar.date(from: DateComponents(year: 2026, month: 1, day: 20))!),
            makeAsset(id: "jan-old", date: calendar.date(from: DateComponents(year: 2026, month: 1, day: 2))!),
            makeAsset(id: "feb", date: calendar.date(from: DateComponents(year: 2026, month: 2, day: 4))!)
        ]
        let client = TestPhotoLibraryClient(assets: assets, shouldFailDeletion: failDeletion)
        client.permission = permission
        let container = try ModelContainer(
            for: RollSlashSchema.schema,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let model = AppModel(
            photoLibrary: client,
            previewProvider: TestPreviewProvider(),
            locationResolver: locationResolver,
            modelContainer: container,
            onboardingDefaults: onboardingDefaults
        )
        return Harness(model: model, client: client, container: container)
    }

    private func makeAsset(id: String, date: Date) -> PhotoAssetDescriptor {
        PhotoAssetDescriptor(
            id: id,
            creationDate: date,
            coordinate: nil,
            mediaKind: .photo,
            duration: 0,
            pixelWidth: 100,
            pixelHeight: 100
        )
    }
}

    @MainActor
    private struct Harness {
        let model: AppModel
        let client: TestPhotoLibraryClient
        let container: ModelContainer
}

private enum TestError: Error { case deletionFailed }

@MainActor
private final class TestPhotoLibraryClient: PhotoLibraryClient {
    var onLibraryChange: (@MainActor @Sendable () -> Void)?
    var assets: [PhotoAssetDescriptor]
    var shouldFailDeletion: Bool
    var deletedIdentifiers: [String] = []
    var deletionResultOverride: Set<String>?
    var permission: PhotoPermission = .full
    var suspendFetches = false
    var shouldFailFetch = false
    var hiddenAssetIDs = Set<String>()
    var shouldFailVerification = false
    var favoriteLookupCount = 0
    var suspendEstimates = false
    var suspendDeletions = false
    var deletionCallCount = 0
    private var pendingOperation: CheckedContinuation<Void, Never>?
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []
    private var pendingFetches: [CheckedContinuation<[PhotoAssetDescriptor], Never>] = []
    private var pendingCountWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(assets: [PhotoAssetDescriptor], shouldFailDeletion: Bool) {
        self.assets = assets
        self.shouldFailDeletion = shouldFailDeletion
    }

    func authorizationStatus() -> PhotoPermission { permission }
    func requestAuthorization() async -> PhotoPermission { permission }
    private(set) var fetchCallCount = 0

    func fetchAssets() async throws -> [PhotoAssetDescriptor] {
        fetchCallCount += 1
        if shouldFailFetch { throw URLError(.cannotLoadFromNetwork) }
        if suspendFetches {
            return await withCheckedContinuation { continuation in
                pendingFetches.append(continuation)
                let ready = pendingCountWaiters.filter { pendingFetches.count >= $0.count }
                pendingCountWaiters.removeAll { pendingFetches.count >= $0.count }
                ready.forEach { $0.continuation.resume() }
            }
        }
        return assets
    }
    func waitForPendingFetches(_ count: Int) async {
        if pendingFetches.count >= count { return }
        await withCheckedContinuation { pendingCountWaiters.append((count, $0)) }
    }

    func existingAssetIdentifiers(in identifiers: Set<String>) async throws -> Set<String> {
        guard permission == .full else { throw PhotoLibraryVerificationError.fullAccessRequired }
        if shouldFailVerification { throw URLError(.cannotLoadFromNetwork) }
        return identifiers.intersection(Set(assets.map(\.id)).union(hiddenAssetIDs))
    }
    func finishFetch(at index: Int, returning assets: [PhotoAssetDescriptor]) {
        pendingFetches.remove(at: index).resume(returning: assets)
    }
    func deleteAssets(with identifiers: [String]) async throws -> Set<String> {
        if shouldFailDeletion { throw TestError.deletionFailed }
        deletionCallCount += 1
        if suspendDeletions { await suspendOperation() }
        deletedIdentifiers = identifiers
        let available = Set(assets.map(\.id))
        let deleted = Set(identifiers).intersection(available)
        let result = deletionResultOverride ?? deleted
        assets.removeAll { result.contains($0.id) }
        return result
    }
    func estimateStorageBytes(for identifiers: [String]) async -> [String: Int64] {
        if suspendEstimates { await suspendOperation() }
        return [:]
    }
    private func suspendOperation() async {
        await withCheckedContinuation { continuation in
            pendingOperation = continuation
            operationWaiters.forEach { $0.resume() }
            operationWaiters.removeAll()
        }
    }
    func waitForSuspendedOperation() async {
        if pendingOperation != nil { return }
        await withCheckedContinuation { operationWaiters.append($0) }
    }
    func resumeOperation() {
        suspendEstimates = false
        suspendDeletions = false
        pendingOperation?.resume()
        pendingOperation = nil
    }
    func isFavorite(with identifier: String) async -> Bool {
        favoriteLookupCount += 1
        return assets.first { $0.id == identifier }?.isFavorite ?? false
    }
    func setFavorite(_ favorite: Bool, for identifier: String) async throws {
        if let index = assets.firstIndex(where: { $0.id == identifier }) {
            assets[index].isFavorite = favorite
        }
        onLibraryChange?()
    }
    func presentLimitedLibraryPicker() {}
    func openSystemSettings() {}
}

@MainActor
private final class TestPreviewProvider: MediaPreviewProvider {
    func image(for identifier: String, targetSize: CGSize, kind: PreviewRequestKind) async -> UIImage? { nil }
    func livePhoto(for identifier: String, targetSize: CGSize) async -> PHLivePhoto? { nil }
    func playerItem(for identifier: String) async -> AVPlayerItem? { nil }
    func shareableVideoURL(for identifier: String) async throws -> URL? { nil }
    func startCaching(identifiers: [String], targetSize: CGSize, kind: PreviewRequestKind) {}
    func stopCachingAll() {}
}

private struct TestLocationResolver: LocationResolver {
    func resolve(_ coordinate: GeoCoordinate) async throws -> ResolvedLocation? { nil }
}

private actor SuspendedLocationResolver: LocationResolver {
    private(set) var requestCount = 0
    private var continuation: CheckedContinuation<ResolvedLocation?, Error>?

    func resolve(_ coordinate: GeoCoordinate) async throws -> ResolvedLocation? {
        requestCount += 1
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func waitForRequest(count: Int) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while requestCount < count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        return requestCount >= count
    }

    func finish(with location: ResolvedLocation) {
        continuation?.resume(returning: location)
        continuation = nil
    }
}
