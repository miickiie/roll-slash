import Foundation
import SwiftData

enum RollSlashSchema {
    static var schema: Schema {
        Schema([
            AssetDecisionRecord.self,
            CleanupSessionRecord.self,
            CleanupActionRecord.self,
            GroupCompletionRecord.self,
            LocationCacheRecord.self
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
        self.cursor = 0
        self.statusRaw = CleanupSessionStatus.swiping.rawValue
        self.createdAt = .now
    }

    var groupKind: GroupKind { GroupKind(rawValue: groupKindRaw) ?? .month }
    var selectedGroupKeys: [String] {
        get { Self.decode([String].self, from: selectedGroupKeysData) ?? [] }
        set { selectedGroupKeysData = Self.encode(newValue) }
    }
    var orderedAssetIDs: [String] {
        get { Self.decode([String].self, from: orderedAssetIDsData) ?? [] }
        set { orderedAssetIDsData = Self.encode(newValue) }
    }
    var reviewSelectedIDs: [String] {
        get { Self.decode([String].self, from: reviewSelectedIDsData) ?? [] }
        set { reviewSelectedIDsData = Self.encode(newValue) }
    }
    var decisionBaselines: [SessionDecisionBaseline]? {
        get {
            guard let data = decisionBaselinesData else { return nil }
            return Self.decode([SessionDecisionBaseline].self, from: data)
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

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        try? JSONDecoder().decode(type, from: data)
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
