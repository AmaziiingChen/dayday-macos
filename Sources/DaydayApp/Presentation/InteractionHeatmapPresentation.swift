import DaydayCore
import Foundation

/// Read-only, civil-time presentation of privacy-closed keyboard and pointer
/// actions. It intentionally measures observed interaction events, not
/// presence, foreground duration, focus, or productivity.
struct InteractionHeatmapPresentation: Equatable {
    struct Day: Identifiable, Equatable {
        struct Cell: Identifiable, Equatable {
            let hour: Int
            let keyPressCount: UInt64
            let pointerClickCount: UInt64
            let scrollActionCount: UInt64
            let interactionCount: UInt64
            let objectiveRecordCount: UInt64

            var hasAggregate: Bool { objectiveRecordCount > 0 }
            var id: Int { hour }
        }

        let logicalDayStart: Date
        let timeZoneIdentifier: String
        let cells: [Cell]
        let interactionCount: UInt64
        let objectiveRecordCount: UInt64

        var id: String { "\(timeZoneIdentifier)|\(logicalDayStart.timeIntervalSinceReferenceDate)" }
    }

    let days: [Day]
    let interactionCount: UInt64
    let activeDayCount: Int
    let objectiveRecordCount: UInt64
}

enum InteractionHeatmapPresentationAdapter {
    enum AggregationError: Error, Equatable {
        case unsignedOverflow
    }

    private struct DayKey: Hashable {
        let start: Date
        let timeZoneIdentifier: String
    }

    private struct MutableDay {
        var keyPressesByHour = Array(repeating: UInt64(0), count: 24)
        var clicksByHour = Array(repeating: UInt64(0), count: 24)
        var scrollsByHour = Array(repeating: UInt64(0), count: 24)
        var recordsByHour = Array(repeating: UInt64(0), count: 24)
    }

    /// A logical day continues through the following boundary hour rather than
    /// resetting at civil midnight.
    static let workdayHours = orderedHours(boundary: .standard)

    static func orderedHours(boundary: WorkdayBoundary) -> [Int] {
        Array(boundary.hour..<24) + Array(0..<boundary.hour)
    }

