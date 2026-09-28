import SwiftUI

struct PopupModal<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.48)
                .ignoresSafeArea()

            content
                .padding(24)
                .frame(maxWidth: 380)
                .background(.regularMaterial, in: .rect(cornerRadius: 28))
                .overlay {
                    RoundedRectangle(cornerRadius: 28)
                        .stroke(.white.opacity(0.18), lineWidth: 1)
                }
                .padding(24)
        }
        .presentationBackground(.clear)
        .interactiveDismissDisabled()
        .accessibilityElement(children: .contain)
    }
}
