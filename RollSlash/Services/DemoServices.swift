import AVFoundation
import PhotosUI
import UIKit

@MainActor
final class DemoPhotoLibraryClient: PhotoLibraryClient {
    var onLibraryChange: (@MainActor @Sendable () -> Void)?
    private var assets: [PhotoAssetDescriptor]

    init() {
        let calendar = Calendar(identifier: .gregorian)
        assets = (0..<12).map { index in
            let date = calendar.date(byAdding: .month, value: -index, to: .now)
            return PhotoAssetDescriptor(
                id: "demo-\(index)",
                creationDate: date,
                coordinate: index.isMultiple(of: 4) ? nil : GeoCoordinate(latitude: 13.7563, longitude: 100.5018),
                mediaKind: index.isMultiple(of: 5) ? .video : (index.isMultiple(of: 3) ? .livePhoto : .photo),
                duration: index.isMultiple(of: 5) ? 18 : 0,
                pixelWidth: 3024,
                pixelHeight: 4032
            )
        }
    }

    func authorizationStatus() -> PhotoPermission { .full }
    func requestAuthorization() async -> PhotoPermission { .full }
    func fetchAssets() async throws -> [PhotoAssetDescriptor] { assets }

    func deleteAssets(with identifiers: [String]) async throws {
        let deleted = Set(identifiers)
        assets.removeAll { deleted.contains($0.id) }
        onLibraryChange?()
    }

    func presentLimitedLibraryPicker() {}
    func openSystemSettings() {}
}

@MainActor
final class DemoMediaPreviewProvider: MediaPreviewProvider {
    func image(for identifier: String, targetSize: CGSize, kind: PreviewRequestKind) async -> UIImage? {
        let boundedSize = CGSize(width: min(max(targetSize.width, 240), 1200), height: min(max(targetSize.height, 240), 1600))
        let renderer = UIGraphicsImageRenderer(size: boundedSize)
        return renderer.image { context in
            let palette: [(UIColor, UIColor)] = [
                (.systemPink, .systemPurple),
                (.systemOrange, .systemPink),
                (.systemIndigo, .systemBlue),
                (.systemTeal, .systemGreen)
            ]
            let colors = palette[abs(identifier.hashValue) % palette.count]
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
    func startCaching(identifiers: [String], targetSize: CGSize) {}
    func stopCachingAll() {}
}

struct DemoLocationResolver: LocationResolver {
    func resolve(_ coordinate: GeoCoordinate) async throws -> ResolvedLocation? {
        ResolvedLocation(city: "Bangkok", country: "Thailand")
    }
}
