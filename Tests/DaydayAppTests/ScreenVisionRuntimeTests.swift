import DaydayAI
import DaydayCapture
import DaydayCore
import Foundation
import Testing

@testable import DaydayApp

struct ScreenVisionRuntimeTests {
  @Test
  func configuredRuntimeArchivesProviderResultAsInference() async throws {
    let repository = VisionObservationRepository()
    let client = FixtureScreenVisionClient()
    let runtime = ScreenVisionRuntime(
      provider: .init(
        configuration: .init(
          endpoint: URL(string: "https://vision.example.com")!,
          model: "vision-model"
        ),
        credential: "test-key"
      ),
      client: client
    )
    await runtime.attach(repository)
    await runtime.attachUsageRepository(repository)
    let derivatives = try Self.derivatives()

    for derivative in derivatives { await runtime.receive(derivative) }
    await runtime.flushPending()

    #expect(await client.callCount == 1)
    let archived = try #require(await repository.observations.first)
    #expect(archived.kind == .inference)
    #expect(archived.inferenceOrigin == "byok-screen-vision-timeline-v4")
    #expect(archived.provenance.display == derivatives[0].frame.display)
    #expect(archived.provenance.endedAt == derivatives[2].frame.observedAt)
    #expect(archived.text?.contains("development") == true)
    #expect(archived.text?.contains("正在编辑 Swift 代码") == true)
    #expect(archived.text?.contains("系统前台应用：未取得") == true)
    #expect(archived.visualWorkSegment?.displays.count == 1)
    #expect(archived.visualWorkSegment?.relationship == .coordinated)
    #expect(await repository.usage.count == 1)
    #expect(await repository.usage.first?.totalTokens == 100)
  }

