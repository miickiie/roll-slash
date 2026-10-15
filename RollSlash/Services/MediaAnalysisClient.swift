import Foundation
import CoreImage
import Photos
import UIKit
import Vision

protocol MediaAnalysisClient: Sendable {
    func prepare() async
    func analyze(_ asset: PhotoAssetDescriptor) async -> MediaAnalysisResult
    func analyze(_ asset: PhotoAssetDescriptor, cachedResult: MediaAnalysisResult?) async -> MediaAnalysisResult
    func concurrencyLimit() async -> Int
    func clusters(assets: [PhotoAssetDescriptor], results: [String: MediaAnalysisResult]) async -> [SimilarPhotoCluster]
}

extension MediaAnalysisClient {
    func prepare() async {}
    func concurrencyLimit() async -> Int { 1 }
    func analyze(_ asset: PhotoAssetDescriptor, cachedResult: MediaAnalysisResult?) async -> MediaAnalysisResult {
        await analyze(asset)
    }
}

actor PhotoKitMediaAnalysisClient: MediaAnalysisClient {
    private var similarityAvailable: Bool?
    private let workers = AnalysisWorkerPool(workers: [PhotoKitAnalysisWorker(), PhotoKitAnalysisWorker()],
                                             liveLimit: { AnalysisWorkPolicy.currentWorkerCount })
    private let matcher = SimilarPhotoMatcher()

    func prepare() async {
        // Healthy capabilities are stable for this process; unsuccessful probes retry next scan.
        if similarityAvailable != true { similarityAvailable = Self.similarityBackendAvailable() }
    }

    func concurrencyLimit() async -> Int { AnalysisWorkPolicy.currentWorkerCount }

    func analyze(_ descriptor: PhotoAssetDescriptor) async -> MediaAnalysisResult {
        await analyze(descriptor, cachedResult: nil)
    }

    func analyze(_ descriptor: PhotoAssetDescriptor, cachedResult: MediaAnalysisResult?) async -> MediaAnalysisResult {
        if similarityAvailable == nil { await prepare() }
        guard let worker = await workers.acquire(limit: AnalysisWorkPolicy.currentWorkerCount) else {
            return cachedResult ?? MediaAnalysisResult()
        }
        let result = await worker.analyze(descriptor, cachedResult: cachedResult,
                                        similarityAvailable: similarityAvailable == true)
        await workers.release(worker)
        return result
    }

    nonisolated static func analyzeImage(_ image: CGImage, isLarge: Bool? = nil, similarityAvailable: Bool? = nil,
                                        cachedResult: MediaAnalysisResult? = nil) -> MediaAnalysisResult {
        var result = cachedResult ?? MediaAnalysisResult()
        result.isLarge = isLarge ?? result.isLarge
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let needsFingerprint = result.featurePrint == nil || result.perceptualHash == nil
        let usableSimilarity = needsFingerprint ? (similarityAvailable ?? similarityBackendAvailable()) : true
        result.similarityUnavailable = !usableSimilarity
        if needsFingerprint && usableSimilarity { do {
            let interval = AnalysisPerformance.begin(.fingerprint)
            defer { AnalysisPerformance.end(.fingerprint, interval) }
            let fingerprint = VNGenerateImageFeaturePrintRequest()
            fingerprint.revision = VNGenerateImageFeaturePrintRequestRevision2
            try VisionComputeConfiguration.configure(fingerprint)
            try handler.perform([fingerprint])
            if let observation = fingerprint.results?.first, SimilarPhotoDetection.isUsable(observation) {
                result.featurePrint = try NSKeyedArchiver.archivedData(withRootObject: observation, requiringSecureCoding: true)
                result.perceptualHash = SimilarPhotoDetection.hash(image)
            }
        } catch { /* Keep failed analysis retryable. */ } }
        return result
    }

    nonisolated static func similarityBackendAvailable() -> Bool {
        do {
            var observations: [VNFeaturePrintObservation] = []
            for image in [SimilarityCalibrationImages.scene(0), SimilarityCalibrationImages.scene(1)] {
                let request = VNGenerateImageFeaturePrintRequest()
                request.revision = VNGenerateImageFeaturePrintRequestRevision2
                try VisionComputeConfiguration.configure(request)
                try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
                guard let observation = request.results?.first, SimilarPhotoDetection.isUsable(observation) else { return false }
                observations.append(observation)
            }
            var distance: Float = 0
            try observations[0].computeDistance(&distance, to: observations[1])
            return distance.isFinite && distance > SimilarPhotoDetection.maximumDistance
        } catch { return false }
    }

    func clusters(assets: [PhotoAssetDescriptor], results: [String: MediaAnalysisResult]) async -> [SimilarPhotoCluster] {
        await matcher.clusters(assets: assets, results: results)
    }
}

