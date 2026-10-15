import Foundation
import SwiftData

protocol AnalysisCacheReading: Sendable {
    func load(for assets: [PhotoAssetDescriptor]) async throws -> MediaAnalysisCacheSnapshot
}

struct CleanupStoreError: LocalizedError, Equatable {
    static let deletionInProgress = CleanupStoreError(
        message: String(localized: "Roll Slash is still confirming a deletion. Finish that before starting another cleanup.")
    )

    let message: String
    var errorDescription: String? { message }
}

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
    func undoLastUnitFromReview(session: CleanupSessionRecord) throws
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
    func loadAnalysisCache(for assets: [PhotoAssetDescriptor]) async throws -> MediaAnalysisCacheSnapshot
    func removeCachedAnalysis(for assetIdentifiers: Set<String>) throws
    func cacheAnalysis(_ result: MediaAnalysisResult, for asset: PhotoAssetDescriptor) throws
    func cacheAnalysis(_ entries: [MediaAnalysisCacheEntry]) throws
}

@MainActor
final class SwiftDataCleanupRepository: CleanupRepository {
    private let context: ModelContext
    private let analysisContext: ModelContext
    private let analysisEncoder = JSONEncoder()
    private let analysisReader: any AnalysisCacheReading
    private let saveChanges: (ModelContext) throws -> Void

    init(container: ModelContainer, analysisReader: (any AnalysisCacheReading)? = nil,
         saveChanges: @escaping (ModelContext) throws -> Void = { try $0.save() }) {
        context = ModelContext(container)
        context.autosaveEnabled = true
        analysisContext = ModelContext(container)
        analysisContext.autosaveEnabled = false
        self.analysisReader = analysisReader ?? AnalysisCacheReader(container: container)
        self.saveChanges = saveChanges
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
        guard !assetIdentifiers.isEmpty else { return }
        for chunk in Array(assetIdentifiers).chunks(of: 200) {
            let identifiers = chunk
            let descriptor = FetchDescriptor<AssetDecisionRecord>(
                predicate: #Predicate { identifiers.contains($0.assetIdentifier) }
            )
            try context.fetch(descriptor).forEach(context.delete)
        }
        try context.save()
    }

    func activeSession() throws -> CleanupSessionRecord? {
        var descriptor = FetchDescriptor<CleanupSessionRecord>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    func createSession(groupKind: GroupKind, selectedGroupKeys: [String], orderedAssetIDs: [String], workPlan: CleanupWorkPlan? = nil) throws -> CleanupSessionRecord {
        let existingSessions = try context.fetch(FetchDescriptor<CleanupSessionRecord>())
        if existingSessions.contains(where: { $0.status == .deleting }) {
            throw CleanupStoreError.deletionInProgress
        }
        for session in existingSessions {
            try discard(session: session)
        }
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
            try save()
        } catch {
            context.rollback()
            throw error
        }
    }

    func undoLastUnitFromReview(session: CleanupSessionRecord) throws {
        guard session.status == .reviewing, session.cursor > 0,
              let previous = session.unit(at: session.cursor - 1) else { return }
        do {
            let selected = Set(session.reviewSelectedIDs)
            for action in try actions(for: session.identifier) where action.isApplied && action.decision == .deletePending {
                action.decision = selected.contains(action.assetIdentifier) ? .deletePending : .keep
                try upsertDecision(action.decision, for: action.assetIdentifier, sessionIdentifier: session.identifier)
            }
            session.status = .swiping
            session.reviewSelectedIDs = []
            try setUnitApplied(session: session,
                               range: previous.start..<(previous.start + previous.unit.assetIDs.count),
                               applied: false)
        } catch {
            context.rollback()
            throw error
        }
    }

    func loadAnalysisCache(for assets: [PhotoAssetDescriptor]) async throws -> MediaAnalysisCacheSnapshot {
        try await analysisReader.load(for: assets)
    }

