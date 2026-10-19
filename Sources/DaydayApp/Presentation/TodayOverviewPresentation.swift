import DaydayCore
import Foundation

enum TodayOverviewReportState: Equatable, Sendable {
  case unavailable
  case readyToGenerate
  case generating
  case available

  var metricLabel: String {
    switch self {
    case .unavailable: "未就绪"
    case .readyToGenerate: "可生成"
    case .generating: "生成中"
    case .available: "已有草稿"
    }
  }
}

struct TodayOverviewReportInput: Equatable, Sendable {
  let hasDraft: Bool
  let isGenerating: Bool
  let isReady: Bool
}

struct TodayOverviewBucket: Equatable, Sendable {
  let hour: Int
  let label: String
  let entryCount: Int
  let isFuture: Bool
}

struct TodayOverviewPresentation: Equatable, Sendable {
  let timelineEntryCount: Int
  let factualEntryCount: Int
  let sessionEntryCount: Int
  let inferenceEntryCount: Int
  let observedApplicationCount: Int
  let observedSessionCount: Int
  let reportState: TodayOverviewReportState
  let buckets: [TodayOverviewBucket]
  let accessibilitySummary: String

  static let loading = TodayOverviewPresentation(
    timelineEntryCount: 0,
    factualEntryCount: 0,
    sessionEntryCount: 0,
    inferenceEntryCount: 0,
    observedApplicationCount: 0,
    observedSessionCount: 0,
    reportState: .unavailable,
    buckets: [],
    accessibilitySummary: "正在读取本工作日的本地时间线。"
  )
}

/// A pure projection of the live timeline. Counts describe visible timeline entries,
/// not elapsed attention, input, focus, or productivity.
enum TodayOverviewPresentationAdapter {
  static func make(
    timeline: TodayTimelinePresentation?,
    report: TodayOverviewReportInput,
    now: Date,
    timeZoneIdentifier: String
  ) -> TodayOverviewPresentation {
    let reportState = reportState(for: report)
    guard let timeline else {
      return .init(
        timelineEntryCount: 0,
        factualEntryCount: 0,
        sessionEntryCount: 0,
        inferenceEntryCount: 0,
        observedApplicationCount: 0,
        observedSessionCount: 0,
        reportState: reportState,
        buckets: [],
        accessibilitySummary: "正在读取本工作日的本地时间线。"
      )
    }

    let effectiveNow = min(max(now, timeline.boundary.startsAt), timeline.boundary.endsAt)
    let counts = aggregate(
      boundary: timeline.boundary,
      timeZoneIdentifier: timeZoneIdentifier,
      items: timeline.items,
      effectiveNow: effectiveNow
    )
    let buckets = makeBuckets(
      boundary: timeline.boundary,
      timeZoneIdentifier: timeZoneIdentifier,
      counts: counts.bucketCounts,
      now: now
    )

    return .init(
      timelineEntryCount: counts.timelineEntryCount,
      factualEntryCount: counts.factualEntryCount,
      sessionEntryCount: counts.sessionEntryCount,
      inferenceEntryCount: counts.inferenceEntryCount,
      observedApplicationCount: counts.applicationLabels.count,
      observedSessionCount: counts.sessionEntryCount,
      reportState: reportState,
      buckets: buckets,
      accessibilitySummary: accessibilitySummary(
        boundary: timeline.boundary,
        buckets: buckets,
        timelineEntryCount: counts.timelineEntryCount,
        factualEntryCount: counts.factualEntryCount,
        sessionEntryCount: counts.sessionEntryCount,
        inferenceEntryCount: counts.inferenceEntryCount,
        observedApplicationCount: counts.applicationLabels.count,
        reportState: reportState
      )
    )
  }

  private struct Counts {
    var timelineEntryCount = 0
    var factualEntryCount = 0
    var sessionEntryCount = 0
    var inferenceEntryCount = 0
    var applicationLabels: Set<String> = []
    var bucketCounts = Array(repeating: 0, count: 24)
  }

