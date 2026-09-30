import Foundation

enum PhotoLibraryDeletionError: LocalizedError, Sendable {
    case inaccessibleAssets(requested: Int, accessible: Int)

    var errorDescription: String? {
        switch self {
        case let .inaccessibleAssets(requested, accessible):
            return String(
                localized: "Photos access changed before deletion. \(accessible) of \(requested) selected items are still accessible. No items were deleted."
            )
        }
    }
}

enum PhotoLibraryFavoriteError: LocalizedError, Sendable {
    case assetUnavailable

    var errorDescription: String? {
        switch self {
        case .assetUnavailable:
            String(localized: "This item is no longer available in Photos.")
        }
    }
}

@MainActor
protocol PhotoLibraryClient: AnyObject {
    var onLibraryChange: (@MainActor @Sendable () -> Void)? { get set }
    func authorizationStatus() -> PhotoPermission
    func requestAuthorization() async -> PhotoPermission
    func startObservingChanges()
    func fetchAssets() async throws -> [PhotoAssetDescriptor]
    func estimateStorageBytes(for identifiers: [String]) async -> [String: Int64]
    func deleteAssets(with identifiers: [String]) async throws -> Set<String>
    func isFavorite(with identifier: String) async -> Bool
    func setFavorite(_ favorite: Bool, for identifier: String) async throws
    func presentLimitedLibraryPicker()
    func openSystemSettings()
}

extension PhotoLibraryClient {
    func estimateStorageBytes(for identifiers: [String]) async -> [String: Int64] { [:] }
    func startObservingChanges() {}
}
