import AVFoundation
import Observation
import Photos
import SwiftData
import SwiftUI
import Testing
import UIKit
@testable import RollSlash

@MainActor
struct ViewerPreviewTests {
    @Test func comparisonRequestsWholePhotoAtDisplaySizeWithoutDownloading() {
        let size = CGSize(width: 525, height: 525)
        let config = PreviewImageConfiguration(kind: .comparison, targetSize: size)
        #expect(config.targetSize == size)
        #expect(config.contentMode == .aspectFit)
        #expect(config.options.deliveryMode == .highQualityFormat)
        #expect(!config.options.isNetworkAccessAllowed)
        #expect(config.options.version == .current)
    }

    @Test func fullResolutionUsesCurrentOriginalAndAllowsExplicitDownload() {
        let config = PreviewImageConfiguration(kind: .fullResolution, targetSize: CGSize(width: 100, height: 100))
        #expect(config.targetSize == PHImageManagerMaximumSize)
        #expect(config.contentMode == .aspectFit)
        #expect(config.options.resizeMode == .none)
        #expect(config.options.deliveryMode == .highQualityFormat)
        #expect(config.options.version == .current)
        #expect(config.options.isNetworkAccessAllowed)
    }

    @Test func thumbnailsRetainBoundedCropAndLocalPolicy() {
        let config = PreviewImageConfiguration(kind: .thumbnail, targetSize: CGSize(width: 2400, height: 1200))
        #expect(config.targetSize == CGSize(width: 600, height: 300))
        #expect(config.contentMode == .aspectFill)
        #expect(config.options.deliveryMode == .fastFormat)
        #expect(!config.options.isNetworkAccessAllowed)
    }

    @Test func degradedImagesDoNotFinishDetailedRequestsAndLateResultsAreIgnored() async {
        for kind in [PreviewRequestKind.active, .comparison, .fullResolution] {
            let degraded = UIImage()
            let final = UIImage()
            let result = await PreviewImageDelivery.result(acceptDegraded: kind == .thumbnail) { handler in
                handler(degraded, [PHImageResultIsDegradedKey: true])
                handler(final, [PHImageResultIsDegradedKey: false])
                handler(degraded, nil)
                return 1
            } cancel: { _ in }
            #expect(result.value === final)
        }
    }

    @Test func degradedLiveResultsWaitForTheFinalValue() async {
        let result = await PreviewImageDelivery.result { handler in
            handler("degraded", [PHImageResultIsDegradedKey: true])
            handler("final", [PHImageResultIsDegradedKey: false])
            handler("late", nil)
            return 1
        } cancel: { _ in }
        #expect(result.value == "final")
    }

    @Test func failedLiveResultFinishesWithoutWaiting() async {
        let result = await PreviewImageDelivery.result { handler in
            handler("nope", [PHImageErrorKey: NSError(domain: "test", code: 1), PHImageResultIsDegradedKey: true])
            handler("late", nil)
            return 1
        } cancel: { _ in }
        #expect(result.value == nil)
    }

    @Test func failedOrUnavailableOriginalFinishesWithoutAnImage() async {
        let cases: [[AnyHashable: Any]?] = [nil, [PHImageCancelledKey: true],
            [PHImageErrorKey: NSError(domain: "test", code: 1), PHImageResultIsDegradedKey: true]]
        for info in cases {
            let result: PreviewResult<UIImage> = await PreviewImageDelivery.result { handler in
                handler(nil, info)
                return 2
            } cancel: { _ in }
            #expect(result.value == nil)
        }
    }

    @Test func cancellationStopsPhotoKitAndRejectsLateImage() async throws {
        let request = PendingPreviewRequest()
        let task = Task {
            await PreviewImageDelivery.result(start: request.start, cancel: request.cancel)
        }
        for _ in 0..<100 where request.handler == nil { await Task.yield() }
        _ = try #require(request.handler)
        task.cancel()
        #expect(await task.value.value == nil)
        for _ in 0..<100 where !request.cancelled { await Task.yield() }
        #expect(request.cancelled)
        request.handler?(UIImage(), nil)
        #expect(await task.value.value == nil)
    }

    @Test("Photos failures retain their domain, code and cloud status")
    func structuredPhotosFailure() async {
        let result: PreviewResult<UIImage> = await PreviewImageDelivery.result { handler in
            handler(nil, [PHImageErrorKey: NSError(domain: PHPhotosErrorDomain,
                code: PHPhotosError.Code.missingResource.rawValue)])
            return 1
        } cancel: { _ in }
        guard case .failure(let failure) = result else { Issue.record("Expected a resource failure"); return }
        #expect(failure.domain == PHPhotosErrorDomain)
        #expect(failure.code == 3303)
        #expect(failure.isMissingResource)
        #expect(!failure.isInCloud)
    }

