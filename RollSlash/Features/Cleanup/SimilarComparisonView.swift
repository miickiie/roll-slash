import SwiftUI

struct SimilarComparisonView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.displayScale) private var displayScale
    @State private var preview: ComparisonPreview?
    @State private var isSubmitting = false

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let tileWidth = max(1, (geometry.size.width - 32 - 12) / 2)
                let cacheRequest = ComparisonCacheRequest(
                    identifiers: Array(((appModel.currentComparison?.assetIDs ?? [])
                        + (appModel.currentComparison?.contextAssetIDs ?? [])).prefix(12)),
                    pixels: (tileWidth * displayScale).rounded(.up)
                )
                VStack(spacing: 0) {
                    ScrollView {
                        Text("Select the photos to delete. Unselected photos will be kept.")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true).padding()
                        if let unit = appModel.currentComparison {
                            LazyVGrid(columns: [GridItem(.flexible(minimum: 0), spacing: 12),
                                                GridItem(.flexible(minimum: 0), spacing: 12)], spacing: 12) {
                                ForEach(unit.assetIDs + unit.contextAssetIDs, id: \.self) { id in
                                    if let asset = appModel.assetIndex[id] {
                                        comparisonTile(asset, unit: unit, width: tileWidth)
                                    }
                                }
                            }
                            .padding(.horizontal)
                        }
                        if dynamicTypeSize.isAccessibilitySize { historyControls }
                    }
                    .accessibilityIdentifier("comparison-grid-scroll")
                    if !dynamicTypeSize.isAccessibilitySize { historyControls }
                    ProgressView(value: Double(appModel.sessionCompleted), total: Double(max(1, appModel.sessionTotal)))
                }
                .task(id: cacheRequest) {
                    guard !Task.isCancelled else { return }
                    appModel.preheatComparison(targetSize: CGSize(width: cacheRequest.pixels, height: cacheRequest.pixels))
                }
            }
            .navigationTitle("Similar Photos")
            .navigationBarTitleDisplayMode(dynamicTypeSize.isAccessibilitySize ? .inline : .large)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { appModel.route = .dashboard }
                        .disabled(isSubmitting)
                        .accessibilityHint("Pauses this session. Your progress stays on the dashboard.")
                }
            }
            .safeAreaInset(edge: .bottom) {
                let layout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 8))
                layout {
                    Button("Keep All") { submit { await appModel.confirmComparison(keepAll: true) } }
                        .buttonStyle(.bordered)
                        .tint(RollSlashTheme.keep)
                        .accessibilityIdentifier("comparison-keep-all")
                        .frame(maxWidth: .infinity)
                    Button("Confirm Choices") { submit { await appModel.confirmComparison() } }
                        .buttonStyle(.borderedProminent)
                        .tint(RollSlashTheme.violet)
                        .accessibilityIdentifier("comparison-confirm")
                        .frame(maxWidth: .infinity)
                }
                .font(.headline)
                .buttonBorderShape(.roundedRectangle)
                .frame(maxWidth: .infinity).padding().background(.ultraThinMaterial)
                .disabled(isSubmitting)
            }
            .fullScreenCover(item: $preview) { preview in
                SimilarComparisonPreview(initialIdentifier: preview.id, unit: preview.unit, onDismiss: closePreview)
            }
            .alert("Roll Slash", isPresented: Binding(
                get: { appModel.errorMessage != nil },
                set: { if !$0 { appModel.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { appModel.errorMessage = nil }
            } message: { Text(appModel.errorMessage ?? "") }
        }
        .visibleSystemStatusBar()
        .sensoryFeedback(.selection, trigger: appModel.comparisonDeleteIDs)
    }

    private var historyControls: some View {
        HStack {
            Button { appModel.undo() } label: {
                if dynamicTypeSize.isAccessibilitySize { Image(systemName: "arrow.uturn.backward") }
                else { Label("Undo", systemImage: "arrow.uturn.backward") }
            }
            .disabled(!appModel.canUndo || isSubmitting)
            .accessibilityLabel("Undo").accessibilityIdentifier("comparison-undo")
            Spacer()
            Text("\(appModel.sessionRemaining) left").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button { submit { await appModel.redo() } } label: {
                if dynamicTypeSize.isAccessibilitySize { Image(systemName: "arrow.uturn.forward") }
                else { Label("Redo", systemImage: "arrow.uturn.forward") }
            }
            .disabled(!appModel.canRedo || isSubmitting)
            .accessibilityLabel("Redo").accessibilityIdentifier("comparison-redo")
        }
        .padding()
    }

    private func comparisonTile(_ asset: PhotoAssetDescriptor, unit: CleanupWorkUnit, width: CGFloat) -> some View {
        let selected = appModel.comparisonDeleteIDs.contains(asset.id)
        return VStack(spacing: 8) {
            Button { preview = ComparisonPreview(id: asset.id, unit: unit) } label: {
                ComparisonPhotoImage(asset: asset, width: width)
                    .frame(width: width, height: width)
                    .clipped().clipShape(.rect(cornerRadius: 16))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Inspect photo")
            .accessibilityIdentifier("comparison-preview-\(asset.id)")
            if unit.assetIDs.contains(asset.id) {
                Button { appModel.toggleComparisonDeletion(asset.id) } label: {
                    Group {
                        if dynamicTypeSize.isAccessibilitySize {
                            VStack(spacing: 6) {
                                Image(systemName: selected ? "checkmark.circle.fill" : "circle").font(.title3)
                                Text(selected ? "Selected to delete" : "Select to delete").font(.caption)
                            }
                        } else {
                            Label(selected ? "Selected to delete" : "Select to delete", systemImage: selected ? "checkmark.circle.fill" : "circle")
                                .font(.subheadline)
                        }
                    }
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(RollSlashTheme.coral)
                .disabled(isSubmitting)
                .accessibilityLabel(selected ? "Selected to delete" : "Select to delete")
                .accessibilityIdentifier("comparison-delete-\(asset.id)")
                .accessibilityValue(selected ? "Selected to delete" : "Not selected to delete")
            } else {
                Text(ComparisonContextCopy.label(for: appModel.decisionsByAssetID[asset.id]))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(width: width)
    }

    private func closePreview() {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { preview = nil }
    }

    private func submit(_ operation: @escaping @MainActor () async -> Void) {
        guard !isSubmitting else { return }
        isSubmitting = true
        Task { await operation(); isSubmitting = false }
    }
}

enum ComparisonContextCopy {
    static func label(for decision: AssetDecision?) -> String {
        switch decision {
        case .deletePending: String(localized: "Previously marked to delete")
        case .keep: String(localized: "Previously kept")
        case nil: String(localized: "Not in this cleanup")
        }
    }
}

private struct ComparisonPreview: Identifiable {
    let id: String
    let unit: CleanupWorkUnit
}

private struct ComparisonCacheRequest: Hashable {
    let identifiers: [String]
    let pixels: CGFloat
}

private struct ComparisonPhotoImage: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.displayScale) private var displayScale
    let asset: PhotoAssetDescriptor
    let width: CGFloat
    @State private var image: UIImage?
    @State private var loaded = false

    private struct Request: Hashable {
        let id: String
        let modificationDate: Date?
        let pixels: CGFloat
    }

    var body: some View {
        let request = Request(id: asset.id, modificationDate: asset.modificationDate,
                              pixels: (width * displayScale).rounded(.up))
        ZStack {
            Color(uiColor: .secondarySystemGroupedBackground)
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
                    .frame(width: width, height: width)
            } else if loaded {
                Label("In iCloud — open to load", systemImage: "icloud.and.arrow.down")
                    .font(.caption).foregroundStyle(.secondary).padding(8)
            } else {
                ProgressView()
            }
        }
        .task(id: request) {
            loaded = false
            let result = await appModel.previewProvider.image(
                for: request.id, targetSize: CGSize(width: request.pixels, height: request.pixels), kind: .comparison
            )
            guard !Task.isCancelled else { return }
            image = result
            loaded = true
        }
        .accessibilityHidden(true)
    }
}

private struct SimilarComparisonPreview: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let unit: CleanupWorkUnit
    let onDismiss: () -> Void
    @State private var currentIdentifier: String
    @State private var exitOffset = CGSize.zero
    @State private var exitOpacity = 1.0
    @State private var isDismissing = false

    init(initialIdentifier: String, unit: CleanupWorkUnit, onDismiss: @escaping () -> Void) {
        self.unit = unit
        self.onDismiss = onDismiss
        _currentIdentifier = State(initialValue: initialIdentifier)
    }

    private var sequence: ComparisonPreviewSequence { ComparisonPreviewSequence(unit: unit) }
    private var accessible: Set<String> {
        guard let current = appModel.currentComparison else { return [] }
        let available = Set((unit.assetIDs + unit.contextAssetIDs).filter { appModel.assetIndex[$0] != nil })
        return sequence.accessibleIdentifiers(in: available, currentUnit: current)
    }
    private var identifiers: [String] { sequence.identifiers(accessible: accessible) }

    var body: some View {
        GeometryReader { geometry in
            let viewportHeight = geometry.size.height + geometry.safeAreaInsets.top + geometry.safeAreaInsets.bottom
            Group {
                if let asset = appModel.assetIndex[currentIdentifier],
                   let index = identifiers.firstIndex(of: currentIdentifier) {
                    MediaViewer(asset: asset, loadsFullResolution: true,
                                onSwipeLeft: { navigate(1) }, onSwipeRight: { navigate(-1) },
                                onDismissSwipe: { dismissPreview(toward: $0, viewportHeight: viewportHeight) },
                                dismissSwipeAxis: .vertical,
                                onClose: { dismissPreview(toward: CGSize(width: 0, height: 100), viewportHeight: viewportHeight) })
                        .id(currentIdentifier)
                        .safeAreaInset(edge: .bottom, spacing: 0) { controls(index: index) }
                } else {
                    Color.black.ignoresSafeArea()
                }
            }
            .offset(exitOffset)
            .opacity(exitOpacity)
            .allowsHitTesting(!isDismissing)
        }
        .presentationBackground(.clear)
        .interactiveDismissDisabled()
        .preferredColorScheme(.dark)
        .visibleSystemStatusBar()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("comparison-media-viewer")
        .onAppear { reconcile() }
        .onChange(of: identifiers) { _, _ in reconcile() }
        .onChange(of: appModel.currentComparison) { _, current in
            guard let current, current.clusterID == unit.clusterID else { onDismiss(); return }
            reconcile()
        }
        .alert("Roll Slash", isPresented: Binding(
            get: { appModel.errorMessage != nil },
            set: { if !$0 { appModel.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { appModel.errorMessage = nil }
        } message: { Text(appModel.errorMessage ?? "") }
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

    private func controls(index: Int) -> some View {
        let editable = appModel.currentComparison?.assetIDs.contains(currentIdentifier) == true
        let selected = appModel.comparisonDeleteIDs.contains(currentIdentifier)
        return VStack(spacing: 10) {
            Text("\(index + 1) of \(identifiers.count)")
                .font(.subheadline.weight(.semibold))
                .accessibilityIdentifier("comparison-viewer-position")
            HStack(spacing: 12) {
                Button("Previous", systemImage: "chevron.left") { navigate(-1) }
                    .labelStyle(.iconOnly).disabled(index == 0)
                    .accessibilityIdentifier("comparison-viewer-previous")
                if editable {
                    Button { appModel.toggleComparisonDeletion(currentIdentifier) } label: {
                        Label(selected ? "Selected to delete" : "Select to delete",
                              systemImage: selected ? "checkmark.circle.fill" : "circle")
                            .font(.headline).multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .buttonStyle(.borderedProminent).tint(selected ? RollSlashTheme.coral : .gray)
                    .accessibilityIdentifier("comparison-viewer-toggle")
                    .accessibilityValue(selected ? "Selected to delete" : "Not selected to delete")
                    .accessibilityHint("Saves this choice for Confirm Choices. No photo is deleted yet.")
                } else {
                    Text(ComparisonContextCopy.label(for: appModel.decisionsByAssetID[currentIdentifier]))
                        .font(.subheadline).multilineTextAlignment(.center)
                        .accessibilityIdentifier("comparison-viewer-read-only")
                }
                Button("Next", systemImage: "chevron.right") { navigate(1) }
                    .labelStyle(.iconOnly).disabled(index == identifiers.count - 1)
                    .accessibilityIdentifier("comparison-viewer-next")
            }
            .font(.title3.weight(.semibold))
        }
        .foregroundStyle(.white).padding().frame(maxWidth: .infinity)
        .background(.black.opacity(0.9))
    }

    private func navigate(_ step: Int) {
        if let next = sequence.neighbor(of: currentIdentifier, step: step, accessible: accessible) {
            currentIdentifier = next
        }
    }

    private func reconcile() {
        guard appModel.currentComparison != nil,
              let next = sequence.replacement(for: currentIdentifier, accessible: accessible) else {
            onDismiss()
            return
        }
        currentIdentifier = next
    }
}
