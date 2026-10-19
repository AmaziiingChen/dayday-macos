import DaydayCore
import Foundation

/// Public, privacy-closed configuration for the in-memory input accumulator.
public struct InputAggregationAccumulatorConfiguration: Equatable, Sendable {
    public let timeZoneIdentifier: String
    public let gridRows: UInt16
    public let gridColumns: UInt16
    public let collectorVersion: String
    public let defaultLayoutVersion: String

    public init(
        timeZoneIdentifier: String,
        gridRows: UInt16 = 24,
        gridColumns: UInt16 = 32,
        collectorVersion: String,
        defaultLayoutVersion: String
    ) throws {
        guard TimeZone(identifier: timeZoneIdentifier) != nil else {
            throw InputAggregationAccumulatorError.invalidTimeZoneIdentifier(
                timeZoneIdentifier
            )
        }
        guard gridRows > 0,
              gridColumns > 0,
              gridRows <= NormalizedDisplayGrid.maximumDimension,
              gridColumns <= NormalizedDisplayGrid.maximumDimension else {
            throw InputAggregationAccumulatorError.invalidGridDimensions(
                rows: gridRows,
                columns: gridColumns
            )
        }
        guard Self.isValidVersion(collectorVersion) else {
            throw InputAggregationAccumulatorError.invalidVersion(collectorVersion)
        }
        guard Self.isValidVersion(defaultLayoutVersion) else {
            throw InputAggregationAccumulatorError.invalidVersion(defaultLayoutVersion)
        }

        self.timeZoneIdentifier = timeZoneIdentifier
        self.gridRows = gridRows
        self.gridColumns = gridColumns
        self.collectorVersion = collectorVersion
        self.defaultLayoutVersion = defaultLayoutVersion
    }

    fileprivate static func isValidVersion(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 64
            && value.utf8.allSatisfy { byte in
                (48...57).contains(byte)
                    || (65...90).contains(byte)
                    || (97...122).contains(byte)
                    || byte == 46
                    || byte == 43
                    || byte == 45
                    || byte == 95
            }
    }
}

public enum InputAggregationAccumulatorError: Error, Equatable, Sendable {
    case invalidTimeZoneIdentifier(String)
    case invalidGridDimensions(rows: UInt16, columns: UInt16)
    case invalidVersion(String)
    case invalidTimestamp
    case invalidInterval
    case invalidNormalizedLocation
    case bucketAlreadyFlushed
    case unsignedOverflow
    case includedDurationExceedsBucket
    case aggregateInvariantViolation
}

/// Aggregate-only state suitable for diagnostics and UI composition.
public struct InputAggregationAccumulatorSnapshot: Equatable, Sendable {
    public let pendingPeriods: [InputAggregatePeriod]
    public let sealedThrough: Date?

    public init(pendingPeriods: [InputAggregatePeriod], sealedThrough: Date?) {
        self.pendingPeriods = pendingPeriods
        self.sealedThrough = sealedThrough
    }
}

