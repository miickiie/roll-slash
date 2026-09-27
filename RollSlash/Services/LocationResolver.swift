import CoreLocation
import Foundation
import MapKit

protocol LocationResolver: Sendable {
    func resolve(_ coordinate: GeoCoordinate) async throws -> ResolvedLocation?
}

struct MapKitLocationResolver: LocationResolver {
    func resolve(_ coordinate: GeoCoordinate) async throws -> ResolvedLocation? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard let request = MKReverseGeocodingRequest(location: location) else { return nil }
        request.preferredLocale = .current
        let items = try await request.mapItems
        guard let representations = items.first?.addressRepresentations else { return nil }
        return ResolvedLocation(
            city: representations.cityName,
            country: representations.regionName
        )
    }
}
