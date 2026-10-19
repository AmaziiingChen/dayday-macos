import DaydayCore
import Foundation
import SwiftUI
import Testing

@testable import DaydayApp

@Suite("Health archive dashboard presentation")
struct HealthArchiveDashboardPresentationTests {
  @Test("Day density fills zero days and preserves objective totals")
  func fillsCalendarRange() throws {
    let calendar = utcCalendar
    let first = date(2026, 8, 1, calendar: calendar)
    let third = date(2026, 8, 3, calendar: calendar)
    let value = try HealthArchiveDensityPresentationAdapter.make(
      from: [
        HealthArchiveDayCount(logicalDate: "2026-08-01", observationCount: 4),
        HealthArchiveDayCount(logicalDate: "2026-08-03", observationCount: 9),
      ],
      startsAt: first,
      endsAt: third,
      calendar: calendar
    )

    #expect(value.days.map(\.observationCount) == [4, 0, 9])
    #expect(value.activeDayCount == 2)
    #expect(value.observationCount == 13)
    #expect(value.maximumDayCount == 9)
  }

  @Test("Heat intensity is logarithmic, bounded, and neutral for no records")
  func intensityScale() {
    #expect(HealthArchiveDensityPresentationAdapter.intensity(value: 0, maximum: 100) == 0)
    let low = HealthArchiveDensityPresentationAdapter.intensity(value: 1, maximum: 100)
    let high = HealthArchiveDensityPresentationAdapter.intensity(value: 50, maximum: 100)
    #expect(low > 0)
    #expect(high > low)
    #expect(HealthArchiveDensityPresentationAdapter.intensity(value: 100, maximum: 100) == 1)
  }

  @Test("Shared heat intensity remains continuous between endpoints")
  func continuousHeatScale() {
    let values = stride(from: 1.0, through: 100.0, by: 1).map {
      DaydayHeatmapScale.intensity(value: $0, maximum: 100)
    }
    #expect(values.count == 100)
    #expect(zip(values, values.dropFirst()).allSatisfy { $0 < $1 })
    #expect(values.last == 1)
  }