/// Swift-concurrency-safe, memory-only input coarsening boundary.
///
/// Raw interaction methods and sample types are module-internal. Other modules
/// can observe only immutable aggregate facts and control completed-bucket
/// flushes; they cannot serialize, log, or retain an event-shaped public value.
public actor InputAggregationAccumulator {
    /// An input cluster remains continuous only while another admitted event
    /// arrives within this interval. The timestamp itself never leaves this
    /// actor; persisted aggregates retain only the resulting hourly total.
    private static let detectedInteractionGap: TimeInterval = 60

    private let configuration: InputAggregationAccumulatorConfiguration
    private var buckets: [InputAggregatePeriod: Bucket] = [:]
    private var sealedThrough: Date?
    private var lastDetectedInteractionAt: Date?

    public init(configuration: InputAggregationAccumulatorConfiguration) {
        self.configuration = configuration
    }

    public func snapshot() -> InputAggregationAccumulatorSnapshot {
        InputAggregationAccumulatorSnapshot(
            pendingPeriods: buckets.keys.sorted { $0.start < $1.start },
            sealedThrough: sealedThrough
        )
    }

    /// Produces privacy-closed snapshots for open civil-hour buckets without
    /// sealing them. The caller persists these as replaceable checkpoints; no
    /// raw event, timestamp, coordinate, or input ordering leaves Capture.
    public func openCheckpoints(at checkpointedAt: Date) throws -> [InputAggregateCheckpoint] {
        guard checkpointedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw InputAggregationAccumulatorError.invalidTimestamp
        }
        return try buckets.values
            .sorted { $0.period.start < $1.period.start }
            .map { bucket in
                try InputAggregateCheckpoint(
                    aggregate: makeAggregate(from: bucket),
                    revision: bucket.revision,
                    checkpointedAt: checkpointedAt
                )
            }
    }

    /// Restores a durable open-hour checkpoint before any new samples are
    /// admitted. Restored data stays aggregate-only and retains its stable
    /// bucket identity so subsequent checkpoints replace it instead of
    /// duplicating counts after a restart.
    public func restore(_ checkpoint: InputAggregateCheckpoint) throws {
        let aggregate = checkpoint.aggregate
        guard aggregate.period.granularity == .hour else {
            throw InputAggregationAccumulatorError.aggregateInvariantViolation
        }
        guard buckets[aggregate.period] == nil else {
            throw InputAggregationAccumulatorError.aggregateInvariantViolation
        }
        let restoredDisplays = Dictionary(uniqueKeysWithValues: aggregate.displays.map { item in
            let cells = Dictionary(uniqueKeysWithValues: item.grid.cells.map { cell in
                (
                    GridCellKey(row: cell.row, column: cell.column),
                    MutableGridCell(
                        clicks: MutableClickCounts(cell.clicks),
                        dwellMilliseconds: cell.dwellMilliseconds
                    )
                )
            })
            return (
                DisplayRevisionKey(display: item.display),
                MutableDisplayTotals(
                    display: item.display,
                    pointer: MutablePointerTotals(item.pointer),
                    cells: cells
                )
            )
        })
        let restoredApplications = Dictionary(uniqueKeysWithValues: aggregate.applicationTotals.map {
            ($0.applicationIdentifier, MutableApplicationTotals(keyCount: $0.keyCount, pointer: MutablePointerTotals($0.pointer)))
        })
        let restoredCoverage: [CoverageInterval]
        if aggregate.includedDurationMilliseconds > 0 {
            let end = aggregate.period.start.addingTimeInterval(
                Double(aggregate.includedDurationMilliseconds) / 1_000
            )
            restoredCoverage = [CoverageInterval(start: aggregate.period.start, end: end)]
        } else {
            restoredCoverage = []
        }
        buckets[aggregate.period] = Bucket(
            id: aggregate.id,
            period: aggregate.period,
            physicalKeyCounts: Dictionary(uniqueKeysWithValues: aggregate.physicalKeyCounts.map {
                ($0.hardwareKeyCode, $0.count)
            }),
            applications: restoredApplications,
            displays: restoredDisplays,
            coverageIntervals: restoredCoverage,
            layoutVersions: Set(aggregate.layoutVersions),
            revision: checkpoint.revision
        )
    }

    /// Flushes only whole civil-hour buckets ending at or before `cutoff`.
    /// Repeating a flush is an observable no-op, and later samples cannot
    /// recreate a bucket that has already been sealed.
    public func flush(completedBefore cutoff: Date) throws -> [InputAggregate] {
        let aggregates = try completedAggregates(endingBefore: cutoff)
        try seal(aggregates)
        if sealedThrough.map({ cutoff > $0 }) ?? true {
            sealedThrough = cutoff
        }
        return aggregates
    }

    /// Returns complete buckets without mutating memory. Production storage
    /// must finalize these first, then call ``seal(_:)`` only after its
    /// transaction commits; this prevents a transient disk failure from
    /// turning an admitted aggregate into silent data loss.
    public func completedAggregates(endingBefore cutoff: Date) throws -> [InputAggregate] {
        guard cutoff.timeIntervalSinceReferenceDate.isFinite else {
            throw InputAggregationAccumulatorError.invalidTimestamp
        }

        let periods = buckets.keys
            .filter { $0.end <= cutoff }
            .sorted { $0.start < $1.start }
        var aggregates: [InputAggregate] = []
        aggregates.reserveCapacity(periods.count)
        for period in periods {
            guard let bucket = buckets[period] else { continue }
            aggregates.append(try makeAggregate(from: bucket))
        }

        return aggregates
    }

    /// Seals exactly the complete buckets returned by
    /// ``completedAggregates(endingBefore:)`` after durable finalization.
    public func seal(_ aggregates: [InputAggregate]) throws {
        var periods = Set<InputAggregatePeriod>()
        for aggregate in aggregates {
            guard aggregate.period.granularity == .hour,
                  let bucket = buckets[aggregate.period],
                  try makeAggregate(from: bucket) == aggregate,
                  periods.insert(aggregate.period).inserted
            else { throw InputAggregationAccumulatorError.aggregateInvariantViolation }
        }
        for period in periods { buckets.removeValue(forKey: period) }
        if let latest = aggregates.map(\.period.end).max(),
           sealedThrough.map({ latest > $0 }) ?? true {
            sealedThrough = latest
        }
    }

    func record(
        _ sample: TransientPhysicalKeySample,
        disposition: EventSecurityDisposition
    ) throws {
        guard disposition == .allowed else { return }
        let period = try period(containing: sample.occurredAt)
        try ensureOpen(period)

        var candidate = buckets
        try recordDetectedInteraction(endingAt: sample.occurredAt, in: &candidate)
        var bucket = candidate[period] ?? makeBucket(period: period)
        try bucket.touch()
        bucket.layoutVersions.insert(sample.layoutVersion)
        bucket.physicalKeyCounts[sample.hardwareKeyCode] = try checkedAdd(
            bucket.physicalKeyCounts[sample.hardwareKeyCode, default: 0],
            1
        )
        if let applicationIdentifier = sample.applicationIdentifier {
            var application = bucket.applications[applicationIdentifier]
                ?? MutableApplicationTotals()
            application.keyCount = try checkedAdd(application.keyCount, 1)
            bucket.applications[applicationIdentifier] = application
        }
        candidate[period] = bucket
        buckets = candidate
        lastDetectedInteractionAt = sample.occurredAt
    }

    func record(
        _ sample: TransientPointerSample,
        disposition: EventSecurityDisposition
    ) throws {
        guard disposition == .allowed, sample.action.hasContribution else { return }
        let period = try period(containing: sample.occurredAt)
        try ensureOpen(period)

        let cell = try gridCell(for: sample.location)
        var candidate = buckets
        try recordDetectedInteraction(endingAt: sample.occurredAt, in: &candidate)
        var bucket = candidate[period] ?? makeBucket(period: period)
        try bucket.touch()
        let displayKey = DisplayRevisionKey(display: sample.display)
        var display = bucket.displays[displayKey]
            ?? MutableDisplayTotals(display: sample.display)
        try display.apply(sample.action, at: cell, checkedAdd: checkedAdd)
        bucket.displays[displayKey] = display

        if let applicationIdentifier = sample.applicationIdentifier,
           sample.action.contributesToApplicationTotals {
            var application = bucket.applications[applicationIdentifier]
                ?? MutableApplicationTotals()
            try application.apply(sample.action, checkedAdd: checkedAdd)
            bucket.applications[applicationIdentifier] = application
        }
        candidate[period] = bucket
        buckets = candidate
        lastDetectedInteractionAt = sample.occurredAt
    }

    func record(
        _ sample: TransientInputCoverageSample,
        disposition: EventSecurityDisposition
    ) throws {
        guard disposition == .allowed else { return }
        guard sample.startedAt.timeIntervalSinceReferenceDate.isFinite,
              sample.endedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw InputAggregationAccumulatorError.invalidTimestamp
        }
        guard sample.startedAt < sample.endedAt else {
            throw InputAggregationAccumulatorError.invalidInterval
        }

        var candidate = buckets
        var cursor = sample.startedAt
        while cursor < sample.endedAt {
            let period = try period(containing: cursor)
            try ensureOpen(period)
            let overlapEnd = min(period.end, sample.endedAt)
            let overlapMilliseconds = try milliseconds(from: cursor, to: overlapEnd)
            if overlapMilliseconds > 0 {
                var bucket = candidate[period] ?? makeBucket(period: period)
                try bucket.touch()
                bucket.coverageIntervals = coalescing(
                    CoverageInterval(start: cursor, end: overlapEnd),
                    into: bucket.coverageIntervals
                )
                let included = try coverageMilliseconds(bucket.coverageIntervals)
                let maximum = try milliseconds(from: period.start, to: period.end)
                guard included <= maximum else {
                    throw InputAggregationAccumulatorError.includedDurationExceedsBucket
                }
                candidate[period] = bucket
            }
            cursor = overlapEnd
        }
        buckets = candidate
    }

    private func period(containing timestamp: Date) throws -> InputAggregatePeriod {
        guard timestamp.timeIntervalSinceReferenceDate.isFinite else {
            throw InputAggregationAccumulatorError.invalidTimestamp
        }
        do {
            return try InputAggregationPolicy.hourlyPeriod(
                containing: timestamp,
                timeZoneIdentifier: configuration.timeZoneIdentifier
            )
        } catch {
            throw InputAggregationAccumulatorError.aggregateInvariantViolation
        }
    }

    /// Records only the provable interval between two nearby admitted events.
    /// It never claims that the user remained active after the final event or
    /// across a long silent gap.
    private func recordDetectedInteraction(
        endingAt timestamp: Date,
        in candidate: inout [InputAggregatePeriod: Bucket]
    ) throws {
        guard let previous = lastDetectedInteractionAt,
              timestamp > previous,
              timestamp.timeIntervalSince(previous) <= Self.detectedInteractionGap
        else { return }
        try recordCoverage(
            TransientInputCoverageSample(startedAt: previous, endedAt: timestamp),
            in: &candidate
        )
    }

    private func recordCoverage(
        _ sample: TransientInputCoverageSample,
        in candidate: inout [InputAggregatePeriod: Bucket]
    ) throws {
        var cursor = sample.startedAt
        while cursor < sample.endedAt {
            let period = try period(containing: cursor)
            try ensureOpen(period)
            let overlapEnd = min(period.end, sample.endedAt)
            let overlapMilliseconds = try milliseconds(from: cursor, to: overlapEnd)
            if overlapMilliseconds > 0 {
                var bucket = candidate[period] ?? makeBucket(period: period)
                try bucket.touch()
                bucket.coverageIntervals = coalescing(
                    CoverageInterval(start: cursor, end: overlapEnd),
                    into: bucket.coverageIntervals
                )
                let included = try coverageMilliseconds(bucket.coverageIntervals)
                let maximum = try milliseconds(from: period.start, to: period.end)
                guard included <= maximum else {
                    throw InputAggregationAccumulatorError.includedDurationExceedsBucket
                }
                candidate[period] = bucket
            }
            cursor = overlapEnd
        }
    }

    private func ensureOpen(_ period: InputAggregatePeriod) throws {
        if let sealedThrough, period.end <= sealedThrough {
            throw InputAggregationAccumulatorError.bucketAlreadyFlushed
        }
    }

    private func makeBucket(period: InputAggregatePeriod) -> Bucket {
        Bucket(
            id: InputAggregateID(),
            period: period,
            layoutVersions: [configuration.defaultLayoutVersion],
            revision: 1
        )
    }

    private func gridCell(
        for location: TransientNormalizedPointerLocation
    ) throws -> GridCellKey {
        guard location.x.isFinite,
              location.y.isFinite,
              (0...1).contains(location.x),
              (0...1).contains(location.y) else {
            throw InputAggregationAccumulatorError.invalidNormalizedLocation
        }
        let column = min(
            UInt16(location.x * Double(configuration.gridColumns)),
            configuration.gridColumns - 1
        )
        let row = min(
            UInt16(location.y * Double(configuration.gridRows)),
            configuration.gridRows - 1
        )
        return GridCellKey(row: row, column: column)
    }

    private func makeAggregate(from bucket: Bucket) throws -> InputAggregate {
        let includedDurationMilliseconds = try coverageMilliseconds(
            bucket.coverageIntervals
        )
        do {
            return try InputAggregate(
                id: bucket.id,
                period: bucket.period,
                physicalKeyCounts: bucket.physicalKeyCounts.map {
                    PhysicalKeyCount(hardwareKeyCode: $0.key, count: $0.value)
                },
                // Kept in the encoded schema for backward-compatible reads;
                // all new aggregates deliberately persist the retired metric as zero.
                committedCharacterCount: 0,
                applicationTotals: bucket.applications.map { identifier, totals in
                    ApplicationInputTotals(
                        applicationIdentifier: identifier,
                        keyCount: totals.keyCount,
                        pointer: totals.pointer.immutable
                    )
                },
                displays: try bucket.displays.values.map { display in
                    DisplayInputAggregate(
                        display: display.display,
                        pointer: display.pointer.immutable,
                        grid: try NormalizedDisplayGrid(
                            rows: configuration.gridRows,
                            columns: configuration.gridColumns,
                            cells: display.cells.map { key, cell in
                                NormalizedGridCell(
                                    row: key.row,
                                    column: key.column,
                                    clicks: cell.clicks.immutable,
                                    dwellMilliseconds: cell.dwellMilliseconds
                                )
                            }
                        )
                    )
                },
                includedDurationMilliseconds: includedDurationMilliseconds,
                collectorVersions: [configuration.collectorVersion],
                layoutVersions: Array(bucket.layoutVersions)
            )
        } catch {
            throw InputAggregationAccumulatorError.aggregateInvariantViolation
        }
    }

    private func checkedAdd(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
        let result = lhs.addingReportingOverflow(rhs)
        guard !result.overflow else {
            throw InputAggregationAccumulatorError.unsignedOverflow
        }
        return result.partialValue
    }

    private func milliseconds(from start: Date, to end: Date) throws -> UInt64 {
        let value = (end.timeIntervalSince(start) * 1_000).rounded(.towardZero)
        guard value.isFinite, value >= 0, let milliseconds = UInt64(exactly: value) else {
            throw InputAggregationAccumulatorError.unsignedOverflow
        }
        return milliseconds
    }

    private func coverageMilliseconds(
        _ intervals: [CoverageInterval]
    ) throws -> UInt64 {
        try intervals.reduce(into: UInt64(0)) { total, interval in
            total = try checkedAdd(
                total,
                milliseconds(from: interval.start, to: interval.end)
            )
        }
    }

    private func coalescing(
        _ added: CoverageInterval,
        into existing: [CoverageInterval]
    ) -> [CoverageInterval] {
        let ordered = (existing + [added]).sorted {
            $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start
        }
        var result: [CoverageInterval] = []
        for interval in ordered {
            guard let last = result.last else {
                result.append(interval)
                continue
            }
            if interval.start <= last.end {
                result[result.count - 1] = CoverageInterval(
                    start: last.start,
                    end: max(last.end, interval.end)
                )
            } else {
                result.append(interval)
            }
        }
        return result
    }
}

