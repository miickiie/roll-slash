import Foundation
import SwiftData

@MainActor
protocol CleanupRepository: AnyObject {
    func allDecisions() throws -> [String: AssetDecision]
    func decision(for assetIdentifier: String) throws -> AssetDecision?
    func setDecision(_ decision: AssetDecision, for assetIdentifier: String, sessionIdentifier: UUID?) throws
    func removeDecisions(for assetIdentifiers: Set<String>) throws
    func activeSession() throws -> CleanupSessionRecord?
    func createSession(groupKind: GroupKind, selectedGroupKeys: [String], orderedAssetIDs: [String], workPlan: CleanupWorkPlan?) throws -> CleanupSessionRecord
    func actions(for sessionIdentifier: UUID) throws -> [CleanupActionRecord]
    func recordDecision(session: CleanupSessionRecord, assetIdentifier: String, decision: AssetDecision) throws -> CleanupActionRecord
    func recordDecisions(session: CleanupSessionRecord, decisions: [(String, AssetDecision)]) throws -> [CleanupActionRecord]
    func setUnitApplied(session: CleanupSessionRecord, range: Range<Int>, applied: Bool) throws
    func replaceActions(sessionIdentifier: UUID, actions: [CleanupActionSnapshot]) throws
    func updateReviewSelection(session: CleanupSessionRecord, candidateIDs: [String], selectedIDs: Set<String>) throws
    func updateReviewSelection(session: CleanupSessionRecord, assetIdentifier: String, isSelected: Bool) throws
    func save() throws
    func discard(session: CleanupSessionRecord) throws
    func finish(session: CleanupSessionRecord) throws
    func completedGroups() throws -> [String: GroupCompletionRecord]
    func markCompleted(groupKey: String, label: String) throws
    func cachedLocations(for bucketKeys: Set<String>, localeIdentifier: String) throws -> [String: ResolvedLocation]
    func cacheLocation(_ location: ResolvedLocation, for bucketKey: String) throws
    func resetHistory() throws
    func cachedAnalysis(for assets: [PhotoAssetDescriptor]) throws -> [String: MediaAnalysisResult]
    func cacheAnalysis(_ result: MediaAnalysisResult, for asset: PhotoAssetDescriptor) throws
    func cacheAnalysis(_ entries: [MediaAnalysisCacheEntry]) throws
}

@MainActor
final class SwiftDataCleanupRepository: CleanupRepository {
    private let context: ModelContext
    private let analysisContext: ModelContext
    private var analysisIndex: [String: MediaAnalysisCacheRecord]?
    private let analysisEncoder = JSONEncoder()

