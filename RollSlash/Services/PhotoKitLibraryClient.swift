import Photos
import PhotosUI
import UIKit

@MainActor
final class PhotoKitLibraryClient: NSObject, PhotoLibraryClient {
    var onLibraryChange: (@MainActor @Sendable () -> Void)?
    private var isObservingChanges = false
    private var selfieIDs: Set<String>?
    private var libraryChangeGeneration = 0

    override init() {
        super.init()
    }

    deinit {
        if isObservingChanges {
            PHPhotoLibrary.shared().unregisterChangeObserver(self)
        }
    }

    func startObservingChanges() {
        guard !isObservingChanges, authorizationStatus().canRead else { return }
        PHPhotoLibrary.shared().register(self)
        isObservingChanges = true
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
        let knownSelfieIDs = selfieIDs
        let generation = libraryChangeGeneration
        let fetched = await Task.detached(priority: .userInitiated) { () -> (assets: [PhotoAssetDescriptor], selfieIDs: Set<String>, resolvedSelfies: Bool) in
            let collections = PHAssetCollection.fetchAssetCollections(
                with: .smartAlbum,
                subtype: .smartAlbumUserLibrary,
                options: nil
            )
            guard let library = collections.firstObject else { return ([], [], false) }

            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            options.includeHiddenAssets = false
            options.includeAllBurstAssets = true

            let fetchResult = PHAsset.fetchAssets(in: library, options: options)
            let selfieIDs: Set<String>
            if let knownSelfieIDs {
                selfieIDs = knownSelfieIDs
            } else {
                var collected = Set<String>()
                let selfieAlbums = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumSelfPortraits, options: nil)
                selfieAlbums.enumerateObjects { album, _, _ in
                    PHAsset.fetchAssets(in: album, options: options).enumerateObjects { asset, _, _ in
                        if asset.mediaType == .image { collected.insert(asset.localIdentifier) }
                    }
                }
                selfieIDs = collected
            }
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
                    pixelHeight: asset.pixelHeight,
                    modificationDate: asset.modificationDate,
                    isScreenshot: asset.mediaSubtypes.contains(.photoScreenshot),
                    isPanorama: asset.mediaSubtypes.contains(.photoPanorama),
                    isFavorite: asset.isFavorite,
                    burstIdentifier: asset.burstIdentifier,
                    isSelfie: selfieIDs.contains(asset.localIdentifier)
                ))
            }
            return (descriptors, selfieIDs, true)
        }.value
        if generation == libraryChangeGeneration, knownSelfieIDs == nil, fetched.resolvedSelfies {
            selfieIDs = fetched.selfieIDs
        }
        return fetched.assets
    }

    func estimateStorageBytes(for identifiers: [String]) async -> [String: Int64] {
        let identifiers = identifiers
        return await Task.detached(priority: .utility) {
            guard #available(iOS 27, *) else { return [:] }
            guard !identifiers.isEmpty else { return [:] }

            let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
            var estimates: [String: Int64] = [:]
            fetchResult.enumerateObjects { asset, _, _ in
                let resources = PHAssetResource.assetResources(for: asset)
                guard !resources.isEmpty else { return }
                var total: Int64 = 0
                var isComplete = true
                for resource in resources {
                    guard let resourceBytes = resource.dataSize else {
                        isComplete = false
                        break
                    }
                    total += Int64(resourceBytes)
                }
                if isComplete { estimates[asset.localIdentifier] = total }
            }
            return estimates
        }.value
    }

    func deleteAssets(with identifiers: [String]) async throws -> Set<String> {
        try await Self.performDeletion(identifiers)
    }

    func isFavorite(with identifier: String) async -> Bool {
        PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject?.isFavorite ?? false
    }

    func setFavorite(_ favorite: Bool, for identifier: String) async throws {
        // PhotoKit runs the change block on its own serial queue. Keep the
        // operation outside this @MainActor client so Swift 6 does not attach
        // main-actor isolation to the closure (which would trap at runtime
        // when PhotoKit invokes it off the main actor).
        try await Self.performFavoriteChange(favorite, identifier: identifier)
    }

    nonisolated private static func performFavoriteChange(_ favorite: Bool, identifier: String) async throws {
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        guard let asset = fetchResult.firstObject else {
            throw PhotoLibraryFavoriteError.assetUnavailable
        }

        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetChangeRequest(for: asset)
            request.isFavorite = favorite
        }
    }

    nonisolated private static func performDeletion(_ identifiers: [String]) async throws -> Set<String> {
        guard !identifiers.isEmpty else { return [] }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        var accessibleIdentifiers = Set<String>()
        assets.enumerateObjects { asset, _, _ in
            accessibleIdentifiers.insert(asset.localIdentifier)
        }
        guard accessibleIdentifiers.count == Set(identifiers).count else {
            throw PhotoLibraryDeletionError.inaccessibleAssets(
                requested: Set(identifiers).count,
                accessible: accessibleIdentifiers.count
            )
        }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets)
        }
        return accessibleIdentifiers
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
            self?.libraryChangeGeneration += 1
            self?.selfieIDs = nil
            self?.onLibraryChange?()
        }
    }
}
