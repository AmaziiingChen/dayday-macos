import Foundation

// MARK: - Logical day

public struct LogicalDayDate: Codable, Hashable, Sendable {
    public enum ValidationError: Error, Equatable, Sendable {
        case invalidGregorianDate(year: Int, month: Int, day: Int)
    }

    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let components = DateComponents(year: year, month: month, day: day)
        guard let date = calendar.date(from: components) else {
            throw ValidationError.invalidGregorianDate(year: year, month: month, day: day)
        }

        let roundTrip = calendar.dateComponents([.year, .month, .day], from: date)
        guard roundTrip.year == year, roundTrip.month == month, roundTrip.day == day else {
            throw ValidationError.invalidGregorianDate(year: year, month: month, day: day)
        }

        self.year = year
        self.month = month
        self.day = day
    }

    private enum CodingKeys: String, CodingKey {
        case year, month, day
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            year: values.decode(Int.self, forKey: .year),
            month: values.decode(Int.self, forKey: .month),
            day: values.decode(Int.self, forKey: .day)
        )
    }
}

public struct WorkdayBoundarySnapshot: Codable, Hashable, Sendable {
    public enum ValidationError: Error, Equatable, Sendable {
        case invalidHour(Int)
        case nonFiniteDate
        case invalidInterval
    }

    public let hour: Int
    public let startsAt: Date
    public let endsAt: Date

    public init(hour: Int, startsAt: Date, endsAt: Date) throws {
        guard (0...23).contains(hour) else {
            throw ValidationError.invalidHour(hour)
        }
        guard startsAt.isFinite, endsAt.isFinite else {
            throw ValidationError.nonFiniteDate
        }
        guard startsAt < endsAt else {
            throw ValidationError.invalidInterval
        }

        self.hour = hour
        self.startsAt = startsAt
        self.endsAt = endsAt
    }

    private enum CodingKeys: String, CodingKey {
        case hour, startsAt, endsAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            hour: values.decode(Int.self, forKey: .hour),
            startsAt: values.decode(Date.self, forKey: .startsAt),
            endsAt: values.decode(Date.self, forKey: .endsAt)
        )
    }
}

public struct DayDescriptor: Codable, Hashable, Sendable {
    public enum ValidationError: Error, Equatable, Sendable {
        case invalidIANATimeZone(String)
        case boundaryDoesNotStartOnLogicalDate
        case boundaryEndDoesNotStartNextLogicalDate
    }

    public let id: DayID
    public let logicalDate: LogicalDayDate
    public let timeZoneIdentifier: String
    public let boundary: WorkdayBoundarySnapshot

    public init(
        id: DayID = DayID(),
        logicalDate: LogicalDayDate,
        timeZoneIdentifier: String,
        boundary: WorkdayBoundarySnapshot
    ) throws {
        guard Self.isKnownIANATimeZone(timeZoneIdentifier),
              let timeZone = TimeZone(identifier: timeZoneIdentifier) else {
            throw ValidationError.invalidIANATimeZone(timeZoneIdentifier)
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let logicalDayStart = calendar.date(from: DateComponents(
            year: logicalDate.year,
            month: logicalDate.month,
            day: logicalDate.day,
            hour: 0
        )), let nextLogicalDayStart = calendar.date(
            byAdding: .day,
            value: 1,
            to: logicalDayStart
        ) else {
            throw ValidationError.boundaryDoesNotStartOnLogicalDate
        }

        let policy = try WorkdayBoundary(hour: boundary.hour)
        guard let logicalDayProbe = calendar.date(
            bySettingHour: 23,
            minute: 0,
            second: 0,
            of: logicalDayStart
        ), try policy.start(containing: logicalDayProbe, calendar: calendar) == boundary.startsAt else {
            throw ValidationError.boundaryDoesNotStartOnLogicalDate
        }
        guard let nextLogicalDayProbe = calendar.date(
            bySettingHour: 23,
            minute: 0,
            second: 0,
            of: nextLogicalDayStart
        ), try policy.start(containing: nextLogicalDayProbe, calendar: calendar) == boundary.endsAt else {
            throw ValidationError.boundaryEndDoesNotStartNextLogicalDate
        }

        self.id = id
        self.logicalDate = logicalDate
        self.timeZoneIdentifier = timeZoneIdentifier
        self.boundary = boundary
    }

    private static func isKnownIANATimeZone(_ identifier: String) -> Bool {
        identifier == "UTC" || TimeZone.knownTimeZoneIdentifiers.contains(identifier)
    }

    private enum CodingKeys: String, CodingKey {
        case id, logicalDate, timeZoneIdentifier, boundary
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: values.decode(DayID.self, forKey: .id),
            logicalDate: values.decode(LogicalDayDate.self, forKey: .logicalDate),
            timeZoneIdentifier: values.decode(String.self, forKey: .timeZoneIdentifier),
            boundary: values.decode(WorkdayBoundarySnapshot.self, forKey: .boundary)
        )
    }
}

private extension Date {
    var isFinite: Bool {
        timeIntervalSinceReferenceDate.isFinite
    }
}
