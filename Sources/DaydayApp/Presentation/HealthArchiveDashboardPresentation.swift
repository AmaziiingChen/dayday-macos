import DaydayCore
import Foundation

struct HealthArchiveDensityPresentation: Hashable {
  struct Day: Hashable, Identifiable {
    let date: Date
    let observationCount: Int

    var id: Date { date }
  }

  let days: [Day]
  let activeDayCount: Int
  let observationCount: Int
  let maximumDayCount: Int
}

enum HealthArchiveDensityPresentationAdapter {
  enum PresentationError: Error, Equatable {
    case invalidRange
    case invalidLogicalDate(String)
  }

  static func make(
    from counts: [HealthArchiveDayCount],
    startsAt: Date,
    endsAt: Date,
    calendar suppliedCalendar: Calendar = .autoupdatingCurrent
  ) throws -> HealthArchiveDensityPresentation {
    guard startsAt <= endsAt else { throw PresentationError.invalidRange }
    var calendar = suppliedCalendar
    calendar.timeZone = suppliedCalendar.timeZone
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.isLenient = false

    var countByDay: [Date: Int] = [:]
    for count in counts {
      guard count.observationCount >= 0,
        let parsed = formatter.date(from: count.logicalDate),
        formatter.string(from: parsed) == count.logicalDate
      else { throw PresentationError.invalidLogicalDate(count.logicalDate) }
      let day = calendar.startOfDay(for: parsed)
      countByDay[day, default: 0] += count.observationCount
    }

    let firstDay = calendar.startOfDay(for: startsAt)
    let finalDay = calendar.startOfDay(for: endsAt)
    var cursor = firstDay
    var days: [HealthArchiveDensityPresentation.Day] = []
    while cursor <= finalDay {
      days.append(.init(date: cursor, observationCount: countByDay[cursor, default: 0]))
      guard let next = calendar.date(byAdding: .day, value: 1, to: cursor), next > cursor else {
        break
      }
      cursor = next
    }

    return HealthArchiveDensityPresentation(
      days: days,
      activeDayCount: days.lazy.filter { $0.observationCount > 0 }.count,
      observationCount: days.reduce(0) { $0 + $1.observationCount },
      maximumDayCount: days.map(\.observationCount).max() ?? 0
    )
  }

  static func intensity(value: Int, maximum: Int) -> Double {
    DaydayHeatmapScale.intensity(value: Double(value), maximum: Double(maximum))
  }
}

enum HealthMetricTrendRange: String, CaseIterable, Identifiable, Hashable {
  case yesterday
  case today
  case week
  case month
  case quarter
  case year

  var id: Self { self }

  var title: String {
    switch self {
    case .yesterday: "昨天"
    case .today: "当天"
    case .week: "7 天"
    case .month: "1 个月"
    case .quarter: "3 个月"
    case .year: "全年"
    }
  }

  var compactTitle: String {
    switch self {
    case .yesterday: "昨天"
    case .today: "当天"
    case .week: "7天"
    case .month: "1月"
    case .quarter: "3月"
    case .year: "全年"
    }
  }

  var dayCount: Int {
    switch self {
    case .yesterday, .today: 1
    case .week: 7
    case .month: 30
    case .quarter: 90
    case .year: 365
    }
  }

  var presentsRangeAverage: Bool {
    switch self {
    case .yesterday, .today: false
    case .week, .month, .quarter, .year: true
    }
  }

  var preferredXAxisMarkCount: Int {
    switch self {
    case .quarter, .year: 6
    case .yesterday, .today, .week, .month: 7
    }
  }
}

struct HealthMetricCardSummaryPresentation: Equatable {
  let value: Double?
  let contextLabel: String
  let isAverage: Bool
}

struct HealthMetricCalendarPresentation: Hashable {
  struct Day: Hashable, Identifiable {
    let date: Date
    let value: Double?
    let minimum: Double?
    let maximum: Double?

