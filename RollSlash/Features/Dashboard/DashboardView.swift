import SwiftUI

struct DashboardScrollMemory {
    var monthID: String?
    var locationID: String?
    var monthAnchorID: String?
    var locationAnchorID: String?
    var monthOrder: [String] = []
    var locationOrder: [String] = []
    var typeID: String?
    var typeAnchorID: String?
    var typeOrder: [String] = []

    mutating func reconcileType(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        let resolved = Self.validAnchor(typeAnchorID ?? typeID, previous: typeOrder, current: ids)
        typeAnchorID = resolved
        typeID = resolved
        typeOrder = ids
    }

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
                if appModel.libraryLoadError != nil {
                    Button("Retry") {
                        appModel.errorMessage = nil
                        Task { await appModel.reloadLibrary() }
                    }
                }
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
                .zIndex(1)
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

                if appModel.grouping == .type {
                    VStack(alignment: .leading, spacing: 4) {
                        if appModel.isAnalyzingTypes {
                            ProgressView("Analyzing local photos… \(appModel.typeAnalysisCompleted)/\(appModel.typeAnalysisTotal)",
                                         value: Double(appModel.typeAnalysisCompleted), total: Double(max(1, appModel.typeAnalysisTotal)))
                                .accessibilityIdentifier("type-analysis-progress")
                        }
                        Text("Photos can appear in more than one group. Analysis uses local media without iCloud downloads.")
                            .font(.caption).foregroundStyle(.secondary)
                        if !appModel.isAnalyzingTypes && appModel.typeAnalysisUnavailableCount > 0 {
                            Text("\(appModel.typeAnalysisUnavailableCount) photos could not be fully analyzed. Roll Slash will retry when they become available.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let warning = appModel.similarityWarning {
                            Text(warning).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal).padding(.bottom, 8)
                }

                if appModel.isLoading && appModel.assets.isEmpty {
                    Spacer()
                    ProgressView("Reading your library…")
                    Spacer()
                } else if appModel.libraryLoadError != nil && appModel.visibleGroups.isEmpty {
                    ContentUnavailableView {
                        Label("Could not load your library", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text("Try reading your Photos library again.")
                    } actions: {
                        Button("Retry") { Task { await appModel.reloadLibrary() } }
                            .accessibilityIdentifier("retry-library")
                    }
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
                let selectedCount = appModel.selectedCandidateCount
                Button {
                    mascotDidMove()
                    appModel.beginSelectedCleanup()
                } label: {
                    VStack(spacing: 2) {
                        Text("Clean \(appModel.selectedGroupIDs.count) groups")
                            .font(.headline)
                        Text("\(selectedCount) items to review")
                            .font(.caption)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
                .tint(RollSlashTheme.violet)
                .disabled(selectedCount == 0)
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
        HStack(alignment: .center, spacing: 14) {
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

struct RollSlashMascot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let actionID: Int
    @State private var isBobbing = false
    @State private var pose: MascotPose = .rest
    @State private var dustProgress: CGFloat = 1
    @State private var actionTask: Task<Void, Never>?

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
            Circle()
                .stroke(.white.opacity(pose == .swipe ? 0.95 : 0), lineWidth: pose == .swipe ? 3 : 1)
                .scaleEffect(pose == .swipe ? 1.18 : 0.86)
            CatFace(pose: pose, isBobbing: isBobbing && pose == .rest)
            DustBurst(progress: dustProgress)
            CatPaw(pose: pose)
            Duster(pose: pose)
        }
        .frame(width: 56, height: 56)
        .scaleEffect(pose.scale, anchor: .leading)
        .rotationEffect(.degrees(pose.lean))
        .offset(pose.shift)
        .shadow(color: RollSlashTheme.violet.opacity(pose == .swipe ? 0.4 : 0), radius: pose == .swipe ? 12 : 0, y: 5)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Roll Slash mascot, cat with an animated paw and feather duster")
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                isBobbing = true
            }
        }
        .onDisappear { actionTask?.cancel() }
        .onChange(of: actionID) { _, _ in
            playSlash()
        }
    }

    private func playSlash() {
        guard !reduceMotion else { return }
        actionTask?.cancel()
        actionTask = Task { @MainActor in
            withAnimation(.spring(response: 0.16, dampingFraction: 0.82)) {
                pose = .windup
            }
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            var reset = Transaction()
            reset.disablesAnimations = true
            withTransaction(reset) { dustProgress = 0 }
            withAnimation(.spring(response: 0.28, dampingFraction: 0.46)) {
                pose = .swipe
            }
            withAnimation(.easeOut(duration: 0.55)) {
                dustProgress = 1
            }
            try? await Task.sleep(for: .milliseconds(420))
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.46, dampingFraction: 0.62)) {
                pose = .rest
            }
        }
    }
}

struct RollSlashMascotFace: View {
    var body: some View {
        ZStack {
            CatHeadSilhouette().fill(MascotPalette.fur)
            CatInnerEarShape(leading: true).fill(MascotPalette.ear)
            CatInnerEarShape(leading: false).fill(MascotPalette.ear)
            HStack(spacing: 9) {
                CatEye(squinting: true, wide: false)
                    .rotationEffect(.degrees(14))
                CatEye(squinting: true, wide: false)
                    .rotationEffect(.degrees(-14))
            }
            .offset(y: 1)
        }
        .frame(width: 48, height: 50)
        .accessibilityHidden(true)
    }
}

private enum MascotPose: Equatable {
    case rest
    case windup
    case swipe

