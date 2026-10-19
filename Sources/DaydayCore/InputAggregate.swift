import Foundation

/// Stable identity for one logical input aggregate bucket.
public struct InputAggregateID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init() {
        self.init(rawValue: UUID())
    }
}

public enum InputAggregateGranularity: String, Codable, CaseIterable, Hashable, Sendable {
    case hour
    case day
}

/// A civil-time bucket represented by absolute UTC instants and an IANA time zone.
///
/// Hourly buckets form a disjoint civil-day partition and may be shorter or
/// longer than 60 minutes around time-zone transitions. Daily buckets may start
/// at any configured whole local hour and end at that boundary on the next
/// calendar day, including sub-hour daylight-saving changes.
public struct InputAggregatePeriod: Codable, Equatable, Hashable, Sendable {
    public enum ValidationError: Error, Equatable, Sendable {
        case invalidTimestamp
        case endNotAfterStart
        case invalidTimeZoneIdentifier(String)
        case boundaryNotAligned
        case invalidHourlyBoundary
        case missingWorkdayBoundaryHour
        case unexpectedWorkdayBoundaryHour
        case invalidDailyBoundary
    }

    public let start: Date
    public let end: Date
    public let granularity: InputAggregateGranularity
    public let timeZoneIdentifier: String
    /// Present only for daily buckets. Keeping the configured wall-clock hour
    /// avoids inferring `03:00` when a `02:00` boundary is shifted by DST.
    public let workdayBoundaryHour: Int?

    public init(
        start: Date,
        end: Date,
        granularity: InputAggregateGranularity,
        timeZoneIdentifier: String,
        workdayBoundaryHour: Int? = nil
    ) throws {
        guard start.timeIntervalSinceReferenceDate.isFinite,
              end.timeIntervalSinceReferenceDate.isFinite else {
            throw ValidationError.invalidTimestamp
        }
        guard end > start else {
            throw ValidationError.endNotAfterStart
        }
        guard let timeZone = TimeZone(identifier: timeZoneIdentifier) else {
            throw ValidationError.invalidTimeZoneIdentifier(timeZoneIdentifier)
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        switch granularity {
        case .hour:
            guard workdayBoundaryHour == nil else {
                throw ValidationError.unexpectedWorkdayBoundaryHour
            }
            let canonicalInterval: DateInterval
            do {
                canonicalInterval = try CivilHourPartition.interval(
                    containing: start,
                    calendar: calendar,
                    timeZone: timeZone
                )
            } catch {
                throw ValidationError.invalidHourlyBoundary
            }
            guard canonicalInterval.start == start else {
                throw ValidationError.boundaryNotAligned
            }
            guard canonicalInterval.end == end else {
                throw ValidationError.invalidHourlyBoundary
            }
        case .day:
            guard let workdayBoundaryHour else {
                throw ValidationError.missingWorkdayBoundaryHour
            }
            let boundary: WorkdayBoundary
            do {
                boundary = try WorkdayBoundary(hour: workdayBoundaryHour)
            } catch {
                throw ValidationError.invalidDailyBoundary
            }
            guard try boundary.start(containing: start, calendar: calendar) == start,
                  let nextCivilDay = calendar.date(
                    byAdding: .day,
                    value: 1,
                    to: calendar.startOfDay(for: start)
                  ),
                  let nextDayProbe = calendar.date(
                    bySettingHour: 23,
                    minute: 0,
                    second: 0,
                    of: nextCivilDay
                  ),
                  try boundary.start(containing: nextDayProbe, calendar: calendar) == end else {
                throw ValidationError.invalidDailyBoundary
            }
        }

        self.start = start
        self.end = end
        self.granularity = granularity
        self.timeZoneIdentifier = timeZoneIdentifier
        self.workdayBoundaryHour = workdayBoundaryHour
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            start: container.decode(Date.self, forKey: .start),
            end: container.decode(Date.self, forKey: .end),
            granularity: container.decode(InputAggregateGranularity.self, forKey: .granularity),
            timeZoneIdentifier: container.decode(String.self, forKey: .timeZoneIdentifier),
            workdayBoundaryHour: container.decodeIfPresent(
                Int.self,
                forKey: .workdayBoundaryHour
            )
        )
    }