    var id: Date { date }
  }

  let kind: HealthObservationKind
  let days: [Day]
  let minimumValue: Double
  let maximumValue: Double
}

enum HealthMetricPresentationAdapter {
  static let preferredKinds: [HealthObservationKind] = [
    .heartRate,
    .stepCount,
    .sleepAnalysis,
    .restingHeartRate,
    .respiratoryRate,
    .oxygenSaturation,
    .heartRateVariabilitySDNN,
    .activeEnergyBurned,
    .distanceWalkingRunning,
    .appleExerciseTime,
    .timeInDaylight,
    .walkingHeartRateAverage,
    .walkingSpeed,
    .sleepingWristTemperature,
    .workout,
    .mindfulSession,
    .bodyMass,
    .bodyMassIndex,
    .dietaryWater,
    .vo2Max,
    .distanceCycling,
    .basalEnergyBurned,
    .headphoneAudioExposure,
    .environmentalAudioExposure,
    .flightsClimbed,
    .appleStandTime,
    .appleMoveTime,
    .height,
    .bodyFatPercentage,
    .leanBodyMass,
    .appleStandHour,
    .walkingStepLength,
    .walkingAsymmetryPercentage,
    .walkingDoubleSupportPercentage,
    .appleWalkingSteadiness,
    .stairAscentSpeed,
    .stairDescentSpeed,
    .sixMinuteWalkTestDistance,
    .runningSpeed,
    .runningPower,
    .runningStrideLength,
    .runningGroundContactTime,
    .runningVerticalOscillation,
    .dietaryEnergyConsumed,
    .dietaryProtein,
    .dietaryCarbohydrates,
    .dietaryFatTotal,
    .dietarySugar,
    .dietaryFiber,
    .dietarySodium,
    .dietaryCaffeine,
  ]

  static func orderedSeries(_ series: [HealthMetricSeries]) -> [HealthMetricSeries] {
    let rank = Dictionary(uniqueKeysWithValues: preferredKinds.enumerated().map { ($1, $0) })
    return series.sorted {
      let left = rank[$0.kind] ?? Int.max
      let right = rank[$1.kind] ?? Int.max
      if left != right { return left < right }
      if $0.kind.healthGroup.sortOrder != $1.kind.healthGroup.sortOrder {
        return $0.kind.healthGroup.sortOrder < $1.kind.healthGroup.sortOrder
      }
      return $0.kind.rawValue < $1.kind.rawValue
    }
  }

  static func prioritizingRecentData(
    in series: [HealthMetricSeries],
    range: HealthMetricTrendRange = .week,
    now: Date,
    calendar suppliedCalendar: Calendar = .autoupdatingCurrent
  ) -> [HealthMetricSeries] {
    series.enumerated()
      .map { offset, item in
        (
          offset: offset,
          item: item,
          hasData: trendPoints(
            from: item,
            range: range,
            now: now,
            calendar: suppliedCalendar
          ).contains { $0.value.isFinite }
        )
      }
      .sorted { left, right in
        if left.hasData != right.hasData { return left.hasData && !right.hasData }
        return left.offset < right.offset
      }
      .map { $0.item }
  }

  static func calendar(
    from series: HealthMetricSeries,
    startsAt: Date,
    endsAt: Date,
    calendar suppliedCalendar: Calendar = .autoupdatingCurrent
  ) -> HealthMetricCalendarPresentation {
    var calendar = suppliedCalendar
    calendar.timeZone = suppliedCalendar.timeZone
    let byDay = Dictionary(
      series.dailyPoints.map { (calendar.startOfDay(for: $0.startedAt), $0) },
      uniquingKeysWith: { _, newer in newer }
    )
    var cursor = calendar.startOfDay(for: startsAt)
    let finalDay = calendar.startOfDay(for: endsAt)
    var days: [HealthMetricCalendarPresentation.Day] = []
    while cursor <= finalDay {
      let point = byDay[cursor]
      days.append(
        .init(
          date: cursor,
          value: point?.value,
          minimum: point?.minimum,
          maximum: point?.maximum
        ))
      guard let next = calendar.date(byAdding: .day, value: 1, to: cursor), next > cursor else {
        break
      }
      cursor = next
    }
    let values = days.compactMap(\.value)
    return HealthMetricCalendarPresentation(
      kind: series.kind,
      days: days,
      minimumValue: values.min() ?? 0,
      maximumValue: values.max() ?? 0
    )
  }

