import DaydayCore
import Foundation
import Testing

@testable import DaydayApp

@Suite("Today overview presentation")
struct TodayOverviewPresentationTests {
  @Test("Empty timelines have no invented observations")
  func emptyTimeline() throws {
    let timeline = makeTimeline(
      state: .empty,
      items: [
        .init(
          id: "boundary-start", occurredAt: boundary.startsAt, timeDescription: "04:00",
          endedAt: nil,
          kind: .boundaryStart, title: "工作日开始", sourceLabel: "配置边界", accessibilityLabel: "开始"
        )
      ])

    let overview = makeOverview(timeline: timeline, now: boundary.startsAt)

    #expect(overview.timelineEntryCount == 0)
    #expect(overview.factualEntryCount == 0)
    #expect(overview.sessionEntryCount == 0)
    #expect(overview.inferenceEntryCount == 0)
    #expect(overview.observedApplicationCount == 0)
    #expect(overview.observedSessionCount == 0)
    #expect(overview.buckets.count == 24)
    #expect(overview.buckets.allSatisfy { $0.entryCount == 0 })
    #expect(overview.buckets[0].label == "04:00")
    #expect(overview.accessibilitySummary.contains("不表示") == false)
  }

  @Test("Counts facts, sessions, inferences, and named applications separately")
  func populatedTimeline() throws {
    let atFive = boundary.startsAt.addingTimeInterval(60 * 60)
    let items = [
      item(id: "fact", at: atFive, kind: .objectiveFact, title: "客观事实：applicationContextChanged"),
      item(id: "segment", at: atFive, kind: .activitySegment, title: "使用 Xcode"),
      item(id: "session", at: atFive, kind: .sessionSpan, title: "Xcode 会话"),
      item(id: "activity", at: atFive, kind: .activityInference, title: "本地归集 Activity"),
      item(id: "inference", at: atFive, kind: .inferredActivity, title: "推断：Xcode 活动"),
    ]

    let overview = makeOverview(
      timeline: makeTimeline(state: .populated, items: items), now: atFive)

    #expect(overview.timelineEntryCount == 5)
    #expect(overview.factualEntryCount == 2)
    #expect(overview.sessionEntryCount == 1)
    #expect(overview.inferenceEntryCount == 1)
    #expect(overview.observedApplicationCount == 1)
    #expect(overview.observedSessionCount == 1)
    #expect(overview.buckets[1].entryCount == 5)
    #expect(overview.reportState == .readyToGenerate)
    #expect(overview.accessibilitySummary.contains("5 个时间线条目"))
    #expect(overview.accessibilitySummary.contains("2 个独立事实卡"))
    #expect(overview.accessibilitySummary.contains("1 个 AI 推断"))
  }

  @Test("After-midnight records stay in the workday bucket that starts at 04:00")
  func afterMidnight() throws {
    let afterMidnight = boundary.startsAt.addingTimeInterval(20 * 60 * 60)
    let overview = makeOverview(
      timeline: makeTimeline(
        state: .populated,
        items: [item(id: "late", at: afterMidnight, kind: .objectiveFact, title: "事实")]
      ),
      now: afterMidnight
    )

    #expect(overview.buckets[20].label == "00:00")
    #expect(overview.buckets[20].entryCount == 1)
    #expect(overview.buckets[0].entryCount == 0)
  }

  @Test("Equal timestamps remain together in a deterministic bucket")
  func equalTimestamps() throws {
    let timestamp = boundary.startsAt.addingTimeInterval(3 * 60 * 60)
    let overview = makeOverview(
      timeline: makeTimeline(
        state: .populated,
        items: [
          item(id: "b", at: timestamp, kind: .objectiveFact, title: "事实 B"),
          item(id: "a", at: timestamp, kind: .lifecycleGap, title: "边界"),
        ]
      ),
      now: timestamp
    )

    #expect(overview.factualEntryCount == 2)
    #expect(overview.buckets[3].entryCount == 2)
  }

  @Test("Future timeline entries and buckets are excluded until their time arrives")
  func futureBoundary() throws {
    let now = boundary.startsAt.addingTimeInterval(2 * 60 * 60 + 10)
    let future = boundary.startsAt.addingTimeInterval(8 * 60 * 60)
    let overview = makeOverview(
      timeline: makeTimeline(
        state: .populated,
        items: [
          item(
            id: "current", at: boundary.startsAt.addingTimeInterval(60 * 60), kind: .objectiveFact,
            title: "事实"),
          item(id: "future", at: future, kind: .objectiveFact, title: "未来事实"),
        ]
      ),
      now: now
    )

    #expect(overview.factualEntryCount == 1)
    #expect(overview.buckets[8].entryCount == 0)
    #expect(overview.buckets[3].isFuture)
    #expect(overview.accessibilitySummary.contains("07:00 尚未到达"))
  }

