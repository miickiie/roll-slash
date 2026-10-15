import Foundation
import SwiftData

enum RollSlashSchema {
    static var schema: Schema {
        Schema([
            AssetDecisionRecord.self,
            CleanupSessionRecord.self,
            CleanupActionRecord.self,
            GroupCompletionRecord.self,
            LocationCacheRecord.self,
            MediaAnalysisCacheRecord.self
        ])
    }
}

@Model
final class AssetDecisionRecord {
    @Attribute(.unique) var assetIdentifier: String
    var decisionRaw: String
    var decidedAt: Date
    var sessionIdentifier: UUID?

    init(assetIdentifier: String, decision: AssetDecision, sessionIdentifier: UUID?) {
        self.assetIdentifier = assetIdentifier
        self.decisionRaw = decision.rawValue
        self.decidedAt = .now
        self.sessionIdentifier = sessionIdentifier
    }

    var decision: AssetDecision {
        get { AssetDecision(rawValue: decisionRaw) ?? .keep }
        set {
            decisionRaw = newValue.rawValue
            decidedAt = .now
        }
    }
}

@Model
final class CleanupSessionRecord {
    @Attribute(.unique) var identifier: UUID
    var groupKindRaw: String
    var selectedGroupKeysData: Data
    var orderedAssetIDsData: Data
    var reviewSelectedIDsData: Data
    var decisionBaselinesData: Data?
    var workPlanData: Data?
    var comparisonDraftDeleteIDsData: Data?
    @Transient private var readCache = CleanupSessionReadCache()
    var cursor: Int
    var statusRaw: String
    var createdAt: Date

    init(identifier: UUID = UUID(), groupKind: GroupKind, selectedGroupKeys: [String], orderedAssetIDs: [String]) {
        self.identifier = identifier
        self.groupKindRaw = groupKind.rawValue
        self.selectedGroupKeysData = Self.encode(selectedGroupKeys)
        self.orderedAssetIDsData = Self.encode(orderedAssetIDs)
        self.reviewSelectedIDsData = Self.encode([String]())
        self.decisionBaselinesData = nil
        self.workPlanData = nil
        self.comparisonDraftDeleteIDsData = nil
        self.cursor = 0
        self.statusRaw = CleanupSessionStatus.swiping.rawValue
        self.createdAt = .now
    }

    var groupKind: GroupKind { GroupKind(rawValue: groupKindRaw) ?? .month }
    var workPlan: CleanupWorkPlan? {
        get {
            guard var plan = readCache.plan(for: workPlanData) else { return nil }
            plan.draftDeleteIDs = draftDeleteIDs
            return plan
        }
        set {
            guard var plan = newValue else {
                workPlanData = nil
                comparisonDraftDeleteIDsData = nil
                return
            }
            let drafts = plan.draftDeleteIDs
            plan.draftDeleteIDs = []
            if readCache.plan(for: workPlanData)?.units != plan.units {
                workPlanData = Self.encode(plan)
            }
            draftDeleteIDs = drafts
        }
    }

    // Older sessions stored the draft inside the plan. An optional separate field
    // preserves that format while keeping new selection writes independent of plan size.
    var draftDeleteIDs: Set<String> {
        get {
            if let data = comparisonDraftDeleteIDsData {
                return Set(readCache.drafts.value(for: data) ?? [])
            }
            return readCache.plan(for: workPlanData)?.draftDeleteIDs ?? []
        }
        set {
            guard newValue != draftDeleteIDs else { return }
            comparisonDraftDeleteIDsData = Self.encode(newValue.sorted())
        }
    }

    func unit(at cursor: Int) -> (unit: CleanupWorkUnit, start: Int)? {
        guard cursor >= 0 else { return nil }
        if let plan = readCache.plan(for: workPlanData) {
            let starts = readCache.unitStarts
            var lower = 0, upper = starts.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if starts[middle] <= cursor { lower = middle + 1 } else { upper = middle }
            }
            guard lower > 0 else { return nil }
            let index = lower - 1, start = starts[index], unit = plan.units[index]
            return cursor < start + unit.assetIDs.count ? (unit, start) : nil
        }
        let ids = orderedAssetIDs
        return ids.indices.contains(cursor) ? (.swipe(ids[cursor]), cursor) : nil
    }
    var selectedGroupKeys: [String] {
        get { readCache.groupKeys.value(for: selectedGroupKeysData) ?? [] }
        set { selectedGroupKeysData = Self.encode(newValue) }
    }
    var orderedAssetIDs: [String] {
        get { readCache.assetIDs.value(for: orderedAssetIDsData) ?? [] }
        set { orderedAssetIDsData = Self.encode(newValue) }
    }
    var reviewSelectedIDs: [String] {
        get { readCache.reviewIDs.value(for: reviewSelectedIDsData) ?? [] }
        set { reviewSelectedIDsData = Self.encode(newValue) }
    }
    var decisionBaselines: [SessionDecisionBaseline]? {
        get {
            readCache.baselines.value(for: decisionBaselinesData)
        }
        set { decisionBaselinesData = newValue.map(Self.encode) }
    }

    func originalDecision(for assetIdentifier: String) -> AssetDecision? {
        decisionBaselines?.first { $0.assetIdentifier == assetIdentifier }?.decision ?? nil
    }
    var status: CleanupSessionStatus {
        get { CleanupSessionStatus(rawValue: statusRaw) ?? .swiping }
        set { statusRaw = newValue.rawValue }
    }

    private static func encode<T: Encodable>(_ value: T) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data()
    }

}

