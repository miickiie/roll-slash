import SwiftUI

struct ReviewView: View {
    @Environment(AppModel.self) private var appModel
    @State private var focusedIdentifier: String?

    private let columns = [GridItem(.adaptive(minimum: 105), spacing: 3)]

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
        ZStack(alignment: .topTrailing) {
            Button(action: preview) {
                MediaThumbnailView(identifier: identifier, size: CGSize(width: 180, height: 180))
                    .aspectRatio(1, contentMode: .fill)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Preview item")
            Button(action: toggle) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, isSelected ? RollSlashTheme.coral : .black.opacity(0.5))
                    .padding(7)
            }
            .accessibilityLabel(isSelected ? "Keep this item" : "Select this item for deletion")
        }
    }
}
