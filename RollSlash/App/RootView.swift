import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var dashboardScroll = DashboardScrollMemory()

    var body: some View {
        Group {
            switch appModel.route {
            case .onboarding:
                OnboardingView()
            case .dashboard:
                DashboardView(scrollMemory: $dashboardScroll)
            case .cleanup:
                CleanupView()
            case .similarComparison:
                SimilarComparisonView()
            case .review:
                ReviewView()
            case .completion:
                CompletionView()
            }
        }
        .visibleSystemStatusBar()
        .preferredColorScheme(appModel.route == .cleanup ? .dark : nil)
        .animation(.snappy, value: appModel.route)
        .task {
            await appModel.start()
        }
        .onChange(of: scenePhase) { _, phase in
            appModel.setForeground(phase == .active)
            guard phase == .active else { return }
            Task { await appModel.refreshAuthorization() }
        }
    }
}
