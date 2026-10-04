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
    let schema = RollSlashSchema.schema

        do {
            let configuration = ModelConfiguration(isStoredInMemoryOnly: isTesting)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            self.container = container
            let photoLibrary: any PhotoLibraryClient
            let previewProvider: any MediaPreviewProvider
            let locationResolver: any LocationResolver
            let analysisClient: any MediaAnalysisClient
            if isUITesting {
                let comparisonFixtures = processInfo.arguments.contains("--comparison-fixtures")
                let fixtureDate = Calendar(identifier: .gregorian).date(
                    from: DateComponents(year: 2026, month: 9, day: 15)
                )!
                photoLibrary = DemoPhotoLibraryClient(referenceDate: fixtureDate, comparisonFixtures: comparisonFixtures)
                previewProvider = DemoMediaPreviewProvider(comparisonFixtures: comparisonFixtures)
                locationResolver = DemoLocationResolver()
                analysisClient = DemoMediaAnalysisClient(comparisonFixtures: comparisonFixtures)
            } else {
                photoLibrary = PhotoKitLibraryClient()
                previewProvider = PhotoKitMediaPreviewProvider()
                locationResolver = MapKitLocationResolver()
                analysisClient = PhotoKitMediaAnalysisClient()
            }
            _appModel = State(initialValue: AppModel(
                photoLibrary: photoLibrary,
                previewProvider: previewProvider,
                locationResolver: locationResolver,
                modelContainer: container,
                analysisClient: analysisClient
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