    @Test("cloud-only callbacks finish local requests but wait for an explicit download")
    func cloudDeliveryPolicy() async {
        let image = UIImage()
        for allowsDownload in [false, true] {
            let result: PreviewResult<UIImage> = await PreviewImageDelivery.result(
                isNetworkAccessAllowed: allowsDownload) { handler in
                    handler(nil, [PHImageResultIsDegradedKey: true, PHImageResultIsInCloudKey: true])
                    handler(image, nil)
                    return 1
            } cancel: { _ in }
            if allowsDownload { #expect(result.value === image) }
            else {
                guard case .failure(let failure) = result else { Issue.record("Expected a cloud-only failure"); continue }
                #expect(failure.isInCloud)
                #expect(!failure.isMissingResource)
            }
        }
    }

    @Test func frozenNavigationIncludesReadOnlyContextButNeverAnotherSet() {
        let sequence = ComparisonPreviewSequence(unit: CleanupWorkUnit(
            kind: .comparison, assetIDs: ["a", "b"], contextAssetIDs: ["kept"], clusterID: "first"
        ))
        let accessible: Set<String> = ["a", "b", "kept", "other-set"]
        #expect(sequence.identifiers(accessible: accessible) == ["a", "b", "kept"])
        #expect(sequence.neighbor(of: "a", step: -1, accessible: accessible) == nil)
        #expect(sequence.neighbor(of: "a", step: 1, accessible: accessible) == "b")
        #expect(sequence.neighbor(of: "b", step: 1, accessible: accessible) == "kept")
        #expect(sequence.neighbor(of: "kept", step: 1, accessible: accessible) == nil)
    }

    @Test func permissionChangesSkipMissingPhotosAndReconcileNearestSurvivor() {
        let sequence = ComparisonPreviewSequence(unit: CleanupWorkUnit(
            kind: .comparison, assetIDs: ["a", "b", "c"], contextAssetIDs: ["d"], clusterID: "first"
        ))
        #expect(sequence.neighbor(of: "a", step: 1, accessible: ["a", "c", "d"]) == "c")
        #expect(sequence.replacement(for: "b", accessible: ["a", "c", "d"]) == "c")
        #expect(sequence.replacement(for: "d", accessible: ["a", "c"]) == "c")
        #expect(sequence.replacement(for: "a", accessible: []) == nil)
    }

    @Test func restoringLibraryAccessCannotReintroduceRemovedSessionMembers() {
        let frozen = CleanupWorkUnit(kind: .comparison, assetIDs: ["a", "b", "c"],
                                     contextAssetIDs: ["kept"], clusterID: "first")
        let sequence = ComparisonPreviewSequence(unit: frozen)
        let reconciled = CleanupWorkUnit(kind: .comparison, assetIDs: ["a", "c"],
                                         contextAssetIDs: ["kept"], clusterID: "first")
        let accessible = sequence.accessibleIdentifiers(in: ["a", "b", "c", "kept", "new"], currentUnit: reconciled)
        #expect(sequence.identifiers(accessible: accessible) == ["a", "c", "kept"])
        #expect(sequence.neighbor(of: "a", step: 1, accessible: accessible) == "c")
        let other = CleanupWorkUnit(kind: .comparison, assetIDs: ["a", "new"], contextAssetIDs: [], clusterID: "second")
        #expect(sequence.accessibleIdentifiers(in: ["a", "new"], currentUnit: other).isEmpty)
    }
}

@MainActor
@Suite("Video resource export")
struct VideoResourceExportTests {
    @Test("video exports retain all received chunks")
    func writesChunks() async throws {
        let request = PendingResourceRequest()
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: destination) }
        let task = Task { try await PreviewResourceDelivery.write(to: destination, start: request.start, cancel: request.cancel) }
        for _ in 0..<100 where request.completed == nil { await Task.yield() }
        let completed = try #require(request.completed)
        request.dataReceived?(Data([1, 2]))
        request.dataReceived?(Data([3, 4]))
        completed(nil)
        try await task.value
        #expect(try Data(contentsOf: destination) == Data([1, 2, 3, 4]))
    }

    @Test("cancelling an export stops Photos, removes the file and rejects late data")
    func cancellationStopsTransfer() async throws {
        let request = PendingResourceRequest()
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: destination) }
        let task = Task { try await PreviewResourceDelivery.write(to: destination, start: request.start, cancel: request.cancel) }
        for _ in 0..<100 where request.completed == nil { await Task.yield() }
        _ = try #require(request.completed)
        request.dataReceived?(Data([1, 2]))
        task.cancel()
        do {
            try await task.value
            Issue.record("A cancelled video export must throw CancellationError")
        } catch is CancellationError {}
        for _ in 0..<100 where !request.cancelled { await Task.yield() }
        #expect(request.cancelled)
        request.dataReceived?(Data([3, 4]))
        request.completed?(nil)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test("Photos export errors remove partial video files")
    func failedTransferRemovesFile() async throws {
        let request = PendingResourceRequest()
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: destination) }
        let task = Task { try await PreviewResourceDelivery.write(to: destination, start: request.start, cancel: request.cancel) }
        for _ in 0..<100 where request.completed == nil { await Task.yield() }
        let completed = try #require(request.completed)
        request.dataReceived?(Data([1, 2]))
        completed(URLError(.networkConnectionLost))
        do {
            try await task.value
            Issue.record("A failed transfer must return the Photos error")
        } catch let error as URLError {
            #expect(error.code == .networkConnectionLost)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test("an already cancelled export never starts a Photos request")
    func cancellationBeforeStarting() async throws {
        let request = PendingResourceRequest()
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let task = Task { try await PreviewResourceDelivery.write(to: destination, start: request.start, cancel: request.cancel) }
        task.cancel()
        do {
            try await task.value
            Issue.record("An already cancelled export must throw CancellationError")
        } catch is CancellationError {}
        #expect(request.completed == nil)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }
}

@MainActor
@Suite("Video preview failure recovery", .serialized)
struct VideoPreviewPlaybackTests {
    @Test("player-item failures discovered after loading show the retry state")
    func asynchronouslyFailedItem() async throws {
        let playback = VideoPreviewPlayback()
        let missingVideo = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        playback.load(AVPlayerItem(url: missingVideo), isMuted: true)
        let deadline = ContinuousClock.now + .seconds(5)
        while !playback.hasFailed, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(playback.hasFailed)
        #expect(playback.player == nil)
        playback.reset()
        #expect(!playback.hasFailed)
    }

    @Test("dismissal detaches playback observers and ignores stale failures")
    func staleFailureAfterDismissal() async throws {
        let playback = VideoPreviewPlayback()
        let item = AVPlayerItem(asset: AVMutableComposition())
        playback.load(item, isMuted: true)
        playback.reset()
        NotificationCenter.default.post(name: AVPlayerItem.failedToPlayToEndTimeNotification, object: item)
        for _ in 0..<20 { await Task.yield() }
        #expect(!playback.hasFailed)
        #expect(playback.player == nil)
        playback.load(nil, isMuted: true)
        #expect(playback.hasFailed)
    }
}

@MainActor
private final class PendingResourceRequest {
    var dataReceived: (@Sendable (Data) -> Void)?
    var completed: (@Sendable ((any Error)?) -> Void)?
    var cancelled = false

    func start(_ dataReceived: @escaping @Sendable (Data) -> Void,
               _ completed: @escaping @Sendable ((any Error)?) -> Void) -> PHAssetResourceDataRequestID {
        self.dataReceived = dataReceived
        self.completed = completed
        return 42
    }

    func cancel(_ id: PHAssetResourceDataRequestID) { cancelled = id == 42 }
}

@MainActor
private final class PendingPreviewRequest {
    var handler: (@Sendable (UIImage?, [AnyHashable: Any]?) -> Void)?
    var cancelled = false

    func start(_ handler: @escaping @Sendable (UIImage?, [AnyHashable: Any]?) -> Void) -> PHImageRequestID {
        self.handler = handler
        return 42
    }

    func cancel(_ id: PHImageRequestID) { cancelled = id == 42 }
}

@MainActor
@Suite("Preview image cache")
struct PreviewImageCacheTests {
    @Test("recently viewed images survive count-based eviction")
    func leastRecentlyUsedEviction() {
        let cache = PreviewImageCache(countLimit: 2)
        let image = makeImage(size: 10)
        for id in ["a", "b"] { cache.store(image, for: key(id), generation: cache.generation(for: key(id))) }
        #expect(cache.image(for: key("a")) === image)
        cache.store(image, for: key("c"), generation: cache.generation(for: key("c")))
        #expect(cache.image(for: key("b")) == nil)
        #expect(cache.image(for: key("a")) === image)
        #expect(cache.image(for: key("c")) === image)
    }

    @Test("decoded byte limits evict old images and reject oversized images")
    func decodedByteLimit() throws {
        let image = makeImage(size: 10)
        let pixels = try #require(image.cgImage)
        let cost = pixels.bytesPerRow * pixels.height
        let cache = PreviewImageCache(byteLimit: cost * 2)
        for id in ["a", "b", "c"] { cache.store(image, for: key(id), generation: cache.generation(for: key(id))) }
        #expect(cache.byteCount == cost * 2)
        #expect(cache.image(for: key("a")) == nil)
        cache.store(makeImage(size: 100), for: key("oversized"), generation: cache.generation(for: key("oversized")))
        #expect(cache.image(for: key("oversized")) == nil)
        #expect(cache.image(for: key("b")) === image)
        #expect(cache.image(for: key("c")) === image)
        cache.store(image, for: key("b"), generation: cache.generation(for: key("b")))
        #expect(cache.byteCount == cost * 2)
    }

    @Test("invalidation rejects results from requests started before a library change")
    func staleRequestCannotRepopulateCache() {
        let cache = PreviewImageCache()
        let image = makeImage(size: 10)
        let oldGeneration = cache.generation(for: key("a"))
        cache.store(image, for: key("a"), generation: oldGeneration)
        cache.removeAll()
        cache.store(image, for: key("a"), generation: oldGeneration)
        #expect(cache.byteCount == 0)
        #expect(cache.image(for: key("a")) == nil)
        cache.store(image, for: key("a"), generation: cache.generation(for: key("a")))
        #expect(cache.image(for: key("a")) === image)
    }

    @Test("stopping navigation preheating preserves images until explicit invalidation")
    func navigationCacheLifecycle() async {
        let cache = PreviewImageCache()
        let image = makeImage(size: 10)
        let size = CGSize(width: 900, height: 1200)
        let request = PreviewImageCache.Key(identifier: "fixture", kind: .active, targetSize: size)
        cache.store(image, for: request, generation: cache.generation(for: request))
        let provider = PhotoKitMediaPreviewProvider(imageCache: cache)
        #expect(await provider.image(for: "fixture", targetSize: size, kind: .active) === image)
        provider.stopCachingAll()
        #expect(await provider.image(for: "fixture", targetSize: size, kind: .active) === image)
        provider.invalidateCachedImages()
        #expect(cache.image(for: request) == nil)
        #expect(cache.byteCount == 0)
    }

    @Test("selective invalidation removes only targeted identifiers and keeps unaffected images")
    func selectiveInvalidation() async {
        let cache = PreviewImageCache()
        let imageA = makeImage(size: 10)
        let imageB = makeImage(size: 10)
        let size = CGSize(width: 100, height: 100)
        let keyA = PreviewImageCache.Key(identifier: "a", kind: .active, targetSize: size)
        let keyB = PreviewImageCache.Key(identifier: "b", kind: .active, targetSize: size)
        cache.store(imageA, for: keyA, generation: cache.generation(for: keyA))
        cache.store(imageB, for: keyB, generation: cache.generation(for: keyB))

        let provider = PhotoKitMediaPreviewProvider(imageCache: cache)
        provider.invalidateCachedImages(for: ["a"])

        #expect(cache.image(for: keyA) == nil)
        #expect(cache.image(for: keyB) === imageB)
    }

    @Test("selective invalidation rejects affected requests and accepts unrelated requests already in flight")
    func selectiveInvalidationPreservesUnrelatedRequests() {
        let cache = PreviewImageCache()
        let image = makeImage(size: 10)
        let a = key("a"), b = key("b")
        let generationA = cache.generation(for: a), generationB = cache.generation(for: b)
        cache.remove(for: ["a"])
        cache.store(image, for: a, generation: generationA)
        cache.store(image, for: b, generation: generationB)
        #expect(cache.image(for: a) == nil)
        #expect(cache.image(for: b) === image)
        cache.store(image, for: a, generation: cache.generation(for: a))
        #expect(cache.image(for: a) === image)
    }

    private func key(_ id: String) -> PreviewImageCache.Key {
        PreviewImageCache.Key(identifier: id, kind: .active, targetSize: CGSize(width: 10, height: 10))
    }

    private func makeImage(size: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format).image { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        }
    }
}

