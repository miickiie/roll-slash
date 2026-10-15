import AVFoundation
import Foundation
import OSLog
import Photos
import PhotosUI
import UIKit

enum PreviewRequestKind: Sendable, Hashable {
    case thumbnail
    case active
    case comparison
    case fullResolution
}

struct PreviewFailure: Sendable, Equatable {
    let domain: String
    let code: Int
    let isInCloud: Bool

    init(error: (any Error)? = nil, isInCloud: Bool = false) {
        let error = error as NSError?
        domain = error?.domain ?? "PhotoKit"
        code = error?.code ?? 0
        self.isInCloud = isInCloud
    }

    var isMissingResource: Bool {
        domain == PHPhotosErrorDomain && code == PHPhotosError.Code.missingResource.rawValue && !isInCloud
    }
}

enum PreviewResult<Value: Sendable>: Sendable {
    case success(Value)
    case failure(PreviewFailure)
    case cancelled

    var value: Value? {
        if case .success(let value) = self { return value }
        return nil
    }
}

private enum PreviewDiagnostics {
    static let logger = Logger(subsystem: "com.rollslash.app", category: "Media preview")

    static func record(_ failure: PreviewFailure, identifier: String, stage: String,
                       kind: PreviewRequestKind, configuration: PreviewImageConfiguration,
                       networkAccessAllowed: Bool? = nil) {
        let network = networkAccessAllowed ?? configuration.options.isNetworkAccessAllowed
        logger.debug("Preview failure asset=\(identifier, privacy: .private(mask: .hash)) stage=\(stage, privacy: .public) kind=\(String(describing: kind), privacy: .public) size=\(String(describing: configuration.targetSize), privacy: .public) version=\(configuration.options.version.rawValue) network=\(network) domain=\(failure.domain, privacy: .public) code=\(failure.code) cloud=\(failure.isInCloud)")
    }
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
    /// Waits for PhotoKit's final callback. Degraded frames stay open until the finished image, an error, or cancellation.
    static func result<Value: Sendable>(
        acceptDegraded: Bool = false,
        isNetworkAccessAllowed: Bool = false,
        start: (@escaping @Sendable (Value?, [AnyHashable: Any]?) -> Void) -> PHImageRequestID,
        cancel: @escaping @MainActor @Sendable (PHImageRequestID) -> Void
    ) async -> PreviewResult<Value> {
        guard !Task.isCancelled else { return .cancelled }
        let stream = AsyncStream<PreviewResult<Value>> { continuation in
            let requestID = start { value, info in
                let cancelled = info?[PHImageCancelledKey] as? Bool == true
                let error = info?[PHImageErrorKey] as? any Error
                let inCloud = info?[PHImageResultIsInCloudKey] as? Bool == true
                let degraded = info?[PHImageResultIsDegradedKey] as? Bool == true
                if cancelled { continuation.yield(.cancelled) }
                else if let error { continuation.yield(.failure(PreviewFailure(error: error, isInCloud: inCloud))) }
                else if degraded && !acceptDegraded {
                    // A local-only request may end with a degraded nil callback for a cloud asset.
                    guard value == nil && inCloud && !isNetworkAccessAllowed else { return }
                    continuation.yield(.failure(PreviewFailure(isInCloud: true)))
                } else if let value { continuation.yield(.success(value)) }
                else { continuation.yield(.failure(PreviewFailure(isInCloud: inCloud))) }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                Task { @MainActor in cancel(requestID) }
            }
        }
        for await result in stream { return Task.isCancelled ? .cancelled : result }
        return .cancelled
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
    struct Generation: Equatable {
        let cache: Int
        let asset: Int
    }

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
    private var generation = 0
    private var assetGenerations: [String: Int] = [:]
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

    func generation(for key: Key) -> Generation {
        Generation(cache: generation, asset: assetGenerations[key.identifier, default: 0])
    }

    func store(_ image: UIImage, for key: Key, generation: Generation) {
        guard generation == self.generation(for: key), countLimit > 0 else { return }
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
        assetGenerations.removeAll()
        entries.removeAll()
        order.removeAll()
        byteCount = 0
    }

    func remove(for identifiers: Set<String>) {
        guard !identifiers.isEmpty else { return }
        for id in identifiers { assetGenerations[id, default: 0] += 1 }
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

/// Shares requests between views while allowing each view to cancel independently.
@MainActor
final class PreviewImageLoader {
    private struct Pending {
        let id: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<UIImage?, Never>]
    }

    private let cache: PreviewImageCache
    private var pending: [PreviewImageCache.Key: Pending] = [:]
    private var missingResources: Set<PreviewImageCache.Key> = []
    private var failureOrder: [PreviewImageCache.Key] = []

    init(cache: PreviewImageCache = PreviewImageCache()) { self.cache = cache }

    func image(for key: PreviewImageCache.Key,
               load: @escaping @MainActor () async -> PreviewResult<UIImage>) async -> UIImage? {
        guard !Task.isCancelled else { return nil }
        if let image = cache.image(for: key) { return image }
        if missingResources.contains(key) { return nil }
        let waiterID = UUID()
        let image: UIImage? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: nil); return }
                if pending[key] != nil {
                    pending[key]?.waiters[waiterID] = continuation
                } else {
                    let requestID = UUID()
                    let generation = cache.generation(for: key)
                    let task = Task { [weak self] in
                        let result = await load()
                        guard let self, pending[key]?.id == requestID else { return }
                        let waiters = pending.removeValue(forKey: key)?.waiters.values
                        if !Task.isCancelled {
                            switch result {
                            case .success(let image) where key.kind != .fullResolution:
                                cache.store(image, for: key, generation: generation)
                            case .failure(let failure) where failure.isMissingResource:
                                missingResources.insert(key)
                                failureOrder.append(key)
                                while failureOrder.count > 96 { missingResources.remove(failureOrder.removeFirst()) }
                            default: break
                            }
                        }
                        waiters?.forEach { $0.resume(returning: Task.isCancelled ? nil : result.value) }
                    }
                    pending[key] = Pending(id: requestID, task: task, waiters: [waiterID: continuation])
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(waiter: waiterID, for: key) }
        }
        return Task.isCancelled ? nil : image
    }

    func hasResult(for key: PreviewImageCache.Key) -> Bool {
        missingResources.contains(key) || cache.image(for: key) != nil
    }

    /// Releases rendered images without interrupting views waiting for a preview.
    func removeCachedImages() {
        cache.removeAll()
    }

    func invalidate(for identifiers: Set<String>? = nil) {
        let keys = pending.keys.filter { identifiers?.contains($0.identifier) ?? true }
        for key in keys {
            if let request = pending.removeValue(forKey: key) {
                request.task.cancel()
                request.waiters.values.forEach { $0.resume(returning: nil) }
            }
        }
        if let identifiers {
            cache.remove(for: identifiers)
            missingResources = missingResources.filter { !identifiers.contains($0.identifier) }
            failureOrder.removeAll { identifiers.contains($0.identifier) }
        } else {
            cache.removeAll()
            missingResources.removeAll()
            failureOrder.removeAll()
        }
    }

    private func cancel(waiter: UUID, for key: PreviewImageCache.Key) {
        guard let continuation = pending[key]?.waiters.removeValue(forKey: waiter) else { return }
        continuation.resume(returning: nil)
        if pending[key]?.waiters.isEmpty == true { pending.removeValue(forKey: key)?.task.cancel() }
    }
}

