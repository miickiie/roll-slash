import CoreGraphics
import CryptoKit
import Foundation
import Vision

enum SimilarPhotoDetection {
    // Pinned to Vision revision 2 and checked against committed native reference prints.
    static let maximumDistance: Float = 0.30

    static func isUsable(_ observation: VNFeaturePrintObservation) -> Bool {
        guard observation.elementType == .float, observation.elementCount > 0,
              observation.data.count == observation.elementCount * MemoryLayout<Float>.size else { return false }
        return observation.data.withUnsafeBytes { bytes in
            var norm: Float = 0
            for index in 0..<observation.elementCount {
                let value = bytes.loadUnaligned(fromByteOffset: index * MemoryLayout<Float>.size, as: Float.self)
                guard value.isFinite else { return false }
                norm += value * value
            }
            return norm.isFinite && norm > 0
        }
    }

    static func hash(_ image: CGImage) -> UInt64? {
        var pixels = [UInt8](repeating: 0, count: 9 * 8)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: 9, height: 8, bitsPerComponent: 8,
                                          bytesPerRow: 9, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 9, height: 8))
            return true
        }
        guard rendered else { return nil }
        var hash: UInt64 = 0
        for y in 0..<8 { for x in 0..<8 {
            if pixels[y * 9 + x] > pixels[y * 9 + x + 1] { hash |= 1 << (y * 8 + x) }
        } }
        return hash
    }

    static func clusters(assets: [PhotoAssetDescriptor], results: [String: MediaAnalysisResult],
                         decode: (String, Data) -> DecodedSimilarityPrint? = { _, data in DecodedSimilarityPrint.decode(data) }) -> [SimilarPhotoCluster] {
        let interval = AnalysisPerformance.begin(.clusters)
        defer { AnalysisPerformance.end(.clusters, interval) }
        var index = SimilarityCandidateIndex()
        var prints: [String: VNFeaturePrintObservation] = [:]
        var members: [String: [String]] = [:]
        var representatives: [String] = []
        for asset in assets.sorted(by: {
            let lhs = $0.creationDate ?? .distantPast, rhs = $1.creationDate ?? .distantPast
            return lhs == rhs ? $0.id < $1.id : lhs > rhs
        }) where asset.mediaKind != .video {
            guard !Task.isCancelled, let result = results[asset.id], let data = result.featurePrint,
                  let hash = result.perceptualHash,
                  let decoded = decode(asset.id, data) else { continue }
            let print = decoded.observation
            let digest = decoded.digest
            if let representative = index.exactRepresentative(for: digest) {
                members[representative, default: [representative]].append(asset.id)
                continue
            }
            let candidates = index.candidates(for: hash)
            var best: (String, Float)?
            for candidate in candidates.sorted() {
                guard let other = prints[candidate] else { continue }
                var distance: Float = 0
                guard (try? print.computeDistance(&distance, to: other)) != nil,
                      distance <= maximumDistance else { continue }
                if best == nil || distance < best!.1 { best = (candidate, distance) }
            }
            if let best {
                members[best.0, default: [best.0]].append(asset.id)
                index.cacheExact(digest, representative: best.0)
            } else {
                prints[asset.id] = print
                representatives.append(asset.id)
                index.insertRepresentative(asset.id, hash: hash, digest: digest)
            }
        }
        return representatives.compactMap { id in
            guard let ids = members[id], ids.count > 1 else { return nil }
            return SimilarPhotoCluster(id: id, assetIDs: ids)
        }
    }
}

final class DecodedSimilarityPrint: NSObject {
    let encoded: Data
    let observation: VNFeaturePrintObservation
    let digest: Data

    private init(encoded: Data, observation: VNFeaturePrintObservation) {
        self.encoded = encoded
        self.observation = observation
        digest = Data(SHA256.hash(data: observation.data))
    }

    static func decode(_ data: Data) -> DecodedSimilarityPrint? {
        guard let observation = try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: data),
              SimilarPhotoDetection.isUsable(observation) else { return nil }
        return DecodedSimilarityPrint(encoded: data, observation: observation)
    }
}