// MARK: - Module-internal transient samples

struct TransientPhysicalKeySample: Sendable {
    let occurredAt: Date
    let hardwareKeyCode: UInt16
    let applicationIdentifier: ApplicationIdentifier?
    let layoutVersion: String

    init(
        occurredAt: Date,
        hardwareKeyCode: UInt16,
        applicationIdentifier: ApplicationIdentifier?,
        layoutVersion: String
    ) throws {
        guard occurredAt.timeIntervalSinceReferenceDate.isFinite else {
            throw InputAggregationAccumulatorError.invalidTimestamp
        }
        guard InputAggregationAccumulatorConfiguration.isValidVersion(layoutVersion) else {
            throw InputAggregationAccumulatorError.invalidVersion(layoutVersion)
        }
        self.occurredAt = occurredAt
        self.hardwareKeyCode = hardwareKeyCode
        self.applicationIdentifier = applicationIdentifier
        self.layoutVersion = layoutVersion
    }
}

struct TransientNormalizedPointerLocation: Sendable {
    let x: Double
    let y: Double

    init(x: Double, y: Double) throws {
        guard x.isFinite, y.isFinite,
              (0...1).contains(x), (0...1).contains(y) else {
            throw InputAggregationAccumulatorError.invalidNormalizedLocation
        }
        self.x = x
        self.y = y
    }
}