  static func trendPoints(
    from series: HealthMetricSeries,
    range: HealthMetricTrendRange,
    now: Date,
    calendar suppliedCalendar: Calendar = .autoupdatingCurrent
  ) -> [HealthMetricPoint] {
    var calendar = suppliedCalendar
    calendar.timeZone = suppliedCalendar.timeZone
    let today = calendar.startOfDay(for: now)
    if range == .today, !series.intradayPoints.isEmpty {
      return series.intradayPoints
        .filter { $0.endedAt >= today && $0.startedAt <= now }
        .sorted { $0.startedAt < $1.startedAt }
    }
    if range == .yesterday {
      let start = calendar.date(byAdding: .day, value: -1, to: today) ?? today
      return series.dailyPoints
        .filter { $0.startedAt >= start && $0.startedAt < today }
        .sorted { $0.startedAt < $1.startedAt }
    }
    let start =
      calendar.date(
        byAdding: .day,
        value: -(range.dayCount - 1),
        to: today
      ) ?? today
    return series.dailyPoints
      .filter { $0.startedAt >= start && $0.startedAt <= now }
      .sorted { $0.startedAt < $1.startedAt }
  }

  /// Selects the highest truthful resolution that remains comparable within the chosen range.
  /// Single-day views use truthful intraday detail. Every multi-day range uses daily projections,
  /// so a chart never compares five-minute samples with daily values and normal sampling pauses do
  /// not masquerade as missing days.
  static func plotPoints(
    from series: HealthMetricSeries,
    range: HealthMetricTrendRange,
    now: Date,
    calendar suppliedCalendar: Calendar = .autoupdatingCurrent
  ) -> [HealthMetricPoint] {
    var calendar = suppliedCalendar
    calendar.timeZone = suppliedCalendar.timeZone
    let today = calendar.startOfDay(for: now)
    let interval: Range<Date>?
    switch range {
    case .today:
      interval = today..<now.addingTimeInterval(1)
    case .yesterday:
      let start = calendar.date(byAdding: .day, value: -1, to: today) ?? today
      interval = start..<today
    case .week, .month, .quarter, .year:
      interval = nil
    }

    if let interval {
      let detail = series.intradayPoints
        .filter { $0.endedAt > interval.lowerBound && $0.startedAt < interval.upperBound }
        .sorted { $0.startedAt < $1.startedAt }
      if !detail.isEmpty { return detail }
    }
    return trendPoints(
      from: series,
      range: range,
      now: now,
      calendar: calendar
    )
  }

  static func averageValue(in points: [HealthMetricPoint]) -> Double? {
    let values = points.lazy.map(\.value).filter(\.isFinite)
    var total = 0.0
    var count = 0
    for value in values {
      total += value
      count += 1
    }
    return count > 0 ? total / Double(count) : nil
  }

  static func averageValue(
    in points: [HealthMetricPoint],
    aggregation: HealthMetricAggregation
  ) -> Double? {
    guard aggregation == .discreteAverage else { return averageValue(in: points) }
    var weightedTotal = 0.0
    var totalWeight = 0
    for point in points where point.value.isFinite && point.contributingSampleCount > 0 {
      weightedTotal += point.value * Double(point.contributingSampleCount)
      totalWeight += point.contributingSampleCount
    }
    return totalWeight > 0 ? weightedTotal / Double(totalWeight) : averageValue(in: points)
  }

