import Foundation
import Testing

@testable import DaydayApp

@Suite("Today greeting")
struct TodayGreetingTests {
  @Test("Rotates product greetings every quarter hour without changing within a slot")
  func rotatesEveryQuarterHour() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
    let start = try #require(calendar.date(from: DateComponents(
      timeZone: calendar.timeZone, year: 2026, month: 8, day: 8, hour: 9, minute: 7
    )))
    let sameSlot = try #require(calendar.date(byAdding: .minute, value: 7, to: start))
    let nextSlot = try #require(calendar.date(byAdding: .minute, value: 8, to: start))
    let nextCycle = try #require(calendar.date(byAdding: .minute, value: 16 * 15, to: start))

    let messages = (0..<16).compactMap { offset in
      calendar.date(byAdding: .minute, value: offset * 15, to: start)
        .map(TodayGreeting.message)
    }

    #expect(messages.count == 16)
    #expect(Set(messages).count == 16)
    #expect(TodayGreeting.message(for: start) == TodayGreeting.message(for: sameSlot))
    #expect(TodayGreeting.message(for: start) != TodayGreeting.message(for: nextSlot))
    #expect(TodayGreeting.message(for: start) == TodayGreeting.message(for: nextCycle))
  }
}
