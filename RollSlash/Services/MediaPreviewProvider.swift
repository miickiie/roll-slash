import AVFoundation
import Photos
import PhotosUI
import UIKit

enum PreviewRequestKind: Sendable, Equatable {
    case thumbnail
    case active
    case comparison
    case fullResolution
}

/// Keeps sizing, network policy, and final-quality delivery consistent across previews.
struct PreviewImageConfiguration {
    static let cardTargetSize = CGSize(width: 900, height: 1200)

    let targetSize: CGSize
    let contentMode: PHImageContentMode
    let options: PHImageRequestOptions

    init(kind: PreviewRequestKind, targetSize: CGSize) {
        self.targetSize = kind == .fullResolution ? PHImageManagerMaximumSize
            : (kind == .thumbnail ? targetSize.bounded(to: 600) : targetSize)
        contentMode = kind == .thumbnail ? .aspectFill : .aspectFit
        options = PHImageRequestOptions()
        options.version = .current
        options.deliveryMode = kind == .thumbnail ? .fastFormat : .highQualityFormat
        options.resizeMode = kind == .fullResolution ? .none : .fast
        options.isNetworkAccessAllowed = kind == .active || kind == .fullResolution
    }
}

/// Changes to an asset version or its display size cancel and replace the view's request.
struct PreviewImageRequest: Hashable {
    let identifier: String?
    let modificationDate: Date?
    let pixelWidth: CGFloat
    let pixelHeight: CGFloat
    let retryCount: Int

    init(identifier: String?, modificationDate: Date?, targetSize: CGSize, retryCount: Int = 0) {
        self.identifier = identifier
        self.modificationDate = modificationDate
        pixelWidth = targetSize.width
        pixelHeight = targetSize.height
        self.retryCount = retryCount
    }

    var targetSize: CGSize { CGSize(width: pixelWidth, height: pixelHeight) }
}

@MainActor
enum PreviewImageDelivery {
    static func image(
        kind: PreviewRequestKind,
        start: (@escaping @Sendable (UIImage?, [AnyHashable: Any]?) -> Void) -> PHImageRequestID,
        cancel: @escaping @MainActor @Sendable (PHImageRequestID) -> Void
    ) async -> UIImage? {
        guard !Task.isCancelled else { return nil }
        let stream = AsyncStream<UIImage?> { continuation in
            let requestID = start { image, info in
                let cancelled = info?[PHImageCancelledKey] as? Bool == true
                let error = info?[PHImageErrorKey] != nil
                if !cancelled && !error && kind != .thumbnail,
                   info?[PHImageResultIsDegradedKey] as? Bool == true { return }
                continuation.yield(cancelled || error ? nil : image)
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                Task { @MainActor in cancel(requestID) }
            }
        }
        for await image in stream { return Task.isCancelled ? nil : image }
        return nil
    }
}

@MainActor
protocol MediaPreviewProvider: AnyObject {
    func image(for identifier: String, targetSize: CGSize, kind: PreviewRequestKind) async -> UIImage?
    func livePhoto(for identifier: String, targetSize: CGSize) async -> PHLivePhoto?
    func playerItem(for identifier: String) async -> AVPlayerItem?
    func shareableVideoURL(for identifier: String) async throws -> URL?
    func startCaching(identifiers: [String], targetSize: CGSize, kind: PreviewRequestKind)
    func stopCachingAll()
}

@MainActor
final class PhotoKitMediaPreviewProvider: MediaPreviewProvider {
    private let manager = PHCachingImageManager()
    private var cachedAssets: [String: PHAsset] = [:]
    private var cachedConfiguration: PreviewImageConfiguration?
    private var cachedKind: PreviewRequestKind?

    func image(for identifier: String, targetSize: CGSize, kind: PreviewRequestKind) async -> UIImage? {
        guard let asset = asset(for: identifier) else { return nil }
        let configuration = PreviewImageConfiguration(kind: kind, targetSize: targetSize)
        return await PreviewImageDelivery.image(kind: kind) { handler in
            manager.requestImage(for: asset, targetSize: configuration.targetSize,
                                 contentMode: configuration.contentMode, options: configuration.options,
                                 resultHandler: handler)
        } cancel: { [manager] requestID in
            manager.cancelImageRequest(requestID)
        }
    }

