@testable import DaydayApp
import DaydayCore
import Foundation
import Testing

struct InputInsightsPresentationBuilderTests {
  @Test("Semantic range cache reuses only a fresh sibling-tab range")
  func semanticRangeCachePolicy() {
    let loadedAt = instant("2026-08-08T09:00:00Z")
    let loaded = instant("2026-08-08T04:00:00Z")..<instant("2026-08-08T09:00:01Z")
    let sibling = instant("2026-08-08T04:00:00Z")..<instant("2026-08-08T09:00:10Z")
    let other = instant("2026-08-07T04:00:00Z")..<instant("2026-08-08T09:00:10Z")

    #expect(PresentationRangeCachePolicy.canReuse(
      loadedRange: loaded,
      loadedAt: loadedAt,
      requestedRange: sibling,
      now: instant("2026-08-08T09:00:12Z"),
      maximumAge: 30
    ))
    #expect(!PresentationRangeCachePolicy.canReuse(
      loadedRange: loaded,
      loadedAt: loadedAt,
      requestedRange: sibling,
      now: instant("2026-08-08T09:00:31Z"),
      maximumAge: 30
    ))
    #expect(!PresentationRangeCachePolicy.canReuse(
      loadedRange: loaded,
      loadedAt: loadedAt,
      requestedRange: other,
      now: instant("2026-08-08T09:00:12Z"),
      maximumAge: 30
    ))

    let historical = instant("2026-07-01T04:00:00Z")..<instant("2026-07-02T04:00:00Z")
    #expect(PresentationRangeCachePolicy.canReuse(
      loadedRange: historical,
      loadedAt: instant("2026-07-02T05:00:00Z"),
      requestedRange: historical,
      now: instant("2026-08-08T09:00:12Z"),
      maximumAge: 30
    ))
  }

  @Test("Historical projections keep a bounded LRU and reuse immutable daily ranges")
  func historicalProjectionCache() {
    var cache = InputHistoricalProjectionCache(capacity: 2)
    let snapshot = InputAggregatePresentationSnapshot(
      aggregates: [], keyboardCounts: [:], metricSummary: .empty
    )
    let first = instant("2026-07-01T04:00:00Z")..<instant("2026-07-02T04:00:00Z")
    let second = instant("2026-07-02T04:00:00Z")..<instant("2026-07-03T04:00:00Z")
    let third = instant("2026-07-03T04:00:00Z")..<instant("2026-07-04T04:00:00Z")
    let loadedAt = instant("2026-07-04T05:00:00Z")

    cache.insert(.init(range: first, stored: [], snapshot: snapshot, loadedAt: loadedAt, mutableDayStart: first.lowerBound))
    cache.insert(.init(range: second, stored: [], snapshot: snapshot, loadedAt: loadedAt, mutableDayStart: second.lowerBound))
    #expect(cache.value(compatibleWith: first, now: instant("2026-08-08T09:00:00Z"), maximumAge: 30) != nil)
    cache.insert(.init(range: third, stored: [], snapshot: snapshot, loadedAt: loadedAt, mutableDayStart: third.lowerBound))

    #expect(cache.value(compatibleWith: first, now: instant("2026-08-08T09:00:00Z"), maximumAge: 30) != nil)
    #expect(cache.value(compatibleWith: second, now: instant("2026-08-08T09:00:00Z"), maximumAge: 30) == nil)
  }

  @Test("Pointer history index is payload-free, latest-first, and DST safe")
  func pointerHistoryIndex() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
    let days = PointerHistoryDayIndex.make(
      dayCount: 4,
      endingAt: instant("2026-11-02T20:00:00Z"),
      calendar: calendar
    )

    #expect(days.count == 4)
    #expect(days.map(\.logicalDayStart) == days.map(\.logicalDayStart).sorted(by: >))
    #expect(days.contains(where: { $0.range.upperBound.timeIntervalSince($0.range.lowerBound) == 90_000 }))
  }

  @Test("Pointer day cache is bounded and promotes recently reused days")
  func pointerDayCacheIsBounded() {
    var cache = PointerDayPresentationCache(capacity: 2)
    cache.insert(.init(presentation: nil), for: "a")
    cache.insert(.init(presentation: nil), for: "b")
    #expect(cache.value(for: "a") != nil)
    cache.insert(.init(presentation: nil), for: "c")

    #expect(cache.value(for: "a") != nil)
    #expect(cache.value(for: "b") == nil)
    #expect(cache.value(for: "c") != nil)
  }

  @Test("Range snapshot combines stored and live aggregate data off the view path")
  func combinesStoredAndLiveData() throws {
    let display = DisplayContext(id: DisplayID(rawValue: UUID()), topologyRevision: 1)
    let stored = try aggregate(
      start: instant("2026-08-08T08:00:00Z"), display: display, leftClicks: 3
    )
    let live = try aggregate(
      start: instant("2026-08-08T09:00:00Z"), display: display, leftClicks: 2
    )

    let snapshot = InputInsightsPresentationBuilder.makeRangeSnapshot(
      stored: [stored], live: [live]
    )

    #expect(snapshot.aggregates.count == 2)
    #expect(snapshot.pointerPresentationFailed == false)
    #expect(snapshot.pointerDisplays.first?.display.pointer.clicks.left == 5)
  }

  @Test("Aggregate snapshot precomputes keyboard totals once for every consumer")
  func precomputesKeyboardTotals() throws {
    let display = DisplayContext(id: DisplayID(rawValue: UUID()), topologyRevision: 1)
    let stored = try aggregate(
      start: instant("2026-08-08T08:00:00Z"),
      display: display,
      leftClicks: 0,
      physicalKeyCounts: [PhysicalKeyCount(hardwareKeyCode: 12, count: 3)]
    )
    let live = try aggregate(
      start: instant("2026-08-08T09:00:00Z"),
      display: display,
      leftClicks: 0,
      physicalKeyCounts: [PhysicalKeyCount(hardwareKeyCode: 12, count: 2)]
    )

    let snapshot = InputInsightsPresentationBuilder.makeAggregateSnapshot(
      stored: [stored], live: [live]
    )

    #expect(snapshot.keyboardCounts[12] == 5)
  }

  @Test("History snapshot groups cached aggregates by logical workday")
  func groupsHistoryByWorkday() throws {
    let display = DisplayContext(id: DisplayID(rawValue: UUID()), topologyRevision: 1)
    let first = try aggregate(
      start: instant("2026-08-08T05:00:00Z"), display: display, leftClicks: 1
    )
    let second = try aggregate(
      start: instant("2026-08-08T12:00:00Z"), display: display, leftClicks: 4
    )

    let snapshot = InputInsightsPresentationBuilder.makePointerHistorySnapshot(
      stored: [first, second], live: []
    )

    #expect(snapshot.loadFailed == false)
    #expect(snapshot.days.count == 1)
    #expect(snapshot.days.first?.display.pointer.clicks.left == 5)
  }

  @Test("Pointer history uses the owner-configured logical-day boundary")
  func groupsHistoryByConfiguredBoundary() throws {
    let display = DisplayContext(id: DisplayID(rawValue: UUID()), topologyRevision: 1)
    let beforeBoundary = try aggregate(
      start: instant("2026-08-08T05:00:00Z"), display: display, leftClicks: 1
    )
    let afterBoundary = try aggregate(
      start: instant("2026-08-08T07:00:00Z"), display: display, leftClicks: 4
    )

    let snapshot = InputInsightsPresentationBuilder.makePointerHistorySnapshot(
      stored: [beforeBoundary, afterBoundary],
      live: [],
      boundary: try WorkdayBoundary(hour: 6)
    )

    #expect(snapshot.loadFailed == false)
    #expect(snapshot.days.count == 2)
    #expect(snapshot.days.first?.logicalDayStart == instant("2026-08-08T06:00:00Z"))
  }

  private func aggregate(
    start: Date,
    display: DisplayContext,
    leftClicks: UInt64,
    physicalKeyCounts: [PhysicalKeyCount] = []
  ) throws -> InputAggregate {
    try InputAggregate(
      period: InputAggregatePeriod(
        start: start,
        end: start.addingTimeInterval(3_600),
        granularity: .hour,
        timeZoneIdentifier: "UTC"
      ),
      physicalKeyCounts: physicalKeyCounts,
      displays: [
        DisplayInputAggregate(
          display: display,
          pointer: PointerTotals(clicks: ClickCounts(left: leftClicks)),
          grid: try NormalizedDisplayGrid(
            rows: 2,
            columns: 2,
            cells: [
              NormalizedGridCell(
                row: 0,
                column: 0,
                clicks: ClickCounts(left: leftClicks)
              )
            ]
          )
        )
      ],
      collectorVersions: ["test-v1"],
      layoutVersions: ["physical-v1"]
    )
  }

  private func instant(_ value: String) -> Date {
    ISO8601DateFormatter().date(from: value)!
  }
}
