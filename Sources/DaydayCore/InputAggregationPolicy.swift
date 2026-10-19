import CryptoKit
import Foundation

/// A pure, storage-independent policy for combining already-coarsened input
/// summaries. It never receives raw key or pointer events.
public enum InputAggregationPolicy {
    public enum AggregationError: Error, Equatable, Sendable {
        case incompatibleIdentity
        case incompatiblePeriod
        case incompatibleGrid(display: DisplayID, topologyRevision: UInt64)
        case unsignedOverflow
        case dailyTargetRequired
        case hourlySourceRequired
        case sourceTimeZoneMismatch
        case sourceOutsideDailyPeriod
        case duplicateSource(InputAggregateID)
        case outputCollidesWithSource(InputAggregateID)
        case overlappingHourlyPeriods
        case noHourlySources
        case invalidRetentionDays(Int)
        case invalidDailyPeriodDerivation
    }

    public static let defaultHourlyRetentionDays = 180

    /// Returns the canonical, disjoint civil-hour partition containing an
    /// instant. Boundaries include offset transitions, so unusual 30-minute DST
    /// changes never create overlapping persisted aggregates.
    public static func hourlyPeriod(
        containing timestamp: Date,
        timeZoneIdentifier: String
    ) throws -> InputAggregatePeriod {
        guard let timeZone = TimeZone(identifier: timeZoneIdentifier) else {
            throw InputAggregatePeriod.ValidationError.invalidTimeZoneIdentifier(
                timeZoneIdentifier
            )
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let interval: DateInterval
        do {
            interval = try CivilHourPartition.interval(
                containing: timestamp,
                calendar: calendar,
                timeZone: timeZone
            )
        } catch {
            throw InputAggregatePeriod.ValidationError.invalidTimestamp
        }
        return try InputAggregatePeriod(
            start: interval.start,
            end: interval.end,
            granularity: .hour,
            timeZoneIdentifier: timeZoneIdentifier
        )
    }

    /// Adds a candidate only when the privacy gate allowed collection. Metadata-only
    /// and excluded candidates have exactly zero contribution, including duration.
    public static func adding(
        _ candidate: InputAggregate,
        to accumulator: InputAggregate,
        disposition: EventSecurityDisposition
    ) throws -> InputAggregate {
        guard disposition == .allowed else {
            return accumulator
        }
        return try merge(accumulator, candidate)
    }

    /// Combines two snapshots of the same logical bucket. Both must share their
    /// stable identity and period, preventing accidental double-bucketing.
    public static func merge(
        _ lhs: InputAggregate,
        _ rhs: InputAggregate
    ) throws -> InputAggregate {
        guard lhs.id == rhs.id else {
            throw AggregationError.incompatibleIdentity
        }
        guard lhs.period == rhs.period else {
            throw AggregationError.incompatiblePeriod
        }

        return try combineContent(
            [lhs, rhs],
            outputID: lhs.id,
            outputPeriod: lhs.period
        )
    }

    /// Produces a daily value plus the explicit list of source hour IDs. This
    /// method performs no persistence or deletion. Storage must first durably
    /// save `dailyAggregate`, then explicitly delete the listed hours.
    public static func makeDailyRollup(
        id: InputAggregateID = InputAggregateID(),
        period: InputAggregatePeriod,
        hourly: [InputAggregate]
    ) throws -> DailyInputRollupPlan {
        guard period.granularity == .day else {
            throw AggregationError.dailyTargetRequired
        }
        guard !hourly.isEmpty else {
            throw AggregationError.noHourlySources
        }

        let ordered = hourly.sorted {
            if $0.period.start != $1.period.start {
                return $0.period.start < $1.period.start
            }
            return $0.id.rawValue.uuidString < $1.id.rawValue.uuidString
        }
        var seenIDs = Set<InputAggregateID>()
        var previousEnd: Date?
        for source in ordered {
            guard source.period.granularity == .hour else {
                throw AggregationError.hourlySourceRequired
            }
            guard source.period.timeZoneIdentifier == period.timeZoneIdentifier else {
                throw AggregationError.sourceTimeZoneMismatch
            }
            guard source.period.start >= period.start, source.period.end <= period.end else {
                throw AggregationError.sourceOutsideDailyPeriod
            }
            guard seenIDs.insert(source.id).inserted else {
                throw AggregationError.duplicateSource(source.id)
            }
            guard source.id != id else {
                throw AggregationError.outputCollidesWithSource(id)
            }
            if let previousEnd, source.period.start < previousEnd {
                throw AggregationError.overlappingHourlyPeriods
            }
            previousEnd = source.period.end
        }

        let aggregate = try combineContent(ordered, outputID: id, outputPeriod: period)
        return DailyInputRollupPlan(
            dailyAggregate: aggregate,
            sourceHourlyAggregateIDs: ordered.map(\InputAggregate.id)
        )
    }

    /// Returns a stable daily aggregate ID derived from the daily period, so
    /// rollup is idempotent across scheduler runs and process restarts.
    /// Distinct civil days always produce distinct IDs.
    public static func dailyRollupID(for period: InputAggregatePeriod) throws -> InputAggregateID {
        guard period.granularity == .day,
              let workdayBoundaryHour = period.workdayBoundaryHour else {
            throw AggregationError.dailyTargetRequired
        }
        var input = Data("dayday.daily-rollup.v1".utf8)
        let start = period.start.timeIntervalSinceReferenceDate
        let end = period.end.timeIntervalSinceReferenceDate
        withUnsafeBytes(of: start) { input.append(contentsOf: $0) }
        withUnsafeBytes(of: end) { input.append(contentsOf: $0) }
        input.append(Data(period.timeZoneIdentifier.utf8))
        withUnsafeBytes(of: workdayBoundaryHour) { input.append(contentsOf: $0) }

        let digest = SHA256.hash(data: input)
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let text = bytes.map { String(format: "%02x", $0) }.joined()
        guard
            let uuid = UUID(
                uuidString:
                    "\(text.prefix(8))-\(text.dropFirst(8).prefix(4))-\(text.dropFirst(12).prefix(4))-\(text.dropFirst(16).prefix(4))-\(text.dropFirst(20))"
            )
        else {
            throw AggregationError.invalidDailyPeriodDerivation
        }
        return InputAggregateID(rawValue: uuid)
    }

    /// Builds one deterministic daily rollup plan per completed civil day of the
    /// supplied hourly aggregates. Days are only rolled up once every contained
    /// hour has already ended at or before `cutoff`, so a partial day is never
    /// coalesced and deleted twice.
    public static func dailyRollupPlans(
        for hours: [InputAggregate],
        cutoff: Date,
        workdayBoundaryHour: Int
    ) throws -> [DailyInputRollupPlan] {
        var byDay: [InputAggregatePeriod: [InputAggregate]] = [:]
        for hour in hours where isEligibleForDailyRollup(hour, cutoff: cutoff) {
            let day = try dailyPeriod(containing: hour, workdayBoundaryHour: workdayBoundaryHour)
            byDay[day, default: []].append(hour)
        }

        var plans: [DailyInputRollupPlan] = []
        for (day, dayHours) in byDay {
            guard day.end <= cutoff else { continue }
            plans.append(
                try makeDailyRollup(
                    id: try dailyRollupID(for: day),
                    period: day,
                    hourly: dayHours
                )
            )
        }
        return plans.sorted { $0.dailyAggregate.period.start < $1.dailyAggregate.period.start }
    }

    /// Returns the daily period whose workday boundary contains an hourly
    /// aggregate's start instant. Hourly buckets never cross a boundary, so the
    /// hour's start selects exactly one civil day.
    private static func dailyPeriod(
        containing hour: InputAggregate,
        workdayBoundaryHour: Int
    ) throws -> InputAggregatePeriod {
        guard hour.period.granularity == .hour else {
            throw AggregationError.hourlySourceRequired
        }
        guard let timeZone = TimeZone(identifier: hour.period.timeZoneIdentifier) else {
            throw InputAggregatePeriod.ValidationError.invalidTimeZoneIdentifier(
                hour.period.timeZoneIdentifier
            )
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let boundary = try WorkdayBoundary(hour: workdayBoundaryHour)
        let start = try boundary.start(containing: hour.period.start, calendar: calendar)
        guard let nextCivilDay = calendar.date(
            byAdding: .day,
            value: 1,
            to: calendar.startOfDay(for: start)
        ),
        let probe = calendar.date(bySettingHour: 23, minute: 0, second: 0, of: nextCivilDay) else {
            throw AggregationError.invalidDailyPeriodDerivation
        }
        let end = try boundary.start(containing: probe, calendar: calendar)
        return try InputAggregatePeriod(
            start: start,
            end: end,
            granularity: .day,
            timeZoneIdentifier: hour.period.timeZoneIdentifier,
            workdayBoundaryHour: workdayBoundaryHour
        )
    }

    /// Returns the current workday boundary moved back by the retention count in
    /// local civil days. Calendar arithmetic avoids DST drift.
    public static func hourlyRollupCutoff(
        relativeTo referenceDate: Date,
        timeZoneIdentifier: String,
        workdayBoundaryHour: Int,
        retentionDays: Int = defaultHourlyRetentionDays
    ) throws -> Date {
        guard retentionDays > 0 else {
            throw AggregationError.invalidRetentionDays(retentionDays)
        }
        guard let timeZone = TimeZone(identifier: timeZoneIdentifier) else {
            throw InputAggregatePeriod.ValidationError.invalidTimeZoneIdentifier(timeZoneIdentifier)
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let boundary = try WorkdayBoundary(hour: workdayBoundaryHour)
        let currentStart = try boundary.start(containing: referenceDate, calendar: calendar)
        guard let targetCivilDay = calendar.date(
            byAdding: .day,
            value: -retentionDays,
            to: calendar.startOfDay(for: currentStart)
        ),
        let targetProbe = calendar.date(
            bySettingHour: 23,
            minute: 0,
            second: 0,
            of: targetCivilDay
        ) else {
            throw InputAggregatePeriod.ValidationError.invalidTimestamp
        }
        return try boundary.start(containing: targetProbe, calendar: calendar)
    }

    public static func isEligibleForDailyRollup(
        _ aggregate: InputAggregate,
        cutoff: Date
    ) -> Bool {
        aggregate.period.granularity == .hour && aggregate.period.end <= cutoff
    }

    private static func combineContent(
        _ aggregates: [InputAggregate],
        outputID: InputAggregateID,
        outputPeriod: InputAggregatePeriod
    ) throws -> InputAggregate {
        var keys: [UInt16: UInt64] = [:]
        var applications: [ApplicationIdentifier: ApplicationInputTotals] = [:]
        var displays: [DisplayRevisionKey: DisplayInputAggregate] = [:]
        var includedDuration: UInt64 = 0
        var collectorVersions = Set<String>()
        var layoutVersions = Set<String>()

        for aggregate in aggregates {
            includedDuration = try checkedAdd(includedDuration, aggregate.includedDurationMilliseconds)
            collectorVersions.formUnion(aggregate.collectorVersions)
            layoutVersions.formUnion(aggregate.layoutVersions)

            for key in aggregate.physicalKeyCounts {
                keys[key.hardwareKeyCode] = try checkedAdd(
                    keys[key.hardwareKeyCode, default: 0],
                    key.count
                )
            }

            for application in aggregate.applicationTotals {
                if let existing = applications[application.applicationIdentifier] {
                    applications[application.applicationIdentifier] = ApplicationInputTotals(
                        applicationIdentifier: application.applicationIdentifier,
                        keyCount: try checkedAdd(existing.keyCount, application.keyCount),
                        pointer: try mergePointer(existing.pointer, application.pointer)
                    )
                } else {
                    applications[application.applicationIdentifier] = application
                }
            }

            for display in aggregate.displays {
                let key = DisplayRevisionKey(display: display.display)
                if let existing = displays[key] {
                    displays[key] = try mergeDisplay(existing, display)
                } else {
                    displays[key] = display
                }
            }
        }

        return try InputAggregate(
            id: outputID,
            period: outputPeriod,
            physicalKeyCounts: keys.map {
                PhysicalKeyCount(hardwareKeyCode: $0.key, count: $0.value)
            },
            // The encoded field remains for old database payloads, but daily
            // projections intentionally do not carry the retired metric forward.
            committedCharacterCount: 0,
            applicationTotals: Array(applications.values),
            displays: Array(displays.values),
            includedDurationMilliseconds: includedDuration,
            collectorVersions: Array(collectorVersions),
            layoutVersions: Array(layoutVersions)
        )
    }

    private static func mergeDisplay(
        _ lhs: DisplayInputAggregate,
        _ rhs: DisplayInputAggregate
    ) throws -> DisplayInputAggregate {
        guard lhs.grid.rows == rhs.grid.rows, lhs.grid.columns == rhs.grid.columns else {
            throw AggregationError.incompatibleGrid(
                display: lhs.display.id,
                topologyRevision: lhs.display.topologyRevision
            )
        }

        struct CellKey: Hashable {
            let row: UInt16
            let column: UInt16
        }
        var cells = Dictionary(uniqueKeysWithValues: lhs.grid.cells.map {
            (CellKey(row: $0.row, column: $0.column), $0)
        })
        for cell in rhs.grid.cells {
            let key = CellKey(row: cell.row, column: cell.column)
            if let existing = cells[key] {
                cells[key] = NormalizedGridCell(
                    row: key.row,
                    column: key.column,
                    clicks: try mergeClicks(existing.clicks, cell.clicks),
                    dwellMilliseconds: try checkedAdd(
                        existing.dwellMilliseconds,
                        cell.dwellMilliseconds
                    )
                )
            } else {
                cells[key] = cell
            }
        }

        return DisplayInputAggregate(
            display: lhs.display,
            pointer: try mergePointer(lhs.pointer, rhs.pointer),
            grid: try NormalizedDisplayGrid(
                rows: lhs.grid.rows,
                columns: lhs.grid.columns,
                cells: Array(cells.values)
            )
        )
    }

    private static func mergePointer(_ lhs: PointerTotals, _ rhs: PointerTotals) throws -> PointerTotals {
        PointerTotals(
            clicks: try mergeClicks(lhs.clicks, rhs.clicks),
            scroll: try mergeScroll(lhs.scroll, rhs.scroll),
            scrollEventCount: try checkedAdd(lhs.scrollEventCount, rhs.scrollEventCount),
            estimatedDistanceMilliPoints: try checkedAdd(
                lhs.estimatedDistanceMilliPoints,
                rhs.estimatedDistanceMilliPoints
            )
        )
    }

    private static func mergeScroll(_ lhs: ScrollTotals, _ rhs: ScrollTotals) throws -> ScrollTotals {
        ScrollTotals(
            up: try checkedAdd(lhs.up, rhs.up),
            down: try checkedAdd(lhs.down, rhs.down),
            left: try checkedAdd(lhs.left, rhs.left),
            right: try checkedAdd(lhs.right, rhs.right)
        )
    }

    private static func mergeClicks(_ lhs: ClickCounts, _ rhs: ClickCounts) throws -> ClickCounts {
        ClickCounts(
            left: try checkedAdd(lhs.left, rhs.left),
            right: try checkedAdd(lhs.right, rhs.right),
            other: try checkedAdd(lhs.other, rhs.other)
        )
    }

    private static func checkedAdd(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
        let result = lhs.addingReportingOverflow(rhs)
        guard !result.overflow else {
            throw AggregationError.unsignedOverflow
        }
        return result.partialValue
    }

    private struct DisplayRevisionKey: Hashable {
        let id: DisplayID
        let topologyRevision: UInt64

        init(display: DisplayContext) {
            id = display.id
            topologyRevision = display.topologyRevision
        }
    }
}

/// A two-phase rollup result. Merely constructing this value never removes the
/// hourly sources; deletion is an explicit storage-layer action after the daily
/// aggregate is durably committed.
public struct DailyInputRollupPlan: Equatable, Hashable, Sendable {
    public let dailyAggregate: InputAggregate
    public let sourceHourlyAggregateIDs: [InputAggregateID]

    fileprivate init(
        dailyAggregate: InputAggregate,
        sourceHourlyAggregateIDs: [InputAggregateID]
    ) {
        self.dailyAggregate = dailyAggregate
        self.sourceHourlyAggregateIDs = sourceHourlyAggregateIDs
    }
}