  @Test("One provider request can archive multiple evidence-bound work segments")
  func multiSegmentResponseArchivesEachSegment() async throws {
    let repository = VisionObservationRepository()
    let client = SegmentingVisionClient()
    let runtime = ScreenVisionRuntime(
      provider: .init(
        configuration: .init(
          endpoint: URL(string: "https://vision.example.com")!, model: "vision-model"),
        credential: "test-key"
      ), client: client
    )
    await runtime.attach(repository)
    await runtime.attachUsageRepository(repository)
    let display = DisplayContext(id: DisplayID(), topologyRevision: 1)
    for offset in 0..<4 {
      await runtime.receive(
        try Self.derivative(display: display, at: 5_500 + TimeInterval(offset * 30)))
    }
    await runtime.flushPending()

    #expect(await client.callCount == 1)
    #expect(await repository.observations.count == 2)
    #expect(await repository.observations.map(\.visualWorkSegment?.activityKind) == [
      .reading, .development,
    ])
    #expect(await repository.usage.count == 1)
  }

  @Test
  func missingProviderDropsDerivativeWithoutCallingClientOrArchiving() async throws {
    let repository = VisionObservationRepository()
    let client = FixtureScreenVisionClient()
    let runtime = ScreenVisionRuntime(provider: nil, client: client)
    await runtime.attach(repository)

    for derivative in try Self.derivatives() { await runtime.receive(derivative) }

    #expect(await client.callCount == 0)
    #expect(await repository.observations.isEmpty)
  }

  @Test
  func unauthorizedFailureLatchesUntilExplicitReconfiguration() async throws {
    let repository = VisionObservationRepository()
    let client = UnauthorizedThenSuccessfulVisionClient()
    let provider = ScreenVisionRuntime.Provider(
      configuration: .init(
        endpoint: URL(string: "https://vision.example.com")!, model: "vision-model"),
      credential: "test-key"
    )
    let runtime = ScreenVisionRuntime(provider: provider, client: client)
    await runtime.attach(repository)
    await runtime.attachUsageRepository(repository)

    for derivative in try Self.derivatives() { await runtime.receive(derivative) }
    await runtime.flushPending()
    for derivative in try Self.derivatives(start: 5_100) { await runtime.receive(derivative) }

    #expect(await client.callCount == 1)
    #expect(await repository.usage.count == 1)
    #expect(await repository.usage.first?.errorCategory == .unauthorized)

    await runtime.configure(provider)
    for derivative in try Self.derivatives(start: 5_200) { await runtime.receive(derivative) }
    await runtime.flushPending()

    #expect(await client.callCount == 3)
    #expect(await repository.observations.count == 2)
    #expect(await repository.usage.count == 3)
  }

  @Test
  func simultaneousDisplaysStayInOneTimeSlice() async throws {
    let repository = VisionObservationRepository()
    let client = FixtureScreenVisionClient()
    let runtime = ScreenVisionRuntime(
      provider: .init(
        configuration: .init(endpoint: URL(string: "https://vision.example.com")!, model: "vision-model"),
        credential: "test-key"
      ), client: client
    )
    await runtime.attach(repository)
    let left = DisplayContext(id: DisplayID(), topologyRevision: 1)
    let right = DisplayContext(id: DisplayID(), topologyRevision: 1)
    for offset in 0..<3 {
      for display in [left, right] {
        await runtime.receive(try Self.derivative(
          display: display, at: 6_000 + TimeInterval(offset * 10)
        ))
      }
    }
    await runtime.flushPending()
    #expect(await client.callCount == 1)
    #expect(await client.lastTimeSliceDisplayCounts == [2, 2, 2])
  }

  @Test
  func fourDisplaysAreSampledIntoOneEightFrameWindow() async throws {
    let repository = VisionObservationRepository()
    let client = FixtureScreenVisionClient()
    let runtime = ScreenVisionRuntime(
      provider: .init(
        configuration: .init(
          endpoint: URL(string: "https://vision.example.com")!, model: "vision-model"),
        credential: "test-key"
      ), client: client
    )
    await runtime.attach(repository)
    let displays = (0..<4).map { _ in
      DisplayContext(id: DisplayID(), topologyRevision: 1)
    }
    for offset in 0..<4 {
      for display in displays {
        await runtime.receive(
          try Self.derivative(display: display, at: 6_500 + TimeInterval(offset * 10)))
      }
    }
    await runtime.flushPending()

    #expect(await client.callCount == 1)
    #expect(await client.batchFrameCounts == [8])
    #expect(await repository.observations.count == 1)
  }

  @Test("Submission anchors capture evidence without prematurely invoking the model")
  func submissionAnchorIsAWeakBoundary() async throws {
    let repository = VisionObservationRepository()
    let client = FixtureScreenVisionClient()
    let runtime = ScreenVisionRuntime(
      provider: .init(
        configuration: .init(
          endpoint: URL(string: "https://vision.example.com")!, model: "vision-model"),
        credential: "test-key"
      ),
      client: client,
      timing: .init(
        partialWindowFlushDelay: 10,
        initialRetryDelay: 10,
        maximumRetryDelay: 10
      )
    )
    await runtime.attach(repository)
    for derivative in try Self.derivatives(start: 6_800) { await runtime.receive(derivative) }

    await runtime.recordSubmissionAnchor()

    #expect(await client.callCount == 0)
    await runtime.flushPending()
    #expect(await client.callCount == 1)
  }

  @Test("A long local window sends at most eight representative frames in one request")
  func longWindowUsesRepresentativeFrameBudget() async throws {
    let repository = VisionObservationRepository()
    let client = FixtureScreenVisionClient()
    let runtime = ScreenVisionRuntime(
      provider: .init(
        configuration: .init(
          endpoint: URL(string: "https://vision.example.com")!, model: "vision-model"),
        credential: "test-key"
      ), client: client
    )
    await runtime.attach(repository)
    let display = DisplayContext(id: DisplayID(), topologyRevision: 1)
    for offset in 0..<12 {
      await runtime.receive(
        try Self.derivative(display: display, at: 7_200 + TimeInterval(offset * 30)))
    }
    await runtime.flushPending()

    #expect(await client.callCount == 1)
    #expect(await client.batchFrameCounts == [8])
    #expect(await repository.observations.count == 1)
  }

  @Test
  func shortVisualWindowIsFlushedInsteadOfJoiningLaterWork() async throws {
    let repository = VisionObservationRepository()
    let client = FixtureScreenVisionClient()
    let runtime = ScreenVisionRuntime(
      provider: .init(
        configuration: .init(endpoint: URL(string: "https://vision.example.com")!, model: "vision-model"),
        credential: "test-key"
      ), client: client
    )
    await runtime.attach(repository)
    let display = DisplayContext(id: DisplayID(), topologyRevision: 1)
    await runtime.receive(try Self.derivative(display: display, at: 7_000))
    await runtime.flushPending()
    await runtime.receive(try Self.derivative(display: display, at: 8_000))
    await runtime.flushPending()

    #expect(await client.callCount == 2)
    #expect(await client.lastTimeSliceDisplayCounts == [1])
    #expect(await repository.observations.count == 2)
  }

  @Test("Local acceptance failures are recorded as failures with provider token usage")
  func recordsLocalAcceptanceFailureInsteadOfProviderSuccess() async throws {
    let repository = VisionObservationRepository(failsObservationInsert: true)
    let runtime = ScreenVisionRuntime(
      provider: .init(
        configuration: .init(endpoint: URL(string: "https://vision.example.com")!, model: "vision-model"),
        credential: "test-key"
      ),
      client: FixtureScreenVisionClient()
    )
    await runtime.attach(repository)
    await runtime.attachUsageRepository(repository)
    let display = DisplayContext(id: DisplayID(), topologyRevision: 1)
    await runtime.receive(try Self.derivative(display: display, at: 7_500))
    await runtime.flushPending()

    let usage = await repository.usage
    let recorded = try #require(usage.first)
    #expect(recorded.outcome == .failure)
    #expect(recorded.errorCategory == .archiveFailure)
    #expect(recorded.failureStage == .localAcceptance)
    #expect(recorded.totalTokens == 100)
  }

  @Test
  func providerReceivesOnlyBoundedPriorVisualSegmentContext() async throws {
    let repository = VisionObservationRepository()
    let client = FixtureScreenVisionClient()
    let display = DisplayContext(id: DisplayID(), topologyRevision: 1)
    let priorAt = Date(timeIntervalSinceReferenceDate: 4_900)
    _ = try await repository.insert(
      VisibleContentObservation(
        provenance: .init(
          source: .init(collector: .screenUnderstanding, collectorVersion: "test", payloadSchemaVersion: 1),
          observedAt: priorAt, timeZoneIdentifier: "UTC", display: display
        ),
        kind: .inference,
        redactionState: .noRedactionNeeded,
        text: "AI 视觉推断",
        inferenceOrigin: "test",
        visualWorkSegment: try .init(
          primarySituation: "在 WeChat 对话中起草回复",
          interaction: "输入区域可见",
          activityKind: .writing,
          foregroundApplicationLabel: "WeChat",
          displays: [try .init(displayID: display.id, role: .communication, visibleState: "对话窗口")],
          relationship: .coordinated,
          evidence: ["对话输入区可见"]
        )
      )
    )
    let runtime = ScreenVisionRuntime(
      provider: .init(
        configuration: .init(endpoint: URL(string: "https://vision.example.com")!, model: "vision-model"),
        credential: "test-key"
      ), client: client
    )
    await runtime.attach(repository)
    for derivative in try Self.derivatives(start: 5_000) { await runtime.receive(derivative) }
    await runtime.flushPending()

    #expect(await client.lastPriorSegmentApplications == ["WeChat"])
  }

  @Test("Scheduled partial flush does not cancel its own provider request")
  func scheduledPartialFlushKeepsProviderRequestAlive() async throws {
    let repository = VisionObservationRepository()
    let client = CancellationObservingVisionClient()
    let runtime = ScreenVisionRuntime(
      provider: .init(
        configuration: .init(
          endpoint: URL(string: "https://vision.example.com")!, model: "vision-model"),
        credential: "test-key"
      ),
      client: client,
      timing: .init(
        partialWindowFlushDelay: 0.02,
        initialRetryDelay: 0.03,
        maximumRetryDelay: 0.03
      )
    )
    await runtime.attach(repository)

    for derivative in try Self.derivatives(start: 9_000) {
      await runtime.receive(derivative)
    }

    #expect(await Self.eventually { await repository.observations.count == 1 })
    #expect(await client.callCount == 1)
    #expect(await client.sawCancelledTask == false)
    await runtime.configure(nil)
  }

  @Test("Continuous incoming frames do not postpone a failed batch retry")
  func continuousFramesPreserveRetryDeadline() async throws {
    let repository = VisionObservationRepository()
    let client = RetryThenSuccessfulVisionClient()
    let runtime = ScreenVisionRuntime(
      provider: .init(
        configuration: .init(
          endpoint: URL(string: "https://vision.example.com")!, model: "vision-model"),
        credential: "test-key"
      ),
      client: client,
      timing: .init(
        partialWindowFlushDelay: 1,
        initialRetryDelay: 0.03,
        maximumRetryDelay: 0.03
      )
    )
    await runtime.attach(repository)
    let derivatives = try Self.derivatives(start: 10_000)
    for derivative in derivatives { await runtime.receive(derivative) }
    await runtime.flushPending()
    #expect(await client.callCount == 1)

    let display = derivatives[0].frame.display
    let incoming = try (0..<40).map { offset in
      try Self.derivative(
        display: display,
        at: 10_021 + TimeInterval(offset)
      )
    }
    let feed = Task {
      for derivative in incoming {
        await runtime.receive(derivative)
        try? await Task.sleep(for: .milliseconds(5))
      }
    }

    let recoveredWhileFramesWereArriving = await Self.eventually(timeoutIterations: 30) {
      await client.callCount >= 2
    }
    await feed.value

    #expect(recoveredWhileFramesWereArriving)
    #expect(await repository.observations.count >= 1)
    await runtime.configure(nil)
  }

  @Test("In-memory pending evidence remains aligned with the durable queue capacity")
  @MainActor
  func pendingEvidenceRemainsBounded() async throws {
    let repository = VisionObservationRepository()
    let client = FixtureScreenVisionClient()
    let runtime = ScreenVisionRuntime(
      provider: .init(
        configuration: .init(
          endpoint: URL(string: "https://vision.example.com")!, model: "vision-model"),
        credential: "test-key"
      ),
      client: client,
      timing: .init(
        partialWindowFlushDelay: 10,
        initialRetryDelay: 10,
        maximumRetryDelay: 10
      )
    )
    await runtime.attach(repository)
    let trace = ScreenVisionTraceBox()
    await runtime.setTraceHandler { trace.value = $0 }
    let display = DisplayContext(id: DisplayID(), topologyRevision: 1)

    for offset in 0..<80 {
      await runtime.receive(
        try Self.derivative(display: display, at: 11_000 + TimeInterval(offset))
      )
    }

    #expect(trace.value?.pendingTimeSliceCount == 64)
    #expect(await client.callCount == 0)
    await runtime.configure(nil)
  }

  @Test("A failed evidence window receives at most one immediate retry")
  func failedWindowHasOneImmediateRetry() async throws {
    let repository = VisionObservationRepository()
    let client = AlwaysInvalidVisionClient()
    let runtime = ScreenVisionRuntime(
      provider: .init(
        configuration: .init(
          endpoint: URL(string: "https://vision.example.com")!, model: "vision-model"),
        credential: "test-key"),
      client: client,
      timing: .init(
        partialWindowFlushDelay: 10,
        initialRetryDelay: 0.02,
        maximumRetryDelay: 0.02,
        maximumImmediateRetryAttempts: 1)
    )
    await runtime.attach(repository)
    await runtime.attachUsageRepository(repository)
    await runtime.receive(try Self.derivative(
      display: DisplayContext(id: DisplayID(), topologyRevision: 1), at: 12_000))

    await runtime.flushPending()
    #expect(await Self.eventually { await client.callCount == 2 })
    try? await Task.sleep(for: .milliseconds(80))

    #expect(await client.callCount == 2)
    #expect(await repository.usage.count == 2)
    await runtime.configure(nil)
  }

  @Test("Workday success and attempt caps defer new provider calls without deleting evidence")
  @MainActor
  func workdayCallBudgetIsBounded() async throws {
    let now = Date()
    let seededUsage = try (0..<2).map { offset in
      try ScreenVisionUsageRecord(
        provider: "vision.example.com", model: "vision-model", requestID: "seed-\(offset)",
        startedAt: now.addingTimeInterval(TimeInterval(-offset - 1)),
        completedAt: now.addingTimeInterval(TimeInterval(-offset)),
        outcome: .success)
    }
    let repository = VisionObservationRepository(usage: seededUsage)
    let client = FixtureScreenVisionClient()
    let runtime = ScreenVisionRuntime(
      provider: .init(
        configuration: .init(
          endpoint: URL(string: "https://vision.example.com")!, model: "vision-model"),
        credential: "test-key"),
      client: client,
      timing: .init(
        partialWindowFlushDelay: 10,
        initialRetryDelay: 10,
        maximumRetryDelay: 10,
        maximumSuccessfulCallsPerWorkday: 2,
        maximumAttemptsPerWorkday: 3)
    )
    await runtime.attach(repository)
    await runtime.attachUsageRepository(repository)
    let trace = ScreenVisionTraceBox()
    await runtime.setTraceHandler { trace.value = $0 }
    await runtime.receive(try Self.derivative(
      display: DisplayContext(id: DisplayID(), topologyRevision: 1),
      at: now.timeIntervalSinceReferenceDate))

    await runtime.flushPending()

    #expect(await client.callCount == 0)
    #expect(trace.value?.pendingTimeSliceCount == 1)
    #expect(await repository.observations.isEmpty)
    await runtime.configure(nil)
  }

  private static func derivatives(start: TimeInterval = 5_000) throws -> [ObjectiveScreenVisionDerivative] {
    let display = DisplayContext(id: DisplayID(), topologyRevision: 1)
    return try (0..<3).map { offset in
      try derivative(display: display, at: start + TimeInterval(offset * 10))
    }
  }

  private static func derivative(display: DisplayContext, at observedAt: TimeInterval) throws
    -> ObjectiveScreenVisionDerivative
  {
    try ObjectiveScreenVisionDerivative(
      frame: ObjectiveScreenFrameMetadata(
        display: display,
        observedAt: Date(timeIntervalSinceReferenceDate: observedAt),
        pixelWidth: 2_560,
        pixelHeight: 1_440
      ),
      encodedJPEG: Data([0xFF, 0xD8, 0xFF]),
      pixelWidth: 1_600,
      pixelHeight: 720,
      redactedOCRLines: [try RedactedOCRLine("func buildReport()")]
    )
  }

  private static func eventually(
    timeoutIterations: Int = 200,
    _ condition: @escaping @Sendable () async -> Bool
  ) async -> Bool {
    for _ in 0..<timeoutIterations {
      if await condition() { return true }
      try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
  }
}

