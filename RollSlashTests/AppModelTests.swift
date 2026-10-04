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

    private func makeHarness(failDeletion: Bool = false) throws -> Harness {
        let calendar = Calendar(identifier: .gregorian)
        let assets = [
            makeAsset(id: "jan-new", date: calendar.date(from: DateComponents(year: 2026, month: 1, day: 20))!),
            makeAsset(id: "jan-old", date: calendar.date(from: DateComponents(year: 2026, month: 1, day: 2))!),
            makeAsset(id: "feb", date: calendar.date(from: DateComponents(year: 2026, month: 2, day: 4))!)
        ]
        let client = TestPhotoLibraryClient(assets: assets, shouldFailDeletion: failDeletion)
        let container = try ModelContainer(
            for: RollSlashSchema.schema,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let model = AppModel(
            photoLibrary: client,
            previewProvider: TestPreviewProvider(),
            locationResolver: TestLocationResolver(),
            modelContainer: container
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
    func fetchAssets() async throws -> [PhotoAssetDescriptor] {
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
    func isFavorite(with identifier: String) async -> Bool { false }
    func setFavorite(_ favorite: Bool, for identifier: String) async throws {}
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
