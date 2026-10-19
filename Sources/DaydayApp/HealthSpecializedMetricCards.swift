import Charts
import DaydayCore
import SwiftUI

/// Objective, bounded presentations for the four health summaries that benefit from a layout
/// more specific than a single-metric line card. No raw HealthKit payload reaches these views.
enum HealthSpecializedCardKind: String, CaseIterable, Identifiable {
  case sleep
  case heart
  case activity
  case body

  var id: Self { self }

  var title: String {
    switch self {
    case .sleep: "睡眠"
    case .heart: "心率"
    case .activity: "活动"
    case .body: "身体测量"
    }
  }

  var systemImage: String {
    switch self {
    case .sleep: "bed.double.fill"
    case .heart: "heart.fill"
    case .activity: "figure.walk.motion"
    case .body: "scalemass.fill"
    }
  }

  var tint: Color {
    switch self {
    case .sleep: .indigo
    case .heart: .pink
    case .activity: .green
    case .body: .cyan
    }
  }

  var metricKinds: [HealthObservationKind] {
    switch self {
    case .sleep:
      [.sleepAnalysis]
    case .heart:
      [.heartRate, .restingHeartRate, .heartRateVariabilitySDNN]
    case .activity:
      [.stepCount, .activeEnergyBurned, .appleExerciseTime, .appleStandHour]
    case .body:
      [.bodyMass, .bodyMassIndex, .bodyFatPercentage, .leanBodyMass]
    }
  }
}

struct HealthSpecializedMetricPresentation: Equatable, Identifiable {
  let kind: HealthObservationKind
  let unit: HealthMetricUnit
  let aggregation: HealthMetricAggregation
  let currentPoints: [HealthMetricPoint]
  let currentValue: Double?
  let previousValue: Double?
  let observedMinimum: Double?
  let observedMaximum: Double?
  let visualSnapshot: HealthSpecializedVisualSnapshot

  var id: HealthObservationKind { kind }
}

struct HealthSpecializedCardPresentation: Equatable {
  let kind: HealthSpecializedCardKind
  let range: HealthMetricTrendRange
  let metrics: [HealthSpecializedMetricPresentation]
  let isExpanded: Bool
}

struct HealthSpecializedChartSegment: Equatable, Identifiable {
  let id: Int
  let points: [HealthMetricPoint]
}

/// A specialized-card snapshot with a deliberately smaller rendering budget than the general
/// metric chart. Factual points remain outside this display-only projection.
struct HealthSpecializedVisualSnapshot: Equatable {
  let points: [HealthMetricMorphPoint]
  let axis: HealthMetricChartAxisPresentation
  let transitionKey: HealthMetricLineChartTransitionKey

  static func make(
    series: HealthMetricSeries,
    range: HealthMetricTrendRange,
    isExpanded: Bool,
    now: Date
  ) -> Self {
    let factualPoints = HealthMetricPresentationAdapter.plotPoints(
      from: series,
      range: range,
      now: now
    )
    let displayedValues = factualPoints.map {
      healthMetricChartValue($0.value, kind: series.kind, unit: series.unit)
    }
    var hasher = Hasher()
    for point in factualPoints { hasher.combine(point) }
    let displayMode: HealthMetricChartDisplayMode = isExpanded ? .expanded : .compact
    return Self(
      points: HealthSpecializedMorphProjection.make(
        from: factualPoints,
        slotCount: isExpanded
          ? HealthSpecializedCardPresentationAdapter.expandedPointLimit
          : HealthSpecializedCardPresentationAdapter.compactPointLimit
      ),
      axis: HealthMetricChartAxisPresentation.make(
        values: displayedValues,
        desiredIntervals: isExpanded ? 5 : 4
      ),
      transitionKey: .init(
        kind: series.kind,
        range: range,
        displayMode: displayMode,
        archiveRevision: 0,
        dataFingerprint: hasher.finalize()
      )
    )
  }
}