  static func cardSummary(
    from series: HealthMetricSeries,
    range: HealthMetricTrendRange,
    now: Date,
    calendar suppliedCalendar: Calendar = .autoupdatingCurrent
  ) -> HealthMetricCardSummaryPresentation {
    let points = trendPoints(from: series, range: range, now: now, calendar: suppliedCalendar)
    if range.presentsRangeAverage {
      return .init(
        value: averageValue(in: points, aggregation: series.aggregation),
        contextLabel: "\(range.title)平均",
        isAverage: true
      )
    }

    var calendar = suppliedCalendar
    calendar.timeZone = suppliedCalendar.timeZone
    let today = calendar.startOfDay(for: now)
    let point: HealthMetricPoint?
    if range == .today {
      switch series.aggregation {
      case .discreteAverage:
        point =
          series.latestSample.flatMap {
            $0.endedAt >= today && $0.endedAt <= now ? $0 : nil
          } ?? points.last
      case .cumulativeSum, .duration:
        point =
          series.dailyPoints.last {
            $0.endedAt > today && $0.startedAt <= now
          } ?? points.last
      }
    } else {
      point = points.last
    }

    guard let point else {
      return .init(value: nil, contextLabel: range.title, isAverage: false)
    }
    if range == .yesterday {
      return .init(value: point.value, contextLabel: "昨天", isAverage: false)
    }
    let contextLabel: String
    switch series.aggregation {
    case .discreteAverage:
      contextLabel = point.endedAt.formatted(date: .omitted, time: .shortened)
    case .cumulativeSum, .duration:
      contextLabel = calendar.isDate(point.startedAt, inSameDayAs: now) ? "当天" : "最近一天"
    }
    return .init(value: point.value, contextLabel: contextLabel, isAverage: false)
  }
}

enum HealthMetricPointSampling {
  /// Largest-Triangle-Three-Buckets keeps the first/last anchors and the strongest intervening
  /// shape changes. Hover inspection continues to use the unsampled points.
  static func downsample(
    _ suppliedPoints: [HealthMetricPoint],
    limit: Int
  ) -> [HealthMetricPoint] {
    let points = suppliedPoints.filter { $0.value.isFinite }
    guard limit >= 3, points.count > limit else { return points }

    let bucketWidth = Double(points.count - 2) / Double(limit - 2)
    var sampled: [HealthMetricPoint] = [points[0]]
    sampled.reserveCapacity(limit)
    var anchorIndex = 0

    for bucket in 0..<(limit - 2) {
      let averageStart = min(
        points.count - 1,
        Int(floor(Double(bucket + 1) * bucketWidth)) + 1
      )
      let averageEnd = min(
        points.count,
        Int(floor(Double(bucket + 2) * bucketWidth)) + 1
      )
      let averageRange = averageStart..<max(averageStart + 1, averageEnd)
      let averageCount = Double(averageRange.count)
      let averageX =
        averageRange.reduce(0.0) {
          $0 + points[$1].startedAt.timeIntervalSinceReferenceDate
        } / averageCount
      let averageY = averageRange.reduce(0.0) { $0 + points[$1].value } / averageCount

      let candidateStart = min(
        points.count - 2,
        Int(floor(Double(bucket) * bucketWidth)) + 1
      )
      let candidateEnd = min(
        points.count - 1,
        Int(floor(Double(bucket + 1) * bucketWidth)) + 1
      )
      let anchor = points[anchorIndex]
      let anchorX = anchor.startedAt.timeIntervalSinceReferenceDate
      var selectedIndex = candidateStart
      var largestArea = -Double.infinity
      for index in candidateStart..<max(candidateStart + 1, candidateEnd) {
        let candidate = points[index]
        let candidateX = candidate.startedAt.timeIntervalSinceReferenceDate
        let area = abs(
          (anchorX - averageX) * (candidate.value - anchor.value)
            - (anchorX - candidateX) * (averageY - anchor.value)
        )
        if area > largestArea {
          largestArea = area
          selectedIndex = index
        }
      }
      sampled.append(points[selectedIndex])
      anchorIndex = selectedIndex
    }

    sampled.append(points[points.count - 1])
    return sampled
  }
}

