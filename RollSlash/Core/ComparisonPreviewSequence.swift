import Foundation

/// Navigation uses the frozen session unit, never a changing analysis cluster.
struct ComparisonPreviewSequence {
    let unit: CleanupWorkUnit

    func accessibleIdentifiers(in library: Set<String>, currentUnit: CleanupWorkUnit) -> Set<String> {
        guard currentUnit.kind == .comparison, currentUnit.clusterID == unit.clusterID else { return [] }
        return library.intersection(currentUnit.assetIDs + currentUnit.contextAssetIDs)
            .intersection(unit.assetIDs + unit.contextAssetIDs)
    }

    func identifiers(accessible: Set<String>) -> [String] {
        (unit.assetIDs + unit.contextAssetIDs).filter { accessible.contains($0) }
    }

    func neighbor(of id: String, step: Int, accessible: Set<String>) -> String? {
        let ids = identifiers(accessible: accessible)
        guard let index = ids.firstIndex(of: id), ids.indices.contains(index + step) else { return nil }
        return ids[index + step]
    }

    func replacement(for id: String, accessible: Set<String>) -> String? {
        let ordered = unit.assetIDs + unit.contextAssetIDs
        let surviving = identifiers(accessible: accessible)
        guard !surviving.contains(id) else { return id }
        guard let index = ordered.firstIndex(of: id) else { return surviving.first }
        return ordered.dropFirst(index).first { accessible.contains($0) } ?? surviving.last
    }
}
