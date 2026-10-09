import Foundation
import SwiftData
import Testing
@testable import RollSlash

@MainActor
@Suite("Cleanup repository")
struct RepositoryTests {
    @Test("session decisions and action history persist")
    func sessionPersistence() throws {
        let repository = SwiftDataCleanupRepository(container: try makeContainer())
        let session = try repository.createSession(
            groupKind: .month,
            selectedGroupKeys: ["month:2026-01"],
            orderedAssetIDs: ["a", "b"]
        )
        _ = try repository.recordDecision(session: session, assetIdentifier: "a", decision: .keep)

        #expect(try repository.activeSession()?.identifier == session.identifier)
        #expect(try repository.decision(for: "a") == .keep)
        #expect(try repository.actions(for: session.identifier).count == 1)

        try repository.discard(session: session)
        #expect(try repository.activeSession() == nil)
        #expect(try repository.decision(for: "a") == nil)
    }

    @Test("discard restores the session decision baseline")
    func discardRestoresBaseline() throws {
        let repository = SwiftDataCleanupRepository(container: try makeContainer())
        try repository.setDecision(.keep, for: "a", sessionIdentifier: nil)
        let session = try repository.createSession(
            groupKind: .month,
            selectedGroupKeys: ["month:2026-01"],
            orderedAssetIDs: ["a", "b"]
        )

        try repository.setDecision(.deletePending, for: "a", sessionIdentifier: session.identifier)
        try repository.setDecision(.keep, for: "b", sessionIdentifier: session.identifier)
        try repository.discard(session: session)

        #expect(try repository.decision(for: "a") == .keep)
        #expect(try repository.decision(for: "b") == nil)
    }

    @Test("legacy sessions without a baseline still discard session decisions")
    func legacySessionDiscard() throws {
        let repository = SwiftDataCleanupRepository(container: try makeContainer())
        let session = try repository.createSession(
            groupKind: .month,
            selectedGroupKeys: ["month:2026-01"],
            orderedAssetIDs: ["a"]
        )
        session.decisionBaselinesData = nil
        try repository.setDecision(.keep, for: "a", sessionIdentifier: session.identifier)

        try repository.discard(session: session)

        #expect(try repository.decision(for: "a") == nil)
    }

    @Test("single review selection update changes only the tapped candidate")
    func singleReviewSelectionUpdate() throws {
        let repository = SwiftDataCleanupRepository(container: try makeContainer())
        let session = try repository.createSession(
            groupKind: .month,
            selectedGroupKeys: ["month:2026-01"],
            orderedAssetIDs: ["a", "b"]
        )
        try repository.updateReviewSelection(
            session: session,
            candidateIDs: ["a", "b"],
            selectedIDs: ["a", "b"]
        )

        try repository.updateReviewSelection(session: session, assetIdentifier: "a", isSelected: false)

        #expect(try repository.decision(for: "a") == .keep)
        #expect(try repository.decision(for: "b") == .deletePending)
        #expect(session.reviewSelectedIDs == ["b"])
    }

