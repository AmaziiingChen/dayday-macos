import DaydayCore
import Foundation
import Testing

@testable import DaydayApp

@Suite("Pipeline diagnostics")
struct PipelineDiagnosticsModelTests {
  @Test("Publishes content-free counts and provider usage")
  @MainActor
  func publishesCountsWithoutExposingCapturedText() async throws {
    let now = Date()
    let repository = DiagnosticsRepository(
      observations: [
        try observation(kind: .objectiveText, text: "private OCR text", at: now),
        try observation(kind: .inference, text: "private visual summary", at: now),
      ],
      usage: ScreenVisionUsageSummary(
        callCount: 3, successCount: 2, inputTokens: 10, outputTokens: 4,
        cachedInputTokens: 0, totalTokens: 14, failuresByCategory: [.network: 1],
        failuresByStage: [.providerRequest: 1]
      )
    )
    let model = PipelineDiagnosticsModel()
    model.configure(
      visibleContent: repository,
      textProduction: repository,
      visionUsage: repository
    )

    #expect(await eventually { !model.isRefreshing })
    #expect(model.objectiveTextDescription.contains("1 条"))
    #expect(model.visualInferenceDescription.contains("1 条"))
    #expect(model.visionUsageDescription == "2/3 成功 · 14 tokens · 失败：请求 1")
    #expect(!model.objectiveTextDescription.contains("private"))
    #expect(!model.visualInferenceDescription.contains("private"))
  }

  @Test("Shows content-free visual anchor and segment trace")
  @MainActor
  func showsContentFreeScreenVisionTrace() {
    let model = PipelineDiagnosticsModel()
    model.applyScreenVisionTrace(
      .init(
        pendingTimeSliceCount: 2,
        lastAnchor: .submission,
        lastTransition: .changed,
        lastCompletedAt: Date(timeIntervalSinceReferenceDate: 8_000),
        lastFailureCategory: nil,
        lastFailureStage: nil
      )
    )

    #expect(model.visualAnchorDescription.contains("回车或数字键盘 Enter"))
    #expect(model.visualAnchorDescription.contains("2 个待处理时片"))
    #expect(model.visualSegmentDescription.contains("状态已变化，切分新片段"))
  }

  @Test("Shows a content-free visual failure stage")
  @MainActor
  func showsContentFreeScreenVisionFailureStage() {
    let model = PipelineDiagnosticsModel()
    model.applyScreenVisionTrace(
      .init(
        pendingTimeSliceCount: 64,
        lastAnchor: nil,
        lastTransition: nil,
        lastCompletedAt: nil,
        lastFailureCategory: .invalidResponse,
        lastFailureStage: .responseValidation
      )
    )

    #expect(model.visualAnchorDescription.contains("64 个待处理时片"))
    #expect(model.visualSegmentDescription.contains("响应校验 / invalidResponse"))
  }

  private func observation(
    kind: VisibleContentKind,
    text: String,
    at date: Date
  ) throws -> VisibleContentObservation {
    try VisibleContentObservation(
      provenance: VisibleContentProvenance(
        source: CollectorSource(
          collector: .screenUnderstanding,
          collectorVersion: "test-v1",
          payloadSchemaVersion: 1
        ),
        observedAt: date,
        timeZoneIdentifier: "UTC"
      ),
      kind: kind,
      classification: .ordinaryVisibleContent,
      redactionState: .noRedactionNeeded,
      text: text,
      inferenceOrigin: kind == .inference ? "test-v1" : nil
    )
  }

  @MainActor
  private func eventually(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
    for _ in 0..<100 {
      if condition() { return true }
      await Task.yield()
    }
    return condition()
  }
}

private actor DiagnosticsRepository: VisibleContentArchiveRepository,
  TextProductionAggregateRepository, ScreenVisionUsageRepository
{
  let observations: [VisibleContentObservation]
  let usage: ScreenVisionUsageSummary

  init(observations: [VisibleContentObservation], usage: ScreenVisionUsageSummary) {
    self.observations = observations
    self.usage = usage
  }

  func insert(_ observation: VisibleContentObservation) async throws -> DeepCaptureInsertResult {
    .alreadyPresent
  }

  func fetchVisibleContent(observedIn range: Range<Date>) async throws
    -> [VisibleContentObservation]
  {
    observations.filter { range.contains($0.provenance.observedAt) }
  }

  func insert(_ aggregate: TextProductionAggregate) async throws -> DeepCaptureInsertResult {
    .alreadyPresent
  }

  func fetchTextProduction(observedIn range: Range<Date>) async throws
    -> [TextProductionAggregate]
  {
    []
  }

  func insert(_ record: ScreenVisionUsageRecord) async throws -> DeepCaptureInsertResult {
    .alreadyPresent
  }

  func screenVisionUsage(in range: Range<Date>) async throws -> ScreenVisionUsageSummary {
    usage
  }
}
