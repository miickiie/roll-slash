import Foundation

@MainActor
protocol PhotoLibraryClient: AnyObject {
    var onLibraryChange: (@MainActor @Sendable () -> Void)? { get set }
    func authorizationStatus() -> PhotoPermission
    func requestAuthorization() async -> PhotoPermission
    func fetchAssets() async throws -> [PhotoAssetDescriptor]
    func deleteAssets(with identifiers: [String]) async throws
    func presentLimitedLibraryPicker()
    func openSystemSettings()
}

