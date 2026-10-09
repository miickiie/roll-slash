import AVKit
import PhotosUI
import SwiftUI

struct CleanupView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragOffset: CGSize = .zero
    @State private var isDecisionLocked = false
    @State private var actionStamp: ActionStamp?
    @State private var actionTask: Task<Void, Never>?
    @State private var unlockTask: Task<Void, Never>?
    @State private var showingReviewNowConfirmation = false
    @State private var pendingReviewCurrentBatch = false
    @State private var previewAsset: PhotoAssetDescriptor?
    @State private var previewImage: UIImage?
    @State private var previewExitOffset: CGSize = .zero
    @State private var previewOpacity = 1.0
    @State private var isPreviewDismissing = false
    @State private var hapticPulse = HapticPulse(id: 0, kind: .impact)
    @State private var actionGeneration = UUID()

    var body: some View {
        ZStack {
            RollSlashTheme.background.ignoresSafeArea()
            VStack(spacing: 14) {
                header
                Spacer(minLength: 0)
                deck
                Text("Swipe right to keep · left to delete")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.65))
                    .accessibilityHidden(true)
                Spacer(minLength: 0)
                decisionButtons
                historyButtons
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            if let previewAsset {
                GeometryReader { geometry in
                    let viewport = CGSize(
                        width: geometry.size.width,
                        height: geometry.size.height + geometry.safeAreaInsets.top + geometry.safeAreaInsets.bottom
                    )
                    MediaViewer(
                        asset: previewAsset,
                        initialImage: previewImage,
                        onDismissSwipe: { translation in
                            dismissPreview(toward: translation, viewport: viewport)
                        },
                        onClose: {
                            dismissPreview(toward: CGSize(width: 0, height: 100), viewport: viewport)
                        },
                        dismissalOffset: previewExitOffset,
                        dismissalOpacity: previewOpacity
                    )
                    .frame(width: geometry.size.width, height: geometry.size.height)
                }
                .zIndex(1)
            }
        }
        .foregroundStyle(.white)
        .sensoryFeedback(trigger: hapticPulse) { _, pulse in pulse.feedback }
        .alert("Roll Slash", isPresented: Binding(
            get: { appModel.errorMessage != nil },
            set: { if !$0 { appModel.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { appModel.errorMessage = nil }
        } message: {
            Text(appModel.errorMessage ?? "")
        }
        .onDisappear {
            actionGeneration = UUID()
            actionTask?.cancel()
            unlockTask?.cancel()
            actionStamp = nil
            isDecisionLocked = false
        }
    }

    private func openPreview(_ asset: PhotoAssetDescriptor, image: UIImage?) {
        guard !isDecisionLocked else { return }
        previewExitOffset = .zero
        previewOpacity = 1
        isPreviewDismissing = false
        previewImage = image
        previewAsset = asset
    }

    private func dismissPreview(toward translation: CGSize, viewport: CGSize) {
        guard previewAsset != nil, !isPreviewDismissing else { return }
        let length = hypot(translation.width, translation.height)
        guard length > 0 else { return }
        isPreviewDismissing = true

        if reduceMotion {
            finishPreviewDismissal()
            return
        }

        let horizontal = translation.width / length
        let vertical = translation.height / length
        let horizontalTravel = viewport.width / max(abs(horizontal), 0.001)
        let verticalTravel = viewport.height / max(abs(vertical), 0.001)
        let travel = min(horizontalTravel, verticalTravel) + 80

        withAnimation(.easeOut(duration: 0.28)) {
            previewExitOffset = CGSize(width: horizontal * travel, height: vertical * travel)
            previewOpacity = 0
        } completion: {
            finishPreviewDismissal()
        }
    }

    private func finishPreviewDismissal() {
        previewAsset = nil
        previewImage = nil
        previewExitOffset = .zero
        previewOpacity = 1
        isPreviewDismissing = false
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack {
                Button("Close", systemImage: "chevron.down") { appModel.route = .dashboard }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)
                    .disabled(isDecisionLocked)
                    .accessibilityHint("Pauses this session. Your progress stays on the dashboard.")
            Spacer()
            VStack(spacing: 1) {
                Text("\(appModel.sessionRemaining) left").font(.headline)
                Text("\(appModel.keptCount) kept  •  \(appModel.deleteCount) to delete")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
            }
            Spacer()
            Button(appModel.deleteCount > 0 ? "Review deletes now" : "Finish session", systemImage: "checkmark.seal") {
                if appModel.deleteCount > 0 {
                    showingReviewNowConfirmation = true
                } else {
                    Task { await appModel.finishCurrentSession() }
                }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.glass)
            .disabled(isDecisionLocked)
            .accessibilityIdentifier(appModel.deleteCount > 0 ? "review-now" : "finish-session")
            .accessibilityHint(appModel.deleteCount > 0
                ? "Review items marked for deletion now. Unswiped items stay for later."
                : "Finish this session. Unswiped items stay available for later.")
            .fullScreenCover(
                isPresented: $showingReviewNowConfirmation,
                onDismiss: {
                    guard pendingReviewCurrentBatch else { return }
                    pendingReviewCurrentBatch = false
                    appModel.reviewCurrentBatch()
                }
            ) {
                PopupModal {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Review deletes now?")
                            .font(.headline)
                        Text("This reviews the \(appModel.deleteCount) item\(appModel.deleteCount == 1 ? "" : "s") currently marked for deletion. Unswiped items stay in this session for later.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        PopupActionRow {
                            Button("Keep Swiping") { showingReviewNowConfirmation = false }
                                .buttonStyle(.bordered)
                        } confirm: {
                            Button("Review Deletes") {
                                pendingReviewCurrentBatch = true
                                showingReviewNowConfirmation = false
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(RollSlashTheme.coral)
                        }
                    }
                }
            }
        }
        ProgressView(value: Double(appModel.sessionCompleted), total: Double(max(appModel.sessionTotal, 1)))
            .tint(RollSlashTheme.coral)
        }
    }

    private func decideFromButton(_ decision: AssetDecision) {
        guard !isDecisionLocked, let assetID = appModel.currentAsset?.id else { return }
        dragOffset = .zero
        commitDecision(decision, for: assetID)
    }

    private func undoFromPhoto() {
        guard appModel.canUndo, let cursor = appModel.activeSession?.cursor else { return }
        guard appModel.currentAsset != nil else {
            pulse(.impact)
            appModel.undo()
            return
        }
        showStampThenAct(.undo, isStillValid: { appModel.activeSession?.cursor == cursor }) {
            if appModel.canUndo { appModel.undo() }
        }
    }

    private func redoFromButton() {
        guard appModel.canRedo, let cursor = appModel.activeSession?.cursor else { return }
        guard appModel.currentAsset != nil else {
            pulse(.impact)
            Task { await appModel.redo() }
            return
        }
        showStampThenAct(.redo, isStillValid: { appModel.activeSession?.cursor == cursor }) {
            if appModel.canRedo { await appModel.redo() }
        }
    }

    private func commitDecision(_ decision: AssetDecision, for assetID: String) {
        guard !isDecisionLocked, let sessionID = appModel.activeSession?.identifier else { return }
        if reduceMotion {
            showStampThenAct(decision == .keep ? .keep : .delete, isStillValid: {
                appModel.activeSession?.identifier == sessionID && appModel.currentAsset?.id == assetID
            }) {
                await appModel.decide(decision)
            }
            return
        }

        pulse(decision == .keep ? .success : .warning)
        isDecisionLocked = true
        withAnimation(.snappy) {
            dragOffset.width = decision == .keep ? 700 : -700
        } completion: {
            dragOffset = .zero
            if appModel.route == .cleanup,
               appModel.activeSession?.identifier == sessionID,
               appModel.currentAsset?.id == assetID {
                Task {
                    await appModel.decide(decision)
                    unlockDecisionAfterTransition()
                }
            } else {
                unlockDecisionAfterTransition()
            }
        }
    }

    private func showStampThenAct(
        _ stamp: ActionStamp,
        isStillValid: @escaping () -> Bool,
        perform: @escaping () async -> Void
    ) {
        guard !isDecisionLocked, appModel.activeSession != nil else { return }
        isDecisionLocked = true
        dragOffset = .zero
        pulse(stamp.haptic)
        let generation = UUID()
        actionGeneration = generation
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
            actionStamp = stamp
        }
        actionTask?.cancel()
        actionTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(350))
            } catch {
                if actionGeneration == generation { isDecisionLocked = false }
                return
            }
            guard actionGeneration == generation else { return }
            withAnimation(reduceMotion ? nil : .easeIn(duration: 0.12)) {
                actionStamp = nil
            }
            if appModel.route == .cleanup, isStillValid() {
                await perform()
            }
            unlockDecisionAfterTransition()
        }
    }

    private func pulse(_ kind: HapticPulse.Kind) {
        hapticPulse = HapticPulse(id: hapticPulse.id + 1, kind: kind)
    }

    private func unlockDecisionAfterTransition() {
        unlockTask?.cancel()
        unlockTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(300))
            } catch {
                return
            }
            isDecisionLocked = false
        }
    }

    private var deck: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 30).fill(.white.opacity(0.08)).offset(y: 12).scaleEffect(0.94)
            RoundedRectangle(cornerRadius: 30).fill(.white.opacity(0.12)).offset(y: 6).scaleEffect(0.97)
            if let asset = appModel.currentAsset {
                MediaCardView(
                    asset: asset,
                    onPhotoTap: undoFromPhoto,
                    onOpenPreview: { image in openPreview(asset, image: image) },
                    isPreviewOpen: previewAsset != nil
                )
                    .id(asset.id)
                    .offset(dragOffset)
                    .rotationEffect(.degrees(Double(dragOffset.width / 22)))
                    .overlay(alignment: dragOffset.width >= 0 ? .topLeading : .topTrailing) {
                        if abs(dragOffset.width) > 35 {
                            SwipeStamp(action: dragOffset.width > 0 ? .keep : .delete)
                                .padding(24)
                                .opacity(min(1, abs(dragOffset.width) / 110))
                                .allowsHitTesting(false)
                        }
                    }
                    .overlay {
                        if let actionStamp {
                            SwipeStamp(action: actionStamp)
                                .transition(.opacity.combined(with: .scale(scale: 0.9)))
                                .allowsHitTesting(false)
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 12)
                            .onChanged { if !isDecisionLocked { dragOffset = $0.translation } }
                            .onEnded { value in
                                guard !isDecisionLocked else { return }
                                if let decision = CleanupSwipe.decision(
                                    translation: value.translation,
                                    predictedEnd: value.predictedEndTranslation
                                ) {
                                    commitDecision(decision, for: asset.id)
                                } else {
                                    withAnimation(reduceMotion ? nil : .snappy) { dragOffset = .zero }
                                }
                            }
                    )
                    .accessibilityAction(named: "Keep") { decideFromButton(.keep) }
                    .accessibilityAction(named: "Delete") { decideFromButton(.deletePending) }
            } else {
                unavailableCard
            }
        }
        .aspectRatio(0.76, contentMode: .fit)
    }

    private var decisionButtons: some View {
        HStack(spacing: 34) {
            DecisionButton(
                title: "Delete",
                icon: "xmark",
                color: RollSlashTheme.coral,
                accessibilityHint: "Stages this item for deletion. Photos is unchanged until final review."
            ) { decideFromButton(.deletePending) }
            .disabled(isDecisionLocked || appModel.currentAsset == nil)
            .accessibilityIdentifier("decision-delete")
            DecisionButton(
                title: "Keep",
                icon: "heart.fill",
                color: RollSlashTheme.keep,
                accessibilityHint: "Marks this item as reviewed and keeps it in Photos"
            ) { decideFromButton(.keep) }
            .disabled(isDecisionLocked || appModel.currentAsset == nil)
            .accessibilityIdentifier("decision-keep")
        }
    }

    private var historyButtons: some View {
        HStack(spacing: 24) {
            Button("Undo", systemImage: "arrow.uturn.backward") { undoFromPhoto() }
                .disabled(isDecisionLocked || !appModel.canUndo)
                .accessibilityIdentifier("undo-button")
            Button("Redo", systemImage: "arrow.uturn.forward") { redoFromButton() }
                .disabled(isDecisionLocked || !appModel.canRedo)
                .accessibilityIdentifier("redo-button")
        }
        .font(.subheadline.bold())
        .buttonStyle(.glass)
    }

    private var unavailableCard: some View {
        Group {
            if appModel.isLoading {
                ProgressView("Updating library…").tint(.white)
            } else {
                ContentUnavailableView {
                    Label("Photo unavailable", systemImage: "photo.badge.exclamationmark")
                } description: {
                    Text(appModel.canUndo
                         ? "This item is no longer in your library. Undo returns to the previous photo."
                         : "This item is no longer in your library.")
                }
                .foregroundStyle(.white)
            }
        }
    }
}