enum TransientPointerButton: Sendable {
    case left
    case right
    case other
}

enum TransientScrollDirection: Sendable {
    case up
    case down
    case left
    case right
}

enum TransientPointerAction: Sendable {
    case click(TransientPointerButton)
    case scroll(TransientScrollDirection, magnitude: UInt64, eventCount: UInt64)
    case movement(distanceMilliPoints: UInt64)
    case dwell(milliseconds: UInt64)

    var hasContribution: Bool {
        switch self {
        case .click:
            return true
        case let .scroll(_, magnitude, _):
            return magnitude > 0
        case let .movement(distanceMilliPoints):
            return distanceMilliPoints > 0
        case let .dwell(milliseconds):
            return milliseconds > 0
        }
    }

    var contributesToApplicationTotals: Bool {
        switch self {
        case .click, .scroll, .movement:
            return true
        case .dwell:
            return false
        }
    }
}

struct TransientPointerSample: Sendable {
    let occurredAt: Date
    let display: DisplayContext
    let applicationIdentifier: ApplicationIdentifier?
    let location: TransientNormalizedPointerLocation
    let action: TransientPointerAction

    init(
        occurredAt: Date,
        display: DisplayContext,
        applicationIdentifier: ApplicationIdentifier?,
        location: TransientNormalizedPointerLocation,
        action: TransientPointerAction
    ) throws {
        guard occurredAt.timeIntervalSinceReferenceDate.isFinite else {
            throw InputAggregationAccumulatorError.invalidTimestamp
        }
        self.occurredAt = occurredAt
        self.display = display
        self.applicationIdentifier = applicationIdentifier
        self.location = location
        self.action = action
    }
}