    private enum CodingKeys: String, CodingKey {
        case start
        case end
        case granularity
        case timeZoneIdentifier
        case workdayBoundaryHour
    }

}

/// Creates a disjoint partition of one civil day from nominal wall-clock hour
/// boundaries plus every actual offset transition. Calendar `.hour` intervals
/// can overlap in zones with sub-hour DST changes (for example Lord Howe), so
/// they are not safe persistence or rollup boundaries on their own.
enum CivilHourPartition {
    enum CalculationError: Error {
        case dayUnavailable
        case boundaryUnavailable
        case intervalUnavailable
    }

    static func interval(
        containing timestamp: Date,
        calendar: Calendar,
        timeZone: TimeZone
    ) throws -> DateInterval {
        guard timestamp.timeIntervalSinceReferenceDate.isFinite,
              let day = calendar.dateInterval(of: .day, for: timestamp) else {
            throw CalculationError.dayUnavailable
        }

        let civilDate = calendar.dateComponents([.era, .year, .month, .day], from: day.start)
        var boundaries = [day.start, day.end]
        boundaries.reserveCapacity(27)

        for hour in 0..<24 {
            var components = civilDate
            components.calendar = calendar
            components.timeZone = timeZone
            components.hour = hour
            components.minute = 0
            components.second = 0
            components.nanosecond = 0
            guard let boundary = calendar.date(from: components) else {
                throw CalculationError.boundaryUnavailable
            }
            if boundary >= day.start, boundary <= day.end {
                boundaries.append(boundary)
            }
        }

        var transitionCursor = day.start.addingTimeInterval(-0.001)
        while let transition = timeZone.nextDaylightSavingTimeTransition(
            after: transitionCursor
        ), transition < day.end {
            if transition > day.start {
                boundaries.append(transition)
            }
            transitionCursor = transition.addingTimeInterval(0.001)
        }

        boundaries.sort()
        boundaries = boundaries.reduce(into: []) { unique, boundary in
            if unique.last != boundary {
                unique.append(boundary)
            }
        }

        for index in boundaries.indices.dropLast() {
            let start = boundaries[index]
            let end = boundaries[index + 1]
            if timestamp >= start, timestamp < end {
                return DateInterval(start: start, end: end)
            }
        }
        throw CalculationError.intervalUnavailable
    }
}

/// One unordered physical-key counter. It deliberately contains no timestamp,
/// character, modifier combination, application, or preceding/following key.
public struct PhysicalKeyCount: Codable, Equatable, Hashable, Sendable {
    public let hardwareKeyCode: UInt16
    public let count: UInt64

    public init(hardwareKeyCode: UInt16, count: UInt64) {
        self.hardwareKeyCode = hardwareKeyCode
        self.count = count
    }
}

public struct ClickCounts: Codable, Equatable, Hashable, Sendable {
    public let left: UInt64
    public let right: UInt64
    public let other: UInt64

    public init(left: UInt64 = 0, right: UInt64 = 0, other: UInt64 = 0) {
        self.left = left
        self.right = right
        self.other = other
    }
}

/// Directional magnitudes preserve useful scroll information without signed
/// cancellation. Non-negative components make checked merges associative for
/// every representable total.
public struct ScrollTotals: Codable, Equatable, Hashable, Sendable {
    public let up: UInt64
    public let down: UInt64
    public let left: UInt64
    public let right: UInt64

    public init(
        up: UInt64 = 0,
        down: UInt64 = 0,
        left: UInt64 = 0,
        right: UInt64 = 0
    ) {
        self.up = up
        self.down = down
        self.left = left
        self.right = right
    }
}

