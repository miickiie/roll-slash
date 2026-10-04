import SwiftUI

extension View {
    /// Apply at route and presentation roots, independent of transient photo actions.
    @ViewBuilder
    func visibleSystemStatusBar() -> some View {
        if #available(iOS 27, *) {
            toolbarVisibility(.visible, for: .statusBar)
        } else {
            statusBarHidden(false)
        }
    }
}