actor SimilarPhotoMatcher {
    private struct Input: Equatable {
        let id: String
        let creationDate: Date?
        let featurePrint: Data
        let hash: UInt64
    }
    private var decoded: [String: DecodedSimilarityPrint] = [:]
    private var previousInput: [Input]?
    private var previousClusters: [SimilarPhotoCluster] = []
    private let capacity: Int
    private(set) var decodingCount = 0

    init(capacity: Int = 4096) { self.capacity = max(1, capacity) }

    func clusters(assets: [PhotoAssetDescriptor], results: [String: MediaAnalysisResult]) -> [SimilarPhotoCluster] {
        let accessibleIDs = Set(assets.map(\.id))
        for id in Set(decoded.keys).subtracting(accessibleIDs) { removeCachedPrint(id) }
        let input = assets.compactMap { asset -> Input? in
            guard asset.mediaKind != .video, let result = results[asset.id],
                  let data = result.featurePrint, let hash = result.perceptualHash else { return nil }
            return Input(id: asset.id, creationDate: asset.creationDate, featurePrint: data, hash: hash)
        }.sorted { $0.id < $1.id }
        guard !Task.isCancelled else { return [] }
        if input == previousInput { return previousClusters }
        // Rebuild representatives in canonical order so concurrent photo completion cannot change membership.
        let clusters = SimilarPhotoDetection.clusters(assets: assets, results: results) { id, data in
            if let cached = decoded[id], cached.encoded == data { return cached }
            decodingCount += 1
            guard let value = DecodedSimilarityPrint.decode(data) else {
                removeCachedPrint(id)
                return nil
            }
            removeCachedPrint(id)
            // Stable admission avoids evicting the entire cache on every large-library traversal.
            if decoded.count < capacity { decoded[id] = value }
            return value
        }
        if !Task.isCancelled {
            previousInput = input
            previousClusters = clusters
        }
        return clusters
    }

    private func removeCachedPrint(_ id: String) {
        decoded.removeValue(forKey: id)
    }
}

struct SimilarityCandidateIndex {
    private var bands: [UInt16: [String]] = [:]
    private var exactPrints: [Data: String] = [:]

    func exactRepresentative(for digest: Data) -> String? { exactPrints[digest] }

    mutating func cacheExact(_ digest: Data, representative: String) { exactPrints[digest] = representative }

    mutating func insertRepresentative(_ id: String, hash: UInt64, digest: Data) {
        cacheExact(digest, representative: id)
        for key in Self.keys(hash) {
            bands[key, default: []].append(id)
            if bands[key]!.count > 32 { bands[key]!.removeFirst() }
        }
    }

    func candidates(for hash: UInt64) -> Set<String> {
        Self.keys(hash).reduce(into: Set<String>()) { ids, key in
            ids.formUnion((bands[key] ?? []).suffix(32))
        }
    }

    private static func keys(_ hash: UInt64) -> [UInt16] {
        (0..<8).map { UInt16($0 << 8) | UInt16((hash >> ($0 * 8)) & 255) }
    }
}

// Fixed, non-personal canaries also provide reproducible matcher calibration fixtures.
enum SimilarityCalibrationImages {
    static func scene(_ scene: Int, offset: CGFloat = 0) -> CGImage {
        let context = CGContext(data: nil, width: 800, height: 800, bitsPerComponent: 8, bytesPerRow: 3200,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: 0, green: 0.478, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 800, height: 800))
        if scene == 0 {
            context.setFillColor(red: 0.204, green: 0.780, blue: 0.349, alpha: 1)
            context.fill(CGRect(x: 0, y: 430, width: 800, height: 370))
            context.setFillColor(red: 1, green: 0.8, blue: 0, alpha: 1)
            context.fillEllipse(in: CGRect(x: 80 + offset, y: 80, width: 130, height: 130))
            context.setFillColor(red: 0.647, green: 0.518, blue: 0.369, alpha: 1)
            context.fill(CGRect(x: 400 + offset, y: 260, width: 40, height: 280))
            context.setFillColor(red: 0.333, green: 0.333, blue: 0.333, alpha: 1)
            context.fillEllipse(in: CGRect(x: 300 + offset, y: 160, width: 250, height: 230))
        } else if scene == 1 {
            for row in 0..<8 { for column in 0..<8 {
                let white: CGFloat = (row + column).isMultiple(of: 2) ? 1 : 0
                context.setFillColor(red: white, green: white, blue: white, alpha: 1)
                context.fill(CGRect(x: column * 100, y: row * 100, width: 100, height: 100))
            } }
        } else {
            context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 800, height: 800))
            context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
            for row in 0..<12 {
                context.fill(CGRect(x: 70, y: 70 + row * 50, width: 200 + row % 3 * 150, height: 18))
            }
        }
        return context.makeImage()!
    }
}
