import SwiftUI

struct DashboardView: View {
    @Environment(AppModel.self) private var appModel
    @State private var mascotActionID = 0

    var body: some View {
        @Bindable var appModel = appModel
        NavigationStack {
            ZStack(alignment: .bottom) {
                Color(.systemGroupedBackground).ignoresSafeArea()
                content
            }
            .navigationTitle("")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "gearshape") {
                        appModel.showingSettings = true
                    }
                }
            }
            .sheet(isPresented: $appModel.showingSettings) {
                SettingsView()
            }
            .alert("Roll Slash", isPresented: Binding(
                get: { appModel.errorMessage != nil },
                set: { if !$0 { appModel.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { appModel.errorMessage = nil }
            } message: {
                Text(appModel.errorMessage ?? "")
            }
            .onChange(of: appModel.grouping) { _, _ in mascotDidMove() }
            .onChange(of: appModel.selectedGroupIDs) { _, _ in mascotDidMove() }
            .onChange(of: appModel.route) { _, _ in mascotDidMove() }
            .onChange(of: appModel.showingSettings) { _, _ in mascotDidMove() }
        }
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 0) {
            DashboardHeader(actionID: mascotActionID)
            if !appModel.permission.canRead {
                PermissionEmptyState()
            } else {
                if appModel.isPartialAccess { LimitedAccessBanner() }
                if appModel.activeSession != nil { ResumeBanner() }
                Picker("Grouping", selection: Binding(
                    get: { appModel.grouping },
                    set: { appModel.grouping = $0 }
                )) {
                    ForEach(GroupKind.allCases, id: \.self) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 10)

                if appModel.isLoading && appModel.assets.isEmpty {
                    Spacer()
                    ProgressView("Reading your library…")
                    Spacer()
                } else if appModel.visibleGroups.isEmpty {
                    ContentUnavailableView(
                        "Nothing to clean",
                        systemImage: "sparkles",
                        description: Text("Accessible photos and videos will appear here.")
                    )
                } else {
                    GroupList(onInteraction: mascotDidMove)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !appModel.selectedGroupIDs.isEmpty {
                Button {
                    mascotDidMove()
                    appModel.beginSelectedCleanup()
                } label: {
                    VStack(spacing: 2) {
                        Text("Clean \(appModel.selectedGroupIDs.count) groups")
                            .font(.headline)
                        Text("\(appModel.selectedCandidateCount) items to review")
                            .font(.caption)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
                .tint(RollSlashTheme.violet)
                .disabled(appModel.selectedUnresolvedCount == 0)
                .accessibilityIdentifier("clean-selected")
                .padding()
            }
        }
    }

    private func mascotDidMove() {
        mascotActionID &+= 1
    }
}

private struct DashboardHeader: View {
    let actionID: Int

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("Roll Slash")
                .font(.largeTitle.bold())
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("dashboard-title")
            RollSlashMascot(actionID: actionID)
            Spacer(minLength: 0)
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }
}

private struct RollSlashMascot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let actionID: Int
    @State private var isBobbing = false
    @State private var isSlashing = false

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [RollSlashTheme.violet.opacity(0.95), RollSlashTheme.coral.opacity(0.9)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            CatHeadAndPaw(isBobbing: isBobbing, isSlashing: isSlashing)
            Duster(isSlashing: isSlashing)
        }
        .frame(width: 36, height: 36)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Roll Slash mascot, cat with an animated paw and feather duster")
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                isBobbing = true
            }
        }
        .onChange(of: actionID) { _, _ in
            guard !reduceMotion else { return }
            withAnimation(.spring(response: 0.2, dampingFraction: 0.55)) {
                isSlashing.toggle()
            }
        }
    }
}

private struct CatHeadAndPaw: View {
    let isBobbing: Bool
    let isSlashing: Bool

