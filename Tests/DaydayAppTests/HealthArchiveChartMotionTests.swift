import DaydayCore
import Foundation
import SwiftUI
import Testing

@testable import DaydayApp

@Suite("Health archive chart motion")
struct HealthArchiveChartMotionTests {
  @Test("Canvas morph exposes a real intermediate Bezier shape")
  @MainActor
  func canvasMorphIntermediateShape() {
    typealias Point = HealthMetricAnimatedLineOverlay.RenderPoint
    var canvas = HealthMetricMorphCanvas(
      source: [
        Point(y: 0.2, connectedToPrevious: false),
        Point(y: 0.4, connectedToPrevious: true),
      ],
      target: [
        Point(y: 0.8, connectedToPrevious: false),
        Point(y: 0.6, connectedToPrevious: true),
      ],
      progress: 0.5,
      tint: .pink,
      lineWidth: 2,
      plotFrame: nil
    )

    #expect(canvas.interpolatedPoints.map(\.y) == [0.5, 0.5])
    #expect(canvas.animatableData == 0.5)
    canvas.animatableData = 0.25
    let intermediate = canvas.interpolatedPoints.compactMap(\.y)
    #expect(intermediate.count == 2)
    #expect(abs(intermediate[0] - 0.35) < 1e-12)
    #expect(abs(intermediate[1] - 0.45) < 1e-12)
  }

  @Test("Snapshot cache key follows revision, display mode, minute, and series identity")
  func cacheKeyIdentity() {
    let now = Date(timeIntervalSince1970: 1_786_320_030)
    let series = makeSeries(values: [60, 64, 70])
    let baseline = HealthMetricLineChartSnapshotCacheKey.make(
      series: series,
      range: .today,
      displayMode: .compact,
      archiveRevision: 8,
      now: now,
      calendar: utcCalendar
    )
    let sameMinute = HealthMetricLineChartSnapshotCacheKey.make(
      series: series,
      range: .today,
      displayMode: .compact,
      archiveRevision: 8,
      now: now.addingTimeInterval(20),
      calendar: utcCalendar
    )
    let nextMinute = HealthMetricLineChartSnapshotCacheKey.make(
      series: series,
      range: .today,
      displayMode: .compact,
      archiveRevision: 8,
      now: now.addingTimeInterval(60),
      calendar: utcCalendar
    )
    let expanded = HealthMetricLineChartSnapshotCacheKey.make(
      series: series,
      range: .today,
      displayMode: .expanded,
      archiveRevision: 8,
      now: now,
      calendar: utcCalendar
    )
    let revised = HealthMetricLineChartSnapshotCacheKey.make(
      series: series,
      range: .today,
      displayMode: .compact,
      archiveRevision: 9,
      now: now,
      calendar: utcCalendar
    )

    #expect(baseline == sameMinute)
    #expect(baseline != nextMinute)
    #expect(baseline != expanded)
    #expect(baseline != revised)
  }

  @Test("Snapshot cache evicts the least recently used entry")
  @MainActor
  func cacheEviction() {
    let now = Date(timeIntervalSince1970: 1_786_320_030)
    let series = makeSeries(values: [60, 64, 70])
    let cache = HealthMetricLineChartSnapshotCache(capacity: 2)
    let keys = (1...3).map { revision in
      HealthMetricLineChartSnapshotCacheKey.make(
        series: series,
        range: .week,
        displayMode: .compact,
        archiveRevision: UInt64(revision),
        now: now,
        calendar: utcCalendar
      )
    }
    func makeSnapshot(revision: UInt64) -> HealthMetricLineChartSnapshot {
      HealthMetricLineChartSnapshot.make(
        series: series,
        range: .week,
        displayMode: .compact,
        archiveRevision: revision,
        now: now
      )
    }

    _ = cache.snapshot(for: keys[0]) { makeSnapshot(revision: 1) }
    _ = cache.snapshot(for: keys[1]) { makeSnapshot(revision: 2) }
    _ = cache.snapshot(for: keys[0]) { makeSnapshot(revision: 1) }
    _ = cache.snapshot(for: keys[2]) { makeSnapshot(revision: 3) }

    #expect(cache.count == 2)
    #expect(cache.contains(keys[0]))
    #expect(!cache.contains(keys[1]))
    #expect(cache.contains(keys[2]))
  }

  @Test("Range changes keep the same compact slot identities")
  func transitionSlotIdentity() {
    let now = Date(timeIntervalSince1970: 1_786_320_030)
    let series = makeSeries(values: [60, 64, 70])
    let today = HealthMetricLineChartSnapshot.make(
      series: series,
      range: .today,
      displayMode: .compact,
      archiveRevision: 1,
      now: now
    )
    let week = HealthMetricLineChartSnapshot.make(
      series: series,
      range: .week,
      displayMode: .compact,
      archiveRevision: 1,
      now: now
    )

    #expect(today.points.map(\.id) == Array(0..<120))
    #expect(week.points.map(\.id) == today.points.map(\.id))
  }

  @Test("Accessible chart descriptor exposes factual points instead of morph slots")
  func accessibilityUsesFactualPoints() {
    let series = makeSeries(values: [60, 64, 70])
    let descriptor = HealthMetricAccessibilityChartDescriptor(
      series: series,
      range: .today,
      points: series.intradayPoints,
      axis: HealthMetricChartAxisPresentation.make(values: [60, 64, 70]),
      pointLimit: HealthMetricChartDisplayMode.compact.targetSlotCount
    ).makeChartDescriptor()
    let accessiblePoints = descriptor.series.flatMap(\.dataPoints)

    #expect(accessiblePoints.count == 3)
    #expect(accessiblePoints.compactMap(\.label).count == 3)
  }

  @Test("Accessible chart descriptor shares sustained-gap segmentation")
  func accessibilityPreservesSustainedGaps() {
    let start = Date(timeIntervalSince1970: 1_786_319_400)
    let offsets: [TimeInterval] = [0, 300, 600, 7_200, 7_500]
    let points = offsets.enumerated().map { index, offset in
      let pointStart = start.addingTimeInterval(offset)
      return HealthMetricPoint(
        startedAt: pointStart,
        endedAt: pointStart.addingTimeInterval(300),
        value: Double(60 + index),
        contributingSampleCount: 1
      )
    }
    let series = makeSeries(points: points)
    let descriptor = HealthMetricAccessibilityChartDescriptor(
      series: series,
      range: .week,
      points: points,
      axis: HealthMetricChartAxisPresentation.make(values: points.map(\.value)),
      pointLimit: HealthMetricChartDisplayMode.compact.targetSlotCount
    ).makeChartDescriptor()

    #expect(descriptor.series.count == 2)
    #expect(descriptor.series.flatMap(\.dataPoints).count == points.count)
  }

  private var utcCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
  }

  private func makeSeries(values: [Double]) -> HealthMetricSeries {
    let start = Date(timeIntervalSince1970: 1_786_319_400)
    let points = values.enumerated().map { index, value in
      let pointStart = start.addingTimeInterval(Double(index) * 300)
      return HealthMetricPoint(
        startedAt: pointStart,
        endedAt: pointStart.addingTimeInterval(300),
        value: value,
        contributingSampleCount: 1
      )
    }
    return makeSeries(points: points)
  }

  private func makeSeries(points: [HealthMetricPoint]) -> HealthMetricSeries {
    HealthMetricSeries(
      kind: .heartRate,
      aggregation: .discreteAverage,
      unit: .beatsPerMinute,
      latestSample: points.last,
      dailyPoints: points,
      intradayPoints: points
    )
  }
}
