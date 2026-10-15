import Foundation

enum MediaTypeCategory: String, CaseIterable, Codable, Sendable {
    case screenshots, similarPhotos, livePhotos, videos, largePhotos
    case bursts, favorites, panoramas, selfies

    var key: GroupKey { GroupKey(kind: .type, value: rawValue) }

    var title: String {
        switch self {
        case .screenshots: String(localized: "Screenshots")
        case .similarPhotos: String(localized: "Similar Photos")
        case .livePhotos: String(localized: "Live Photos")
        case .videos: String(localized: "Videos")
        case .largePhotos: String(localized: "Large Photos")
        case .bursts: String(localized: "Bursts")
        case .favorites: String(localized: "Favorites")
        case .panoramas: String(localized: "Panoramas")
        case .selfies: String(localized: "Selfies")
        }
    }

    func contains(_ asset: PhotoAssetDescriptor, analysis: MediaAnalysisResult?, similarIDs: Set<String>) -> Bool {
        switch self {
        case .screenshots: asset.isScreenshot
        case .similarPhotos: similarIDs.contains(asset.id)
        case .livePhotos: asset.mediaKind == .livePhoto
        case .videos: asset.mediaKind == .video
        case .largePhotos: asset.mediaKind != .video && analysis?.isLarge == true
        case .bursts: asset.burstIdentifier != nil
        case .favorites: asset.isFavorite
        case .panoramas: asset.isPanorama
        case .selfies: asset.mediaKind != .video && asset.isSelfie
        }
    }
}

struct MediaAnalysisResult: Codable, Sendable, Equatable {
    static let version = 1
    static let largePhotoThreshold: Int64 = 20_000_000

    // nil means unavailable, never a confirmed negative.
    var isLarge: Bool?
    var featurePrint: Data?
    var perceptualHash: UInt64?
    var similarityUnavailable = false

    var isComplete: Bool {
        isLarge != nil && featurePrint != nil && perceptualHash != nil
    }

    static func signature(for asset: PhotoAssetDescriptor) -> String {
        "\(version)|\(asset.modificationDate?.timeIntervalSince1970.description ?? "nil")|\(asset.pixelWidth)x\(asset.pixelHeight)|\(asset.mediaKind.rawValue)"
    }
}

struct MediaAnalysisCacheEntry: Sendable {
    let asset: PhotoAssetDescriptor
    let result: MediaAnalysisResult
}

struct MediaAnalysisCacheSnapshot: Sendable {
    let results: [String: MediaAnalysisResult]
    let missingAssetIDs: Set<String>
}

struct SimilarPhotoCluster: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let assetIDs: [String]
}

struct CleanupWorkUnit: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case swipe, comparison }
    var kind: Kind
    var assetIDs: [String]
    var contextAssetIDs: [String]
    var clusterID: String?

    static func swipe(_ id: String) -> Self {
        Self(kind: .swipe, assetIDs: [id], contextAssetIDs: [], clusterID: nil)
    }
}

struct CleanupWorkPlan: Codable, Sendable, Equatable {
    var units: [CleanupWorkUnit]
    var draftDeleteIDs: Set<String> = []

    var assetIDs: [String] { units.flatMap(\.assetIDs) }
}
