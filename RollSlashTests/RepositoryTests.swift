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

    private func makeContainer() throws -> ModelContainer {
        return try ModelContainer(
            for: RollSlashSchema.schema,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
    }
}