    var scale: CGFloat {
        switch self {
        case .rest: 1
        case .windup: 0.88
        case .swipe: 1.38
        }
    }

    var lean: Double {
        switch self {
        case .rest: 0
        case .windup: -18
        case .swipe: 20
        }
    }

    var shift: CGSize {
        switch self {
        case .rest: .zero
        case .windup: CGSize(width: -6, height: 5)
        case .swipe: CGSize(width: 10, height: -14)
        }
    }

    var pawAngle: Double {
        switch self {
        case .rest: -18
        case .windup: -82
        case .swipe: 48
        }
    }

    var pawShift: CGSize {
        switch self {
        case .rest: CGSize(width: 14, height: 14)
        case .windup: CGSize(width: 1, height: -4)
        case .swipe: CGSize(width: 24, height: 18)
        }
    }

    var dusterAngle: Double {
        switch self {
        case .rest: -24
        case .windup: -88
        case .swipe: 56
        }
    }

    var dusterShift: CGSize {
        switch self {
        case .rest: CGSize(width: 20, height: 12)
        case .windup: CGSize(width: -4, height: -10)
        case .swipe: CGSize(width: 26, height: 6)
        }
    }
}

private enum MascotPalette {
    static let fur = Color(red: 0.992, green: 0.914, blue: 0.227)
    static let ear = Color(red: 1.0, green: 0.576, blue: 0.145)
    static let mouth = Color(red: 0.984, green: 0.369, blue: 0.514)
    static let eye = Color(red: 0.122, green: 0.024, blue: 0.0)
    static let paw = Color(red: 0.961, green: 0.588, blue: 0.165)
    static let dustLight = Color(red: 0.678, green: 0.980, blue: 0.906)
    static let dust = Color(red: 0.373, green: 0.922, blue: 0.808)
    static let dustDeep = Color(red: 0.247, green: 0.851, blue: 0.780)
    static let handle = Color(red: 0.055, green: 0.490, blue: 0.490)
}

private struct CatFace: View {
    let pose: MascotPose
    let isBobbing: Bool

