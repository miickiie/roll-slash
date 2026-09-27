import Foundation
import SwiftData

@MainActor
protocol CleanupRepository: AnyObject {
    func allDecisions() throws -> [String: AssetDecision]
    func decision(for assetIdentifier: String) throws -> AssetDecision?
    func setDecision(_ decision: AssetDecision, for assetIdentifier: String, sessionIdentifier: UUID?) throws
    func restoreOriginalDecision(for assetIdentifier: String, in session: CleanupSessionRecord) throws
    func removeDecision(for assetIdentifier: String) throws
    func removeDecisions(for assetIdentifiers: Set<String>) throws
    func activeSession() throws -> CleanupSessionRecord?
    func createSession(groupKind: GroupKind, selectedGroupKeys: [String], orderedAssetIDs: [String]) throws -> CleanupSessionRecord
    func actions(for sessionIdentifier: UUID) throws -> [CleanupActionRecord]
    func appendAction(sessionIdentifier: UUID, sequence: Int, assetIdentifier: String, decision: AssetDecision) throws
    func trimActions(sessionIdentifier: UUID, from sequence: Int) throws
    func replaceActions(sessionIdentifier: UUID, actions: [CleanupActionSnapshot]) throws
    func updateReviewSelection(session: CleanupSessionRecord, candidateIDs: [String], selectedIDs: Set<String>) throws
    func save() throws
    func discard(session: CleanupSessionRecord) throws
    func finish(session: CleanupSessionRecord) throws
    func completedGroups() throws -> [String: GroupCompletionRecord]
    func markCompleted(groupKey: String, label: String) throws
    func cachedLocation(for bucketKey: String) throws -> ResolvedLocation?
    func cacheLocation(_ location: ResolvedLocation, for bucketKey: String) throws
    func resetHistory() throws
}

@MainActor
final class SwiftDataCleanupRepository: CleanupRepository {
    private let context: ModelContext

    init(container: ModelContainer) {
        context = ModelContext(container)
        context.autosaveEnabled = true
    }

    func allDecisions() throws -> [String: AssetDecision] {
        let records = try context.fetch(FetchDescriptor<AssetDecisionRecord>())
        return Dictionary(uniqueKeysWithValues: records.map { ($0.assetIdentifier, $0.decision) })
    }

