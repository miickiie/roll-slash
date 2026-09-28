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
    var onSwipeLeft: (() -> Void)? = nil
    var onSwipeRight: (() -> Void)? = nil

    @State private var image: UIImage?
    @State private var livePhoto: PHLivePhoto?
    @State private var player: AVPlayer?
    @State private var isLivePlaying = false
    @State private var isMuted = true
    @State private var failed = false
    @State private var zoomScale: CGFloat = 1

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            content
                .ignoresSafeArea()
                .id(asset.id)

            VStack {
                HStack {
                    Text(asset.mediaKind == .video ? "Video preview" : "Photo preview")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Spacer()
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
                    Button("Close", systemImage: "xmark") { dismiss() }
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
                Spacer()
            }
        }
        .task(id: asset.id) { await load() }
        .onDisappear { player?.pause() }
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
                    ZoomableImage(image: image, zoomScale: $zoomScale)
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
            ZoomableImage(image: image, zoomScale: $zoomScale)
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

    private func load() async {
        player?.pause()
        player = nil
        image = nil
        livePhoto = nil
        isLivePlaying = false
        zoomScale = 1
        failed = false
        let target = CGSize(width: 1600, height: 2200)
        image = await appModel.previewProvider.image(for: asset.id, targetSize: target, kind: .active)
        guard !Task.isCancelled else { return }

        switch asset.mediaKind {
        case .photo:
            break
        case .livePhoto:
            livePhoto = await appModel.previewProvider.livePhoto(for: asset.id, targetSize: target)
        case .video:
            if let item = await appModel.previewProvider.playerItem(for: asset.id) {
                guard !Task.isCancelled else { return }
                let newPlayer = AVPlayer(playerItem: item)
                newPlayer.isMuted = isMuted
                player = newPlayer
                newPlayer.play()
            }
        }
        failed = image == nil && livePhoto == nil && player == nil
    }

    private func handleNavigationSwipe(_ value: DragGesture.Value) {
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

private struct ZoomableImage: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let image: UIImage
    @Binding var zoomScale: CGFloat

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
                            .onChanged { value in gestureOffset = value.translation }
                            .onEnded { value in
                                offset = clampedOffset(
                                    CGSize(width: offset.width + value.translation.width, height: offset.height + value.translation.height),
                                    scale: zoomScale,
                                    in: proxy.size
                                )
                                gestureOffset = .zero
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
