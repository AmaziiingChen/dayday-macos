import DaydayCore
import Foundation

/// Owner-visible, local-only schedule settings. Saving publishes one validated snapshot so every
/// consumer changes boundary and automation policy together instead of observing partial edits.
@MainActor
final class DailyWorkScheduleSettingsModel: ObservableObject {
  @Published var workStartHour: Int
  @Published var workStartMinute: Int
  @Published var workEndHour: Int
  @Published var workEndMinute: Int
  @Published var reportHour: Int
  @Published var reportMinute: Int
  @Published var boundaryHour: Int
  @Published private(set) var status = "使用默认时间"
  @Published private(set) var appliedSchedule: DailyWorkSchedule

  static let storageKey = "dayday.schedule.daily-work.v1"

  private let defaults: UserDefaults
  private var changeHandler: (@MainActor @Sendable (DailyWorkSchedule) -> Void)?

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    let stored = Self.load(from: defaults)
    let schedule = stored ?? .standard
    appliedSchedule = schedule
    workStartHour = schedule.workStartsAt.hour
    workStartMinute = schedule.workStartsAt.minute
    workEndHour = schedule.workEndsAt.hour
    workEndMinute = schedule.workEndsAt.minute
    reportHour = schedule.reportGeneratesAt.hour
    reportMinute = schedule.reportGeneratesAt.minute
    boundaryHour = schedule.logicalDayBoundaryHour
    if stored != nil { status = "已读取本机时间配置" }
  }

  var currentSchedule: DailyWorkSchedule {
    appliedSchedule
  }

  func setChangeHandler(
    _ handler: (@MainActor @Sendable (DailyWorkSchedule) -> Void)?
  ) {
    changeHandler = handler
    handler?(currentSchedule)
  }

  func save() {
    guard let schedule = validatedSchedule() else {
      status = "时间配置无效；上班和下班时间不能完全相同"
      return
    }
    do {
      defaults.set(try JSONEncoder().encode(schedule), forKey: Self.storageKey)
      appliedSchedule = schedule
      status = "已保存；新的工作日边界和日报时间立即生效"
      changeHandler?(schedule)
    } catch {
      status = "无法保存时间配置"
    }
  }

  func restoreDefaults() {
    apply(.standard)
    save()
  }

  private func validatedSchedule() -> DailyWorkSchedule? {
    guard let start = try? LocalTimeOfDay(hour: workStartHour, minute: workStartMinute),
      let end = try? LocalTimeOfDay(hour: workEndHour, minute: workEndMinute),
      let report = try? LocalTimeOfDay(hour: reportHour, minute: reportMinute)
    else { return nil }
    return try? DailyWorkSchedule(
      workStartsAt: start,
      workEndsAt: end,
      reportGeneratesAt: report,
      logicalDayBoundaryHour: boundaryHour
    )
  }

  private func apply(_ schedule: DailyWorkSchedule) {
    workStartHour = schedule.workStartsAt.hour
    workStartMinute = schedule.workStartsAt.minute
    workEndHour = schedule.workEndsAt.hour
    workEndMinute = schedule.workEndsAt.minute
    reportHour = schedule.reportGeneratesAt.hour
    reportMinute = schedule.reportGeneratesAt.minute
    boundaryHour = schedule.logicalDayBoundaryHour
  }

  private static func load(from defaults: UserDefaults) -> DailyWorkSchedule? {
    guard let data = defaults.data(forKey: storageKey) else { return nil }
    return try? JSONDecoder().decode(DailyWorkSchedule.self, from: data)
  }
}