  @Test("Spring-forward keeps the skipped civil hour as an empty labeled cell")
  func springForwardUsesCivilHours() throws {
    let boundary = try newYorkBoundary(year: 2024, month: 3, day: 9)
    let afterSkip = utcDate(year: 2024, month: 3, day: 10, hour: 7, minute: 10)  // 03:10 EDT
    let overview = makeOverview(
      timeline: makeTimeline(
        boundary: boundary,
        state: .populated,
        items: [item(id: "after-skip", at: afterSkip, kind: .objectiveFact, title: "事实")]
      ),
      now: utcDate(year: 2024, month: 3, day: 10, hour: 7, minute: 30),
      timeZoneIdentifier: "America/New_York"
    )

    #expect(overview.buckets[22].label == "02:00")
    #expect(overview.buckets[22].entryCount == 0)
    #expect(!overview.buckets[22].isFuture)
    #expect(overview.buckets[23].label == "03:00")
    #expect(overview.buckets[23].entryCount == 1)
  }

  @Test("Fall-back merges both repeated civil-hour observations into one cell")
  func fallBackMergesRepeatedCivilHour() throws {
    let boundary = try newYorkBoundary(year: 2024, month: 11, day: 2)
    let firstOneAM = utcDate(year: 2024, month: 11, day: 3, hour: 5, minute: 10)  // 01:10 EDT
    let secondOneAM = utcDate(year: 2024, month: 11, day: 3, hour: 6, minute: 10)  // 01:10 EST
    let overview = makeOverview(
      timeline: makeTimeline(
        boundary: boundary,
        state: .populated,
        items: [
          item(id: "first", at: firstOneAM, kind: .objectiveFact, title: "事实一"),
          item(id: "second", at: secondOneAM, kind: .objectiveFact, title: "事实二"),
        ]
      ),
      now: utcDate(year: 2024, month: 11, day: 3, hour: 6, minute: 30),
      timeZoneIdentifier: "America/New_York"
    )

    #expect(overview.buckets[21].label == "01:00")
    #expect(overview.buckets[21].entryCount == 2)
    #expect(!overview.buckets[21].isFuture)
    #expect(overview.buckets[22].isFuture)
  }

  @Test("Dashboard keeps foreground facts, input counters, and AI inferences separate")
  func dashboardKeepsSignalsSeparate() throws {
    let now = instant("2026-08-10T12:30:00Z")
    let applicationID = ApplicationIdentifier(rawValue: UUID())
    let intervals = [
      ApplicationUsagePresentation.Interval(
        id: "foreground",
        applicationIdentifier: applicationID,
        displayLabel: "Xcode",
        startedAt: instant("2026-08-10T10:30:00Z"),
        endedAt: instant("2026-08-10T11:15:00Z"),
        isOngoing: false
      )
    ]
    let timeline = [
      item(
        id: "fact",
        at: instant("2026-08-10T11:05:00Z"),
        kind: .objectiveFact,
        title: "客观事实"
      ),
      item(
        id: "ai",
        at: instant("2026-08-10T11:10:00Z"),
        endedAt: instant("2026-08-10T11:40:00Z"),
        kind: .inferredActivity,
        title: "AI 推断"
      ),
    ]
    let aggregate = try inputAggregate(
      start: instant("2026-08-10T11:00:00Z"),
      keyCount: 7,
      clickCount: 5,
      includedDurationMilliseconds: 3_600_000
    )

    let dashboard = TodayDashboardPresentationAdapter.make(
      now: now,
      timeZoneIdentifier: "UTC",
      applicationIntervals: intervals,
      timelineItems: timeline,
      inputAggregates: [aggregate]
    )

    #expect(dashboard.hours.count == 12)
    let ten = try #require(dashboard.hours.first(where: { $0.label == "10:00" }))
    let eleven = try #require(dashboard.hours.first(where: { $0.label == "11:00" }))
    #expect(ten.foregroundDuration == 30 * 60)
    #expect(eleven.foregroundDuration == 15 * 60)
    #expect(eleven.factualEntryCount == 1)
    #expect(eleven.inferenceEntryCount == 1)
    #expect(eleven.physicalKeyPressCount == 7)
    #expect(eleven.clickCount == 5)
    #expect(dashboard.inferenceSegments.count == 1)
    #expect(dashboard.inferenceClusters.count == 1)
  }

