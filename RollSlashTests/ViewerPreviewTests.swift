import Photos
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
