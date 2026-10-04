import Foundation
import os

enum AnalysisWorkPolicy {
    static func workerCount(lowPower: Bool, thermalState: ProcessInfo.ThermalState) -> Int {
        lowPower || thermalState != .nominal ? 1 : 2
    }

    static var currentWorkerCount: Int {
        workerCount(lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
                    thermalState: ProcessInfo.processInfo.thermalState)
    }
}

struct AnalysisPhasePlan {
    let sizing: Bool
    let fingerprint: Bool
    var image: Bool { fingerprint }

    init(cached: MediaAnalysisResult?, similarityAvailable: Bool = true) {
        sizing = cached?.isLarge == nil
        fingerprint = (cached?.featurePrint == nil || cached?.perceptualHash == nil) && similarityAvailable
    }
}

// A lease remains occupied until its worker returns, even when its scan is canceled.
// This also bounds work across overlapping foreground/library-refresh generations.
actor AnalysisWorkerPool<Worker: Sendable> {
    private struct Waiter {
        let id: UUID
        let limit: Int
        let continuation: CheckedContinuation<Worker?, Never>
    }
    private var available: [Worker]
    private let count: Int
    private let liveLimit: (@Sendable () -> Int)?
    private var waiters: [Waiter] = []

    init(workers: [Worker], liveLimit: (@Sendable () -> Int)? = nil) {
        precondition(!workers.isEmpty)
        available = workers
        count = workers.count
        self.liveLimit = liveLimit
    }

    func acquire(limit: Int) async -> Worker? {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: nil); return }
                waiters.append(Waiter(id: id, limit: max(1, min(limit, count)), continuation: continuation))
                dispatch()
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func release(_ worker: Worker) {
        available.append(worker)
        dispatch()
    }

    private func dispatch() {
        while let waiter = waiters.first, !available.isEmpty,
              count - available.count < min(waiter.limit, max(1, liveLimit?() ?? count)) {
            waiters.removeFirst()
            waiter.continuation.resume(returning: available.removeLast())
        }
    }

    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: nil)
        dispatch()
    }
}

// Fixed phase names and random interval IDs: no photo identifiers, text or images.
enum AnalysisPerformance {
    enum Phase {
        case scan, sizing, image, orientation, fingerprint, cache, clusters, groups
        var name: StaticString {
            switch self {
            case .scan: "Scan"
            case .sizing: "Sizing"
            case .image: "Local image"
            case .orientation: "Orientation"
            case .fingerprint: "Feature print"
            case .cache: "Cache batch"
            case .clusters: "Similar clusters"
            case .groups: "Type groups"
            }
        }
    }
    private static let signposter = OSSignposter(subsystem: "com.rollslash.app", category: "Photo analysis")

    static func begin(_ phase: Phase) -> OSSignpostIntervalState {
        signposter.beginInterval(phase.name, id: signposter.makeSignpostID())
    }

    static func end(_ phase: Phase, _ state: OSSignpostIntervalState) {
        signposter.endInterval(phase.name, state)
    }
}
