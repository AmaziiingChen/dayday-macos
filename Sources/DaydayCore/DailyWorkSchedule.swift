import Foundation

/// A local wall-clock time without a date or time-zone. It is suitable for owner-configured
/// recurring schedule points and remains stable across daylight-saving transitions.
public struct LocalTimeOfDay: Codable, Equatable, Hashable, Sendable {
  public enum ValidationError: Error, Equatable, Sendable {
    case invalidHour(Int)
    case invalidMinute(Int)
  }

  public let hour: Int
  public let minute: Int

  public init(hour: Int, minute: Int = 0) throws {
    guard (0...23).contains(hour) else { throw ValidationError.invalidHour(hour) }
    guard (0...59).contains(minute) else { throw ValidationError.invalidMinute(minute) }
    self.hour = hour
    self.minute = minute
  }

  public var minuteOfDay: Int { hour * 60 + minute }

  public func hasArrived(at date: Date, calendar: Calendar) -> Bool {
    let components = calendar.dateComponents([.hour, .minute], from: date)
    return (components.hour ?? 0) * 60 + (components.minute ?? 0) >= minuteOfDay
  }
}

/// The owner-visible recurring schedule used by collection summaries and report generation.
/// The logical-day boundary is deliberately independent from the displayed work start/end times.
public struct DailyWorkSchedule: Codable, Equatable, Hashable, Sendable {
  public enum ValidationError: Error, Equatable, Sendable {
    case invalidBoundaryHour(Int)
    case identicalWorkStartAndEnd
  }

  public let workStartsAt: LocalTimeOfDay
  public let workEndsAt: LocalTimeOfDay
  public let reportGeneratesAt: LocalTimeOfDay
  public let logicalDayBoundaryHour: Int

  public init(
    workStartsAt: LocalTimeOfDay,
    workEndsAt: LocalTimeOfDay,
    reportGeneratesAt: LocalTimeOfDay,
    logicalDayBoundaryHour: Int
  ) throws {
    guard (0...23).contains(logicalDayBoundaryHour) else {
      throw ValidationError.invalidBoundaryHour(logicalDayBoundaryHour)
    }
    guard workStartsAt != workEndsAt else { throw ValidationError.identicalWorkStartAndEnd }
    self.workStartsAt = workStartsAt
    self.workEndsAt = workEndsAt
    self.reportGeneratesAt = reportGeneratesAt
    self.logicalDayBoundaryHour = logicalDayBoundaryHour
  }

  public static let standard = try! DailyWorkSchedule(
    workStartsAt: LocalTimeOfDay(hour: 9),
    workEndsAt: LocalTimeOfDay(hour: 18),
    reportGeneratesAt: LocalTimeOfDay(hour: 18),
    logicalDayBoundaryHour: WorkdayBoundary.standard.hour
  )

  public var workdayBoundary: WorkdayBoundary {
    // Construction was validated by the initializer.
    try! WorkdayBoundary(hour: logicalDayBoundaryHour)
  }
}
