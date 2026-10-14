import AVFoundation
import PhotosUI
import UIKit

@MainActor
final class DemoPhotoLibraryClient: PhotoLibraryClient {
    var onLibraryChange: (@MainActor @Sendable () -> Void)?
    private var assets: [PhotoAssetDescriptor]
    private var favoriteIdentifiers: Set<String> = []

    init(referenceDate: Date = .now, comparisonFixtures: Bool = false) {
        let calendar = Calendar(identifier: .gregorian)
        assets = (0..<12).map { index in
            let date = calendar.date(byAdding: .month, value: -index, to: referenceDate)
            return PhotoAssetDescriptor(
                id: "demo-\(index)",
                creationDate: date,
            coordinate: index.isMultiple(of: 4) ? nil : GeoCoordinate(latitude: 13.7563 + Double(index), longitude: 100.5018),
                mediaKind: index.isMultiple(of: 5) ? .video : (index.isMultiple(of: 3) ? .livePhoto : .photo),
                duration: index.isMultiple(of: 5) ? 18 : 0,
                pixelWidth: comparisonFixtures && (index == 2 || index == 8) ? 2400 : 3024,
                pixelHeight: comparisonFixtures && (index == 2 || index == 8) ? 800 : 4032,
                isScreenshot: index == 1 || index == 2,
                isPanorama: index == 8,
                isFavorite: index == 11,
                burstIdentifier: index == 4 || index == 7 ? "demo-burst" : nil,
                isSelfie: index == 9
            )
        }
        favoriteIdentifiers = Set(assets.filter(\.isFavorite).map(\.id))
    }

    func authorizationStatus() -> PhotoPermission { .full }
    func requestAuthorization() async -> PhotoPermission { .full }
    func fetchAssets() async throws -> [PhotoAssetDescriptor] { assets }

    func existingAssetIdentifiers(in identifiers: Set<String>) async throws -> Set<String> {
        identifiers.intersection(assets.map(\.id))
    }

    func deleteAssets(with identifiers: [String]) async throws -> Set<String> {
        let deleted = Set(identifiers).intersection(Set(assets.map(\.id)))
        assets.removeAll { deleted.contains($0.id) }
        onLibraryChange?()
        return deleted
    }

    func isFavorite(with identifier: String) async -> Bool {
        favoriteIdentifiers.contains(identifier)
    }

    func setFavorite(_ favorite: Bool, for identifier: String) async throws {
        guard assets.contains(where: { $0.id == identifier }) else {
            throw PhotoLibraryFavoriteError.assetUnavailable
        }
        if favorite {
            favoriteIdentifiers.insert(identifier)
        } else {
            favoriteIdentifiers.remove(identifier)
        }
        if let index = assets.firstIndex(where: { $0.id == identifier }) { assets[index].isFavorite = favorite }
        onLibraryChange?()
    }

    func presentLimitedLibraryPicker() {}
    func openSystemSettings() {}
}

@MainActor
final class DemoMediaPreviewProvider: MediaPreviewProvider {
    let comparisonFixtures: Bool
    private var renderedImages: [String: UIImage] = [:]

    init(comparisonFixtures: Bool = false) { self.comparisonFixtures = comparisonFixtures }

    func image(for identifier: String, targetSize: CGSize, kind: PreviewRequestKind) async -> UIImage? {
        let cacheKey = "\(identifier)|\(kind)|\(Int(targetSize.width.rounded()))x\(Int(targetSize.height.rounded()))"
        if kind != .fullResolution, let cached = renderedImages[cacheKey] { return cached }
        let rendered = renderImage(for: identifier, targetSize: targetSize, kind: kind)
        if kind != .fullResolution {
            if renderedImages.count >= 48 { renderedImages.removeAll() }
            renderedImages[cacheKey] = rendered
        }
        return rendered
    }

    func invalidateCachedImages() { renderedImages.removeAll() }

