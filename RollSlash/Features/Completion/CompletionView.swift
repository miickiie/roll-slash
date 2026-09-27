import SwiftUI

struct CompletionView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animate = false

    var body: some View {
        ZStack {
            RollSlashTheme.background.ignoresSafeArea()
            if !reduceMotion {
                ForEach(0..<16, id: \.self) { index in
                    Circle()
                        .fill(index.isMultiple(of: 2) ? RollSlashTheme.coral : RollSlashTheme.violet)
                        .frame(width: CGFloat(5 + index % 4), height: CGFloat(5 + index % 4))
                        .offset(
                            x: animate ? CGFloat((index % 5) * 76 - 150) : 0,
                            y: animate ? CGFloat((index % 7) * 88 - 260) : 0
                        )
                        .opacity(animate ? 0 : 1)
                }
            }
            VStack(spacing: 22) {
                Image(systemName: "sparkles")
                    .font(.system(size: 64, weight: .semibold))
                    .foregroundStyle(RollSlashTheme.coral)
                    .symbolEffect(.bounce, value: animate)
                Text("Freshly slashed")
                    .font(.largeTitle.bold())
                Text("This cleanup is complete. New media added later will automatically reopen its month or location group.")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.72))
                    .multilineTextAlignment(.center)
                Button("Back to library") { appModel.finishCompletion() }
                    .buttonStyle(.glassProminent)
                    .tint(RollSlashTheme.coral)
            }
            .foregroundStyle(.white)
            .padding(28)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 1.4)) { animate = true }
        }
    }
}

