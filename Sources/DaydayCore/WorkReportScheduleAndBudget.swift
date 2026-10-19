import Foundation

// MARK: - Token budget

/// A daily and/or monthly generation budget expressed in provider-reported tokens. The policy only
/// decides whether an AI generation may start; it never stops local collection.
public struct WorkReportTokenBudget: Equatable, Sendable {
  public enum Violation: Equatable, Sendable {
    case none
    case daily(atLeast: Int, limit: Int)
    case monthly(atLeast: Int, limit: Int)
  }

  public enum ValidationError: Error, Equatable, Sendable {
    case negativeLimit
  }

  public let dailyLimit: Int?
  public let monthlyLimit: Int?

  public init(dailyLimit: Int?, monthlyLimit: Int?) throws {
    func valid(_ value: Int?) -> Bool { value == nil || value! >= 0 }
    guard valid(dailyLimit), valid(monthlyLimit) else {
      throw ValidationError.negativeLimit
    }
    self.dailyLimit = dailyLimit
    self.monthlyLimit = monthlyLimit
  }

  public static let unlimited = try! WorkReportTokenBudget(dailyLimit: nil, monthlyLimit: nil)

  public func violation(
    forDay dayTokens: Int, responding calendarMonthTokens: Int
  ) -> Violation {
    if let dailyLimit, dayTokens >= dailyLimit {
      return .daily(atLeast: dayTokens, limit: dailyLimit)
    }
    if let monthlyLimit, calendarMonthTokens >= monthlyLimit {
      return .monthly(atLeast: calendarMonthTokens, limit: monthlyLimit)
    }
    return .none
  }
}

/// Normalized time-of-day at which an unattended report may be generated, decoupled from the 04:00
/// workday boundary. Generation still only happens when a draft for that logical day is absent.
public struct WorkReportAutoSchedule: Equatable, Sendable {
  public enum ValidationError: Error, Equatable, Sendable {
    case invalidHour(Int)
  }

  public static let defaultAutoEndHour = 18

  public let generatesAt: LocalTimeOfDay
  public var endHour: Int { generatesAt.hour }

  public init(endHour: Int) throws {
    guard (0...23).contains(endHour) else { throw ValidationError.invalidHour(endHour) }
    generatesAt = try LocalTimeOfDay(hour: endHour)
  }

  public init(generatesAt: LocalTimeOfDay) {
    self.generatesAt = generatesAt
  }

  public static let standard = try! WorkReportAutoSchedule(endHour: defaultAutoEndHour)

  /// True once `now` has reached the configured end hour within its calendar day, regardless of the
  /// logical workday boundary.
  public func isDue(now: Date, calendar: Calendar = .current) -> Bool {
    generatesAt.hasArrived(at: now, calendar: calendar)
  }
}
