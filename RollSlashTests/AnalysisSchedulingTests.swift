import Foundation
import Testing
@testable import RollSlash

@Suite("Balanced analysis scheduling")
struct AnalysisSchedulingTests {
    @Test("power and thermal limits preserve every detector and bound concurrency")
    func powerPolicy() {
        #expect(AnalysisWorkPolicy.workerCount(lowPower: false, thermalState: .nominal) == 2)
        #expect(AnalysisWorkPolicy.workerCount(lowPower: true, thermalState: .nominal) == 1)
        for state in [ProcessInfo.ThermalState.fair, .serious, .critical] {
            #expect(AnalysisWorkPolicy.workerCount(lowPower: false, thermalState: state) == 1)
        }
    }

    @Test("successful positive and negative stages are reused; missing hashes remain retryable")
    func cachedPhases() {
        for positive in [true, false] {
            let complete = MediaAnalysisResult(isLarge: positive, featurePrint: Data([1]), perceptualHash: 7)
            let plan = AnalysisPhasePlan(cached: complete)
            #expect(!plan.sizing && !plan.fingerprint && !plan.image)
            #expect(complete.isComplete)
            let result = PhotoKitMediaAnalysisClient.analyzeImage(SimilarityCalibrationImages.scene(0),
                similarityAvailable: false, cachedResult: complete)
            #expect(result == complete)
        }
        let partial = MediaAnalysisResult(isLarge: false, featurePrint: Data([1]))
        #expect(!partial.isComplete)
        let retry = AnalysisPhasePlan(cached: partial)
        #expect(!retry.sizing && retry.fingerprint && retry.image)
        let sizingOnly = AnalysisPhasePlan(cached: MediaAnalysisResult(featurePrint: Data([1]), perceptualHash: 7))
        #expect(sizingOnly.sizing && !sizingOnly.image)
        let unavailable = AnalysisPhasePlan(cached: nil, similarityAvailable: false)
        #expect(unavailable.sizing && !unavailable.image)
        #expect(AnalysisPhasePlan(cached: nil).fingerprint)
    }

    @Test("legacy receipt-incomplete JSON retains sizing and fingerprints without an OCR requirement")
    func legacyAnalysisJSON() throws {
        let legacy = Data(#"{"isLarge":false,"isReceipt":null,"featurePrint":"AQ==","perceptualHash":7,"unsupportedReceiptLanguages":["th-TH"],"similarityUnavailable":false}"#.utf8)
        let result = try JSONDecoder().decode(MediaAnalysisResult.self, from: legacy)
        #expect(MediaAnalysisResult.version == 1)
        #expect(result.isLarge == false && result.featurePrint == Data([1]) && result.perceptualHash == 7)
        #expect(result.isComplete)
        #expect(!AnalysisPhasePlan(cached: result).image)
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any])
        #expect(encoded["isReceipt"] == nil)
        #expect(encoded["unsupportedReceiptLanguages"] == nil)
    }

    @Test("canceled waiters do not leak worker leases across scan generations")
    func canceledWaiters() async throws {
        let pool = AnalysisWorkerPool(workers: [0, 1])
        let first = try #require(await pool.acquire(limit: 2))
        let second = try #require(await pool.acquire(limit: 2))
        let canceled = Task { await pool.acquire(limit: 2) }
        canceled.cancel()
        #expect(await canceled.value == nil)
        await pool.release(first)
        let replacement = try #require(await pool.acquire(limit: 2))
        #expect(replacement == first)
        await pool.release(second)
        await pool.release(replacement)
        let one = try #require(await pool.acquire(limit: 1))
        let two = Task { await pool.acquire(limit: 1) }
        let alsoCanceled = Task { await pool.acquire(limit: 1) }
        alsoCanceled.cancel()
        #expect(await alsoCanceled.value == nil)
        await pool.release(one)
        let next = try #require(await two.value)
        await pool.release(next)
    }
}
