import Foundation
import Observation
import SwiftData
import CryptoKit

struct CleanupMetricsSummary: Equatable {
    let itemCount: Int
    let estimatedStorageBytes: Int64
    let unavailableEstimateCount: Int

    static let zero = CleanupMetricsSummary(itemCount: 0, estimatedStorageBytes: 0, unavailableEstimateCount: 0)

    var formattedEstimatedStorage: String {
        guard estimatedStorageBytes > 0 else {
            return unavailableEstimateCount > 0 ? String(localized: "Unavailable") : String(localized: "0 bytes")
        }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: estimatedStorageBytes)
    }
}

private final class CleanupMetricsStore {
    private struct Entry: Codable {
        var estimatedBytes: Int64?
    }

    private struct FoldedTotals: Codable {
        var itemCount = 0
        var estimatedStorageBytes: Int64 = 0
        var unavailableEstimateCount = 0
    }

    private static let storageKey = "roll-slash.cleanup-metrics.v1"
    private static let foldedKey = "roll-slash.cleanup-metrics.folded.v1"
    private static let stagedKey = "roll-slash.cleanup-metrics.staged.v1"
    private static let sessionLimit = 40
    private let defaults: UserDefaults?
    private var entries: [String: [String: Entry]]
    private var folded = FoldedTotals()
    private var staged: [String: [String: Int64]]

    init() {
        let process = ProcessInfo.processInfo
        let isTesting = process.arguments.contains("--ui-testing")
            || process.environment["XCTestConfigurationFilePath"] != nil
        defaults = isTesting ? nil : .standard
        if let data = defaults?.data(forKey: Self.storageKey),
           let savedEntries = try? JSONDecoder().decode([String: [String: Entry]].self, from: data) {
            entries = savedEntries
        } else {
            entries = [:]
        }
        if let data = defaults?.data(forKey: Self.foldedKey),
           let savedFolded = try? JSONDecoder().decode(FoldedTotals.self, from: data) {
            folded = savedFolded
        }
        if let data = defaults?.data(forKey: Self.stagedKey),
           let savedStaged = try? JSONDecoder().decode([String: [String: Int64]].self, from: data) {
            staged = savedStaged
        } else {
            staged = [:]
        }
    }

    /// Remembers byte estimates before Photos deletion so a crash during deletion can still report them.
    func stage(sessionID: UUID, ids: [String], estimatedBytes: [String: Int64]) {
        let sessionKey = sessionID.uuidString
        var bucket = staged[sessionKey] ?? [:]
        var changed = false
        for id in Set(ids) {
            guard let bytes = estimatedBytes[id] else { continue }
            let assetKey = Self.assetKey(for: id)
            if bucket[assetKey] != bytes {
                bucket[assetKey] = bytes
                changed = true
            }
        }
        guard changed else { return }
        staged[sessionKey] = bucket
        saveStaged()
    }

    func clearStage(sessionID: UUID) {
        guard staged.removeValue(forKey: sessionID.uuidString) != nil else { return }
        saveStaged()
    }

    func record(sessionID: UUID, ids: [String], estimatedBytes: [String: Int64]) {
        let sessionKey = sessionID.uuidString
        let stagedBytes = staged[sessionKey] ?? [:]
        var changed = false
        for id in Set(ids) {
            let assetKey = Self.assetKey(for: id)
            let estimate = estimatedBytes[id] ?? stagedBytes[assetKey]
            if let existing = entries[sessionKey]?[assetKey] {
                if existing.estimatedBytes == nil, let estimate {
                    entries[sessionKey, default: [:]][assetKey] = Entry(estimatedBytes: estimate)
                    changed = true
                }
            } else {
                entries[sessionKey, default: [:]][assetKey] = Entry(estimatedBytes: estimate)
                changed = true
            }
        }
        if staged.removeValue(forKey: sessionKey) != nil { changed = true }
        guard changed else { return }
        prune(keeping: sessionKey)
        saveEntries()
        saveStaged()
    }

    func summary(for sessionID: UUID? = nil) -> CleanupMetricsSummary {
        let selectedEntries: [Entry]
        if let sessionID {
            selectedEntries = entries[sessionID.uuidString].map { Array($0.values) } ?? []
            return CleanupMetricsSummary(
                itemCount: selectedEntries.count,
                estimatedStorageBytes: selectedEntries.compactMap(\.estimatedBytes).reduce(0, +),
                unavailableEstimateCount: selectedEntries.filter { $0.estimatedBytes == nil }.count
            )
        }
        selectedEntries = entries.values.flatMap(\.values)
        return CleanupMetricsSummary(
            itemCount: selectedEntries.count + folded.itemCount,
            estimatedStorageBytes: selectedEntries.compactMap(\.estimatedBytes).reduce(folded.estimatedStorageBytes, +),
            unavailableEstimateCount: selectedEntries.filter { $0.estimatedBytes == nil }.count + folded.unavailableEstimateCount
        )
    }

    func reset() {
        entries.removeAll()
        folded = FoldedTotals()
        staged.removeAll()
        defaults?.removeObject(forKey: Self.storageKey)
        defaults?.removeObject(forKey: Self.foldedKey)
        defaults?.removeObject(forKey: Self.stagedKey)
    }

    private func prune(keeping sessionKey: String) {
        let overflow = entries.count - Self.sessionLimit
        guard overflow > 0 else { return }
        for key in entries.keys.filter({ $0 != sessionKey }).prefix(overflow) {
            guard let removed = entries.removeValue(forKey: key) else { continue }
            folded.itemCount += removed.count
            folded.estimatedStorageBytes += removed.values.compactMap(\.estimatedBytes).reduce(0, +)
            folded.unavailableEstimateCount += removed.values.filter { $0.estimatedBytes == nil }.count
        }
    }

