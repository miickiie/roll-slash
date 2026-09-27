import Foundation

enum AppRoute: Hashable {
    case onboarding
    case dashboard
    case cleanup
    case review
    case completion
}

enum PhotoPermission: String, Sendable {
    case notDetermined
    case denied
    case restricted
    case limited
    case full

    var canRead: Bool { self == .limited || self == .full }
}

enum MediaKind: String, Codable, Sendable {
    case photo
    case livePhoto
    case video
}

struct GeoCoordinate: Codable, Hashable, Sendable {
    let latitude: Double
    let longitude: Double
}

struct PhotoAssetDescriptor: Identifiable, Hashable, Sendable {
    let id: String
    let creationDate: Date?
    let coordinate: GeoCoordinate?
    let mediaKind: MediaKind
    let duration: TimeInterval
    let pixelWidth: Int
    let pixelHeight: Int
}

enum GroupKind: String, Codable, CaseIterable, Sendable {
    case month
    case location

    var title: String {
        switch self {
        case .month: String(localized: "Month")
        case .location: String(localized: "Location")
        }
    }
}

struct GroupKey: Hashable, Codable, Sendable, Identifiable {
    let kind: GroupKind
    let value: String

    var id: String { "\(kind.rawValue):\(value)" }

    init(kind: GroupKind, value: String) {
        self.kind = kind
        self.value = value
    }

    init?(rawValue: String) {
        guard let separator = rawValue.firstIndex(of: ":"),
              let kind = GroupKind(rawValue: String(rawValue[..<separator])) else { return nil }
        self.kind = kind
        self.value = String(rawValue[rawValue.index(after: separator)...])
    }
}

struct MediaGroup: Identifiable, Hashable, Sendable {
    let key: GroupKey
    var title: String
    var subtitle: String?
    var assetIDs: [String]
    var unresolvedCount: Int
    var thumbnailAssetID: String?
    var isCleaned: Bool
    var sortDate: Date?

    var id: String { key.id }
    var totalCount: Int { assetIDs.count }
    var reviewedCount: Int { totalCount - unresolvedCount }
}

enum AssetDecision: String, Codable, Sendable {
    case keep
    case deletePending
}

enum CleanupSessionStatus: String, Codable, Sendable {
    case swiping
    case reviewing
    case deleting
}

struct ResolvedLocation: Codable, Hashable, Sendable {
    let city: String?
    let country: String?

    var title: String {
        city ?? country ?? String(localized: "Unresolved Location")
    }

    var subtitle: String? {
        guard city != nil else { return nil }
        return country
    }

    var normalizedKey: String {
        let cityPart = city?.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) ?? ""
        let countryPart = country?.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) ?? ""
        return "\(cityPart)|\(countryPart)"
    }
}

struct CleanupActionSnapshot: Codable, Hashable, Sendable {
    let sequence: Int
    let assetIdentifier: String
    var decision: AssetDecision
    var isApplied: Bool
}

enum MonthGrouping {
    static let unknownKey = "unknown"

    static func key(for date: Date?, calendar: Calendar = .rollSlashGregorian) -> String {
        guard let date else { return unknownKey }
        let components = calendar.dateComponents([.year, .month], from: date)
        guard let year = components.year, let month = components.month else { return unknownKey }
        return String(format: "%04d-%02d", year, month)
    }

    static func title(for key: String, calendar: Calendar = .rollSlashGregorian, locale: Locale = .current) -> String {
        guard key != unknownKey else { return String(localized: "Unknown Date") }
        let pieces = key.split(separator: "-")
        guard pieces.count == 2,
              let year = Int(pieces[0]),
              let month = Int(pieces[1]),
              let date = calendar.date(from: DateComponents(year: year, month: month)) else {
            return String(localized: "Unknown Date")
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.dateFormat = "MMM-yy"
        return formatter.string(from: date)
    }

    static func year(for key: String) -> String? {
        guard key != unknownKey else { return nil }
        return key.split(separator: "-").first.map(String.init)
    }

    static func group(_ assets: [PhotoAssetDescriptor], calendar: Calendar = .rollSlashGregorian) -> [String: [PhotoAssetDescriptor]] {
        Dictionary(grouping: assets) { key(for: $0.creationDate, calendar: calendar) }
    }
}

extension Calendar {
    static var rollSlashGregorian: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }
}

enum LocationBucketing {
    static func key(for coordinate: GeoCoordinate) -> String {
        let latitude = (coordinate.latitude * 20).rounded() / 20
        let longitude = (coordinate.longitude * 20).rounded() / 20
        return String(format: "%.2f,%.2f", locale: Locale(identifier: "en_US_POSIX"), latitude, longitude)
    }

    static func center(for key: String) -> GeoCoordinate? {
        let values = key.split(separator: ",")
        guard values.count == 2,
              let latitude = Double(values[0]),
              let longitude = Double(values[1]) else { return nil }
        return GeoCoordinate(latitude: latitude, longitude: longitude)
    }
}