private actor PhotoKitAnalysisWorker {
    private let imageManager = PHImageManager()
    private var imageContext: CIContext?

    func analyze(_ descriptor: PhotoAssetDescriptor, cachedResult: MediaAnalysisResult?,
                 similarityAvailable: Bool) async -> MediaAnalysisResult {
        var result = cachedResult ?? MediaAnalysisResult()
        guard !Task.isCancelled, descriptor.mediaKind != .video else { return result }
        let plan = AnalysisPhasePlan(cached: result, similarityAvailable: similarityAvailable)
        guard plan.sizing || plan.image else {
            result.similarityUnavailable = (result.featurePrint == nil || result.perceptualHash == nil) && !similarityAvailable
            return result
        }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [descriptor.id], options: nil).firstObject else { return result }
        if plan.sizing {
            let interval = AnalysisPerformance.begin(.sizing)
            result.isLarge = await isLarge(asset)
            AnalysisPerformance.end(.sizing, interval)
        }
        result.similarityUnavailable = (result.featurePrint == nil || result.perceptualHash == nil) && !similarityAvailable
        guard !Task.isCancelled, plan.image, let image = await analysisImage(asset) else { return result }
        return PhotoKitMediaAnalysisClient.analyzeImage(image, similarityAvailable: similarityAvailable,
                                                      cachedResult: result)
    }

    private func analysisImage(_ asset: PHAsset) async -> CGImage? {
        let interval = AnalysisPerformance.begin(.image)
        defer { AnalysisPerformance.end(.image, interval) }
        let manager = imageManager
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.isNetworkAccessAllowed = false
        let (stream, continuation) = AsyncStream<UIImage?>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let requestID = manager.requestImage(for: asset, targetSize: CGSize(width: 1600, height: 1600),
                                             contentMode: .aspectFit, options: options) { image, info in
            if (info?[PHImageResultIsDegradedKey] as? Bool) == true {
                if info?[PHImageErrorKey] != nil || (info?[PHImageResultIsInCloudKey] as? Bool) == true {
                    continuation.yield(nil)
                    continuation.finish()
                }
                return
            }
            continuation.yield(image)
            continuation.finish()
        }
        defer { manager.cancelImageRequest(requestID) }
        for await image in stream {
            guard !Task.isCancelled, let image else { return nil }
            return uprightImage(image)
        }
        return nil
    }

    private func uprightImage(_ image: UIImage) -> CGImage? {
        let interval = AnalysisPerformance.begin(.orientation)
        defer { AnalysisPerformance.end(.orientation, interval) }
        guard let cgImage = image.cgImage else { return nil }
        guard image.imageOrientation != .up else { return cgImage }
        let orientation: CGImagePropertyOrientation
        switch image.imageOrientation {
        case .up: orientation = .up
        case .down: orientation = .down
        case .left: orientation = .left
        case .right: orientation = .right
        case .upMirrored: orientation = .upMirrored
        case .downMirrored: orientation = .downMirrored
        case .leftMirrored: orientation = .leftMirrored
        case .rightMirrored: orientation = .rightMirrored
        @unknown default: return nil
        }
        let oriented = CIImage(cgImage: cgImage).oriented(forExifOrientation: Int32(orientation.rawValue))
        if imageContext == nil { imageContext = CIContext(options: [.cacheIntermediates: false]) }
        return imageContext?.createCGImage(oriented, from: oriented.extent)
    }

    private func isLarge(_ asset: PHAsset) async -> Bool? {
        let resources = PHAssetResource.assetResources(for: asset)
        let types = LargePhotoSizing.resourceTypes(available: Set(resources.map { $0.type.rawValue }),
                                                   isLive: asset.mediaSubtypes.contains(.photoLive))
        guard !types.isEmpty else { return nil }
        var total: Int64 = 0
        var components: [Int64?] = []
        for type in types {
            guard !Task.isCancelled else { return nil }
            guard let resource = resources.first(where: { $0.type.rawValue == type }) else { components.append(nil); continue }
            if #available(iOS 27, *), let size = resource.dataSize {
                total += Int64(size)
                components.append(Int64(size))
            } else if let bytes = await localBytes(resource, limit: MediaAnalysisResult.largePhotoThreshold - total) {
                total += bytes
                components.append(bytes)
            } else {
                components.append(nil)
            }
            if total >= MediaAnalysisResult.largePhotoThreshold { return true }
        }
        return LargePhotoSizing.eligibility(componentBytes: components)
    }

    private func localBytes(_ resource: PHAssetResource, limit: Int64) async -> Int64? {
        enum Event: Sendable { case bytes(Int64), finished, failed }
        let manager = PHAssetResourceManager.default()
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = false
        let (stream, continuation) = AsyncStream<Event>.makeStream()
        let requestID = manager.requestData(for: resource, options: options) { data in
            continuation.yield(.bytes(Int64(data.count)))
        } completionHandler: { error in
            continuation.yield(error == nil ? .finished : .failed)
            continuation.finish()
        }
        defer { manager.cancelDataRequest(requestID) }
        var total: Int64 = 0
        for await event in stream {
            guard !Task.isCancelled else { return nil }
            switch event {
            case let .bytes(bytes):
                total += bytes
                if total >= limit { return total }
            case .finished: return total
            case .failed: return nil
            }
        }
        return nil
    }
}

enum LargePhotoSizing {
    static func resourceTypes(available: Set<Int>, isLive: Bool) -> [Int] {
        let still = available.contains(PHAssetResourceType.fullSizePhoto.rawValue)
            ? PHAssetResourceType.fullSizePhoto.rawValue : PHAssetResourceType.photo.rawValue
        guard available.contains(still) else { return [] }
        guard isLive else { return [still] }
        let motion = available.contains(PHAssetResourceType.fullSizePairedVideo.rawValue)
            ? PHAssetResourceType.fullSizePairedVideo.rawValue : PHAssetResourceType.pairedVideo.rawValue
        return [still, motion]
    }

    static func eligibility(componentBytes: [Int64?]) -> Bool? {
        let known = componentBytes.compactMap { $0 }.reduce(0, +)
        if known >= MediaAnalysisResult.largePhotoThreshold { return true }
        return componentBytes.isEmpty || componentBytes.contains(where: { $0 == nil }) ? nil : false
    }
}

enum VisionComputeConfiguration {
    static func configure(_ request: VNRequest) throws {
        #if targetEnvironment(simulator)
        let stages = try request.supportedComputeStageDevices
        if let cpu = stages[.main]?.first(where: { if case .cpu = $0 { return true }; return false }) {
            request.setComputeDevice(cpu, for: .main)
        }
        #endif
    }
}