@MainActor
@Suite("Shared preview requests")
struct PreviewImageLoaderTests {
    @Test("memory cleanup preserves shared preview requests without refilling the cleared cache",
          arguments: [PreviewRequestKind.thumbnail, .active, .comparison, .fullResolution])
    func memoryCleanupPreservesRequests(kind: PreviewRequestKind) async throws {
        let cache = PreviewImageCache()
        let loader = PreviewImageLoader(cache: cache)
        let cachedKey = key("cached")
        cache.store(makeImage(), for: cachedKey, generation: cache.generation(for: cachedKey))
        #expect(cache.byteCount > 0)

        let request = PendingImageLoad()
        let pendingKey = key("pending", kind: kind)
        let first = Task { await loader.image(for: pendingKey, load: request.load) }
        try #require(await waitUntil { request.calls == 1 })

        loader.removeCachedImages()
        #expect(cache.byteCount == 0)
        #expect(cache.image(for: cachedKey) == nil)

        var secondStarted = false
        let second = Task {
            secondStarted = true
            return await loader.image(for: pendingKey, load: request.load)
        }
        try #require(await waitUntil { secondStarted })
        #expect(request.calls == 1)
        let image = makeImage()
        for _ in 0..<request.calls { request.finish(at: 0, with: .success(image)) }
        #expect(await first.value === image)
        #expect(await second.value === image)
        #expect(cache.image(for: pendingKey) == nil)

        let freshImage = makeImage()
        var freshLoads = 0
        #expect(await loader.image(for: pendingKey) {
            freshLoads += 1
            return .success(freshImage)
        } === freshImage)
        #expect(freshLoads == 1)
        if kind != .fullResolution { #expect(cache.image(for: pendingKey) === freshImage) }
    }

    @Test("cancelling one view preserves another view's shared image request")
    func sharedRequestCancellation() async throws {
        let loader = PreviewImageLoader()
        let request = PendingImageLoad()
        let key = key("a")
        let first = Task { await loader.image(for: key, load: request.load) }
        try #require(await waitUntil { request.calls == 1 })
        var secondStarted = false
        let second = Task {
            secondStarted = true
            return await loader.image(for: key, load: request.load)
        }
        try #require(await waitUntil { secondStarted })
        first.cancel()
        #expect(await first.value == nil)
        #expect(request.calls == 1)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { $0.fill(CGRect(x: 0, y: 0, width: 10, height: 10)) }
        request.finish(at: 0, with: .success(image))
        #expect(await second.value === image)
        #expect(await loader.image(for: key, load: request.load) === image)
        #expect(request.calls == 1)
    }

    @Test("library changes cancel only affected requests and reject their late results")
    func invalidateDuringLoad() async throws {
        let loader = PreviewImageLoader()
        let request = PendingImageLoad()
        let old = Task { await loader.image(for: key("a"), load: request.load) }
        try #require(await waitUntil { request.calls == 1 })
        let unaffected = Task { await loader.image(for: key("b"), load: request.load) }
        try #require(await waitUntil { request.calls == 2 })
        loader.invalidate(for: ["a"])
        #expect(await old.value == nil)
        let replacement = Task { await loader.image(for: key("a"), load: request.load) }
        try #require(await waitUntil { request.calls == 3 })
        let stale = makeImage(), current = makeImage(), other = makeImage()
        request.finish(at: 0, with: .success(stale))
        request.finish(at: 0, with: .success(other))
        request.finish(at: 0, with: .success(current))
        #expect(await unaffected.value === other)
        #expect(await replacement.value === current)
        #expect(await loader.image(for: key("a"), load: request.load) === current)
        #expect(request.calls == 3)
    }

    @Test("a missing-resource failure is reused until explicit invalidation")
    func missingResourceRetry() async {
        let loader = PreviewImageLoader()
        let failure = PreviewFailure(error: NSError(domain: PHPhotosErrorDomain,
            code: PHPhotosError.Code.missingResource.rawValue))
        var calls = 0
        for _ in 0..<2 {
            #expect(await loader.image(for: key("a")) { calls += 1; return .failure(failure) } == nil)
        }
        #expect(calls == 1)
        // Local-only thumbnail failures must not block a user-initiated preview/download.
        #expect(await loader.image(for: key("a", kind: .active)) { calls += 1; return .success(UIImage()) } != nil)
        #expect(calls == 2)
        loader.invalidate(for: ["a"])
        #expect(await loader.image(for: key("a")) { calls += 1; return .success(UIImage()) } != nil)
        #expect(calls == 3)
    }

    @Test("cloud, transient and cancelled results do not poison the image cache")
    func retryableFailures() async {
        let loader = PreviewImageLoader()
        let outcomes: [PreviewResult<UIImage>] = [
            .failure(PreviewFailure(error: URLError(.timedOut))),
            .failure(PreviewFailure(error: NSError(domain: PHPhotosErrorDomain,
                code: PHPhotosError.Code.missingResource.rawValue), isInCloud: true)), .cancelled
        ]
        for (index, outcome) in outcomes.enumerated() {
            var calls = 0
            let request = key(String(index))
            for _ in 0..<2 {
                #expect(await loader.image(for: request) { calls += 1; return outcome } == nil)
            }
            #expect(calls == 2)
        }
    }

    private func key(_ id: String, kind: PreviewRequestKind = .thumbnail) -> PreviewImageCache.Key {
        PreviewImageCache.Key(identifier: id, kind: kind, targetSize: CGSize(width: 100, height: 100))
    }

    private func makeImage() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image {
            $0.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        }
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        return condition()
    }
}