struct TransientInputCoverageSample: Sendable {
    let startedAt: Date
    let endedAt: Date

    init(startedAt: Date, endedAt: Date) throws {
        guard startedAt.timeIntervalSinceReferenceDate.isFinite,
              endedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw InputAggregationAccumulatorError.invalidTimestamp
        }
        guard startedAt < endedAt else {
            throw InputAggregationAccumulatorError.invalidInterval
        }
        self.startedAt = startedAt
        self.endedAt = endedAt
    }
}

// MARK: - Mutable aggregate internals

private struct Bucket: Sendable {
    let id: InputAggregateID
    let period: InputAggregatePeriod
    var physicalKeyCounts: [UInt16: UInt64] = [:]
    var applications: [ApplicationIdentifier: MutableApplicationTotals] = [:]
    var displays: [DisplayRevisionKey: MutableDisplayTotals] = [:]
    var coverageIntervals: [CoverageInterval] = []
    var layoutVersions: Set<String>
    var revision: UInt64

    mutating func touch() throws {
        let next = revision.addingReportingOverflow(1)
        guard !next.overflow else { throw InputAggregationAccumulatorError.unsignedOverflow }
        revision = next.partialValue
    }
}

private struct CoverageInterval: Sendable {
    let start: Date
    let end: Date
}

