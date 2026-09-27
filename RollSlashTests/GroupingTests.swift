import Foundation
import Testing
@testable import RollSlash

@Suite("Grouping")
struct GroupingTests {
    @Test("month keys honor calendar time zone and render MMM-yy")
    func monthKeysAndTitles() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Bangkok"))
        let date = try #require(ISO8601DateFormatter().date(from: "2026-01-31T18:30:00Z"))

        #expect(MonthGrouping.key(for: date, calendar: calendar) == "2026-02")
        #expect(MonthGrouping.title(for: "2026-02", calendar: calendar, locale: Locale(identifier: "en_US")) == "Feb-26")
        #expect(MonthGrouping.key(for: nil, calendar: calendar) == MonthGrouping.unknownKey)
        #expect(MonthGrouping.title(for: MonthGrouping.unknownKey) == "Unknown Date")
    }

    @Test("nearby coordinates use one stable bucket")
    func coordinateBucketing() {
        let first = GeoCoordinate(latitude: 13.7563, longitude: 100.5018)
        let second = GeoCoordinate(latitude: 13.7580, longitude: 100.5001)

        #expect(LocationBucketing.key(for: first) == LocationBucketing.key(for: second))
        #expect(LocationBucketing.center(for: LocationBucketing.key(for: first)) != nil)
    }

    @Test("50,000 metadata records group without media loading")
    func largeLibraryGrouping() {
        let calendar = Calendar(identifier: .gregorian)
        let base = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1))!
        let assets = (0..<50_000).map { index in
            PhotoAssetDescriptor(
                id: "asset-\(index)",
                creationDate: calendar.date(byAdding: .month, value: -(index % 120), to: base),
                coordinate: nil,
                mediaKind: .photo,
                duration: 0,
                pixelWidth: 100,
                pixelHeight: 100
            )
        }
        let clock = ContinuousClock()
        let start = clock.now
        let groups = MonthGrouping.group(assets, calendar: calendar)
        let elapsed = start.duration(to: clock.now)

        #expect(groups.count == 120)
        #expect(groups.values.reduce(0) { $0 + $1.count } == 50_000)
        #expect(elapsed < .seconds(5))
    }
}