/// Selects the fixed render budget used by a health metric chart. Keeping the slot catalog stable
/// lets Swift Charts interpolate values instead of treating a range change as unrelated inserts
/// and removals.
enum HealthMetricChartDisplayMode: Hashable, Sendable {
  case compact
  case expanded

  var targetSlotCount: Int {
    switch self {
    case .compact: 120
    case .expanded: 360
    }
  }
}

/// A rebuildable, display-only point. `slot` is deliberately independent from metric kind, date,
/// and trend range so every chart in the same display mode exposes exactly the same identities.
/// Raw `HealthMetricPoint` values remain authoritative for summaries and hover inspection.
struct HealthMetricMorphPoint: Identifiable, Hashable, Sendable {
  let slot: Int
  let date: Date?
  let value: Double?
  let isConnectedToPrevious: Bool

  var id: Int { slot }
}

/// Shared visual-gap policy for metric charts. HealthKit quantity samples are irregular even after
/// they are placed into fixed five-minute, quarter-hour, or daily buckets. Breaking the line for
/// every empty bucket turns a real trend into isolated strokes, so the chart may bridge a short
/// sampling pause. Longer uncovered intervals remain explicit gaps. Raw facts still drive every
/// summary and hover value; this policy only controls whether the display line is continuous.
enum HealthMetricGapPolicy {
  private static let dateTolerance: TimeInterval = 1

  static func genuineGapIntervals(in points: [HealthMetricPoint]) -> [Range<Date>] {
    guard points.count > 1 else { return [] }
    let durations = points.compactMap { point -> TimeInterval? in
      let duration = point.endedAt.timeIntervalSince(point.startedAt)
      return duration > dateTolerance && duration.isFinite ? duration : nil
    }.sorted()
    guard !durations.isEmpty else { return [] }
    let nominalBucketDuration = durations[(durations.count - 1) / 2]
    let deltas = zip(points, points.dropFirst()).compactMap { left, right -> TimeInterval? in
      let delta = right.startedAt.timeIntervalSince(left.startedAt)
      return delta > dateTolerance && delta.isFinite ? delta : nil
    }.sorted()
    guard !deltas.isEmpty else { return [] }

    // Bound the observed cadence by the repository bucket width. This accepts Apple Watch's
    // naturally irregular sampling without letting a long period off-wrist redefine a gap as the
    // new normal. MAD adds measured jitter only from intervals that are plausibly continuous.
    let hasEnoughCadenceEvidence = deltas.count >= 5
    let observedCadence =
      hasEnoughCadenceEvidence
      ? min(
        nominalBucketDuration * 3,
        max(nominalBucketDuration, median(deltas))
      )
      : nominalBucketDuration
    let ordinaryDeltas = deltas.filter { $0 <= nominalBucketDuration * 6 }
    let jitter =
      hasEnoughCadenceEvidence
      ? median(ordinaryDeltas.map { abs($0 - observedCadence) }.sorted())
      : 0
    let maximumContinuousDelta = min(
      nominalBucketDuration * 12,
      max(observedCadence * 3, observedCadence + jitter * 6)
    )

    return zip(points, points.dropFirst()).compactMap { left, right in
      let coverageEnd = max(left.startedAt, left.endedAt)
      let uncoveredDuration = right.startedAt.timeIntervalSince(coverageEnd)
      let startDelta = right.startedAt.timeIntervalSince(left.startedAt)
      guard startDelta > maximumContinuousDelta + dateTolerance,
        uncoveredDuration > dateTolerance
      else { return nil }
      return coverageEnd..<right.startedAt
    }
  }

