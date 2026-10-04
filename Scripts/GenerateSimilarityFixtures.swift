import CoreGraphics
import Foundation
import Vision

// Generate native reference prints from the application's fixed synthetic canaries.
// Compile this source alongside Core/DomainModels.swift, Core/MediaTypes.swift,
// and Core/ImageSimilarity.swift using the native macOS SDK. Run outside the
// filesystem sandbox so Vision can select its working native compute backend.
// No Photos APIs, networking, or personal images are used. Only the requested
// fixture output is written.
@main
struct NativeFeaturePrintGenerator {
    struct Reference: Codable {
        let id: String
        let featurePrint: Data
        let perceptualHash: UInt64
    }

    // Render deterministic alpha blends between the scene and checker canaries.
    // Search every fraction 0...1 in increments of 0.05. Select an ordered triple
    // with both adjacent distances within the matcher cutoff and endpoint distance
    // above it. Maximize the smallest boundary margin rather than hard-coding a
    // lucky triple, so regenerated fixtures remain robust to native precision.
    static func blendedImage(fraction: CGFloat) -> CGImage {
        let context = CGContext(data: nil, width: 800, height: 800,
                                bitsPerComponent: 8, bytesPerRow: 3200,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 800)
        context.draw(SimilarityCalibrationImages.scene(0), in: bounds)
        context.setAlpha(fraction)
        context.draw(SimilarityCalibrationImages.scene(1), in: bounds)
        return context.makeImage()!
    }

    static func featurePrint(_ image: CGImage) throws -> VNFeaturePrintObservation {
        let request = VNGenerateImageFeaturePrintRequest()
        request.revision = VNGenerateImageFeaturePrintRequestRevision2
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        guard let observation = request.results?.first,
              SimilarPhotoDetection.isUsable(observation) else {
            throw NSError(domain: "NativeFeaturePrintGenerator", code: 6)
        }
        return observation
    }

    static func chainImages() throws -> [(String, CGImage)] {
        let fractions = (0...20).map { CGFloat($0) / 20 }
        let images = fractions.map { blendedImage(fraction: $0) }
        let observations = try images.map(featurePrint)
        var distances = [[Float]](repeating: [Float](repeating: 0, count: images.count),
                                  count: images.count)
        for first in 0..<images.count {
            for second in (first + 1)..<images.count {
                var distance: Float = 0
                try observations[first].computeDistance(&distance, to: observations[second])
                distances[first][second] = distance
                distances[second][first] = distance
            }
        }
        let cutoff = SimilarPhotoDetection.maximumDistance
        var best: (first: Int, middle: Int, last: Int, margin: Float)?
        for first in 0..<images.count {
            for middle in (first + 1)..<images.count {
                for last in (middle + 1)..<images.count {
                    let ab = distances[first][middle]
                    let bc = distances[middle][last]
                    let ac = distances[first][last]
                    guard ab <= cutoff, bc <= cutoff, ac > cutoff else { continue }
                    let margin = min(cutoff - ab, cutoff - bc, ac - cutoff)
                    if best == nil || margin > best!.margin {
                        best = (first, middle, last, margin)
                    }
                }
            }
        }
        guard let best else {
            throw NSError(domain: "NativeFeaturePrintGenerator", code: 7,
                          userInfo: [NSLocalizedDescriptionKey: "No meaningful transitive-chain fixture found"])
        }
        print("Chain fractions A=\(fractions[best.first]) B=\(fractions[best.middle]) C=\(fractions[best.last])")
        print("Chain AB=\(distances[best.first][best.middle]) BC=\(distances[best.middle][best.last]) AC=\(distances[best.first][best.last]) cutoff=\(cutoff) minMargin=\(best.margin)")
        return [("chain-a", images[best.first]), ("chain-b", images[best.middle]),
                ("chain-c", images[best.last])]
    }

    static func main() throws {
        let destination = CommandLine.arguments.dropFirst().first
            ?? "/private/tmp/photo-slash-native-featureprints.json"
        var scenes: [(String, CGImage)] = [
            ("base", SimilarityCalibrationImages.scene(0, offset: 0)),
            ("near", SimilarityCalibrationImages.scene(0, offset: 6)),
            ("shift30", SimilarityCalibrationImages.scene(0, offset: 30)),
            ("shift65", SimilarityCalibrationImages.scene(0, offset: 65)),
            ("checker", SimilarityCalibrationImages.scene(1)),
            ("document", SimilarityCalibrationImages.scene(2))
        ]
        scenes += try chainImages()
        var references: [Reference] = []
        var decoded: [VNFeaturePrintObservation] = []
        for (id, image) in scenes {
            let request = VNGenerateImageFeaturePrintRequest()
            request.revision = VNGenerateImageFeaturePrintRequestRevision2
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            guard let observation = request.results?.first,
                  SimilarPhotoDetection.isUsable(observation),
                  let hash = SimilarPhotoDetection.hash(image) else {
                throw NSError(domain: "NativeFeaturePrintGenerator", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Invalid native print for \(id)"])
            }
            let archive = try NSKeyedArchiver.archivedData(withRootObject: observation,
                                                         requiringSecureCoding: true)
            guard let restored = try NSKeyedUnarchiver.unarchivedObject(
                ofClass: VNFeaturePrintObservation.self, from: archive),
                SimilarPhotoDetection.isUsable(restored), restored.data == observation.data else {
                throw NSError(domain: "NativeFeaturePrintGenerator", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Archive verification failed for \(id)"])
            }
            var roundTripDistance: Float = 0
            try observation.computeDistance(&roundTripDistance, to: restored)
            guard roundTripDistance == 0 else {
                throw NSError(domain: "NativeFeaturePrintGenerator", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "Round trip changed print for \(id)"])
            }
            let norm = restored.data.withUnsafeBytes { bytes -> Double in
                var squared: Double = 0
                for index in 0..<restored.elementCount {
                    let value = bytes.loadUnaligned(fromByteOffset: index * MemoryLayout<Float>.size,
                                                    as: Float.self)
                    squared += Double(value) * Double(value)
                }
                return squared.squareRoot()
            }
            print("\(id): revision=\(restored.requestRevision) count=\(restored.elementCount) norm=\(norm) hash=\(hash) archiveBytes=\(archive.count)")
            references.append(Reference(id: id, featurePrint: archive, perceptualHash: hash))
            decoded.append(restored)
        }
        for first in 0..<decoded.count {
            for second in (first + 1)..<decoded.count {
                var distance: Float = 0
                try decoded[first].computeDistance(&distance, to: decoded[second])
                print("\(references[first].id) -> \(references[second].id): \(distance)")
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = try encoder.encode(references)
        let reread = try JSONDecoder().decode([Reference].self, from: json)
        guard reread.count == references.count else {
            throw NSError(domain: "NativeFeaturePrintGenerator", code: 4)
        }
        for reference in reread {
            guard let observation = try NSKeyedUnarchiver.unarchivedObject(
                ofClass: VNFeaturePrintObservation.self, from: reference.featurePrint),
                SimilarPhotoDetection.isUsable(observation) else {
                throw NSError(domain: "NativeFeaturePrintGenerator", code: 5)
            }
        }
        try json.write(to: URL(fileURLWithPath: destination), options: .atomic)
        print("Verified \(reread.count) secure-archive references written to \(destination)")
    }
}