/// Aggregate pointer values use integer units so merges are deterministic.
/// Distance is measured in thousandths of a display point.
public struct PointerTotals: Codable, Equatable, Hashable, Sendable {
    public let clicks: ClickCounts
    public let scroll: ScrollTotals
    /// Number of observed system scroll-wheel events with a non-zero axis.
    /// This is intentionally distinct from the directional scroll magnitudes:
    /// one diagonal gesture can affect two magnitudes but is still one action.
    public let scrollEventCount: UInt64
    public let estimatedDistanceMilliPoints: UInt64

    public init(
        clicks: ClickCounts = ClickCounts(),
        scroll: ScrollTotals = ScrollTotals(),
        scrollEventCount: UInt64 = 0,
        estimatedDistanceMilliPoints: UInt64 = 0
    ) {
        self.clicks = clicks
        self.scroll = scroll
        self.scrollEventCount = scrollEventCount
        self.estimatedDistanceMilliPoints = estimatedDistanceMilliPoints
    }

    /// Existing local aggregates intentionally remain readable. Their former
    /// scroll values are direction magnitudes, not recoverable event counts,
    /// so an omitted count defaults to zero rather than being inferred.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            clicks: try container.decode(ClickCounts.self, forKey: .clicks),
            scroll: try container.decode(ScrollTotals.self, forKey: .scroll),
            scrollEventCount: try container.decodeIfPresent(
                UInt64.self, forKey: .scrollEventCount
            ) ?? 0,
            estimatedDistanceMilliPoints: try container.decode(
                UInt64.self, forKey: .estimatedDistanceMilliPoints
            )
        )
    }

    private enum CodingKeys: String, CodingKey {
        case clicks
        case scroll
        case scrollEventCount
        case estimatedDistanceMilliPoints
    }
}

/// A coarse cell in a normalized display grid. Row/column indices reveal only
/// a bin, never the precise pointer coordinate or its path through time.
public struct NormalizedGridCell: Codable, Equatable, Hashable, Sendable {
    public let row: UInt16
    public let column: UInt16
    public let clicks: ClickCounts
    public let dwellMilliseconds: UInt64

    public init(
        row: UInt16,
        column: UInt16,
        clicks: ClickCounts = ClickCounts(),
        dwellMilliseconds: UInt64 = 0
    ) {
        self.row = row
        self.column = column
        self.clicks = clicks
        self.dwellMilliseconds = dwellMilliseconds
    }
}

public struct NormalizedDisplayGrid: Codable, Equatable, Hashable, Sendable {
    public enum ValidationError: Error, Equatable, Sendable {
        case invalidDimensions(rows: UInt16, columns: UInt16)
        case cellOutOfRange(row: UInt16, column: UInt16)
        case duplicateCell(row: UInt16, column: UInt16)
    }

    /// A bounded grid prevents accidental use as a high-resolution coordinate log.
    public static let maximumDimension: UInt16 = 128

    public let rows: UInt16
    public let columns: UInt16
    public let cells: [NormalizedGridCell]

    public init(rows: UInt16, columns: UInt16, cells: [NormalizedGridCell]) throws {
        guard rows > 0, columns > 0,
              rows <= Self.maximumDimension,
              columns <= Self.maximumDimension else {
            throw ValidationError.invalidDimensions(rows: rows, columns: columns)
        }

        var seen = Set<GridIndex>()
        for cell in cells {
            guard cell.row < rows, cell.column < columns else {
                throw ValidationError.cellOutOfRange(row: cell.row, column: cell.column)
            }
            guard seen.insert(GridIndex(row: cell.row, column: cell.column)).inserted else {
                throw ValidationError.duplicateCell(row: cell.row, column: cell.column)
            }
        }

        self.rows = rows
        self.columns = columns
        self.cells = cells.sorted(by: Self.cellOrder)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            rows: container.decode(UInt16.self, forKey: .rows),
            columns: container.decode(UInt16.self, forKey: .columns),
            cells: container.decode([NormalizedGridCell].self, forKey: .cells)
        )
    }

    private struct GridIndex: Hashable {
        let row: UInt16
        let column: UInt16
    }

    private static func cellOrder(_ lhs: NormalizedGridCell, _ rhs: NormalizedGridCell) -> Bool {
        lhs.row == rhs.row ? lhs.column < rhs.column : lhs.row < rhs.row
    }

    private enum CodingKeys: String, CodingKey {
        case rows
        case columns
        case cells
    }
}

