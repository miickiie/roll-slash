import Foundation
import Observation
import SwiftData

private struct GroupCompletionSnapshot: Sendable {
    let groupKey: String
    let lastLabel: String
}

private struct GroupBuildResult: Sendable {
    let month: [MediaGroup]
    let location: [MediaGroup]
}

@MainActor
@Observable
final class AppModel {
    var route: AppRoute = .onboarding
    var permission: PhotoPermission = .notDetermined
    var grouping: GroupKind = .month {
        didSet {
            selectedGroupIDs.removeAll()
            if grouping == .location { resolveMissingLocations() }
        }
    }
    var monthGroups: [MediaGroup] = []
    var locationGroups: [MediaGroup] = []
    var selectedGroupIDs: Set<String> = []
    var assets: [PhotoAssetDescriptor] = []
    private(set) var assetIndex: [String: PhotoAssetDescriptor] = [:]
    private(set) var decisionsByAssetID: [String: AssetDecision] = [:]
    var activeSession: CleanupSessionRecord?
    var actions: [CleanupActionRecord] = []
    var isLoading = false
    var isDeleting = false
    var errorMessage: String?
    var showingSettings = false

    @ObservationIgnored private let photoLibrary: any PhotoLibraryClient
    @ObservationIgnored let previewProvider: any MediaPreviewProvider
    @ObservationIgnored private let locationResolver: any LocationResolver
    @ObservationIgnored private let repository: any CleanupRepository
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var bucketLocations: [String: ResolvedLocation] = [:]
    @ObservationIgnored private var locationResolutionTask: Task<Void, Never>?

    init(
        photoLibrary: any PhotoLibraryClient,
        previewProvider: any MediaPreviewProvider,
        locationResolver: any LocationResolver,
        modelContainer: ModelContainer
    ) {
        self.photoLibrary = photoLibrary
        self.previewProvider = previewProvider
        self.locationResolver = locationResolver
        self.repository = SwiftDataCleanupRepository(container: modelContainer)
    }

    var visibleGroups: [MediaGroup] {
        grouping == .month ? monthGroups : locationGroups
    }

    var selectedGroups: [MediaGroup] {
        visibleGroups.filter { selectedGroupIDs.contains($0.id) }
    }

    var selectedCandidateCount: Int {
        return selectedGroups.reduce(into: Set<String>()) { identifiers, group in
            if group.isCleaned {
                identifiers.formUnion(group.assetIDs)
            } else {
                identifiers.formUnion(group.assetIDs.filter { decisionsByAssetID[$0] == nil })
            }
        }.count
    }

    var selectedUnresolvedCount: Int {
        selectedCandidateCount
    }

    var currentAsset: PhotoAssetDescriptor? {
        guard let session = activeSession,
              session.cursor < session.orderedAssetIDs.count else { return nil }
        let identifier = session.orderedAssetIDs[session.cursor]
        return assetIndex[identifier]
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

    var isPartialAccess: Bool { permission == .limited }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        photoLibrary.onLibraryChange = { [weak self] in
            guard let self, !self.isDeleting else { return }
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
            if permission.canRead { await reloadLibrary() }
        }
    }

    func requestAccess() async {
        UserDefaults.standard.set(true, forKey: "hasSeenOnboarding")
        permission = await photoLibrary.requestAuthorization()
        route = .dashboard
        if permission.canRead { await reloadLibrary() }
    }

    func refreshAuthorization() async {
        guard hasStarted else { return }
        let previousPermission = permission
        permission = photoLibrary.authorizationStatus()
        if permission.canRead {
            await reloadLibrary()
        } else if previousPermission.canRead || !assets.isEmpty {
            locationResolutionTask?.cancel()
            previewProvider.stopCachingAll()
            assets = []
            assetIndex = [:]
            monthGroups = []
            locationGroups = []
            selectedGroupIDs.removeAll()
            route = .dashboard
        }
    }

    func continueWithoutAccess() {
        UserDefaults.standard.set(true, forKey: "hasSeenOnboarding")
        permission = photoLibrary.authorizationStatus()
        route = .dashboard
    }

