import DaydayCore
import Foundation
import Testing

@testable import DaydayApp

struct MenuBarTimelinePresentationTests {
  @Test("Ninety-minute menu distribution keeps only visible objective observations")
  func recentDistributionFiltersAndBucketsEvents() throws {
    let now = instant("2026-08-08T10:00:00Z")
    let events = [
      try event(
        kind: .stableStateObservation,
        collector: .screenUnderstanding,
        at: "2026-08-08T08:35:00Z"
      ),
      try event(
        kind: .applicationContextChanged,
        collector: .applicationWindowContext,
        at: "2026-08-08T09:55:00Z"
      ),
      try event(
        kind: .collectorStateTransition,
        collector: .screenUnderstanding,
        at: "2026-08-08T09:50:00Z"
      ),
      try event(
        kind: .stableStateObservation,
        collector: .screenUnderstanding,
        at: "2026-08-08T08:20:00Z"
      ),
    ]

    let presentation = MenuBarTimelinePresentationAdapter.make(
      events: events,
      range: .recentNinetyMinutes,
      now: now,
      calendar: utcCalendar
    )

    #expect(presentation.state == .populated)
    #expect(presentation.buckets.count == 18)
    #expect(presentation.totalObservationCount == 2)
    #expect(presentation.screenObservationCount == 1)
    #expect(presentation.applicationObservationCount == 1)
    #expect(presentation.otherObservationCount == 0)
    #expect(presentation.buckets[1].screenObservationCount == 1)
    #expect(presentation.buckets[17].applicationObservationCount == 1)
  }

  @Test("Today distribution begins at the logical 04:00 workday boundary")
  func todayDistributionUsesWorkdayBoundary() throws {
    let presentation = MenuBarTimelinePresentationAdapter.make(
      events: [
        try event(
          kind: .stableStateObservation,
          collector: .screenUnderstanding,
          at: "2026-08-08T04:10:00Z"
        ),
        try event(
          kind: .applicationContextChanged,
          collector: .applicationWindowContext,
          at: "2026-08-08T13:05:00Z"
        ),
      ],
      range: .today,
      now: instant("2026-08-08T13:10:00Z"),
      calendar: utcCalendar
    )

    #expect(presentation.rangeStart == instant("2026-08-08T04:00:00Z"))
    #expect(presentation.buckets.count == 10)
    #expect(presentation.buckets.first?.screenObservationCount == 1)
    #expect(presentation.buckets.last?.applicationObservationCount == 1)
  }

  @Test("Timeline layouts keep one stable popover and chart footprint")
  func rangesKeepStableDashboardSizing() {
    #expect(MenuBarTimelineRange.allCases.map(\.popoverSize.width) == [420, 420, 420, 420])
    #expect(MenuBarTimelineRange.allCases.map(\.popoverSize.height) == [620, 620, 620, 620])
    #expect(MenuBarTimelineRange.allCases.map(\.chartHeight) == [96, 96, 96, 96])
  }

  @Test("Week axis uses weekday labels while month uses month and day")
  func axisLabelsMatchTheTimelineGranularity() {
    let date = instant("2026-08-03T12:00:00Z")
    #expect(MenuBarTimelineRange.week.axisLabel(for: date, calendar: utcCalendar) == "周一")
    let monthLabel = MenuBarTimelineRange.month.axisLabel(for: date, calendar: utcCalendar)
    #expect(!monthLabel.hasPrefix("周"))
    #expect(monthLabel.contains("8"))
    #expect(monthLabel.contains("3"))
  }

  @Test("A cached range selection cannot be overwritten by an older disk read") @MainActor
  func cachedSelectionCancelsOlderRangeRead() async {
    let now = instant("2026-08-08T10:00:00Z")
    let model = MenuBarTimelineModel(now: { now })
    model.configure(repository: DelayedMenuBarTimelineRepository())

    model.refresh(range: .recentNinetyMinutes)
    await waitUntilLoaded(model)
    #expect(model.presentation.range == .recentNinetyMinutes)

    model.refresh(range: .today)
    for _ in 0..<5 { await Task.yield() }
    model.refresh(range: .recentNinetyMinutes)
    try? await Task.sleep(for: .milliseconds(80))

    #expect(model.presentation.range == .recentNinetyMinutes)
    #expect(!model.isLoading)
  }

  @MainActor
  private func waitUntilLoaded(_ model: MenuBarTimelineModel) async {
    for _ in 0..<100 where model.isLoading {
      try? await Task.sleep(for: .milliseconds(2))
    }
  }

  private var utcCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }

  private func event(
    kind: ObjectiveEventKind,
    collector: CollectorKind,
    at timestamp: String
  ) throws -> ObjectiveEvent {
    try ObjectiveEvent(
      kind: kind,
      occurredAt: instant(timestamp),
      timeZoneIdentifier: "UTC",
      source: try CollectorSource(
        collector: collector,
        collectorVersion: "test-v1",
        payloadSchemaVersion: 1
      ),
      securityDisposition: .allowed
    )
  }

  private func instant(_ value: String) -> Date {
    ISO8601DateFormatter().date(from: value)!
  }
}

private actor DelayedMenuBarTimelineRepository: ObjectiveEventRepository {
  func insert(_ event: ObjectiveEvent) async throws -> ObjectiveEventInsertResult { .inserted }

  func fetch(occurredIn range: Range<Date>) async throws -> [ObjectiveEvent] {
    // The long request deliberately ignores cancellation to exercise the
    // model's generation guard after a cached selection is made.
    if range.upperBound.timeIntervalSince(range.lowerBound) > 90 * 60 {
      try? await Task.sleep(for: .milliseconds(40))
    }
    return []
  }
}