  private static func median(_ sortedValues: [TimeInterval]) -> TimeInterval {
    guard !sortedValues.isEmpty else { return 0 }
    let middle = sortedValues.count / 2
    if sortedValues.count.isMultiple(of: 2) {
      return (sortedValues[middle - 1] + sortedValues[middle]) / 2
    }
    return sortedValues[middle]
  }
}

enum HealthMetricMorphProjection {
  /// Projects finite source facts onto a stable slot catalog. Interpolation only supplies the
  /// transient chart shape between nearby facts; it must never be used for statistics or hover.
  /// A material sampling gap remains nil (or starts a new segment after downsampling), so a long
  /// absent observation interval is not presented as continuous measurement.
  static func make(
    from suppliedPoints: [HealthMetricPoint],
    mode: HealthMetricChartDisplayMode
  ) -> [HealthMetricMorphPoint] {
    let slotCount = mode.targetSlotCount
    let emptySlots = (0..<slotCount).map {
      HealthMetricMorphPoint(
        slot: $0,
        date: nil,
        value: nil,
        isConnectedToPrevious: false
      )
    }
    let points = sanitized(suppliedPoints)
    guard let first = points.first else { return emptySlots }
    guard points.count > 1, let last = points.last, first.startedAt < last.startedAt else {
      var result = emptySlots
      result[0] = HealthMetricMorphPoint(
        slot: 0,
        date: first.startedAt,
        value: first.value,
        isConnectedToPrevious: false
      )
      return result
    }

    let gapIntervals = HealthMetricGapPolicy.genuineGapIntervals(in: points)
    if points.count >= slotCount {
      return sampledProjection(
        points: points,
        slotCount: slotCount,
        gapIntervals: gapIntervals
      )
    }
    return interpolatedProjection(
      points: points,
      slotCount: slotCount,
      gapIntervals: gapIntervals
    )
  }

  private static func sanitized(_ suppliedPoints: [HealthMetricPoint]) -> [HealthMetricPoint] {
    let sorted =
      suppliedPoints
      .filter { $0.value.isFinite }
      .sorted {
        if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
        if $0.endedAt != $1.endedAt { return $0.endedAt < $1.endedAt }
        if $0.contributingSampleCount != $1.contributingSampleCount {
          return $0.contributingSampleCount < $1.contributingSampleCount
        }
        return $0.value < $1.value
      }
    var result: [HealthMetricPoint] = []
    result.reserveCapacity(sorted.count)
    for point in sorted {
      if result.last?.startedAt == point.startedAt {
        // Equal timestamps cannot occupy two temporal positions. The deterministic final member
        // favors the longer aggregate, then the larger sample count/value through the sort above.
        result[result.count - 1] = point
      } else {
        result.append(point)
      }
    }
    return result
  }

  private static func sampledProjection(
    points: [HealthMetricPoint],
    slotCount: Int,
    gapIntervals: [Range<Date>]
  ) -> [HealthMetricMorphPoint] {
    // A render slot is not a control point. Feeding all 120/360 LTTB extrema directly to the
    // spline leaves dense signals such as heart rate looking like a polyline at card size. Keep a
    // pixel-appropriate set of LTTB anchors, then use the same bounded interpolation as sparse
    // series to fill the stable slot catalog. Peaks selected by LTTB and genuine gaps are retained;
    // raw facts remain authoritative for hover, summaries, axes, and accessibility.
    // Roughly one retained anchor per 10-15 horizontal points at the approved card sizes. The
    // remaining slots describe the curve between anchors instead of adding more sharp corners.
    let controlPointLimit = max(12, slotCount / 6)
    let controlPoints = HealthMetricPointSampling.downsample(
      points,
      limit: controlPointLimit
    )
    return interpolatedProjection(
      points: controlPoints,
      slotCount: slotCount,
      gapIntervals: gapIntervals
    )
  }