@MainActor
private final class PendingImageLoad {
    private(set) var calls = 0
    private var pending: [CheckedContinuation<PreviewResult<UIImage>, Never>] = []

    func load() async -> PreviewResult<UIImage> {
        calls += 1
        return await withCheckedContinuation { pending.append($0) }
    }

    func finish(at index: Int, with result: PreviewResult<UIImage>) {
        pending.remove(at: index).resume(returning: result)
    }
}

@MainActor
@Suite("Generated video posters")
struct VideoPosterGeneratorTests {
    @Test("a local video generates a bounded poster with its display rotation")
    func boundedRotatedPoster() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 32
        ])
        input.transform = CGAffineTransform(rotationAngle: .pi / 2)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 32])
        writer.add(input)
        try #require(writer.startWriting())
        defer { if writer.status == .writing { writer.cancelWriting() } }
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        try #require(CVPixelBufferCreate(kCFAllocatorDefault, 64, 32, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess)
        let pixels = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        if let base = CVPixelBufferGetBaseAddress(pixels) {
            base.initializeMemory(as: UInt8.self, repeating: 127, count: CVPixelBufferGetBytesPerRow(pixels) * 32)
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        for frame in 0..<2 {
            let deadline = ContinuousClock.now + .seconds(5)
            while !input.isReadyForMoreMediaData, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            try #require(input.isReadyForMoreMediaData)
            try #require(adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)))
        }
        writer.endSession(atSourceTime: CMTime(value: 2, timescale: 30))
        input.markAsFinished()
        await writer.finishWriting()
        try #require(writer.status == .completed)

        let poster = try await VideoPosterGenerator().image(for: VideoPosterAsset(AVURLAsset(url: url)),
                                                           targetSize: CGSize(width: 16, height: 16))
        #expect(max(poster.size.width, poster.size.height) <= 16)
        #expect(poster.size.height > poster.size.width)
    }

    @Test("a cancelled poster request exits before attempting to decode")
    func cancelledPoster() async throws {
        let generator = VideoPosterGenerator()
        let task = Task { try await generator.image(for: VideoPosterAsset(AVURLAsset(url: URL(fileURLWithPath: "/missing.mov"))),
                                                     targetSize: CGSize(width: 100, height: 100)) }
        task.cancel()
        do { _ = try await task.value; Issue.record("A cancelled poster request must throw") }
        catch is CancellationError {}
    }
}

