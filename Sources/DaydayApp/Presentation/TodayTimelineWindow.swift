import Foundation

/// Keeps the live workday timeline bounded while preserving its latest-first chronology.
///
/// Timeline facts remain available in the local archive. The page starts with a small latest-first
/// window and expands only after the person explicitly asks to see more.
enum TodayTimelineWindow {
  static let initialItemLimit = 5
  static let additionalItemCount = 5
  /// A healthy visual batch starts after the eight-minute local aggregation window, then still
  /// needs bounded provider and archive time. Falling back sooner would present normal batching
  /// as a failed or lagging AI timeline.
  static let visualInferenceStalenessTolerance: TimeInterval = 10 * 60

  /// AI visual inferences are the primary Today narrative. Their disclosure rows already contain
  /// the supporting evidence, so objective facts remain a fallback rather than competing with the
  /// inferred activity cards for the first five positions.
  static func primaryItems(from items: [TodayTimelineItem]) -> [TodayTimelineItem] {
    let visualInferences = items.filter {
      $0.kind == .inferredActivity && $0.inference != nil
    }
    guard !visualInferences.isEmpty else { return items }
    return usesObjectiveFallback(from: items) ? items : visualInferences
  }

  /// A stale visual narrative must not hide newer durable facts. Visual inference remains the
  /// preferred concise story while it is keeping pace; once objective work is more than one
  /// bounded inference window ahead, Today falls back to the complete latest-first evidence list.
  static func usesObjectiveFallback(from items: [TodayTimelineItem]) -> Bool {
    let latestVisual =
      items
      .filter { $0.kind == .inferredActivity && $0.inference != nil }
      .map(effectiveEnd)
      .max()
    let latestLocalEvidence =
      items
      .filter {
        $0.kind == .objectiveFact || $0.kind == .sessionSpan || $0.kind == .activitySegment
          || $0.kind == .activityInference
      }
      .map(effectiveEnd)
      .max()
    guard let latestVisual, let latestLocalEvidence else { return false }
    return
      latestLocalEvidence.timeIntervalSince(latestVisual) > visualInferenceStalenessTolerance
  }

  static func visibleItems(
    from items: [TodayTimelineItem], limit: Int
  ) -> [TodayTimelineItem] {
    Array(items.prefix(normalizedLimit(limit)))
  }

  static func canRevealMore(totalCount: Int, currentLimit: Int) -> Bool {
    normalizedLimit(currentLimit) < totalCount
  }

  static func nextLimit(currentLimit: Int, totalCount: Int) -> Int {
    guard totalCount > 0 else { return 0 }
    let current = normalizedLimit(currentLimit)
    let expanded =
      current > Int.max - additionalItemCount
      ? Int.max
      : current + additionalItemCount
    return min(totalCount, expanded)
  }

  static func nextBatchCount(currentLimit: Int, totalCount: Int) -> Int {
    max(
      0,
      nextLimit(currentLimit: currentLimit, totalCount: totalCount) - normalizedLimit(currentLimit)
    )
  }

  private static func normalizedLimit(_ limit: Int) -> Int {
    max(0, limit)
  }

  private static func effectiveEnd(_ item: TodayTimelineItem) -> Date {
    item.endedAt ?? item.occurredAt
  }
}
