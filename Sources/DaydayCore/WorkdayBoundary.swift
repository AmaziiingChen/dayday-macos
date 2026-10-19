import Foundation

/// Defines where a user's logical day starts in their local calendar.
///
/// A boundary at 4 means that 03:30 belongs to the preceding logical day,
/// while 04:00 starts a new one. The type is intentionally independent from
/// storage and UI so callers can inject the user's current calendar.
public struct WorkdayBoundary: Equatable, Sendable {
    public enum ValidationError: Error, Equatable, Sendable {
        case invalidHour(Int)
    }

    public enum CalculationError: Error, Equatable, Sendable {
        case dayIntervalUnavailable(Date)
        case previousDayUnavailable(Date)
        case boundaryUnavailable(Date, hour: Int)
    }

    /// The agreed product default. Users may configure a different boundary.
    public static let standard = WorkdayBoundary(validatedHour: 4)

    public let hour: Int

    public init(hour: Int) throws {
        guard (0...23).contains(hour) else {
            throw ValidationError.invalidHour(hour)
        }

        self.hour = hour
    }

    private init(validatedHour hour: Int) {
        self.hour = hour
    }

    /// Returns the boundary instant for the logical day containing `date`.
    ///
    /// The calculation uses local wall-clock components instead of subtracting
    /// absolute hours, which would drift when daylight-saving time changes.
    /// If the configured time does not exist on a spring-forward day, the
    /// boundary is the first valid local time after it. If it occurs twice on a
    /// fall-back day, the first occurrence is used.
    public func start(containing date: Date, calendar: Calendar) throws -> Date {
        guard let dateInterval = calendar.dateInterval(of: .day, for: date) else {
            throw CalculationError.dayIntervalUnavailable(date)
        }

        let localHour = calendar.component(.hour, from: date)
        let targetDayStart: Date

        if localHour >= hour {
            targetDayStart = dateInterval.start
        } else {
            guard let previousDay = calendar.date(
                byAdding: .day,
                value: -1,
                to: dateInterval.start
            ) else {
                throw CalculationError.previousDayUnavailable(dateInterval.start)
            }
            targetDayStart = previousDay
        }

        guard let targetDayInterval = calendar.dateInterval(
            of: .day,
            for: targetDayStart
        ) else {
            throw CalculationError.dayIntervalUnavailable(targetDayStart)
        }
        var components = calendar.dateComponents(
            [.era, .year, .month, .day],
            from: targetDayStart
        )
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.hour = hour
        components.minute = 0
        components.second = 0
        components.nanosecond = 0
        guard let boundary = calendar.date(from: components),
              boundary >= targetDayInterval.start,
              boundary < targetDayInterval.end else {
            throw CalculationError.boundaryUnavailable(targetDayStart, hour: hour)
        }

        return boundary
    }

    public func contains(_ lhs: Date, and rhs: Date, calendar: Calendar) throws -> Bool {
        try start(containing: lhs, calendar: calendar) == start(containing: rhs, calendar: calendar)
    }
}