  /// Counts every visible entry exactly once. The previous projection filtered
  /// the full timeline once per metric and another 24 times for the hour strip,
  /// which made a live sidebar refresh disproportionately expensive.
  private static func aggregate(
    boundary: WorkdayBoundarySnapshot,
    timeZoneIdentifier: String,
    items: [TodayTimelineItem],
    effectiveNow: Date
  ) -> Counts {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .gmt
    var counts = Counts()
    for item in items {
      guard !isBoundary(item.kind), item.occurredAt <= effectiveNow else { continue }

      counts.timelineEntryCount += 1
      if isFactual(item.kind) {
        counts.factualEntryCount += 1
      }
      if item.kind == .sessionSpan {
        counts.sessionEntryCount += 1
      }
      if isInference(item.kind) {
        counts.inferenceEntryCount += 1
      }
      if let application = observedApplicationLabel(item) {
        counts.applicationLabels.insert(application)
      }

      let hour = calendar.component(.hour, from: item.occurredAt)
      counts.bucketCounts[civilBucketIndex(hour: hour, boundaryHour: boundary.hour)] += 1
    }
    return counts
  }

  private static func reportState(for input: TodayOverviewReportInput) -> TodayOverviewReportState {
    if input.hasDraft { return .available }
    if input.isGenerating { return .generating }
    return input.isReady ? .readyToGenerate : .unavailable
  }

  private static func isBoundary(_ kind: TodayTimelineItemKind) -> Bool {
    kind == .boundaryStart || kind == .boundaryEnd
  }

  private static func isFactual(_ kind: TodayTimelineItemKind) -> Bool {
    switch kind {
    case .objectiveFact, .activitySegment, .lifecycleGap, .securityGap: true
    default: false
    }
  }

  private static func isInference(_ kind: TodayTimelineItemKind) -> Bool {
    kind == .inferredActivity
  }

  private static func observedApplicationLabel(_ item: TodayTimelineItem) -> String? {
    switch item.kind {
    case .activitySegment:
      return item.title.hasPrefix("使用 ") ? String(item.title.dropFirst(3)) : nil
    case .sessionSpan:
      return item.title.hasSuffix(" 会话") ? String(item.title.dropLast(3)) : nil
    default:
      return nil
    }
  }

  private static func makeBuckets(
    boundary: WorkdayBoundarySnapshot,
    timeZoneIdentifier: String,
    counts: [Int],
    now: Date
  ) -> [TodayOverviewBucket] {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .gmt
    let currentBucket =
      now < boundary.startsAt
      ? nil
      : now >= boundary.endsAt
        ? 24
        : civilBucketIndex(hour: calendar.component(.hour, from: now), boundaryHour: boundary.hour)

    return (0..<24).map { index in
      let hour = (boundary.hour + index) % 24
      return .init(
        hour: hour,
        label: String(format: "%02d:00", hour),
        entryCount: counts[index],
        isFuture: currentBucket.map { index > $0 } ?? true
      )
    }
  }

  private static func civilBucketIndex(hour: Int, boundaryHour: Int) -> Int {
    (hour - boundaryHour + 24) % 24
  }

  private static func accessibilitySummary(
    boundary: WorkdayBoundarySnapshot,
    buckets: [TodayOverviewBucket],
    timelineEntryCount: Int,
    factualEntryCount: Int,
    sessionEntryCount: Int,
    inferenceEntryCount: Int,
    observedApplicationCount: Int,
    reportState: TodayOverviewReportState
  ) -> String {
    let bucketText = buckets.map {
      $0.isFuture ? "\($0.label) 尚未到达" : "\($0.label) \($0.entryCount) 条记录"
    }.joined(separator: "；")
    return
      "本工作日从 \(boundary.hour):00 至次日 \(boundary.hour):00。截至当前，已载入 \(timelineEntryCount) 个时间线条目，其中 \(factualEntryCount) 个独立事实卡、\(sessionEntryCount) 个客观会话、\(inferenceEntryCount) 个 AI 推断；时间线中识别出 \(observedApplicationCount) 个应用名称，日报\(reportState.metricLabel)。时段条目数：\(bucketText)。"
  }
}

/// A compact, read-only projection for the Today sidebar. Each signal keeps its
/// original meaning: foreground intervals are objective application facts,
/// input values are privacy-closed counters, and AI intervals remain visibly
/// separate inferences. No combined activity or productivity score is derived.
struct TodayDashboardHour: Identifiable, Equatable, Sendable {
  let startsAt: Date
  let endsAt: Date
  let label: String
  let foregroundDuration: TimeInterval
  let factualEntryCount: Int
  let inferenceEntryCount: Int
  let physicalKeyPressCount: UInt64
  let clickCount: UInt64
  let isCurrent: Bool