    func decision(for assetIdentifier: String) throws -> AssetDecision? {
        var descriptor = FetchDescriptor<AssetDecisionRecord>(predicate: #Predicate { $0.assetIdentifier == assetIdentifier })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first?.decision
    }

    func setDecision(_ decision: AssetDecision, for assetIdentifier: String, sessionIdentifier: UUID?) throws {
        try upsertDecision(decision, for: assetIdentifier, sessionIdentifier: sessionIdentifier)
        try context.save()
    }

    private func upsertDecision(_ decision: AssetDecision, for assetIdentifier: String, sessionIdentifier: UUID?) throws {
        var descriptor = FetchDescriptor<AssetDecisionRecord>(predicate: #Predicate { $0.assetIdentifier == assetIdentifier })
        descriptor.fetchLimit = 1
        if let existing = try context.fetch(descriptor).first {
            existing.decision = decision
            existing.sessionIdentifier = sessionIdentifier
        } else {
            context.insert(AssetDecisionRecord(assetIdentifier: assetIdentifier, decision: decision, sessionIdentifier: sessionIdentifier))
        }
    }

    private func removeDecisionWithoutSaving(for assetIdentifier: String) throws {
        let descriptor = FetchDescriptor<AssetDecisionRecord>(
            predicate: #Predicate { $0.assetIdentifier == assetIdentifier }
        )
        try context.fetch(descriptor).forEach(context.delete)
    }

    func restoreOriginalDecision(for assetIdentifier: String, in session: CleanupSessionRecord) throws {
        if let baselines = session.decisionBaselines {
            guard let baseline = baselines.first(where: { $0.assetIdentifier == assetIdentifier }) else { return }
            if let decision = baseline.decision {
                try upsertDecision(decision, for: assetIdentifier, sessionIdentifier: nil)
            } else {
                try removeDecisionWithoutSaving(for: assetIdentifier)
            }
        } else {
            try removeDecisionWithoutSaving(for: assetIdentifier)
        }
        try context.save()
    }

    func removeDecision(for assetIdentifier: String) throws {
        let descriptor = FetchDescriptor<AssetDecisionRecord>(predicate: #Predicate { $0.assetIdentifier == assetIdentifier })
        try context.fetch(descriptor).forEach(context.delete)
        try context.save()
    }

    func removeDecisions(for assetIdentifiers: Set<String>) throws {
        let records = try context.fetch(FetchDescriptor<AssetDecisionRecord>())
        records.filter { assetIdentifiers.contains($0.assetIdentifier) }.forEach(context.delete)
        try context.save()
    }

    func activeSession() throws -> CleanupSessionRecord? {
        var descriptor = FetchDescriptor<CleanupSessionRecord>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    func createSession(groupKind: GroupKind, selectedGroupKeys: [String], orderedAssetIDs: [String]) throws -> CleanupSessionRecord {
        let existingDecisions = try allDecisions()
        let baselines = orderedAssetIDs.map {
            SessionDecisionBaseline(assetIdentifier: $0, decision: existingDecisions[$0])
        }
        let session = CleanupSessionRecord(groupKind: groupKind, selectedGroupKeys: selectedGroupKeys, orderedAssetIDs: orderedAssetIDs)
        session.decisionBaselines = baselines
        context.insert(session)
        try context.save()
        return session
    }

    func actions(for sessionIdentifier: UUID) throws -> [CleanupActionRecord] {
        let descriptor = FetchDescriptor<CleanupActionRecord>(
            predicate: #Predicate { $0.sessionIdentifier == sessionIdentifier },
            sortBy: [SortDescriptor(\.sequence)]
        )
        return try context.fetch(descriptor)
    }

    func appendAction(sessionIdentifier: UUID, sequence: Int, assetIdentifier: String, decision: AssetDecision) throws {
        context.insert(CleanupActionRecord(
            sessionIdentifier: sessionIdentifier,
            sequence: sequence,
            assetIdentifier: assetIdentifier,
            decision: decision
        ))
        try context.save()
    }

    func trimActions(sessionIdentifier: UUID, from sequence: Int) throws {
        let descriptor = FetchDescriptor<CleanupActionRecord>(predicate: #Predicate {
            $0.sessionIdentifier == sessionIdentifier && $0.sequence >= sequence
        })
        try context.fetch(descriptor).forEach(context.delete)
        try context.save()
    }

    func replaceActions(sessionIdentifier: UUID, actions: [CleanupActionSnapshot]) throws {
        let descriptor = FetchDescriptor<CleanupActionRecord>(predicate: #Predicate { $0.sessionIdentifier == sessionIdentifier })
        try context.fetch(descriptor).forEach(context.delete)
        for action in actions {
            context.insert(CleanupActionRecord(
                sessionIdentifier: sessionIdentifier,
                sequence: action.sequence,
                assetIdentifier: action.assetIdentifier,
                decision: action.decision,
                isApplied: action.isApplied
            ))
        }
        try context.save()
    }

    func updateReviewSelection(
        session: CleanupSessionRecord,
        candidateIDs: [String],
        selectedIDs: Set<String>
    ) throws {
        for identifier in candidateIDs {
            try upsertDecision(
                selectedIDs.contains(identifier) ? .deletePending : .keep,
                for: identifier,
                sessionIdentifier: session.identifier
            )
        }
        session.reviewSelectedIDs = candidateIDs.filter(selectedIDs.contains)
        try context.save()
    }

    func save() throws {
        try context.save()
    }

    func discard(session: CleanupSessionRecord) throws {
        let sessionID = session.identifier
        if let baselines = session.decisionBaselines {
            for baseline in baselines {
                if let decision = baseline.decision {
                    try upsertDecision(decision, for: baseline.assetIdentifier, sessionIdentifier: nil)
                } else {
                    try removeDecisionWithoutSaving(for: baseline.assetIdentifier)
                }
            }
        } else {
            let decisions = try context.fetch(FetchDescriptor<AssetDecisionRecord>(predicate: #Predicate { $0.sessionIdentifier == sessionID }))
            decisions.forEach(context.delete)
        }
        let actions = try context.fetch(FetchDescriptor<CleanupActionRecord>(predicate: #Predicate { $0.sessionIdentifier == sessionID }))
        actions.forEach(context.delete)
        context.delete(session)
        try context.save()
    }

    func finish(session: CleanupSessionRecord) throws {
        let sessionID = session.identifier
        let decisions = try context.fetch(FetchDescriptor<AssetDecisionRecord>(predicate: #Predicate { $0.sessionIdentifier == sessionID }))
        decisions.forEach { $0.sessionIdentifier = nil }
        let actions = try context.fetch(FetchDescriptor<CleanupActionRecord>(predicate: #Predicate { $0.sessionIdentifier == sessionID }))
        actions.forEach(context.delete)
        context.delete(session)
        try context.save()
    }

    func completedGroups() throws -> [String: GroupCompletionRecord] {
        let records = try context.fetch(FetchDescriptor<GroupCompletionRecord>())
        return Dictionary(uniqueKeysWithValues: records.map { ($0.groupKey, $0) })
    }

    func markCompleted(groupKey: String, label: String) throws {
        var descriptor = FetchDescriptor<GroupCompletionRecord>(predicate: #Predicate { $0.groupKey == groupKey })
        descriptor.fetchLimit = 1
        if let record = try context.fetch(descriptor).first {
            record.lastLabel = label
            record.completedAt = .now
        } else {
            context.insert(GroupCompletionRecord(groupKey: groupKey, lastLabel: label))
        }
        try context.save()
    }

    func cachedLocation(for bucketKey: String) throws -> ResolvedLocation? {
        var descriptor = FetchDescriptor<LocationCacheRecord>(predicate: #Predicate { $0.bucketKey == bucketKey })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first?.location
    }

    func cacheLocation(_ location: ResolvedLocation, for bucketKey: String) throws {
        var descriptor = FetchDescriptor<LocationCacheRecord>(predicate: #Predicate { $0.bucketKey == bucketKey })
        descriptor.fetchLimit = 1
        if let record = try context.fetch(descriptor).first {
            record.city = location.city
            record.country = location.country
            record.localeIdentifier = Locale.current.identifier
            record.resolvedAt = .now
        } else {
            context.insert(LocationCacheRecord(
                bucketKey: bucketKey,
                city: location.city,
                country: location.country,
                localeIdentifier: Locale.current.identifier
            ))
        }
        try context.save()
    }

    func resetHistory() throws {
        try context.delete(model: AssetDecisionRecord.self)
        try context.delete(model: CleanupActionRecord.self)
        try context.delete(model: CleanupSessionRecord.self)
        try context.delete(model: GroupCompletionRecord.self)
        try context.save()
    }
}