    func reloadLibrary() async {
        guard permission.canRead else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let fetchedAssets = try await photoLibrary.fetchAssets()
            assets = fetchedAssets
            assetIndex = Dictionary(uniqueKeysWithValues: fetchedAssets.map { ($0.id, $0) })
            try refreshDecisionCache()
            try recoverDeletingSessionIfPossible()
            try reconcileSessionState(purgeMissingDecisions: permission == .full)
            try refreshDecisionCache()
            try loadCachedLocations()
            try await rebuildGroupsOffMain()
            if grouping == .location { resolveMissingLocations() }
            if let session = activeSession,
               session.status == .swiping,
               session.cursor >= session.orderedAssetIDs.count {
                finishSwiping()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func toggleSelection(_ group: MediaGroup) {
        if selectedGroupIDs.contains(group.id) {
            selectedGroupIDs.remove(group.id)
        } else {
            selectedGroupIDs.insert(group.id)
        }
    }

    func beginSelectedCleanup() {
        guard activeSession == nil else {
            resumeSession()
            return
        }
        let identifiers = selectedGroups.reduce(into: Set<String>()) { identifiers, group in
            if group.isCleaned {
                identifiers.formUnion(group.assetIDs)
            } else {
                identifiers.formUnion(group.assetIDs.filter { decisionsByAssetID[$0] == nil })
            }
        }
        let ordered = assets
            .filter { identifiers.contains($0.id) }
            .sorted { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }
            .map(\.id)
        guard !ordered.isEmpty else { return }

        do {
            let keys = selectedGroups.map(\.key.id)
            activeSession = try repository.createSession(
                groupKind: grouping,
                selectedGroupKeys: keys,
                orderedAssetIDs: ordered
            )
            actions = []
            route = .cleanup
            preheatAroundCurrentAsset()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func resumeSession() {
        guard let session = activeSession else { return }
        switch session.status {
        case .swiping: route = .cleanup
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

    func discardActiveSession() {
        guard let session = activeSession else { return }
        do {
            try repository.discard(session: session)
            try refreshDecisionCache()
            activeSession = nil
            actions = []
            selectedGroupIDs.removeAll()
            try rebuildGroups()
            route = .dashboard
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func decide(_ decision: AssetDecision) {
        guard let session = activeSession,
              session.status == .swiping,
              session.cursor < session.orderedAssetIDs.count else { return }
        let assetIdentifier = session.orderedAssetIDs[session.cursor]
        do {
            try repository.trimActions(sessionIdentifier: session.identifier, from: session.cursor)
            try repository.appendAction(
                sessionIdentifier: session.identifier,
                sequence: session.cursor,
                assetIdentifier: assetIdentifier,
                decision: decision
            )
            try repository.setDecision(decision, for: assetIdentifier, sessionIdentifier: session.identifier)
            decisionsByAssetID[assetIdentifier] = decision
            session.cursor += 1
            try repository.save()
            actions = try repository.actions(for: session.identifier)
            if session.cursor == session.orderedAssetIDs.count {
                finishSwiping()
            } else {
                preheatAroundCurrentAsset()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func undo() {
        guard let session = activeSession, session.status == .swiping, session.cursor > 0 else { return }
        let sequence = session.cursor - 1
        guard let action = actions.first(where: { $0.sequence == sequence }) else { return }
        do {
            action.isApplied = false
            try repository.restoreOriginalDecision(for: action.assetIdentifier, in: session)
            try refreshDecisionCache()
            session.cursor -= 1
            try repository.save()
            actions = try repository.actions(for: session.identifier)
            preheatAroundCurrentAsset()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func redo() {
        guard let session = activeSession, session.status == .swiping,
              let action = actions.first(where: { $0.sequence == session.cursor && !$0.isApplied }) else { return }
        do {
            action.isApplied = true
            try repository.setDecision(action.decision, for: action.assetIdentifier, sessionIdentifier: session.identifier)
            decisionsByAssetID[action.assetIdentifier] = action.decision
            session.cursor += 1
            try repository.save()
            actions = try repository.actions(for: session.identifier)
            if session.cursor == session.orderedAssetIDs.count {
                finishSwiping()
            } else {
                preheatAroundCurrentAsset()
            }
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

    func toggleReviewSelection(_ identifier: String) {
        guard let session = activeSession,
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
        guard let session = activeSession else { return }
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
        guard let session = activeSession else { return }
        do {
            try repository.updateReviewSelection(session: session, candidateIDs: reviewCandidateIDs, selectedIDs: [])
            try refreshDecisionCache()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func undoLastSwipeFromReview() {
        guard let session = activeSession, session.status == .reviewing, session.cursor > 0 else { return }
        do {
            let applied = actions.filter(\.isApplied)
            session.status = .swiping
            try repository.updateReviewSelection(
                session: session,
                candidateIDs: applied.map(\.assetIdentifier),
                selectedIDs: Set(applied.filter { $0.decision == .deletePending }.map(\.assetIdentifier))
            )
            route = .cleanup
            undo()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func commitDeletion() async {
        guard let session = activeSession else { return }
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

        if !selected.isEmpty {
            do {
                let deletedIdentifiers = try await photoLibrary.deleteAssets(with: selected)
                guard deletedIdentifiers == Set(selected) else {
                    throw PhotoLibraryDeletionError.inaccessibleAssets(
                        requested: Set(selected).count,
                        accessible: deletedIdentifiers.count
                    )
                }
            } catch {
                guard activeSession?.identifier == sessionID else { return }
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
            try finalizeSession(session, markGroupsCompleted: fullyReviewed)
            await reloadLibrary()
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
                try? rebuildGroups()
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
    func resetHistory() -> Bool {
        guard activeSession?.status != .deleting else {
            errorMessage = String(localized: "Cleanup history cannot be reset while a deletion is being reconciled.")
            return false
        }
        do {
            try repository.resetHistory()
            try refreshDecisionCache()
            activeSession = nil
            actions = []
            selectedGroupIDs.removeAll()
            try rebuildGroups()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func finishSwiping() {
        guard let session = activeSession else { return }
        let candidates = actions.filter { $0.isApplied && $0.decision == .deletePending }.map(\.assetIdentifier)
        if candidates.isEmpty {
            do {
                try finalizeSession(session)
                route = .completion
            } catch {
                errorMessage = error.localizedDescription
            }
        } else {
            reviewCurrentBatch()
        }
    }

    private func finalizeSession(_ session: CleanupSessionRecord, markGroupsCompleted: Bool = true) throws {
        let allGroups = monthGroups + locationGroups
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
            try rebuildGroups()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func refreshDecisionCache() throws {
        decisionsByAssetID = try repository.allDecisions()
    }

    private func rebuildGroups() throws {
        let completions = try completionSnapshots()
        let result = Self.buildGroups(
            assets: assets,
            decisions: decisionsByAssetID,
            completions: completions,
            bucketLocations: bucketLocations
        )
        monthGroups = result.month
        locationGroups = result.location
    }

    private func rebuildGroupsOffMain() async throws {
        let completions = try completionSnapshots()
        let assets = assets
        let decisions = decisionsByAssetID
        let bucketLocations = bucketLocations
        let result = await Task.detached(priority: .userInitiated) {
            Self.buildGroups(
                assets: assets,
                decisions: decisions,
                completions: completions,
                bucketLocations: bucketLocations
            )
        }.value
        guard !Task.isCancelled else { return }
        monthGroups = result.month
        locationGroups = result.location
    }

    private func completionSnapshots() throws -> [String: GroupCompletionSnapshot] {
        try repository.completedGroups().reduce(into: [:]) { result, record in
            result[record.groupKey] = GroupCompletionSnapshot(groupKey: record.groupKey, lastLabel: record.lastLabel)
        }
    }

    private static func buildGroups(
        assets: [PhotoAssetDescriptor],
        decisions: [String: AssetDecision],
        completions: [String: GroupCompletionSnapshot],
        bucketLocations: [String: ResolvedLocation]
    ) -> GroupBuildResult {
        GroupBuildResult(
            month: buildMonthGroups(assets: assets, decisions: decisions, completions: completions),
            location: buildLocationGroups(
                assets: assets,
                decisions: decisions,
                completions: completions,
                bucketLocations: bucketLocations
            )
        )
    }

    private static func buildMonthGroups(
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
                isCleaned: !values.isEmpty && unresolved == 0,
                sortDate: values.compactMap(\.creationDate).max()
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
                isCleaned: true,
                sortDate: nil
            ))
        }
        return groups.sorted {
            if $0.key.value == MonthGrouping.unknownKey { return false }
            if $1.key.value == MonthGrouping.unknownKey { return true }
            return $0.key.value > $1.key.value
        }
    }

    private static func buildLocationGroups(
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
                isCleaned: !items.isEmpty && unresolved == 0,
                sortDate: nil
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
                isCleaned: true,
                sortDate: nil
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
        let buckets = Set(assets.compactMap(\.coordinate).map(LocationBucketing.key))
        for bucket in buckets.subtracting(bucketLocations.keys) {
            if let location = try repository.cachedLocation(for: bucket) {
                bucketLocations[bucket] = location
            }
        }
    }

    private static func itemCountText(_ count: Int) -> String {
        count == 1 ? String(localized: "1 item") : String(localized: "\(count) items")
    }

    private func resolveMissingLocations() {
        guard grouping == .location else { return }
        locationResolutionTask?.cancel()
        let buckets = Dictionary(grouping: assets.compactMap { asset -> (String, GeoCoordinate)? in
            guard let coordinate = asset.coordinate else { return nil }
            return (LocationBucketing.key(for: coordinate), coordinate)
        }, by: { $0.0 })
        let missing = buckets.keys.filter { bucketLocations[$0] == nil }.sorted()
        locationResolutionTask = Task { [weak self] in
            guard let self else { return }
            for batchStart in stride(from: 0, to: missing.count, by: 60) {
                var changed = false
                let batchEnd = min(batchStart + 60, missing.count)
                for bucket in missing[batchStart..<batchEnd] {
                    guard !Task.isCancelled, let coordinate = buckets[bucket]?.first?.1 else { return }
                    do {
                        let location = try await locationResolver.resolve(coordinate)
                            ?? ResolvedLocation(city: nil, country: nil)
                        bucketLocations[bucket] = location
                        try repository.cacheLocation(location, for: bucket)
                        changed = true
                    } catch {
                        // Leave transient failures uncached so a later refresh can retry them.
                    }
                }
                if changed { try? await rebuildGroupsOffMain() }
                await Task.yield()
            }
        }
    }

    private func preheatAroundCurrentAsset() {
        guard let session = activeSession else { return }
        let lower = max(0, session.cursor - 1)
        let upper = min(session.orderedAssetIDs.count, session.cursor + 4)
        guard lower < upper else { return }
        previewProvider.startCaching(
            identifiers: Array(session.orderedAssetIDs[lower..<upper]),
            targetSize: CGSize(width: 900, height: 1200)
        )
    }

    private func reconcileSessionState(purgeMissingDecisions: Bool) throws {
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
        guard reconciledOrder != session.orderedAssetIDs
                || session.cursor != reconciledCursor
                || reviewSelection != session.reviewSelectedIDs
                || actionsNeedReplacement else { return }

        session.orderedAssetIDs = reconciledOrder
        session.cursor = reconciledCursor
        session.reviewSelectedIDs = reviewSelection
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

    private func recoverDeletingSessionIfPossible() throws {
        guard permission == .full,
              let session = activeSession,
              session.status == .deleting else { return }

        let accessible = Set(assets.map(\.id))
        let submitted = Set(session.reviewSelectedIDs)
        let fullyReviewed = session.cursor >= session.orderedAssetIDs.count
        let stillPresent = submitted.intersection(accessible)
        let confirmedMissing = submitted.subtracting(accessible)
        if !confirmedMissing.isEmpty {
            try repository.removeDecisions(for: confirmedMissing)
        }

        if stillPresent.isEmpty {
            try finalizeSession(session, markGroupsCompleted: fullyReviewed)
            route = fullyReviewed ? .completion : .dashboard
        } else {
            session.reviewSelectedIDs = session.reviewSelectedIDs.filter(stillPresent.contains)
            session.status = .reviewing
            try repository.save()
            route = .review
        }
    }
}