  var id: Date { startsAt }
}

struct TodayDashboardInferenceSegment: Identifiable, Equatable, Sendable {
  let id: String
  let startsAt: Date
  let endsAt: Date
  let title: String
}

struct TodayDashboardInferenceCluster: Identifiable, Equatable, Sendable {
  let id: String
  let startsAt: Date
  let endsAt: Date
  let segmentCount: Int
  let titles: [String]
}

struct TodayDashboardInferenceDetail: Equatable, Sendable {
  let lanes: [[TodayDashboardInferenceSegment]]
  let overflowCount: Int

  var segmentCount: Int {
    lanes.reduce(overflowCount) { $0 + $1.count }
  }
}

struct TodayDashboardPresentation: Equatable, Sendable {
  let hours: [TodayDashboardHour]
  let inferenceSegments: [TodayDashboardInferenceSegment]
  let inferenceClusters: [TodayDashboardInferenceCluster]
  let inferenceDetailsByHour: [Date: TodayDashboardInferenceDetail]

  var range: Range<Date>? {
    guard let first = hours.first, let last = hours.last else { return nil }
    return first.startsAt..<last.endsAt
  }

  func inferenceDetail(
    for hour: TodayDashboardHour,
    maximumLaneCount: Int = 2
  ) -> TodayDashboardInferenceDetail {
    if maximumLaneCount == 2, let detail = inferenceDetailsByHour[hour.id] {
      return detail
    }
    return computedInferenceDetail(for: hour, maximumLaneCount: maximumLaneCount)
  }

  fileprivate func computedInferenceDetail(
    for hour: TodayDashboardHour,
    maximumLaneCount: Int
  ) -> TodayDashboardInferenceDetail {
    let visibleSegments = inferenceSegments.filter {
      if $0.endsAt > $0.startsAt {
        return $0.startsAt < hour.endsAt && $0.endsAt > hour.startsAt
      }
      return $0.startsAt >= hour.startsAt && $0.startsAt < hour.endsAt
    }
    guard maximumLaneCount > 0 else {
      return .init(lanes: [], overflowCount: visibleSegments.count)
    }

    let clipped = visibleSegments.map { segment in
      let start = max(segment.startsAt, hour.startsAt)
      let end = min(max(segment.endsAt, start), hour.endsAt)
      return .init(id: segment.id, startsAt: start, endsAt: end, title: segment.title)
    }
    .sorted(by: inferenceSegmentOrder)

    var lanes = Array(repeating: [TodayDashboardInferenceSegment](), count: maximumLaneCount)
    var laneEnds = Array(repeating: hour.startsAt, count: maximumLaneCount)
    var overflowCount = 0
    for segment in clipped {
      guard let laneIndex = laneEnds.firstIndex(where: { $0 <= segment.startsAt }) else {
        overflowCount += 1
        continue
      }
      lanes[laneIndex].append(segment)
      laneEnds[laneIndex] = min(
        hour.endsAt,
        max(segment.endsAt, segment.startsAt.addingTimeInterval(60))
      )
    }

    return .init(
      lanes: lanes.filter { !$0.isEmpty },
      overflowCount: overflowCount
    )
  }

  private func inferenceSegmentOrder(
    _ lhs: TodayDashboardInferenceSegment,
    _ rhs: TodayDashboardInferenceSegment
  ) -> Bool {
    if lhs.startsAt != rhs.startsAt { return lhs.startsAt < rhs.startsAt }
    if lhs.endsAt != rhs.endsAt { return lhs.endsAt < rhs.endsAt }
    return lhs.id < rhs.id
  }
}

enum TodayDashboardPresentationAdapter {
  static let hourCount = 12
  static let foregroundScaleMaximum: TimeInterval = 60 * 60

  /// Compatibility entry point for tests and non-SwiftUI consumers. TodayView
  /// uses the split projection below so a one-second foreground clock never
  /// scans or clusters the full evidence thread again.
  static func make(
    now: Date,
    timeZoneIdentifier: String,
    applicationIntervals: [ApplicationUsagePresentation.Interval],
    timelineItems: [TodayTimelineItem],
    inputAggregates: [InputAggregate]
  ) -> TodayDashboardPresentation {
    let timeline = makeTimelineProjection(
      now: now,
      timeZoneIdentifier: timeZoneIdentifier,
      timelineItems: timelineItems
    )
    return mergeLiveSignals(
      into: timeline,
      now: now,
      applicationIntervals: applicationIntervals,
      inputAggregates: inputAggregates
    )
  }