    var body: some View {
        ZStack {
            Path { path in
                path.move(to: CGPoint(x: 7, y: 10))
                path.addLine(to: CGPoint(x: 9, y: 3))
                path.addLine(to: CGPoint(x: 14, y: 8))
                path.closeSubpath()
            }
            .fill(.yellow)
            .offset(x: -3, y: isBobbing ? -1 : 1)
            Path { path in
                path.move(to: CGPoint(x: 17, y: 8))
                path.addLine(to: CGPoint(x: 22, y: 3))
                path.addLine(to: CGPoint(x: 24, y: 11))
                path.closeSubpath()
            }
            .fill(.yellow)
            .offset(x: -3, y: isBobbing ? -1 : 1)
            Capsule()
                .fill(.yellow)
                .frame(width: 18, height: 15)
                .overlay {
                    HStack(spacing: 5) {
                        Circle().fill(.black).frame(width: 2, height: 2)
                        Circle().fill(.black).frame(width: 2, height: 2)
                    }
                    .offset(y: -1)
                }
                .overlay(alignment: .bottom) {
                    Capsule()
                        .fill(.pink.opacity(0.9))
                        .frame(width: 4, height: 2)
                        .offset(y: -3)
                }
                .offset(x: -5, y: isBobbing ? -3 : -1)
            Image(systemName: "pawprint.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.orange)
                .rotationEffect(.degrees(isSlashing ? -35 : -12))
                .offset(x: 5, y: isSlashing ? 4 : 7)
        }
    }
}

private struct Duster: View {
    let isSlashing: Bool

    var body: some View {
        VStack(spacing: -3) {
            HStack(spacing: -3) {
                Capsule().fill(.mint).frame(width: 5, height: 10).rotationEffect(.degrees(-20))
                Capsule().fill(.mint).frame(width: 5, height: 12)
                Capsule().fill(.mint).frame(width: 5, height: 10).rotationEffect(.degrees(20))
            }
            Capsule()
                .fill(.white.opacity(0.9))
                .frame(width: 3, height: 10)
        }
        .rotationEffect(.degrees(isSlashing ? -48 : -18))
        .offset(x: isSlashing ? 8 : 5, y: isSlashing ? -3 : 4)
    }
}

private struct PermissionEmptyState: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        ContentUnavailableView {
            Label("Photo access needed", systemImage: "photo.badge.exclamationmark")
        } description: {
            Text("Roll Slash can only group and clean media you allow it to see.")
        } actions: {
            if appModel.permission == .notDetermined {
                Button("Choose Photo Access") { Task { await appModel.requestAccess() } }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Open Settings") { appModel.openSystemSettings() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

private struct LimitedAccessBanner: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "circle.lefthalf.filled")
            VStack(alignment: .leading, spacing: 2) {
                Text("Showing selected photos only").font(.subheadline.bold())
                Text("Counts do not include your full library.").font(.caption)
            }
            Spacer()
            Button("Manage") { appModel.presentLimitedLibraryPicker() }
                .buttonStyle(.bordered)
        }
        .padding(12)
        .background(.orange.opacity(0.16), in: .rect(cornerRadius: 14))
        .padding(.horizontal)
    }
}

private struct ResumeBanner: View {
    @Environment(AppModel.self) private var appModel
    @State private var showingDiscardConfirmation = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(appModel.activeSession?.status == .deleting ? "Deletion needs verification" : "Cleanup in progress")
                    .font(.headline)
                Text(appModel.activeSession?.status == .deleting ? "Full Photo Access is required to reconcile the result." : "\(appModel.sessionRemaining) items remaining")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if appModel.activeSession?.status == .deleting {
                Button("Manage Access") { appModel.openSystemSettings() }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Discard", role: .destructive) { showingDiscardConfirmation = true }
                    .fullScreenCover(isPresented: $showingDiscardConfirmation) {
                        PopupModal {
                            discardConfirmation
                        }
                    }
                Button("Resume") { appModel.resumeSession() }.buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .background(.thinMaterial)
    }

    private var discardConfirmation: some View {
            VStack(alignment: .leading, spacing: 14) {
                Text("Discard the current cleanup?")
                    .font(.headline)
                Text("Changes from this unfinished session will be discarded and prior review choices restored. Your Photos library will not change.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                PopupActionRow {
                    Button("Keep Session") { showingDiscardConfirmation = false }
                        .buttonStyle(.bordered)
                } confirm: {
                    Button("Discard Session", role: .destructive) {
                        showingDiscardConfirmation = false
                        appModel.discardActiveSession()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(RollSlashTheme.coral)
                }
            }
    }
}

private struct GroupList: View {
    @Environment(AppModel.self) private var appModel
    let onInteraction: () -> Void
    @State private var dragStarted = false

