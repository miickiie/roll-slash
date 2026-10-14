import Foundation
import SwiftData
import Testing
@testable import RollSlash

@MainActor
@Suite("Type grouping and comparison sessions")
struct TypeGroupingTests {
    @Test("all nine types are ordered, overlap, and hide only empty categories")
    func categories() async throws {
        let harness = try makeHarness()
        await harness.model.start()
        harness.model.grouping = .type
        try await awaitAnalysis(harness.model)
        #expect(harness.model.typeGroups.map(\.key.value) == MediaTypeCategory.allCases.map(\.rawValue))
        #expect(harness.model.typeGroups.count == 9)
        #expect(!harness.model.typeGroups.contains { $0.key.value == "receipts" })
        let aGroups = harness.model.typeGroups.filter { $0.assetIDs.contains("a") }
        #expect(aGroups.count == 8)
        #expect(harness.model.typeGroups.first { $0.key.value == "videos" }?.assetIDs == ["v"])
        harness.model.toggleSelection(try #require(harness.model.typeGroups.first { $0.key.value == "similarPhotos" }))
        harness.model.toggleSelection(try #require(harness.model.typeGroups.first { $0.key.value == "screenshots" }))
        #expect(harness.model.selectedCandidateCount == 2)
        harness.library.assets.removeAll { $0.id == "a" }
        await harness.model.reloadLibrary()
        try await awaitAnalysis(harness.model)
        #expect(harness.model.typeGroups.map(\.key.value) == ["videos"])
    }

    @Test("50,000 metadata assets build Type groups without image analysis")
    func largeMetadataLibrary() {
        let assets = (0..<50_000).map { index in
            PhotoAssetDescriptor(id: String(index), creationDate: nil, coordinate: nil,
                                 mediaKind: index.isMultiple(of: 5) ? .video : .photo, duration: 0,
                                 pixelWidth: 100, pixelHeight: 100, isScreenshot: index.isMultiple(of: 3),
                                 isFavorite: index.isMultiple(of: 7))
        }
        let groups = AppModel.buildTypeGroups(assets: assets, decisions: [:], analysis: [:], similarIDs: [])
        #expect(groups.map(\.key.value) == ["screenshots", "videos", "favorites"])
        #expect(groups.first { $0.key.value == "videos" }?.totalCount == 10_000)
    }

    @Test("mixed selection reviews each asset once and comparison undo restores the whole set")
    func mixedSelectionAndUndo() async throws {
        let harness = try makeHarness()
        try await selectTypes(harness, ["similarPhotos", "screenshots", "videos"])
        harness.model.beginSelectedCleanup()
        #expect(harness.model.route == .similarComparison)
        #expect(harness.model.sessionTotal == 3)
        #expect(harness.model.activeSession?.orderedAssetIDs == ["a", "b", "v"])
        #expect(harness.model.comparisonDeleteIDs.isEmpty)
        harness.model.toggleComparisonDeletion("a")
        await harness.model.confirmComparison()
        #expect(harness.model.route == .cleanup)
        #expect(harness.model.currentAsset?.id == "v")
        #expect(harness.model.keptCount == 1)
        #expect(harness.model.deleteCount == 1)
        harness.model.undo()
        #expect(harness.model.route == .similarComparison)
        #expect(harness.model.sessionCompleted == 0)
        #expect(harness.model.comparisonDeleteIDs == ["a"])
        #expect(harness.model.decisionsByAssetID["a"] == nil)
        #expect(harness.model.decisionsByAssetID["b"] == nil)
        await harness.model.redo()
        #expect(harness.model.sessionCompleted == 2)
        #expect(harness.model.route == .cleanup)
        await harness.model.decide(.keep)
        #expect(harness.model.route == .review)
        #expect(harness.model.reviewCandidateIDs == ["a"])
    }

    @Test("drafts survive relaunch and final review undo reopens the complete comparison")
    func draftResumeAndReviewUndo() async throws {
        let harness = try makeHarness()
        try await selectTypes(harness, ["similarPhotos"])
        harness.model.beginSelectedCleanup()
        harness.model.toggleComparisonDeletion("b")
        harness.model.route = .dashboard
        let relaunched = harness.newModel()
        await relaunched.start()
        relaunched.resumeSession()
        #expect(relaunched.route == .similarComparison)
        #expect(relaunched.comparisonDeleteIDs == ["b"])
        await relaunched.confirmComparison()
        #expect(relaunched.route == .review)
        relaunched.undoLastSwipeFromReview()
        #expect(relaunched.route == .similarComparison)
        #expect(relaunched.sessionCompleted == 0)
        #expect(relaunched.keptCount == 0)
        #expect(relaunched.deleteCount == 0)
        #expect(relaunched.comparisonDeleteIDs == ["b"])
        await relaunched.redo()
        #expect(relaunched.route == .review)
        harness.library.failDeletion = true
        await relaunched.commitDeletion()
        #expect(relaunched.route == .review)
        #expect(relaunched.reviewSelectedIDs == ["b"])
        #expect(harness.library.deleted.isEmpty)
        harness.library.failDeletion = false
        await relaunched.commitDeletion()
        #expect(relaunched.route == .completion)
        #expect(harness.library.deleted == ["b"])
    }

    @Test("previous global choices remain read-only context and cleaned groups remain visible")
    func globalContext() async throws {
        let harness = try makeHarness()
        let repository = SwiftDataCleanupRepository(container: harness.container)
        try repository.setDecision(.keep, for: "a", sessionIdentifier: nil)
        try await selectTypes(harness, ["similarPhotos"])
        #expect(harness.model.selectedCandidateCount == 1)
        #expect(harness.model.typeGroups.first { $0.key.value == "screenshots" }?.isCleaned == true)
        harness.model.beginSelectedCleanup()
        #expect(harness.model.currentComparison?.assetIDs == ["b"])
        #expect(harness.model.currentComparison?.contextAssetIDs == ["a"])
        harness.model.toggleComparisonDeletion("a")
        #expect(harness.model.comparisonDeleteIDs.isEmpty)
        await harness.model.confirmComparison(keepAll: true)
        #expect(harness.model.route == .completion)
        #expect(try repository.decision(for: "a") == .keep)
        #expect(try repository.decision(for: "b") == .keep)
    }

    @Test("library changes cannot expand a frozen comparison and inaccessible members become swipe units")
    func frozenAndFilteredPlan() async throws {
        let harness = try makeHarness()
        try await selectTypes(harness, ["similarPhotos", "videos"])
        harness.model.beginSelectedCleanup()
        let c = makeAsset("c")
        harness.library.assets.append(c)
        let repository = SwiftDataCleanupRepository(container: harness.container)
        try repository.cacheAnalysis(TypeFixtureAnalysis.result, for: c)
        await harness.model.reloadLibrary()
        #expect(harness.model.similarClusters.first?.assetIDs == ["a", "b", "c"])
        #expect(harness.model.currentComparison?.assetIDs == ["a", "b"])
        #expect(harness.model.activeSession?.orderedAssetIDs == ["a", "b", "v"])
        harness.model.toggleComparisonDeletion("b")
        harness.library.assets.removeAll { $0.id == "b" }
        await harness.model.reloadLibrary()
        #expect(harness.model.route == .cleanup)
        #expect(harness.model.currentAsset?.id == "a")
        #expect(harness.model.comparisonDeleteIDs.isEmpty)
        #expect(harness.model.activeSession?.workPlan?.assetIDs == harness.model.activeSession?.orderedAssetIDs)
        #expect(harness.model.sessionCompleted == 0)
    }

    @Test("applied and undone comparisons stay aligned after a member is removed")
    func removedReviewedMember() async throws {
        for undoFirst in [false, true] {
            let harness = try makeHarness()
            try await selectTypes(harness, ["similarPhotos", "videos"])
            harness.model.beginSelectedCleanup()
            harness.model.toggleComparisonDeletion("a")
            await harness.model.confirmComparison()
            if undoFirst { harness.model.undo() }
            harness.library.assets.removeAll { $0.id == "b" }
            await harness.model.reloadLibrary()
            let session = try #require(harness.model.activeSession)
            #expect(session.orderedAssetIDs == ["a", "v"])
            #expect(session.workPlan?.assetIDs == session.orderedAssetIDs)
            #expect(session.cursor == (undoFirst ? 0 : 1))
            if undoFirst {
                await harness.model.redo()
                #expect(session.cursor == 1)
            } else {
                harness.model.undo()
                #expect(session.cursor == 0)
                #expect(harness.model.decisionsByAssetID["a"] == nil)
            }
        }
    }

    @Test("legacy sessions continue to use swipe review")
    func legacySession() async throws {
        let harness = try makeHarness()
        let repository = SwiftDataCleanupRepository(container: harness.container)
        _ = try repository.createSession(groupKind: .month, selectedGroupKeys: [], orderedAssetIDs: ["a", "b"])
        await harness.model.start()
        harness.model.resumeSession()
        #expect(harness.model.route == .cleanup)
        #expect(harness.model.currentComparison == nil)
        await harness.model.decide(.keep)
        harness.model.undo()
        #expect(harness.model.sessionCompleted == 0)
    }

    @Test("cache persists across model contexts and history reset, but invalidates content and algorithm changes")
    func cachePersistence() throws {
        let harness = try makeHarness()
        let repository = SwiftDataCleanupRepository(container: harness.container)
        let original = makeAsset("cache", modified: Date(timeIntervalSince1970: 1))
        try repository.cacheAnalysis(TypeFixtureAnalysis.result, for: original)
        let newRepository = SwiftDataCleanupRepository(container: harness.container)
        #expect(try newRepository.cachedAnalysis(for: [original])[original.id] == TypeFixtureAnalysis.result)
        try newRepository.resetHistory()
        #expect(try newRepository.cachedAnalysis(for: [original])[original.id] != nil)
        let modified = makeAsset("cache", modified: Date(timeIntervalSince1970: 2))
        #expect(try newRepository.cachedAnalysis(for: [modified]).isEmpty)
        let context = ModelContext(harness.container)
        context.insert(try MediaAnalysisCacheRecord(assetIdentifier: original.id, signature: "old-algorithm", result: TypeFixtureAnalysis.result))
        try context.save()
        #expect(try newRepository.cachedAnalysis(for: [original]).isEmpty)
    }

    @Test("leaving Type and revoking access discard stale analysis results")
    func canceledAnalysis() async throws {
        let service = SuspendedTypeAnalysis()
        let harness = try makeHarness(analysis: service)
        await harness.model.start()
        harness.model.grouping = .type
        await service.waitForRequest()
        harness.model.grouping = .month
        await service.release()
        for _ in 0..<20 { await Task.yield() }
        #expect(harness.model.analysisResults.isEmpty)
        #expect(!harness.model.isAnalyzingTypes)
        harness.library.permission = .denied
        await harness.model.refreshAuthorization()
        #expect(harness.model.typeGroups.isEmpty)
        #expect(harness.model.similarClusters.isEmpty)
    }

    @Test("full to limited to full access restores cached analysis without rescanning")
    func limitedAccessAnalysisCache() async throws {
        let service = CountingCachedAnalysis()
        let harness = try makeHarness(analysis: service)
        let repository = SwiftDataCleanupRepository(container: harness.container)
        let fullLibrary = harness.library.assets
        for asset in fullLibrary where asset.mediaKind != .video {
            try repository.cacheAnalysis(TypeFixtureAnalysis.result, for: asset)
        }
        await harness.model.start()
        harness.model.grouping = .type
        try await awaitAnalysis(harness.model)

        harness.library.permission = .limited
        harness.library.assets.removeAll { $0.id == "b" }
        await harness.model.refreshAuthorization()
        try await awaitAnalysis(harness.model)
        #expect(harness.model.analysisResults["b"] == nil)
        #expect(harness.model.similarClusters.isEmpty)

        harness.library.permission = .full
        harness.library.assets = fullLibrary
        await harness.model.refreshAuthorization()
        try await awaitAnalysis(harness.model)
        #expect(harness.model.analysisResults["b"] == TypeFixtureAnalysis.result)
        #expect(harness.model.similarClusters.first?.assetIDs == ["a", "b"])
        #expect(await service.analyzedIDs.isEmpty)
    }

    @Test("partial cache reads retain hidden records for upsert and full reads purge removed assets")
    func partialCacheUpsertAndPurge() throws {
        let harness = try makeHarness()
        let repository = SwiftDataCleanupRepository(container: harness.container)
        let a = makeAsset("a"), b = makeAsset("b")
        try repository.cacheAnalysis(TypeFixtureAnalysis.result, for: a)
        try repository.cacheAnalysis(TypeFixtureAnalysis.result, for: b)
        #expect(try repository.cachedAnalysis(for: [a], purgeMissing: false).keys.sorted() == ["a"])
        var updated = TypeFixtureAnalysis.result
        updated.isLarge = false
        try repository.cacheAnalysis(updated, for: b)
        let restored = SwiftDataCleanupRepository(container: harness.container)
        #expect(try restored.cachedAnalysis(for: [a, b])["b"] == updated)
        let records = try ModelContext(harness.container).fetch(FetchDescriptor<MediaAnalysisCacheRecord>())
        #expect(records.count == 2)
        _ = try restored.cachedAnalysis(for: [a], purgeMissing: true)
        #expect(try restored.cachedAnalysis(for: [a, b])["b"] == nil)
    }

    @Test("unavailable media remains retryable and similarity capability failures are visible")
    func unavailableAnalysis() async throws {
        let service = TypeFixtureAnalysis(unavailable: true)
        let harness = try makeHarness(analysis: service)
        await harness.model.start()
        harness.model.grouping = .type
        try await awaitAnalysis(harness.model)
        #expect(harness.model.typeAnalysisUnavailableCount == 2)
        #expect(harness.model.similarityWarning != nil)
        #expect(!harness.model.typeGroups.contains { $0.key.value == "receipts" })
        #expect(!harness.model.typeGroups.contains { $0.key.value == "similarPhotos" })
        await harness.model.reloadLibrary()
        try await awaitAnalysis(harness.model)
        #expect(harness.model.typeAnalysisCompleted == 2)
        #expect(harness.model.typeAnalysisUnavailableCount == 2)
    }

    @Test("Type scroll anchors are independent and recover from hidden groups")
    func scrollMemory() {
        var memory = DashboardScrollMemory()
        memory.monthID = "month:2026-01"
        memory.locationID = "location:bangkok"
        memory.reconcileType(["type:screenshots", "type:receipts", "type:selfies"])
        memory.typeAnchorID = "type:receipts"
        memory.reconcileType(["type:screenshots", "type:selfies"])
        #expect(memory.typeID == "type:selfies")
        #expect(memory.monthID == "month:2026-01")
        #expect(memory.locationID == "location:bangkok")
    }

    @Test("stale cluster computation cannot replace a newer library reload or revoked access")
    func staleClusters() async throws {
        let service = SuspendedClusterAnalysis()
        let harness = try makeHarness(analysis: service)
        await harness.model.start()
        await service.suspend()
        let oldReload = Task { await harness.model.reloadLibrary() }
        await service.waitForPending(1)
        harness.library.assets.removeAll { $0.id != "v" }
        let newReload = Task { await harness.model.reloadLibrary() }
        await service.waitForPending(2)
        await service.finish(at: 1)
        await newReload.value
        await service.finish(at: 0)
        await oldReload.value
        #expect(harness.model.assets.map(\.id) == ["v"])
        #expect(harness.model.similarClusters.isEmpty)

        harness.library.assets = [makeAsset("a"), makeAsset("b")]
        let revokedReload = Task { await harness.model.reloadLibrary() }
        await service.waitForPending(1)
        harness.library.permission = .denied
        await harness.model.refreshAuthorization()
        await service.finish(at: 0)
        await revokedReload.value
        #expect(harness.model.assets.isEmpty)
        #expect(harness.model.similarClusters.isEmpty)
    }

    @Test("backgrounding cancels analysis and returning resumes it without refetching the library")
    func backgroundCancellation() async throws {
        let service = SuspendedTypeAnalysis()
        let harness = try makeHarness(analysis: service)
        await harness.model.start()
        harness.model.grouping = .type
        await service.waitForRequest()
        harness.model.setForeground(false)
        await service.release()
        await harness.model.reloadLibrary()
        #expect(!harness.model.isAnalyzingTypes)
        #expect(harness.model.analysisResults.isEmpty)
        let fetches = harness.library.fetchCount
        harness.model.setForeground(true)
        await service.waitForRequest()
        #expect(harness.model.isAnalyzingTypes)
        #expect(harness.library.fetchCount == fetches)
        harness.model.setForeground(false)
        await service.release()
    }

    @Test("legacy OCR-incomplete cache is reused without scheduling another scan")
    func legacyCacheWithoutRescan() async throws {
        let harness = try makeHarness(analysis: NoAnalysisExpected())
        let context = ModelContext(harness.container)
        let legacy = Data(#"{"isLarge":false,"isReceipt":null,"featurePrint":"AQ==","perceptualHash":7,"unsupportedReceiptLanguages":["th-TH"],"similarityUnavailable":false}"#.utf8)
        for asset in harness.library.assets where asset.mediaKind != .video {
            let record = try MediaAnalysisCacheRecord(assetIdentifier: asset.id,
                signature: MediaAnalysisResult.signature(for: asset), result: MediaAnalysisResult())
            record.resultData = legacy
            context.insert(record)
        }
        try context.save()
        await harness.model.start()
        harness.model.grouping = .type
        try await awaitAnalysis(harness.model)
        #expect(harness.model.typeAnalysisCompleted == 2)
        #expect(harness.model.typeAnalysisUnavailableCount == 0)
        #expect(harness.model.analysisResults["a"]?.isComplete == true)
        #expect(harness.model.analysisResults["b"]?.isComplete == true)
        #expect(!harness.model.typeGroups.contains { $0.key.value == "receipts" })
    }

    @Test("existing sessions from the removed category retain their frozen swipe plan")
    func removedCategorySessionResumes() async throws {
        let harness = try makeHarness()
        let repository = SwiftDataCleanupRepository(container: harness.container)
        let session = try repository.createSession(groupKind: .type, selectedGroupKeys: ["type:receipts"],
                                                   orderedAssetIDs: ["a", "b"], workPlan: nil)
        await harness.model.start()
        harness.model.resumeSession()
        #expect(harness.model.activeSession?.identifier == session.identifier)
        #expect(harness.model.activeSession?.orderedAssetIDs == ["a", "b"])
        #expect(harness.model.route == .cleanup)
        #expect(harness.model.currentAsset?.id == "a")
    }

    @Test("two workers publish out of order, pass cached stages, and flush accepted work on navigation")
    func balancedConcurrencyAndResume() async throws {
        let service = ControlledBalancedAnalysis()
        let harness = try makeHarness(analysis: service)
        let repository = SwiftDataCleanupRepository(container: harness.container)
        let partial = MediaAnalysisResult(isLarge: false)
        try repository.cacheAnalysis(partial, for: harness.library.assets[0])
        await harness.model.start()
        harness.model.grouping = .type
        await service.waitForRequests(2)
        #expect(await service.peak == 2)
        #expect(await service.cachedResult(for: "a") == partial)
        await service.finish("b")
        let deadline = Date().addingTimeInterval(5)
        while harness.model.typeAnalysisCompleted == 0 && Date() < deadline { await Task.yield() }
        #expect(harness.model.typeAnalysisCompleted == 1)
        #expect(harness.model.analysisResults["b"]?.isComplete == true)
        harness.model.grouping = .month
        let saved = try SwiftDataCleanupRepository(container: harness.container).cachedAnalysis(for: harness.library.assets)
        #expect(saved["b"]?.isComplete == true)
        #expect(saved["a"] == partial)
        await service.finish("a")
        for _ in 0..<20 { await Task.yield() }
        #expect(harness.model.analysisResults["a"] == partial)
        harness.model.grouping = .type
        await service.waitForRequests(3)
        let requested = await service.requestedIDs
        #expect(Set(requested.prefix(2)) == Set(["a", "b"]))
        #expect(requested.count == 3 && requested.last == "a")
        await service.finish("a")
        try await awaitAnalysis(harness.model)
        #expect(harness.model.typeAnalysisCompleted == 2)
        #expect(harness.model.typeAnalysisUnavailableCount == 0)
        #expect(harness.model.analysisResults["a"]?.isLarge == false)
    }

    @Test("accepted results flush on the timer while another photo is still running")
    func timedCacheFlush() async throws {
        let service = ControlledBalancedAnalysis()
        let harness = try makeHarness(analysis: service)
        await harness.model.start()
        harness.model.grouping = .type
        await service.waitForRequests(2)
        await service.finish("b")
        var saved: MediaAnalysisResult?
        let deadline = Date().addingTimeInterval(5)
        while saved == nil && Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
            saved = try SwiftDataCleanupRepository(container: harness.container).cachedAnalysis(for: harness.library.assets)["b"]
        }
        #expect(saved?.isComplete == true)
        #expect(harness.model.isAnalyzingTypes)
        harness.model.setForeground(false)
        await service.finish("a")
    }

    @Test("batched analysis upserts persist independently of cleanup history")
    func batchedCache() throws {
        let harness = try makeHarness()
        let repository = SwiftDataCleanupRepository(container: harness.container)
        let assets = (0..<50).map { makeAsset("batch-\($0)") }
        try repository.cacheAnalysis(assets.map { MediaAnalysisCacheEntry(asset: $0, result: TypeFixtureAnalysis.result) })
        let negative = MediaAnalysisResult(isLarge: false, featurePrint: Data([1]), perceptualHash: 0)
        try repository.cacheAnalysis(assets.prefix(25).map { MediaAnalysisCacheEntry(asset: $0, result: negative) })
        try repository.resetHistory()
        let reloaded = SwiftDataCleanupRepository(container: harness.container)
        let saved = try reloaded.cachedAnalysis(for: assets)
        #expect(saved.count == 50)
        #expect(saved["batch-0"] == negative)
        #expect(saved["batch-49"] == TypeFixtureAnalysis.result)
        #expect(try ModelContext(harness.container).fetchCount(FetchDescriptor<MediaAnalysisCacheRecord>()) == 50)
        let modified = makeAsset("batch-0", modified: Date(timeIntervalSince1970: 4))
        #expect(try reloaded.cachedAnalysis(for: [modified]).isEmpty)
    }

    @Test("undo and redo preserve drafts in subsequent comparisons, including relaunch")
    func draftsAcrossComparisons() async throws {
        let harness = try makeHarness(analysis: TwoSetAnalysis())
        harness.library.assets += [makeAsset("c"), makeAsset("d")]
        try await selectTypes(harness, ["similarPhotos"])
        harness.model.beginSelectedCleanup()
        harness.model.toggleComparisonDeletion("a")
        await harness.model.confirmComparison()
        #expect(harness.model.currentComparison?.assetIDs == ["c", "d"])
        let frozenData = harness.model.activeSession?.workPlanData
        harness.model.toggleComparisonDeletion("c")
        #expect(harness.model.activeSession?.workPlanData == frozenData)
        harness.model.undo()
        #expect(harness.model.comparisonDeleteIDs == ["a"])
        await harness.model.redo()
        #expect(harness.model.comparisonDeleteIDs == ["c"])
        harness.model.route = .dashboard
        let resumed = harness.newModel()
        await resumed.start()
        resumed.resumeSession()
        #expect(resumed.currentComparison?.assetIDs == ["c", "d"])
        #expect(resumed.comparisonDeleteIDs == ["c"])
        await resumed.confirmComparison()
        #expect(resumed.reviewCandidateIDs == ["a", "c"])
    }

    @Test("metadata groups appear while cached similarity matching is still running")
    func metadataBeforeMatching() async throws {
        let service = SuspendedClusterAnalysis()
        let harness = try makeHarness(analysis: service)
        await harness.model.start()
        await service.suspend()
        harness.library.assets.removeAll { $0.id != "v" }
        let reload = Task { await harness.model.reloadLibrary() }
        await service.waitForPending(1)
        #expect(harness.model.monthGroups.reduce(0) { $0 + $1.totalCount } == 1)
        #expect(harness.model.typeGroups.map(\.key.value) == ["videos"])
        await service.finish(at: 0)
        await reload.value
    }

    @Test("unchanged Similar Photos stays visible during a refresh instead of moving its scroll anchor")
    func cachedSimilarGroupDuringRefresh() async throws {
        let service = SuspendedClusterAnalysis(initialClusters: [SimilarPhotoCluster(id: "fixture", assetIDs: ["a", "b"])])
        let harness = try makeHarness(analysis: service)
        let repository = SwiftDataCleanupRepository(container: harness.container)
        for asset in harness.library.assets where asset.mediaKind != .video {
            try repository.cacheAnalysis(TypeFixtureAnalysis.result, for: asset)
        }
        await harness.model.start()
        harness.model.grouping = .type
        let previous = harness.model.typeGroups.map(\.id)
        #expect(previous.contains("type:similarPhotos"))
        await service.suspend()
        let reload = Task { await harness.model.reloadLibrary() }
        await service.waitForPending(1)
        #expect(harness.model.typeGroups.map(\.id) == previous)
        await service.finish(at: 0)
        await reload.value
    }

    private func selectTypes(_ harness: TypeHarness, _ names: [String]) async throws {
        await harness.model.start()
        harness.model.grouping = .type
        try await awaitAnalysis(harness.model)
        for name in names { harness.model.toggleSelection(try #require(harness.model.typeGroups.first { $0.key.value == name })) }
    }

    private func awaitAnalysis(_ model: AppModel) async throws {
        let deadline = Date().addingTimeInterval(5)
        while model.isAnalyzingTypes && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!model.isAnalyzingTypes)
    }

    private func makeAsset(_ id: String, modified: Date? = nil) -> PhotoAssetDescriptor {
        PhotoAssetDescriptor(id: id, creationDate: nil, coordinate: nil, mediaKind: .photo,
                             duration: 0, pixelWidth: 100, pixelHeight: 100, modificationDate: modified)
    }

    private func makeHarness(analysis: any MediaAnalysisClient = TypeFixtureAnalysis()) throws -> TypeHarness {
        let allFlags = PhotoAssetDescriptor(id: "a", creationDate: nil, coordinate: nil, mediaKind: .livePhoto,
            duration: 0, pixelWidth: 100, pixelHeight: 100, isScreenshot: true, isPanorama: true,
            isFavorite: true, burstIdentifier: "burst", isSelfie: true)
        let video = PhotoAssetDescriptor(id: "v", creationDate: nil, coordinate: nil, mediaKind: .video,
                                        duration: 10, pixelWidth: 100, pixelHeight: 100)
        let library = TypeTestLibrary(assets: [allFlags, makeAsset("b"), video])
        let container = try ModelContainer(for: RollSlashSchema.schema,
                                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        return TypeHarness(library: library, container: container, analysis: analysis)
    }
}

@MainActor private struct TypeHarness {
    let library: TypeTestLibrary
    let container: ModelContainer
    let analysis: any MediaAnalysisClient
    let model: AppModel

    init(library: TypeTestLibrary, container: ModelContainer, analysis: any MediaAnalysisClient) {
        self.library = library
        self.container = container
        self.analysis = analysis
        self.model = AppModel(photoLibrary: library, previewProvider: DemoMediaPreviewProvider(),
            locationResolver: DemoLocationResolver(), modelContainer: container, analysisClient: analysis)
    }

    func newModel() -> AppModel {
        AppModel(photoLibrary: library, previewProvider: DemoMediaPreviewProvider(), locationResolver: DemoLocationResolver(),
                 modelContainer: container, analysisClient: analysis)
    }
}

@MainActor private final class TypeTestLibrary: PhotoLibraryClient {
    var onLibraryChange: (@MainActor @Sendable () -> Void)?
    var assets: [PhotoAssetDescriptor]
    var permission: PhotoPermission = .full
    var failDeletion = false
    var deleted = Set<String>()
    private(set) var fetchCount = 0
    init(assets: [PhotoAssetDescriptor]) { self.assets = assets }
    func authorizationStatus() -> PhotoPermission { permission }
    func requestAuthorization() async -> PhotoPermission { permission }
    func fetchAssets() async throws -> [PhotoAssetDescriptor] {
        fetchCount += 1
        return assets
    }
    func existingAssetIdentifiers(in identifiers: Set<String>) async throws -> Set<String> {
        identifiers.intersection(assets.map(\.id))
    }
    func deleteAssets(with identifiers: [String]) async throws -> Set<String> {
        if failDeletion { throw URLError(.cancelled) }
        deleted = Set(identifiers)
        assets.removeAll { deleted.contains($0.id) }
        return deleted
    }
    func isFavorite(with identifier: String) async -> Bool { assets.first { $0.id == identifier }?.isFavorite ?? false }
    func setFavorite(_ favorite: Bool, for identifier: String) async throws {}
    func presentLimitedLibraryPicker() {}
    func openSystemSettings() {}
}

private struct TypeFixtureAnalysis: MediaAnalysisClient {
    var unavailable = false
    static let result = MediaAnalysisResult(isLarge: true, featurePrint: Data([1]), perceptualHash: 0)
    func analyze(_ asset: PhotoAssetDescriptor) async -> MediaAnalysisResult {
        if unavailable { return MediaAnalysisResult(similarityUnavailable: true) }
        var result = Self.result
        result.isLarge = asset.id == "a"
        return result
    }
    func clusters(assets: [PhotoAssetDescriptor], results: [String: MediaAnalysisResult]) async -> [SimilarPhotoCluster] {
        let ids = assets.filter { $0.mediaKind != .video && results[$0.id]?.featurePrint != nil }.map(\.id).sorted()
        return ids.count > 1 ? [SimilarPhotoCluster(id: "fixture", assetIDs: ids)] : []
    }
}

private actor CountingCachedAnalysis: MediaAnalysisClient {
    private(set) var analyzedIDs: [String] = []
    func analyze(_ asset: PhotoAssetDescriptor) async -> MediaAnalysisResult {
        analyzedIDs.append(asset.id)
        return TypeFixtureAnalysis.result
    }
    func clusters(assets: [PhotoAssetDescriptor], results: [String: MediaAnalysisResult]) async -> [SimilarPhotoCluster] {
        await TypeFixtureAnalysis().clusters(assets: assets, results: results)
    }
}

private struct TwoSetAnalysis: MediaAnalysisClient {
    func analyze(_ asset: PhotoAssetDescriptor) async -> MediaAnalysisResult { TypeFixtureAnalysis.result }
    func clusters(assets: [PhotoAssetDescriptor], results: [String: MediaAnalysisResult]) async -> [SimilarPhotoCluster] {
        let available = Set(assets.filter { results[$0.id]?.featurePrint != nil }.map(\.id))
        return [["a", "b"], ["c", "d"]].compactMap { ids in
            let members = ids.filter(available.contains)
            return members.count > 1 ? SimilarPhotoCluster(id: ids[0], assetIDs: members) : nil
        }
    }
}

private actor SuspendedTypeAnalysis: MediaAnalysisClient {
    private var continuation: CheckedContinuation<MediaAnalysisResult, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func analyze(_ asset: PhotoAssetDescriptor) async -> MediaAnalysisResult {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            waiters.forEach { $0.resume() }
            waiters = []
        }
    }
    func waitForRequest() async {
        if continuation != nil { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() { continuation?.resume(returning: TypeFixtureAnalysis.result); continuation = nil }
    func clusters(assets: [PhotoAssetDescriptor], results: [String: MediaAnalysisResult]) async -> [SimilarPhotoCluster] { [] }
}

private actor SuspendedClusterAnalysis: MediaAnalysisClient {
    private var suspended = false
    private let initialClusters: [SimilarPhotoCluster]
    private var pending: [(ids: [String], continuation: CheckedContinuation<[SimilarPhotoCluster], Never>)] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    init(initialClusters: [SimilarPhotoCluster] = []) { self.initialClusters = initialClusters }
    func suspend() { suspended = true }
    func analyze(_ asset: PhotoAssetDescriptor) async -> MediaAnalysisResult { TypeFixtureAnalysis.result }
    func clusters(assets: [PhotoAssetDescriptor], results: [String: MediaAnalysisResult]) async -> [SimilarPhotoCluster] {
        guard suspended else { return initialClusters }
        return await withCheckedContinuation { continuation in
            pending.append((assets.filter { $0.mediaKind != .video }.map(\.id), continuation))
            let ready = waiters.filter { pending.count >= $0.0 }
            waiters.removeAll { pending.count >= $0.0 }
            ready.forEach { $0.1.resume() }
        }
    }
    func waitForPending(_ count: Int) async {
        if pending.count >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }
    func finish(at index: Int) {
        let entry = pending.remove(at: index)
        entry.continuation.resume(returning: entry.ids.count > 1 ? [SimilarPhotoCluster(id: "suspended", assetIDs: entry.ids)] : [])
    }
}

private actor ControlledBalancedAnalysis: MediaAnalysisClient {
    private var pending: [String: CheckedContinuation<MediaAnalysisResult, Never>] = [:]
    private var cached: [String: MediaAnalysisResult] = [:]
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var requestedIDs: [String] = []
    private(set) var peak = 0
    func concurrencyLimit() async -> Int { 2 }
    func analyze(_ asset: PhotoAssetDescriptor) async -> MediaAnalysisResult { await analyze(asset, cachedResult: nil) }
    func analyze(_ asset: PhotoAssetDescriptor, cachedResult: MediaAnalysisResult?) async -> MediaAnalysisResult {
        await withCheckedContinuation { continuation in
            pending[asset.id] = continuation
            cached[asset.id] = cachedResult
            requestedIDs.append(asset.id)
            peak = max(peak, pending.count)
            let ready = waiters.filter { requestedIDs.count >= $0.0 }
            waiters.removeAll { requestedIDs.count >= $0.0 }
            ready.forEach { $0.1.resume() }
        }
    }
    func cachedResult(for id: String) -> MediaAnalysisResult? { cached[id] }
    func waitForRequests(_ count: Int) async {
        if requestedIDs.count >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }
    func finish(_ id: String) {
        var result = TypeFixtureAnalysis.result
        result.isLarge = cached[id]?.isLarge ?? result.isLarge
        pending.removeValue(forKey: id)?.resume(returning: result)
    }
    func clusters(assets: [PhotoAssetDescriptor], results: [String: MediaAnalysisResult]) async -> [SimilarPhotoCluster] {
        await TypeFixtureAnalysis().clusters(assets: assets, results: results)
    }
}

private struct NoAnalysisExpected: MediaAnalysisClient {
    func analyze(_ asset: PhotoAssetDescriptor) async -> MediaAnalysisResult {
        Issue.record("Completed legacy sizing and fingerprints must not be rescanned")
        return MediaAnalysisResult()
    }
    func clusters(assets: [PhotoAssetDescriptor], results: [String: MediaAnalysisResult]) async -> [SimilarPhotoCluster] { [] }
}
