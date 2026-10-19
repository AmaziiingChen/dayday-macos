import DaydayCore
import Foundation
import Testing

@testable import DaydayApp

@MainActor
struct WeatherRuntimeWorkReportTests {
  @Test("only a current-workday district observation enters report context")
  func convertsAllowedObservation() throws {
    let start = Date(timeIntervalSinceReferenceDate: 10_000)
    let day = try makeDay(start: start)
    let source = WeatherRuntime.Snapshot(
      district: "深圳南山区",
      placeName: "广东省深圳市南山区科技园路",
      temperatureCelsius: 30,
      feelsLikeCelsius: 32,
      humidityPercent: 72,
      windKilometersPerHour: 8,
      weatherCode: 2,
      observedAt: start.addingTimeInterval(3_600),
      retrievedAt: start.addingTimeInterval(3_620)
    )

    let snapshot = try #require(WeatherRuntime.workReportSnapshot(from: source, for: day))
    #expect(snapshot.dayID == day.id)
    #expect(snapshot.location.displayName == "深圳南山区")
    #expect(snapshot.condition == "多云")
    #expect(snapshot.temperatureCelsius == 30)
    #expect(snapshot.humidityPercent == 72)
    #expect(!snapshot.location.providerLocationKey.rawValue.contains("22."))
    #expect(!snapshot.location.providerLocationKey.rawValue.contains("113."))
  }

  @Test("observation outside the configured logical day is excluded")
  func excludesOutsideObservation() throws {
    let start = Date(timeIntervalSinceReferenceDate: 20_000)
    let day = try makeDay(start: start)
    let source = WeatherRuntime.Snapshot(
      district: "深圳南山区",
      temperatureCelsius: 30,
      feelsLikeCelsius: nil,
      humidityPercent: nil,
      windKilometersPerHour: nil,
      weatherCode: 0,
      observedAt: day.boundary.endsAt,
      retrievedAt: day.boundary.endsAt
    )

    #expect(WeatherRuntime.workReportSnapshot(from: source, for: day) == nil)
  }

  private func makeDay(start: Date) throws -> DayDescriptor {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
    let aligned = try WorkdayBoundary.standard.start(containing: start, calendar: calendar)
    let end = try #require(calendar.date(byAdding: .day, value: 1, to: aligned))
    let components = calendar.dateComponents([.year, .month, .day], from: aligned)
    return try DayDescriptor(
      id: DayID(rawValue: UUID(uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE")!),
      logicalDate: LogicalDayDate(
        year: try #require(components.year),
        month: try #require(components.month),
        day: try #require(components.day)
      ),
      timeZoneIdentifier: "UTC",
      boundary: WorkdayBoundarySnapshot(
        hour: WorkdayBoundary.standard.hour,
        startsAt: aligned,
        endsAt: end
      )
    )
  }
}
