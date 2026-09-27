import SwiftData
import SwiftUI

@main
struct RollSlashApp: App {
    private let container: ModelContainer

    @State private var appModel: AppModel

    init() {
        let processInfo = ProcessInfo.processInfo
        let isUITesting = processInfo.arguments.contains("--ui-testing")
        let isTesting = isUITesting || processInfo.environment["XCTestConfigurationFilePath"] != nil
        let schema = Schema([
            AssetDecisionRecord.self,
            CleanupSessionRecord.self,
            CleanupActionRecord.self,
            GroupCompletionRecord.self,
            LocationCacheRecord.self
        ])

        do {
            let configuration = ModelConfiguration(isStoredInMemoryOnly: isTesting)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            self.container = container
            let photoLibrary: any PhotoLibraryClient
            let previewProvider: any MediaPreviewProvider
            let locationResolver: any LocationResolver
            if isUITesting {
                photoLibrary = DemoPhotoLibraryClient()
                previewProvider = DemoMediaPreviewProvider()
                locationResolver = DemoLocationResolver()
            } else {
                photoLibrary = PhotoKitLibraryClient()
                previewProvider = PhotoKitMediaPreviewProvider()
                locationResolver = MapKitLocationResolver()
            }
            _appModel = State(initialValue: AppModel(
                photoLibrary: photoLibrary,
                previewProvider: previewProvider,
                locationResolver: locationResolver,
                modelContainer: container
            ))
        } catch {
            fatalError("Unable to initialize Roll Slash storage: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appModel)
                .modelContainer(container)
        }
    }
}