  @Test("Dashboard clusters only visual AI intervals and ignores local Activity rules")
  func dashboardInferenceClustersAndLanes() throws {
    let now = instant("2026-08-10T12:30:00Z")
    let timeline = [
      item(
        id: "ai-a",
        at: instant("2026-08-10T11:10:00Z"),
        endedAt: instant("2026-08-10T11:25:00Z"),
        kind: .inferredActivity,
        title: "归纳 A"
      ),
      item(
        id: "ai-b",
        at: instant("2026-08-10T11:12:00Z"),
        endedAt: instant("2026-08-10T11:20:00Z"),
        kind: .activityInference,
        title: "本地规则 Activity"
      ),
      item(
        id: "ai-c",
        at: instant("2026-08-10T11:14:00Z"),
        endedAt: instant("2026-08-10T11:18:00Z"),
        kind: .inferredActivity,
        title: "归纳 C"
      ),
      item(
        id: "ai-d",
        at: instant("2026-08-10T11:40:00Z"),
        endedAt: instant("2026-08-10T11:45:00Z"),
        kind: .inferredActivity,
        title: "归纳 D"
      ),
    ]

    let dashboard = TodayDashboardPresentationAdapter.make(
      now: now,
      timeZoneIdentifier: "UTC",
      applicationIntervals: [],
      timelineItems: timeline,
      inputAggregates: []
    )

    #expect(dashboard.inferenceSegments.count == 3)
    #expect(!dashboard.inferenceSegments.contains { $0.id == "ai-b" })
    #expect(dashboard.inferenceClusters.count == 2)
    #expect(dashboard.inferenceClusters[0].segmentCount == 2)
    #expect(dashboard.inferenceClusters[1].segmentCount == 1)

    let eleven = try #require(dashboard.hours.first(where: { $0.label == "11:00" }))
    let detail = dashboard.inferenceDetail(for: eleven)
    #expect(detail.lanes.count == 2)
    #expect(detail.overflowCount == 0)
    #expect(detail.segmentCount == 3)
  }

  @Test("Collector coverage never becomes a foreground-duration bar")
  func dashboardDoesNotUseCollectorCoverageAsDuration() throws {
    let now = instant("2026-08-10T12:30:00Z")
    let aggregate = try inputAggregate(
      start: instant("2026-08-10T12:00:00Z"),
      keyCount: 1,
      clickCount: 1,
      includedDurationMilliseconds: 30 * 60 * 1_000
    )

    let dashboard = TodayDashboardPresentationAdapter.make(
      now: now,
      timeZoneIdentifier: "UTC",
      applicationIntervals: [],
      timelineItems: [],
      inputAggregates: [aggregate]
    )

    let current = try #require(dashboard.hours.last)
    #expect(current.isCurrent)
    #expect(current.foregroundDuration == 0)
    #expect(current.physicalKeyPressCount == 1)
    #expect(current.clickCount == 1)
  }

  @Test("Live signal merging reuses the stable timeline and AI projection")
  func dashboardLiveMergeReusesTimelineProjection() throws {
    let now = instant("2026-08-10T12:30:00Z")
    let timeline = [
      item(
        id: "fact",
        at: instant("2026-08-10T12:05:00Z"),
        kind: .objectiveFact,
        title: "客观事实"
      ),
      item(
        id: "ai",
        at: instant("2026-08-10T12:10:00Z"),
        endedAt: instant("2026-08-10T12:20:00Z"),
        kind: .inferredActivity,
        title: "AI 推断"
      ),
    ]
    let stable = TodayDashboardPresentationAdapter.makeTimelineProjection(
      now: now,
      timeZoneIdentifier: "UTC",
      timelineItems: timeline
    )
    let interval = ApplicationUsagePresentation.Interval(
      id: "ongoing",
      applicationIdentifier: ApplicationIdentifier(rawValue: UUID()),
      displayLabel: "Xcode",
      startedAt: instant("2026-08-10T12:00:00Z"),
      endedAt: instant("2026-08-10T12:30:00Z"),
      isOngoing: true
    )

    let live = TodayDashboardPresentationAdapter.mergeLiveSignals(
      into: stable,
      now: now,
      applicationIntervals: [interval],
      inputAggregates: []
    )

    #expect(live.inferenceSegments == stable.inferenceSegments)
    #expect(live.inferenceClusters == stable.inferenceClusters)
    #expect(live.inferenceDetailsByHour == stable.inferenceDetailsByHour)
    let current = try #require(live.hours.last)
    #expect(current.factualEntryCount == 1)
    #expect(current.inferenceEntryCount == 1)
    #expect(current.foregroundDuration == TimeInterval(30 * 60))
  }

