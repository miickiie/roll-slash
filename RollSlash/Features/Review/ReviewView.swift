import SwiftUI

struct ReviewView: View {
    @Environment(AppModel.self) private var appModel
    @State private var focusedPreview: PreviewIdentifier?

    private let columns = Array(repeating: GridItem(.flexible(minimum: 0), spacing: 4), count: 4)

    private var allCandidatesSelected: Bool {
        let candidates = Set(appModel.reviewCandidateIDs)
        return !candidates.isEmpty && candidates.isSubset(of: appModel.reviewSelectedIDs)
    }

    private var selectAllBinding: Binding<Bool> {
        Binding(
            get: { allCandidatesSelected },
            set: { newValue in
                if newValue {
                    appModel.selectAllForDeletion()
                } else {
                    appModel.keepAllFromReview()
                }
            }
        )
    }

    var body: some View {
        let candidateIDs = appModel.reviewCandidateIDs
        let selectedIDs = appModel.reviewSelectedIDs
        let allSelected = !candidateIDs.isEmpty && Set(candidateIDs).isSubset(of: selectedIDs)
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    Text("\(selectedIDs.count) selected for deletion")
                        .font(.subheadline.bold())
                    Spacer()
                    Toggle(isOn: selectAllBinding) {
                        Label(
                            "Select All",
                            systemImage: allSelected ? "checkmark.circle.fill" : "checkmark.circle"
                        )
                    }
                    .toggleStyle(.button)
                    .buttonStyle(.bordered)
                    .disabled(candidateIDs.isEmpty)
                    .accessibilityIdentifier("select-all")
                    .accessibilityHint(
                        allSelected
                            ? "Keeps every item in this review."
                            : "Selects every item in this review for deletion."
                    )
                }
                .padding()

                ScrollView {
                    LazyVGrid(columns: columns, spacing: 3) {
                        ForEach(candidateIDs, id: \.self) { identifier in
                            ReviewTile(
                                identifier: identifier,
                                isSelected: selectedIDs.contains(identifier)
                            ) {
                                appModel.toggleReviewSelection(identifier)
                            } preview: { image in
                                focusedPreview = PreviewIdentifier(id: identifier, image: image)
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
                        Text(selectedIDs.isEmpty
                             ? (appModel.sessionRemaining > 0 ? "Finish this batch" : "Finish without deleting")
                             : "Delete \(selectedIDs.count) items")
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                }
                .buttonStyle(.borderedProminent)
                .tint(selectedIDs.isEmpty ? RollSlashTheme.violet : RollSlashTheme.coral)
                .disabled(!appModel.canEditReview)
                .accessibilityIdentifier("commit-deletion")
                .padding()
                .background(.ultraThinMaterial)
            }
            .fullScreenCover(item: $focusedPreview) { item in
                ReviewMediaViewer(initialIdentifier: item.id, initialImage: item.image) {
                    var transaction = Transaction(animation: nil)
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { focusedPreview = nil }
                }
            }
            .disabled(!appModel.canEditReview)
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
    let image: UIImage?
}

private struct ReviewMediaViewer: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let initialIdentifier: String
    let initialImage: UIImage?
    let onDismiss: () -> Void
    @State private var currentIdentifier: String
    @State private var exitOffset = CGSize.zero
    @State private var exitOpacity = 1.0
    @State private var isDismissing = false

    init(initialIdentifier: String, initialImage: UIImage?, onDismiss: @escaping () -> Void) {
        self.initialIdentifier = initialIdentifier
        self.initialImage = initialImage
        self.onDismiss = onDismiss
        _currentIdentifier = State(initialValue: initialIdentifier)
    }

    private var assets: [PhotoAssetDescriptor] {
        appModel.reviewCandidateAssets
    }

    private var currentIndex: Int? {
        assets.firstIndex { $0.id == currentIdentifier }
    }

    private var currentAsset: PhotoAssetDescriptor? {
        guard let currentIndex, assets.indices.contains(currentIndex) else { return nil }
        return assets[currentIndex]
    }

    private var isCurrentSelected: Bool {
        guard let currentAsset else { return false }
        return appModel.reviewSelectedIDs.contains(currentAsset.id)
    }

    var body: some View {
        GeometryReader { geometry in
            let viewportHeight = geometry.size.height + geometry.safeAreaInsets.top + geometry.safeAreaInsets.bottom
            Group {
                if let currentAsset, let currentIndex {
                    MediaViewer(
                        asset: currentAsset,
                        initialImage: currentIdentifier == initialIdentifier ? initialImage : nil,
                        onSwipeLeft: advance,
                        onSwipeRight: goBack,
                        onDismissSwipe: { dismissPreview(toward: $0, viewportHeight: viewportHeight) },
                        dismissSwipeAxis: .vertical,
                        onClose: { dismissPreview(toward: CGSize(width: 0, height: 100), viewportHeight: viewportHeight) }
                    )
                    .overlay(alignment: .bottom) {
                        controls(currentIndex: currentIndex)
                    }
                } else {
                    VStack(spacing: 16) {
                        ContentUnavailableView("Item unavailable", systemImage: "photo.badge.exclamationmark")
                        Button("Close", action: onDismiss)
                            .buttonStyle(.borderedProminent)
                    }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.black)
                }
            }
            .offset(exitOffset)
            .opacity(exitOpacity)
            .allowsHitTesting(!isDismissing)
        }
        .presentationBackground(.clear)
        .interactiveDismissDisabled()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("review-media-viewer")
        .preferredColorScheme(.dark)
        .visibleSystemStatusBar()
        .onAppear { reconcileCurrentAsset() }
        .onChange(of: appModel.reviewCandidateIDs) { _, _ in
            reconcileCurrentAsset()
        }
    }