@MainActor
@Suite("Hosted preview lifecycle", .serialized)
struct PreviewLifecycleTests {
    @Test("same-identifier edits reload cleanup cards and thumbnails", arguments: [false, true])
    func editedAssetReloads(showsThumbnail: Bool) async throws {
        let library = PreviewTestLibrary(assets: [asset("a", modified: 1)])
        let provider = RecordingPreviewProvider()
        let model = try makeModel(library: library, provider: provider)
        await model.start()
        let layout = PreviewTestLayout()
        let host = PreviewLifecycleHost(showsThumbnail: showsThumbnail, layout: layout).environment(model)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: host)
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKeyAndVisible()
        }
        try #require(await waitUntil { provider.images.count == 1 })
        library.assets = [asset("a", modified: 2)]
        await model.reloadLibrary()
        try #require(await waitUntil { provider.images.count == 2 })
        #expect(provider.images.map(\.identifier) == ["a", "a"])
        #expect(provider.images.allSatisfy { $0.kind == (showsThumbnail ? .thumbnail : .active) })
        if showsThumbnail {
            let previousSize = provider.images.last?.targetSize
            layout.size = 120
            try #require(await waitUntil { provider.images.count == 3 })
            #expect(provider.images.last?.targetSize != previousSize)
        }
    }

    @Test("comparison preheating matches tile requests and remains bounded")
    func comparisonPreheatingMatchesTiles() async throws {
        let assets = (0..<14).map { asset("item-\($0)", modified: 1) }
        let library = PreviewTestLibrary(assets: assets)
        let provider = RecordingPreviewProvider()
        let container = try ModelContainer(for: RollSlashSchema.schema,
                                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let ids = assets.map(\.id)
        let repository = SwiftDataCleanupRepository(container: container)
        _ = try repository.createSession(groupKind: .type, selectedGroupKeys: ["type:similarPhotos"],
            orderedAssetIDs: ids, workPlan: CleanupWorkPlan(units: [
                CleanupWorkUnit(kind: .comparison, assetIDs: ids, contextAssetIDs: [], clusterID: "test")
            ]))
        let model = AppModel(photoLibrary: library, previewProvider: provider,
                             locationResolver: DemoLocationResolver(), modelContainer: container,
                             analysisClient: PreviewTestAnalysis())
        await model.start()
        model.resumeSession()
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: SimilarComparisonView()
            .environment(model).environment(\.displayScale, 3).frame(width: 300, height: 600))
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKeyAndVisible()
        }
        try #require(await waitUntil { !provider.caches.isEmpty && !provider.images.isEmpty })
        let cache = try #require(provider.caches.last)
        #expect(cache.identifiers == Array(ids.prefix(12)))
        #expect(cache.kind == .comparison)
        #expect(cache.targetSize.width == cache.targetSize.height)
        #expect(provider.images.allSatisfy { $0.kind == cache.kind && $0.targetSize == cache.targetSize })
        #expect(!PreviewImageConfiguration(kind: cache.kind, targetSize: cache.targetSize).options.isNetworkAccessAllowed)
        model.route = .dashboard
        #expect(provider.didStopCaching)
    }

    @Test("a delayed next photo is loaded before promotion and retained for undo")
    func swipePreviewsRemainLoaded() async throws {
        let provider = DelayedSwipePreviewProvider()
        let model = try await makeSwipeModel(
            assets: ["a", "b", "c", "d", "e"].map { asset($0, modified: 1) }, provider: provider
        )
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: CleanupView().environment(model))
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            provider.finishAll()
            previousKeyWindow?.makeKeyAndVisible()
        }
        try #require(await waitUntil { Set(provider.images) == ["a", "b", "c"] })
        provider.finish("a", color: .red)
        provider.finish("b", color: .blue)
        provider.finish("c", color: .green)
        try #require(await waitUntil { centerColor(of: window, matches: (255, 0, 0)) })

        await model.decide(.keep)
        try #require(await waitUntil { provider.images.contains("d") })
        #expect(model.currentAsset?.id == "b")
        #expect(centerColor(of: window, matches: (0, 0, 255)))
        #expect(provider.images.filter { $0 == "b" }.count == 1)
        #expect(!provider.images.contains("e"))
        #expect(model.swipePreviewAssets.count == 4)

        model.undo()
        try #require(await waitUntil { model.currentAsset?.id == "a" && centerColor(of: window, matches: (255, 0, 0)) })
        #expect(provider.images.filter { $0 == "a" }.count == 1)
        #expect(provider.images.filter { $0 == "b" }.count == 1)
    }

    @Test("look-ahead loads posters and requests motion only for the active card")
    func upcomingMotionStaysDeferred() async throws {
        let provider = DelayedSwipePreviewProvider()
        let model = try await makeSwipeModel(assets: [
            asset("a", modified: 1), asset("b", modified: 1, kind: .video),
            asset("c", modified: 1, kind: .livePhoto), asset("d", modified: 1)
        ], provider: provider)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: CleanupView().environment(model))
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            provider.finishAll()
            previousKeyWindow?.makeKeyAndVisible()
        }
        try #require(await waitUntil { Set(provider.images) == ["a", "b", "c"] })
        provider.finish("a", color: .red)
        provider.finish("b", color: .blue)
        provider.finish("c", color: .green)
        try #require(await waitUntil { centerColor(of: window, matches: (255, 0, 0)) })
        #expect(provider.videoRequests.isEmpty)
        #expect(provider.liveRequests.isEmpty)
        await model.decide(.keep)
        try #require(await waitUntil { provider.videoRequests == ["b"] })
        #expect(provider.liveRequests.isEmpty)
        #expect(centerColor(of: window, matches: (0, 0, 255)))
        await model.decide(.deletePending)
        try #require(await waitUntil { provider.liveRequests == ["c"] })
        #expect(provider.videoRequests == ["b"])
        #expect(provider.images.filter { $0 == "c" }.count == 1)
    }

    @Test("an active video requests playback before its delayed poster finishes")
    func videoPlaybackDoesNotWaitForPoster() async throws {
        let provider = DelayedSwipePreviewProvider()
        let model = try await makeSwipeModel(assets: [asset("a", modified: 1, kind: .video)], provider: provider)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: CleanupView().environment(model))
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            provider.finishAll()
            previousKeyWindow?.makeKeyAndVisible()
        }
        let requestedMotion = try await waitUntil { provider.videoRequests.contains("a") }
        #expect(requestedMotion)
        #expect(provider.images == ["a"])
        #expect(provider.videoRequests == ["a"])
        #expect(provider.liveRequests.isEmpty)
    }

    @Test("the swipe buffer stops at comparison sets and respects its size limit")
    func swipeBufferBoundaries() async throws {
        let provider = RecordingPreviewProvider()
        let model = try await makeSwipeModel(assets: ["a", "b", "c", "d", "e"].map { asset($0, modified: 1) },
            provider: provider, units: [
                .swipe("a"), CleanupWorkUnit(kind: .comparison, assetIDs: ["b", "c"], contextAssetIDs: [], clusterID: "set"),
                .swipe("d"), .swipe("e")
            ])
        #expect(model.swipePreviewAssets.map(\.id) == ["a"])
        await model.decide(.keep)
        #expect(model.route == .similarComparison)
        #expect(model.swipePreviewAssets.isEmpty)
        await model.confirmComparison(keepAll: true)
        #expect(model.currentAsset?.id == "d")
        #expect(model.swipePreviewAssets.map(\.id) == ["d", "e"])
    }

    private func makeSwipeModel(assets: [PhotoAssetDescriptor], provider: any MediaPreviewProvider,
                                units: [CleanupWorkUnit]? = nil) async throws -> AppModel {
        let container = try ModelContainer(for: RollSlashSchema.schema,
                                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let repository = SwiftDataCleanupRepository(container: container)
        _ = try repository.createSession(groupKind: .month, selectedGroupKeys: ["month:no-date"],
            orderedAssetIDs: assets.map(\.id),
            workPlan: CleanupWorkPlan(units: units ?? assets.map { .swipe($0.id) }))
        let model = AppModel(photoLibrary: PreviewTestLibrary(assets: assets), previewProvider: provider,
                             locationResolver: DemoLocationResolver(), modelContainer: container,
                             analysisClient: PreviewTestAnalysis())
        await model.start()
        model.resumeSession()
        return model
    }

    private func centerColor(of window: UIWindow, matches expected: (UInt8, UInt8, UInt8)) -> Bool {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let snapshot = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        guard let image = snapshot.cgImage else { return false }
        var pixel = [UInt8](repeating: 0, count: 4)
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info) else { return false }
        context.translateBy(x: -window.bounds.midX, y: -window.bounds.midY)
        context.draw(image, in: window.bounds)
        return zip(pixel.prefix(3), [expected.0, expected.1, expected.2]).allSatisfy { abs(Int($0) - Int($1)) < 5 }
    }

    private func asset(_ id: String, modified: TimeInterval, kind: MediaKind = .photo) -> PhotoAssetDescriptor {
        PhotoAssetDescriptor(id: id, creationDate: nil, coordinate: nil, mediaKind: kind,
                             duration: 0, pixelWidth: 100, pixelHeight: 100,
                             modificationDate: Date(timeIntervalSince1970: modified))
    }

    private func makeModel(library: PreviewTestLibrary, provider: RecordingPreviewProvider) throws -> AppModel {
        let container = try ModelContainer(for: RollSlashSchema.schema,
                                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        return AppModel(photoLibrary: library, previewProvider: provider, locationResolver: DemoLocationResolver(),
                        modelContainer: container, analysisClient: PreviewTestAnalysis())
    }

    private func waitUntil(_ predicate: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        return predicate()
    }
}

