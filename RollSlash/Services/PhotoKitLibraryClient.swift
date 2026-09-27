import Photos
import PhotosUI
import UIKit

@MainActor
final class PhotoKitLibraryClient: NSObject, PhotoLibraryClient {
    var onLibraryChange: (@MainActor @Sendable () -> Void)?

    override init() {
        super.init()
        PHPhotoLibrary.shared().register(self)
    }

    deinit {
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
    }

    func authorizationStatus() -> PhotoPermission {
        map(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    func requestAuthorization() async -> PhotoPermission {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return map(status)
    }

    func fetchAssets() async throws -> [PhotoAssetDescriptor] {
        guard authorizationStatus().canRead else { return [] }
        return await Task.detached(priority: .userInitiated) {
            let collections = PHAssetCollection.fetchAssetCollections(
                with: .smartAlbum,
                subtype: .smartAlbumUserLibrary,
                options: nil
            )
            guard let library = collections.firstObject else { return [] }

            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            options.includeHiddenAssets = false
            options.includeAllBurstAssets = true

            let fetchResult = PHAsset.fetchAssets(in: library, options: options)
            var descriptors: [PhotoAssetDescriptor] = []
            descriptors.reserveCapacity(fetchResult.count)
            fetchResult.enumerateObjects { asset, _, _ in
                guard asset.mediaType == .image || asset.mediaType == .video else { return }
                let kind: MediaKind
                if asset.mediaType == .video {
                    kind = .video
                } else if asset.mediaSubtypes.contains(.photoLive) {
                    kind = .livePhoto
                } else {
                    kind = .photo
                }
                descriptors.append(PhotoAssetDescriptor(
                    id: asset.localIdentifier,
                    creationDate: asset.creationDate,
                    coordinate: asset.location.map { GeoCoordinate(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) },
                    mediaKind: kind,
                    duration: asset.duration,
                    pixelWidth: asset.pixelWidth,
                    pixelHeight: asset.pixelHeight
                ))
            }
            return descriptors
        }.value
    }

    func deleteAssets(with identifiers: [String]) async throws {
        try await Self.performDeletion(identifiers)
    }

    nonisolated private static func performDeletion(_ identifiers: [String]) async throws {
        guard !identifiers.isEmpty else { return }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets)
        }
    }

    func presentLimitedLibraryPicker() {
        guard let controller = Self.topViewController() else { return }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: controller)
    }

    func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func map(_ status: PHAuthorizationStatus) -> PhotoPermission {
        switch status {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .limited: .limited
        case .authorized: .full
        @unknown default: .denied
        }
    }

    private static func topViewController(base: UIViewController? = nil) -> UIViewController? {
        let root = base ?? UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .rootViewController
        if let navigation = root as? UINavigationController {
            return topViewController(base: navigation.visibleViewController)
        }
        if let tab = root as? UITabBarController {
            return topViewController(base: tab.selectedViewController)
        }
        if let presented = root?.presentedViewController {
            return topViewController(base: presented)
        }
        return root
    }
}

extension PhotoKitLibraryClient: PHPhotoLibraryChangeObserver {
    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor [weak self] in
            self?.onLibraryChange?()
        }
    }
}
