import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch appModel.route {
            case .onboarding:
                OnboardingView()
            case .dashboard:
                DashboardView()
            case .cleanup:
                CleanupView()
            case .review:
                ReviewView()
            case .completion:
                CompletionView()
            }
        }
        .animation(.snappy, value: appModel.route)
        .task {
            await appModel.start()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await appModel.refreshAuthorization() }
        }
    }
}
