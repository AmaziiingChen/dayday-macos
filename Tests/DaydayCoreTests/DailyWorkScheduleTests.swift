import DaydayCore
import Foundation
import Testing

struct DailyWorkScheduleTests {
  @Test("owner-visible defaults are 09:00, 18:00, 18:00 and a 04:00 logical day")
  func defaults() {
    let schedule = DailyWorkSchedule.standard

    #expect(schedule.workStartsAt == (try? LocalTimeOfDay(hour: 9)))
    #expect(schedule.workEndsAt == (try? LocalTimeOfDay(hour: 18)))
    #expect(schedule.reportGeneratesAt == (try? LocalTimeOfDay(hour: 18)))
    #expect(schedule.logicalDayBoundaryHour == 4)
  }

  @Test("logical day boundary is configurable independently from work hours")
  func configurableBoundary() throws {
    let midnight = try DailyWorkSchedule(
      workStartsAt: LocalTimeOfDay(hour: 9),
      workEndsAt: LocalTimeOfDay(hour: 18),
      reportGeneratesAt: LocalTimeOfDay(hour: 18, minute: 30),
      logicalDayBoundaryHour: 0
    )

    #expect(midnight.workdayBoundary.hour == 0)
    #expect(midnight.reportGeneratesAt.minute == 30)
  }

  @Test("automatic generation honors configured minutes")
  func minuteAwareAutoGeneration() throws {
    let schedule = WorkReportAutoSchedule(
      generatesAt: try LocalTimeOfDay(hour: 18, minute: 15)
    )
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
    let before = try #require(
      calendar.date(from: DateComponents(year: 2026, month: 8, day: 10, hour: 18, minute: 14))
    )
    let atTime = try #require(
      calendar.date(from: DateComponents(year: 2026, month: 8, day: 10, hour: 18, minute: 15))
    )

    #expect(!schedule.isDue(now: before, calendar: calendar))
    #expect(schedule.isDue(now: atTime, calendar: calendar))
  }

  @Test("identical start and end times fail validation")
  func rejectsIdenticalWorkTimes() throws {
    let time = try LocalTimeOfDay(hour: 9)
    #expect(throws: DailyWorkSchedule.ValidationError.identicalWorkStartAndEnd) {
      _ = try DailyWorkSchedule(
        workStartsAt: time,
        workEndsAt: time,
        reportGeneratesAt: LocalTimeOfDay(hour: 18),
        logicalDayBoundaryHour: 4
      )
    }
  }
}
