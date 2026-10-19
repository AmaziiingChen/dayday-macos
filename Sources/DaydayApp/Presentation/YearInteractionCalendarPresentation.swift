import DaydayCore
import Foundation

/// A read-only, range-wide projection of persisted input coverage arranged by
/// logical day. It deliberately has no hour-of-day distribution: a value is
/// only the duration in which input collection detected interaction on that
/// logical day, and it never establishes attendance, presence, focus, or
/// productivity.
struct YearInteractionCalendarPresentation: Equatable {
    struct DayCell: Identifiable, Equatable {
        let logicalDayStart: Date
        let timeZoneIdentifier: String
        let detectedInteractionMilliseconds: UInt64
        let objectiveRecordCount: UInt64

        var id: String { "\(timeZoneIdentifier)|\(logicalDayStart.timeIntervalSinceReferenceDate)" }
    }

    let days: [DayCell]
    let timeZoneIdentifier: String
    let detectedInteractionMilliseconds: UInt64
    let activeDayCount: Int
    let objectiveRecordCount: UInt64
}

/// Builds a complete logical-day grid for a range, overlaying stored input
/// aggregates. A daily rollup supersedes its source hours so the same workday
/// is never counted twice.
enum YearInteractionCalendarPresentationAdapter {
    enum AggregationError: Error, Equatable {
        case invalidRange
        case invalidTimeZone(String)
        case unsignedOverflow
    }

    static func make(
        from aggregates: [InputAggregate],
        in range: Range<Date>,
        timeZoneIdentifier: String
    ) throws -> YearInteractionCalendarPresentation {
        guard range.lowerBound.timeIntervalSinceReferenceDate.isFinite,
            range.upperBound.timeIntervalSinceReferenceDate.isFinite,
            range.lowerBound < range.upperBound
        else {
            throw AggregationError.invalidRange
        }
        guard let timeZone = TimeZone(identifier: timeZoneIdentifier) else {
            throw AggregationError.invalidTimeZone(timeZoneIdentifier)
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let boundary = WorkdayBoundary.standard

        var dayStarts: [Date] = []
        guard let firstStart = try? boundary.start(containing: range.lowerBound, calendar: calendar) else {
            return .init(days: [], timeZoneIdentifier: timeZoneIdentifier, detectedInteractionMilliseconds: 0, activeDayCount: 0, objectiveRecordCount: 0)
        }
        var cursor = firstStart
        while cursor < range.upperBound {
            dayStarts.append(cursor)
            // Step one logical day forward from the boundary itself. Stepping
            // from civil midnight would re-resolve to the same boundary because
            // hours before 04:00 belong to the previous logical day.
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor),
                let nextStart = try? boundary.start(containing: next, calendar: calendar),
                nextStart > cursor
            else { break }
            cursor = nextStart
        }
        guard !dayStarts.isEmpty else {
            return .init(days: [], timeZoneIdentifier: timeZoneIdentifier, detectedInteractionMilliseconds: 0, activeDayCount: 0, objectiveRecordCount: 0)
        }
        let daySet = Set(dayStarts)

        var dailyDays = Set<Date>()
        for aggregate in aggregates where aggregate.period.granularity == .day {
            dailyDays.insert(aggregate.period.start)
        }

        var totalsByDay: [Date: (milliseconds: UInt64, records: UInt64)] = [:]
        for aggregate in aggregates {
            let dayStart: Date
            if aggregate.period.granularity == .day {
                dayStart = aggregate.period.start
            } else {
                guard let start = try? boundary.start(containing: aggregate.period.start, calendar: calendar) else { continue }
                dayStart = start
            }
            guard daySet.contains(dayStart) else { continue }
            if aggregate.period.granularity == .day || !dailyDays.contains(dayStart) {
                let current = totalsByDay[dayStart] ?? (0, 0)
                totalsByDay[dayStart] = (
                    try checkedAdd(current.milliseconds, aggregate.includedDurationMilliseconds),
                    try checkedAdd(current.records, 1)
                )
            }
        }

        var totalMilliseconds: UInt64 = 0
        var totalRecords: UInt64 = 0
        var activeDayCount = 0
        let cells = dayStarts.map { start -> YearInteractionCalendarPresentation.DayCell in
            let value = totalsByDay[start] ?? (0, 0)
            return YearInteractionCalendarPresentation.DayCell(
                logicalDayStart: start,
                timeZoneIdentifier: timeZoneIdentifier,
                detectedInteractionMilliseconds: value.milliseconds,
                objectiveRecordCount: value.records
            )
        }
        for cell in cells {
            totalMilliseconds = try checkedAdd(totalMilliseconds, cell.detectedInteractionMilliseconds)
            totalRecords = try checkedAdd(totalRecords, cell.objectiveRecordCount)
            if cell.detectedInteractionMilliseconds > 0 { activeDayCount += 1 }
        }

        return YearInteractionCalendarPresentation(
            days: cells,
            timeZoneIdentifier: timeZoneIdentifier,
            detectedInteractionMilliseconds: totalMilliseconds,
            activeDayCount: activeDayCount,
            objectiveRecordCount: totalRecords
        )
    }

    static func checkedAdd(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
        let result = lhs.addingReportingOverflow(rhs)
        guard !result.overflow else { throw AggregationError.unsignedOverflow }
        return result.partialValue
    }
}