    var body: some View {
        ZStack {
            CatHeadSilhouette()
                .fill(MascotPalette.fur)
            CatInnerEarShape(leading: true)
                .fill(MascotPalette.ear)
            CatInnerEarShape(leading: false)
                .fill(MascotPalette.ear)
            HStack(spacing: 9) {
                CatEye(squinting: pose == .swipe, wide: pose == .windup)
                CatEye(squinting: pose == .swipe, wide: pose == .windup)
            }
            .offset(y: 1)
            CatMouth(open: pose == .swipe ? 1 : 0)
                .fill(MascotPalette.mouth)
                .frame(width: pose == .swipe ? 11 : 9, height: pose == .swipe ? 8 : 6.5)
                .offset(y: 9)
        }
        .frame(width: 48, height: 50)
        .offset(x: -2, y: isBobbing ? -2 : 0)
        .rotationEffect(.degrees(pose == .windup ? 8 : (pose == .swipe ? -6 : 0)))
    }
}

private struct CatHeadSilhouette: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addEllipse(in: CGRect(x: rect.width * 0.06, y: rect.height * 0.28, width: rect.width * 0.88, height: rect.height * 0.70))
        path.addPath(ear(in: rect, leading: true))
        path.addPath(ear(in: rect, leading: false))
        return path
    }

    private func ear(in rect: CGRect, leading: Bool) -> Path {
        let width = rect.width
        let height = rect.height
        var path = Path()
        if leading {
            path.move(to: CGPoint(x: width * 0.10, y: height * 0.48))
            path.addCurve(
                to: CGPoint(x: width * 0.19, y: height * 0.19),
                control1: CGPoint(x: width * 0.10, y: height * 0.34),
                control2: CGPoint(x: width * 0.14, y: height * 0.21)
            )
            path.addQuadCurve(
                to: CGPoint(x: width * 0.25, y: height * 0.17),
                control: CGPoint(x: width * 0.21, y: height * 0.16)
            )
            path.addCurve(
                to: CGPoint(x: width * 0.48, y: height * 0.34),
                control1: CGPoint(x: width * 0.33, y: height * 0.19),
                control2: CGPoint(x: width * 0.42, y: height * 0.28)
            )
        } else {
            path.move(to: CGPoint(x: width * 0.52, y: height * 0.34))
            path.addCurve(
                to: CGPoint(x: width * 0.75, y: height * 0.17),
                control1: CGPoint(x: width * 0.58, y: height * 0.28),
                control2: CGPoint(x: width * 0.67, y: height * 0.19)
            )
            path.addQuadCurve(
                to: CGPoint(x: width * 0.81, y: height * 0.19),
                control: CGPoint(x: width * 0.79, y: height * 0.16)
            )
            path.addCurve(
                to: CGPoint(x: width * 0.90, y: height * 0.48),
                control1: CGPoint(x: width * 0.86, y: height * 0.21),
                control2: CGPoint(x: width * 0.90, y: height * 0.34)
            )
        }
        path.closeSubpath()
        return path
    }
}

private struct CatInnerEarShape: Shape {
    let leading: Bool

    func path(in rect: CGRect) -> Path {
        let width = rect.width
        let height = rect.height
        var path = Path()
        if leading {
            path.move(to: CGPoint(x: width * 0.17, y: height * 0.42))
            path.addQuadCurve(
                to: CGPoint(x: width * 0.23, y: height * 0.25),
                control: CGPoint(x: width * 0.17, y: height * 0.29)
            )
            path.addQuadCurve(
                to: CGPoint(x: width * 0.40, y: height * 0.33),
                control: CGPoint(x: width * 0.26, y: height * 0.22)
            )
        } else {
            path.move(to: CGPoint(x: width * 0.60, y: height * 0.33))
            path.addQuadCurve(
                to: CGPoint(x: width * 0.77, y: height * 0.25),
                control: CGPoint(x: width * 0.74, y: height * 0.22)
            )
            path.addQuadCurve(
                to: CGPoint(x: width * 0.83, y: height * 0.42),
                control: CGPoint(x: width * 0.83, y: height * 0.29)
            )
        }
        path.closeSubpath()
        return path
    }
}

private struct CatMouth: Shape {
    var open: CGFloat

