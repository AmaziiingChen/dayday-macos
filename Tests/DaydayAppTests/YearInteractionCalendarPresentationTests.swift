@testable import DaydayApp
import DaydayCore
import Foundation
import Testing

struct YearInteractionCalendarPresentationTests {
    @Test("Empty input still yields the complete logical-day grid for the range")
    func emptyInputYieldsDayGrid() throws {
        let range = try range("2026-01-01T00:00:00Z", to: "2026-01-04T00:00:00Z", zone: "Asia/Shanghai")

        let presentation = try YearInteractionCalendarPresentationAdapter.make(
            from: [],
            in: range,
            timeZoneIdentifier: "Asia/Shanghai"
        )

        #expect(presentation.days.count == 4)
        #expect(presentation.days.allSatisfy { $0.detectedInteractionMilliseconds == 0 })
        #expect(presentation.activeDayCount == 0)
        #expect(presentation.objectiveRecordCount == 0)
        #expect(presentation.detectedInteractionMilliseconds == 0)
    }

    @Test("Hour aggregates are summed into their 04:00 logical day")
    func sumsHoursPerLogicalDay() throws {
        let beforeBoundary = try aggregate("2026-08-03T19:00:00Z", zone: "Asia/Shanghai", milliseconds: 120_000)
        let afterBoundary = try aggregate("2026-08-03T21:00:00Z", zone: "Asia/Shanghai", milliseconds: 600_000)
        let nextDay = try aggregate("2026-08-04T02:00:00Z", zone: "Asia/Shanghai", milliseconds: 300_000)
        let range = try range("2026-08-01T00:00:00Z", to: "2026-08-05T00:00:00Z", zone: "Asia/Shanghai")

        let presentation = try YearInteractionCalendarPresentationAdapter.make(
            from: [beforeBoundary, afterBoundary, nextDay],
            in: range,
            timeZoneIdentifier: "Asia/Shanghai"
        )

        #expect(presentation.days.count == 5)
        let august3 = try #require(presentation.days.first(where: { calendarDay(of: $0.logicalDayStart, zone: "Asia/Shanghai") == 3 }))
        #expect(august3.detectedInteractionMilliseconds == 120_000)
        #expect(august3.objectiveRecordCount == 1)
        let august4 = try #require(presentation.days.first(where: { calendarDay(of: $0.logicalDayStart, zone: "Asia/Shanghai") == 4 }))
        #expect(august4.detectedInteractionMilliseconds == 900_000)
        #expect(august4.objectiveRecordCount == 2)
        #expect(presentation.activeDayCount == 2)
        #expect(presentation.detectedInteractionMilliseconds == 1_020_000)
        #expect(presentation.objectiveRecordCount == 3)
    }

    @Test("A daily rollup supersedes its source hours so a workday is not counted twice")
    func dailyRollupSupersedesHours() throws {
        let daily = try dailyAggregate("2026-08-03T20:00:00Z", zone: "Asia/Shanghai", milliseconds: 3_600_000)
        let hour = try aggregate("2026-08-03T21:00:00Z", zone: "Asia/Shanghai", milliseconds: 600_000)
        let range = try range("2026-08-01T00:00:00Z", to: "2026-08-05T00:00:00Z", zone: "Asia/Shanghai")

        let presentation = try YearInteractionCalendarPresentationAdapter.make(
            from: [daily, hour],
            in: range,
            timeZoneIdentifier: "Asia/Shanghai"
        )

        let august4 = try #require(presentation.days.first(where: { calendarDay(of: $0.logicalDayStart, zone: "Asia/Shanghai") == 4 }))
        #expect(august4.detectedInteractionMilliseconds == 3_600_000)
        #expect(august4.objectiveRecordCount == 1)
        #expect(presentation.detectedInteractionMilliseconds == 3_600_000)
        #expect(presentation.objectiveRecordCount == 1)
    }

