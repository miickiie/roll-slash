import CoreLocation
import Foundation
import MapKit

protocol LocationResolver: Sendable {
    func resolve(_ coordinate: GeoCoordinate) async throws -> ResolvedLocation?
}

struct MapKitLocationResolver: LocationResolver {
    func resolve(_ coordinate: GeoCoordinate) async throws -> ResolvedLocation? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        for attempt in 0..<2 {
            try await ReverseGeocodingRateLimiter.shared.acquire()
            guard let request = MKReverseGeocodingRequest(location: location) else { return nil }
            request.preferredLocale = .current
            do {
                let items = try await request.mapItems
                guard let representations = items.first?.addressRepresentations else { return nil }
                return ResolvedLocation(
                    city: representations.cityName,
                    country: representations.regionName
                )
            } catch {
                guard Self.isThrottled(error) else { throw error }
                await ReverseGeocodingRateLimiter.shared.pauseAfterThrottle()
                if attempt == 1 { throw error }
            }
        }
        return nil
    }

    private static func isThrottled(_ error: Error) -> Bool {
        let error = error as NSError
        return (error.domain == MKErrorDomain && error.code == Int(MKError.Code.loadingThrottled.rawValue))
            || (error.domain == "GEOErrorDomain" && error.code == -3)
    }
}

private actor ReverseGeocodingRateLimiter {
    static let shared = ReverseGeocodingRateLimiter()

    private static let historyKey = "roll-slash.reverse-geocoding-history.v1"
    private static let pauseKey = "roll-slash.reverse-geocoding-pause.v1"
    private let window: TimeInterval = 60
    private let spacing: TimeInterval = 2.1
    private let maxRequestsPerWindow = 30
    private var requestDates: [Date]
    private var pausedUntil: Date

    init() {
        requestDates = (UserDefaults.standard.array(forKey: Self.historyKey) as? [Date] ?? []).sorted()
        pausedUntil = UserDefaults.standard.object(forKey: Self.pauseKey) as? Date ?? .distantPast
    }

    func acquire() async throws {
        while true {
            try Task.checkCancellation()
            let now = Date()
            requestDates.removeAll { $0 > now || now.timeIntervalSince($0) >= window }

            let nextSpacing = requestDates.last?.addingTimeInterval(spacing) ?? now
            let nextWindow = requestDates.count >= maxRequestsPerWindow
                ? requestDates[requestDates.count - maxRequestsPerWindow].addingTimeInterval(window + 1)
                : now
            let nextRequest = max(nextSpacing, nextWindow, pausedUntil)
            if nextRequest <= now {
                requestDates.append(now)
                UserDefaults.standard.set(requestDates, forKey: Self.historyKey)
                return
            }
            try await Task.sleep(for: .seconds(nextRequest.timeIntervalSince(now)))
        }
    }

    func pauseAfterThrottle() {
        pausedUntil = max(pausedUntil, Date().addingTimeInterval(window + 5))
        UserDefaults.standard.set(pausedUntil, forKey: Self.pauseKey)
    }
}