    private func dismissPreview(toward translation: CGSize, viewportHeight: CGFloat) {
        guard !isDismissing else { return }
        isDismissing = true
        guard !reduceMotion else { onDismiss(); return }
        let direction: CGFloat = translation.height < 0 ? -1 : 1
        withAnimation(.easeOut(duration: 0.24)) {
            exitOffset.height = direction * (viewportHeight + abs(translation.height) + 80)
            exitOpacity = 0
        } completion: {
            onDismiss()
        }
    }

    private func controls(currentIndex: Int) -> some View {
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
        guard let currentIndex, currentIndex < assets.count - 1 else { return }
        withAnimation(.snappy) {
            self.currentIdentifier = assets[currentIndex + 1].id
        }
    }

    private func goBack() {
        guard let currentIndex, currentIndex > 0 else { return }
        withAnimation(.snappy) {
            self.currentIdentifier = assets[currentIndex - 1].id
        }
    }

    private func reconcileCurrentAsset() {
        guard !assets.isEmpty else {
            onDismiss()
            return
        }
        guard !assets.contains(where: { $0.id == currentIdentifier }) else { return }
        currentIdentifier = assets.first?.id ?? initialIdentifier
    }
}

private struct ReviewTile: View {
    private let tileHeight: CGFloat = 96

    let identifier: String
    let isSelected: Bool
    let toggle: () -> Void
    let preview: (UIImage?) -> Void
    @State private var thumbnailImage: UIImage?

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topTrailing) {
                Button { preview(thumbnailImage) } label: {
                    MediaThumbnailView(
                        identifier: identifier,
                        size: CGSize(width: 140, height: 96),
                        onImageLoaded: { thumbnailImage = $0 }
                    )
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipShape(.rect(cornerRadius: 8))
                .accessibilityLabel("Preview photo")
                .accessibilityIdentifier("review-preview-\(identifier)")
                .accessibilityHint("Opens a full-screen preview. Swipe left for the next item, right for the previous item, or up or down to close.")
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
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .frame(height: tileHeight)
    }
}