private struct HapticPulse: Equatable {
    enum Kind: Equatable {
        case success
        case warning
        case impact
    }

    let id: Int
    let kind: Kind

    var feedback: SensoryFeedback {
        switch kind {
        case .success: .success
        case .warning: .warning
        case .impact: .impact
        }
    }
}

enum CleanupSwipe {
    static let commitDistance: CGFloat = 100
    static let flickDistance: CGFloat = 28
    static let flickPredictedDistance: CGFloat = 140

    static func decision(translation: CGSize, predictedEnd: CGSize) -> AssetDecision? {
        guard abs(translation.width) > abs(translation.height) else { return nil }
        let width: CGFloat
        if abs(translation.width) >= commitDistance {
            width = translation.width
        } else if abs(translation.width) >= flickDistance,
                  abs(predictedEnd.width) >= flickPredictedDistance,
                  abs(predictedEnd.width) > abs(predictedEnd.height) {
            width = predictedEnd.width
        } else {
            return nil
        }
        return width > 0 ? .keep : .deletePending
    }
}

private enum ActionStamp {
    case keep
    case delete
    case undo
    case redo

    var title: LocalizedStringKey {
        switch self {
        case .keep: "KEEP"
        case .delete: "DELETE"
        case .undo: "UNDO"
        case .redo: "REDO"
        }
    }