  private static func interpolatedProjection(
    points: [HealthMetricPoint],
    slotCount: Int,
    gapIntervals: [Range<Date>]
  ) -> [HealthMetricMorphPoint] {
    let anchorSlots = anchorSlotIndexes(points: points, slotCount: slotCount)
    var sourceIndex = 0
    var previousDate: Date?
    var previousValue: Double?
    var result: [HealthMetricMorphPoint] = []
    result.reserveCapacity(slotCount)

    for slot in 0..<slotCount {
      while sourceIndex + 1 < points.count - 1
        && anchorSlots[sourceIndex + 1] < slot
      {
        sourceIndex += 1
      }
      let left = points[sourceIndex]
      let right = points[min(sourceIndex + 1, points.count - 1)]
      let leftSlot = anchorSlots[sourceIndex]
      let rightSlot = anchorSlots[min(sourceIndex + 1, anchorSlots.count - 1)]
      let slotProgress =
        leftSlot == rightSlot
        ? 0
        : Double(slot - leftSlot) / Double(rightSlot - leftSlot)
      let date = left.startedAt.addingTimeInterval(
        right.startedAt.timeIntervalSince(left.startedAt) * slotProgress
      )
      let crossesGap = containsGap(
        from: left.startedAt,
        through: right.startedAt,
        intervals: gapIntervals
      )
      let value: Double?
      if slot == leftSlot {
        value = left.value
      } else if slot == rightSlot {
        value = right.value
      } else if crossesGap {
        value = nil
      } else {
        // Shape sparse facts into a bounded cubic ease before Swift Charts draws the spline. The
        // former linear fill created 120 collinear subsegments, so even a curved LineMark retained
        // obvious polygon corners. Smoothstep keeps every visual value inside its two factual
        // endpoints and gives the range transition a continuous tangent without changing raw data.
        let curvedProgress = slotProgress * slotProgress * (3 - 2 * slotProgress)
        value = left.value + ((right.value - left.value) * curvedProgress)
      }
      let connected =
        value != nil && previousValue != nil
        && previousDate.map {
          !containsGap(from: $0, through: date, intervals: gapIntervals)
        } ?? false
      result.append(
        HealthMetricMorphPoint(
          slot: slot,
          date: date,
          value: value,
          isConnectedToPrevious: connected
        ))
      previousDate = date
      previousValue = value
    }
    return result
  }

  /// Gives every retained factual/control point an exact, unique slot while keeping its temporal
  /// position as close as possible. Leaving at least two render slots per neighboring anchor lets
  /// the bounded curve round the path instead of collapsing back into a one-segment polyline.
  private static func anchorSlotIndexes(
    points: [HealthMetricPoint],
    slotCount: Int
  ) -> [Int] {
    guard points.count > 1 else { return [0] }
    let firstDate = points[0].startedAt
    let duration = points[points.count - 1].startedAt.timeIntervalSince(firstDate)
    let minimumSeparation = slotCount >= ((points.count - 1) * 2 + 1) ? 2 : 1
    var result = [0]
    result.reserveCapacity(points.count)

    for index in 1..<(points.count - 1) {
      let temporalProgress =
        duration > 0
        ? points[index].startedAt.timeIntervalSince(firstDate) / duration
        : Double(index) / Double(points.count - 1)
      let idealSlot = Int((temporalProgress * Double(slotCount - 1)).rounded())
      let minimumSlot = result[result.count - 1] + minimumSeparation
      let anchorsAfterThisOne = points.count - index - 1
      let maximumSlot = slotCount - 1 - anchorsAfterThisOne * minimumSeparation
      result.append(min(maximumSlot, max(minimumSlot, idealSlot)))
    }
    result.append(slotCount - 1)
    return result
  }