private struct DisplayRevisionKey: Hashable, Sendable {
    let id: DisplayID
    let topologyRevision: UInt64

    init(display: DisplayContext) {
        id = display.id
        topologyRevision = display.topologyRevision
    }
}

private struct GridCellKey: Hashable, Sendable {
    let row: UInt16
    let column: UInt16
}

private struct MutableClickCounts: Sendable {
    var left: UInt64 = 0
    var right: UInt64 = 0
    var other: UInt64 = 0

    var immutable: ClickCounts {
        ClickCounts(left: left, right: right, other: other)
    }

    init(_ value: ClickCounts = ClickCounts()) {
        left = value.left
        right = value.right
        other = value.other
    }

    mutating func add(
        _ button: TransientPointerButton,
        checkedAdd: (UInt64, UInt64) throws -> UInt64
    ) throws {
        switch button {
        case .left:
            left = try checkedAdd(left, 1)
        case .right:
            right = try checkedAdd(right, 1)
        case .other:
            other = try checkedAdd(other, 1)
        }
    }
}

private struct MutableScrollTotals: Sendable {
    var up: UInt64 = 0
    var down: UInt64 = 0
    var left: UInt64 = 0
    var right: UInt64 = 0

    var immutable: ScrollTotals {
        ScrollTotals(up: up, down: down, left: left, right: right)
    }

