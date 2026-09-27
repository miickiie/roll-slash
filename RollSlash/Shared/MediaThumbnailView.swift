import SwiftUI

struct MediaThumbnailView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.displayScale) private var displayScale
    let identifier: String?
    let size: CGSize

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if identifier == nil {
                Image(systemName: "sparkles")
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .clipped()
        .task(id: identifier) {
            guard let identifier else { return }
            image = await appModel.previewProvider.image(
                for: identifier,
                targetSize: CGSize(width: size.width * displayScale, height: size.height * displayScale),
                kind: .thumbnail
            )
        }
    }
}