    private func renderImage(for identifier: String, targetSize: CGSize, kind: PreviewRequestKind) -> UIImage {
        let boundedSize: CGSize
        let ordinal = Int(identifier.split(separator: "-").last ?? "0") ?? 0
        if comparisonFixtures {
            let ratio: CGFloat = ordinal == 2 || ordinal == 8 ? 3 : 0.75
            let longest = kind == .fullResolution ? 2400 : min(max(targetSize.width, targetSize.height), 1600)
            boundedSize = ratio > 1 ? CGSize(width: longest, height: longest / ratio)
                : CGSize(width: longest * ratio, height: longest)
        } else if identifier == "demo-2", case .active = kind,
           targetSize.width <= 900, targetSize.height <= 1200 {
            boundedSize = CGSize(width: 900, height: 300)
        } else {
            boundedSize = CGSize(width: min(max(targetSize.width, 240), 1200), height: min(max(targetSize.height, 240), 1600))
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1 // Preview target sizes are pixels, rather than screen points.
        let renderer = UIGraphicsImageRenderer(size: boundedSize, format: format)
        return renderer.image { context in
            let palette: [(UIColor, UIColor)] = [
                (.systemPink, .systemPurple),
                (.systemOrange, .systemPink),
                (.systemIndigo, .systemBlue),
                (.systemTeal, .systemGreen)
            ]
            let colors = palette[(ordinal == 2 ? 1 : ordinal) % palette.count]
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let gradient = CGGradient(
                colorsSpace: colorSpace,
                colors: [colors.0.cgColor, colors.1.cgColor] as CFArray,
                locations: [0, 1]
            )!
            context.cgContext.drawLinearGradient(
                gradient,
                start: .zero,
                end: CGPoint(x: boundedSize.width, y: boundedSize.height),
                options: []
            )
            if comparisonFixtures {
                context.cgContext.setStrokeColor(UIColor.white.cgColor)
                context.cgContext.setLineWidth(12)
                context.cgContext.stroke(CGRect(origin: .zero, size: boundedSize).insetBy(dx: 6, dy: 6))
            }
            let symbol = UIImage(systemName: "photo.stack.fill")?.withTintColor(.white.withAlphaComponent(0.72), renderingMode: .alwaysOriginal)
            let symbolSize = min(boundedSize.width, boundedSize.height) * 0.28
            symbol?.draw(in: CGRect(
                x: (boundedSize.width - symbolSize) / 2,
                y: (boundedSize.height - symbolSize) / 2,
                width: symbolSize,
                height: symbolSize
            ))
        }
    }

    func livePhoto(for identifier: String, targetSize: CGSize) async -> PHLivePhoto? { nil }
    func playerItem(for identifier: String) async -> AVPlayerItem? { nil }
    func shareableVideoURL(for identifier: String) async throws -> URL? { nil }
    func startCaching(identifiers: [String], targetSize: CGSize, kind: PreviewRequestKind) {}
    func stopCachingAll() { renderedImages.removeAll() }
}

struct DemoLocationResolver: LocationResolver {
    func resolve(_ coordinate: GeoCoordinate) async throws -> ResolvedLocation? {
        let ordinal = Int((coordinate.latitude - 13.7563).rounded())
        return ResolvedLocation(city: "Demo Place \(ordinal)", country: "Thailand")
    }
}

struct DemoMediaAnalysisClient: MediaAnalysisClient {
    var comparisonFixtures = false
    func analyze(_ asset: PhotoAssetDescriptor) async -> MediaAnalysisResult {
        MediaAnalysisResult(isLarge: asset.id == "demo-3",
                            featurePrint: Data([1]), perceptualHash: 0)
    }

    func clusters(assets: [PhotoAssetDescriptor], results: [String: MediaAnalysisResult]) async -> [SimilarPhotoCluster] {
        if comparisonFixtures {
            return [["demo-1", "demo-2", "demo-4"], ["demo-7", "demo-8"]].enumerated().compactMap { index, members in
                let ids = members.filter { id in assets.contains { $0.id == id } && results[id]?.featurePrint != nil }
                return ids.count >= 2 ? SimilarPhotoCluster(id: "demo-similar-\(index)", assetIDs: ids) : nil
            }
        }
        let ids = ["demo-1", "demo-2"].filter { id in assets.contains { $0.id == id } && results[id]?.featurePrint != nil }
        return ids.count == 2 ? [SimilarPhotoCluster(id: "demo-similar", assetIDs: ids)] : []
    }
}