public struct DisplayInputAggregate: Codable, Equatable, Hashable, Sendable {
    public let display: DisplayContext
    public let pointer: PointerTotals
    public let grid: NormalizedDisplayGrid

    public init(display: DisplayContext, pointer: PointerTotals, grid: NormalizedDisplayGrid) {
        self.display = display
        self.pointer = pointer
        self.grid = grid
    }
}

/// Per-application aggregation is deliberately totals-only. There is no field
/// capable of associating a physical key code or grid cell with an application.
public struct ApplicationIdentifier: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    /// Opaque ID resolved from a separately governed application catalog. The
    /// aggregate itself cannot carry a bundle ID, title, URL, or document text.
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(UUID.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct ApplicationInputTotals: Codable, Equatable, Hashable, Sendable {
    public let applicationIdentifier: ApplicationIdentifier
    public let keyCount: UInt64
    public let pointer: PointerTotals

    public init(
        applicationIdentifier: ApplicationIdentifier,
        keyCount: UInt64,
        pointer: PointerTotals = PointerTotals()
    ) {
        self.applicationIdentifier = applicationIdentifier
        self.keyCount = keyCount
        self.pointer = pointer
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let applicationIdentifier = try container.decode(
            ApplicationIdentifier.self,
            forKey: .applicationIdentifier
        )
        let keyCount = try container.decode(UInt64.self, forKey: .keyCount)
        let pointer = try container.decode(PointerTotals.self, forKey: .pointer)
        self.init(
            applicationIdentifier: applicationIdentifier,
            keyCount: keyCount,
            pointer: pointer
        )
    }

    private enum CodingKeys: String, CodingKey {
        case applicationIdentifier
        case keyCount
        case pointer
    }
}

/// Privacy-closed hour/day input summary.
///
/// The shape cannot encode typed text, key order, exact pointer coordinates,
/// pointer trajectories, or a per-key-per-application distribution.
public struct InputAggregate: Codable, Equatable, Hashable, Sendable {
    public enum ValidationError: Error, Equatable, Sendable {
        case emptyVersionSet
        case invalidVersion(String)
        case duplicateHardwareKeyCode(UInt16)
        case duplicateApplicationIdentifier(ApplicationIdentifier)
        case duplicateDisplay(DisplayID, topologyRevision: UInt64)
        case includedDurationExceedsPeriod
    }

    public let id: InputAggregateID
    public let period: InputAggregatePeriod
    public let physicalKeyCounts: [PhysicalKeyCount]
    /// User-visible graphemes committed after a verified local text edit. This
    /// deliberately excludes paste, secure fields, unsupported controls, and
    /// every change that cannot be attributed to a preceding typing sequence.
    public let committedCharacterCount: UInt64
    public let applicationTotals: [ApplicationInputTotals]
    public let displays: [DisplayInputAggregate]
    public let includedDurationMilliseconds: UInt64
    public let collectorVersions: [String]
    public let layoutVersions: [String]

    public init(
        id: InputAggregateID = InputAggregateID(),
        period: InputAggregatePeriod,
        physicalKeyCounts: [PhysicalKeyCount] = [],
        committedCharacterCount: UInt64 = 0,
        applicationTotals: [ApplicationInputTotals] = [],
        displays: [DisplayInputAggregate] = [],
        includedDurationMilliseconds: UInt64 = 0,
        collectorVersions: [String],
        layoutVersions: [String]
    ) throws {
        let collectorVersions = try Self.validatedVersions(collectorVersions)
        let layoutVersions = try Self.validatedVersions(layoutVersions)

        var keyCodes = Set<UInt16>()
        for key in physicalKeyCounts where !keyCodes.insert(key.hardwareKeyCode).inserted {
            throw ValidationError.duplicateHardwareKeyCode(key.hardwareKeyCode)
        }

        var applications = Set<ApplicationIdentifier>()
        for application in applicationTotals
        where !applications.insert(application.applicationIdentifier).inserted {
            throw ValidationError.duplicateApplicationIdentifier(application.applicationIdentifier)
        }

        var displayKeys = Set<DisplayRevisionKey>()
        for display in displays {
            let key = DisplayRevisionKey(
                id: display.display.id,
                topologyRevision: display.display.topologyRevision
            )
            guard displayKeys.insert(key).inserted else {
                throw ValidationError.duplicateDisplay(key.id, topologyRevision: key.topologyRevision)
            }
        }

        let periodMilliseconds = period.end.timeIntervalSince(period.start) * 1_000
        guard Double(includedDurationMilliseconds) <= periodMilliseconds.rounded() else {
            throw ValidationError.includedDurationExceedsPeriod
        }

        self.id = id
        self.period = period
        self.physicalKeyCounts = physicalKeyCounts.sorted {
            $0.hardwareKeyCode < $1.hardwareKeyCode
        }
        self.committedCharacterCount = committedCharacterCount
        self.applicationTotals = applicationTotals.sorted {
            $0.applicationIdentifier.rawValue.uuidString
                < $1.applicationIdentifier.rawValue.uuidString
        }
        self.displays = displays.sorted(by: Self.displayOrder)
        self.includedDurationMilliseconds = includedDurationMilliseconds
        self.collectorVersions = collectorVersions
        self.layoutVersions = layoutVersions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(InputAggregateID.self, forKey: .id),
            period: container.decode(InputAggregatePeriod.self, forKey: .period),
            physicalKeyCounts: container.decode([PhysicalKeyCount].self, forKey: .physicalKeyCounts),
            committedCharacterCount: container.decodeIfPresent(
                UInt64.self, forKey: .committedCharacterCount
            ) ?? 0,
            applicationTotals: container.decode(
                [ApplicationInputTotals].self,
                forKey: .applicationTotals
            ),
            displays: container.decode([DisplayInputAggregate].self, forKey: .displays),
            includedDurationMilliseconds: container.decode(
                UInt64.self,
                forKey: .includedDurationMilliseconds
            ),
            collectorVersions: container.decode([String].self, forKey: .collectorVersions),
            layoutVersions: container.decode([String].self, forKey: .layoutVersions)
        )
    }

    private struct DisplayRevisionKey: Hashable {
        let id: DisplayID
        let topologyRevision: UInt64
    }

    private static func validatedVersions(_ values: [String]) throws -> [String] {
        guard !values.isEmpty else {
            throw ValidationError.emptyVersionSet
        }

        var result = Set<String>()
        for value in values {
            guard !value.isEmpty,
                  value.utf8.count <= 64,
                  value.utf8.allSatisfy({ byte in
                      byte.isASCIIAlphaNumeric || byte == 46 || byte == 43 || byte == 45 || byte == 95
                  }) else {
                throw ValidationError.invalidVersion(value)
            }
            result.insert(value)
        }
        return result.sorted()
    }

    private static func displayOrder(
        _ lhs: DisplayInputAggregate,
        _ rhs: DisplayInputAggregate
    ) -> Bool {
        let lhsID = lhs.display.id.rawValue.uuidString
        let rhsID = rhs.display.id.rawValue.uuidString
        if lhsID != rhsID {
            return lhsID < rhsID
        }
        return lhs.display.topologyRevision < rhs.display.topologyRevision
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case period
        case physicalKeyCounts
        case committedCharacterCount
        case applicationTotals
        case displays
        case includedDurationMilliseconds
        case collectorVersions
        case layoutVersions
    }
}

private extension UInt8 {
    var isASCIIAlphaNumeric: Bool {
        (48...57).contains(self) || (65...90).contains(self) || (97...122).contains(self)
    }

}