/// AVFoundation's legacy asset type has no Sendable conformance. The wrapped asset
/// is read-only, is never exposed for mutation, and is used by the poster actor.
struct VideoPosterAsset: @unchecked Sendable {
    fileprivate let value: AVAsset
    init(_ asset: AVAsset) { value = asset }
}

/// AVFoundation doesn't mark its generator Sendable. Serialize its control calls;
/// completion callbacks transfer only an immutable CGImage or an error.
private final class VideoPosterFrameRequest: @unchecked Sendable {
    private let lock = NSLock()
    private let generator: AVAssetImageGenerator
    private var cancelled = false

    init(asset: VideoPosterAsset, targetSize: CGSize) {
        generator = AVAssetImageGenerator(asset: asset.value)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = targetSize.width > 0 && targetSize.height > 0
            ? targetSize.bounded(to: 1600) : CGSize(width: 1600, height: 1600)
    }

    func image() async throws -> CGImage {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let started = lock.withLock {
                    guard !cancelled else { return false }
                    generator.generateCGImageAsynchronously(for: .zero) { image, _, error in
                        if let image { continuation.resume(returning: image) }
                        else { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
                    }
                    return true
                }
                if !started { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: { self.cancel() }
    }

    private func cancel() {
        lock.withLock {
            cancelled = true
            generator.cancelAllCGImageGeneration()
        }
    }
}

/// Bounded frame extraction avoids decoding full-resolution videos on the main actor.
actor VideoPosterGenerator {
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func image(for asset: VideoPosterAsset, targetSize: CGSize) async throws -> UIImage {
        if active >= 2 { await withCheckedContinuation { waiters.append($0) } }
        else { active += 1 }
        defer {
            if waiters.isEmpty { active -= 1 }
            else { waiters.removeFirst().resume() }
        }
        try Task.checkCancellation()
        let request = VideoPosterFrameRequest(asset: asset, targetSize: targetSize)
        let frame = try await request.image()
        try Task.checkCancellation()
        return UIImage(cgImage: frame)
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
    private let imageLoader: PreviewImageLoader
    private let posterGenerator = VideoPosterGenerator()
    private var cachedConfiguration: PreviewImageConfiguration?
    private var cachedKind: PreviewRequestKind?
    private var memoryWarningObservation: PreviewMemoryWarningObservation?

    init(imageCache: PreviewImageCache = PreviewImageCache()) {
        imageLoader = PreviewImageLoader(cache: imageCache)
        memoryWarningObservation = PreviewMemoryWarningObservation { [weak self] in
            Task { @MainActor in self?.releaseCachedImages() }
        }
    }

    func image(for identifier: String, targetSize: CGSize, kind: PreviewRequestKind) async -> UIImage? {
        guard !Task.isCancelled else { return nil }
        let configuration = PreviewImageConfiguration(kind: kind, targetSize: targetSize)
        let key = PreviewImageCache.Key(identifier: identifier, kind: kind,
            targetSize: kind == .fullResolution ? .zero : configuration.targetSize)
        return await imageLoader.image(for: key) { [self] in
            guard let asset = asset(for: identifier) else {
                let failure = PreviewFailure(error: NSError(domain: PHPhotosErrorDomain,
                    code: PHPhotosError.Code.identifierNotFound.rawValue))
                PreviewDiagnostics.record(failure, identifier: identifier, stage: "asset-lookup",
                                          kind: kind, configuration: configuration)
                return .failure(failure)
            }
            return await loadImage(for: asset, kind: kind, configuration: configuration)
        }
    }

    private func loadImage(for asset: PHAsset, kind: PreviewRequestKind,
                           configuration: PreviewImageConfiguration) async -> PreviewResult<UIImage> {
        let result = await PreviewImageDelivery.result(acceptDegraded: kind == .thumbnail,
            isNetworkAccessAllowed: configuration.options.isNetworkAccessAllowed) { handler in
                manager.requestImage(for: asset, targetSize: configuration.targetSize,
                                     contentMode: configuration.contentMode, options: configuration.options,
                                     resultHandler: handler)
        } cancel: { [manager] requestID in
            manager.cancelImageRequest(requestID)
        }
        guard !Task.isCancelled else { return .cancelled }
        guard case .failure(let failure) = result else { return result }
        PreviewDiagnostics.record(failure, identifier: asset.localIdentifier, stage: "image",
                                  kind: kind, configuration: configuration)
        guard asset.mediaType == .video else { return result }

        let options = PHVideoRequestOptions()
        options.version = .current
        options.deliveryMode = .automatic
        options.isNetworkAccessAllowed = false
        let video: PreviewResult<VideoPosterAsset> = await PreviewImageDelivery.result { handler in
            manager.requestAVAsset(forVideo: asset, options: options) { asset, _, info in
                handler(asset.map(VideoPosterAsset.init), info)
            }
        } cancel: { [manager] requestID in manager.cancelImageRequest(requestID) }
        switch video {
        case .cancelled: return .cancelled
        case .failure(let failure):
            PreviewDiagnostics.record(failure, identifier: asset.localIdentifier, stage: "poster-video",
                                      kind: kind, configuration: configuration, networkAccessAllowed: false)
            return .failure(failure)
        case .success(let video):
            do {
                return .success(try await posterGenerator.image(for: video, targetSize: configuration.targetSize))
            } catch is CancellationError { return .cancelled }
            catch {
                guard !Task.isCancelled else { return .cancelled }
                let failure = PreviewFailure(error: error)
                PreviewDiagnostics.record(failure, identifier: asset.localIdentifier, stage: "poster-frame",
                                          kind: kind, configuration: configuration, networkAccessAllowed: false)
                return .failure(failure)
            }
        }
    }

    func livePhoto(for identifier: String, targetSize: CGSize) async -> PHLivePhoto? {
        guard let asset = asset(for: identifier) else { return nil }
        let options = PHLivePhotoRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        let result = await PreviewImageDelivery.result(isNetworkAccessAllowed: true) { handler in
            manager.requestLivePhoto(for: asset, targetSize: targetSize, contentMode: .aspectFit, options: options, resultHandler: handler)
        } cancel: { [manager] requestID in
            manager.cancelImageRequest(requestID)
        }
        if case .failure(let failure) = result {
            PreviewDiagnostics.record(failure, identifier: identifier, stage: "live-photo", kind: .active,
                                      configuration: PreviewImageConfiguration(kind: .active, targetSize: targetSize))
        }
        return result.value
    }

    func playerItem(for identifier: String) async -> AVPlayerItem? {
        guard let asset = asset(for: identifier) else { return nil }
        let options = PHVideoRequestOptions()
        options.deliveryMode = .automatic
        options.isNetworkAccessAllowed = true
        let result = await PreviewImageDelivery.result(isNetworkAccessAllowed: true) { handler in
            manager.requestPlayerItem(forVideo: asset, options: options, resultHandler: handler)
        } cancel: { [manager] requestID in
            manager.cancelImageRequest(requestID)
        }
        if case .failure(let failure) = result {
            PreviewDiagnostics.record(failure, identifier: identifier, stage: "player-item", kind: .active,
                                      configuration: PreviewImageConfiguration(kind: .active, targetSize: .zero))
        }
        return result.value
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
        guard kind != .fullResolution else { stopCachingAll(); return }
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

        let missing = identifiers.filter {
            cachedAssets[$0] == nil && !imageLoader.hasResult(for: PreviewImageCache.Key(
                identifier: $0, kind: kind, targetSize: configuration.targetSize))
        }
        guard !missing.isEmpty else { return }
        let result = PHAsset.fetchAssets(withLocalIdentifiers: missing, options: nil)
        var added: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in
            self.cachedAssets[asset.localIdentifier] = asset
            self.rememberResolved(asset)
            // Upcoming cards load their video posters through the fallback-aware loader.
            if asset.mediaType != .video { added.append(asset) }
        }
        guard !added.isEmpty else { return }
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

    private func releaseCachedImages() {
        stopCachingAll()
        imageLoader.removeCachedImages()
        resolvedAssets.removeAll()
    }

    func invalidateCachedImages() {
        stopCachingAll()
        imageLoader.invalidate()
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
        imageLoader.invalidate(for: identifiers)
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
