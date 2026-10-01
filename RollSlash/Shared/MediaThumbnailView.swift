import SwiftUI

struct MediaThumbnailView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.displayScale) private var displayScale
    let identifier: String?
    let size: CGSize
    var onImageLoaded: ((UIImage?) -> Void)? = nil

    @State private var image: UIImage?
    @State private var loadFailed = false

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if identifier == nil {
                Image(systemName: "sparkles")
                    .foregroundStyle(.secondary)
            } else if loadFailed {
                Image(systemName: "photo.badge.exclamationmark")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Thumbnail unavailable; open to load the photo")
            } else {
                ProgressView()
            }
        }
        .clipped()
        .task(id: identifier) {
            image = nil
            loadFailed = false
            guard let identifier else {
                onImageLoaded?(nil)
                return
            }
            let loadedImage = await appModel.previewProvider.image(
                for: identifier,
                targetSize: CGSize(width: size.width * displayScale, height: size.height * displayScale),
                kind: .thumbnail
            )
            guard !Task.isCancelled else { return }
            image = loadedImage
            loadFailed = loadedImage == nil
            onImageLoaded?(loadedImage)
        }
    }
}