    var body: some View {
        if appModel.grouping == .month {
            MonthGroupList(onInteraction: onInteraction)
        } else {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(appModel.locationGroups) { group in GroupRow(group: group) }
                }
                .padding(.horizontal)
                .padding(.bottom, 120)
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { _ in
                        guard !dragStarted else { return }
                        dragStarted = true
                        onInteraction()
                    }
                    .onEnded { _ in dragStarted = false }
            )
        }
    }
}

private struct MonthGroupList: View {
    @Environment(AppModel.self) private var appModel
    let onInteraction: () -> Void
    @State private var dragStarted = false
    private let columns = [
        GridItem(.flexible(minimum: 0), spacing: 12, alignment: .top),
        GridItem(.flexible(minimum: 0), spacing: 12, alignment: .top)
    ]
    private let singleColumn = [GridItem(.flexible(minimum: 0), alignment: .top)]

    private var sections: [(String, [MediaGroup])] {
        let grouped = Dictionary(grouping: appModel.monthGroups) { MonthGrouping.year(for: $0.key.value) ?? String(localized: "Other") }
        return grouped.map { ($0.key, $0.value) }.sorted {
            if $0.0 == String(localized: "Other") { return false }
            if $1.0 == String(localized: "Other") { return true }
            return $0.0 > $1.0
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .trailing) {
                ScrollView {
                    LazyVStack(alignment: .leading, pinnedViews: [.sectionHeaders]) {
                        ForEach(sections, id: \.0) { year, groups in
                            Section {
                                LazyVGrid(columns: groups.count == 1 ? singleColumn : columns, spacing: 12) {
                                    ForEach(groups) { group in
                                        MonthGroupCard(group: group)
                                    }
                                }
                            } header: {
                                Text(year)
                                    .font(.title2.bold())
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 6)
                                    .background(Color(.systemGroupedBackground))
                                    .id(year)
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.trailing, 40)
                    .padding(.bottom, 120)
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 8)
                        .onChanged { _ in
                            guard !dragStarted else { return }
                            dragStarted = true
                            onInteraction()
                        }
                        .onEnded { _ in dragStarted = false }
                )
                VStack(spacing: 8) {
                    ForEach(sections, id: \.0) { year, _ in
                        Button(year) {
                            onInteraction()
                            withAnimation { proxy.scrollTo(year, anchor: .top) }
                        }
                        .font(.caption2.bold())
                        .foregroundStyle(RollSlashTheme.violet)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(.rect)
                        .accessibilityLabel("Jump to \(year)")
                    }
                }
                .padding(.trailing, 4)
            }
        }
    }
}

private struct MonthGroupCard: View {
    @Environment(AppModel.self) private var appModel
    @State private var showingReviewAgainConfirmation = false
    let group: MediaGroup

    private var selected: Bool { appModel.selectedGroupIDs.contains(group.id) }