enum HealthSpecializedMorphProjection {
  static func make(
    from suppliedPoints: [HealthMetricPoint],
    slotCount: Int
  ) -> [HealthMetricMorphPoint] {
    let resolvedSlotCount = max(2, slotCount)
    let empty = (0..<resolvedSlotCount).map {
      HealthMetricMorphPoint(
        slot: $0,
        date: nil,
        value: nil,
        isConnectedToPrevious: false
      )
    }
    let factualPoints = sanitized(suppliedPoints)
    guard let first = factualPoints.first else { return empty }
    guard factualPoints.count > 1, let last = factualPoints.last, first.startedAt < last.startedAt
    else {
      var result = empty
      result[0] = .init(
        slot: 0,
        date: first.startedAt,
        value: first.value,
        isConnectedToPrevious: false
      )
      return result
    }

    let gapIntervals = HealthMetricGapPolicy.genuineGapIntervals(in: factualPoints)
    let controlPoints =
      factualPoints.count > resolvedSlotCount
      ? HealthMetricPointSampling.downsample(
        factualPoints,
        limit: max(12, resolvedSlotCount / 2)
      ) : factualPoints
    let duration = last.startedAt.timeIntervalSince(first.startedAt)
    var result: [HealthMetricMorphPoint] = []
    result.reserveCapacity(resolvedSlotCount)
    var controlIndex = 0
    var previousDate: Date?

    for slot in 0..<resolvedSlotCount {
      let progress = Double(slot) / Double(resolvedSlotCount - 1)
      let date = first.startedAt.addingTimeInterval(duration * progress)
      if gapIntervals.contains(where: { $0.lowerBound < date && date < $0.upperBound }) {
        result.append(.init(slot: slot, date: nil, value: nil, isConnectedToPrevious: false))
        previousDate = nil
        continue
      }
      while controlIndex + 1 < controlPoints.count,
        controlPoints[controlIndex + 1].startedAt < date
      {
        controlIndex += 1
      }
      let left = controlPoints[controlIndex]
      let right = controlPoints[min(controlIndex + 1, controlPoints.count - 1)]
      let interval = right.startedAt.timeIntervalSince(left.startedAt)
      let value: Double
      if interval <= 0 {
        value = right.value
      } else {
        let fraction = min(1, max(0, date.timeIntervalSince(left.startedAt) / interval))
        let eased = fraction * fraction * (3 - 2 * fraction)
        value = left.value + (right.value - left.value) * eased
      }
      let crossesGap =
        previousDate.map { previous in
          gapIntervals.contains { $0.lowerBound < date && $0.upperBound > previous }
        } ?? true
      result.append(
        .init(
          slot: slot,
          date: date,
          value: value,
          isConnectedToPrevious: previousDate != nil && !crossesGap
        ))
      previousDate = date
    }
    return result
  }

  private static func sanitized(_ suppliedPoints: [HealthMetricPoint]) -> [HealthMetricPoint] {
    let sorted = suppliedPoints.filter { $0.value.isFinite }.sorted {
      if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
      if $0.endedAt != $1.endedAt { return $0.endedAt < $1.endedAt }
      return $0.contributingSampleCount < $1.contributingSampleCount
    }
    var result: [HealthMetricPoint] = []
    result.reserveCapacity(sorted.count)
    for point in sorted {
      if result.last?.startedAt == point.startedAt {
        result[result.count - 1] = point
      } else {
        result.append(point)
      }
    }
    return result
  }
}

enum HealthSpecializedCardPresentationAdapter {
  static let compactPointLimit = 24
  static let expandedPointLimit = 120