    var animatableData: CGFloat {
        get { open }
        set { open = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let upperLeft = rect.minY + rect.height * (0.22 - 0.10 * open)
        let upperRight = rect.minY + rect.height * (0.08 - 0.04 * open)
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.10, y: upperLeft))
        path.addCurve(
            to: CGPoint(x: rect.minX + rect.width * 0.86, y: upperRight),
            control1: CGPoint(x: rect.minX + rect.width * 0.42, y: upperLeft + rect.height * 0.04),
            control2: CGPoint(x: rect.minX + rect.width * 0.70, y: upperRight + rect.height * 0.04)
        )
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.22),
            control1: CGPoint(x: rect.maxX, y: upperRight - rect.height * 0.06),
            control2: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.06)
        )
        path.addCurve(
            to: CGPoint(x: rect.midX, y: rect.maxY),
            control1: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.70),
            control2: CGPoint(x: rect.minX + rect.width * 0.80, y: rect.maxY)
        )
        path.addCurve(
            to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.36),
            control1: CGPoint(x: rect.minX + rect.width * 0.22, y: rect.maxY),
            control2: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.76)
        )
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + rect.width * 0.10, y: upperLeft),
            control: CGPoint(x: rect.minX, y: upperLeft)
        )
        path.closeSubpath()
        return path
    }
}

private struct CatEye: View {
    let squinting: Bool
    let wide: Bool

    var body: some View {
        ZStack {
            if squinting {
                Capsule()
                    .fill(MascotPalette.eye)
                    .frame(width: 8, height: 2.5)
            } else {
                Circle()
                    .fill(MascotPalette.eye)
                    .frame(width: wide ? 6 : 5, height: wide ? 6.5 : 5.5)
                Circle()
                    .fill(.white)
                    .frame(width: 1.8, height: 1.8)
                    .offset(x: 1.1, y: -1.2)
            }
        }
        .frame(width: 8, height: 8)
    }
}

private struct CatPaw: View {
    let pose: MascotPose

    var body: some View {
        Circle()
            .fill(MascotPalette.paw)
            .frame(width: 14, height: 14)
            .rotationEffect(.degrees(pose.pawAngle))
            .offset(pose.pawShift)
    }
}

private struct Duster: View {
    let pose: MascotPose

    var body: some View {
        VStack(spacing: -4) {
            HStack(spacing: -4) {
                feather(MascotPalette.dustDeep, height: 13, angle: -28)
                feather(MascotPalette.dust, height: 16, angle: -12)
                feather(MascotPalette.dustLight, height: 18, angle: 0)
                feather(MascotPalette.dust, height: 16, angle: 12)
                feather(MascotPalette.dustDeep, height: 13, angle: 28)
            }
            Capsule()
                .fill(MascotPalette.handle)
                .frame(width: 3.5, height: 16)
        }
        .rotationEffect(.degrees(pose.dusterAngle), anchor: .bottom)
        .offset(pose.dusterShift)
    }

    private func feather(_ color: Color, height: CGFloat, angle: Double) -> some View {
        Capsule()
            .fill(color)
            .frame(width: 6, height: height)
            .rotationEffect(.degrees(angle))
    }
}

private struct DustBurst: View {
    let progress: CGFloat

    var body: some View {
        ZStack {
            speck(MascotPalette.dustLight, distance: CGSize(width: 22, height: -18), size: 6)
            speck(MascotPalette.dust, distance: CGSize(width: 30, height: -6), size: 5)
            speck(MascotPalette.dustDeep, distance: CGSize(width: 14, height: -26), size: 5)
            speck(MascotPalette.dust, distance: CGSize(width: 34, height: -20), size: 4)
            Capsule()
                .fill(MascotPalette.dustLight)
                .frame(width: 8, height: 3)
                .rotationEffect(.degrees(-30))
                .scaleEffect(0.3 + progress * 1.3)
                .offset(x: 18 * progress, y: -24 * progress)
                .opacity(Double(1 - progress))
        }
        .offset(x: 8, y: 2)
        .allowsHitTesting(false)
    }