    @Test("location cache reads only requested buckets in the current locale")
    func locationCacheBatchAndLocale() throws {
        let repository = SwiftDataCleanupRepository(container: try makeContainer())
        let first = ResolvedLocation(city: "Bangkok", country: "Thailand")
        let second = ResolvedLocation(city: "Chiang Mai", country: "Thailand")
        try repository.cacheLocation(first, for: "first")
        try repository.cacheLocation(second, for: "second")

        let current = try repository.cachedLocations(
            for: ["first"], localeIdentifier: Locale.current.identifier
        )
        #expect(current == ["first": first])
        #expect(try repository.cachedLocations(
            for: ["first", "second"], localeIdentifier: "different-locale"
        ).isEmpty)
    }

    @Test("draft writes and swipe decisions leave a large frozen plan unchanged")
    func frozenPlanWrites() throws {
        let container = try makeContainer()
        let repository = SwiftDataCleanupRepository(container: container)
        let ids = (0..<26_000).map { "asset-\($0)" }
        let comparison = CleanupWorkUnit(kind: .comparison, assetIDs: Array(ids.prefix(2)),
                                         contextAssetIDs: [], clusterID: "first")
        let plan = CleanupWorkPlan(units: [comparison] + ids.dropFirst(2).map(CleanupWorkUnit.swipe))
        let session = try repository.createSession(groupKind: .type, selectedGroupKeys: [], orderedAssetIDs: ids, workPlan: plan)
        let frozenData = try #require(session.workPlanData)
        session.draftDeleteIDs = [ids[0]]
        try repository.save()
        _ = try repository.recordDecisions(session: session, decisions: [(ids[0], .deletePending), (ids[1], .keep)])
        _ = try repository.recordDecision(session: session, assetIdentifier: ids[2], decision: .keep)
        #expect(session.workPlanData == frozenData)
        #expect(session.draftDeleteIDs.isEmpty)
        #expect(session.unit(at: 1)?.start == 0)
        #expect(session.unit(at: 2)?.unit == .swipe(ids[2]))
        #expect(session.unit(at: 25_999)?.unit == .swipe(ids[25_999]))
        #expect(session.unit(at: -1) == nil)
        #expect(session.unit(at: 26_000) == nil)
        let reopened = try #require(try SwiftDataCleanupRepository(container: container).activeSession())
        #expect(reopened.unit(at: 25_999)?.start == 25_999)

        let clock = ContinuousClock()
        let cachedStart = clock.now
        for cursor in 25_950..<26_000 { #expect(session.unit(at: cursor)?.start == cursor) }
        let cachedDuration = cachedStart.duration(to: clock.now)
        let uncachedStart = clock.now
        for cursor in 25_950..<26_000 {
            let decoded = try JSONDecoder().decode(CleanupWorkPlan.self, from: frozenData)
            var start = 0
            for unit in decoded.units {
                if cursor < start + unit.assetIDs.count { break }
                start += unit.assetIDs.count
            }
            #expect(start == cursor)
        }
        print("26,000-asset session, 50 late-cursor lookups: cached \(cachedDuration), repeated decode/walk \(uncachedStart.duration(to: clock.now))")
    }

    @Test("legacy embedded drafts load and byte changes invalidate session lookup caches")
    func legacyDraftsAndInvalidation() throws {
        let session = CleanupSessionRecord(groupKind: .type, selectedGroupKeys: [], orderedAssetIDs: ["a", "b", "c"])
        let unit = CleanupWorkUnit(kind: .comparison, assetIDs: ["a", "b"], contextAssetIDs: [], clusterID: "legacy")
        session.workPlanData = try JSONEncoder().encode(CleanupWorkPlan(units: [unit, .swipe("c")], draftDeleteIDs: ["b"]))
        #expect(session.comparisonDraftDeleteIDsData == nil)
        #expect(session.workPlan?.draftDeleteIDs == ["b"])
        #expect(session.unit(at: 2)?.start == 2)
        let data = session.workPlanData
        session.draftDeleteIDs = ["a"]
        #expect(session.workPlan?.draftDeleteIDs == ["a"])
        #expect(session.workPlanData == data)
        session.workPlanData = try JSONEncoder().encode(CleanupWorkPlan(units: [.swipe("c")]))
        #expect(session.unit(at: 0)?.unit == .swipe("c"))
        #expect(session.unit(at: 1) == nil)
        #expect(session.orderedAssetIDs == ["a", "b", "c"])
        session.orderedAssetIDsData = try JSONEncoder().encode(["c"])
        session.workPlanData = nil
        #expect(session.orderedAssetIDs == ["c"])
        #expect(session.unit(at: 0)?.unit == .swipe("c"))
    }

    @Test("legacy and separate comparison drafts survive reopening a disk store")
    func diskDraftPersistence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RollSlash-session-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("session.store")
        let unit = CleanupWorkUnit(kind: .comparison, assetIDs: ["a", "b"], contextAssetIDs: [], clusterID: "legacy")
        let legacyData = try JSONEncoder().encode(CleanupWorkPlan(units: [unit], draftDeleteIDs: ["a"]))
        func openStore() throws -> SwiftDataCleanupRepository {
            let configuration = ModelConfiguration(url: url, cloudKitDatabase: .none)
            let container = try ModelContainer(for: RollSlashSchema.schema, configurations: [configuration])
            return SwiftDataCleanupRepository(container: container)
        }
        do {
            let repository = try openStore()
            let session = try repository.createSession(groupKind: .type, selectedGroupKeys: [], orderedAssetIDs: ["a", "b"])
            session.workPlanData = legacyData
            try repository.save()
        }
        do {
            let repository = try openStore()
            let session = try #require(try repository.activeSession())
            #expect(session.comparisonDraftDeleteIDsData == nil)
            #expect(session.draftDeleteIDs == ["a"])
            session.draftDeleteIDs = ["b"]
            try repository.save()
        }
        let repository = try openStore()
        let session = try #require(try repository.activeSession())
        #expect(session.workPlanData == legacyData)
        #expect(session.workPlan?.draftDeleteIDs == ["b"])
        #expect(session.unit(at: 1)?.unit == unit)
    }

    @Test("a new session replaces an abandoned swipe and refuses to hide a deletion")
    func createSessionReplacesAbandonedSwipeOnly() throws {
        let repository = SwiftDataCleanupRepository(container: try makeContainer())
        let abandoned = try repository.createSession(groupKind: .month, selectedGroupKeys: [], orderedAssetIDs: ["a"])
        _ = try repository.recordDecision(session: abandoned, assetIdentifier: "a", decision: .keep)
        let replacement = try repository.createSession(groupKind: .month, selectedGroupKeys: [], orderedAssetIDs: ["b"])
        #expect(try repository.activeSession()?.identifier == replacement.identifier)
        #expect(try repository.actions(for: abandoned.identifier).isEmpty)
        #expect(try repository.decision(for: "a") == nil)

        replacement.status = .deleting
        try repository.save()
        #expect(throws: CleanupStoreError.self) {
            try repository.createSession(groupKind: .month, selectedGroupKeys: [], orderedAssetIDs: ["c"])
        }
        #expect(try repository.activeSession()?.identifier == replacement.identifier)
        #expect(try repository.actions(for: replacement.identifier).isEmpty)
    }

    private func makeContainer() throws -> ModelContainer {
        return try ModelContainer(
            for: RollSlashSchema.schema,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
    }
}