    var symbol: String {
        switch self {
        case .keep: "heart.fill"
        case .delete: "xmark"
        case .undo: "arrow.uturn.backward"
        case .redo: "arrow.uturn.forward"
        }
    }

    var color: Color {
        switch self {
        case .keep: RollSlashTheme.keep
        case .delete: RollSlashTheme.coral
        case .undo, .redo: .white
        }
    }

    var haptic: HapticPulse.Kind {
        switch self {
        case .keep: .success
        case .delete: .warning
        case .undo, .redo: .impact
        }
    }
}

private struct SwipeStamp: View {
    let action: ActionStamp

    var body: some View {
        Label(action.title, systemImage: action.symbol)
            .font(.title.bold())
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .foregroundStyle(action.color)
            .background(.black.opacity(0.72), in: .capsule)
            .overlay(Capsule().stroke(action.color, lineWidth: 3))
            .shadow(color: .black.opacity(0.45), radius: 8)
    }
}

private struct DecisionButton: View {
    let title: LocalizedStringKey
    let icon: String
    let color: Color
    let accessibilityHint: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.title2.bold())
                    .frame(width: 62, height: 62)
                    .background(color, in: .circle)
                Text(title).font(.caption.bold())
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint(accessibilityHint)
    }
}

struct MediaCardView: View {
    @Environment(AppModel.self) private var appModel
    let asset: PhotoAssetDescriptor
    let onPhotoTap: () -> Void
    let onOpenPreview: (UIImage?) -> Void
    let isPreviewOpen: Bool

