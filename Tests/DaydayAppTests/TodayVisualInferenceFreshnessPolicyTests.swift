import Foundation
import Testing

@testable import DaydayApp

@Suite("Today visual inference freshness policy")
struct TodayVisualInferenceFreshnessPolicyTests {
  @Test("The normal aggregation window remains an AI-first narrative")
  func keepsVisualNarrativeDuringNormalAggregation() {
    let visualAt = Date(timeIntervalSinceReferenceDate: 12_000)
    let inference = inferenceItem(at: visualAt)
    let latestFact = factItem(at: visualAt.addingTimeInterval(9 * 60))

    #expect(!TodayTimelineWindow.usesObjectiveFallback(from: [latestFact, inference]))
    #expect(TodayTimelineWindow.primaryItems(from: [latestFact, inference]) == [inference])
  }

  @Test("The evidence fallback activates after the bounded aggregation allowance")
  func fallsBackAfterAggregationAllowance() {
    let visualAt = Date(timeIntervalSinceReferenceDate: 13_000)
    let inference = inferenceItem(at: visualAt)
    let latestFact = factItem(at: visualAt.addingTimeInterval(10 * 60 + 1))

    #expect(TodayTimelineWindow.usesObjectiveFallback(from: [latestFact, inference]))
    #expect(
      TodayTimelineWindow.primaryItems(from: [latestFact, inference]) == [latestFact, inference])
  }

  private func factItem(at date: Date) -> TodayTimelineItem {
    .init(
      id: "fact-\(date.timeIntervalSinceReferenceDate)",
      occurredAt: date,
      timeDescription: "04:00",
      endedAt: nil,
      kind: .objectiveFact,
      title: "本地事实",
      sourceLabel: "本地",
      accessibilityLabel: "本地事实"
    )
  }

  private func inferenceItem(at date: Date) -> TodayTimelineItem {
    .init(
      id: "inference-\(date.timeIntervalSinceReferenceDate)",
      occurredAt: date,
      timeDescription: "04:00",
      endedAt: nil,
      kind: .inferredActivity,
      title: "AI 时段",
      sourceLabel: "AI 视觉推断",
      accessibilityLabel: "AI 时段",
      inference: .init(
        id: "digest-\(date.timeIntervalSinceReferenceDate)",
        startedAt: date,
        endedAt: nil,
        summary: "AI 时段",
        interaction: "可见工作状态",
        activityKind: "other",
        evidence: ["可见窗口"],
        observationCount: 1,
        displayID: nil,
        observationIDs: []
      )
    )
  }
}