    init(_ value: ScrollTotals = ScrollTotals()) {
        up = value.up
        down = value.down
        left = value.left
        right = value.right
    }

    mutating func add(
        _ direction: TransientScrollDirection,
        magnitude: UInt64,
        checkedAdd: (UInt64, UInt64) throws -> UInt64
    ) throws {
        switch direction {
        case .up:
            up = try checkedAdd(up, magnitude)
        case .down:
            down = try checkedAdd(down, magnitude)
        case .left:
            left = try checkedAdd(left, magnitude)
        case .right:
            right = try checkedAdd(right, magnitude)
        }
    }
}

private struct MutablePointerTotals: Sendable {
    var clicks = MutableClickCounts()
    var scroll = MutableScrollTotals()
    var scrollEventCount: UInt64 = 0
    var estimatedDistanceMilliPoints: UInt64 = 0

    var immutable: PointerTotals {
        PointerTotals(
            clicks: clicks.immutable,
            scroll: scroll.immutable,
            scrollEventCount: scrollEventCount,
            estimatedDistanceMilliPoints: estimatedDistanceMilliPoints
        )
    }

    init(_ value: PointerTotals = PointerTotals()) {
        clicks = MutableClickCounts(value.clicks)
        scroll = MutableScrollTotals(value.scroll)
        scrollEventCount = value.scrollEventCount
        estimatedDistanceMilliPoints = value.estimatedDistanceMilliPoints
    }

    mutating func apply(
        _ action: TransientPointerAction,
        checkedAdd: (UInt64, UInt64) throws -> UInt64
    ) throws {
        switch action {
        case let .click(button):
            try clicks.add(button, checkedAdd: checkedAdd)
        case let .scroll(direction, magnitude, eventCount):
            try scroll.add(direction, magnitude: magnitude, checkedAdd: checkedAdd)
            scrollEventCount = try checkedAdd(scrollEventCount, eventCount)
        case let .movement(distance):
            estimatedDistanceMilliPoints = try checkedAdd(
                estimatedDistanceMilliPoints,
                distance
            )
        case .dwell:
            break
        }
    }
}

private struct MutableApplicationTotals: Sendable {
    var keyCount: UInt64 = 0
    var pointer = MutablePointerTotals()

    init(keyCount: UInt64 = 0, pointer: MutablePointerTotals = MutablePointerTotals()) {
        self.keyCount = keyCount
        self.pointer = pointer
    }

    mutating func apply(
        _ action: TransientPointerAction,
        checkedAdd: (UInt64, UInt64) throws -> UInt64
    ) throws {
        try pointer.apply(action, checkedAdd: checkedAdd)
    }
}

private struct MutableGridCell: Sendable {
    var clicks = MutableClickCounts()
    var dwellMilliseconds: UInt64 = 0
}

private struct MutableDisplayTotals: Sendable {
    let display: DisplayContext
    var pointer = MutablePointerTotals()
    var cells: [GridCellKey: MutableGridCell] = [:]

    init(
        display: DisplayContext,
        pointer: MutablePointerTotals = MutablePointerTotals(),
        cells: [GridCellKey: MutableGridCell] = [:]
    ) {
        self.display = display
        self.pointer = pointer
        self.cells = cells
    }

    mutating func apply(
        _ action: TransientPointerAction,
        at cellKey: GridCellKey,
        checkedAdd: (UInt64, UInt64) throws -> UInt64
    ) throws {
        try pointer.apply(action, checkedAdd: checkedAdd)
        switch action {
        case let .click(button):
            var cell = cells[cellKey] ?? MutableGridCell()
            try cell.clicks.add(button, checkedAdd: checkedAdd)
            cells[cellKey] = cell
        case let .dwell(milliseconds):
            var cell = cells[cellKey] ?? MutableGridCell()
            cell.dwellMilliseconds = try checkedAdd(
                cell.dwellMilliseconds,
                milliseconds
            )
            cells[cellKey] = cell
        case .scroll, .movement:
            break
        }
    }
}