@MainActor
private final class ScreenVisionTraceBox {
  var value: ScreenVisionRuntime.Trace?
}

private actor FixtureScreenVisionClient: ScreenVisionInferring {
  private(set) var callCount = 0
  private(set) var batchFrameCounts: [Int] = []
  private(set) var lastTimeSliceDisplayCounts: [Int] = []
  private(set) var lastPriorSegmentApplications: [String?] = []

  func infer(
    batch: ScreenVisualTimelineBatch,
    configuration: OpenAICompatibleVisionConfiguration,
    credential: String
  ) async throws -> ProviderScreenVisionResponse {
    callCount += 1
    batchFrameCounts.append(batch.frames.count)
    #expect((1...ScreenVisualTimelineBatch.maximumFrameCount).contains(batch.frames.count))
    lastTimeSliceDisplayCounts = batch.timeSlices.map { $0.frames.count }
    lastPriorSegmentApplications = batch.continuityContext.recentSegments.map(\.foregroundApplicationLabel)
    #expect(batch.frames.allSatisfy { $0.image.pixelWidth == 1_600 })
    #expect(batch.frames.allSatisfy { $0.redactedOCRLines.map(\.value) == ["func buildReport()"] })
    #expect(configuration.model == "vision-model")
    #expect(credential == "test-key")
    return ProviderScreenVisionResponse(
      requestID: "request-1",
      inference: try ScreenVisualInference(
        summary: "正在编辑 Swift 代码",
        interaction: "编辑器中显示源代码和插入光标",
        activityKind: .development,
        evidence: ["Swift 源码可见"],
        displayStates: try Array(Set(batch.frames.map(\.displayLabel))).sorted().enumerated().map {
          index, label in
          try .init(
            displayLabel: label,
            role: index == 0 ? .primary : .reference,
            visibleState: index == 0 ? "Xcode 源码编辑器可见" : "参考资料可见"
          )
        },
        relationship: .coordinated
      ),
      usage: ProviderReportedTokenUsage(totalTokens: 100)
    )
  }
}