    @Test("Aggregates outside the range are ignored and do not produce trailing days")
    func ignoresOutOfRangeAggregates() throws {
        let outside = try aggregate("2026-07-30T21:00:00Z", zone: "Asia/Shanghai", milliseconds: 500_000)
        let inside = try aggregate("2026-08-03T21:00:00Z", zone: "Asia/Shanghai", milliseconds: 100_000)
        let range = try range("2026-08-01T00:00:00Z", to: "2026-08-05T00:00:00Z", zone: "Asia/Shanghai")

        let presentation = try YearInteractionCalendarPresentationAdapter.make(
            from: [outside, inside],
            in: range,
            timeZoneIdentifier: "Asia/Shanghai"
        )

        #expect(presentation.days.count == 5)
        #expect(presentation.detectedInteractionMilliseconds == 100_000)
    }

    @Test("Logical days are emitted in ascending order")
    func ascendingOrder() throws {
        let range = try range("2026-08-01T00:00:00Z", to: "2026-08-05T00:00:00Z", zone: "Asia/Shanghai")
        let presentation = try YearInteractionCalendarPresentationAdapter.make(
            from: [],
            in: range,
            timeZoneIdentifier: "Asia/Shanghai"
        )
        let starts = presentation.days.map(\.logicalDayStart)
        #expect(starts == starts.sorted())
    }

    @Test("Unsigned accumulation fails closed instead of wrapping")
    func refusesOverflow() {
        #expect(throws: YearInteractionCalendarPresentationAdapter.AggregationError.unsignedOverflow) {
            try YearInteractionCalendarPresentationAdapter.checkedAdd(UInt64.max, 1)
        }
    }

    @Test("Invalid range and unknown time zone are rejected")
    func rejectsInvalidInputs() {
        let emptyRange = Date()..<Date()
        #expect(throws: YearInteractionCalendarPresentationAdapter.AggregationError.invalidRange) {
            try YearInteractionCalendarPresentationAdapter.make(from: [], in: emptyRange, timeZoneIdentifier: "Asia/Shanghai")
        }
        let validRange = Date()..<Date().addingTimeInterval(86_400)
        #expect(throws: YearInteractionCalendarPresentationAdapter.AggregationError.invalidTimeZone("Nope/Nope")) {
            try YearInteractionCalendarPresentationAdapter.make(from: [], in: validRange, timeZoneIdentifier: "Nope/Nope")
        }
    }

    private func aggregate(
        _ startValue: String,
        zone: String,
        milliseconds: UInt64
    ) throws -> InputAggregate {
        let start = ISO8601DateFormatter().date(from: startValue)!
        let period = try InputAggregatePeriod(
            start: start,
            end: start.addingTimeInterval(3_600),
            granularity: .hour,
            timeZoneIdentifier: zone
        )
        return try InputAggregate(
            period: period,
            includedDurationMilliseconds: milliseconds,
            collectorVersions: ["test-v1"],
            layoutVersions: ["physical-v1"]
        )
    }

    private func dailyAggregate(
        _ startValue: String,
        zone: String,
        milliseconds: UInt64
    ) throws -> InputAggregate {
        let start = ISO8601DateFormatter().date(from: startValue)!
        let period = try InputAggregatePeriod(
            start: start,
            end: start.addingTimeInterval(86_400),
            granularity: .day,
            timeZoneIdentifier: zone,
            workdayBoundaryHour: WorkdayBoundary.standard.hour
        )
        return try InputAggregate(
            period: period,
            includedDurationMilliseconds: milliseconds,
            collectorVersions: ["test-v1"],
            layoutVersions: ["physical-v1"]
        )
    }

    private func range(
        _ startValue: String,
        to endValue: String,
        zone: String
    ) throws -> Range<Date> {
        let start = ISO8601DateFormatter().date(from: startValue)!
        let end = ISO8601DateFormatter().date(from: endValue)!
        return start..<end
    }

    private func calendarDay(of date: Date, zone: String) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone) ?? .autoupdatingCurrent
        return calendar.component(.day, from: date)
    }
}