  /// Stable evidence-only work. This is linear in the number of timeline
  /// entries and performs AI interval clustering exactly once per timeline
  /// snapshot, rather than once per live foreground-duration tick.
  static func makeTimelineProjection(
    now: Date,
    timeZoneIdentifier: String,
    timelineItems: [TodayTimelineItem]
  ) -> TodayDashboardPresentation {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .autoupdatingCurrent
    guard let currentHour = calendar.dateInterval(of: .hour, for: now) else {
      return emptyPresentation
    }

    let hourIntervals = (0..<hourCount).compactMap { index -> DateInterval? in
      let offset = index - (hourCount - 1)
      guard
        let start = calendar.date(byAdding: .hour, value: offset, to: currentHour.start),
        let end = calendar.date(byAdding: .hour, value: 1, to: start)
      else { return nil }
      return DateInterval(start: start, end: end)
    }
    guard let windowStart = hourIntervals.first?.start,
      let windowEnd = hourIntervals.last?.end
    else {
      return emptyPresentation
    }
    let visibleEnd = min(now, windowEnd)
    let hourIndexByStart = Dictionary(
      uniqueKeysWithValues: hourIntervals.enumerated().map { ($0.element.start, $0.offset) }
    )
    var factualCounts = Array(repeating: 0, count: hourIntervals.count)
    var inferenceCounts = Array(repeating: 0, count: hourIntervals.count)
    var inferenceSegments: [TodayDashboardInferenceSegment] = []
    inferenceSegments.reserveCapacity(min(timelineItems.count, 128))

    for item in timelineItems {
      guard item.occurredAt >= windowStart, item.occurredAt < visibleEnd,
        let itemHour = calendar.dateInterval(of: .hour, for: item.occurredAt),
        let index = hourIndexByStart[itemHour.start]
      else { continue }
      if isFactual(item.kind) {
        factualCounts[index] += 1
      } else if isInference(item.kind) {
        inferenceCounts[index] += 1
        let start = max(item.occurredAt, windowStart)
        let end = min(max(item.endedAt ?? item.occurredAt, start), visibleEnd)
        inferenceSegments.append(
          .init(id: item.id, startsAt: start, endsAt: end, title: item.title)
        )
      }
    }

    let hours = hourIntervals.enumerated().map { index, hour in
      let components = calendar.dateComponents([.hour, .minute], from: hour.start)
      let label = String(
        format: "%02d:%02d",
        components.hour ?? 0,
        components.minute ?? 0
      )
      return TodayDashboardHour(
        startsAt: hour.start,
        endsAt: hour.end,
        label: label,
        foregroundDuration: 0,
        factualEntryCount: factualCounts[index],
        inferenceEntryCount: inferenceCounts[index],
        physicalKeyPressCount: 0,
        clickCount: 0,
        isCurrent: hour.start <= now && now < hour.end
      )
    }
    let base = TodayDashboardPresentation(
      hours: hours,
      inferenceSegments: inferenceSegments,
      inferenceClusters: inferenceClusters(from: inferenceSegments),
      inferenceDetailsByHour: [:]
    )
    let details = Dictionary(
      uniqueKeysWithValues: hours.map {
        ($0.id, base.computedInferenceDetail(for: $0, maximumLaneCount: 2))
      }
    )
    return .init(
      hours: hours,
      inferenceSegments: inferenceSegments,
      inferenceClusters: base.inferenceClusters,
      inferenceDetailsByHour: details
    )
  }

