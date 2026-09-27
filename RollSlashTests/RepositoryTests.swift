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
        try repository.appendAction(sessionIdentifier: session.identifier, sequence: 0, assetIdentifier: "a", decision: .keep)
        try repository.setDecision(.keep, for: "a", sessionIdentifier: session.identifier)

        #expect(try repository.activeSession()?.identifier == session.identifier)
        #expect(try repository.decision(for: "a") == .keep)
        #expect(try repository.actions(for: session.identifier).count == 1)

        try repository.discard(session: session)
        #expect(try repository.activeSession() == nil)
        #expect(try repository.decision(for: "a") == nil)
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            AssetDecisionRecord.self,
            CleanupSessionRecord.self,
            CleanupActionRecord.self,
            GroupCompletionRecord.self,
            LocationCacheRecord.self
        ])
        return try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
    }
}