  static func make(
    kind: HealthSpecializedCardKind,
    series: [HealthMetricSeries],
    range: HealthMetricTrendRange,
    now: Date,
    isExpanded: Bool,
    calendar suppliedCalendar: Calendar = .autoupdatingCurrent
  ) -> HealthSpecializedCardPresentation? {
    let byKind = Dictionary(
      series.map { ($0.kind, $0) },
      uniquingKeysWith: { _, newer in newer }
    )
    let pointLimit = isExpanded ? expandedPointLimit : compactPointLimit
    let metrics = kind.metricKinds.compactMap {
      metricKind -> HealthSpecializedMetricPresentation? in
      guard let metricSeries = byKind[metricKind] else { return nil }
      let current = currentPoints(
        from: metricSeries,
        range: range,
        now: now,
        calendar: suppliedCalendar
      )
      guard !current.isEmpty || metricSeries.latestSample != nil else { return nil }
      let summary = summaryPoints(
        from: metricSeries,
        range: range,
        now: now,
        calendar: suppliedCalendar
      )
      let previous =
        isExpanded
        ? previousPoints(
          from: metricSeries,
          range: range,
          now: now,
          calendar: suppliedCalendar
        ) : []
      let bounded = HealthMetricPointSampling.downsample(current, limit: pointLimit)
      let finiteSummary = summary.filter { $0.value.isFinite }
      return HealthSpecializedMetricPresentation(
        kind: metricKind,
        unit: metricSeries.unit,
        aggregation: metricSeries.aggregation,
        currentPoints: bounded,
        currentValue: HealthMetricPresentationAdapter.averageValue(
          in: finiteSummary,
          aggregation: metricSeries.aggregation
        ),
        previousValue: isExpanded
          ? HealthMetricPresentationAdapter.averageValue(
            in: previous,
            aggregation: metricSeries.aggregation
          ) : nil,
        observedMinimum: isExpanded
          ? finiteSummary.compactMap { $0.minimum ?? $0.value }.min() : nil,
        observedMaximum: isExpanded
          ? finiteSummary.compactMap { $0.maximum ?? $0.value }.max() : nil,
        visualSnapshot: HealthSpecializedVisualSnapshot.make(
          series: metricSeries,
          range: range,
          isExpanded: isExpanded,
          now: now
        )
      )
    }
    guard !metrics.isEmpty else { return nil }
    return .init(kind: kind, range: range, metrics: metrics, isExpanded: isExpanded)
  }

  static func currentPoints(
    from series: HealthMetricSeries,
    range: HealthMetricTrendRange,
    now: Date,
    calendar: Calendar
  ) -> [HealthMetricPoint] {
    HealthMetricPresentationAdapter.plotPoints(
      from: series,
      range: range,
      now: now,
      calendar: calendar
    ).filter { $0.value.isFinite }
  }

  /// Values used in a card headline must share the same daily factual grain as the comparison
  /// period. Cumulative and duration metrics therefore remain daily totals, while discrete daily
  /// averages are weighted by contributing sample count by the caller. Intraday buckets remain a
  /// visual inspection surface and never become a headline average.
  static func summaryPoints(
    from series: HealthMetricSeries,
    range: HealthMetricTrendRange,
    now: Date,
    calendar: Calendar
  ) -> [HealthMetricPoint] {
    let today = calendar.startOfDay(for: now)
    let start: Date
    let end: Date
    switch range {
    case .today:
      start = today
      end = now.addingTimeInterval(1)
    case .yesterday:
      start = calendar.date(byAdding: .day, value: -1, to: today) ?? today
      end = today
    case .week, .month, .quarter, .year:
      start = calendar.date(byAdding: .day, value: -(range.dayCount - 1), to: today) ?? today
      end = now.addingTimeInterval(1)
    }
    return series.dailyPoints
      .filter { $0.value.isFinite && $0.startedAt >= start && $0.startedAt < end }
      .sorted { $0.startedAt < $1.startedAt }
  }

  static func previousPoints(
    from series: HealthMetricSeries,
    range: HealthMetricTrendRange,
    now: Date,
    calendar suppliedCalendar: Calendar
  ) -> [HealthMetricPoint] {
    var calendar = suppliedCalendar
    calendar.timeZone = suppliedCalendar.timeZone
    let today = calendar.startOfDay(for: now)
    let currentStart: Date
    let previousStart: Date
    let previousEnd: Date

    switch range {
    case .today:
      currentStart = today
      previousStart = calendar.date(byAdding: .day, value: -1, to: currentStart) ?? currentStart
      previousEnd = currentStart
    case .yesterday:
      currentStart = calendar.date(byAdding: .day, value: -1, to: today) ?? today
      previousStart = calendar.date(byAdding: .day, value: -1, to: currentStart) ?? currentStart
      previousEnd = currentStart
    case .week, .month, .quarter, .year:
      currentStart =
        calendar.date(byAdding: .day, value: -(range.dayCount - 1), to: today) ?? today
      previousEnd = currentStart
      previousStart =
        calendar.date(byAdding: .day, value: -range.dayCount, to: previousEnd) ?? previousEnd
    }

    return series.dailyPoints
      .filter {
        $0.value.isFinite && $0.startedAt >= previousStart && $0.startedAt < previousEnd
      }
      .sorted { $0.startedAt < $1.startedAt }
  }

