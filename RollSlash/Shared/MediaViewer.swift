import AVKit
import Photos
import PhotosUI
import SwiftUI
import UIKit

/// A distraction-free preview used when a card or review tile needs closer inspection.
/// Decision gestures intentionally live outside this view.
struct MediaViewer: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    let asset: PhotoAssetDescriptor
    var initialImage: UIImage? = nil
    var onSwipeLeft: (() -> Void)? = nil
    var onSwipeRight: (() -> Void)? = nil
    var onDismissSwipe: ((CGSize) -> Void)? = nil
    var onClose: (() -> Void)? = nil
    var dismissalOffset: CGSize = .zero
    var dismissalOpacity: Double = 1

    @State private var image: UIImage?
    @State private var hasDetailedImage = false
    @State private var livePhoto: PHLivePhoto?
    @State private var player: AVPlayer?
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
                    .ignoresSafeArea()
                    .id(asset.id)
                    .offset(dismissalOffset)

                VStack {
                    viewerToolbar.opacity(dismissalOpacity)
                    Spacer()
                }
            }
        }
        .task(id: asset.id) { await load() }
        .onDisappear {
            favoriteTask?.cancel()
            favoriteTask = nil
            shareTask?.cancel()
            shareTask = nil
            player?.pause()
        }
        .onChange(of: asset.id) { _, _ in
            shareTask?.cancel()
            shareTask = nil
            isPreparingShare = false
        }
        .sheet(isPresented: $showingShareSheet, onDismiss: cleanUpSharedVideo) {
            if let shareURL {
                ShareSheet(items: [shareURL])
            } else if let image {
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
                    handleNavigationSwipe(value)
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
                    ZoomableImage(image: image, zoomScale: $zoomScale, onDismissSwipe: onDismissSwipe)
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
            } else {
                loading
            }
        }
    }

    @ViewBuilder
    private var zoomedStill: some View {
        if let image {
            ZoomableImage(image: image, zoomScale: $zoomScale, onDismissSwipe: onDismissSwipe)
        } else if failed {
            ContentUnavailableView {
                Label("Preview unavailable", systemImage: "icloud.slash")
            } description: {
                Text("The item may still be in iCloud.")
            } actions: {
                Button("Retry") { Task { await load() } }
            }
            .foregroundStyle(.white)
        } else {
            loading
        }
    }

    private var loading: some View {
        ProgressView("Loading preview…")
            .tint(.white)
            .foregroundStyle(.white)
    }

    private var viewerToolbar: some View {
        HStack {
            Text(asset.mediaKind == .video ? "Video preview" : "Photo preview")
                .font(.headline)
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
        player?.pause()
        player = nil
        image = initialImage
        hasDetailedImage = false
        livePhoto = nil
        isLivePlaying = false
        zoomScale = 1
        failed = false
        isFavorite = false
        favoriteErrorMessage = nil
        shareErrorMessage = nil
        let target = CGSize(width: 1600, height: 2200)
        switch asset.mediaKind {
        case .photo:
            if let detailedImage = await appModel.previewProvider.image(for: asset.id, targetSize: target, kind: .active) {
                image = detailedImage
                hasDetailedImage = true
            }
        case .livePhoto:
            if let detailedImage = await appModel.previewProvider.image(for: asset.id, targetSize: target, kind: .active) {
                image = detailedImage
                hasDetailedImage = true
            }
            guard !Task.isCancelled else { return }
            livePhoto = await appModel.previewProvider.livePhoto(for: asset.id, targetSize: target)
        case .video:
            if let item = await appModel.previewProvider.playerItem(for: asset.id) {
                guard !Task.isCancelled else { return }
                let newPlayer = AVPlayer(playerItem: item)
                newPlayer.isMuted = isMuted
                player = newPlayer
                newPlayer.play()
            }
            if let detailedImage = await appModel.previewProvider.image(for: asset.id, targetSize: target, kind: .active) {
                image = detailedImage
                hasDetailedImage = true
            }
        }
        guard !Task.isCancelled else { return }
        isFavorite = await appModel.isFavorite(asset.id)
        failed = image == nil && livePhoto == nil && player == nil
    }

    private func toggleFavorite() {
        guard !isUpdatingFavorite else { return }
        let nextValue = !isFavorite
        isUpdatingFavorite = true
        favoriteTask?.cancel()
        favoriteTask = Task { @MainActor in
            defer { isUpdatingFavorite = false }
            do {
                try await appModel.setFavorite(nextValue, for: asset.id)
                guard !Task.isCancelled else { return }
                isFavorite = nextValue
            } catch is CancellationError {
                return
            } catch {
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
        isPreparingShare = true
        shareTask = Task { @MainActor in
            defer { isPreparingShare = false }
            do {
                guard let url = try await appModel.previewProvider.shareableVideoURL(for: asset.id) else {
                    shareErrorMessage = String(localized: "This video is no longer available for sharing.")
                    return
                }
                guard !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: url)
                    return
                }
                shareURL = url
                showingShareSheet = true
            } catch is CancellationError {
                return
            } catch {
                shareErrorMessage = error.localizedDescription
            }
        }
    }

    private func cleanUpSharedVideo() {
        if let shareURL { try? FileManager.default.removeItem(at: shareURL) }
        shareURL = nil
    }

    private func handleNavigationSwipe(_ value: DragGesture.Value) {
        // Cleanup dismissal is handled by the fitted photo's gesture so blank
        // margins around an aspect-fit image cannot dismiss the viewer.
        guard onDismissSwipe == nil else { return }
        // VideoPlayer owns horizontal drags for scrubbing. Use the explicit
        // Previous/Next controls for video review navigation instead.
        guard asset.mediaKind != .video else { return }
        guard zoomScale <= 1.001 else { return }
        guard abs(value.translation.width) > abs(value.translation.height) else { return }
        guard abs(value.translation.width) >= 80 else { return }

        if value.translation.width < 0 {
            onSwipeLeft?()
        } else {
            onSwipeRight?()
        }
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private struct ZoomableImage: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let image: UIImage
    @Binding var zoomScale: CGFloat
    var onDismissSwipe: ((CGSize) -> Void)? = nil

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
                                    || zoomScale > 1.001
                                    || fittedPhotoRect(in: proxy.size).contains(value.startLocation) {
                                    gestureOffset = value.translation
                                }
                            }
                            .onEnded { value in
                                let startsOnPhoto = fittedPhotoRect(in: proxy.size).contains(value.startLocation)
                                let shouldDismiss = onDismissSwipe != nil
                                    && startsOnPhoto
                                    && zoomScale <= 1.001
                                    && gestureScale <= 1.001
                                    && max(abs(value.translation.width), abs(value.translation.height)) >= 80
                                if shouldDismiss {
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
