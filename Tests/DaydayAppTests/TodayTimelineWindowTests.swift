import Foundation
import Testing

@testable import DaydayApp

@Suite("Today timeline progressive window")
struct TodayTimelineWindowTests {
  @Test("AI visual inferences remain the primary Today narrative")
  func prioritizesVisualInferences() {
    let inference = inferenceItem(at: .distantPast)

    #expect(TodayTimelineWindow.primaryItems(from: [item, inference, item]) == [inference])
    #expect(!TodayTimelineWindow.usesObjectiveFallback(from: [item, inference]))
    #expect(TodayTimelineWindow.primaryItems(from: [item, item]).count == 2)
  }

  @Test("New objective facts replace a visual narrative that has fallen behind")
  func fallsBackToNewerObjectiveFacts() {
    let visualAt = Date(timeIntervalSinceReferenceDate: 10_000)
    let inference = inferenceItem(at: visualAt)
    let recentFact = makeItem(at: visualAt.addingTimeInterval(10 * 60 + 1))
    let selection = TodayTimelineWindow.primaryItems(from: [recentFact, inference])

    #expect(TodayTimelineWindow.usesObjectiveFallback(from: [recentFact, inference]))
    #expect(selection == [recentFact, inference])
  }

  @Test("New local Activity also exposes evidence when visual AI has fallen behind")
  func fallsBackToNewerLocalActivity() {
    let visualAt = Date(timeIntervalSinceReferenceDate: 15_000)
    let inference = inferenceItem(at: visualAt)
    let recentActivity = makeItem(
      id: "local-activity",
      at: visualAt.addingTimeInterval(10 * 60 + 1),
      kind: .activityInference
    )

    #expect(TodayTimelineWindow.usesObjectiveFallback(from: [recentActivity, inference]))
    #expect(
      TodayTimelineWindow.primaryItems(from: [recentActivity, inference]) == [
        recentActivity, inference,
      ])
  }

  @Test("Visual inference remains primary within the bounded processing window")
  func keepsRecentVisualInferencePrimary() {
    let visualAt = Date(timeIntervalSinceReferenceDate: 20_000)
    let inference = inferenceItem(at: visualAt)
    let recentFact = makeItem(at: visualAt.addingTimeInterval(4 * 60))

    #expect(!TodayTimelineWindow.usesObjectiveFallback(from: [recentFact, inference]))
    #expect(TodayTimelineWindow.primaryItems(from: [recentFact, inference]) == [inference])
  }

  @Test("Starts with only the latest five records")
  func startsBounded() {
    #expect(TodayTimelineWindow.initialItemLimit == 5)
    let items = Array(repeating: item, count: 120)
    #expect(TodayTimelineWindow.visibleItems(from: items, limit: 5).count == 5)
    #expect(TodayTimelineWindow.canRevealMore(totalCount: 120, currentLimit: 5))
  }

  @Test("Reveals fixed five-record batches without exceeding local results")
  func revealsBatches() {
    #expect(TodayTimelineWindow.nextLimit(currentLimit: 5, totalCount: 400) == 10)
    #expect(TodayTimelineWindow.nextBatchCount(currentLimit: 5, totalCount: 400) == 5)
    #expect(TodayTimelineWindow.nextLimit(currentLimit: 10, totalCount: 13) == 13)
    #expect(TodayTimelineWindow.nextBatchCount(currentLimit: 10, totalCount: 13) == 3)
    #expect(!TodayTimelineWindow.canRevealMore(totalCount: 13, currentLimit: 13))
  }

  @Test("Handles empty and invalid presentation limits")
  func handlesEdgeCases() {
    #expect(TodayTimelineWindow.visibleItems(from: [], limit: -1).isEmpty)
    #expect(TodayTimelineWindow.nextLimit(currentLimit: -1, totalCount: 0) == 0)
    #expect(TodayTimelineWindow.nextLimit(currentLimit: -1, totalCount: 3) == 3)
    #expect(!TodayTimelineWindow.canRevealMore(totalCount: 3, currentLimit: 3))
  }

  private var item: TodayTimelineItem {
    makeItem(at: .distantPast)
  }

  private func makeItem(at date: Date) -> TodayTimelineItem {
    makeItem(id: "item", at: date, kind: .objectiveFact)
  }

  private func makeItem(
    id: String,
    at date: Date,
    kind: TodayTimelineItemKind
  ) -> TodayTimelineItem {
    TodayTimelineItem(
      id: id,
      occurredAt: date,
      timeDescription: "04:00",
      endedAt: nil,
      kind: kind,
      title: "本地事实",
      sourceLabel: "本地",
      accessibilityLabel: "本地事实"
    )
  }

  private func inferenceItem(at date: Date) -> TodayTimelineItem {
    TodayTimelineItem(
      id: "inference",
      occurredAt: date,
      timeDescription: "04:01",
      endedAt: nil,
      kind: .inferredActivity,
      title: "推断活动",
      sourceLabel: "AI 视觉推断",
      accessibilityLabel: "AI 推断",
      inference: VisualInferenceDigest(
        id: "digest",
        startedAt: date,
        endedAt: nil,
        summary: "推断活动",
        interaction: "正在处理工作内容",
        activityKind: "work",
        evidence: ["可见应用切换"],
        observationCount: 1,
        displayID: nil,
        observationIDs: []
      )
    )
  }
}