  private static func containsGap(
    from start: Date,
    through end: Date,
    intervals: [Range<Date>]
  ) -> Bool {
    guard start < end else { return false }
    return intervals.contains { $0.lowerBound < end && $0.upperBound > start }
  }
}

enum HealthMetricWaterfallDistribution {
  static func columnCount(for availableWidth: CGFloat) -> Int {
    switch availableWidth {
    case 1_040...: 4
    case 780...: 3
    case 520...: 2
    default: 1
    }
  }

  static func columns<Item>(
    for items: [Item],
    columnCount: Int,
    estimatedHeight: (Item) -> CGFloat
  ) -> [[Item]] {
    let count = max(1, columnCount)
    var columns = Array(repeating: [Item](), count: count)
    var heights = Array(repeating: CGFloat.zero, count: count)
    for item in items {
      let column = heights.indices.min { heights[$0] < heights[$1] } ?? 0
      columns[column].append(item)
      heights[column] += max(0, estimatedHeight(item))
    }
    return columns
  }

  static func visibleCount(requested: Int, total: Int, columnCount: Int) -> Int {
    let columns = max(1, columnCount)
    let minimumForBalancedWideLayout = columns >= 3 ? columns * 2 : 0
    return min(max(0, total), max(max(0, requested), minimumForBalancedWideLayout))
  }

  static func expandedVisibleCount(
    current: Int,
    total: Int,
    columnCount: Int,
    increment: Int = 6
  ) -> Int {
    let boundedTotal = max(0, total)
    let boundedCurrent = min(max(0, current), boundedTotal)
    guard boundedCurrent < boundedTotal else { return boundedCurrent }
    let columns = max(1, columnCount)
    let desired = min(boundedTotal, boundedCurrent + max(1, increment))
    let completedRows = ((desired + columns - 1) / columns) * columns
    return min(boundedTotal, completedRows)
  }
}

enum HealthArchiveKindGroup: Int, CaseIterable, Identifiable {
  case heart
  case activity
  case sleepAndMindfulness
  case body
  case nutrition
  case environment

  var id: Self { self }
  var sortOrder: Int { rawValue }

  var title: String {
    switch self {
    case .heart: "心脏与呼吸"
    case .activity: "活动与体能"
    case .sleepAndMindfulness: "睡眠与身心"
    case .body: "身体测量"
    case .nutrition: "营养"
    case .environment: "环境与听力"
    }
  }
}

extension HealthObservationKind {
  var healthGroup: HealthArchiveKindGroup {
    switch self {
    case .heartRate, .restingHeartRate, .heartRateVariabilitySDNN, .respiratoryRate,
      .oxygenSaturation, .walkingHeartRateAverage, .vo2Max:
      .heart
    case .stepCount, .distanceWalkingRunning, .distanceCycling, .flightsClimbed,
      .activeEnergyBurned, .basalEnergyBurned, .appleExerciseTime, .appleStandTime,
      .appleMoveTime, .timeInDaylight, .workout, .appleStandHour, .walkingSpeed,
      .walkingStepLength, .walkingAsymmetryPercentage, .walkingDoubleSupportPercentage,
      .appleWalkingSteadiness, .stairAscentSpeed, .stairDescentSpeed,
      .sixMinuteWalkTestDistance, .runningSpeed, .runningPower, .runningStrideLength,
      .runningGroundContactTime, .runningVerticalOscillation:
      .activity
    case .sleepAnalysis, .sleepingWristTemperature, .mindfulSession:
      .sleepAndMindfulness
    case .bodyMass, .bodyMassIndex, .height, .bodyFatPercentage, .leanBodyMass:
      .body
    case .dietaryWater, .dietaryEnergyConsumed, .dietaryProtein, .dietaryCarbohydrates,
      .dietaryFatTotal, .dietarySugar, .dietaryFiber, .dietarySodium, .dietaryCaffeine:
      .nutrition
    case .headphoneAudioExposure, .environmentalAudioExposure:
      .environment
    }
  }
}