    init(container: ModelContainer) {
        context = ModelContext(container)
        context.autosaveEnabled = true
        analysisContext = ModelContext(container)
        analysisContext.autosaveEnabled = false
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

    func createSession(groupKind: GroupKind, selectedGroupKeys: [String], orderedAssetIDs: [String], workPlan: CleanupWorkPlan? = nil) throws -> CleanupSessionRecord {
        let existingDecisions = try allDecisions()
        let baselines = orderedAssetIDs.map {
            SessionDecisionBaseline(assetIdentifier: $0, decision: existingDecisions[$0])
        }
        let session = CleanupSessionRecord(groupKind: groupKind, selectedGroupKeys: selectedGroupKeys, orderedAssetIDs: orderedAssetIDs)
        session.decisionBaselines = baselines
        session.workPlan = workPlan
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
    func recordDecision(session: CleanupSessionRecord, assetIdentifier: String, decision: AssetDecision) throws -> CleanupActionRecord {
        try recordDecisions(session: session, decisions: [(assetIdentifier, decision)])[0]
    }

    func recordDecisions(session: CleanupSessionRecord, decisions: [(String, AssetDecision)]) throws -> [CleanupActionRecord] {
        let sessionIdentifier = session.identifier
        let sequence = session.cursor
        let descriptor = FetchDescriptor<CleanupActionRecord>(predicate: #Predicate {
            $0.sessionIdentifier == sessionIdentifier && $0.sequence >= sequence
        })
        try context.fetch(descriptor).forEach(context.delete)
        do {
            var recorded: [CleanupActionRecord] = []
            for (offset, pair) in decisions.enumerated() {
                let action = CleanupActionRecord(sessionIdentifier: sessionIdentifier, sequence: sequence + offset,
                                                 assetIdentifier: pair.0, decision: pair.1)
                context.insert(action)
                try upsertDecision(pair.1, for: pair.0, sessionIdentifier: sessionIdentifier)
                recorded.append(action)
            }
            session.cursor += decisions.count
            session.draftDeleteIDs.subtract(decisions.map { $0.0 })
            try context.save()
            return recorded
        } catch {
            context.rollback()
            throw error
        }
    }

    func setUnitApplied(session: CleanupSessionRecord, range: Range<Int>, applied: Bool) throws {
        do {
            let unitActions = try actions(for: session.identifier).filter { range.contains($0.sequence) }
            guard unitActions.count == range.count else { throw CocoaError(.validationMissingMandatoryProperty) }
            for action in unitActions {
                action.isApplied = applied
                if applied {
                    try upsertDecision(action.decision, for: action.assetIdentifier, sessionIdentifier: session.identifier)
                } else if let baseline = session.originalDecision(for: action.assetIdentifier) {
                    try upsertDecision(baseline, for: action.assetIdentifier, sessionIdentifier: nil)
                } else {
                    try removeDecisionWithoutSaving(for: action.assetIdentifier)
                }
            }
            session.cursor = applied ? range.upperBound : range.lowerBound
            var drafts = session.draftDeleteIDs
            drafts.subtract(unitActions.map(\.assetIdentifier))
            if !applied {
                drafts.formUnion(unitActions.filter { $0.decision == .deletePending }.map(\.assetIdentifier))
            }
            session.draftDeleteIDs = drafts
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    func cachedAnalysis(for assets: [PhotoAssetDescriptor]) throws -> [String: MediaAnalysisResult] {
        let signatures = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, MediaAnalysisResult.signature(for: $0)) })
        var results: [String: MediaAnalysisResult] = [:]
        analysisIndex = nil
        var index: [String: MediaAnalysisCacheRecord] = [:]
        for record in try analysisContext.fetch(FetchDescriptor<MediaAnalysisCacheRecord>()) {
            guard let signature = signatures[record.assetIdentifier], signature == record.signature else {
                analysisContext.delete(record)
                continue
            }
            results[record.assetIdentifier] = record.result
            index[record.assetIdentifier] = record
        }
        do { try analysisContext.save(); analysisIndex = index }
        catch { analysisContext.rollback(); throw error }
        return results
    }

    func cacheAnalysis(_ result: MediaAnalysisResult, for asset: PhotoAssetDescriptor) throws {
        try cacheAnalysis([MediaAnalysisCacheEntry(asset: asset, result: result)])
    }

    func cacheAnalysis(_ entries: [MediaAnalysisCacheEntry]) throws {
        guard !entries.isEmpty else { return }
        let interval = AnalysisPerformance.begin(.cache)
        defer { AnalysisPerformance.end(.cache, interval) }
        do {
            if analysisIndex == nil {
                analysisIndex = Dictionary(uniqueKeysWithValues:
                    try analysisContext.fetch(FetchDescriptor<MediaAnalysisCacheRecord>()).map { ($0.assetIdentifier, $0) })
            }
            for entry in entries {
                let id = entry.asset.id
                let signature = MediaAnalysisResult.signature(for: entry.asset)
                if let existing = analysisIndex?[id] {
                    existing.signature = signature
                    existing.resultData = try analysisEncoder.encode(entry.result)
                } else {
                    let record = try MediaAnalysisCacheRecord(assetIdentifier: id, signature: signature, result: entry.result)
                    analysisContext.insert(record)
                    analysisIndex?[id] = record
                }
            }
            try analysisContext.save()
        } catch {
            analysisContext.rollback()
            analysisIndex = nil
            throw error
        }
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

    func updateReviewSelection(session: CleanupSessionRecord, assetIdentifier: String, isSelected: Bool) throws {
        try upsertDecision(
            isSelected ? .deletePending : .keep,
            for: assetIdentifier,
            sessionIdentifier: session.identifier
        )
        var selected = session.reviewSelectedIDs
        if isSelected {
            if !selected.contains(assetIdentifier) {
                selected.append(assetIdentifier)
            }
        } else {
            selected.removeAll { $0 == assetIdentifier }
        }
        session.reviewSelectedIDs = selected
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

    func cachedLocations(for bucketKeys: Set<String>, localeIdentifier: String) throws -> [String: ResolvedLocation] {
        guard !bucketKeys.isEmpty else { return [:] }
        let records = try context.fetch(FetchDescriptor<LocationCacheRecord>())
        return Dictionary(uniqueKeysWithValues: records.compactMap { record in
            guard bucketKeys.contains(record.bucketKey), record.localeIdentifier == localeIdentifier else { return nil }
            return (record.bucketKey, record.location)
        })
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
