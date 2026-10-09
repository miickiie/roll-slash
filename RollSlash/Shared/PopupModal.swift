import SwiftUI
import UIKit

struct PopupModal<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.58)
                .ignoresSafeArea()

            ViewThatFits(in: .vertical) {
                content.fixedSize(horizontal: false, vertical: true)
                ScrollView { content }
                    .scrollBounceBehavior(.basedOnSize)
                    .accessibilityIdentifier("popup-content-scroll")
            }
                .padding(24)
                .frame(maxWidth: 380)
                .background(Color(uiColor: .secondarySystemBackground), in: .rect(cornerRadius: 28))
                .foregroundStyle(Color.primary)
                .clipShape(.rect(cornerRadius: 28))
                .overlay {
                    RoundedRectangle(cornerRadius: 28)
                        .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.28), radius: 24, y: 12)
                .padding(24)
        }
        .presentationBackground(.clear)
        .interactiveDismissDisabled()
        .accessibilityElement(children: .contain)
    }
}

struct PopupActionRow<Cancel: View, Confirm: View>: View {
    let cancel: Cancel
    let confirm: Confirm

    init(
        @ViewBuilder cancel: () -> Cancel,
        @ViewBuilder confirm: () -> Confirm
    ) {
        self.cancel = cancel()
        self.confirm = confirm()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                cancel.fixedSize(horizontal: true, vertical: false)
                confirm.fixedSize(horizontal: true, vertical: false).foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity, alignment: .center)

            VStack(spacing: 10) {
                cancel.fixedSize(horizontal: false, vertical: true)
                confirm.fixedSize(horizontal: false, vertical: true).foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity)
    }
}
