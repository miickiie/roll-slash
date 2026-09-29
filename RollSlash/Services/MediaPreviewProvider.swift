import AVFoundation
import Photos
import PhotosUI
import UIKit

enum PreviewRequestKind: Sendable {
    case thumbnail
    case active
}

@MainActor
protocol MediaPreviewProvider: AnyObject {
    func image(for identifier: String, targetSize: CGSize, kind: PreviewRequestKind) async -> UIImage?
    func livePhoto(for identifier: String, targetSize: CGSize) async -> PHLivePhoto?
    func playerItem(for identifier: String) async -> AVPlayerItem?
    func startCaching(identifiers: [String], targetSize: CGSize)
    func stopCachingAll()
}

@MainActor
final class PhotoKitMediaPreviewProvider: MediaPreviewProvider {
    private let manager = PHCachingImageManager()
    private var cachedAssets: [String: PHAsset] = [:]
    private var cachedTargetSize: CGSize?

    func image(for identifier: String, targetSize: CGSize, kind: PreviewRequestKind) async -> UIImage? {
        guard let asset = asset(for: identifier) else { return nil }
        let options = PHImageRequestOptions()
        options.deliveryMode = kind == .thumbnail ? .fastFormat : .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = kind == .active
        let requestSize = kind == .thumbnail ? targetSize.bounded(to: 600) : targetSize

        let stream = AsyncStream<UIImage?> { continuation in
            let contentMode: PHImageContentMode = kind == .thumbnail ? .aspectFill : .aspectFit
            let requestID = manager.requestImage(for: asset, targetSize: requestSize, contentMode: contentMode, options: options) { image, _ in
                continuation.yield(image)
                continuation.finish()
            }
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { @MainActor in self?.manager.cancelImageRequest(requestID) }
            }
        }
        for await image in stream { return image }
        return nil
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

    func startCaching(identifiers: [String], targetSize: CGSize) {
        let options = cachingOptions()
        if let cachedTargetSize, cachedTargetSize != targetSize {
            manager.stopCachingImages(
                for: Array(cachedAssets.values), targetSize: cachedTargetSize,
                contentMode: .aspectFit, options: options
            )
            cachedAssets.removeAll()
        }
        cachedTargetSize = targetSize

        let requested = Set(identifiers)
        let removed = cachedAssets.filter { !requested.contains($0.key) }
        if !removed.isEmpty {
            manager.stopCachingImages(
                for: Array(removed.values), targetSize: targetSize,
                contentMode: .aspectFit, options: options
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
            for: added, targetSize: targetSize, contentMode: .aspectFit, options: options
        )
    }

    func stopCachingAll() {
        manager.stopCachingImagesForAllAssets()
        cachedAssets.removeAll()
        cachedTargetSize = nil
    }

    private func cachingOptions() -> PHImageRequestOptions {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        return options
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
