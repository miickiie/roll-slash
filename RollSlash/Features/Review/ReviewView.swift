import SwiftUI

struct ReviewView: View {
    @Environment(AppModel.self) private var appModel
    @State private var focusedIdentifier: String?

    private let columns = Array(repeating: GridItem(.flexible(minimum: 72, maximum: 110), spacing: 4), count: 4)

    private var reviewPreviewAssets: [PhotoAssetDescriptor] {
        let assetsByID = Dictionary(uniqueKeysWithValues: appModel.assets.map { ($0.id, $0) })
        return appModel.reviewCandidateIDs.compactMap { assetsByID[$0] }
    }

    private var allCandidatesSelected: Bool {
        let candidates = Set(appModel.reviewCandidateIDs)
        return !candidates.isEmpty && candidates.isSubset(of: appModel.reviewSelectedIDs)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    Text("\(appModel.reviewSelectedIDs.count) selected for deletion")
                        .font(.subheadline.bold())
                    Spacer()
                    Button("Select All", systemImage: "checkmark.circle") {
                        appModel.selectAllForDeletion()
                    }
                    .buttonStyle(.bordered)
                    .disabled(allCandidatesSelected || appModel.reviewCandidateIDs.isEmpty)
                    .accessibilityIdentifier("select-all")
                    .accessibilityHint("Select every item currently marked for deletion.")
                }
                .padding()

                ScrollView {
                    LazyVGrid(columns: columns, spacing: 3) {
                        ForEach(appModel.reviewCandidateIDs, id: \.self) { identifier in
                            ReviewTile(
                                identifier: identifier,
                                isSelected: appModel.reviewSelectedIDs.contains(identifier)
                            ) {
                                appModel.toggleReviewSelection(identifier)
                            } preview: {
                                focusedIdentifier = identifier
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                }
            }
            .navigationTitle("Final review")
            .navigationSubtitle("Unselected items will be kept")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { appModel.route = .dashboard }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Undo Last", systemImage: "arrow.uturn.backward") {
                        appModel.undoLastSwipeFromReview()
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button(role: .destructive) {
                    Task { await appModel.commitDeletion() }
                } label: {
                    HStack {
                        if appModel.isDeleting { ProgressView().tint(.white) }
            Text(appModel.reviewSelectedIDs.isEmpty
                 ? (appModel.sessionRemaining > 0 ? "Finish this batch" : "Finish without deleting")
                 : "Delete \(appModel.reviewSelectedIDs.count) items")
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                }
                .buttonStyle(.borderedProminent)
                .tint(appModel.reviewSelectedIDs.isEmpty ? RollSlashTheme.violet : RollSlashTheme.coral)
                .disabled(appModel.isDeleting)
                .accessibilityIdentifier("commit-deletion")
                .padding()
                .background(.ultraThinMaterial)
            }
.fullScreenCover(item: Binding(
    get: { focusedIdentifier.map(PreviewIdentifier.init) },
    set: { focusedIdentifier = $0?.id }
)) { item in
    if reviewPreviewAssets.contains(where: { $0.id == item.id }) {
        ReviewMediaViewer(
            assets: reviewPreviewAssets,
            initialIdentifier: item.id
        )
    } else {
        ContentUnavailableView("Item unavailable", systemImage: "photo.badge.exclamationmark")
    }
}
            .alert("Deletion did not complete", isPresented: Binding(
                get: { appModel.errorMessage != nil },
                set: { if !$0 { appModel.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { appModel.errorMessage = nil }
            } message: {
                Text(appModel.errorMessage ?? "")
            }
        }
    }
}

private struct PreviewIdentifier: Identifiable {
    let id: String
}

private struct ReviewMediaViewer: View {
    @Environment(AppModel.self) private var appModel

    let assets: [PhotoAssetDescriptor]
    @State private var currentIndex: Int

    init(assets: [PhotoAssetDescriptor], initialIdentifier: String) {
        self.assets = assets
        _currentIndex = State(initialValue: assets.firstIndex(where: { $0.id == initialIdentifier }) ?? 0)
    }

    private var currentAsset: PhotoAssetDescriptor? {
        guard assets.indices.contains(currentIndex) else { return nil }
        return assets[currentIndex]
    }

    private var isCurrentSelected: Bool {
        guard let currentAsset else { return false }
        return appModel.reviewSelectedIDs.contains(currentAsset.id)
    }

    var body: some View {
        Group {
            if let currentAsset {
                MediaViewer(
                    asset: currentAsset,
                    onSwipeLeft: advance,
                    onSwipeRight: goBack
                )
                .overlay(alignment: .bottom) {
                    controls
                }
            } else {
                ContentUnavailableView("Item unavailable", systemImage: "photo.badge.exclamationmark")
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.black)
            }
        }
        .accessibilityIdentifier("review-media-viewer")
    }

    private var controls: some View {
        VStack(spacing: 10) {
            Text("\(currentIndex + 1) of \(assets.count)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .accessibilityIdentifier("review-viewer-position")

            HStack(spacing: 14) {
                Button("Previous", systemImage: "chevron.left") {
                    goBack()
                }
                .labelStyle(.iconOnly)
                .disabled(currentIndex == 0)
                .accessibilityIdentifier("review-viewer-previous")

                Button {
                    if let currentAsset {
                        appModel.toggleReviewSelection(currentAsset.id)
                    }
                } label: {
                    Label(
                        isCurrentSelected ? "Selected for deletion" : "Select for deletion",
                        systemImage: isCurrentSelected ? "checkmark.circle.fill" : "circle"
                    )
                    .font(.headline)
                }
                .buttonStyle(.borderedProminent)
                .tint(isCurrentSelected ? RollSlashTheme.coral : .gray)
                .accessibilityIdentifier("review-viewer-toggle")
                .accessibilityLabel(isCurrentSelected ? "Selected for deletion" : "Kept item")
                .accessibilityHint(isCurrentSelected ? "Tap to keep this item." : "Tap to select this item for deletion.")

                Button("Next", systemImage: "chevron.right") {
                    advance()
                }
                .labelStyle(.iconOnly)
                .disabled(currentIndex >= assets.count - 1)
                .accessibilityIdentifier("review-viewer-next")
            }
            .font(.title3.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(.black.opacity(0.62), in: .capsule)
        }
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity)
    }

    private func advance() {
        guard currentIndex < assets.count - 1 else { return }
        withAnimation(.snappy) {
            currentIndex += 1
        }
    }

    private func goBack() {
        guard currentIndex > 0 else { return }
        withAnimation(.snappy) {
            currentIndex -= 1
        }
    }
}

private struct ReviewTile: View {
    let identifier: String
    let isSelected: Bool
    let toggle: () -> Void
    let preview: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: preview) {
                MediaThumbnailView(identifier: identifier, size: CGSize(width: 100, height: 100))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Preview photo")
            .accessibilityIdentifier("review-preview-\(identifier)")
            .accessibilityHint("Opens a full-screen preview. Swipe left for the next item or right for the previous item.")
            Button(action: toggle) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, isSelected ? RollSlashTheme.coral : .black.opacity(0.65))
                    .padding(7)
                    .background(.black.opacity(0.18), in: .circle)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isSelected ? "Selected item for deletion" : "Kept item")
            .accessibilityValue(isSelected ? "Selected" : "Not selected")
            .accessibilityHint("Tap to \(isSelected ? "keep" : "select for deletion").")
            .accessibilityIdentifier("review-selection-\(identifier)")
            .padding(4)
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(1, contentMode: .fit)
    }
}