  /// Keeps an absent observation interval visually absent. The threshold follows the factual
  /// bucket duration carried by each point rather than assuming that every metric has daily data.
  static func continuousSegments(_ suppliedPoints: [HealthMetricPoint])
    -> [HealthSpecializedChartSegment]
  {
    let points = suppliedPoints.filter { $0.value.isFinite }.sorted { $0.startedAt < $1.startedAt }
    guard !points.isEmpty else { return [] }
    var result: [HealthSpecializedChartSegment] = []
    var active: [HealthMetricPoint] = []
    for point in points {
      if let previous = active.last {
        let factualBucket = max(60, previous.endedAt.timeIntervalSince(previous.startedAt))
        if point.startedAt.timeIntervalSince(previous.startedAt) > factualBucket * 1.75 {
          result.append(.init(id: result.count, points: active))
          active = []
        }
      }
      active.append(point)
    }
    if !active.isEmpty { result.append(.init(id: result.count, points: active)) }
    return result
  }
}

/// A low-cost specialized health card. Compact cards stay at 24 plotted points. Range bands and
/// previous-period details are only created for the single card the user explicitly expands.
struct HealthSpecializedMetricCard: View {
  let kind: HealthSpecializedCardKind
  let series: [HealthMetricSeries]
  let range: HealthMetricTrendRange
  let now: Date
  let isExpanded: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    if let presentation = HealthSpecializedCardPresentationAdapter.make(
      kind: kind,
      series: series,
      range: range,
      now: now,
      isExpanded: isExpanded
    ) {
      VStack(alignment: .leading, spacing: DaydaySpace.m) {
        Label(kind.title, systemImage: kind.systemImage)
          .font(DaydayType.sectionTitle)
          .foregroundStyle(kind.tint)

        switch kind {
        case .sleep:
          sleepContent(presentation)
        case .heart:
          heartContent(presentation)
        case .activity, .body:
          metricGrid(presentation)
        }
      }
      .padding(DaydaySpace.m)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        kind.tint.opacity(0.035),
        in: RoundedRectangle(cornerRadius: DaydayRadius.partition, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: DaydayRadius.partition, style: .continuous)
          .stroke(kind.tint.opacity(0.14), lineWidth: DaydayDepth.hairline)
      }
      .accessibilityElement(children: .contain)
      .accessibilityLabel("\(kind.title)健康事实")
    }
  }

  @ViewBuilder
  private func sleepContent(_ presentation: HealthSpecializedCardPresentation) -> some View {
    if let metric = presentation.metrics.first {
      HStack(alignment: .firstTextBaseline) {
        Text(metric.currentValue.map { formatMetricValue($0, kind: metric.kind) } ?? "—")
          .font(.system(size: 24, weight: .semibold, design: .rounded))
          .monospacedDigit()
        Spacer()
        comparison(metric)
      }
      Chart(metric.currentPoints) { point in
        BarMark(
          x: .value("日期", point.startedAt),
          y: .value("睡眠时长", point.value / 3_600)
        )
        .foregroundStyle(kind.tint.gradient)
        .cornerRadius(3)
      }
      .chartYAxis(presentation.isExpanded ? .automatic : .hidden)
      .chartXAxis(presentation.isExpanded ? .automatic : .hidden)
      .frame(height: presentation.isExpanded ? 180 : 88)
      .accessibilityLabel("睡眠时长节律；当前投影不包含睡眠阶段分类")
    }
  }

  @ViewBuilder
  private func heartContent(_ presentation: HealthSpecializedCardPresentation) -> some View {
    if let primary = presentation.metrics.first {
      let segments = HealthSpecializedCardPresentationAdapter.continuousSegments(
        primary.currentPoints)
      HStack(alignment: .firstTextBaseline) {
        Text(primary.currentValue.map { formatMetricValue($0, kind: primary.kind) } ?? "—")
          .font(.system(size: 24, weight: .semibold, design: .rounded))
          .monospacedDigit()
        Spacer()
        comparison(primary)
      }
      Chart {
        ForEach(segments) { segment in
          ForEach(segment.points) { point in
            if presentation.isExpanded, let minimum = point.minimum, let maximum = point.maximum {
              AreaMark(
                x: .value("时间", point.startedAt),
                yStart: .value("最低", minimum),
                yEnd: .value("最高", maximum),
                series: .value("连续区间", segment.id)
              )
              .foregroundStyle(kind.tint.opacity(0.12))
              .interpolationMethod(.catmullRom)
            }
            PointMark(
              x: .value("时间", point.startedAt),
              y: .value("心率", point.value)
            )
            .opacity(0)
          }
        }
      }
      .chartLegend(.hidden)
      .chartYScale(domain: primary.visualSnapshot.axis.domain)
      .chartOverlay { proxy in
        GeometryReader { geometry in
          HealthMetricAnimatedLineOverlay(
            points: primary.visualSnapshot.points,
            axis: primary.visualSnapshot.axis,
            kind: primary.kind,
            unit: primary.unit,
            transitionKey: primary.visualSnapshot.transitionKey,
            tint: kind.tint,
            lineWidth: presentation.isExpanded ? 2.4 : 2,
            reduceMotion: reduceMotion,
            plotFrame: proxy.plotFrame.map { geometry[$0] }
          )
          .allowsHitTesting(false)
        }
      }
      .chartYAxis(presentation.isExpanded ? .automatic : .hidden)
      .chartXAxis(presentation.isExpanded ? .automatic : .hidden)
      .frame(height: presentation.isExpanded ? 190 : 96)

      if presentation.isExpanded, presentation.metrics.count > 1 {
        metricGrid(presentation, excludingFirst: true)
      }
    }
  }

  private func metricGrid(
    _ presentation: HealthSpecializedCardPresentation,
    excludingFirst: Bool = false
  ) -> some View {
    let metrics = excludingFirst ? Array(presentation.metrics.dropFirst()) : presentation.metrics
    return LazyVGrid(
      columns: [GridItem(.adaptive(minimum: presentation.isExpanded ? 210 : 150), spacing: 12)],
      alignment: .leading,
      spacing: 12
    ) {
      ForEach(metrics) { metric in
        VStack(alignment: .leading, spacing: DaydaySpace.xs) {
          Label(metric.kind.healthDisplayName, systemImage: metric.kind.healthSymbolName)
            .font(DaydayType.metadata.weight(.semibold))
            .foregroundStyle(metric.kind.healthTint)
          Text(metric.currentValue.map { formatMetricValue($0, kind: metric.kind) } ?? "—")
            .font(.system(size: 19, weight: .semibold, design: .rounded))
            .monospacedDigit()
          if presentation.isExpanded {
            HStack(spacing: DaydaySpace.m) {
              comparison(metric)
              if let low = metric.observedMinimum, let high = metric.observedMaximum {
                Text(
                  "范围 \(formatMetricValue(low, kind: metric.kind))–\(formatMetricValue(high, kind: metric.kind))"
                )
              }
            }
            .font(DaydayType.micro)
            .foregroundStyle(.secondary)
          }
          HealthSpecializedSparkline(
            metric: metric,
            tint: metric.kind.healthTint,
            reduceMotion: reduceMotion
          )
          .frame(height: presentation.isExpanded ? 66 : 38)
        }
        .padding(DaydaySpace.s)
        .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 9))
      }
    }
  }

  @ViewBuilder
  private func comparison(_ metric: HealthSpecializedMetricPresentation) -> some View {
    if isExpanded, let previous = metric.previousValue {
      Text("上一周期 \(formatMetricValue(previous, kind: metric.kind))")
        .font(DaydayType.micro)
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }
  }
}

private struct HealthSpecializedSparkline: View {
  let metric: HealthSpecializedMetricPresentation
  let tint: Color
  let reduceMotion: Bool

  var body: some View {
    GeometryReader { geometry in
      HealthMetricAnimatedLineOverlay(
        points: metric.visualSnapshot.points,
        axis: metric.visualSnapshot.axis,
        kind: metric.kind,
        unit: metric.unit,
        transitionKey: metric.visualSnapshot.transitionKey,
        tint: tint,
        lineWidth: 1.5,
        reduceMotion: reduceMotion,
        plotFrame: CGRect(origin: .zero, size: geometry.size)
      )
    }
    .accessibilityHidden(true)
  }
}