  /// Cheap live work. The 12 stable hour buckets and all AI projections are
  /// reused; only foreground-duration and privacy-closed input counters change.
  static func mergeLiveSignals(
    into timeline: TodayDashboardPresentation,
    now: Date,
    applicationIntervals: [ApplicationUsagePresentation.Interval],
    inputAggregates: [InputAggregate]
  ) -> TodayDashboardPresentation {
    guard let range = timeline.range else { return timeline }
    let visibleEnd = min(now, range.upperBound)
    var foregroundDurations = Array(repeating: TimeInterval.zero, count: timeline.hours.count)
    var physicalKeyPressCounts = Array(repeating: UInt64.zero, count: timeline.hours.count)
    var clickCounts = Array(repeating: UInt64.zero, count: timeline.hours.count)

    for interval in applicationIntervals {
      guard interval.endedAt > range.lowerBound, interval.startedAt < visibleEnd else { continue }
      for (index, hour) in timeline.hours.enumerated() {
        let end = min(hour.endsAt, visibleEnd, interval.endedAt)
        let start = max(hour.startsAt, interval.startedAt)
        if end > start {
          foregroundDurations[index] = min(
            foregroundScaleMaximum,
            foregroundDurations[index] + end.timeIntervalSince(start)
          )
        }
      }
    }

    let hourIndexByStart = Dictionary(
      uniqueKeysWithValues: timeline.hours.enumerated().map { ($0.element.startsAt, $0.offset) }
    )
    for aggregate in inputAggregates where aggregate.period.granularity == .hour {
      guard aggregate.period.start >= range.lowerBound,
        aggregate.period.start < visibleEnd,
        let index = hourIndexByStart[aggregate.period.start]
      else { continue }

      for key in aggregate.physicalKeyCounts {
        physicalKeyPressCounts[index] = saturatingAdd(
          physicalKeyPressCounts[index], key.count
        )
      }
      for display in aggregate.displays {
        let clicks = display.pointer.clicks
        clickCounts[index] = saturatingAdd(
          clickCounts[index],
          saturatingAdd(clicks.left, saturatingAdd(clicks.right, clicks.other))
        )
      }
    }

    let hours = timeline.hours.enumerated().map { index, hour in
      TodayDashboardHour(
        startsAt: hour.startsAt,
        endsAt: hour.endsAt,
        label: hour.label,
        foregroundDuration: foregroundDurations[index],
        factualEntryCount: hour.factualEntryCount,
        inferenceEntryCount: hour.inferenceEntryCount,
        physicalKeyPressCount: physicalKeyPressCounts[index],
        clickCount: clickCounts[index],
        isCurrent: hour.startsAt <= now && now < hour.endsAt
      )
    }
    return .init(
      hours: hours,
      inferenceSegments: timeline.inferenceSegments,
      inferenceClusters: timeline.inferenceClusters,
      inferenceDetailsByHour: timeline.inferenceDetailsByHour
    )
  }

  private static func isFactual(_ kind: TodayTimelineItemKind) -> Bool {
    switch kind {
    case .objectiveFact, .activitySegment, .lifecycleGap, .securityGap: true
    default: false
    }
  }

  private static func isInference(_ kind: TodayTimelineItemKind) -> Bool {
    kind == .inferredActivity
  }

  private static func inferenceClusters(
    from segments: [TodayDashboardInferenceSegment]
  ) -> [TodayDashboardInferenceCluster] {
    struct Builder {
      let id: String
      let startsAt: Date
      var endsAt: Date
      var segmentCount: Int
      var titles: [String]
      var seenTitles: Set<String>
    }

    let ordered = segments.sorted {
      if $0.startsAt != $1.startsAt { return $0.startsAt < $1.startsAt }
      if $0.endsAt != $1.endsAt { return $0.endsAt < $1.endsAt }
      return $0.id < $1.id
    }
    var builders: [Builder] = []
    for segment in ordered {
      if var current = builders.last,
        segment.startsAt <= current.endsAt.addingTimeInterval(60)
      {
        current.endsAt = max(current.endsAt, segment.endsAt)
        current.segmentCount += 1
        if current.seenTitles.insert(segment.title).inserted {
          current.titles.append(segment.title)
        }
        builders[builders.count - 1] = current
      } else {
        builders.append(
          Builder(
            id: segment.id,
            startsAt: segment.startsAt,
            endsAt: segment.endsAt,
            segmentCount: 1,
            titles: [segment.title],
            seenTitles: [segment.title]
          )
        )
      }
    }

    return builders.map {
      TodayDashboardInferenceCluster(
        id: $0.id,
        startsAt: $0.startsAt,
        endsAt: $0.endsAt,
        segmentCount: $0.segmentCount,
        titles: $0.titles
      )
    }
  }

  private static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
    let result = lhs.addingReportingOverflow(rhs)
    return result.overflow ? UInt64.max : result.partialValue
  }

  private static var emptyPresentation: TodayDashboardPresentation {
    .init(
      hours: [],
      inferenceSegments: [],
      inferenceClusters: [],
      inferenceDetailsByHour: [:]
    )
  }
}
