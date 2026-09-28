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

@MainActor
protocol PhotoLibraryClient: AnyObject {
    var onLibraryChange: (@MainActor @Sendable () -> Void)? { get set }
    func authorizationStatus() -> PhotoPermission
    func requestAuthorization() async -> PhotoPermission
    func fetchAssets() async throws -> [PhotoAssetDescriptor]
    func deleteAssets(with identifiers: [String]) async throws -> Set<String>
    func presentLimitedLibraryPicker()
    func openSystemSettings()
}
