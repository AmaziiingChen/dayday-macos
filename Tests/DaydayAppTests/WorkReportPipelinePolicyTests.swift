import DaydayCore
import Foundation
import Testing

@testable import DaydayApp

@Suite("Work report pipeline policy")
struct WorkReportPipelinePolicyTests {
  @Test("stale visual inference blocks report generation until coverage catches up")
  func coverageGateUsesObjectiveAndInferenceWatermarks() throws {
    let start = Date(timeIntervalSince1970: 1_785_736_800)
    let objective = try objectiveObservation(at: start.addingTimeInterval(720))
    let staleInference = try inferenceObservation(at: start.addingTimeInterval(60), label: "WeChat")
    let range = start..<start.addingTimeInterval(900)

    let stale = try WorkReportPipelinePolicy.visualSnapshot(
      from: [objective, staleInference], in: range)
    #expect(stale.coverage.blocksGeneration)
    #expect(stale.coverage.visualLag == 660)
    #expect(stale.coverage.blockingStatusText == "视觉总结延迟约 11 分钟，正在等待更新")

    let freshInference = try inferenceObservation(
      at: start.addingTimeInterval(690), label: "WeChat")
    let fresh = try WorkReportPipelinePolicy.visualSnapshot(
      from: [objective, freshInference], in: range)
    #expect(!fresh.coverage.blocksGeneration)
  }

  @Test("report context is bounded while visible conversation text remains unchanged")
  func compactsVisualContextWithoutFilteringConversationNamesOrContent() throws {
    let start = Date(timeIntervalSince1970: 1_785_736_800)
    let observations = try (0..<50).map { index in
      try inferenceObservation(
        at: start.addingTimeInterval(Double(index) * 10),
        label: index.isMultiple(of: 2) ? "WeChat" : "Messages",
        summary: index == 49 ? "产品研发群 · 联系人陈工：今天完整联调通过" : "第 \(index) 条可见消息"
      )
    }

    let result = try WorkReportPipelinePolicy.visualSnapshot(
      from: observations,
      in: start..<start.addingTimeInterval(600)
    )

    #expect(result.coverage.availableVisualSegmentCount == 1)
    #expect(result.segments.count == 1)
    #expect(result.segments.allSatisfy { $0.segment.evidence.count == 3 })
    #expect(result.segments.last?.segment.primarySituation.contains("产品研发群") == true)
    #expect(result.segments.last?.segment.primarySituation.contains("联系人陈工") == true)
    #expect(result.segments.last?.segment.primarySituation.contains("完整联调通过") == true)
  }

  @Test("low-information work notes warn but are not rejected")
  func warnsForNumericWorkNote() {
    #expect(WorkReportPipelinePolicy.workNoteAdvisory(for: "12132") != nil)
    #expect(WorkReportPipelinePolicy.workNoteAdvisory(for: "完成日报证据水位修复") == nil)
  }

  @Test("repeated accessibility notifications compact without losing EventID provenance")
  func compactsRepeatedObjectiveApplicationSpans() throws {
    let start = Date(timeIntervalSince1970: 1_785_736_800)
    let firstID = EventID()
    let secondID = EventID()
    let segments = [
      try WorkReportObjectiveApplicationSegment(
        startedAt: start, endedAt: start.addingTimeInterval(30),
        applicationLabel: "ChatGPT", windowTitle: "Dayday 管线",
        objectiveEventIDs: [firstID]),
      try WorkReportObjectiveApplicationSegment(
        startedAt: start.addingTimeInterval(30), endedAt: start.addingTimeInterval(90),
        applicationLabel: "ChatGPT", windowTitle: "Dayday 管线",
        objectiveEventIDs: [secondID]),
    ]

    let compacted = WorkReportPipelinePolicy.objectiveApplicationSegments(segments)

    #expect(compacted.count == 1)
    #expect(compacted[0].startedAt == start)
    #expect(compacted[0].endedAt == start.addingTimeInterval(90))
    #expect(compacted[0].objectiveEventIDs == [firstID, secondID])
  }

  private func objectiveObservation(at date: Date) throws -> VisibleContentObservation {
    try VisibleContentObservation(
      provenance: provenance(at: date),
      kind: .objectiveText,
      classification: .conversation,
      redactionState: .noRedactionNeeded,
      text: "产品研发群 · 联系人陈工：继续联调"
    )
  }

  private func inferenceObservation(
    at date: Date,
    label: String,
    summary: String = "继续处理可见聊天内容"
  ) throws -> VisibleContentObservation {
    let display = try VisualDisplayState(
      displayID: try #require(provenance(at: date).display?.id),
      role: .primary,
      visibleState: "\(label) 窗口显示：\(summary)"
    )
    let segment = try VisualWorkSegment(
      primarySituation: summary,
      interaction: "可见输入与阅读",
      activityKind: .communication,
      foregroundApplicationLabel: label,
      displays: [display],
      relationship: .coordinated,
      systemContextAgreement: .matches,
      evidence: (0..<8).map { "证据 \($0)" },
      uncertainties: ["仅能确认屏幕可见内容"]
    )
    return try VisibleContentObservation(
      provenance: provenance(at: date, displayID: display.displayID),
      kind: .inference,
      classification: .conversation,
      redactionState: .noRedactionNeeded,
      text: summary,
      inferenceOrigin: "test-vision-v1",
      visualWorkSegment: segment
    )
  }

  private func provenance(
    at date: Date,
    displayID: DisplayID = DisplayID(
      rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
  ) throws -> VisibleContentProvenance {
    try VisibleContentProvenance(
      source: CollectorSource(
        collector: .screenUnderstanding,
        collectorVersion: "test-v1",
        payloadSchemaVersion: 1
      ),
      observedAt: date,
      timeZoneIdentifier: "UTC",
      display: DisplayContext(id: displayID, topologyRevision: 1)
    )
  }
}
