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
        let result = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        var assets: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in assets.append(asset) }
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        manager.startCachingImages(for: assets, targetSize: targetSize, contentMode: .aspectFit, options: options)
    }

    func stopCachingAll() {
        manager.stopCachingImagesForAllAssets()
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