private actor SegmentingVisionClient: ScreenVisionInferring {
  private(set) var callCount = 0

  func infer(
    batch: ScreenVisualTimelineBatch,
    configuration: OpenAICompatibleVisionConfiguration,
    credential: String
  ) async throws -> ProviderScreenVisionResponse {
    callCount += 1
    let label = batch.frames[0].displayLabel
    func inference(
      summary: String, activityKind: ScreenVisualActivityKind
    ) throws -> ScreenVisualInference {
      try ScreenVisualInference(
        summary: summary,
        interaction: "画面状态随时间变化",
        activityKind: activityKind,
        evidence: ["可见界面状态"],
        displayStates: [
          try .init(displayLabel: label, role: .primary, visibleState: summary)
        ],
        relationship: .coordinated
      )
    }
    return ProviderScreenVisionResponse(
      requestID: "segmented-request",
      segments: [
        .init(timeSliceRange: 0...1, inference: try inference(summary: "查阅资料", activityKind: .reading)),
        .init(timeSliceRange: 2...3, inference: try inference(summary: "编辑代码", activityKind: .development)),
      ],
      usage: ProviderReportedTokenUsage(totalTokens: 120)
    )
  }
}

private actor UnauthorizedThenSuccessfulVisionClient: ScreenVisionInferring {
  private(set) var callCount = 0

  func infer(
    batch: ScreenVisualTimelineBatch,
    configuration: OpenAICompatibleVisionConfiguration,
    credential: String
  ) async throws -> ProviderScreenVisionResponse {
    callCount += 1
    if callCount == 1 { throw ScreenVisionProviderError.unauthorized }
    return ProviderScreenVisionResponse(
      requestID: "recovered-request",
      inference: try ScreenVisualInference(
        summary: "连接恢复", interaction: "视觉推断重新开始", activityKind: .other,
        evidence: ["显式连接测试成功"],
        displayStates: [
          try .init(
            displayLabel: batch.frames[0].displayLabel,
            role: .primary,
            visibleState: "连接恢复后的工作画面"
          )
        ],
        relationship: .coordinated),
      usage: ProviderReportedTokenUsage(totalTokens: 10)
    )
  }
}