    @State private var image: UIImage?
    @State private var livePhoto: PHLivePhoto?
    @State private var player: AVPlayer?
    @State private var isLivePlaying = false
    @State private var isMuted = true
    @State private var failed = false
    @State private var isVisible = false
    @State private var retryCount = 0

    var body: some View {
        let request = PreviewImageRequest(identifier: asset.id, modificationDate: asset.modificationDate,
                                          targetSize: PreviewImageConfiguration.cardTargetSize, retryCount: retryCount)
        GeometryReader { _ in
            ZStack {
                Color.black
                media
                if failed {
                    ContentUnavailableView {
                        Label("Preview unavailable", systemImage: "icloud.slash")
                    } description: {
                        Text("The item may still be in iCloud.")
                    } actions: {
                        Button("Retry") { retryCount += 1 }
                    }
                    .foregroundStyle(.white)
                }
                VStack {
                    HStack {
                        mediaBadge
                        Spacer()
                        Button("Open full-screen preview", systemImage: "arrow.up.left.and.arrow.down.right") {
                            onOpenPreview(image)
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.glass)
                        .accessibilityIdentifier("open-media-viewer")
                        .accessibilityHint("Opens a preview where you can zoom and inspect details.")
                        if asset.mediaKind == .video {
                            Button(isMuted ? "Unmute" : "Mute", systemImage: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill") {
                                isMuted.toggle()
                                player?.isMuted = isMuted
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.glass)
                        }
                    }
                    Spacer()
                    if let date = asset.creationDate {
                        Text(date.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption.bold())
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(.black.opacity(0.5), in: .capsule)
                    }
                }
                .padding(14)
            }
            .clipShape(.rect(cornerRadius: 30))
            .task(id: request) { await load(request: request) }
            .onAppear {
                isVisible = true
                if asset.mediaKind == .video && !isPreviewOpen { player?.play() }
            }
            .onDisappear {
                isVisible = false
                player?.pause()
            }
            .onChange(of: isPreviewOpen) { _, isOpen in
                if isOpen { player?.pause() }
                else if isVisible && asset.mediaKind == .video { player?.play() }
            }
            .onLongPressGesture(minimumDuration: 0.1, pressing: { pressing in
                guard asset.mediaKind == .livePhoto else { return }
                isLivePlaying = pressing
            }, perform: {})
        }
    }

