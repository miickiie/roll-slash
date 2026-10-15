import AVFoundation
import Foundation
import Photos
import PhotosUI
import UIKit

enum PreviewRequestKind: Sendable, Hashable {
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

    /// Waits for PhotoKit's final callback. Degraded frames stay open until the finished image, an error, or cancellation.
    static func finalResult<Value: Sendable>(
        start: (@escaping @Sendable (Value?, [AnyHashable: Any]?) -> Void) -> PHImageRequestID,
        cancel: @escaping @MainActor @Sendable (PHImageRequestID) -> Void
    ) async -> Value? {
        guard !Task.isCancelled else { return nil }
        let stream = AsyncStream<Value?> { continuation in
            let requestID = start { value, info in
                let cancelled = info?[PHImageCancelledKey] as? Bool == true
                let error = info?[PHImageErrorKey] != nil
                let degraded = info?[PHImageResultIsDegradedKey] as? Bool == true
                if !cancelled && !error && degraded { return }
                continuation.yield(cancelled || error ? nil : value)
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                Task { @MainActor in cancel(requestID) }
            }
        }
        for await value in stream { return Task.isCancelled ? nil : value }
        return nil
    }
}

@MainActor
enum PreviewResourceDelivery {
    static func write(
        to destination: URL,
        start: (@escaping @Sendable (Data) -> Void, @escaping @Sendable ((any Error)?) -> Void) -> PHAssetResourceDataRequestID,
        cancel: @escaping @MainActor @Sendable (PHAssetResourceDataRequestID) -> Void
    ) async throws {
        try Task.checkCancellation()
        do {
            let file = try PreviewResourceFile(destination: destination)
            defer { file.close() }
            let stream = AsyncThrowingStream<Void, any Error> { continuation in
                let requestID = start({ data in
                    do { try file.write(data) }
                    catch { continuation.finish(throwing: error) }
                }, { error in
                    if let error { continuation.finish(throwing: error) }
                    else { continuation.finish() }
                })
                continuation.onTermination = { @Sendable _ in
                    file.close()
                    Task { @MainActor in cancel(requestID) }
                }
            }
            for try await _ in stream {}
            try Task.checkCancellation()
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
}

/// PhotoKit callbacks may arrive after cancellation. The lock keeps late writes
/// from touching a closed file and avoids buffering an entire video in memory.
private final class PreviewResourceFile: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: FileHandle?

    init(destination: URL) throws {
        try Data().write(to: destination, options: .withoutOverwriting)
        handle = try FileHandle(forWritingTo: destination)
    }

    func write(_ data: Data) throws {
        try lock.withLock { try handle?.write(contentsOf: data) }
    }

    func close() {
        lock.withLock {
            try? handle?.close()
            handle = nil
        }
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
    func invalidateCachedImages()
    func invalidateCachedImages(for identifiers: Set<String>)
}

extension MediaPreviewProvider {
    func invalidateCachedImages() {}
    func invalidateCachedImages(for identifiers: Set<String>) {}
}

@MainActor
final class PreviewImageCache {
    struct Key: Hashable {
        let identifier: String
        let kind: PreviewRequestKind
        let width: Int
        let height: Int

        init(identifier: String, kind: PreviewRequestKind, targetSize: CGSize) {
            self.identifier = identifier
            self.kind = kind
            width = Int(targetSize.width.rounded())
            height = Int(targetSize.height.rounded())
        }
    }

    private struct Entry {
        let image: UIImage
        let cost: Int
    }

    private let byteLimit: Int
    private let countLimit: Int
    private var entries: [Key: Entry] = [:]
    private var order: [Key] = []
    private(set) var generation = 0
    private(set) var byteCount = 0

    init(byteLimit: Int = 48 * 1024 * 1024, countLimit: Int = 96) {
        self.byteLimit = max(0, byteLimit)
        self.countLimit = max(0, countLimit)
    }

    func image(for key: Key) -> UIImage? {
        guard let entry = entries[key] else { return nil }
        touch(key)
        return entry.image
    }

    func store(_ image: UIImage, for key: Key, generation: Int) {
        guard generation == self.generation, countLimit > 0 else { return }
        let cost: Int
        if let pixels = image.cgImage {
            let size = pixels.bytesPerRow.multipliedReportingOverflow(by: pixels.height)
            guard !size.overflow else { return }
            cost = size.partialValue
        } else {
            let size = image.size.width * image.size.height * image.scale * image.scale * 4
            guard size.isFinite, size > 0, size < CGFloat(Int.max) else { return }
            cost = Int(size)
        }
        guard cost > 0, cost <= byteLimit else { return }
        if let previous = entries[key] { byteCount -= previous.cost }
        entries[key] = Entry(image: image, cost: cost)
        byteCount += cost
        touch(key)
        while byteCount > byteLimit || entries.count > countLimit {
            let oldest = order.removeFirst()
            if let removed = entries.removeValue(forKey: oldest) { byteCount -= removed.cost }
        }
    }

    func removeAll() {
        generation += 1
        entries.removeAll()
        order.removeAll()
        byteCount = 0
    }

    func remove(for identifiers: Set<String>) {
        guard !identifiers.isEmpty else { return }
        generation += 1
        let toRemove = entries.keys.filter { identifiers.contains($0.identifier) }
        for key in toRemove {
            if let entry = entries.removeValue(forKey: key) {
                byteCount -= entry.cost
            }
        }
        order.removeAll { identifiers.contains($0.identifier) }
    }

    private func touch(_ key: Key) {
        order.removeAll { $0 == key }
        order.append(key)
    }
}

private final class PreviewMemoryWarningObservation {
    private let token: NSObjectProtocol

    init(handler: @escaping @Sendable () -> Void) {
        token = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { _ in handler() }
    }

    deinit { NotificationCenter.default.removeObserver(token) }
}

@MainActor
final class PhotoKitMediaPreviewProvider: MediaPreviewProvider {
    private let manager = PHCachingImageManager()
    private var cachedAssets: [String: PHAsset] = [:]
    private var resolvedAssets: [String: PHAsset] = [:]
    private let renderedImages: PreviewImageCache
    private var cachedConfiguration: PreviewImageConfiguration?
    private var cachedKind: PreviewRequestKind?
    private var memoryWarningObservation: PreviewMemoryWarningObservation?

    init(imageCache: PreviewImageCache = PreviewImageCache()) {
        renderedImages = imageCache
        memoryWarningObservation = PreviewMemoryWarningObservation { [weak self] in
            Task { @MainActor in self?.invalidateCachedImages() }
        }
    }

    func image(for identifier: String, targetSize: CGSize, kind: PreviewRequestKind) async -> UIImage? {
        guard !Task.isCancelled else { return nil }
        let configuration = PreviewImageConfiguration(kind: kind, targetSize: targetSize)
        let key = kind == .fullResolution ? nil
            : PreviewImageCache.Key(identifier: identifier, kind: kind, targetSize: configuration.targetSize)
        if let key, let cached = renderedImages.image(for: key) { return cached }
        let generation = renderedImages.generation
        guard let asset = asset(for: identifier) else { return nil }
        let image = await PreviewImageDelivery.image(kind: kind) { handler in
            manager.requestImage(for: asset, targetSize: configuration.targetSize,
                                 contentMode: configuration.contentMode, options: configuration.options,
                                 resultHandler: handler)
        } cancel: { [manager] requestID in
            manager.cancelImageRequest(requestID)
        }
        if let image, let key {
            renderedImages.store(image, for: key, generation: generation)
        }
        return image
    }

    func livePhoto(for identifier: String, targetSize: CGSize) async -> PHLivePhoto? {
        guard let asset = asset(for: identifier) else { return nil }
        let options = PHLivePhotoRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        return await PreviewImageDelivery.finalResult { handler in
            manager.requestLivePhoto(for: asset, targetSize: targetSize, contentMode: .aspectFit, options: options, resultHandler: handler)
        } cancel: { [manager] requestID in
            manager.cancelImageRequest(requestID)
        }
    }

    func playerItem(for identifier: String) async -> AVPlayerItem? {
        guard let asset = asset(for: identifier) else { return nil }
        let options = PHVideoRequestOptions()
        options.deliveryMode = .automatic
        options.isNetworkAccessAllowed = true
        return await PreviewImageDelivery.finalResult { handler in
            manager.requestPlayerItem(forVideo: asset, options: options, resultHandler: handler)
        } cancel: { [manager] requestID in
            manager.cancelImageRequest(requestID)
        }
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
        let resourceManager = PHAssetResourceManager.default()
        try await PreviewResourceDelivery.write(to: destination) { dataReceived, completed in
            resourceManager.requestData(for: resource, options: options,
                                        dataReceivedHandler: dataReceived, completionHandler: completed)
        } cancel: { requestID in
            resourceManager.cancelDataRequest(requestID)
        }
        return destination
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
            self.rememberResolved(asset)
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

    func invalidateCachedImages() {
        stopCachingAll()
        renderedImages.removeAll()
        resolvedAssets.removeAll()
    }

    func invalidateCachedImages(for identifiers: Set<String>) {
        guard !identifiers.isEmpty else { return }
        for id in identifiers {
            if let asset = cachedAssets.removeValue(forKey: id), let config = cachedConfiguration {
                manager.stopCachingImages(for: [asset], targetSize: config.targetSize,
                                          contentMode: config.contentMode, options: config.options)
            }
            resolvedAssets.removeValue(forKey: id)
        }
        renderedImages.remove(for: identifiers)
    }

    private func asset(for identifier: String) -> PHAsset? {
        if let cached = cachedAssets[identifier] ?? resolvedAssets[identifier] { return cached }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else { return nil }
        rememberResolved(asset)
        return asset
    }

    private func rememberResolved(_ asset: PHAsset) {
        let identifier = asset.localIdentifier
        if resolvedAssets[identifier] == nil, resolvedAssets.count >= 256, let oldest = resolvedAssets.keys.first {
            resolvedAssets.removeValue(forKey: oldest)
        }
        resolvedAssets[identifier] = asset
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
