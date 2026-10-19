import Foundation
import Testing
@testable import DaydayCore

struct WorkdayBoundaryTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    @Test
    func beforeBoundaryBelongsToPreviousLogicalDay() throws {
        let boundary = try WorkdayBoundary(hour: 4)
        let date = try #require(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 1, hour: 3, minute: 30
        )))
        let expected = try #require(calendar.date(from: DateComponents(
            year: 2026, month: 7, day: 31, hour: 4
        )))

        #expect(try boundary.start(containing: date, calendar: calendar) == expected)
    }

    @Test
    func atBoundaryStartsTheNewLogicalDay() throws {
        let date = try #require(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 1, hour: 4
        )))

        #expect(try WorkdayBoundary.standard.start(containing: date, calendar: calendar) == date)
    }

    @Test
    func afterBoundaryBelongsToTheNewLogicalDay() throws {
        let date = try #require(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 1, hour: 16, minute: 45
        )))
        let expected = try #require(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 1, hour: 4
        )))

        #expect(try WorkdayBoundary.standard.start(containing: date, calendar: calendar) == expected)
    }

    @Test
    func datesAcrossMidnightCanShareAWorkday() throws {
        let beforeMidnight = try #require(calendar.date(from: DateComponents(
            year: 2026, month: 7, day: 31, hour: 23, minute: 30
        )))
        let afterMidnight = try #require(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 1, hour: 1
        )))

        #expect(try WorkdayBoundary.standard.contains(
            beforeMidnight,
            and: afterMidnight,
            calendar: calendar
        ))
    }

    @Test
    func boundaryHourIsValidated() {
        #expect(throws: WorkdayBoundary.ValidationError.invalidHour(-1)) {
            try WorkdayBoundary(hour: -1)
        }
        #expect(throws: WorkdayBoundary.ValidationError.invalidHour(24)) {
            try WorkdayBoundary(hour: 24)
        }
    }

    @Test
    func springForwardDoesNotMoveFourAMIntoPreviousDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let target = try #require(calendar.date(from: DateComponents(
            year: 2024, month: 3, day: 10, hour: 4, minute: 30
        )))
        let expected = try #require(calendar.date(from: DateComponents(
            year: 2024, month: 3, day: 10, hour: 4
        )))

        #expect(try WorkdayBoundary.standard.start(
            containing: target,
            calendar: calendar
        ) == expected)
    }

    @Test
    func nonexistentBoundaryUsesFirstValidLocalTime() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let boundary = try WorkdayBoundary(hour: 2)
        let target = try #require(calendar.date(from: DateComponents(
            year: 2024, month: 3, day: 10, hour: 3, minute: 30
        )))
        let expected = try #require(calendar.date(from: DateComponents(
            year: 2024, month: 3, day: 10, hour: 3
        )))

        #expect(try boundary.start(containing: target, calendar: calendar) == expected)
    }

    @Test
    func repeatedBoundaryUsesFirstOccurrence() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let boundary = try WorkdayBoundary(hour: 1)
        let noon = try #require(calendar.date(from: DateComponents(
            year: 2024, month: 11, day: 3, hour: 12
        )))
        let dayStart = try #require(calendar.dateInterval(of: .day, for: noon)?.start)
        let expected = try #require(calendar.nextDate(
            after: dayStart.addingTimeInterval(-1),
            matching: DateComponents(hour: 1, minute: 0, second: 0),
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .first,
            direction: .forward
        ))

        #expect(try boundary.start(containing: noon, calendar: calendar) == expected)
    }

    @Test
    func subHourDSTGapStaysOnTheCivilDayAndUsesItsFirstValidInstant() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Australia/Lord_Howe"))
        let boundary = try WorkdayBoundary(hour: 2)
        let target = instant("2026-10-03T16:30:00Z")

        #expect(try boundary.start(containing: target, calendar: calendar)
            == instant("2026-10-03T15:30:00Z"))
    }

    @Test
    func subHourDSTRepeatKeepsTheConfiguredCivilBoundary() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Australia/Lord_Howe"))
        let boundary = try WorkdayBoundary(hour: 2)
        let target = instant("2026-04-04T17:00:00Z")

        #expect(try boundary.start(containing: target, calendar: calendar)
            == instant("2026-04-04T15:30:00Z"))
    }

    private func instant(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }
}
