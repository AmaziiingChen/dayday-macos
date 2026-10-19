import DaydayCore
import Foundation
import Testing

@testable import DaydayApp

struct HealthSpecializedMetricCardsTests {
  private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
  }()

  @Test("Every specialized card has an explicit objective metric catalog")
  func explicitMetricCatalog() {
    #expect(HealthSpecializedCardKind.sleep.metricKinds == [.sleepAnalysis])
    #expect(HealthSpecializedCardKind.heart.metricKinds.first == .heartRate)
    #expect(HealthSpecializedCardKind.activity.metricKinds.contains(.stepCount))
    #expect(HealthSpecializedCardKind.body.metricKinds.contains(.bodyFatPercentage))
  }

  @Test("Compact and expanded presentations keep fixed point budgets")
  func fixedPointBudgets() throws {
    let now = Date(timeIntervalSinceReferenceDate: 800_000)
    var points: [HealthMetricPoint] = []
    for offset in 0..<200 {
      let dayOffset = TimeInterval(offset - 199) * 86_400
      let value = Double(50 + offset % 20)
      points.append(
        HealthMetricPoint(
          startedAt: now.addingTimeInterval(dayOffset),
          endedAt: now.addingTimeInterval(dayOffset + 86_400),
          value: value,
          minimum: value - 5,
          maximum: value + 5,
          contributingSampleCount: 1
        ))
    }
    let series = makeSeries(kind: .heartRate, points: points)

    let compact = try #require(
      HealthSpecializedCardPresentationAdapter.make(
        kind: .heart,
        series: [series],
        range: .year,
        now: now,
        isExpanded: false,
        calendar: calendar
      ))
    let expanded = try #require(
      HealthSpecializedCardPresentationAdapter.make(
        kind: .heart,
        series: [series],
        range: .year,
        now: now,
        isExpanded: true,
        calendar: calendar
      ))

    #expect(compact.metrics[0].currentPoints.count <= 24)
    #expect(expanded.metrics[0].currentPoints.count <= 120)
    #expect(compact.metrics[0].visualSnapshot.points.count == 24)
    #expect(expanded.metrics[0].visualSnapshot.points.count == 120)
    #expect(compact.metrics[0].currentPoints.first == expanded.metrics[0].currentPoints.first)
    #expect(compact.metrics[0].currentPoints.last == expanded.metrics[0].currentPoints.last)
  }

  @Test("Previous-period comparison excludes missing days instead of inventing zeroes")
  func previousPeriodPreservesMissingDays() throws {
    let today = calendar.startOfDay(for: Date(timeIntervalSinceReferenceDate: 900_000))
    let points = [
      point(dayOffset: -13, from: today, value: 60),
      point(dayOffset: -9, from: today, value: 80),
      point(dayOffset: -6, from: today, value: 100),
      point(dayOffset: 0, from: today, value: 120),
    ]
    let presentation = try #require(
      HealthSpecializedCardPresentationAdapter.make(
        kind: .heart,
        series: [makeSeries(kind: .heartRate, points: points)],
        range: .week,
        now: today.addingTimeInterval(43_200),
        isExpanded: true,
        calendar: calendar
      ))

    #expect(presentation.metrics[0].previousValue == 70)
    #expect(presentation.metrics[0].currentValue == 110)
    #expect(presentation.metrics[0].observedMinimum == 100)
    #expect(presentation.metrics[0].observedMaximum == 120)
  }

  @Test("Unavailable specialized cards are omitted rather than populated with placeholders")
  func unavailableCardsAreOmitted() {
    #expect(
      HealthSpecializedCardPresentationAdapter.make(
        kind: .sleep,
        series: [],
        range: .week,
        now: .now,
        isExpanded: false,
        calendar: calendar
      ) == nil)
  }

  @Test("Single-day cumulative and duration headlines use daily totals instead of bucket averages")
  func singleDayTotalsUseDailyProjection() throws {
    let today = calendar.startOfDay(for: Date(timeIntervalSinceReferenceDate: 1_100_000))
    let now = today.addingTimeInterval(18 * 3_600)
    let previousDay = point(dayOffset: -1, from: today, value: 8_000)
    let currentDay = point(dayOffset: 0, from: today, value: 10_000)
    let intraday = [
      HealthMetricPoint(
        startedAt: today,
        endedAt: today.addingTimeInterval(900),
        value: 100,
        contributingSampleCount: 1
      ),
      HealthMetricPoint(
        startedAt: today.addingTimeInterval(900),
        endedAt: today.addingTimeInterval(1_800),
        value: 200,
        contributingSampleCount: 1
      ),
    ]
    let steps = makeSeries(
      kind: .stepCount,
      aggregation: .cumulativeSum,
      unit: .count,
      points: [previousDay, currentDay],
      intradayPoints: intraday
    )
    let activity = try #require(
      HealthSpecializedCardPresentationAdapter.make(
        kind: .activity,
        series: [steps],
        range: .today,
        now: now,
        isExpanded: true,
        calendar: calendar
      ))

    #expect(activity.metrics[0].currentValue == 10_000)
    #expect(activity.metrics[0].previousValue == 8_000)

    let sleep = makeSeries(
      kind: .sleepAnalysis,
      aggregation: .duration,
      unit: .seconds,
      points: [
        point(dayOffset: -1, from: today, value: 7 * 3_600),
        point(dayOffset: 0, from: today, value: 6 * 3_600),
      ],
      intradayPoints: intraday
    )
    let sleepCard = try #require(
      HealthSpecializedCardPresentationAdapter.make(
        kind: .sleep,
        series: [sleep],
        range: .today,
        now: now,
        isExpanded: true,
        calendar: calendar
      ))
    #expect(sleepCard.metrics[0].currentValue == Double(6 * 3_600))
    #expect(sleepCard.metrics[0].previousValue == Double(7 * 3_600))

    let heart = makeSeries(
      kind: .heartRate,
      points: [
        HealthMetricPoint(
          startedAt: previousDay.startedAt,
          endedAt: previousDay.endedAt,
          value: 70,
          contributingSampleCount: 80
        ),
        HealthMetricPoint(
          startedAt: currentDay.startedAt,
          endedAt: currentDay.endedAt,
          value: 80,
          contributingSampleCount: 100
        ),
      ],
      intradayPoints: intraday
    )
    let heartCard = try #require(
      HealthSpecializedCardPresentationAdapter.make(
        kind: .heart,
        series: [heart],
        range: .today,
        now: now,
        isExpanded: true,
        calendar: calendar
      ))
    #expect(heartCard.metrics[0].currentValue == 80)
    #expect(heartCard.metrics[0].previousValue == 70)
  }

  @Test("Compact presentations skip previous-period and observed-range derivation")
  func compactSkipsExpandedDerivations() throws {
    let today = calendar.startOfDay(for: Date(timeIntervalSinceReferenceDate: 1_200_000))
    let presentation = try #require(
      HealthSpecializedCardPresentationAdapter.make(
        kind: .heart,
        series: [
          makeSeries(
            kind: .heartRate,
            points: [
              point(dayOffset: -8, from: today, value: 60),
              point(dayOffset: 0, from: today, value: 70),
            ])
        ],
        range: .week,
        now: today.addingTimeInterval(1),
        isExpanded: false,
        calendar: calendar
      ))

    #expect(presentation.metrics[0].previousValue == nil)
    #expect(presentation.metrics[0].observedMinimum == nil)
    #expect(presentation.metrics[0].observedMaximum == nil)
  }

  @Test("Specialized ranges keep stable morph slots and produce an intermediate curve")
  @MainActor
  func stableMorphIdentityAndIntermediateShape() throws {
    let today = calendar.startOfDay(for: Date(timeIntervalSinceReferenceDate: 1_300_000))
    let points = (-29...0).map { offset in
      point(dayOffset: offset, from: today, value: Double(70 + offset % 7))
    }
    let series = makeSeries(kind: .heartRate, points: points)
    let week = try #require(
      HealthSpecializedCardPresentationAdapter.make(
        kind: .heart,
        series: [series],
        range: .week,
        now: today.addingTimeInterval(1),
        isExpanded: false,
        calendar: calendar
      ))
    let month = try #require(
      HealthSpecializedCardPresentationAdapter.make(
        kind: .heart,
        series: [series],
        range: .month,
        now: today.addingTimeInterval(1),
        isExpanded: false,
        calendar: calendar
      ))

    #expect(
      week.metrics[0].visualSnapshot.points.map(\.slot)
        == month.metrics[0].visualSnapshot.points.map(\.slot))

    let source = [
      HealthMetricAnimatedLineOverlay.RenderPoint(y: 0.2, connectedToPrevious: false),
      HealthMetricAnimatedLineOverlay.RenderPoint(y: 0.4, connectedToPrevious: true),
    ]
    let target = [
      HealthMetricAnimatedLineOverlay.RenderPoint(y: 0.8, connectedToPrevious: false),
      HealthMetricAnimatedLineOverlay.RenderPoint(y: 0.6, connectedToPrevious: true),
    ]
    let midpoint = HealthMetricMorphCanvas(
      source: source,
      target: target,
      progress: 0.5,
      tint: .pink,
      lineWidth: 1.5,
      plotFrame: .zero
    ).interpolatedPoints

    #expect(midpoint.map(\.y) == [0.5, 0.5])
    #expect(HealthMetricChartMotion.animation(reduceMotion: true) == nil)
  }

  @Test("Missing factual intervals split chart paths instead of being connected")
  func missingIntervalsSplitChartPaths() {
    let today = calendar.startOfDay(for: Date(timeIntervalSinceReferenceDate: 1_000_000))
    let points = [
      point(dayOffset: -4, from: today, value: 60),
      point(dayOffset: -3, from: today, value: 62),
      point(dayOffset: 0, from: today, value: 64),
    ]

    let segments = HealthSpecializedCardPresentationAdapter.continuousSegments(points)

    #expect(segments.map(\.points.count) == [2, 1])
  }

  private func makeSeries(
    kind: HealthObservationKind,
    aggregation: HealthMetricAggregation = .discreteAverage,
    unit: HealthMetricUnit = .beatsPerMinute,
    points: [HealthMetricPoint],
    intradayPoints: [HealthMetricPoint] = []
  ) -> HealthMetricSeries {
    HealthMetricSeries(
      kind: kind,
      aggregation: aggregation,
      unit: unit,
      latestSample: points.last,
      dailyPoints: points,
      intradayPoints: intradayPoints
    )
  }

  private func point(dayOffset: Int, from today: Date, value: Double) -> HealthMetricPoint {
    let start = calendar.date(byAdding: .day, value: dayOffset, to: today)!
    return HealthMetricPoint(
      startedAt: start,
      endedAt: calendar.date(byAdding: .day, value: 1, to: start)!,
      value: value,
      minimum: nil,
      maximum: nil,
      contributingSampleCount: 1
    )
  }
}
