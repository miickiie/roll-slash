import SwiftUI

struct DashboardScrollMemory {
    var monthID: String?
    var locationID: String?
    var monthAnchorID: String?
    var locationAnchorID: String?
    var monthOrder: [String] = []
    var locationOrder: [String] = []

    mutating func reconcileMonth(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        let anchor = monthAnchorID ?? monthID
        let resolved: String?
        if let anchor, !ids.contains(anchor),
           let target = Self.monthOrdinal(anchor),
           let nearest = ids.compactMap({ id -> (String, Int)? in
               guard let ordinal = Self.monthOrdinal(id) else { return nil }
               return (id, ordinal)
           }).min(by: { abs($0.1 - target) < abs($1.1 - target) })?.0 {
            resolved = nearest
        } else {
            resolved = Self.validAnchor(anchor, previous: monthOrder, current: ids)
        }
        monthAnchorID = resolved
        monthID = resolved
        monthOrder = ids
    }

    mutating func reconcileLocation(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        let resolved = Self.validAnchor(locationAnchorID ?? locationID, previous: locationOrder, current: ids)
        locationAnchorID = resolved
        locationID = resolved
        locationOrder = ids
    }

    private static func validAnchor(_ anchor: String?, previous: [String], current: [String]) -> String? {
        guard let anchor else { return nil }
        guard !current.contains(anchor) else { return anchor }
        guard !current.isEmpty else { return nil }
        guard let priorIndex = previous.firstIndex(of: anchor) else { return current.first }
        let remaining = Set(current)
        return previous.enumerated()
            .filter { remaining.contains($0.element) }
            .min {
                let firstDistance = abs($0.offset - priorIndex)
                let secondDistance = abs($1.offset - priorIndex)
                return firstDistance == secondDistance ? $0.offset > $1.offset : firstDistance < secondDistance
            }?
            .element ?? current.first
    }

    private static func monthOrdinal(_ id: String) -> Int? {
        guard id.hasPrefix("month:") else { return nil }
        let parts = id.dropFirst("month:".count).split(separator: "-")
        guard parts.count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]),
              (1...12).contains(month) else { return nil }
        return year * 12 + month
    }
}

struct DashboardView: View {
    @Environment(AppModel.self) private var appModel
    @Binding var scrollMemory: DashboardScrollMemory
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
                if appModel.activeSession != nil {
                    ResumeBanner()
                    Text("Finish the current cleanup before selecting more groups.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                }
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
                    GroupList(scrollMemory: $scrollMemory, onInteraction: mascotDidMove)
                        .disabled(appModel.activeSession != nil)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if appModel.activeSession == nil && !appModel.selectedGroupIDs.isEmpty {
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
                path.move(to: CGPoint(x: 6, y: 11))
                path.addLine(to: CGPoint(x: 8, y: 3))
                path.addLine(to: CGPoint(x: 14, y: 9))
                path.closeSubpath()
            }
            .fill(.yellow)
            .offset(x: -2, y: isBobbing ? 0 : 2)
            Path { path in
                path.move(to: CGPoint(x: 16, y: 9))
                path.addLine(to: CGPoint(x: 22, y: 3))
                path.addLine(to: CGPoint(x: 25, y: 11))
                path.closeSubpath()
            }
            .fill(.yellow)
            .offset(x: -2, y: isBobbing ? 0 : 2)
            Capsule()
                .fill(.yellow)
                .frame(width: 21, height: 18)
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
                .offset(x: -5, y: isBobbing ? -2 : 0)
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
                            Task { await appModel.discardActiveSession() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(RollSlashTheme.coral)
                }
            }
    }
}

private struct GroupList: View {
    @Environment(AppModel.self) private var appModel
    @Binding var scrollMemory: DashboardScrollMemory
    let onInteraction: () -> Void
    @State private var dragStarted = false
    @State private var didRestoreLocation = false

    var body: some View {
        if appModel.grouping == .month {
            MonthGroupList(scrollMemory: $scrollMemory, onInteraction: onInteraction)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(appModel.locationGroups) { group in
                            GroupRow(group: group, onSelect: { scrollMemory.locationAnchorID = group.id })
                                .id(group.id)
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.horizontal)
                    .padding(.bottom, 120)
                }
                .scrollPosition(id: $scrollMemory.locationID)
                .accessibilityIdentifier("location-group-list")
                .task(id: appModel.locationGroups.map(\.id)) {
                    let ids = appModel.locationGroups.map(\.id)
                    guard !ids.isEmpty else { return }
                    if didRestoreLocation {
                        if let anchor = scrollMemory.locationAnchorID, !ids.contains(anchor) {
                            scrollMemory.reconcileLocation(ids)
                        } else {
                            scrollMemory.locationOrder = ids
                        }
                        return
                    }
                    scrollMemory.reconcileLocation(ids)
                    didRestoreLocation = true
                    if let anchor = scrollMemory.locationAnchorID {
                        await Task.yield()
                        proxy.scrollTo(anchor, anchor: .center)
                    }
                }
                .onDisappear { didRestoreLocation = false }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 8)
                        .onChanged { _ in
                            guard !dragStarted else { return }
                            dragStarted = true
                            onInteraction()
                        }
                        .onEnded { _ in
                            dragStarted = false
                            if let id = scrollMemory.locationID { scrollMemory.locationAnchorID = id }
                        }
                )
            }
        }
    }
}

private struct MonthGroupList: View {
    @Environment(AppModel.self) private var appModel
    @Binding var scrollMemory: DashboardScrollMemory
    let onInteraction: () -> Void
    @State private var dragStarted = false
    @State private var didRestoreMonth = false
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

    private var orderedGroupIDs: [String] {
        sections.flatMap { section in section.1.map(\.id) }
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
                                        MonthGroupCard(group: group, onSelect: { scrollMemory.monthAnchorID = group.id })
                                            .id(group.id)
                                    }
                                }
                                .scrollTargetLayout()
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
                .scrollPosition(id: $scrollMemory.monthID)
                .accessibilityIdentifier("month-group-list")
                .task(id: orderedGroupIDs) {
                    guard !orderedGroupIDs.isEmpty else { return }
                    if didRestoreMonth {
                        if let anchor = scrollMemory.monthAnchorID, !orderedGroupIDs.contains(anchor) {
                            scrollMemory.reconcileMonth(orderedGroupIDs)
                        } else {
                            scrollMemory.monthOrder = orderedGroupIDs
                        }
                        return
                    }
                    scrollMemory.reconcileMonth(orderedGroupIDs)
                    didRestoreMonth = true
                    if let anchor = scrollMemory.monthAnchorID {
                        await Task.yield()
                        proxy.scrollTo(anchor, anchor: .center)
                    }
                }
                .onDisappear { didRestoreMonth = false }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 8)
                        .onChanged { _ in
                            guard !dragStarted else { return }
                            dragStarted = true
                            onInteraction()
                        }
                        .onEnded { _ in
                            dragStarted = false
                            if let id = scrollMemory.monthID { scrollMemory.monthAnchorID = id }
                        }
                )
                VStack(spacing: 8) {
                    ForEach(sections, id: \.0) { year, groups in
                        Button(year) {
                            onInteraction()
                            scrollMemory.monthAnchorID = groups.first?.id
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
    let onSelect: () -> Void

    private var selected: Bool { appModel.selectedGroupIDs.contains(group.id) }

    var body: some View {
        Button {
            onSelect()
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
    let onSelect: () -> Void

    private var selected: Bool { appModel.selectedGroupIDs.contains(group.id) }

    var body: some View {
        Button {
            onSelect()
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