    /// `range` is optional for backwards-compatible callers. When present it
    /// creates every logical-day row in the requested range, including today
    /// before its first durable checkpoint is available.
    static func make(
        from aggregates: [InputAggregate],
        in range: Range<Date>? = nil,
        boundary: WorkdayBoundary = .standard
    ) throws -> InteractionHeatmapPresentation {
        var values: [DayKey: MutableDay] = [:]
        if let range {
            for key in try expectedDayKeys(in: range, boundary: boundary) {
                values[key] = MutableDay()
            }
        }

        let hourly = aggregates.filter { aggregate in
            aggregate.period.granularity == .hour
                && (range.map { aggregate.period.end > $0.lowerBound && aggregate.period.start < $0.upperBound } ?? true)
        }.sorted {
            if $0.period.start != $1.period.start { return $0.period.start < $1.period.start }
            return $0.id.rawValue.uuidString < $1.id.rawValue.uuidString
        }

        for aggregate in hourly {
            guard let timeZone = TimeZone(identifier: aggregate.period.timeZoneIdentifier) else {
                continue
            }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let logicalDayStart = try boundary.start(containing: aggregate.period.start, calendar: calendar)
            let hour = calendar.component(.hour, from: aggregate.period.start)
            guard (0..<24).contains(hour) else { continue }

            let key = DayKey(start: logicalDayStart, timeZoneIdentifier: aggregate.period.timeZoneIdentifier)
            var day = values[key] ?? MutableDay()
            let metrics = try actionMetrics(for: aggregate)
            day.keyPressesByHour[hour] = try checkedAdd(day.keyPressesByHour[hour], metrics.keyPresses)
            day.clicksByHour[hour] = try checkedAdd(day.clicksByHour[hour], metrics.clicks)
            day.scrollsByHour[hour] = try checkedAdd(day.scrollsByHour[hour], metrics.scrolls)
            day.recordsByHour[hour] = try checkedAdd(day.recordsByHour[hour], 1)
            values[key] = day
        }

        var totalInteractions: UInt64 = 0
        var totalRecords: UInt64 = 0
        var days: [InteractionHeatmapPresentation.Day] = []
        days.reserveCapacity(values.count)
        for (key, value) in values {
            let cells = try orderedHours(boundary: boundary).map { hour in
                let interactionCount = try checkedAdd(
                    try checkedAdd(value.keyPressesByHour[hour], value.clicksByHour[hour]),
                    value.scrollsByHour[hour]
                )
                return InteractionHeatmapPresentation.Day.Cell(
                    hour: hour,
                    keyPressCount: value.keyPressesByHour[hour],
                    pointerClickCount: value.clicksByHour[hour],
                    scrollActionCount: value.scrollsByHour[hour],
                    interactionCount: interactionCount,
                    objectiveRecordCount: value.recordsByHour[hour]
                )
            }
            var interactionCount: UInt64 = 0
            var recordCount: UInt64 = 0
            for cell in cells {
                interactionCount = try checkedAdd(interactionCount, cell.interactionCount)
                recordCount = try checkedAdd(recordCount, cell.objectiveRecordCount)
            }
            totalInteractions = try checkedAdd(totalInteractions, interactionCount)
            totalRecords = try checkedAdd(totalRecords, recordCount)
            days.append(InteractionHeatmapPresentation.Day(
                logicalDayStart: key.start,
                timeZoneIdentifier: key.timeZoneIdentifier,
                cells: cells,
                interactionCount: interactionCount,
                objectiveRecordCount: recordCount
            ))
        }
        days.sort {
            if $0.logicalDayStart != $1.logicalDayStart { return $0.logicalDayStart > $1.logicalDayStart }
            return $0.timeZoneIdentifier < $1.timeZoneIdentifier
        }

        return InteractionHeatmapPresentation(
            days: days,
            interactionCount: totalInteractions,
            activeDayCount: days.count(where: { $0.interactionCount > 0 }),
            objectiveRecordCount: totalRecords
        )
    }

    static func checkedAdd(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
        let result = lhs.addingReportingOverflow(rhs)
        guard !result.overflow else { throw AggregationError.unsignedOverflow }
        return result.partialValue
    }

    private static func actionMetrics(for aggregate: InputAggregate) throws
        -> (keyPresses: UInt64, clicks: UInt64, scrolls: UInt64)
    {
        let keyPresses = try aggregate.physicalKeyCounts.reduce(UInt64(0)) {
            try checkedAdd($0, $1.count)
        }
        let pointers = aggregate.displays.isEmpty
            ? aggregate.applicationTotals.map(\.pointer)
            : aggregate.displays.map(\.pointer)
        let clicks = try pointers.reduce(UInt64(0)) { total, pointer in
            let perPointer = try [pointer.clicks.left, pointer.clicks.right, pointer.clicks.other]
                .reduce(UInt64(0), checkedAdd)
            return try checkedAdd(total, perPointer)
        }
        let scrolls = try pointers.reduce(UInt64(0)) {
            try checkedAdd($0, $1.scrollEventCount)
        }
        return (keyPresses, clicks, scrolls)
    }

    private static func expectedDayKeys(
        in range: Range<Date>, boundary: WorkdayBoundary
    ) throws -> [DayKey] {
        guard range.lowerBound < range.upperBound else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        var start = try boundary.start(containing: range.lowerBound, calendar: calendar)
        var keys: [DayKey] = []
        while start < range.upperBound {
            keys.append(.init(start: start, timeZoneIdentifier: calendar.timeZone.identifier))
            guard let nextProbe = calendar.date(byAdding: .day, value: 1, to: start) else { break }
            let next = try boundary.start(containing: nextProbe, calendar: calendar)
            guard next > start else { break }
            start = next
        }
        return keys
    }
}