    func livePhoto(for identifier: String, targetSize: CGSize) async -> PHLivePhoto? {
        guard let asset = asset(for: identifier) else { return nil }
        let options = PHLivePhotoRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        let stream = AsyncStream<PHLivePhoto?> { continuation in
            let requestID = manager.requestLivePhoto(for: asset, targetSize: targetSize, contentMode: .aspectFit, options: options) { photo, _ in
                continuation.yield(photo)
                continuation.finish()
            }
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { @MainActor in self?.manager.cancelImageRequest(requestID) }
            }
        }
        for await photo in stream { return photo }
        return nil
    }

    func playerItem(for identifier: String) async -> AVPlayerItem? {
        guard let asset = asset(for: identifier) else { return nil }
        let options = PHVideoRequestOptions()
        options.deliveryMode = .automatic
        options.isNetworkAccessAllowed = true
        let stream = AsyncStream<AVPlayerItem?> { continuation in
            let requestID = manager.requestPlayerItem(forVideo: asset, options: options) { item, _ in
                continuation.yield(item)
                continuation.finish()
            }
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { @MainActor in self?.manager.cancelImageRequest(requestID) }
            }
        }
        for await item in stream { return item }
        return nil
    }

    func shareableVideoURL(for identifier: String) async throws -> URL? {
        guard let asset = asset(for: identifier) else { return nil }
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first(where: { $0.type == .fullSizeVideo })
            ?? resources.first(where: { $0.type == .video }) else { return nil }

        let fileExtension = URL(fileURLWithPath: resource.originalFilename).pathExtension
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(fileExtension.isEmpty ? "mov" : fileExtension)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        do {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                PHAssetResourceManager.default().writeData(
                    for: resource, toFile: destination, options: options
                ) { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
            try Task.checkCancellation()
            return destination
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    func startCaching(identifiers: [String], targetSize: CGSize, kind: PreviewRequestKind) {
        let configuration = PreviewImageConfiguration(kind: kind, targetSize: targetSize)
        if let previous = cachedConfiguration,
           previous.targetSize != configuration.targetSize || cachedKind != kind {
            manager.stopCachingImages(
                for: Array(cachedAssets.values), targetSize: previous.targetSize,
                contentMode: previous.contentMode, options: previous.options
            )
            cachedAssets.removeAll()
        }
        cachedConfiguration = configuration
        cachedKind = kind

        let requested = Set(identifiers)
        let removed = cachedAssets.filter { !requested.contains($0.key) }
        if !removed.isEmpty {
            manager.stopCachingImages(
                for: Array(removed.values), targetSize: configuration.targetSize,
                contentMode: configuration.contentMode, options: configuration.options
            )
            removed.keys.forEach { cachedAssets.removeValue(forKey: $0) }
        }

        let missing = identifiers.filter { cachedAssets[$0] == nil }
        guard !missing.isEmpty else { return }
        let result = PHAsset.fetchAssets(withLocalIdentifiers: missing, options: nil)
        var added: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in
            self.cachedAssets[asset.localIdentifier] = asset
            added.append(asset)
        }
        manager.startCachingImages(
            for: added, targetSize: configuration.targetSize,
            contentMode: configuration.contentMode, options: configuration.options
        )
    }

    func stopCachingAll() {
        manager.stopCachingImagesForAllAssets()
        cachedAssets.removeAll()
        cachedConfiguration = nil
        cachedKind = nil
    }

    private func asset(for identifier: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject
    }
}

private extension CGSize {
    func bounded(to maximumDimension: CGFloat) -> CGSize {
        let largest = max(width, height)
        guard largest > maximumDimension, largest > 0 else { return self }
        let scale = maximumDimension / largest
        return CGSize(width: width * scale, height: height * scale)
    }
}
