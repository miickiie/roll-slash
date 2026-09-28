import AVKit
import PhotosUI
import SwiftUI

struct CleanupView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragOffset: CGSize = .zero
    @State private var showingReviewNowConfirmation = false

    var body: some View {
        ZStack {
            RollSlashTheme.background.ignoresSafeArea()
            VStack(spacing: 14) {
                header
                Spacer(minLength: 0)
                deck
                Spacer(minLength: 0)
                decisionButtons
                historyButtons
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
        }
        .foregroundStyle(.white)
        .alert("Roll Slash", isPresented: Binding(
            get: { appModel.errorMessage != nil },
            set: { if !$0 { appModel.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { appModel.errorMessage = nil }
        } message: {
            Text(appModel.errorMessage ?? "")
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack {
                Button("Close", systemImage: "chevron.down") { appModel.route = .dashboard }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)
            Spacer()
            VStack(spacing: 1) {
                Text("\(appModel.sessionRemaining) left").font(.headline)
                Text("\(appModel.keptCount) kept  •  \(appModel.deleteCount) to delete")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
            }
            Spacer()
            Button("Review deletes now", systemImage: "checkmark.seal") {
                showingReviewNowConfirmation = true
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.glass)
            .disabled(appModel.deleteCount == 0)
            .accessibilityIdentifier("review-now")
            .accessibilityHint("Review items currently marked for deletion now, while leaving unswiped items for later.")
            .sheet(isPresented: $showingReviewNowConfirmation) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Review deletes now?")
                        .font(.headline)
                    Text("This reviews the \(appModel.deleteCount) item\(appModel.deleteCount == 1 ? "" : "s") currently marked for deletion. Unswiped items stay in this session for later.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    HStack {
                        Spacer()
                        Button("Keep Swiping") { showingReviewNowConfirmation = false }
                            .buttonStyle(.bordered)
                        Button("Review Deletes") {
                            showingReviewNowConfirmation = false
                            Task { @MainActor in
                                await Task.yield()
                                appModel.reviewCurrentBatch()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(RollSlashTheme.coral)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
            }
        }
        ProgressView(value: Double(appModel.sessionCompleted), total: Double(max(appModel.sessionTotal, 1)))
            .tint(RollSlashTheme.coral)
        }
    }

    private var deck: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 30).fill(.white.opacity(0.08)).offset(y: 12).scaleEffect(0.94)
            RoundedRectangle(cornerRadius: 30).fill(.white.opacity(0.12)).offset(y: 6).scaleEffect(0.97)
            if let asset = appModel.currentAsset {
                MediaCardView(asset: asset)
                    .id(asset.id)
                    .offset(dragOffset)
                    .rotationEffect(.degrees(Double(dragOffset.width / 22)))
                    .overlay(alignment: dragOffset.width >= 0 ? .topLeading : .topTrailing) {
                        if abs(dragOffset.width) > 35 {
                            SwipeStamp(decision: dragOffset.width > 0 ? .keep : .deletePending)
                                .padding(24)
                                .opacity(min(1, abs(dragOffset.width) / 110))
                        }
                    }
                    .gesture(
                        DragGesture()
                            .onChanged { dragOffset = $0.translation }
                            .onEnded { value in
                                let decision: AssetDecision? = if value.translation.width > 100 {
                                    .keep
                                } else if value.translation.width < -100 {
                                    .deletePending
                                } else {
                                    nil
                                }
                                if let decision {
                                    withAnimation(reduceMotion ? nil : .snappy) {
                                        dragOffset.width = decision == .keep ? 700 : -700
                                    } completion: {
                                        dragOffset = .zero
                                        appModel.decide(decision)
                                    }
                                } else {
                                    withAnimation(.snappy) { dragOffset = .zero }
                                }
                            }
                    )
                    .accessibilityAction(named: "Keep") { appModel.decide(.keep) }
                    .accessibilityAction(named: "Delete") { appModel.decide(.deletePending) }
            } else {
                ProgressView().tint(.white)
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
            ) { appModel.decide(.deletePending) }
            .accessibilityIdentifier("decision-delete")
            DecisionButton(
                title: "Keep",
                icon: "heart.fill",
                color: RollSlashTheme.keep,
                accessibilityHint: "Marks this item as reviewed and keeps it in Photos"
            ) { appModel.decide(.keep) }
            .accessibilityIdentifier("decision-keep")
        }
    }

    private var historyButtons: some View {
        HStack(spacing: 24) {
            Button("Undo", systemImage: "arrow.uturn.backward") { appModel.undo() }
                .disabled(!appModel.canUndo)
                .accessibilityIdentifier("undo-button")
            Button("Redo", systemImage: "arrow.uturn.forward") { appModel.redo() }
                .disabled(!appModel.canRedo)
                .accessibilityIdentifier("redo-button")
        }
        .font(.subheadline.bold())
        .buttonStyle(.glass)
    }
}

private struct SwipeStamp: View {
    let decision: AssetDecision

    var body: some View {
        Label(decision == .keep ? "KEEP" : "DELETE", systemImage: decision == .keep ? "heart.fill" : "xmark")
            .font(.title.bold())
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .foregroundStyle(decision == .keep ? RollSlashTheme.keep : RollSlashTheme.coral)
            .background(.black.opacity(0.48), in: .capsule)
            .overlay(Capsule().stroke(decision == .keep ? RollSlashTheme.keep : RollSlashTheme.coral, lineWidth: 3))
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

    @State private var image: UIImage?
    @State private var livePhoto: PHLivePhoto?
    @State private var player: AVPlayer?
    @State private var isLivePlaying = false
    @State private var isMuted = true
    @State private var failed = false
    @State private var isVisible = false
    @State private var showingViewer = false

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black
                media
                if failed {
                    ContentUnavailableView {
                        Label("Preview unavailable", systemImage: "icloud.slash")
                    } description: {
                        Text("The item may still be in iCloud.")
                    } actions: {
                        Button("Retry") { Task { await load(size: proxy.size) } }
                    }
                    .foregroundStyle(.white)
                }
                VStack {
                    HStack {
                        mediaBadge
                        Spacer()
                        Button("Open full-screen preview", systemImage: "arrow.up.left.and.arrow.down.right") {
                            showingViewer = true
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
            .task(id: asset.id) { await load(size: proxy.size) }
            .fullScreenCover(isPresented: $showingViewer) {
                MediaViewer(asset: asset)
            }
            .onAppear {
                isVisible = true
                if asset.mediaKind == .video { player?.play() }
            }
            .onDisappear {
                isVisible = false
                player?.pause()
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
                LivePhotoPlayer(photo: livePhoto, isPlaying: isLivePlaying)
            } else if let image {
                photoImage(image)
            } else {
                loading
            }
        case .video:
            if let player {
                VideoPlayer(player: player)
                    .onAppear { player.play() }
            } else if let image {
                photoImage(image)
            } else {
                loading
            }
        }
    }

    private func photoImage(_ image: UIImage) -> some View {
        Image(uiImage: image).resizable().scaledToFit()
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

    private func load(size: CGSize) async {
        failed = false
        let target = CGSize(width: 900, height: 1200)
        let loadedImage = await appModel.previewProvider.image(for: asset.id, targetSize: target, kind: .active)
        guard !Task.isCancelled else { return }
        image = loadedImage
        switch asset.mediaKind {
        case .photo: break
        case .livePhoto:
            let loadedLivePhoto = await appModel.previewProvider.livePhoto(for: asset.id, targetSize: target)
            guard !Task.isCancelled else { return }
            livePhoto = loadedLivePhoto
        case .video:
            if let item = await appModel.previewProvider.playerItem(for: asset.id) {
                guard !Task.isCancelled else { return }
                let player = AVPlayer(playerItem: item)
                player.isMuted = isMuted
                self.player = player
                if isVisible { player.play() }
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
