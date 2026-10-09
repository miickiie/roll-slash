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
            let result = await PreviewImageDelivery.image(kind: kind) { handler in
                handler(degraded, [PHImageResultIsDegradedKey: true])
                handler(final, [PHImageResultIsDegradedKey: false])
                handler(degraded, nil)
                return 1
            } cancel: { _ in }
            #expect(result === final)
        }
    }

    @Test func degradedLiveResultsWaitForTheFinalValue() async {
        let result = await PreviewImageDelivery.finalResult { handler in
            handler("degraded", [PHImageResultIsDegradedKey: true])
            handler("final", [PHImageResultIsDegradedKey: false])
            handler("late", nil)
            return 1
        } cancel: { _ in }
        #expect(result == "final")
    }

    @Test func failedLiveResultFinishesWithoutWaiting() async {
        let result = await PreviewImageDelivery.finalResult { handler in
            handler("nope", [PHImageErrorKey: NSError(domain: "test", code: 1), PHImageResultIsDegradedKey: true])
            handler("late", nil)
            return 1
        } cancel: { _ in }
        #expect(result == nil)
    }

    @Test func failedOrUnavailableOriginalFinishesWithoutAnImage() async {
        let cases: [[AnyHashable: Any]?] = [nil, [PHImageCancelledKey: true],
            [PHImageErrorKey: NSError(domain: "test", code: 1), PHImageResultIsDegradedKey: true]]
        for info in cases {
            let result = await PreviewImageDelivery.image(kind: .fullResolution) { handler in
                handler(nil, info)
                return 2
            } cancel: { _ in }
            #expect(result == nil)
        }
    }

    @Test func cancellationStopsPhotoKitAndRejectsLateImage() async throws {
        let request = PendingPreviewRequest()
        let task = Task {
            await PreviewImageDelivery.image(kind: .fullResolution, start: request.start, cancel: request.cancel)
        }
        for _ in 0..<100 where request.handler == nil { await Task.yield() }
        _ = try #require(request.handler)
        task.cancel()
        #expect(await task.value == nil)
        for _ in 0..<100 where !request.cancelled { await Task.yield() }
        #expect(request.cancelled)
        request.handler?(UIImage(), nil)
        #expect(await task.value == nil)
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
        for id in ["a", "b"] { cache.store(image, for: key(id), generation: cache.generation) }
        #expect(cache.image(for: key("a")) === image)
        cache.store(image, for: key("c"), generation: cache.generation)
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
        for id in ["a", "b", "c"] { cache.store(image, for: key(id), generation: cache.generation) }
        #expect(cache.byteCount == cost * 2)
        #expect(cache.image(for: key("a")) == nil)
        cache.store(makeImage(size: 100), for: key("oversized"), generation: cache.generation)
        #expect(cache.image(for: key("oversized")) == nil)
        #expect(cache.image(for: key("b")) === image)
        #expect(cache.image(for: key("c")) === image)
        cache.store(image, for: key("b"), generation: cache.generation)
        #expect(cache.byteCount == cost * 2)
    }

    @Test("invalidation rejects results from requests started before a library change")
    func staleRequestCannotRepopulateCache() {
        let cache = PreviewImageCache()
        let image = makeImage(size: 10)
        let oldGeneration = cache.generation
        cache.store(image, for: key("a"), generation: oldGeneration)
        cache.removeAll()
        cache.store(image, for: key("a"), generation: oldGeneration)
        #expect(cache.byteCount == 0)
        #expect(cache.image(for: key("a")) == nil)
        cache.store(image, for: key("a"), generation: cache.generation)
        #expect(cache.image(for: key("a")) === image)
    }

    @Test("stopping navigation preheating preserves images until explicit invalidation")
    func navigationCacheLifecycle() async {
        let cache = PreviewImageCache()
        let image = makeImage(size: 10)
        let size = CGSize(width: 900, height: 1200)
        let request = PreviewImageCache.Key(identifier: "fixture", kind: .active, targetSize: size)
        cache.store(image, for: request, generation: cache.generation)
        let provider = PhotoKitMediaPreviewProvider(imageCache: cache)
        #expect(await provider.image(for: "fixture", targetSize: size, kind: .active) === image)
        provider.stopCachingAll()
        #expect(await provider.image(for: "fixture", targetSize: size, kind: .active) === image)
        provider.invalidateCachedImages()
        #expect(cache.image(for: request) == nil)
        #expect(cache.byteCount == 0)
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
    }

    func livePhoto(for identifier: String, targetSize: CGSize) async -> PHLivePhoto? {
        liveRequests.append(identifier)
        return nil
    }

    func playerItem(for identifier: String) async -> AVPlayerItem? {
        videoRequests.append(identifier)
        return nil
    }

    func shareableVideoURL(for identifier: String) async throws -> URL? { nil }
    func startCaching(identifiers: [String], targetSize: CGSize, kind: PreviewRequestKind) {}
    func stopCachingAll() {}
}