    var body: some View {
        Button {
            if group.isCleaned && !selected {
                showingReviewAgainConfirmation = true
            } else {
                appModel.toggleSelection(group)
            }
        } label: {
            VStack(alignment: .leading, spacing: 9) {
                MediaThumbnailView(identifier: group.thumbnailAssetID, size: CGSize(width: 180, height: 100))
                    .frame(maxWidth: .infinity)
                    .frame(height: 92)
                    .clipShape(.rect(cornerRadius: 16))
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(group.title)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if let subtitle = group.subtitle {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: selected
                          ? "checkmark.circle.fill"
                          : (group.isCleaned ? "checkmark.seal.fill" : "circle"))
                        .font(.title3)
                        .foregroundStyle(selected ? RollSlashTheme.violet : (group.isCleaned ? RollSlashTheme.keep : .secondary))
                        .accessibilityLabel(group.isCleaned ? "Cleaned" : (selected ? "Selected" : "Not selected"))
                }
                if group.totalCount > 0 {
                    ProgressView(value: Double(group.reviewedCount), total: Double(group.totalCount))
                        .tint(group.isCleaned ? RollSlashTheme.keep : RollSlashTheme.violet)
                }
            }
            .padding(10)
            .background(.background, in: .rect(cornerRadius: 20))
            .overlay {
                RoundedRectangle(cornerRadius: 20)
                    .stroke(selected ? RollSlashTheme.violet : .clear, lineWidth: 2)
            }
        }
        .buttonStyle(.plain)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .top)
        .disabled(group.totalCount == 0)
        .accessibilityIdentifier("group-row-\(group.key.id)")
        .accessibilityValue(group.isCleaned ? (selected ? "Cleaned, selected to review again" : "Cleaned") : "\(group.unresolvedCount) left to review")
        .fullScreenCover(isPresented: $showingReviewAgainConfirmation) {
            PopupModal {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Review \(group.title) again?")
                        .font(.headline)
                    Text("All \(group.totalCount) accessible items in this group will be added to a new swipe session. Nothing is deleted until final review.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    PopupActionRow {
                        Button("Not Now") { showingReviewAgainConfirmation = false }
                            .buttonStyle(.bordered)
                    } confirm: {
                        Button("Review Again") {
                            showingReviewAgainConfirmation = false
                            appModel.toggleSelection(group)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
    }
}

private struct GroupRow: View {
    @Environment(AppModel.self) private var appModel
    @State private var showingReviewAgainConfirmation = false
    let group: MediaGroup

    private var selected: Bool { appModel.selectedGroupIDs.contains(group.id) }

    var body: some View {
        Button {
            if group.isCleaned && !selected {
                showingReviewAgainConfirmation = true
            } else {
                appModel.toggleSelection(group)
            }
        } label: {
            HStack(spacing: 14) {
                MediaThumbnailView(identifier: group.thumbnailAssetID, size: CGSize(width: 72, height: 72))
                    .frame(width: 72, height: 72)
                    .clipShape(.rect(cornerRadius: 18))
                VStack(alignment: .leading, spacing: 5) {
                    Text(group.title).font(.headline).foregroundStyle(.primary)
                    if let subtitle = group.subtitle {
                        Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if group.totalCount > 0 {
                        ProgressView(value: Double(group.reviewedCount), total: Double(group.totalCount))
                            .tint(group.isCleaned ? RollSlashTheme.keep : RollSlashTheme.violet)
                    }
                }
                Spacer()
                Image(systemName: selected
                      ? "checkmark.circle.fill"
                      : (group.isCleaned ? "checkmark.seal.fill" : "circle"))
                    .font(.title2)
                    .foregroundStyle(selected ? RollSlashTheme.violet : (group.isCleaned ? RollSlashTheme.keep : .secondary))
                    .accessibilityLabel(group.isCleaned ? "Cleaned" : (selected ? "Selected" : "Not selected"))
            }
            .padding(12)
            .background(.background, in: .rect(cornerRadius: 22))
            .overlay {
                RoundedRectangle(cornerRadius: 22)
                    .stroke(selected ? RollSlashTheme.violet : .clear, lineWidth: 2)
            }
        }
        .buttonStyle(.plain)
        .disabled(group.totalCount == 0)
        .accessibilityIdentifier("group-row-\(group.key.id)")
        .accessibilityValue(group.isCleaned ? (selected ? "Cleaned, selected to review again" : "Cleaned") : "\(group.unresolvedCount) left to review")
        .fullScreenCover(isPresented: $showingReviewAgainConfirmation) {
            PopupModal {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Review \(group.title) again?")
                        .font(.headline)
                    Text("All \(group.totalCount) accessible items in this group will be added to a new swipe session. Nothing is deleted until final review.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    PopupActionRow {
                        Button("Cancel") { showingReviewAgainConfirmation = false }
                            .buttonStyle(.bordered)
                    } confirm: {
                        Button("Review Again") {
                            showingReviewAgainConfirmation = false
                            appModel.toggleSelection(group)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
    }
}