    // Only identifiers verified absent from Photos may be removed. Hidden media
    // and media outside limited access retain their completed analysis.
    func removeCachedAnalysis(for assetIdentifiers: Set<String>) throws {
        guard !assetIdentifiers.isEmpty else { return }
        do {
            for identifiers in Array(assetIdentifiers).chunks(of: 200) {
                let descriptor = FetchDescriptor<MediaAnalysisCacheRecord>(
                    predicate: #Predicate { identifiers.contains($0.assetIdentifier) }
                )
                try analysisContext.fetch(descriptor).forEach(analysisContext.delete)
            }
            try analysisContext.save()
        } catch {
            analysisContext.rollback()
            throw error
        }
    }

    func cacheAnalysis(_ result: MediaAnalysisResult, for asset: PhotoAssetDescriptor) throws {
        try cacheAnalysis([MediaAnalysisCacheEntry(asset: asset, result: result)])
    }

    func cacheAnalysis(_ entries: [MediaAnalysisCacheEntry]) throws {
        guard !entries.isEmpty else { return }
        let interval = AnalysisPerformance.begin(.cache)
        defer { AnalysisPerformance.end(.cache, interval) }
        do {
            var index: [String: MediaAnalysisCacheRecord] = [:]
            for identifiers in Array(Set(entries.map { $0.asset.id })).chunks(of: 200) {
                let descriptor = FetchDescriptor<MediaAnalysisCacheRecord>(
                    predicate: #Predicate { identifiers.contains($0.assetIdentifier) }
                )
                for record in try analysisContext.fetch(descriptor) { index[record.assetIdentifier] = record }
            }
            for entry in entries {
                let id = entry.asset.id
                let signature = MediaAnalysisResult.signature(for: entry.asset)
                if let existing = index[id] {
                    existing.signature = signature
                    existing.resultData = try analysisEncoder.encode(entry.result)
                } else {
                    let record = try MediaAnalysisCacheRecord(assetIdentifier: id, signature: signature, result: entry.result)
                    analysisContext.insert(record)
                    index[id] = record
                }
            }
            try analysisContext.save()
        } catch {
            analysisContext.rollback()
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
        try saveChanges(context)
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
        let locale = localeIdentifier
        var matched: [String: ResolvedLocation] = [:]
        for chunk in Array(bucketKeys).chunks(of: 200) {
            let keys = chunk
            let descriptor = FetchDescriptor<LocationCacheRecord>(
                predicate: #Predicate { keys.contains($0.bucketKey) && $0.localeIdentifier == locale }
            )
            for record in try context.fetch(descriptor) {
                matched[record.bucketKey] = record.location
            }
        }
        return matched
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

private actor AnalysisCacheReader: AnalysisCacheReading {
    private let container: ModelContainer

    init(container: ModelContainer) { self.container = container }

    func load(for assets: [PhotoAssetDescriptor]) throws -> MediaAnalysisCacheSnapshot {
        try Task.checkCancellation()
        // A fresh actor-owned context sees batches saved by the writer and never
        // transfers SwiftData model objects to the main actor.
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let decoder = JSONDecoder()
        let signatures = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, MediaAnalysisResult.signature(for: $0)) })
        var results: [String: MediaAnalysisResult] = [:]
        var missingAssetIDs = Set<String>()
        try Task.checkCancellation()
        for record in try context.fetch(FetchDescriptor<MediaAnalysisCacheRecord>()) {
            try Task.checkCancellation()
            guard let signature = signatures[record.assetIdentifier] else {
                missingAssetIDs.insert(record.assetIdentifier)
                continue
            }
            guard signature == record.signature else { continue }
            results[record.assetIdentifier] = record.decodedResult(using: decoder)
        }
        return MediaAnalysisCacheSnapshot(results: results, missingAssetIDs: missingAssetIDs)
    }
}

private extension Array {
    func chunks(of size: Int) -> [[Element]] {
        guard size > 0, !isEmpty else { return isEmpty ? [] : [self] }
        var result: [[Element]] = []
        result.reserveCapacity((count + size - 1) / size)
        var index = startIndex
        while index < endIndex {
            let next = self.index(index, offsetBy: size, limitedBy: endIndex) ?? endIndex
            result.append(Array(self[index..<next]))
            index = next
        }
        return result
    }
}
