import AVKit
import Observation
import Photos
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// A distraction-free preview used when a card or review tile needs closer inspection.
/// Decision gestures intentionally live outside this view.
struct MediaViewer: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    let asset: PhotoAssetDescriptor
    var initialImage: UIImage? = nil
    var loadsFullResolution = false
    var onSwipeLeft: (() -> Void)? = nil
    var onSwipeRight: (() -> Void)? = nil
    var onDismissSwipe: ((CGSize) -> Void)? = nil
    var dismissSwipeAxis: Axis? = nil
    var onClose: (() -> Void)? = nil
    var dismissalOffset: CGSize = .zero
    var dismissalOpacity: Double = 1

    @State private var image: UIImage?
    @State private var hasDetailedImage = false
    @State private var livePhoto: PHLivePhoto?
    @State private var playback = VideoPreviewPlayback()
    @State private var isLivePlaying = false
    @State private var isMuted = true
    @State private var failed = false
    @State private var zoomScale: CGFloat = 1
    @State private var isFavorite = false
    @State private var isUpdatingFavorite = false
    @State private var favoriteTask: Task<Void, Never>?
    @State private var showingShareSheet = false
    @State private var shareURL: URL?
    @State private var shareTask: Task<Void, Never>?
    @State private var isPreparingShare = false
    @State private var shareErrorMessage: String?
    @State private var favoriteErrorMessage: String?
    @State private var loadGeneration = UUID()
    @State private var isLoadingFullResolution = false
    @State private var fullResolutionFailed = false
    @State private var retryCount = 0

    private struct LoadRequest: Hashable {
        let identifier: String
        let modificationDate: Date?
        let retryCount: Int
    }

    private var player: AVPlayer? { playback.player }

    var body: some View {
        ZStack {
            Color.black.opacity(dismissalOpacity).ignoresSafeArea()
            if asset.mediaKind == .video {
                VStack(spacing: 0) {
                    viewerToolbar
                        .background(.black.opacity(0.72))
                        .opacity(dismissalOpacity)
                    content
                        .id(asset.id)
                        .offset(dismissalOffset)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .ignoresSafeArea(edges: .bottom)
            } else {
                content
                    .ignoresSafeArea(edges: .bottom)
                    .id(asset.id)
                    .offset(dismissalOffset)

                VStack {
                    viewerToolbar.opacity(dismissalOpacity)
                        .background(.black.opacity(0.72))
                    Spacer()
                }
            }
        }
        .preferredColorScheme(.dark)
        .visibleSystemStatusBar()
        .task(id: LoadRequest(identifier: asset.id, modificationDate: asset.modificationDate,
                              retryCount: retryCount)) { await load() }
        .onDisappear {
            loadGeneration = UUID()
            favoriteTask?.cancel()
            favoriteTask = nil
            shareTask?.cancel()
            shareTask = nil
            playback.reset()
        }
        .onChange(of: asset.id) { _, _ in
            favoriteTask?.cancel()
            favoriteTask = nil
            isUpdatingFavorite = false
            shareTask?.cancel()
            shareTask = nil
            isPreparingShare = false
            cleanUpSharedVideo()
            showingShareSheet = false
        }
        .sheet(isPresented: $showingShareSheet, onDismiss: cleanUpSharedVideo) {
            if asset.mediaKind == .video, let shareURL {
                ShareSheet(items: [VideoActivityItemSource(url: shareURL)])
            } else if asset.mediaKind != .video, let image {
                ShareSheet(items: [image])
            }
        }
        .alert("Favorite could not be updated", isPresented: Binding(
            get: { favoriteErrorMessage != nil },
            set: { if !$0 { favoriteErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { favoriteErrorMessage = nil }
        } message: {
            Text(favoriteErrorMessage ?? "")
        }
        .alert("Share unavailable", isPresented: Binding(
            get: { shareErrorMessage != nil },
            set: { if !$0 { shareErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { shareErrorMessage = nil }
        } message: {
            Text(shareErrorMessage ?? "")
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 24)
                .onEnded { value in
                    handlePreviewSwipe(value)
                }
        )
        .onLongPressGesture(minimumDuration: 0.1, pressing: { pressing in
            guard asset.mediaKind == .livePhoto, zoomScale <= 1.001 else { return }
            isLivePlaying = pressing
        }, perform: {})
    }

    @ViewBuilder
    private var content: some View {
        switch asset.mediaKind {
        case .photo:
            zoomedStill
        case .livePhoto:
            if let livePhoto, let image {
                ZStack {
                    ZoomableImage(image: image, zoomScale: $zoomScale, onDismissSwipe: onDismissSwipe,
                                  dismissSwipeAxis: dismissSwipeAxis)
                    if isLivePlaying && zoomScale <= 1.001 {
                        LivePhotoPlayer(photo: livePhoto, isPlaying: true)
                            .allowsHitTesting(false)
                            .aspectRatio(contentMode: .fit)
                    }
                }
            } else if let livePhoto {
                LivePhotoPlayer(photo: livePhoto, isPlaying: isLivePlaying)
                    .aspectRatio(contentMode: .fit)
            } else {
                zoomedStill
            }
        case .video:
            if let player {
                VideoPlayer(player: player)
                    .accessibilityLabel("Video preview")
                    .onAppear { player.play() }
            } else if failed || playback.hasFailed {
                unavailablePreview
            } else {
                loading
            }
        }
    }

    @ViewBuilder
    private var zoomedStill: some View {
        if let image {
            ZoomableImage(image: image, zoomScale: $zoomScale, onDismissSwipe: onDismissSwipe,
                          dismissSwipeAxis: dismissSwipeAxis)
        } else if failed {
            unavailablePreview
        } else {
            loading
        }
    }

    private var unavailablePreview: some View {
        ContentUnavailableView {
            Label("Preview unavailable", systemImage: "icloud.slash")
        } description: {
            Text("The item may still be in iCloud.")
        } actions: {
            Button("Retry") { retryCount += 1 }
        }
        .foregroundStyle(.white)
    }

    private var loading: some View {
        ProgressView("Loading preview…")
            .tint(.white)
            .foregroundStyle(.white)
    }

    private var viewerToolbar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(asset.mediaKind == .video ? "Video preview" : "Photo preview")
                    .font(.headline)
                if isLoadingFullResolution {
                    ProgressView("Loading full resolution…").font(.caption).tint(.white)
                } else if fullResolutionFailed {
                    Button("Retry full resolution") { retryCount += 1 }
                        .font(.caption)
                }
            }
            .foregroundStyle(.white)
            Spacer()
            if image != nil {
                Button(
                    isFavorite ? "Remove from Favorites" : "Add to Favorites",
                    systemImage: isFavorite ? "heart.fill" : "heart"
                ) {
                    toggleFavorite()
                }
                .labelStyle(.iconOnly)
                .font(.title3.weight(.semibold))
                .foregroundStyle(isFavorite ? RollSlashTheme.coral : .white)
                .padding(12)
                .background(.black.opacity(0.55), in: .circle)
                .disabled(isUpdatingFavorite)
                .accessibilityIdentifier("favorite-media")
                .accessibilityLabel(isFavorite ? "Remove from Favorites" : "Add to Favorites")
            }
            if (image != nil && hasDetailedImage) || asset.mediaKind == .video {
                Button(action: share) {
                    if isPreparingShare {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .padding(12)
                .background(.black.opacity(0.55), in: .circle)
                .disabled(isPreparingShare)
                .accessibilityIdentifier("share-media")
                .accessibilityLabel(isPreparingShare
                    ? "Preparing video for sharing"
                    : (asset.mediaKind == .video ? "Share video" : "Share photo"))
            }
            if asset.mediaKind == .video {
                Button(isMuted ? "Unmute" : "Mute", systemImage: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill") {
                    isMuted.toggle()
                    player?.isMuted = isMuted
                }
                .labelStyle(.iconOnly)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .padding(12)
                .background(.black.opacity(0.55), in: .circle)
                .accessibilityHint("Toggles sound for this video preview.")
            }
            Button("Close", systemImage: "xmark") {
                if let onClose { onClose() } else { dismiss() }
            }
            .labelStyle(.iconOnly)
            .font(.title3.weight(.semibold))
            .foregroundStyle(.white)
            .padding(12)
            .background(.black.opacity(0.55), in: .circle)
            .accessibilityIdentifier("close-media-viewer")
            .accessibilityLabel("Close full-screen preview")
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private func load() async {
        let generation = UUID()
        loadGeneration = generation
        let identifier = asset.id
        playback.reset()
        image = initialImage
        hasDetailedImage = false
        livePhoto = nil
        isLivePlaying = false
        zoomScale = 1
        failed = false
        isFavorite = false
        isLoadingFullResolution = false
        fullResolutionFailed = false
        favoriteErrorMessage = nil
        shareErrorMessage = nil
        isUpdatingFavorite = true
        let favorite = await appModel.isFavorite(identifier)
        guard isCurrent(generation) else { return }
        isFavorite = favorite
        isUpdatingFavorite = false
        let target = CGSize(width: 1600, height: 2200)
        switch asset.mediaKind {
        case .photo, .livePhoto:
            let detailedImage = await appModel.previewProvider.image(for: identifier, targetSize: target, kind: .active)
            guard isCurrent(generation) else { return }
            if let detailedImage {
                image = detailedImage
                hasDetailedImage = true
            }
        case .video:
            let item = await appModel.previewProvider.playerItem(for: identifier)
            guard isCurrent(generation) else { return }
            playback.load(item, isMuted: isMuted)
            failed = player == nil
            let detailedImage = await appModel.previewProvider.image(for: identifier, targetSize: target, kind: .active)
            guard isCurrent(generation) else { return }
            if let detailedImage {
                image = detailedImage
                hasDetailedImage = true
            }
        }
        guard isCurrent(generation) else { return }
        if loadsFullResolution && asset.mediaKind != .video {
            isLoadingFullResolution = true
            let original = await appModel.previewProvider.image(for: identifier, targetSize: target, kind: .fullResolution)
            guard isCurrent(generation) else { return }
            isLoadingFullResolution = false
            if let original {
                image = original
                hasDetailedImage = true
            } else {
                fullResolutionFailed = true
            }
        }
        if asset.mediaKind == .livePhoto {
            let motion = await appModel.previewProvider.livePhoto(for: identifier, targetSize: target)
            guard isCurrent(generation) else { return }
            livePhoto = motion
        }
        failed = asset.mediaKind == .video ? player == nil : image == nil && livePhoto == nil
    }

    private func isCurrent(_ generation: UUID) -> Bool {
        !Task.isCancelled && generation == loadGeneration
    }

    private func toggleFavorite() {
        guard !isUpdatingFavorite else { return }
        let nextValue = !isFavorite
        let identifier = asset.id
        let generation = loadGeneration
        isUpdatingFavorite = true
        favoriteTask?.cancel()
        favoriteTask = Task { @MainActor in
            defer { if generation == loadGeneration { isUpdatingFavorite = false } }
            do {
                try await appModel.setFavorite(nextValue, for: identifier)
                guard isCurrent(generation) else { return }
                isFavorite = nextValue
            } catch is CancellationError {
                return
            } catch {
                guard isCurrent(generation) else { return }
                favoriteErrorMessage = error.localizedDescription
            }
        }
    }

    private func share() {
        guard asset.mediaKind == .video else {
            if image != nil { showingShareSheet = true }
            return
        }
        guard !isPreparingShare else { return }
        let identifier = asset.id
        let generation = loadGeneration
        isPreparingShare = true
        shareTask = Task { @MainActor in
            defer { if generation == loadGeneration { isPreparingShare = false } }
            do {
                guard let url = try await appModel.previewProvider.shareableVideoURL(for: identifier) else {
                    guard isCurrent(generation) else { return }
                    shareErrorMessage = String(localized: "This video is no longer available for sharing.")
                    return
                }
                guard isCurrent(generation) else {
                    try? FileManager.default.removeItem(at: url)
                    return
                }
                shareURL = url
                showingShareSheet = true
            } catch is CancellationError {
                return
            } catch {
                guard isCurrent(generation) else { return }
                shareErrorMessage = error.localizedDescription
            }
        }
    }

    private func cleanUpSharedVideo() {
        if let shareURL { try? FileManager.default.removeItem(at: shareURL) }
        shareURL = nil
    }

    private func handlePreviewSwipe(_ value: DragGesture.Value) {
        // The photo owns dismissal and retains its release offset. A vertical
        // dismissal policy still allows horizontal comparison navigation here.
        guard onDismissSwipe == nil || dismissSwipeAxis == .vertical else { return }
        // VideoPlayer owns horizontal drags for scrubbing. Use the explicit
        // Previous/Next controls for video review navigation instead.
        guard asset.mediaKind != .video else { return }
        guard zoomScale <= 1.001 else { return }
        guard abs(value.translation.width) > abs(value.translation.height),
              abs(value.translation.width) >= 80 else { return }
        if value.translation.width < 0 { onSwipeLeft?() } else { onSwipeRight?() }
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private final class VideoActivityItemSource: NSObject, UIActivityItemSource {
    private let url: URL

    init(url: URL) {
        self.url = url
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        url
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        itemForActivityType activityType: UIActivity.ActivityType?
    ) -> Any? {
        url
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        dataTypeIdentifierForActivityType activityType: UIActivity.ActivityType?
    ) -> String {
        UTType(filenameExtension: url.pathExtension)?.identifier ?? UTType.movie.identifier
    }
}

@MainActor
@Observable
final class VideoPreviewPlayback {
    private(set) var player: AVPlayer?
    private(set) var hasFailed = false
    @ObservationIgnored private var observation: VideoFailureObservation?
    @ObservationIgnored private var generation = UUID()

    func load(_ item: AVPlayerItem?, isMuted: Bool) {
        reset()
        guard let item else { hasFailed = true; return }
        let player = AVPlayer(playerItem: item)
        player.isMuted = isMuted
        self.player = player
        let generation = self.generation
        observation = VideoFailureObservation(item: item) { [weak self] in
            Task { @MainActor in self?.recordFailure(generation: generation) }
        }
        if item.status == .failed {
            recordFailure(generation: generation)
        } else {
            player.play()
        }
    }

    func reset() {
        generation = UUID()
        observation = nil
        player?.pause()
        player = nil
        hasFailed = false
    }

    private func recordFailure(generation: UUID) {
        guard generation == self.generation, player != nil else { return }
        observation = nil
        player?.pause()
        player = nil
        hasFailed = true
    }
}

private final class VideoFailureObservation {
    private let status: NSKeyValueObservation
    private let failedToPlay: NSObjectProtocol

    init(item: AVPlayerItem, onFailure: @escaping @Sendable () -> Void) {
        status = item.observe(\.status, options: [.initial, .new]) { item, _ in
            if item.status == .failed { onFailure() }
        }
        failedToPlay = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: nil
        ) { _ in onFailure() }
    }

    deinit {
        status.invalidate()
        NotificationCenter.default.removeObserver(failedToPlay)
    }
}

private struct ZoomableImage: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let image: UIImage
    @Binding var zoomScale: CGFloat
    var onDismissSwipe: ((CGSize) -> Void)? = nil
    var dismissSwipeAxis: Axis? = nil

    @State private var offset = CGSize.zero
    @State private var gestureScale: CGFloat = 1
    @State private var gestureOffset = CGSize.zero

    var body: some View {
        GeometryReader { proxy in
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .scaleEffect(zoomScale * gestureScale)
                .offset(x: offset.width + gestureOffset.width, y: offset.height + gestureOffset.height)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    SimultaneousGesture(
                        MagnifyGesture()
                            .onChanged { value in gestureScale = value.magnification }
                            .onEnded { value in
                                zoomScale = clampedScale(zoomScale * value.magnification)
                                gestureScale = 1
                                offset = clampedOffset(offset, scale: zoomScale, in: proxy.size)
                        },
                        DragGesture()
                            .onChanged { value in
                                if onDismissSwipe == nil
                                    || dismissSwipeAxis == .vertical
                                    || zoomScale > 1.001
                                    || fittedPhotoRect(in: proxy.size).contains(value.startLocation) {
                                    gestureOffset = value.translation
                                }
                            }
                            .onEnded { value in
                                let startsOnPhoto = fittedPhotoRect(in: proxy.size).contains(value.startLocation)
                                let shouldDismiss = onDismissSwipe != nil
                                    && (dismissSwipeAxis == .vertical || startsOnPhoto)
                                    && (dismissSwipeAxis != .vertical || abs(value.translation.height) > abs(value.translation.width))
                                    && zoomScale <= 1.001
                                    && gestureScale <= 1.001
                                    && max(abs(value.translation.width), abs(value.translation.height)) >= 80
                                if shouldDismiss {
                                    // Do not snap to zero before the parent flies the preview out.
                                    onDismissSwipe?(value.translation)
                                } else {
                                    offset = clampedOffset(
                                        CGSize(width: offset.width + value.translation.width, height: offset.height + value.translation.height),
                                        scale: zoomScale,
                                        in: proxy.size
                                    )
                                    gestureOffset = .zero
                                }
                            }
                    )
                )
                .onTapGesture(count: 2) {
                    withAnimation(reduceMotion ? nil : .snappy) {
                        zoomScale = zoomScale > 1.01 ? 1 : 3
                        offset = .zero
                    }
                }
                .accessibilityLabel("Photo preview")
                .accessibilityHint("Pinch to zoom, drag to pan, and double tap to toggle zoom.")
        }
    }

    private func clampedScale(_ proposed: CGFloat) -> CGFloat {
        min(max(proposed, 1), 5)
    }

    private func fittedPhotoRect(in size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0, image.size.width > 0, image.size.height > 0 else { return .zero }
        let fit = min(size.width / image.size.width, size.height / image.size.height)
        let fittedSize = CGSize(width: image.size.width * fit, height: image.size.height * fit)
        return CGRect(
            x: (size.width - fittedSize.width) / 2,
            y: (size.height - fittedSize.height) / 2,
            width: fittedSize.width,
            height: fittedSize.height
        )
    }

    private func clampedOffset(_ proposed: CGSize, scale: CGFloat, in size: CGSize) -> CGSize {
        guard scale > 1 else { return .zero }
        let fittedImageSize: CGSize
        if image.size.width > 0, image.size.height > 0, size.width > 0, size.height > 0 {
            let fit = min(size.width / image.size.width, size.height / image.size.height)
            fittedImageSize = CGSize(width: image.size.width * fit, height: image.size.height * fit)
        } else {
            fittedImageSize = size
        }
        let horizontal = max(0, (fittedImageSize.width * scale - size.width) / 2)
        let vertical = max(0, (fittedImageSize.height * scale - size.height) / 2)
        return CGSize(
            width: min(max(proposed.width, -horizontal), horizontal),
            height: min(max(proposed.height, -vertical), vertical)
        )
    }
}
