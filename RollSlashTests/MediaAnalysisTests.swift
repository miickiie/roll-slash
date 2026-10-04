import Foundation
import Photos
import Testing
import Vision
@testable import RollSlash

@Suite("Local media classification")
struct MediaAnalysisTests {
    @Test("large sizing uses the inclusive 20 MB boundary and both Live Photo components")
    func sizeBoundary() {
        #expect(LargePhotoSizing.eligibility(componentBytes: [19_999_999]) == false)
        #expect(LargePhotoSizing.eligibility(componentBytes: [20_000_000]) == true)
        #expect(LargePhotoSizing.eligibility(componentBytes: [18_000_000, 2_000_000]) == true)
        #expect(LargePhotoSizing.eligibility(componentBytes: [18_000_000, nil]) == nil)
        #expect(LargePhotoSizing.eligibility(componentBytes: [20_000_000, nil]) == true)
        #expect(LargePhotoSizing.eligibility(componentBytes: []) == nil)
        let available: Set<Int> = [PHAssetResourceType.photo.rawValue, PHAssetResourceType.fullSizePhoto.rawValue,
                                   PHAssetResourceType.pairedVideo.rawValue, PHAssetResourceType.fullSizePairedVideo.rawValue]
        #expect(LargePhotoSizing.resourceTypes(available: available, isLive: true) ==
                [PHAssetResourceType.fullSizePhoto.rawValue, PHAssetResourceType.fullSizePairedVideo.rawValue])
        #expect(LargePhotoSizing.resourceTypes(available: available, isLive: false) == [PHAssetResourceType.fullSizePhoto.rawValue])
    }

    @Test("feature-print cutoff separates duplicate and near-identical scene fixtures from hard negatives")
    func similarityCalibration() throws {
        let fixtures = try nativeFixtures()
        let ids = ["base", "base", "near", "checker", "document"]
        let prints = try ids.map { id in
            let fixture = try #require(fixtures.first { $0.id == id })
            return try #require(try NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: fixture.featurePrint))
        }
        var distances: [Float] = []
        for print in prints.dropFirst() {
            var distance: Float = 0
            try prints[0].computeDistance(&distance, to: print)
            distances.append(distance)
        }
        #expect(distances[0] <= SimilarPhotoDetection.maximumDistance)
        #expect(distances[1] <= SimilarPhotoDetection.maximumDistance)
        #expect(distances[2] > SimilarPhotoDetection.maximumDistance)
        #expect(distances[3] > SimilarPhotoDetection.maximumDistance)
        let assets = ids.indices.map { asset("image-\($0)") }
        let results = try Dictionary(uniqueKeysWithValues: ids.enumerated().map { index, id in
            let fixture = try #require(fixtures.first { $0.id == id })
            return ("image-\(index)", MediaAnalysisResult(featurePrint: fixture.featurePrint, perceptualHash: fixture.perceptualHash))
        })
        let clusters = SimilarPhotoDetection.clusters(assets: assets, results: results)
        #expect(clusters.count == 1)
        #expect(Set(clusters.first?.assetIDs ?? []) == Set(["image-0", "image-1", "image-2"]))
    }

    @Test("similarity compares every member to its representative rather than chaining")
    func noTransitiveChain() throws {
        let fixtures = try nativeFixtures()
        let ids = ["chain-a", "chain-b", "chain-c"]
        let selected = try ids.map { id in try #require(fixtures.first { $0.id == id }) }
        let observations = try selected.map { try #require(try NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: $0.featurePrint)) }
        var ab: Float = 0, bc: Float = 0, ac: Float = 0
        try observations[0].computeDistance(&ab, to: observations[1])
        try observations[1].computeDistance(&bc, to: observations[2])
        try observations[0].computeDistance(&ac, to: observations[2])
        #expect(ab <= SimilarPhotoDetection.maximumDistance)
        #expect(bc <= SimilarPhotoDetection.maximumDistance)
        #expect(ac > SimilarPhotoDetection.maximumDistance)
        let results = Dictionary(uniqueKeysWithValues: selected.enumerated().map { index, fixture in
            ("chain-\(index)", MediaAnalysisResult(featurePrint: fixture.featurePrint, perceptualHash: fixture.perceptualHash))
        })
        let clusters = SimilarPhotoDetection.clusters(assets: selected.indices.map { asset("chain-\($0)") }, results: results)
        #expect(clusters.map(\.assetIDs) == [["chain-0", "chain-1"]])
        for cluster in clusters {
            let anchor = try #require(cluster.assetIDs.first).split(separator: "-").last.flatMap { Int($0) }!
            for id in cluster.assetIDs.dropFirst() {
                let index = Int(id.split(separator: "-").last!)!
                var distance: Float = 0
                try observations[anchor].computeDistance(&distance, to: observations[index])
                #expect(distance <= SimilarPhotoDetection.maximumDistance)
            }
        }
    }

    @Test("bounded similarity candidates retain exact duplicates after hash collisions")
    func duplicateIndexCollisions() {
        var index = SimilarityCandidateIndex()
        for id in 0..<50 { index.insertRepresentative("id-\(id)", hash: 0, digest: Data([UInt8(id)])) }
        #expect(index.candidates(for: 0).count == 32)
        #expect(!index.candidates(for: 0).contains("id-0"))
        #expect(index.exactRepresentative(for: Data([0])) == "id-0")
    }

    @Test("large hash-collision libraries keep candidate queries bounded")
    func largeCandidateIndex() {
        var index = SimilarityCandidateIndex()
        for id in 0..<50_000 {
            let value = UInt64(id).bigEndian
            let digest = withUnsafeBytes(of: value) { Data($0) }
            index.insertRepresentative("id-\(id)", hash: 0, digest: digest)
        }
        #expect(index.candidates(for: 0).count == 32)
        let first = UInt64(0).bigEndian
        #expect(index.exactRepresentative(for: withUnsafeBytes(of: first) { Data($0) }) == "id-0")
    }

    @MainActor
    @Test("a collapsed Vision backend yields unavailable similarity rather than false matches")
    func safeUnavailableBackend() async {
        let image = SimilarityCalibrationImages.scene(0)
        let result = await Task.detached {
            PhotoKitMediaAnalysisClient.analyzeImage(image, similarityAvailable: false)
        }.value
        #expect(result.featurePrint == nil)
        #expect(result.similarityUnavailable)
        #expect(result.perceptualHash == nil)
        #expect(!result.isComplete)
    }

    @Test("bounded decoded-print reuse preserves canonical matching and invalidates changed or inaccessible prints")
    func reusableMatcher() async throws {
        let fixtures = try nativeFixtures()
        let base = try #require(fixtures.first { $0.id == "base" })
        let checker = try #require(fixtures.first { $0.id == "checker" })
        let assets = (0..<4).map { asset("cached-\($0)") }
        let result = MediaAnalysisResult(featurePrint: base.featurePrint, perceptualHash: base.perceptualHash)
        var results = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, result) })
        let matcher = SimilarPhotoMatcher(capacity: 2)
        let expected = SimilarPhotoDetection.clusters(assets: assets, results: results)
        #expect(await matcher.clusters(assets: Array(assets.reversed()), results: results) == expected)
        #expect(await matcher.decodingCount == 4)
        #expect(await matcher.clusters(assets: assets, results: results) == expected)
        #expect(await matcher.decodingCount == 4) // Unchanged input reuses complete clusters, even beyond the decoded-print capacity.
        results[assets[0].id] = MediaAnalysisResult(featurePrint: checker.featurePrint, perceptualHash: checker.perceptualHash)
        #expect(await matcher.clusters(assets: assets, results: results) == SimilarPhotoDetection.clusters(assets: assets, results: results))
        #expect(await matcher.decodingCount == 7)
        let limited = Array(assets.dropFirst(2))
        #expect(await matcher.clusters(assets: limited, results: results) == SimilarPhotoDetection.clusters(assets: limited, results: results))
        #expect(await matcher.decodingCount == 9)
        #expect(await matcher.clusters(assets: limited, results: results) == SimilarPhotoDetection.clusters(assets: limited, results: results))
        #expect(await matcher.decodingCount == 9)
    }

    @Test("cluster reuse ignores sizing changes but invalidates ordering and candidate fingerprints")
    func clusterCacheInputs() async throws {
        let fixtures = try nativeFixtures()
        let base = try #require(fixtures.first { $0.id == "base" })
        let near = try #require(fixtures.first { $0.id == "near" })
        let matcher = SimilarPhotoMatcher(capacity: 1)
        var assets = [asset("a"), asset("b")]
        var results = ["a": MediaAnalysisResult(featurePrint: base.featurePrint, perceptualHash: base.perceptualHash),
                       "b": MediaAnalysisResult(featurePrint: near.featurePrint, perceptualHash: near.perceptualHash)]
        #expect(await matcher.clusters(assets: assets, results: results).first?.id == "a")
        #expect(await matcher.decodingCount == 2)
        results["a"]?.isLarge = true
        #expect(await matcher.clusters(assets: assets, results: results).first?.id == "a")
        #expect(await matcher.decodingCount == 2)
        assets[1] = PhotoAssetDescriptor(id: "b", creationDate: Date(timeIntervalSince1970: 1), coordinate: nil,
            mediaKind: .photo, duration: 0, pixelWidth: 800, pixelHeight: 800)
        #expect(await matcher.clusters(assets: assets, results: results).first?.id == "b")
        results["b"]?.perceptualHash = base.perceptualHash ^ UInt64.max
        #expect(await matcher.clusters(assets: assets, results: results).isEmpty)
    }

    private struct NativeFixture: Decodable {
        let id: String
        let featurePrint: Data
        let perceptualHash: UInt64
    }

    private func nativeFixtures() throws -> [NativeFixture] {
        let bundle = Bundle(for: FixtureBundleAnchor.self)
        let url = try #require(bundle.url(forResource: "NativeFeaturePrints", withExtension: "json"))
        return try JSONDecoder().decode([NativeFixture].self, from: Data(contentsOf: url))
    }

    private func asset(_ id: String) -> PhotoAssetDescriptor {
        PhotoAssetDescriptor(id: id, creationDate: nil, coordinate: nil, mediaKind: .photo,
                             duration: 0, pixelWidth: 800, pixelHeight: 800)
    }



}

private final class FixtureBundleAnchor: NSObject {}