    private func speck(_ color: Color, distance: CGSize, size: CGFloat) -> some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .scaleEffect(0.35 + progress * 1.5)
            .offset(x: distance.width * progress, y: distance.height * progress)
            .opacity(Double(1 - progress))
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
                Text(appModel.activeSession?.status == .deleting
                     ? (appModel.permission == .full
                        ? "Make hidden selected items visible in Photos, then check again."
                        : "Full Photo Access is required to reconcile the result.")
                     : "\(appModel.sessionRemaining) items remaining")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if appModel.activeSession?.status == .deleting {
                if appModel.permission == .full {
                    Button("Check Again") { Task { await appModel.reloadLibrary() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(appModel.isLoading)
                } else {
                    Button("Manage Access") { appModel.openSystemSettings() }
                        .buttonStyle(.borderedProminent)
                }
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
    @State private var didRestoreType = false

    var body: some View {
        if appModel.grouping == .month {
            MonthGroupList(scrollMemory: $scrollMemory, onInteraction: onInteraction)
        } else if appModel.grouping == .type {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(appModel.typeGroups) { group in
                            GroupRow(group: group, onSelect: { scrollMemory.typeAnchorID = group.id })
                                .id(group.id)
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.horizontal)
                    .padding(.bottom, 120)
                }
                .scrollPosition(id: $scrollMemory.typeID)
                .accessibilityIdentifier("type-group-list")
                .task(id: appModel.typeGroups.map(\.id)) {
                    let ids = appModel.typeGroups.map(\.id)
                    guard !ids.isEmpty else { return }
                    if didRestoreType {
                        if let anchor = scrollMemory.typeAnchorID, !ids.contains(anchor) { scrollMemory.reconcileType(ids) }
                        else { scrollMemory.typeOrder = ids }
                        return
                    }
                    scrollMemory.reconcileType(ids)
                    didRestoreType = true
                    if let anchor = scrollMemory.typeAnchorID {
                        await Task.yield()
                        proxy.scrollTo(anchor, anchor: .center)
                    }
                }
                .onDisappear { didRestoreType = false }
                .simultaneousGesture(DragGesture(minimumDistance: 8)
                    .onChanged { _ in
                        guard !dragStarted else { return }
                        dragStarted = true
                        onInteraction()
                    }
                    .onEnded { _ in
                        dragStarted = false
                        if let id = scrollMemory.typeID { scrollMemory.typeAnchorID = id }
                    })
            }
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
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
        appModel.monthSections
    }

    private var orderedGroupIDs: [String] {
        sections.flatMap { section in section.1.map(\.id) }
    }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                if dynamicTypeSize.isAccessibilitySize {
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(sections, id: \.0) { year, groups in
                                yearButton(year, firstGroupID: groups.first?.id, proxy: proxy)
                            }
                        }
                        .padding(.horizontal)
                    }
                    .scrollIndicators(.hidden)
                    .fixedSize(horizontal: false, vertical: true)
                }
                ZStack(alignment: .trailing) {
                    ScrollView {
                        LazyVStack(alignment: .leading, pinnedViews: [.sectionHeaders]) {
                            ForEach(sections, id: \.0) { year, groups in
                                Section {
                                    LazyVGrid(columns: groups.count == 1 || dynamicTypeSize.isAccessibilitySize ? singleColumn : columns, spacing: 12) {
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
                        .padding(.trailing, dynamicTypeSize.isAccessibilitySize ? 0 : 40)
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
                    if !dynamicTypeSize.isAccessibilitySize {
                        ScrollView {
                            VStack(spacing: 8) {
                                ForEach(sections, id: \.0) { year, groups in
                                    yearButton(year, firstGroupID: groups.first?.id, proxy: proxy)
                                }
                            }
                        }
                        .scrollIndicators(.hidden)
                        .frame(width: 48)
                        .padding(.trailing, 4)
                    }
                }
            }
        }
    }

    private func yearButton(_ year: String, firstGroupID: String?, proxy: ScrollViewProxy) -> some View {
        Button(year) {
            onInteraction()
            scrollMemory.monthAnchorID = firstGroupID
            withAnimation { proxy.scrollTo(year, anchor: .top) }
        }
        .font(.caption2.bold())
        .lineLimit(1)
        .minimumScaleFactor(0.5)
        .foregroundStyle(RollSlashTheme.violet)
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(.rect)
        .accessibilityLabel("Jump to \(year)")
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
                            .accessibilityIdentifier("group-title-\(group.key.id)")
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
            .contentShape(.rect(cornerRadius: 20))
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
                    Text("All \(group.totalCount) accessible items in this group will be added to a new cleanup session. Nothing is deleted until final review.")
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
            .contentShape(.rect(cornerRadius: 22))
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