private actor CancellationObservingVisionClient: ScreenVisionInferring {
  private(set) var callCount = 0
  private(set) var sawCancelledTask = false

  func infer(
    batch: ScreenVisualTimelineBatch,
    configuration: OpenAICompatibleVisionConfiguration,
    credential: String
  ) async throws -> ProviderScreenVisionResponse {
    callCount += 1
    do {
      try await Task.sleep(for: .milliseconds(5))
    } catch {
      sawCancelledTask = true
      throw ScreenVisionProviderError.cancelled
    }
    if Task.isCancelled {
      sawCancelledTask = true
      throw ScreenVisionProviderError.cancelled
    }
    return try successfulVisionResponse(for: batch, requestID: "scheduled-flush")
  }
}

private actor RetryThenSuccessfulVisionClient: ScreenVisionInferring {
  private(set) var callCount = 0

  func infer(
    batch: ScreenVisualTimelineBatch,
    configuration: OpenAICompatibleVisionConfiguration,
    credential: String
  ) async throws -> ProviderScreenVisionResponse {
    callCount += 1
    if callCount == 1 { throw ScreenVisionProviderError.invalidResponse }
    return try successfulVisionResponse(for: batch, requestID: "retry-recovered")
  }
}

private actor AlwaysInvalidVisionClient: ScreenVisionInferring {
  private(set) var callCount = 0

  func infer(
    batch: ScreenVisualTimelineBatch,
    configuration: OpenAICompatibleVisionConfiguration,
    credential: String
  ) async throws -> ProviderScreenVisionResponse {
    callCount += 1
    throw ScreenVisionProviderError.invalidResponse
  }
}