@MainActor @Observable private final class PreviewTestLayout {
    var size: CGFloat = 80
}

private struct PreviewLifecycleHost: View {
    @Environment(AppModel.self) private var model
    let showsThumbnail: Bool
    let layout: PreviewTestLayout
    var body: some View {
        if let asset = model.assetIndex["a"] {
            if showsThumbnail {
                MediaThumbnailView(identifier: asset.id, size: CGSize(width: layout.size, height: layout.size))
                    .frame(width: layout.size, height: layout.size)
            } else {
                MediaCardView(asset: asset, onPhotoTap: {}, onOpenPreview: { _ in }, isPreviewOpen: false)
                    .frame(width: 300, height: 500)
            }
        }
    }
}

@MainActor private final class RecordingPreviewProvider: MediaPreviewProvider {
    struct ImageRequest {
        let identifier: String
        let targetSize: CGSize
        let kind: PreviewRequestKind
    }
    struct CacheRequest {
        let identifiers: [String]
        let targetSize: CGSize
        let kind: PreviewRequestKind
    }
    var images: [ImageRequest] = []
    var caches: [CacheRequest] = []
    var didStopCaching = false
    func image(for identifier: String, targetSize: CGSize, kind: PreviewRequestKind) async -> UIImage? {
        images.append(ImageRequest(identifier: identifier, targetSize: targetSize, kind: kind))
        return UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        }
    }
    func livePhoto(for identifier: String, targetSize: CGSize) async -> PHLivePhoto? { nil }
    func playerItem(for identifier: String) async -> AVPlayerItem? { nil }
    func shareableVideoURL(for identifier: String) async throws -> URL? { nil }
    func startCaching(identifiers: [String], targetSize: CGSize, kind: PreviewRequestKind) {
        caches.append(CacheRequest(identifiers: identifiers, targetSize: targetSize, kind: kind))
        didStopCaching = false
    }
    func stopCachingAll() { didStopCaching = true }
}