    @ViewBuilder
    private var media: some View {
        switch asset.mediaKind {
        case .photo:
            if let image { photoImage(image) } else { loading }
        case .livePhoto:
            if let livePhoto {
                photoContent(size: image?.size ?? CGSize(width: CGFloat(asset.pixelWidth), height: CGFloat(asset.pixelHeight))) {
                    LivePhotoPlayer(photo: livePhoto, isPlaying: isLivePlaying)
                }
            } else if let image {
                photoImage(image)
            } else {
                loading
            }
        case .video:
            if let player {
                VideoPlayer(player: player)
                    .onAppear { if !isPreviewOpen { player.play() } }
            } else if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                loading
            }
        }
    }

    private func photoImage(_ image: UIImage) -> some View {
        photoContent(size: image.size) {
            Image(uiImage: image).resizable().scaledToFit()
        }
    }

    private func photoContent<Content: View>(size: CGSize, @ViewBuilder content: @escaping () -> Content) -> some View {
        GeometryReader { proxy in
            let scale = min(proxy.size.width / max(size.width, 1), proxy.size.height / max(size.height, 1))
            let fittedSize = CGSize(width: size.width * scale, height: size.height * scale)
            content()
                .frame(width: fittedSize.width, height: fittedSize.height)
                .contentShape(Rectangle())
                .simultaneousGesture(TapGesture().onEnded { onPhotoTap() })
                .accessibilityIdentifier("cleanup-photo-surface")
                .accessibilityLabel("Current photo")
                .accessibilityHint("Tap to undo the previous decision")
                .accessibilityAction(named: "Undo") { onPhotoTap() }
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
    }

    private var loading: some View {
        VStack(spacing: 12) {
            ProgressView().tint(.white)
            Text("Loading preview…").font(.caption).foregroundStyle(.white.opacity(0.7))
        }
    }

    @ViewBuilder
    private var mediaBadge: some View {
        switch asset.mediaKind {
        case .photo:
            EmptyView()
        case .livePhoto:
            Label("LIVE", systemImage: "livephoto")
                .font(.caption.bold())
                .padding(8)
                .background(.black.opacity(0.5), in: .capsule)
        case .video:
            Label(durationText, systemImage: "video.fill")
                .font(.caption.bold())
                .padding(8)
                .background(.black.opacity(0.5), in: .capsule)
        }
    }

    private var durationText: String {
        let seconds = Int(asset.duration.rounded())
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func load(request: PreviewImageRequest) async {
        player?.pause()
        player = nil
        image = nil
        livePhoto = nil
        isLivePlaying = false
        failed = false
        let target = request.targetSize
        switch asset.mediaKind {
        case .photo, .livePhoto:
            let loadedImage = await appModel.previewProvider.image(for: asset.id, targetSize: target, kind: .active)
            guard !Task.isCancelled else { return }
            image = loadedImage
            if asset.mediaKind == .livePhoto {
                let loadedLivePhoto = await appModel.previewProvider.livePhoto(for: asset.id, targetSize: target)
                guard !Task.isCancelled else { return }
                livePhoto = loadedLivePhoto
            }
        case .video:
            let item = await appModel.previewProvider.playerItem(for: asset.id)
            guard !Task.isCancelled else { return }
            if let item {
                let player = AVPlayer(playerItem: item)
                player.isMuted = isMuted
                self.player = player
                if isVisible && !isPreviewOpen { player.play() }
            } else {
                let loadedImage = await appModel.previewProvider.image(for: asset.id, targetSize: target, kind: .active)
                guard !Task.isCancelled else { return }
                image = loadedImage
            }
        }
        failed = image == nil && livePhoto == nil && player == nil
    }
}

struct LivePhotoPlayer: UIViewRepresentable {
    let photo: PHLivePhoto
    let isPlaying: Bool

    func makeUIView(context: Context) -> PHLivePhotoView {
        let view = PHLivePhotoView()
        view.contentMode = .scaleAspectFit
        return view
    }

    func updateUIView(_ view: PHLivePhotoView, context: Context) {
        view.livePhoto = photo
        if isPlaying {
            view.startPlayback(with: .full)
        } else {
            view.stopPlayback()
        }
    }
}
