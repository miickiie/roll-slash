import SwiftUI

struct ReviewView: View {
    @Environment(AppModel.self) private var appModel
    @State private var focusedIdentifier: String?

    private let columns = [GridItem(.adaptive(minimum: 78, maximum: 105), spacing: 3)]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    Text("\(appModel.reviewSelectedIDs.count) selected for deletion")
                        .font(.subheadline.bold())
                    Spacer()
                    Menu("Selection", systemImage: "checkmark.circle") {
                        Button("Select All") { appModel.selectAllForDeletion() }
                        Button("Keep All") { appModel.keepAllFromReview() }
                    }
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
    if let asset = appModel.assets.first(where: { $0.id == item.id }) {
        MediaViewer(asset: asset)
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

private struct ReviewTile: View {
    let identifier: String
    let isSelected: Bool
    let toggle: () -> Void
    let preview: () -> Void

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Button(action: toggle) {
                ZStack(alignment: .topTrailing) {
                    MediaThumbnailView(identifier: identifier, size: CGSize(width: 100, height: 100))
                        .frame(maxWidth: .infinity)
                        .aspectRatio(1, contentMode: .fill)
                        .clipped()
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, isSelected ? RollSlashTheme.coral : .black.opacity(0.5))
                        .padding(7)
                        .allowsHitTesting(false)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .aspectRatio(1, contentMode: .fit)
            .accessibilityLabel(isSelected ? "Selected item for deletion" : "Kept item")
            .accessibilityValue(isSelected ? "Selected" : "Not selected")
            .accessibilityHint("Tap to \(isSelected ? "keep" : "select for deletion"); use the expand button to preview.")
            .accessibilityAction(named: isSelected ? "Keep" : "Select for deletion") {
                toggle()
            }
            Button(action: preview) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(.black.opacity(0.55), in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Preview item full screen")
            .accessibilityIdentifier("preview-item-\(identifier)")
            .padding(6)
        }
    }
}