    private func saveEntries() {
        guard let defaults else { return }
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: Self.storageKey)
        }
        if let data = try? JSONEncoder().encode(folded) {
            defaults.set(data, forKey: Self.foldedKey)
        }
    }

    private func saveStaged() {
        guard let defaults else { return }
        if staged.isEmpty {
            defaults.removeObject(forKey: Self.stagedKey)
        } else if let data = try? JSONEncoder().encode(staged) {
            defaults.set(data, forKey: Self.stagedKey)
        }
    }

    private static func assetKey(for identifier: String) -> String {
        SHA256.hash(data: Data(identifier.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

private struct GroupCompletionSnapshot: Sendable {
    let groupKey: String
    let lastLabel: String
}

private struct GroupBuildResult: Sendable {
    let month: [MediaGroup]
    let location: [MediaGroup]
    let type: [MediaGroup]
}

@MainActor
@Observable
final class AppModel {
    var route: AppRoute = .onboarding {
        didSet {
            guard route != oldValue else { return }
            if route != .cleanup && route != .similarComparison {
                previewProvider.stopCachingAll()
            }
            if route == .dashboard, grouping == .type {
                startTypeAnalysis()
            } else if route != .dashboard {
                cancelTypeAnalysis()
            }
            if route == .dashboard, grouping == .location, !assets.isEmpty {
                resolveMissingLocations()
            } else if route != .dashboard {
                locationResolutionTask?.cancel()
                locationResolutionTask = nil
            }
        }
    }
    var permission: PhotoPermission = .notDetermined
    var grouping: GroupKind = .month {
        didSet {
            selectedGroupIDs.removeAll()
            if grouping == .type { startTypeAnalysis() } else { cancelTypeAnalysis() }
            if grouping == .location {
                resolveMissingLocations()
            } else {
                locationResolutionTask?.cancel()
                locationResolutionTask = nil
            }
        }
    }
    var monthGroups: [MediaGroup] = []
    var locationGroups: [MediaGroup] = []
    var typeGroups: [MediaGroup] = []
    @ObservationIgnored private(set) var analysisResults: [String: MediaAnalysisResult] = [:]
    private(set) var similarClusters: [SimilarPhotoCluster] = []
    private(set) var isAnalyzingTypes = false
    private(set) var typeAnalysisCompleted = 0
    private(set) var typeAnalysisTotal = 0

    private(set) var typeAnalysisUnavailableCount = 0
    private var hasUnavailableSimilarity = false

    var similarityWarning: String? {
        hasUnavailableSimilarity
            ? String(localized: "Similarity detection is unavailable on this device. Other type detection continues.") : nil
    }
    var selectedGroupIDs: Set<String> = []
    var assets: [PhotoAssetDescriptor] = []
    private(set) var assetIndex: [String: PhotoAssetDescriptor] = [:]
    private(set) var decisionsByAssetID: [String: AssetDecision] = [:]
    var activeSession: CleanupSessionRecord?
    var actions: [CleanupActionRecord] = []
    var isLoading = false
    private(set) var isDeleting = false
    var errorMessage: String?
    var showingSettings = false
    private(set) var lifetimeCleanupSummary = CleanupMetricsSummary.zero
    private(set) var lastCleanupSummary = CleanupMetricsSummary.zero

    @ObservationIgnored private let photoLibrary: any PhotoLibraryClient
    @ObservationIgnored let previewProvider: any MediaPreviewProvider
    @ObservationIgnored private let locationResolver: any LocationResolver
    @ObservationIgnored private let repository: any CleanupRepository
    @ObservationIgnored private let analysisClient: any MediaAnalysisClient
    @ObservationIgnored private var typeAnalysisTask: Task<Void, Never>?
    @ObservationIgnored private var typeAnalysisGeneration = 0
    @ObservationIgnored private var analysisCacheBuffer: [String: MediaAnalysisCacheEntry] = [:]
    @ObservationIgnored private var analysisCacheFlushTask: Task<Void, Never>?
    @ObservationIgnored private var unavailableSimilarityCount = 0
    @ObservationIgnored private var isForeground = true
    @ObservationIgnored private let cleanupMetricsStore: CleanupMetricsStore
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var bucketLocations: [String: ResolvedLocation] = [:]
    @ObservationIgnored private var bucketLocationLocaleIdentifier = Locale.current.identifier
    @ObservationIgnored private var locationResolutionTask: Task<Void, Never>?
    @ObservationIgnored private var libraryReloadGeneration = 0
    @ObservationIgnored private var groupBuildGeneration = 0
    @ObservationIgnored private var localPhotoChangeDepth = 0
    @ObservationIgnored private var libraryChangeCoalesced = false

    init(
        photoLibrary: any PhotoLibraryClient,
        previewProvider: any MediaPreviewProvider,
        locationResolver: any LocationResolver,
        modelContainer: ModelContainer,
        analysisClient: any MediaAnalysisClient = PhotoKitMediaAnalysisClient()
    ) {
        self.photoLibrary = photoLibrary
        self.previewProvider = previewProvider
        self.locationResolver = locationResolver
        self.repository = SwiftDataCleanupRepository(container: modelContainer)
        self.analysisClient = analysisClient
        let cleanupMetricsStore = CleanupMetricsStore()
        self.cleanupMetricsStore = cleanupMetricsStore
        self.lifetimeCleanupSummary = cleanupMetricsStore.summary()
    }

    var visibleGroups: [MediaGroup] {
        switch grouping {
        case .month: monthGroups
        case .location: locationGroups
        case .type: typeGroups
        }
    }

    var selectedGroups: [MediaGroup] {
        visibleGroups.filter { selectedGroupIDs.contains($0.id) }
    }

    var selectedCandidateCount: Int {
        selectedCandidateIDs.count
    }

    private var selectedCandidateIDs: Set<String> {
        selectedGroups.reduce(into: Set<String>()) { identifiers, group in
            for id in group.assetIDs where assetIndex[id] != nil {
                if group.isCleaned || decisionsByAssetID[id] == nil { identifiers.insert(id) }
            }
        }
    }

    private var selectedCleanupPlan: CleanupWorkPlan {
        let identifiers = selectedCandidateIDs
        let ordered = assets.filter { identifiers.contains($0.id) }.sorted {
            let lhs = $0.creationDate ?? .distantPast, rhs = $1.creationDate ?? .distantPast
            return lhs == rhs ? $0.id < $1.id : lhs > rhs
        }.map(\.id)
        var units: [CleanupWorkUnit] = []
        var compared = Set<String>()
        if selectedGroupIDs.contains(MediaTypeCategory.similarPhotos.key.id) {
            for cluster in similarClusters {
                let all = cluster.assetIDs.filter { assetIndex[$0] != nil }
                let review = all.filter { identifiers.contains($0) && !compared.contains($0) }
                guard !review.isEmpty, all.count >= 2 else { continue }
                units.append(CleanupWorkUnit(kind: .comparison, assetIDs: review,
                                             contextAssetIDs: all.filter { !identifiers.contains($0) }, clusterID: cluster.id))
                compared.formUnion(review)
            }
        }
        units += ordered.filter { !compared.contains($0) }.map(CleanupWorkUnit.swipe)
        return CleanupWorkPlan(units: units)
    }

    var currentAsset: PhotoAssetDescriptor? {
        guard let session = activeSession,
              session.cursor < session.orderedAssetIDs.count else { return nil }
        let identifier = session.orderedAssetIDs[session.cursor]
        return assetIndex[identifier]
    }

    var currentComparison: CleanupWorkUnit? {
        guard let session = activeSession, let unit = session.unit(at: session.cursor)?.unit,
              unit.kind == .comparison else { return nil }
        return unit
    }

    var comparisonDeleteIDs: Set<String> {
        guard let session = activeSession, let unit = currentComparison else { return [] }
        return session.draftDeleteIDs.intersection(unit.assetIDs)
    }

    func toggleComparisonDeletion(_ id: String) {
        guard !isDeleting, let session = activeSession, session.status == .swiping,
              let unit = currentComparison, unit.assetIDs.contains(id),
              session.workPlan != nil else { return }
        let previous = session.draftDeleteIDs
        var drafts = previous
        if drafts.contains(id) { drafts.remove(id) } else { drafts.insert(id) }
        session.draftDeleteIDs = drafts
        do { try repository.save() } catch { session.draftDeleteIDs = previous; errorMessage = error.localizedDescription }
    }

    func confirmComparison(keepAll: Bool = false) async {
        guard let session = activeSession, session.status == .swiping, let unit = currentComparison else { return }
        let deletions = keepAll ? Set<String>() : comparisonDeleteIDs
        do {
            let sequence = session.cursor
            let recorded = try repository.recordDecisions(session: session, decisions: unit.assetIDs.map {
                ($0, deletions.contains($0) ? .deletePending : .keep)
            })
            actions.removeAll { $0.sequence >= sequence }
            actions += recorded
            try refreshDecisionCache()
            await advanceAfterDecision()
        } catch { errorMessage = error.localizedDescription }
    }

    var reviewCandidateAssets: [PhotoAssetDescriptor] {
        reviewCandidateIDs.compactMap { assetIndex[$0] }
    }

    var sessionTotal: Int { activeSession?.orderedAssetIDs.count ?? 0 }
    var sessionCompleted: Int { activeSession?.cursor ?? 0 }
    var sessionRemaining: Int { max(0, sessionTotal - sessionCompleted) }
    var keptCount: Int { actions.filter { $0.isApplied && $0.decision == .keep }.count }
    var deleteCount: Int { actions.filter { $0.isApplied && $0.decision == .deletePending }.count }
    var canUndo: Bool { activeSession?.status == .swiping && sessionCompleted > 0 }
    var canRedo: Bool {
        guard let session = activeSession, session.status == .swiping else { return false }
        return actions.contains { $0.sequence == session.cursor && !$0.isApplied }
    }

    var reviewCandidateIDs: [String] {
        actions.filter { $0.isApplied && $0.decision == .deletePending }.sorted { $0.sequence < $1.sequence }.map(\.assetIdentifier)
    }

    var reviewSelectedIDs: Set<String> {
        Set(activeSession?.reviewSelectedIDs ?? [])
    }

    var canEditReview: Bool { !isDeleting && activeSession?.status == .reviewing }

    var isPartialAccess: Bool { permission == .limited }

    func isFavorite(_ identifier: String) async -> Bool {
        await photoLibrary.isFavorite(with: identifier)
    }

    func setFavorite(_ favorite: Bool, for identifier: String) async throws {
        // PhotoKit reports our own favorite change as a library update. Applying it
        // locally avoids rebuilding the whole library in the middle of a swipe.
        localPhotoChangeDepth += 1
        defer {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(1500))
                guard let self else { return }
                self.localPhotoChangeDepth = max(0, self.localPhotoChangeDepth - 1)
            }
        }
        try await photoLibrary.setFavorite(favorite, for: identifier)
        applyLocalFavorite(favorite, identifier: identifier)
        if permission.canRead {
            try? await rebuildGroupsOffMain()
        }
    }

    private func applyLocalFavorite(_ favorite: Bool, identifier: String) {
        guard var asset = assetIndex[identifier] else { return }
        asset.isFavorite = favorite
        assetIndex[identifier] = asset
        if let index = assets.firstIndex(where: { $0.id == identifier }) {
            assets[index] = asset
        }
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        photoLibrary.onLibraryChange = { [weak self] in
            guard let self, !self.isDeleting else { return }
            if self.localPhotoChangeDepth > 0 {
                self.libraryChangeCoalesced = true
                return
            }
            Task { await self.reloadLibrary() }
        }
        permission = photoLibrary.authorizationStatus()

        if let session = try? repository.activeSession() {
            activeSession = session
            actions = (try? repository.actions(for: session.identifier)) ?? []
        }

        let hasSeenOnboarding = UserDefaults.standard.bool(forKey: "hasSeenOnboarding")
        if permission == .notDetermined && !hasSeenOnboarding {
            route = .onboarding
        } else {
            route = .dashboard
            if permission.canRead {
                photoLibrary.startObservingChanges()
                await reloadLibrary()
            }
        }
    }

    func requestAccess() async {
        UserDefaults.standard.set(true, forKey: "hasSeenOnboarding")
        permission = await photoLibrary.requestAuthorization()
        route = .dashboard
        if permission.canRead {
            photoLibrary.startObservingChanges()
            await reloadLibrary()
        } else {
            libraryReloadGeneration += 1
            isLoading = false
        }
    }

    /// Re-checks Photos access when the app becomes active. Library edits still arrive through PhotoKit's change observer.
    func refreshForForeground() async {
        guard hasStarted else { return }
        let current = photoLibrary.authorizationStatus()
        let authorizationChanged = current != permission
        let needsInitialLoad = current.canRead && assets.isEmpty && !isLoading
        guard authorizationChanged || needsInitialLoad || libraryChangeCoalesced else { return }
        libraryChangeCoalesced = false
        await refreshAuthorization()
    }

    func refreshAuthorization() async {
        guard hasStarted else { return }
        let previousPermission = permission
        permission = photoLibrary.authorizationStatus()
        if permission.canRead {
            photoLibrary.startObservingChanges()
            await reloadLibrary()
        } else if previousPermission.canRead || !assets.isEmpty {
            libraryReloadGeneration += 1
            isLoading = false
            locationResolutionTask?.cancel()
            cancelTypeAnalysis()
            previewProvider.stopCachingAll()
            assets = []
            assetIndex = [:]
            monthGroups = []
            locationGroups = []
            typeGroups = []
            analysisResults = [:]
            resetAnalysisWarnings()
            typeAnalysisUnavailableCount = 0
            similarClusters = []
            selectedGroupIDs.removeAll()
            route = .dashboard
        }
    }

    func continueWithoutAccess() {
        UserDefaults.standard.set(true, forKey: "hasSeenOnboarding")
        permission = photoLibrary.authorizationStatus()
        route = .dashboard
        if permission.canRead { photoLibrary.startObservingChanges() }
    }

    func reloadLibrary() async {
        guard permission.canRead else { return }
        cancelTypeAnalysis()
        libraryReloadGeneration += 1
        let generation = libraryReloadGeneration
        isLoading = true
        defer { if generation == libraryReloadGeneration { isLoading = false } }
        do {
            let fetchedAssets = try await photoLibrary.fetchAssets()
            guard generation == libraryReloadGeneration, permission.canRead else { return }
            assets = fetchedAssets
            assetIndex = Dictionary(uniqueKeysWithValues: fetchedAssets.map { ($0.id, $0) })
            previewProvider.invalidateCachedImages()
            try refreshDecisionCache()
            try await recoverDeletingSessionIfPossible()
            guard generation == libraryReloadGeneration, permission.canRead else { return }
            try reconcileSessionState(purgeMissingDecisions: permission == .full)
            try refreshDecisionCache()
            try loadCachedLocations()
            let cachedResults = try repository.cachedAnalysis(for: assets, purgeMissing: permission == .full)
            // Keep valid existing sets visible during matching so a foreground
            // refresh does not temporarily hide Similar Photos or move its scroll anchor.
            similarClusters = similarClusters.filter { cluster in
                cluster.assetIDs.allSatisfy { id in
                    guard assetIndex[id] != nil, let cached = cachedResults[id],
                          cached.featurePrint != nil, let previous = analysisResults[id] else { return false }
                    return cached.featurePrint == previous.featurePrint && cached.perceptualHash == previous.perceptualHash
                }
            }
            analysisResults = cachedResults
            resetAnalysisWarnings()
            typeAnalysisUnavailableCount = assets.filter { $0.mediaKind != .video && analysisResults[$0.id]?.isComplete != true }.count
            try await rebuildGroupsOffMain(expectedReloadGeneration: generation)
            guard generation == libraryReloadGeneration, permission.canRead else { return }
            let clusters = await analysisClient.clusters(assets: assets, results: analysisResults)
            guard generation == libraryReloadGeneration, permission.canRead else { return }
            if clusters != similarClusters {
                similarClusters = clusters
                try await rebuildGroupsOffMain(expectedReloadGeneration: generation)
                guard generation == libraryReloadGeneration, permission.canRead else { return }
            }
            isLoading = false
            if grouping == .location { resolveMissingLocations() }
            if grouping == .type { startTypeAnalysis() }
            if let session = activeSession,
               session.status == .swiping,
               session.cursor >= session.orderedAssetIDs.count {
                await finishSwiping()
            } else if route == .cleanup || route == .similarComparison {
                routeCurrentWorkUnit()
                preheatAroundCurrentAsset()
            }
        } catch {
            if generation == libraryReloadGeneration { errorMessage = error.localizedDescription }
        }
    }

    func toggleSelection(_ group: MediaGroup) {
        guard activeSession == nil else { return }
        if selectedGroupIDs.contains(group.id) {
            selectedGroupIDs.remove(group.id)
        } else {
            selectedGroupIDs.insert(group.id)
        }
    }

    func beginSelectedCleanup() {
        guard !isDeleting else { return }
        guard activeSession == nil else {
            resumeSession()
            return
        }
        let plan = selectedCleanupPlan
        let ordered = plan.assetIDs
        guard !ordered.isEmpty else { return }

        do {
            let keys = selectedGroups.map(\.key.id)
            activeSession = try repository.createSession(
                groupKind: grouping,
                selectedGroupKeys: keys,
                orderedAssetIDs: ordered,
                workPlan: plan
            )
            actions = []
            routeCurrentWorkUnit()
            preheatAroundCurrentAsset()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func resumeSession() {
        guard !isDeleting, let session = activeSession else { return }
        switch session.status {
        case .swiping: routeCurrentWorkUnit()
        case .reviewing:
            session.status = .reviewing
            try? repository.save()
            route = .review
        case .deleting:
            errorMessage = String(localized: "Roll Slash must verify the previous deletion before it can continue. Grant Full Photo Access, then return to the app.")
            route = .dashboard
        }
        preheatAroundCurrentAsset()
    }

    func discardActiveSession() async {
        guard !isDeleting, let session = activeSession, session.status != .deleting else { return }
        do {
            try repository.discard(session: session)
            try refreshDecisionCache()
            activeSession = nil
            actions = []
            selectedGroupIDs.removeAll()
            route = .dashboard
            try await rebuildGroupsOffMain()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func decide(_ decision: AssetDecision) async {
        guard let session = activeSession,
              session.status == .swiping,
              session.cursor < session.orderedAssetIDs.count, currentComparison == nil else { return }
        let assetIdentifier = session.orderedAssetIDs[session.cursor]
        do {
            let sequence = session.cursor
            let action = try repository.recordDecision(
                session: session, assetIdentifier: assetIdentifier, decision: decision
            )
            decisionsByAssetID[assetIdentifier] = decision
            actions.removeAll { $0.sequence >= sequence }
            actions.append(action)
            await advanceAfterDecision()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func undo() {
        guard let session = activeSession, session.status == .swiping, session.cursor > 0 else { return }
        guard let previous = session.unit(at: session.cursor - 1) else { return }
        do {
            try repository.setUnitApplied(session: session,
                range: previous.start..<(previous.start + previous.unit.assetIDs.count), applied: false)
            try refreshDecisionCache()
            actions = try repository.actions(for: session.identifier)
            routeCurrentWorkUnit()
            preheatAroundCurrentAsset()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func redo() async {
        guard let session = activeSession, session.status == .swiping,
              let unit = session.unit(at: session.cursor),
              actions.contains(where: { $0.sequence == session.cursor && !$0.isApplied }) else { return }
        do {
            try repository.setUnitApplied(session: session,
                range: unit.start..<(unit.start + unit.unit.assetIDs.count), applied: true)
            try refreshDecisionCache()
            actions = try repository.actions(for: session.identifier)
            await advanceAfterDecision()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func reviewCurrentBatch() {
        guard let session = activeSession, session.status == .swiping else { return }
        let candidates = actions
            .filter { $0.isApplied && $0.decision == .deletePending }
            .sorted { $0.sequence < $1.sequence }
            .map(\.assetIdentifier)
        guard !candidates.isEmpty else { return }

        do {
            session.reviewSelectedIDs = candidates
            session.status = .reviewing
            try repository.save()
            route = .review
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func finishCurrentSession() async {
        guard let session = activeSession,
              session.status == .swiping,
              deleteCount == 0 else { return }

        let fullyReviewed = sessionRemaining == 0
        do {
            try await finalizeSession(session, markGroupsCompleted: fullyReviewed)
            lastCleanupSummary = cleanupMetricsStore.summary(for: session.identifier)
            route = fullyReviewed ? .completion : .dashboard
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func toggleReviewSelection(_ identifier: String) {
        guard canEditReview, let session = activeSession,
              reviewCandidateIDs.contains(identifier),
              assetIndex[identifier] != nil else { return }
        let isSelected = !session.reviewSelectedIDs.contains(identifier)
        do {
            try repository.updateReviewSelection(
                session: session,
                assetIdentifier: identifier,
                isSelected: isSelected
            )
            decisionsByAssetID[identifier] = isSelected ? .deletePending : .keep
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectAllForDeletion() {
        guard canEditReview, let session = activeSession else { return }
        do {
            try repository.updateReviewSelection(
                session: session,
                candidateIDs: reviewCandidateIDs,
                selectedIDs: Set(reviewCandidateIDs)
            )
            try refreshDecisionCache()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func keepAllFromReview() {
        guard canEditReview, let session = activeSession else { return }
        do {
            try repository.updateReviewSelection(session: session, candidateIDs: reviewCandidateIDs, selectedIDs: [])
            try refreshDecisionCache()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func undoLastSwipeFromReview() {
        guard canEditReview, let session = activeSession, session.cursor > 0 else { return }
        do {
            let applied = actions.filter(\.isApplied)
            session.status = .swiping
            try repository.updateReviewSelection(
                session: session,
                candidateIDs: applied.map(\.assetIdentifier),
                selectedIDs: Set(applied.filter { $0.decision == .deletePending }.map(\.assetIdentifier))
            )
            undo()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func commitDeletion() async {
        guard canEditReview, let session = activeSession else { return }
        let sessionID = session.identifier
        let fullyReviewed = session.cursor >= session.orderedAssetIDs.count
        let selected = session.reviewSelectedIDs
        isDeleting = true
        defer { isDeleting = false }

        do {
            session.status = .deleting
            try repository.save()
        } catch {
            session.status = .reviewing
            errorMessage = String(localized: "Roll Slash could not prepare the deletion. Nothing was deleted. \(error.localizedDescription)")
            return
        }

        let estimatedBytes = selected.isEmpty ? [:] : await photoLibrary.estimateStorageBytes(for: selected)
        guard activeSession?.identifier == sessionID, session.status == .deleting else { return }
        cleanupMetricsStore.stage(sessionID: sessionID, ids: selected, estimatedBytes: estimatedBytes)
        if !selected.isEmpty {
            do {
                let deletedIdentifiers = try await photoLibrary.deleteAssets(with: selected)
                guard deletedIdentifiers == Set(selected) else {
                    throw PhotoLibraryDeletionError.inaccessibleAssets(
                        requested: Set(selected).count,
                        accessible: deletedIdentifiers.count
                    )
                }
                cleanupMetricsStore.record(sessionID: sessionID, ids: selected, estimatedBytes: estimatedBytes)
                lifetimeCleanupSummary = cleanupMetricsStore.summary()
            } catch {
                guard activeSession?.identifier == sessionID else { return }
                cleanupMetricsStore.clearStage(sessionID: sessionID)
                session.status = .reviewing
                do {
                    try repository.save()
                } catch {
                    errorMessage = String(localized: "Nothing was deleted, and the review state could not be saved. \(error.localizedDescription)")
                    return
                }
                errorMessage = String(localized: "Nothing was deleted. \(error.localizedDescription)")
                return
            }
    }

        do {
            guard activeSession?.identifier == sessionID else { return }
            if !selected.isEmpty {
                try repository.removeDecisions(for: Set(selected))
                try refreshDecisionCache()
            }
            try await finalizeSession(session, markGroupsCompleted: fullyReviewed)
            await reloadLibrary()
            if fullyReviewed {
                lastCleanupSummary = cleanupMetricsStore.summary(for: session.identifier)
            }
            route = fullyReviewed ? .completion : .dashboard
        } catch {
            if selected.isEmpty {
                session.status = .reviewing
                try? repository.save()
                errorMessage = String(localized: "Nothing was deleted, but Roll Slash could not finish the session. \(error.localizedDescription)")
            } else {
                let deleted = Set(selected)
                assets.removeAll { deleted.contains($0.id) }
                assetIndex = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
                selectedGroupIDs.removeAll()
                try? await rebuildGroupsOffMain()
                route = .dashboard
                errorMessage = String(localized: "\(selected.count) items were deleted from Photos, but Roll Slash could not finish updating its cleanup history. Reopen the app to reconcile the library. \(error.localizedDescription)")
            }
        }
    }

    func finishCompletion() {
        selectedGroupIDs.removeAll()
        route = .dashboard
    }

    func presentLimitedLibraryPicker() {
        photoLibrary.presentLimitedLibraryPicker()
    }

    func openSystemSettings() {
        photoLibrary.openSystemSettings()
    }

    @discardableResult
    func resetHistory() async -> Bool {
        guard !isDeleting, activeSession?.status != .deleting else {
            errorMessage = String(localized: "Cleanup history cannot be reset while a deletion is being reconciled.")
            return false
        }
        do {
            try repository.resetHistory()
            cleanupMetricsStore.reset()
            lifetimeCleanupSummary = .zero
            lastCleanupSummary = .zero
            try refreshDecisionCache()
            activeSession = nil
            actions = []
            selectedGroupIDs.removeAll()
            try await rebuildGroupsOffMain()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func finishSwiping() async {
        guard let session = activeSession else { return }
        let candidates = actions.filter { $0.isApplied && $0.decision == .deletePending }.map(\.assetIdentifier)
        if candidates.isEmpty {
            do {
                try await finalizeSession(session)
                lastCleanupSummary = cleanupMetricsStore.summary(for: session.identifier)
                route = .completion
            } catch {
                errorMessage = error.localizedDescription
            }
        } else {
            reviewCurrentBatch()
        }
    }

    private func finalizeSession(_ session: CleanupSessionRecord, markGroupsCompleted: Bool = true) async throws {
        let allGroups = monthGroups + locationGroups + typeGroups
        if markGroupsCompleted {
            for key in session.selectedGroupKeys {
                let label = allGroups.first(where: { $0.key.id == key })?.title ?? key
                try repository.markCompleted(groupKey: key, label: label)
            }
        }
        try repository.finish(session: session)
        activeSession = nil
        actions = []
        // A finished session must not leave its groups selected. Otherwise a
        // later tap on the same group is interpreted as a deselection, making
        // it impossible to continue an unfinished group after a partial
        // review deletion.
        selectedGroupIDs.removeAll()
        do {
            try await rebuildGroupsOffMain()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func refreshDecisionCache() throws {
        decisionsByAssetID = try repository.allDecisions()
    }

    private func rebuildGroupsOffMain(expectedReloadGeneration: Int? = nil) async throws {
        groupBuildGeneration += 1
        let generation = groupBuildGeneration
        let completions = try completionSnapshots()
        let assets = assets
        let decisions = decisionsByAssetID
        let bucketLocations = bucketLocations
        let analysis = analysisResults
        let similarIDs = Set(similarClusters.flatMap(\.assetIDs))
        let result = await Task.detached(priority: .userInitiated) {
            Self.buildGroups(
                assets: assets,
                decisions: decisions,
                completions: completions,
                bucketLocations: bucketLocations,
                analysis: analysis,
                similarIDs: similarIDs
            )
        }.value
        guard !Task.isCancelled,
              generation == groupBuildGeneration,
              expectedReloadGeneration == nil || expectedReloadGeneration == libraryReloadGeneration,
              permission.canRead else { return }
        monthGroups = result.month
        locationGroups = result.location
        typeGroups = result.type
    }

    private func completionSnapshots() throws -> [String: GroupCompletionSnapshot] {
        let records = try repository.completedGroups()
        var snapshots: [String: GroupCompletionSnapshot] = [:]
        snapshots.reserveCapacity(records.count)
        for (key, record) in records {
            snapshots[key] = GroupCompletionSnapshot(groupKey: record.groupKey, lastLabel: record.lastLabel)
        }
        return snapshots
    }

    nonisolated private static func buildGroups(
        assets: [PhotoAssetDescriptor],
        decisions: [String: AssetDecision],
        completions: [String: GroupCompletionSnapshot],
        bucketLocations: [String: ResolvedLocation],
        analysis: [String: MediaAnalysisResult],
        similarIDs: Set<String>
    ) -> GroupBuildResult {
        GroupBuildResult(
            month: buildMonthGroups(assets: assets, decisions: decisions, completions: completions),
            location: buildLocationGroups(
                assets: assets,
                decisions: decisions,
                completions: completions,
                bucketLocations: bucketLocations
            ),
            type: buildTypeGroups(assets: assets, decisions: decisions, analysis: analysis, similarIDs: similarIDs)
        )
    }

    nonisolated static func buildTypeGroups(assets: [PhotoAssetDescriptor], decisions: [String: AssetDecision],
                                          analysis: [String: MediaAnalysisResult], similarIDs: Set<String>) -> [MediaGroup] {
        MediaTypeCategory.allCases.compactMap { category in
            let members = assets.filter { category.contains($0, analysis: analysis[$0.id], similarIDs: similarIDs) }
            guard !members.isEmpty else { return nil }
            let unresolved = members.filter { decisions[$0.id] == nil }.count
            return MediaGroup(key: category.key, title: category.title, subtitle: itemCountText(members.count),
                              assetIDs: members.map(\.id), unresolvedCount: unresolved,
                              thumbnailAssetID: members.first?.id, isCleaned: unresolved == 0)
        }
    }

    private func routeCurrentWorkUnit() {
        guard let session = activeSession, session.status == .swiping else { return }
        route = session.unit(at: session.cursor)?.unit.kind == .comparison ? .similarComparison : .cleanup
    }

    private func advanceAfterDecision() async {
        guard let session = activeSession else { return }
        if session.cursor >= session.orderedAssetIDs.count { await finishSwiping() }
        else { routeCurrentWorkUnit(); preheatAroundCurrentAsset() }
    }

    private func cancelTypeAnalysis() {
        typeAnalysisGeneration += 1
        typeAnalysisTask?.cancel()
        typeAnalysisTask = nil
        analysisCacheFlushTask?.cancel()
        analysisCacheFlushTask = nil
        _ = flushAnalysisCache()
        isAnalyzingTypes = false
    }

    @discardableResult
    private func flushAnalysisCache() -> Bool {
        guard !analysisCacheBuffer.isEmpty else { return true }
        let entries = analysisCacheBuffer.values.filter { entry in
            permission.canRead && assetIndex[entry.asset.id].map {
                MediaAnalysisResult.signature(for: $0) == MediaAnalysisResult.signature(for: entry.asset)
            } == true
        }
        do {
            try repository.cacheAnalysis(entries)
            analysisCacheBuffer.removeAll(keepingCapacity: true)
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    private func bufferAnalysis(_ result: MediaAnalysisResult, for asset: PhotoAssetDescriptor, generation: Int) -> Bool {
        analysisCacheBuffer[asset.id] = MediaAnalysisCacheEntry(asset: asset, result: result)
        if analysisCacheBuffer.count >= 25 { return flushAnalysisCache() }
        if analysisCacheFlushTask == nil {
            analysisCacheFlushTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self, generation == typeAnalysisGeneration else { return }
                analysisCacheFlushTask = nil
                if !flushAnalysisCache() { typeAnalysisTask?.cancel() }
            }
        }
        return true
    }

    private func resetAnalysisWarnings() {
        unavailableSimilarityCount = 0
        for result in analysisResults.values { adjustAnalysisWarnings(result, delta: 1) }
        publishAnalysisWarnings()
    }

    private func adjustAnalysisWarnings(_ result: MediaAnalysisResult, delta: Int) {
        if result.similarityUnavailable { unavailableSimilarityCount += delta }
    }

    private func publishAnalysisWarnings() {
        hasUnavailableSimilarity = unavailableSimilarityCount > 0
    }

    private func publishTypeGroups(generation: Int) async {
        groupBuildGeneration += 1
        let groupGeneration = groupBuildGeneration
        let snapshot = assets, decisions = decisionsByAssetID, results = analysisResults
        let similarIDs = Set(similarClusters.flatMap(\.assetIDs))
        let groups = await Task.detached(priority: .utility) {
            let interval = AnalysisPerformance.begin(.groups)
            defer { AnalysisPerformance.end(.groups, interval) }
            return Self.buildTypeGroups(assets: snapshot, decisions: decisions, analysis: results, similarIDs: similarIDs)
        }.value
        guard !Task.isCancelled, generation == typeAnalysisGeneration, groupGeneration == groupBuildGeneration,
              permission.canRead, grouping == .type, route == .dashboard else { return }
        typeGroups = groups
    }

    func setForeground(_ active: Bool) {
        isForeground = active
        if !active { cancelTypeAnalysis() }
    }

    private func startTypeAnalysis() {
        guard isForeground, !isLoading, grouping == .type, route == .dashboard, permission.canRead, !assets.isEmpty else { return }
        cancelTypeAnalysis()
        let generation = typeAnalysisGeneration
        let snapshot = assets
        let photos = snapshot.filter { $0.mediaKind != .video }
        let pending = photos.filter { analysisResults[$0.id]?.isComplete != true }
        typeAnalysisTotal = photos.count
        typeAnalysisCompleted = photos.count - pending.count
        isAnalyzingTypes = !pending.isEmpty
        typeAnalysisTask = Task { [weak self] in
            guard let self else { return }
            let interval = AnalysisPerformance.begin(.scan)
            defer {
                AnalysisPerformance.end(.scan, interval)
                if generation == typeAnalysisGeneration {
                    _ = flushAnalysisCache()
                    isAnalyzingTypes = false
                }
            }
            guard !pending.isEmpty else { return }
            await analysisClient.prepare()
            guard !Task.isCancelled, generation == typeAnalysisGeneration else { return }
            let client = analysisClient
            let previouslyCompleted = photos.count - pending.count
            var unavailable = pending.count
            var processed = 0
            var fingerprintsChanged = false
            let clock = ContinuousClock()
            var lastPublication = clock.now
            await withTaskGroup(of: (PhotoAssetDescriptor, MediaAnalysisResult).self) { group in
                var next = 0, inFlight = 0
                while next < pending.count || inFlight > 0 {
                    guard !Task.isCancelled, generation == typeAnalysisGeneration, permission.canRead else {
                        group.cancelAll(); return
                    }
                    let limit = max(1, min(2, await client.concurrencyLimit()))
                    guard !Task.isCancelled, generation == typeAnalysisGeneration else { group.cancelAll(); return }
                    while next < pending.count && inFlight < limit {
                        let asset = pending[next], cached = analysisResults[pending[next].id]
                        group.addTask(priority: .utility) { (asset, await client.analyze(asset, cachedResult: cached)) }
                        next += 1; inFlight += 1
                    }
                    guard let (asset, analyzed) = await group.next() else { break }
                    inFlight -= 1
                    guard !Task.isCancelled, generation == typeAnalysisGeneration, permission.canRead,
                          assetIndex[asset.id].map({ MediaAnalysisResult.signature(for: $0) }) == MediaAnalysisResult.signature(for: asset) else {
                        group.cancelAll(); return
                    }
                    var result = analyzed
                    let previous = analysisResults[asset.id]
                    if let previous {
                        result.isLarge = result.isLarge ?? previous.isLarge
                        result.featurePrint = result.featurePrint ?? previous.featurePrint
                        result.perceptualHash = result.perceptualHash ?? previous.perceptualHash
                        adjustAnalysisWarnings(previous, delta: -1)
                    }
                    adjustAnalysisWarnings(result, delta: 1)
                    fingerprintsChanged = fingerprintsChanged || result.featurePrint != previous?.featurePrint || result.perceptualHash != previous?.perceptualHash
                    analysisResults[asset.id] = result
                    processed += 1
                    if result.isComplete { unavailable -= 1 }
                    guard bufferAnalysis(result, for: asset, generation: generation) else { group.cancelAll(); return }
                    let milestone = processed == 1 || (processed >= 8 && processed.nonzeroBitCount == 1) || processed == pending.count
                    if milestone || lastPublication.duration(to: clock.now) >= .seconds(1) {
                        typeAnalysisCompleted = previouslyCompleted + processed
                        typeAnalysisUnavailableCount = unavailable
                        publishAnalysisWarnings()
                        if milestone && fingerprintsChanged {
                            let clusters = await client.clusters(assets: snapshot, results: analysisResults)
                            guard !Task.isCancelled, generation == typeAnalysisGeneration else { group.cancelAll(); return }
                            similarClusters = clusters
                            fingerprintsChanged = false
                        }
                        await publishTypeGroups(generation: generation)
                        lastPublication = clock.now
                    }
                }
            }
        }
    }

    nonisolated private static func buildMonthGroups(
        assets: [PhotoAssetDescriptor],
        decisions: [String: AssetDecision],
        completions: [String: GroupCompletionSnapshot]
    ) -> [MediaGroup] {
        let grouped = MonthGrouping.group(assets)
        var groups = grouped.map { key, values in
            let groupKey = GroupKey(kind: .month, value: key)
            let unresolved = values.filter { decisions[$0.id] == nil }.count
            return MediaGroup(
                key: groupKey,
                title: MonthGrouping.title(for: key),
                subtitle: itemCountText(values.count),
                assetIDs: values.map(\.id),
                unresolvedCount: unresolved,
                thumbnailAssetID: values.first?.id,
                isCleaned: !values.isEmpty && unresolved == 0
            )
        }
        let currentKeys = Set(groups.map(\.key.id))
        for record in completions.values where record.groupKey.hasPrefix("month:") && !currentKeys.contains(record.groupKey) {
            guard let key = GroupKey(rawValue: record.groupKey) else { continue }
            groups.append(MediaGroup(
                key: key,
                title: record.lastLabel,
                subtitle: itemCountText(0),
                assetIDs: [],
                unresolvedCount: 0,
                thumbnailAssetID: nil,
                isCleaned: true
            ))
        }
        return groups.sorted {
            if $0.key.value == MonthGrouping.unknownKey { return false }
            if $1.key.value == MonthGrouping.unknownKey { return true }
            return $0.key.value > $1.key.value
        }
    }

    nonisolated private static func buildLocationGroups(
        assets: [PhotoAssetDescriptor],
        decisions: [String: AssetDecision],
        completions: [String: GroupCompletionSnapshot],
        bucketLocations: [String: ResolvedLocation]
    ) -> [MediaGroup] {
        var grouped: [String: (ResolvedLocation?, [PhotoAssetDescriptor])] = [:]
        for asset in assets {
            guard let coordinate = asset.coordinate else {
                grouped["no-location", default: (nil, [])].1.append(asset)
                continue
            }
            let bucket = LocationBucketing.key(for: coordinate)
            if let resolved = bucketLocations[bucket] {
                if resolved.city == nil && resolved.country == nil {
                    grouped["unresolved", default: (nil, [])].1.append(asset)
                } else {
                    let key = "resolved:\(resolved.normalizedKey)"
                    if grouped[key] == nil { grouped[key] = (resolved, []) }
                    grouped[key]?.1.append(asset)
                }
            } else {
                grouped["unresolved", default: (nil, [])].1.append(asset)
            }
        }

        var groups = grouped.map { value, pair in
            let key = GroupKey(kind: .location, value: value)
            let items = pair.1
            let unresolved = items.filter { decisions[$0.id] == nil }.count
            let title: String
            let subtitle: String?
            if value == "no-location" {
                title = String(localized: "No Location")
                subtitle = nil
            } else if value == "unresolved" {
                title = String(localized: "Unresolved Location")
                subtitle = String(localized: "Connect to resolve place names")
            } else {
                title = pair.0?.title ?? String(localized: "Unresolved Location")
                subtitle = pair.0?.subtitle
            }
            return MediaGroup(
                key: key,
                title: title,
                subtitle: subtitle ?? itemCountText(items.count),
                assetIDs: items.map(\.id),
                unresolvedCount: unresolved,
                thumbnailAssetID: items.first?.id,
                isCleaned: !items.isEmpty && unresolved == 0
            )
        }

        let currentKeys = Set(groups.map(\.key.id))
        for record in completions.values where record.groupKey.hasPrefix("location:") && record.groupKey != "location:unresolved" && !currentKeys.contains(record.groupKey) {
            guard let key = GroupKey(rawValue: record.groupKey) else { continue }
            groups.append(MediaGroup(
                key: key,
                title: record.lastLabel,
                subtitle: itemCountText(0),
                assetIDs: [],
                unresolvedCount: 0,
                thumbnailAssetID: nil,
                isCleaned: true
            ))
        }
        return groups.sorted {
            let lhsFallback = $0.key.value == "no-location" || $0.key.value == "unresolved"
            let rhsFallback = $1.key.value == "no-location" || $1.key.value == "unresolved"
            if lhsFallback != rhsFallback { return !lhsFallback }
            if $0.totalCount != $1.totalCount { return $0.totalCount > $1.totalCount }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    private func loadCachedLocations() throws {
        let localeIdentifier = Locale.current.identifier
        if bucketLocationLocaleIdentifier != localeIdentifier {
            bucketLocations.removeAll()
            bucketLocationLocaleIdentifier = localeIdentifier
        }
        let buckets = Set(assets.compactMap(\.coordinate).map(LocationBucketing.key))
        let missing = buckets.subtracting(bucketLocations.keys)
        bucketLocations.merge(
            try repository.cachedLocations(for: missing, localeIdentifier: localeIdentifier),
            uniquingKeysWith: { _, latest in latest }
        )
    }

    nonisolated private static func itemCountText(_ count: Int) -> String {
        count == 1 ? String(localized: "1 item") : String(localized: "\(count) items")
    }

    private func resolveMissingLocations() {
        guard grouping == .location, route == .dashboard, permission.canRead else { return }
        locationResolutionTask?.cancel()
        let buckets = Dictionary(grouping: assets.compactMap { asset -> (String, GeoCoordinate)? in
            guard let coordinate = asset.coordinate else { return nil }
            return (LocationBucketing.key(for: coordinate), coordinate)
        }, by: { $0.0 })
        let missing = buckets.keys.filter { bucketLocations[$0] == nil }.sorted { lhs, rhs in
            let lhsCount = buckets[lhs]?.count ?? 0
            let rhsCount = buckets[rhs]?.count ?? 0
            return lhsCount == rhsCount ? lhs < rhs : lhsCount > rhsCount
        }
        locationResolutionTask = Task { [weak self] in
            guard let self else { return }
            var resolvedCount = 0
            for bucket in missing {
                guard !Task.isCancelled, grouping == .location, route == .dashboard,
                      let coordinate = buckets[bucket]?.first?.1 else { return }
                do {
                    let location = try await locationResolver.resolve(coordinate)
                        ?? ResolvedLocation(city: nil, country: nil)
                    guard !Task.isCancelled, grouping == .location, route == .dashboard else { return }
                    try repository.cacheLocation(location, for: bucket)
                    bucketLocations[bucket] = location
                    resolvedCount += 1
                    if resolvedCount == 1 || resolvedCount.isMultiple(of: 8) {
                        try? await rebuildGroupsOffMain()
                    }
                } catch is CancellationError {
                    return
                } catch {
                    // Leave transient failures uncached so a later refresh can retry them.
                }
            }
            if resolvedCount > 1 && !resolvedCount.isMultiple(of: 8) {
                try? await rebuildGroupsOffMain()
            }
        }
    }

    private func preheatAroundCurrentAsset() {
        guard let session = activeSession else { return }
        guard currentComparison == nil else { return }
        let lower = max(0, session.cursor - 1)
        let upper = min(session.orderedAssetIDs.count, session.cursor + 4)
        guard lower < upper else { return }
        previewProvider.startCaching(
            identifiers: Array(session.orderedAssetIDs[lower..<upper]),
            targetSize: PreviewImageConfiguration.cardTargetSize,
            kind: .active
        )
    }

    func preheatComparison(targetSize: CGSize) {
        guard permission.canRead, route == .similarComparison,
              activeSession?.status == .swiping, let unit = currentComparison else { return }
        previewProvider.startCaching(
            identifiers: Array((unit.assetIDs + unit.contextAssetIDs).prefix(12)),
            targetSize: targetSize,
            kind: .comparison
        )
    }

    private func reconcileSessionState(purgeMissingDecisions: Bool) throws {
        // Only crash recovery may change the submitted selection of a deleting session.
        guard !isDeleting, activeSession?.status != .deleting else { return }
        let accessible = Set(assets.map(\.id))
        if purgeMissingDecisions {
            let staleDecisions = Set(try repository.allDecisions().keys).subtracting(accessible)
            if !staleDecisions.isEmpty {
                try repository.removeDecisions(for: staleDecisions)
            }
        }

        guard let session = activeSession else { return }
        let existingActions = try repository.actions(for: session.identifier)
        let validActions = existingActions
            .filter { accessible.contains($0.assetIdentifier) }
            .sorted { $0.sequence < $1.sequence }
        let actionIDs = Set(validActions.map(\.assetIdentifier))
        let remaining = session.orderedAssetIDs.filter { accessible.contains($0) && !actionIDs.contains($0) }
        let reconciledOrder = validActions.map(\.assetIdentifier) + remaining
        let reconciledCursor = validActions.prefix { $0.isApplied }.count
        let reviewSelection = session.reviewSelectedIDs.filter(accessible.contains)
        let actionsNeedReplacement = validActions.count != existingActions.count
            || validActions.enumerated().contains { $0.offset != $0.element.sequence }
        let originalPlan = session.workPlan
        var reconciledPlan = originalPlan
        if var plan = reconciledPlan {
            plan.units = plan.units.compactMap { unit in
                var unit = unit
                unit.assetIDs = unit.assetIDs.filter(accessible.contains)
                unit.contextAssetIDs = unit.contextAssetIDs.filter(accessible.contains)
                guard !unit.assetIDs.isEmpty else { return nil }
                if unit.assetIDs.count + unit.contextAssetIDs.count < 2 { unit.kind = .swipe }
                return unit
            }
            plan.draftDeleteIDs.formIntersection(Set(plan.assetIDs))
            reconciledPlan = plan
        }
        guard reconciledOrder != session.orderedAssetIDs
                || session.cursor != reconciledCursor
                || reviewSelection != session.reviewSelectedIDs
                || actionsNeedReplacement
                || reconciledPlan != originalPlan else { return }

        session.orderedAssetIDs = reconciledOrder
        session.cursor = reconciledCursor
        session.reviewSelectedIDs = reviewSelection
        session.workPlan = reconciledPlan
        try repository.replaceActions(
            sessionIdentifier: session.identifier,
            actions: validActions.enumerated().map { index, action in
                CleanupActionSnapshot(
                    sequence: index,
                    assetIdentifier: action.assetIdentifier,
                    decision: action.decision,
                    isApplied: action.isApplied
                )
            }
        )
        actions = try repository.actions(for: session.identifier)
    }

    private func recoverDeletingSessionIfPossible() async throws {
        guard !isDeleting, permission == .full,
              let session = activeSession,
              session.status == .deleting else { return }

        let accessible = Set(assets.map(\.id))
        let submitted = Set(session.reviewSelectedIDs)
        let fullyReviewed = session.cursor >= session.orderedAssetIDs.count
        let stillPresent = submitted.intersection(accessible)
        let confirmedMissing = submitted.subtracting(accessible)
        if !confirmedMissing.isEmpty {
            cleanupMetricsStore.record(sessionID: session.identifier, ids: Array(confirmedMissing), estimatedBytes: [:])
            lifetimeCleanupSummary = cleanupMetricsStore.summary()
            try repository.removeDecisions(for: confirmedMissing)
        }

        if stillPresent.isEmpty {
            try await finalizeSession(session, markGroupsCompleted: fullyReviewed)
            if fullyReviewed {
                lastCleanupSummary = cleanupMetricsStore.summary(for: session.identifier)
            }
            route = fullyReviewed ? .completion : .dashboard
        } else {
            session.reviewSelectedIDs = session.reviewSelectedIDs.filter(stillPresent.contains)
            session.status = .reviewing
            try repository.save()
            route = .review
        }
    }
}