  @Test("Large timelines keep local Activity out of both fact and AI totals")
  func largeTimelineCountsRemainDistinct() {
    let timestamp = boundary.startsAt.addingTimeInterval(60 * 60)
    var items: [TodayTimelineItem] = []
    items.reserveCapacity(1_600)
    for index in 0..<1_600 {
      let kind: TodayTimelineItemKind
      switch index % 4 {
      case 0: kind = .objectiveFact
      case 1: kind = .sessionSpan
      case 2: kind = .activityInference
      default: kind = .inferredActivity
      }
      items.append(
        item(id: "item-\(index)", at: timestamp, kind: kind, title: "条目 \(index)")
      )
    }

    let overview = makeOverview(
      timeline: makeTimeline(state: .populated, items: items),
      now: timestamp
    )

    #expect(overview.timelineEntryCount == 1_600)
    #expect(overview.factualEntryCount == 400)
    #expect(overview.sessionEntryCount == 400)
    #expect(overview.inferenceEntryCount == 400)
    #expect(
      overview.timelineEntryCount
        > overview.factualEntryCount + overview.sessionEntryCount + overview.inferenceEntryCount)
    #expect(overview.buckets[1].entryCount == 1_600)
  }

  private let boundary = try! WorkdayBoundarySnapshot(
    hour: 4,
    startsAt: Date(timeIntervalSince1970: 1_704_081_600),
    endsAt: Date(timeIntervalSince1970: 1_704_168_000)
  )

  private func makeOverview(
    timeline: TodayTimelinePresentation,
    now: Date,
    timeZoneIdentifier: String = "UTC"
  ) -> TodayOverviewPresentation {
    TodayOverviewPresentationAdapter.make(
      timeline: timeline,
      report: .init(hasDraft: false, isGenerating: false, isReady: true),
      now: now,
      timeZoneIdentifier: timeZoneIdentifier
    )
  }

  private func makeTimeline(state: TodayTimelineState, items: [TodayTimelineItem])
    -> TodayTimelinePresentation
  {
    .init(state: state, boundary: boundary, items: items)
  }

  private func makeTimeline(
    boundary: WorkdayBoundarySnapshot,
    state: TodayTimelineState,
    items: [TodayTimelineItem]
  ) -> TodayTimelinePresentation {
    .init(state: state, boundary: boundary, items: items)
  }

  private func newYorkBoundary(year: Int, month: Int, day: Int) throws -> WorkdayBoundarySnapshot {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
    let start = try #require(
      calendar.date(from: .init(year: year, month: month, day: day, hour: 4)))
    let end = try #require(calendar.date(byAdding: .day, value: 1, to: start))
    return try .init(hour: 4, startsAt: start, endsAt: end)
  }

  private func utcDate(year: Int, month: Int, day: Int, hour: Int, minute: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .gmt
    return calendar.date(
      from: .init(year: year, month: month, day: day, hour: hour, minute: minute))!
  }

  private func item(
    id: String,
    at: Date,
    endedAt: Date? = nil,
    kind: TodayTimelineItemKind,
    title: String
  ) -> TodayTimelineItem {
    .init(
      id: id, occurredAt: at, timeDescription: "", endedAt: endedAt, kind: kind, title: title,
      sourceLabel: "本地记录", accessibilityLabel: title
    )
  }

  private func inputAggregate(
    start: Date,
    keyCount: UInt64,
    clickCount: UInt64,
    includedDurationMilliseconds: UInt64
  ) throws -> InputAggregate {
    let clicks = ClickCounts(left: clickCount)
    let display = DisplayContext(id: DisplayID(rawValue: UUID()), topologyRevision: 1)
    return try InputAggregate(
      period: InputAggregatePeriod(
        start: start,
        end: start.addingTimeInterval(3_600),
        granularity: .hour,
        timeZoneIdentifier: "UTC"
      ),
      physicalKeyCounts: [PhysicalKeyCount(hardwareKeyCode: 12, count: keyCount)],
      displays: [
        DisplayInputAggregate(
          display: display,
          pointer: PointerTotals(clicks: clicks),
          grid: try NormalizedDisplayGrid(
            rows: 1,
            columns: 1,
            cells: [NormalizedGridCell(row: 0, column: 0, clicks: clicks)]
          )
        )
      ],
      includedDurationMilliseconds: includedDurationMilliseconds,
      collectorVersions: ["test-v1"],
      layoutVersions: ["physical-v1"]
    )
  }

  private func instant(_ value: String) -> Date {
    ISO8601DateFormatter().date(from: value)!
  }
}