@MainActor private final class PreviewTestLibrary: PhotoLibraryClient {
    var onLibraryChange: (@MainActor @Sendable () -> Void)?
    var assets: [PhotoAssetDescriptor]
    init(assets: [PhotoAssetDescriptor]) { self.assets = assets }
    func authorizationStatus() -> PhotoPermission { .full }
    func requestAuthorization() async -> PhotoPermission { .full }
    func fetchAssets() async throws -> [PhotoAssetDescriptor] { assets }
    func existingAssetIdentifiers(in identifiers: Set<String>) async throws -> Set<String> {
        identifiers.intersection(assets.map(\.id))
    }
    func deleteAssets(with identifiers: [String]) async throws -> Set<String> { [] }
    func isFavorite(with identifier: String) async -> Bool { false }
    func setFavorite(_ favorite: Bool, for identifier: String) async throws {}
    func presentLimitedLibraryPicker() {}
    func openSystemSettings() {}
}

private struct PreviewTestAnalysis: MediaAnalysisClient {
    func analyze(_ asset: PhotoAssetDescriptor) async -> MediaAnalysisResult { MediaAnalysisResult() }
    func clusters(assets: [PhotoAssetDescriptor], results: [String: MediaAnalysisResult]) async -> [SimilarPhotoCluster] { [] }
}