private func successfulVisionResponse(
  for batch: ScreenVisualTimelineBatch,
  requestID: String
) throws -> ProviderScreenVisionResponse {
  ProviderScreenVisionResponse(
    requestID: requestID,
    inference: try ScreenVisualInference(
      summary: "视觉理解已恢复",
      interaction: "持续输入期间完成了待处理批次",
      activityKind: .development,
      evidence: ["可见工作画面"],
      displayStates: try Array(Set(batch.frames.map(\.displayLabel))).sorted().enumerated().map {
        index, label in
        try .init(
          displayLabel: label,
          role: index == 0 ? .primary : .reference,
          visibleState: "工作画面可见"
        )
      },
      relationship: .coordinated
    ),
    usage: ProviderReportedTokenUsage(totalTokens: 10)
  )
}

private actor VisionObservationRepository: VisibleContentArchiveRepository,
  ScreenVisionUsageRepository
{
  private(set) var observations: [VisibleContentObservation] = []
  private(set) var usage: [ScreenVisionUsageRecord] = []
  private let failsObservationInsert: Bool

  init(
    failsObservationInsert: Bool = false,
    usage: [ScreenVisionUsageRecord] = []
  ) {
    self.failsObservationInsert = failsObservationInsert
    self.usage = usage
  }

  func insert(_ observation: VisibleContentObservation) async throws -> DeepCaptureInsertResult {
    if failsObservationInsert { throw VisionObservationRepositoryError.insertionFailed }
    observations.append(observation)
    return .inserted
  }

  func fetchVisibleContent(observedIn range: Range<Date>) async throws
    -> [VisibleContentObservation]
  {
    observations.filter { range.contains($0.provenance.observedAt) }
  }

  func insert(_ record: ScreenVisionUsageRecord) async throws -> DeepCaptureInsertResult {
    usage.append(record)
    return .inserted
  }

  func screenVisionUsage(in range: Range<Date>) async throws -> ScreenVisionUsageSummary {
    ScreenVisionUsageSummary(
      callCount: usage.count, successCount: usage.filter({ $0.outcome == .success }).count,
      inputTokens: 0, outputTokens: 0, cachedInputTokens: 0,
      totalTokens: usage.compactMap(\.totalTokens).reduce(0, +), failuresByCategory: [:])
  }
}

private enum VisionObservationRepositoryError: Error {
  case insertionFailed
}