// Reference caches avoid observable writes from getters. Each cache compares the
// persisted bytes, so reconciliation, rollback and direct legacy-data updates invalidate it.
private final class SessionValueCache<Value: Decodable> {
    private var hasLoaded = false
    private var snapshot: Data?
    private var decoded: Value?

    func value(for data: Data?) -> Value? {
        if !hasLoaded || snapshot != data {
            hasLoaded = true
            snapshot = data
            decoded = data.flatMap { try? JSONDecoder().decode(Value.self, from: $0) }
        }
        return decoded
    }
}

private final class CleanupSessionReadCache {
    let groupKeys = SessionValueCache<[String]>()
    let assetIDs = SessionValueCache<[String]>()
    let reviewIDs = SessionValueCache<[String]>()
    let baselines = SessionValueCache<[SessionDecisionBaseline]>()
    let drafts = SessionValueCache<[String]>()
    private let workPlan = SessionValueCache<CleanupWorkPlan>()
    private var planSnapshot: Data?
    private(set) var unitStarts: [Int] = []

    func plan(for data: Data?) -> CleanupWorkPlan? {
        let plan = workPlan.value(for: data)
        if data != planSnapshot {
            planSnapshot = data
            var start = 0
            unitStarts = (plan?.units ?? []).map { unit in
                defer { start += unit.assetIDs.count }
                return start
            }
        }
        return plan
    }
}

@Model
final class CleanupActionRecord {
    @Attribute(.unique) var identifier: UUID
    var sessionIdentifier: UUID
    var sequence: Int
    var assetIdentifier: String
    var decisionRaw: String
    var isApplied: Bool

    init(sessionIdentifier: UUID, sequence: Int, assetIdentifier: String, decision: AssetDecision, isApplied: Bool = true) {
        self.identifier = UUID()
        self.sessionIdentifier = sessionIdentifier
        self.sequence = sequence
        self.assetIdentifier = assetIdentifier
        self.decisionRaw = decision.rawValue
        self.isApplied = isApplied
    }

    var decision: AssetDecision {
        get { AssetDecision(rawValue: decisionRaw) ?? .keep }
        set { decisionRaw = newValue.rawValue }
    }
}

@Model
final class GroupCompletionRecord {
    @Attribute(.unique) var groupKey: String
    var lastLabel: String
    var completedAt: Date

    init(groupKey: String, lastLabel: String, completedAt: Date = .now) {
        self.groupKey = groupKey
        self.lastLabel = lastLabel
        self.completedAt = completedAt
    }
}

@Model
final class LocationCacheRecord {
    @Attribute(.unique) var bucketKey: String
    var city: String?
    var country: String?
    var localeIdentifier: String
    var resolvedAt: Date

    init(bucketKey: String, city: String?, country: String?, localeIdentifier: String) {
        self.bucketKey = bucketKey
        self.city = city
        self.country = country
        self.localeIdentifier = localeIdentifier
        self.resolvedAt = .now
    }

    var location: ResolvedLocation {
        ResolvedLocation(city: city, country: country)
    }
}

@Model
final class MediaAnalysisCacheRecord {
    @Attribute(.unique) var assetIdentifier: String
    var signature: String
    var resultData: Data

    init(assetIdentifier: String, signature: String, result: MediaAnalysisResult) throws {
        self.assetIdentifier = assetIdentifier
        self.signature = signature
        self.resultData = try JSONEncoder().encode(result)
    }

    func decodedResult(using decoder: JSONDecoder) -> MediaAnalysisResult? {
        try? decoder.decode(MediaAnalysisResult.self, from: resultData)
    }

}