@MainActor private final class DelayedSwipePreviewProvider: MediaPreviewProvider {
    private(set) var images: [String] = []
    private(set) var videoRequests: [String] = []
    private(set) var liveRequests: [String] = []
    private var pending: [String: [CheckedContinuation<UIImage?, Never>]] = [:]
    private var pendingPlayers: [CheckedContinuation<AVPlayerItem?, Never>] = []

    func image(for identifier: String, targetSize: CGSize, kind: PreviewRequestKind) async -> UIImage? {
        images.append(identifier)
        return await withCheckedContinuation { pending[identifier, default: []].append($0) }
    }

    func finish(_ identifier: String, color: UIColor) {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100)).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        }
        pending.removeValue(forKey: identifier)?.forEach { $0.resume(returning: image) }
    }

    func finishAll() {
        let requests = pending.values.flatMap { $0 }
        pending.removeAll()
        requests.forEach { $0.resume(returning: nil) }
        let players = pendingPlayers
        pendingPlayers.removeAll()
        players.forEach { $0.resume(returning: nil) }
    }

    func livePhoto(for identifier: String, targetSize: CGSize) async -> PHLivePhoto? {
        liveRequests.append(identifier)
        return nil
    }

    func playerItem(for identifier: String) async -> AVPlayerItem? {
        videoRequests.append(identifier)
        return await withCheckedContinuation { pendingPlayers.append($0) }
    }

    func shareableVideoURL(for identifier: String) async throws -> URL? { nil }
    func startCaching(identifiers: [String], targetSize: CGSize, kind: PreviewRequestKind) {}
    func stopCachingAll() {}
}
