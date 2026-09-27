import SwiftUI

struct OnboardingView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        ZStack {
            RollSlashTheme.background.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 28) {
                    Image(systemName: "photo.stack.fill")
                    .font(.system(size: 70, weight: .semibold))
                    .foregroundStyle(.white, RollSlashTheme.coral)
                    .symbolEffect(.breathe)
                    .accessibilityHidden(true)

                VStack(spacing: 12) {
                    Text("Make room for what matters")
                        .font(.largeTitle.bold())
                        .multilineTextAlignment(.center)
            Text("Swipe to keep the good stuff, stage deletion candidates, and confirm everything before Roll Slash asks Photos to delete it.")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.76))
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.white)

                VStack(alignment: .leading, spacing: 16) {
                    BenefitRow(icon: "hand.draw.fill", title: "Fast decisions", detail: "Swipe right to keep, left to delete later.")
                    BenefitRow(icon: "lock.shield.fill", title: "Private by design", detail: "Your originals stay in Photos. Roll Slash stores decisions only.")
                    BenefitRow(icon: "checkmark.circle.fill", title: "You stay in control", detail: "Nothing leaves your library without final review and Apple’s confirmation.")
                }

                    Button {
                    Task { await appModel.requestAccess() }
                } label: {
                    Text("Choose Photo Access")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.glassProminent)
                .tint(RollSlashTheme.coral)

                    Button("Not now") {
                        appModel.continueWithoutAccess()
                    }
                    .foregroundStyle(.white.opacity(0.75))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
                .padding(.horizontal, 24)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}

private struct BenefitRow: View {
    let icon: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(RollSlashTheme.coral)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.white.opacity(0.68))
            }
        }
        .foregroundStyle(.white)
    }
}