  @Test("Wave reveal clamps boundaries and fully settles the final cell")
  func waveBoundaries() {
    let before = DaydayHeatmapWaveMotion.cellProgress(
      globalProgress: -2,
      column: 0,
      row: 0,
      columnCount: 53,
      reduceMotion: false
    )
    let after = DaydayHeatmapWaveMotion.cellProgress(
      globalProgress: 3,
      column: 52,
      row: 3,
      columnCount: 53,
      reduceMotion: false
    )

    #expect(before == 0)
    #expect(abs(after - 1) < 0.000_001)
    #expect(
      DaydayHeatmapWaveMotion.cellScale(revealProgress: -1, reduceMotion: false) == 0.92
    )
    #expect(
      DaydayHeatmapWaveMotion.cellScale(revealProgress: 2, reduceMotion: false) == 1)
    #expect(
      DaydayHeatmapWaveMotion.cellVerticalOffset(
        revealProgress: -1,
        reduceMotion: false
      ) == 0.45)
    #expect(
      DaydayHeatmapWaveMotion.cellVerticalOffset(
        revealProgress: 2,
        reduceMotion: false
      ) == 0)
  }

  @Test("Wave advances by column with only a small row phase")
  func waveDirectionAndPhase() {
    let earlyColumnPhase = DaydayHeatmapWaveMotion.phase(
      column: 4,
      row: 2,
      columnCount: 20
    )
    let laterColumnPhase = DaydayHeatmapWaveMotion.phase(
      column: 12,
      row: 2,
      columnCount: 20
    )
    let neighboringRowPhase = DaydayHeatmapWaveMotion.phase(
      column: 4,
      row: 3,
      columnCount: 20
    )

    #expect(earlyColumnPhase < laterColumnPhase)
    #expect(earlyColumnPhase != neighboringRowPhase)
    let waveEdge = DaydayHeatmapWaveMotion.phase(
      column: 4,
      row: 0,
      columnCount: 53
    )
    let waveCrest = DaydayHeatmapWaveMotion.phase(
      column: 4,
      row: 3,
      columnCount: 53
    )
    #expect(waveCrest - waveEdge > 0)
    #expect(waveCrest - waveEdge < 0.025)

    let globalProgress = 0.42
    let revealedEarlier = DaydayHeatmapWaveMotion.cellProgress(
      globalProgress: globalProgress,
      column: 4,
      row: 2,
      columnCount: 20,
      reduceMotion: false
    )
    let revealedLater = DaydayHeatmapWaveMotion.cellProgress(
      globalProgress: globalProgress,
      column: 12,
      row: 2,
      columnCount: 20,
      reduceMotion: false
    )
    #expect(revealedEarlier > revealedLater)
  }

  @Test("Reduce Motion turns the wave into one short uniform fade")
  func reducedMotionWave() {
    let first = DaydayHeatmapWaveMotion.cellProgress(
      globalProgress: 0.4,
      column: 0,
      row: 0,
      columnCount: 53,
      reduceMotion: true
    )
    let last = DaydayHeatmapWaveMotion.cellProgress(
      globalProgress: 0.4,
      column: 52,
      row: 6,
      columnCount: 53,
      reduceMotion: true
    )

    #expect(first == 0.4)
    #expect(last == first)
    #expect(
      DaydayHeatmapWaveMotion.cellScale(revealProgress: 0.4, reduceMotion: true) == 1)
    #expect(
      DaydayHeatmapWaveMotion.animationDuration(
        columnCount: 5,
        reduceMotion: false
      ) == 0.44)
    #expect(
      DaydayHeatmapWaveMotion.animationDuration(
        columnCount: 53,
        reduceMotion: false
      ) == 0.62)
    #expect(
      DaydayHeatmapWaveMotion.animationDuration(
        columnCount: 53,
        reduceMotion: true
      ) == 0.15)
    #expect(
      DaydayHeatmapWaveMotion.cellVerticalOffset(
        revealProgress: 0.4,
        reduceMotion: true
      ) == 0)
  }

  @Test("Heatmap canvas exposes reveal progress to SwiftUI interpolation")
  @MainActor
  func waveCanvasIsAnimatable() {
    var canvas = HealthMetricWaveCanvas(
      columns: [],
      minimumValue: 0,
      maximumValue: 0,
      tint: .pink,
      layout: .fitting(availableWidth: 600, columnCount: 53),
      reduceMotion: false,
      revealProgress: 0,
      hoveredDay: .constant(nil)
    )

    #expect(canvas.animatableData == 0)
    canvas.animatableData = 0.42
    #expect(canvas.revealProgress == 0.42)
  }

  @Test("Metric calendar preserves missing days and real value bounds")
  func metricCalendarValues() {
    let calendar = utcCalendar
    let first = date(2026, 8, 1, calendar: calendar)
    let third = date(2026, 8, 3, calendar: calendar)
    let series = HealthMetricSeries(
      kind: .heartRate,
      aggregation: .discreteAverage,
      unit: .beatsPerMinute,
      latestSample: nil,
      dailyPoints: [
        metricPoint(at: third, value: 82),
        metricPoint(at: first, value: 61),
      ],
      intradayPoints: []
    )

    let presentation = HealthMetricPresentationAdapter.calendar(
      from: series,
      startsAt: first,
      endsAt: third,
      calendar: calendar
    )

    #expect(presentation.days.map(\.value) == [61, nil, 82])
    #expect(presentation.minimumValue == 61)
    #expect(presentation.maximumValue == 82)
  }

  @Test("Trend ranges select intraday detail or chronological daily values")
  func metricTrendRanges() {
    let calendar = utcCalendar
    let today = date(2026, 8, 9, calendar: calendar)
    let now = calendar.date(byAdding: .hour, value: 12, to: today)!
    let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
    let twoMonthsAgo = calendar.date(byAdding: .day, value: -60, to: today)!
    let fourMonthsAgo = calendar.date(byAdding: .day, value: -120, to: today)!
    let intradayEarly = metricPoint(
      at: calendar.date(byAdding: .hour, value: 8, to: today)!, value: 67)
    let intradayLate = metricPoint(
      at: calendar.date(byAdding: .hour, value: 10, to: today)!, value: 74)
    let yesterdayDetail = metricPoint(
      at: calendar.date(byAdding: .hour, value: 9, to: yesterday)!, value: 65)
    let series = HealthMetricSeries(
      kind: .heartRate,
      aggregation: .discreteAverage,
      unit: .beatsPerMinute,
      latestSample: intradayLate,
      dailyPoints: [
        metricPoint(at: fourMonthsAgo, value: 55),
        metricPoint(at: twoMonthsAgo, value: 64),
        metricPoint(at: today, value: 72),
        metricPoint(at: yesterday, value: 69),
      ],
      intradayPoints: [intradayLate, yesterdayDetail, intradayEarly]
    )

    #expect(
      HealthMetricPresentationAdapter.trendPoints(
        from: series,
        range: .yesterday,
        now: now,
        calendar: calendar
      ).map(\.value) == [69]
    )
    #expect(
      HealthMetricPresentationAdapter.trendPoints(
        from: series,
        range: .today,
        now: now,
        calendar: calendar
      ).map(\.value) == [67, 74]
    )
    #expect(
      HealthMetricPresentationAdapter.trendPoints(
        from: series,
        range: .week,
        now: now,
        calendar: calendar
      ).map(\.value) == [69, 72]
    )
    #expect(
      HealthMetricPresentationAdapter.trendPoints(
        from: series,
        range: .quarter,
        now: now,
        calendar: calendar
      ).map(\.value) == [64, 69, 72]
    )
    #expect(
      HealthMetricPresentationAdapter.trendPoints(
        from: series,
        range: .year,
        now: now,
        calendar: calendar
      ).map(\.value) == [55, 64, 69, 72]
    )
    #expect(
      HealthMetricPresentationAdapter.plotPoints(
        from: series,
        range: .yesterday,
        now: now,
        calendar: calendar
      ).map(\.value) == [65]
    )
    #expect(
      HealthMetricPresentationAdapter.plotPoints(
        from: series,
        range: .week,
        now: now,
        calendar: calendar
      ).map(\.value) == [69, 72]
    )
  }

  @Test("Cumulative trends use intraday detail for one day and comparable daily totals for a week")
  func cumulativeTrendResolution() {
    let calendar = utcCalendar
    let today = date(2026, 8, 9, calendar: calendar)
    let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
    let now = calendar.date(byAdding: .hour, value: 12, to: today)!
    let series = HealthMetricSeries(
      kind: .stepCount,
      aggregation: .cumulativeSum,
      unit: .count,
      latestSample: nil,
      dailyPoints: [
        metricPoint(at: yesterday, value: 8_000),
        metricPoint(at: today, value: 3_000),
      ],
      intradayPoints: [
        metricPoint(
          at: calendar.date(byAdding: .hour, value: 9, to: today)!, value: 600),
        metricPoint(
          at: calendar.date(byAdding: .hour, value: 10, to: today)!, value: 450),
      ]
    )

    #expect(
      HealthMetricPresentationAdapter.plotPoints(
        from: series,
        range: .today,
        now: now,
        calendar: calendar
      ).map(\.value) == [600, 450]
    )
    #expect(
      HealthMetricPresentationAdapter.plotPoints(
        from: series,
        range: .week,
        now: now,
        calendar: calendar
      ).map(\.value) == [8_000, 3_000]
    )
    let summary = HealthMetricPresentationAdapter.cardSummary(
      from: series,
      range: .today,
      now: now,
      calendar: calendar
    )
    #expect(summary.value == 3_000)
  }

  @Test("Line sampling remains bounded and preserves endpoints and a sharp factual peak")
  func lineSampling() {
    let start = Date(timeIntervalSinceReferenceDate: 0)
    var points: [HealthMetricPoint] = []
    points.reserveCapacity(1_000)
    for index in 0..<1_000 {
      points.append(
        metricPoint(
          at: start.addingTimeInterval(Double(index) * 300),
          value: index == 517 ? 180 : 60 + Double(index % 5)
        )
      )
    }

    let sampled = HealthMetricPointSampling.downsample(points, limit: 120)

    #expect(sampled.count == 120)
    #expect(sampled.first == points.first)
    #expect(sampled.last == points.last)
    #expect(sampled.contains { $0.value == 180 })
    let sampledDates = sampled.map { $0.startedAt }
    #expect(sampledDates == sampledDates.sorted())
  }

  @Test("Morph projection keeps a stable identity catalog across ranges and display modes")
  func morphProjectionStableSlots() {
    let start = Date(timeIntervalSinceReferenceDate: 0)
    let today = [
      metricPoint(at: start, value: 60),
      metricPoint(at: start.addingTimeInterval(300), value: 70),
    ]
    let year = (0..<365).map {
      metricPoint(at: start.addingTimeInterval(Double($0) * 86_400), value: Double($0))
    }

    let compactToday = HealthMetricMorphProjection.make(from: today, mode: .compact)
    let compactYear = HealthMetricMorphProjection.make(from: year, mode: .compact)
    let expanded = HealthMetricMorphProjection.make(from: year, mode: .expanded)

    #expect(compactToday.count == 120)
    #expect(compactYear.count == 120)
    #expect(compactToday.map(\.id) == compactYear.map(\.id))
    #expect(compactToday.map(\.id) == Array(0..<120))
    #expect(expanded.count == 360)
    #expect(expanded.map(\.id) == Array(0..<360))
  }

  @Test("Morph projection is deterministic, chronological, finite, and preserves endpoints")
  func morphProjectionDeterminism() {
    let start = Date(timeIntervalSinceReferenceDate: 100)
    let points = [
      metricPoint(at: start.addingTimeInterval(600), value: 80),
      metricPoint(at: start, value: 60),
      metricPoint(at: start.addingTimeInterval(300), value: 70),
      metricPoint(at: start.addingTimeInterval(300), value: 75, contributingSampleCount: 2),
      metricPoint(at: start.addingTimeInterval(900), value: .nan),
    ]

    let first = HealthMetricMorphProjection.make(from: points, mode: .compact)
    let second = HealthMetricMorphProjection.make(from: Array(points.reversed()), mode: .compact)
    let finite = first.compactMap(\.value)
    let dates = first.compactMap(\.date)

    #expect(first == second)
    #expect(first.first?.date == start)
    #expect(first.first?.value == 60)
    #expect(first.last?.date == start.addingTimeInterval(600))
    #expect(first.last?.value == 80)
    #expect(finite.allSatisfy { $0.isFinite })
    #expect(dates == dates.sorted())
  }

  @Test("Sparse morph projection uses a bounded smooth curve instead of linear segments")
  func morphProjectionSmoothsSparseSeries() {
    let start = Date(timeIntervalSinceReferenceDate: 0)
    let end = start.addingTimeInterval(600)
    let projection = HealthMetricMorphProjection.make(
      from: [
        metricPoint(at: start, value: 0, duration: 300),
        metricPoint(at: end, value: 100, duration: 300),
      ],
      mode: .compact
    )
    let slot = 30
    let linearProgress =
      Double(slot) / Double(HealthMetricChartDisplayMode.compact.targetSlotCount - 1)
    let value = projection[slot].value

    #expect(value != nil)
    #expect(value! < linearProgress * 100)
    #expect(projection.compactMap(\.value).allSatisfy { (0...100).contains($0) })
    #expect(projection.first?.value == 0)
    #expect(projection.last?.value == 100)
  }

  @Test("Dense morph projection keeps LTTB anchors but fills stable slots with a bounded curve")
  func morphProjectionSmoothsDenseSeries() {
    let start = Date(timeIntervalSinceReferenceDate: 0)
    let points = (0..<1_000).map { index in
      metricPoint(
        at: start.addingTimeInterval(Double(index) * 60),
        value: 70 + sin(Double(index) / 24) * 12,
        duration: 60
      )
    }
    let sourceDates = Set(points.map(\.startedAt))

    let projection = HealthMetricMorphProjection.make(from: points, mode: .compact)
    let values = projection.compactMap(\.value)

    #expect(projection.count == HealthMetricChartDisplayMode.compact.targetSlotCount)
    #expect(projection.first?.date == points.first?.startedAt)
    #expect(projection.last?.date == points.last?.startedAt)
    #expect(
      projection.contains { point in
        point.date.map { !sourceDates.contains($0) } ?? false
      })
    #expect(values.allSatisfy { (58...82).contains($0) })
  }

  @Test("Morph projection leaves genuine cadence gaps disconnected")
  func morphProjectionPreservesGaps() {
    let start = Date(timeIntervalSinceReferenceDate: 0)
    let points = [
      metricPoint(at: start, value: 60, duration: 300),
      metricPoint(at: start.addingTimeInterval(300), value: 62, duration: 300),
      metricPoint(at: start.addingTimeInterval(600), value: 64, duration: 300),
      metricPoint(at: start.addingTimeInterval(7_200), value: 80, duration: 300),
      metricPoint(at: start.addingTimeInterval(7_500), value: 82, duration: 300),
    ]

    let projection = HealthMetricMorphProjection.make(from: points, mode: .compact)
    let gapPoints = projection.filter {
      guard let date = $0.date else { return false }
      return date > start.addingTimeInterval(600) && date < start.addingTimeInterval(7_200)
    }

    #expect(!gapPoints.isEmpty)
    #expect(gapPoints.allSatisfy { $0.value == nil })
    let secondSegment = projection.first { point in
      guard let date = point.date else { return false }
      return date >= start.addingTimeInterval(7_200) && point.value != nil
    }
    #expect(secondSegment?.isConnectedToPrevious == false)
  }

  @Test("Morph projection bridges one missing daily bucket for a readable trend")
  func morphProjectionBridgesSingleMissingDay() {
    let start = Date(timeIntervalSinceReferenceDate: 0)
    let day: TimeInterval = 86_400
    let points = [
      metricPoint(at: start, value: 60, duration: day),
      metricPoint(at: start.addingTimeInterval(day), value: 62, duration: day),
      metricPoint(at: start.addingTimeInterval(day * 3), value: 68, duration: day),
    ]

    let projection = HealthMetricMorphProjection.make(from: points, mode: .compact)
    let resumed = projection.first { point in
      guard let date = point.date else { return false }
      return date >= start.addingTimeInterval(day * 3) && point.value != nil
    }

    #expect(projection.compactMap(\.value).count == projection.count)
    #expect(resumed?.isConnectedToPrevious == true)
  }

  @Test("Morph projection bridges one missing five-minute bucket for a readable trend")
  func morphProjectionBridgesSingleMissingFiveMinuteBucket() {
    let start = Date(timeIntervalSinceReferenceDate: 0)
    let bucket: TimeInterval = 300
    let points = [
      metricPoint(at: start, value: 60, duration: bucket),
      metricPoint(at: start.addingTimeInterval(bucket), value: 62, duration: bucket),
      metricPoint(at: start.addingTimeInterval(bucket * 3), value: 68, duration: bucket),
    ]

    let projection = HealthMetricMorphProjection.make(from: points, mode: .compact)
    let resumed = projection.first { point in
      guard let date = point.date else { return false }
      return date >= start.addingTimeInterval(bucket * 3) && point.value != nil
    }

    #expect(projection.compactMap(\.value).count == projection.count)
    #expect(resumed?.isConnectedToPrevious == true)
  }

  @Test("Morph projection disconnects a sustained daily gap")
  func morphProjectionDisconnectsSustainedDailyGap() {
    let start = Date(timeIntervalSinceReferenceDate: 0)
    let day: TimeInterval = 86_400
    let points = [
      metricPoint(at: start, value: 60, duration: day),
      metricPoint(at: start.addingTimeInterval(day), value: 62, duration: day),
      metricPoint(at: start.addingTimeInterval(day * 5), value: 68, duration: day),
    ]

    let projection = HealthMetricMorphProjection.make(from: points, mode: .compact)
    let resumed = projection.first { point in
      guard let date = point.date else { return false }
      return date >= start.addingTimeInterval(day * 5) && point.value != nil
    }

    #expect(projection.contains { $0.value == nil })
    #expect(resumed?.isConnectedToPrevious == false)
  }

  @Test("Morph projection disconnects a sustained five-minute gap")
  func morphProjectionDisconnectsSustainedFiveMinuteGap() {
    let start = Date(timeIntervalSinceReferenceDate: 0)
    let bucket: TimeInterval = 300
    let points = [
      metricPoint(at: start, value: 60, duration: bucket),
      metricPoint(at: start.addingTimeInterval(bucket), value: 62, duration: bucket),
      metricPoint(at: start.addingTimeInterval(bucket * 5), value: 68, duration: bucket),
    ]

    let projection = HealthMetricMorphProjection.make(from: points, mode: .compact)
    let resumed = projection.first { point in
      guard let date = point.date else { return false }
      return date >= start.addingTimeInterval(bucket * 5) && point.value != nil
    }

    #expect(projection.contains { $0.value == nil })
    #expect(resumed?.isConnectedToPrevious == false)
  }

  @Test("Gap policy accepts ordinary Apple Watch sampling jitter")
  func gapPolicyAcceptsOrdinarySamplingJitter() {
    let start = Date(timeIntervalSinceReferenceDate: 0)
    let points = metricPoints(
      startingAt: start,
      bucket: 300,
      deltas: [300, 330, 270, 360, 300, 345]
    )

    #expect(HealthMetricGapPolicy.genuineGapIntervals(in: points).isEmpty)
  }

  @Test("Gap policy excludes an off-wrist outlier from normal cadence")
  func gapPolicyRejectsOffWristOutlier() {
    let start = Date(timeIntervalSinceReferenceDate: 0)
    let points = metricPoints(
      startingAt: start,
      bucket: 300,
      deltas: [300, 300, 300, 300, 300, 5_700, 300, 300]
    )

    let gaps = HealthMetricGapPolicy.genuineGapIntervals(in: points)

    #expect(gaps.count == 1)
    #expect(gaps.first?.lowerBound == start.addingTimeInterval(1_800))
    #expect(gaps.first?.upperBound == start.addingTimeInterval(7_200))
  }

  @Test("Gap policy clamps cadence to three buckets and threshold to twelve")
  func gapPolicyClampsCadenceAndThreshold() {
    let start = Date(timeIntervalSinceReferenceDate: 0)
    let cadenceClampPoints = metricPoints(
      startingAt: start,
      bucket: 300,
      deltas: [1_200, 1_200, 1_200, 1_200, 1_200, 3_000]
    )
    let thresholdCapPoints = metricPoints(
      startingAt: start,
      bucket: 300,
      deltas: [300, 300, 300, 300, 1_800, 1_800, 1_800, 1_800, 3_900]
    )

    #expect(HealthMetricGapPolicy.genuineGapIntervals(in: cadenceClampPoints).count == 1)
    #expect(HealthMetricGapPolicy.genuineGapIntervals(in: thresholdCapPoints).count == 1)
  }

  @Test("Morph projection handles empty and single-point input without inventing facts")
  func morphProjectionSparseInput() {
    let empty = HealthMetricMorphProjection.make(from: [], mode: .compact)
    let date = Date(timeIntervalSinceReferenceDate: 42)
    let single = HealthMetricMorphProjection.make(
      from: [metricPoint(at: date, value: 72)],
      mode: .expanded
    )

    #expect(empty.count == 120)
    #expect(empty.allSatisfy { $0.date == nil && $0.value == nil })
    #expect(single.count == 360)
    #expect(single.compactMap(\.value) == [72])
    #expect(single.compactMap(\.date) == [date])
    #expect(single.allSatisfy { !$0.isConnectedToPrevious })
  }

  @Test("Morph projection bounds a large source series to the selected render budget")
  func morphProjectionBoundedOutput() {
    let start = Date(timeIntervalSinceReferenceDate: 0)
    var points: [HealthMetricPoint] = []
    points.reserveCapacity(50_000)
    for index in 0..<50_000 {
      points.append(
        metricPoint(
          at: start.addingTimeInterval(Double(index) * 300),
          value: index == 31_337 ? 180 : 60 + Double(index % 7),
          duration: 300
        ))
    }

    let compact = HealthMetricMorphProjection.make(from: points, mode: .compact)
    let expanded = HealthMetricMorphProjection.make(from: points, mode: .expanded)

    #expect(compact.count == 120)
    #expect(expanded.count == 360)
    #expect(compact.contains { $0.value == 180 })
    #expect(expanded.contains { $0.value == 180 })
  }

  @Test("Trend filters expose yesterday through year in the agreed order")
  func trendFilterCatalog() {
    #expect(
      HealthMetricTrendRange.allCases == [
        .yesterday, .today, .week, .month, .quarter, .year,
      ]
    )
    #expect(
      HealthMetricTrendRange.allCases.map(\.title) == [
        "昨天", "当天", "7 天", "1 个月", "3 个月", "全年",
      ])
    #expect(HealthMetricTrendRange.quarter.dayCount == 90)
    #expect(!HealthMetricTrendRange.today.presentsRangeAverage)
    #expect(HealthMetricTrendRange.week.presentsRangeAverage)
  }

  @Test("Metric formatting uses health units instead of archive counts")
  func metricFormatting() {
    #expect(formatMetricValue(72, kind: .heartRate) == "72 BPM")
    #expect(formatMetricValue(12_345, kind: .stepCount) == "12,345 步")
    #expect(formatMetricValue(27_000, kind: .sleepAnalysis) == "7 小时 30 分")
    #expect(formatMetricValue(16.4, kind: .respiratoryRate) == "16.4 次/分")
    #expect(formatMetricValue(0.98, kind: .oxygenSaturation) == "98%")
    #expect(formatMetricValue(5_420, kind: .distanceWalkingRunning) == "5.42 公里")
    #expect(formatMetricValue(71.25, kind: .bodyMass) == "71.2 公斤")
    #expect(formatMetricValue(0.75, kind: .dietaryWater) == "0.75 升")
    #expect(
      healthMetricChartValue(5_420, kind: .distanceWalkingRunning, unit: .meters) == 5.42)
    #expect(healthMetricChartValue(7_200, kind: .sleepAnalysis, unit: .seconds) == 2)
  }

  @Test("Measured metric catalog is broader than the initial three and remains stable")
  func expandedMetricCatalog() {
    let kinds = HealthMetricPresentationAdapter.preferredKinds
    #expect(kinds.count == HealthObservationKind.allCases.count)
    #expect(Set(kinds).count == kinds.count)
    #expect(kinds.prefix(3) == [.heartRate, .stepCount, .sleepAnalysis])
    #expect(kinds.contains(.respiratoryRate))
    #expect(kinds.contains(.activeEnergyBurned))
    #expect(kinds.contains(.bodyMass))
    #expect(kinds.contains(.dietaryWater))
    #expect(kinds.contains(.environmentalAudioExposure))
    #expect(Set(kinds) == Set(HealthObservationKind.allCases))
  }

  @Test("Focused metric preference is local, stable, and never permits an empty dashboard")
  func focusedMetricPreference() {
    let available: Set<HealthObservationKind> = [.heartRate, .stepCount, .sleepAnalysis]
    #expect(
      HealthMetricVisibilityPreference.decode(
        HealthMetricVisibilityPreference.allToken,
        available: available
      ) == available
    )
    let encoded = HealthMetricVisibilityPreference.encode(
      [.sleepAnalysis, .heartRate],
      available: available
    )
    #expect(encoded == "heartRate,sleepAnalysis")
    #expect(
      HealthMetricVisibilityPreference.decode(encoded, available: available)
        == [.heartRate, .sleepAnalysis]
    )
    #expect(
      HealthMetricVisibilityPreference.decode("unknown", available: available) == available
    )
  }

  @Test("Health metric waterfall balances cards without changing their stable order")
  func waterfallDistribution() {
    let heights: [CGFloat] = [260, 260, 230, 230, 230]
    let columns = HealthMetricWaterfallDistribution.columns(
      for: Array(heights.indices),
      columnCount: 2,
      estimatedHeight: { heights[$0] }
    )
    #expect(columns.count == 2)
    #expect(columns.flatMap { $0 }.sorted() == Array(heights.indices))
    let totals = columns.map { column in column.reduce(0) { $0 + heights[$1] } }
    #expect(abs(totals[0] - totals[1]) <= 260)
  }

  @Test("Health metric waterfall expands from one to four columns at stable card widths")
  func waterfallResponsiveColumns() {
    #expect(HealthMetricWaterfallDistribution.columnCount(for: 400) == 1)
    #expect(HealthMetricWaterfallDistribution.columnCount(for: 519) == 1)
    #expect(HealthMetricWaterfallDistribution.columnCount(for: 520) == 2)
    #expect(HealthMetricWaterfallDistribution.columnCount(for: 779) == 2)
    #expect(HealthMetricWaterfallDistribution.columnCount(for: 780) == 3)
    #expect(HealthMetricWaterfallDistribution.columnCount(for: 1_039) == 3)
    #expect(HealthMetricWaterfallDistribution.columnCount(for: 1_040) == 4)
    #expect(HealthMetricWaterfallDistribution.columnCount(for: 1_600) == 4)
  }

  @Test("Wide waterfall fills complete opening rows and expands by complete rows")
  func waterfallVisibleCounts() {
    #expect(
      HealthMetricWaterfallDistribution.visibleCount(
        requested: 6,
        total: 24,
        columnCount: 4
      ) == 8
    )
    #expect(
      HealthMetricWaterfallDistribution.visibleCount(
        requested: 6,
        total: 24,
        columnCount: 3
      ) == 6
    )
    #expect(
      HealthMetricWaterfallDistribution.visibleCount(
        requested: 6,
        total: 5,
        columnCount: 4
      ) == 5
    )
    #expect(
      HealthMetricWaterfallDistribution.expandedVisibleCount(
        current: 8,
        total: 24,
        columnCount: 4
      ) == 16
    )
    #expect(
      HealthMetricWaterfallDistribution.expandedVisibleCount(
        current: 16,
        total: 18,
        columnCount: 4
      ) == 18
    )
  }

  @Test("Metrics with finite data in the latest seven days precede stale and empty metrics")
  func recentDataPriority() {
    let calendar = utcCalendar
    let today = date(2026, 8, 9, calendar: calendar)
    let now = calendar.date(byAdding: .hour, value: 12, to: today)!
    let recent = calendar.date(byAdding: .day, value: -2, to: today)!
    let stale = calendar.date(byAdding: .day, value: -8, to: today)!
    let input = [
      metricSeries(kind: .dietaryWater, dailyPoints: [metricPoint(at: stale, value: 0.8)]),
      metricSeries(kind: .stepCount, dailyPoints: [metricPoint(at: recent, value: 7_200)]),
      metricSeries(kind: .heartRate, dailyPoints: [metricPoint(at: today, value: 68)]),
      metricSeries(kind: .bodyMass, dailyPoints: []),
    ]

    let prioritized = HealthMetricPresentationAdapter.prioritizingRecentData(
      in: input,
      range: .week,
      now: now,
      calendar: calendar
    )

    #expect(prioritized.map(\.kind) == [.stepCount, .heartRate, .dietaryWater, .bodyMass])
  }

  @Test("Each health metric keeps an independent trend range")
  func independentCardRanges() {
    var selections = HealthMetricCardRangeSelections()
    #expect(selections.range(for: .heartRate) == .week)
    #expect(selections.range(for: .sleepAnalysis) == .week)

    selections.set(.today, for: .sleepAnalysis)
    #expect(selections.range(for: .sleepAnalysis) == .today)
    #expect(selections.range(for: .heartRate) == .week)

    selections.set(.year, for: .heartRate)
    #expect(selections.range(for: .heartRate) == .year)
    #expect(selections.range(for: .sleepAnalysis) == .today)
  }

  @Test("Trend average uses only finite visible points")
  func trendAverage() {
    let startedAt = Date(timeIntervalSinceReferenceDate: 0)
    let points = [
      HealthMetricPoint(
        startedAt: startedAt,
        endedAt: startedAt.addingTimeInterval(60),
        value: 60,
        contributingSampleCount: 1
      ),
      HealthMetricPoint(
        startedAt: startedAt.addingTimeInterval(60),
        endedAt: startedAt.addingTimeInterval(120),
        value: 90,
        contributingSampleCount: 1
      ),
      HealthMetricPoint(
        startedAt: startedAt.addingTimeInterval(120),
        endedAt: startedAt.addingTimeInterval(180),
        value: .infinity,
        contributingSampleCount: 1
      ),
    ]

    #expect(HealthMetricPresentationAdapter.averageValue(in: points) == 75)
    #expect(HealthMetricPresentationAdapter.averageValue(in: []) == nil)
  }

  @Test("Discrete averages respect contributing samples and range cards present averages")
  func weightedRangeAverageAndCardSummary() {
    let calendar = utcCalendar
    let today = date(2026, 8, 9, calendar: calendar)
    let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
    let series = HealthMetricSeries(
      kind: .heartRate,
      aggregation: .discreteAverage,
      unit: .beatsPerMinute,
      latestSample: metricPoint(at: today, value: 72, contributingSampleCount: 2),
      dailyPoints: [
        metricPoint(at: yesterday, value: 66, contributingSampleCount: 4),
        metricPoint(at: today, value: 72, contributingSampleCount: 2),
      ],
      intradayPoints: [metricPoint(at: today, value: 72, contributingSampleCount: 2)]
    )

    let week = HealthMetricPresentationAdapter.cardSummary(
      from: series,
      range: .week,
      now: today.addingTimeInterval(3_600),
      calendar: calendar
    )
    #expect(week.value == 68)
    #expect(week.contextLabel == "7 天平均")
    #expect(week.isAverage)

    let yesterdaySummary = HealthMetricPresentationAdapter.cardSummary(
      from: series,
      range: .yesterday,
      now: today.addingTimeInterval(3_600),
      calendar: calendar
    )
    #expect(yesterdaySummary.value == 66)
    #expect(yesterdaySummary.contextLabel == "昨天")
    #expect(!yesterdaySummary.isAverage)
  }

  @Test("Trend axis follows visible heart-rate values instead of forcing a zero baseline")
  func compactHeartRateAxis() {
    let axis = HealthMetricChartAxisPresentation.make(values: [59, 63, 73])
    #expect(axis.domain == 55...75)
    #expect(axis.tickValues == [55, 60, 65, 70, 75])
    #expect(!axis.domain.contains(0))
  }

  @Test("Trend axis keeps readable rounded ticks for cumulative and stable metrics")
  func readableMetricAxes() {
    let steps = HealthMetricChartAxisPresentation.make(values: [1_107, 2_032, 10_557])
    #expect(steps.domain == 0...15_000)
    #expect(steps.tickValues == [0, 5_000, 10_000, 15_000])

    let oxygen = HealthMetricChartAxisPresentation.make(values: [97.1, 97.4, 97.7])
    #expect(oxygen.domain == 94...100)
    #expect(oxygen.tickValues == [94, 96, 98, 100])

    let empty = HealthMetricChartAxisPresentation.make(values: [.nan, .infinity])
    #expect(empty.domain == 0...1)
    #expect(empty.tickValues == [0, 0.5, 1])
  }

  @Test("Line chart tooltip floats beside its point and remains inside the chart")
  func chartTooltipPlacement() {
    let plotFrame = CGRect(x: 50, y: 20, width: 400, height: 220)
    let container = CGSize(width: 500, height: 280)

    let upperLeft = HealthMetricChartTooltipLayout.center(
      anchor: CGPoint(x: 80, y: 45),
      plotFrame: plotFrame,
      containerSize: container
    )
    #expect(upperLeft.x > 80)
    #expect(upperLeft.y > 45)

    let lowerRight = HealthMetricChartTooltipLayout.center(
      anchor: CGPoint(x: 430, y: 220),
      plotFrame: plotFrame,
      containerSize: container
    )
    #expect(lowerRight.x < 430)
    #expect(lowerRight.y < 220)

    let halfWidth = HealthMetricChartTooltipLayout.size.width / 2
    let halfHeight = HealthMetricChartTooltipLayout.size.height / 2
    #expect(lowerRight.x >= halfWidth)
    #expect(lowerRight.x <= container.width - halfWidth)
    #expect(lowerRight.y >= halfHeight)
    #expect(lowerRight.y <= container.height - halfHeight)
  }

  @Test("Calendar heatmap layout shrinks continuously and stays compact on wide pages")
  func responsiveCalendarLayout() {
    let narrow = DaydayCalendarHeatmapLayout.fitting(availableWidth: 430, columnCount: 53)
    let wide = DaydayCalendarHeatmapLayout.fitting(availableWidth: 1_100, columnCount: 53)

    #expect(narrow.cellSize < wide.cellSize)
    #expect(narrow.width <= 430.5)
    #expect(wide.cellSize == 11)
    #expect(wide.width < 750)
  }

  @Test("Health kinds have a stable user-facing group order")
  func healthKindGroups() {
    #expect(HealthArchiveKindGroup.allCases.map(\.sortOrder) == [0, 1, 2, 3, 4, 5])
    #expect(HealthObservationKind.heartRate.healthGroup == .heart)
    #expect(HealthObservationKind.runningPower.healthGroup == .activity)
    #expect(HealthObservationKind.sleepAnalysis.healthGroup == .sleepAndMindfulness)
    #expect(HealthObservationKind.bodyMass.healthGroup == .body)
    #expect(HealthObservationKind.dietaryWater.healthGroup == .nutrition)
    #expect(HealthObservationKind.environmentalAudioExposure.healthGroup == .environment)
    #expect(
      Set(HealthObservationKind.allCases.map(\.healthGroup)) == Set(HealthArchiveKindGroup.allCases)
    )
  }

  @Test("Malformed stored logical dates fail instead of shifting a heatmap cell")
  func malformedLogicalDateFails() {
    #expect(
      throws: HealthArchiveDensityPresentationAdapter.PresentationError.invalidLogicalDate(
        "not-a-day")
    ) {
      _ = try HealthArchiveDensityPresentationAdapter.make(
        from: [HealthArchiveDayCount(logicalDate: "not-a-day", observationCount: 1)],
        startsAt: Date(timeIntervalSinceReferenceDate: 0),
        endsAt: Date(timeIntervalSinceReferenceDate: 1),
        calendar: utcCalendar
      )
    }
    #expect(
      throws: HealthArchiveDensityPresentationAdapter.PresentationError.invalidLogicalDate(
        "2026-02-31")
    ) {
      _ = try HealthArchiveDensityPresentationAdapter.make(
        from: [HealthArchiveDayCount(logicalDate: "2026-02-31", observationCount: 1)],
        startsAt: Date(timeIntervalSinceReferenceDate: 0),
        endsAt: Date(timeIntervalSinceReferenceDate: 1),
        calendar: utcCalendar
      )
    }
  }

  private var utcCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
  }

  private func date(_ year: Int, _ month: Int, _ day: Int, calendar: Calendar) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day))!
  }

  private func metricPoint(
    at date: Date,
    value: Double,
    contributingSampleCount: Int = 1,
    duration: TimeInterval = 3_600
  ) -> HealthMetricPoint {
    HealthMetricPoint(
      startedAt: date,
      endedAt: date.addingTimeInterval(duration),
      value: value,
      contributingSampleCount: contributingSampleCount
    )
  }

  private func metricPoints(
    startingAt start: Date,
    bucket: TimeInterval,
    deltas: [TimeInterval]
  ) -> [HealthMetricPoint] {
    var offsets: [TimeInterval] = [0]
    offsets.reserveCapacity(deltas.count + 1)
    for delta in deltas {
      offsets.append((offsets.last ?? 0) + delta)
    }
    return offsets.enumerated().map { index, offset in
      metricPoint(
        at: start.addingTimeInterval(offset),
        value: Double(index),
        duration: bucket
      )
    }
  }

  private func metricSeries(
    kind: HealthObservationKind,
    dailyPoints: [HealthMetricPoint]
  ) -> HealthMetricSeries {
    HealthMetricSeries(
      kind: kind,
      aggregation: .discreteAverage,
      unit: .count,
      latestSample: dailyPoints.last,
      dailyPoints: dailyPoints,
      intradayPoints: []
    )
  }
}
