import DaydayCore
import Foundation
import Testing

@testable import DaydayApp

@MainActor
struct DailyWorkScheduleSettingsModelTests {
  @Test("settings expose and persist all four owner-visible times")
  func persistsSchedule() {
    let defaults = makeDefaults()
    let model = DailyWorkScheduleSettingsModel(defaults: defaults)

    #expect(model.workStartHour == 9)
    #expect(model.workEndHour == 18)
    #expect(model.reportHour == 18)
    #expect(model.boundaryHour == 4)

    model.workStartHour = 8
    model.workStartMinute = 30
    model.workEndHour = 17
    model.workEndMinute = 45
    model.reportHour = 18
    model.reportMinute = 15
    model.boundaryHour = 0
    model.save()

    let restored = DailyWorkScheduleSettingsModel(defaults: defaults)
    #expect(restored.currentSchedule.workStartsAt == (try? LocalTimeOfDay(hour: 8, minute: 30)))
    #expect(restored.currentSchedule.workEndsAt == (try? LocalTimeOfDay(hour: 17, minute: 45)))
    #expect(restored.currentSchedule.reportGeneratesAt == (try? LocalTimeOfDay(hour: 18, minute: 15)))
    #expect(restored.currentSchedule.logicalDayBoundaryHour == 0)
  }

  @Test("invalid edits never replace the last persisted schedule")
  func invalidEditsFailClosed() {
    let defaults = makeDefaults()
    let model = DailyWorkScheduleSettingsModel(defaults: defaults)
    model.workEndHour = model.workStartHour
    model.workEndMinute = model.workStartMinute

    model.save()

    #expect(model.status.contains("不能完全相同"))
    #expect(DailyWorkScheduleSettingsModel(defaults: defaults).currentSchedule == .standard)
  }

  private func makeDefaults() -> UserDefaults {
    let suite = "DailyWorkScheduleSettingsModelTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
  }
}
