import DaydayCore
import DaydayIntegrations
import Foundation
import Testing

@testable import DaydayApp

@Suite("Health archive transfer presentation")
@MainActor
struct HealthArchiveTransferPresentationTests {
  @Test("Mac presentation distinguishes waiting, receiving, persisted, and retry states")
  func transferStatesRemainObjectiveAndActionable() {
    #expect(HealthArchiveModel.TransferState.waitingForIPhone.metricTitle == "等待 iPhone")
    #expect(HealthArchiveModel.TransferState.receiving.metricTitle == "正在接收")
    #expect(
      HealthArchiveModel.TransferState.persisted(
        observationCount: 2_000, tombstoneCount: 3, at: .now
      ).metricTitle == "已写入")
    #expect(HealthArchiveModel.TransferState.incomplete.title.contains("保留待同步数据"))
    #expect(
      HealthArchiveModel.TransferState.waitingForIPhone.compactTitle(hasLocalArchive: true)
        == "档案已更新，iPhone 当前未连接"
    )
    #expect(
      HealthArchiveModel.TransferState.waitingForIPhone.compactTitle(hasLocalArchive: false)
        == "等待 iPhone"
    )
  }

  @Test("Initial failure fails normally without inventing a stale archive")
  func initialFailureRemainsAFullFailure() async throws {
    let repository = ScriptedHealthArchiveRepository([.failure])
    let model = HealthArchiveModel(
      pairingStore: EmptyHealthPairingStore(),
      prewarmingEnabled: false
    )
    model.configure(repository: repository)

    model.refresh(matching: try statisticsQuery())

    #expect(model.state == .loading)
    #expect(model.loadingState == .initialArchive)
    #expect(await eventually { model.state == .failed })
    #expect(model.dashboard == nil)
    #expect(model.refreshIssue == nil)
    #expect(model.loadingState == .idle)
  }

  @Test("Configuring the local archive prewarms the default dashboard before navigation")
  func configurationPrewarmsDefaultDashboard() async {
    let repository = ControlledHealthArchiveRepository()
    let model = HealthArchiveModel(pairingStore: EmptyHealthPairingStore())

    model.configure(repository: repository)

    #expect(await eventually { await repository.requestCount == 1 })
    model.loadIfNeeded()
    for _ in 0..<10 { await Task.yield() }
    #expect(await repository.requestCount == 1)
    let result = dashboard(
      archiveRevision: 1,
      observationCount: 120,
      latestBatchReceivedAt: Date(timeIntervalSince1970: 10)
    )
    await repository.resolveRequest(at: 0, with: result)
    #expect(await eventually { model.currentDashboard == result && model.state == .ready })
  }

  @Test("Refresh failure preserves the previous dashboard and a later success clears its issue")
  func refreshFailureKeepsLastSuccessfulDashboard() async throws {
    let first = dashboard(
      observationCount: 120,
      latestBatchReceivedAt: Date(timeIntervalSince1970: 10)
    )
    let replacement = dashboard(
      observationCount: 145,
      latestBatchReceivedAt: Date(timeIntervalSince1970: 20)
    )
    let repository = ScriptedHealthArchiveRepository([.value(first), .failure, .value(replacement)])
    let model = HealthArchiveModel(
      pairingStore: EmptyHealthPairingStore(),
      prewarmingEnabled: false
    )
    model.configure(repository: repository)
    let query = try statisticsQuery()

    model.refresh(matching: query)
    #expect(await eventually { model.dashboard == first && model.state == .ready })
    #expect(model.refreshIssue == nil)

    model.refresh(matching: query)
    #expect(model.state == .loading)
    #expect(model.loadingState == .refreshingExistingDashboard)
    #expect(await eventually { model.refreshIssue == .showingStaleDashboard })
    #expect(model.state == .ready)
    #expect(model.dashboard == first)
    #expect(model.refreshIssue?.title == "本机健康档案暂未刷新")
    #expect(model.refreshIssue?.detail.contains("上次成功读取的数据") == true)

    model.refresh(matching: query)
    #expect(model.loadingState == .refreshingExistingDashboard)
    #expect(await eventually { model.dashboard == replacement && model.state == .ready })
    #expect(model.refreshIssue == nil)
  }

  @Test("A failed filter change never relabels the previous dashboard")
  func failedFilterChangeDoesNotExposeMismatchedDashboard() async throws {
    let first = dashboard(
      observationCount: 120,
      latestBatchReceivedAt: Date(timeIntervalSince1970: 10)
    )
    let repository = ScriptedHealthArchiveRepository([.value(first), .failure])
    let model = HealthArchiveModel(
      pairingStore: EmptyHealthPairingStore(),
      prewarmingEnabled: false
    )
    model.configure(repository: repository)
    let allKinds = try statisticsQuery()
    let heartRate = try HealthArchiveStatisticsQuery(
      kinds: [.heartRate],
      startsAt: Date(timeIntervalSince1970: 30),
      endsAt: Date(timeIntervalSince1970: 90)
    )

    model.refresh(matching: allKinds)
    #expect(await eventually { model.currentDashboard == first && model.state == .ready })

    model.refresh(matching: heartRate)
    #expect(model.loadingState == .initialArchive)
    #expect(model.currentDashboard == nil)
    #expect(await eventually { model.state == .failed })
    #expect(model.dashboard == first)
    #expect(model.currentDashboard == nil)
    #expect(model.refreshIssue == nil)
  }

  @Test("Duplicate refreshes for the same scope coalesce into one database request")
  func duplicateRefreshesAreCoalesced() async throws {
    let repository = ControlledHealthArchiveRepository()
    let model = HealthArchiveModel(
      pairingStore: EmptyHealthPairingStore(),
      prewarmingEnabled: false
    )
    model.configure(repository: repository)
    let query = try statisticsQuery()
    let result = dashboard(
      observationCount: 145,
      latestBatchReceivedAt: Date(timeIntervalSince1970: 20)
    )

    model.refresh(matching: query)
    #expect(await eventually { await repository.requestCount == 1 })
    model.refresh(matching: query)
    for _ in 0..<10 { await Task.yield() }
    #expect(await repository.requestCount == 1)
    await repository.resolveRequest(at: 0, with: result)
    #expect(await eventually { model.dashboard == result && model.state == .ready })

    #expect(model.currentDashboard == result)
    #expect(model.refreshIssue == nil)
  }

  @Test("An explicit same-day refresh paints cached content before background revalidation")
  func explicitSameDayRefreshUsesSemanticCache() async throws {
    let repository = ControlledHealthArchiveRepository()
    let model = HealthArchiveModel(
      pairingStore: EmptyHealthPairingStore(),
      prewarmingEnabled: false
    )
    model.configure(repository: repository)
    let firstQuery = try statisticsQuery()
    let first = dashboard(
      archiveRevision: 1,
      observationCount: 120,
      latestBatchReceivedAt: Date(timeIntervalSince1970: 10)
    )
    model.refresh(matching: firstQuery)
    #expect(await eventually { await repository.requestCount == 1 })
    await repository.resolveRequest(at: 0, with: first)
    #expect(await eventually { model.currentDashboard == first && model.state == .ready })

    let laterSameDay = try HealthArchiveStatisticsQuery(
      startsAt: firstQuery.startsAt,
      endsAt: firstQuery.endsAt.addingTimeInterval(30),
      recentSyncLimit: firstQuery.recentSyncLimit
    )
    let clock = ContinuousClock()
    let cachedPaintStarted = clock.now
    model.refresh(matching: laterSameDay)
    let cachedPaintElapsed = cachedPaintStarted.duration(to: clock.now)

    #expect(model.currentDashboard == first)
    #expect(model.loadingState == .refreshingExistingDashboard)
    #expect(cachedPaintElapsed < .milliseconds(100))
    #expect(await eventually { await repository.requestCount == 2 })

    let replacement = dashboard(
      archiveRevision: 2,
      observationCount: 145,
      latestBatchReceivedAt: Date(timeIntervalSince1970: 20)
    )
    await repository.resolveRequest(at: 1, with: replacement)
    #expect(await eventually { model.currentDashboard == replacement && model.state == .ready })
  }

  @Test("Navigation re-entry reuses the dashboard without another archive scan")
  func navigationReentryDoesNotRevalidateCachedDashboard() async throws {
    let repository = ControlledHealthArchiveRepository()
    let model = HealthArchiveModel(
      pairingStore: EmptyHealthPairingStore(),
      prewarmingEnabled: false
    )
    model.configure(repository: repository)
    let firstQuery = try statisticsQuery()
    let first = dashboard(
      archiveRevision: 1,
      observationCount: 120,
      latestBatchReceivedAt: Date(timeIntervalSince1970: 10)
    )

    model.refresh(matching: firstQuery)
    #expect(await eventually { await repository.requestCount == 1 })
    await repository.resolveRequest(at: 0, with: first)
    #expect(await eventually { model.currentDashboard == first && model.state == .ready })

    let laterSameDay = try HealthArchiveStatisticsQuery(
      startsAt: firstQuery.startsAt,
      endsAt: firstQuery.endsAt.addingTimeInterval(30),
      recentSyncLimit: firstQuery.recentSyncLimit
    )
    model.loadIfNeeded(matching: laterSameDay)
    for _ in 0..<10 { await Task.yield() }

    #expect(model.currentDashboard == first)
    #expect(model.loadingState == .idle)
    #expect(await repository.requestCount == 1)
  }

  @Test("Same-day queries with different start times do not reuse an incompatible cache entry")
  func differentStartTimesDoNotShareSemanticCache() async throws {
    let repository = ControlledHealthArchiveRepository()
    let model = HealthArchiveModel(
      pairingStore: EmptyHealthPairingStore(),
      prewarmingEnabled: false
    )
    model.configure(repository: repository)
    let firstQuery = try statisticsQuery()
    let first = dashboard(
      archiveRevision: 1,
      observationCount: 120,
      latestBatchReceivedAt: Date(timeIntervalSince1970: 10)
    )
    model.refresh(matching: firstQuery)
    #expect(await eventually { await repository.requestCount == 1 })
    await repository.resolveRequest(at: 0, with: first)
    #expect(await eventually { model.currentDashboard == first && model.state == .ready })

    let shiftedStart = try HealthArchiveStatisticsQuery(
      startsAt: firstQuery.startsAt.addingTimeInterval(60),
      endsAt: firstQuery.endsAt,
      recentSyncLimit: firstQuery.recentSyncLimit
    )
    model.refresh(matching: shiftedStart)

    #expect(model.currentDashboard == nil)
    #expect(model.loadingState == .initialArchive)
    #expect(await eventually { await repository.requestCount == 2 })

    let replacement = dashboard(
      archiveRevision: 1,
      observationCount: 119,
      latestBatchReceivedAt: Date(timeIntervalSince1970: 10)
    )
    await repository.resolveRequest(at: 1, with: replacement)
    #expect(await eventually { model.currentDashboard == replacement && model.state == .ready })
  }

  @Test("A completed sync advances the rolling chart window without changing its day count")
  func completedSyncAdvancesRollingWindow() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
    let oldStart = try #require(
      calendar.date(
        from: DateComponents(
          year: 2026, month: 7, day: 11
        )))
    let oldEnd = try #require(
      calendar.date(
        from: DateComponents(
          year: 2026, month: 8, day: 9, hour: 9
        )))
    let newEnd = try #require(
      calendar.date(
        from: DateComponents(
          year: 2026, month: 8, day: 10, hour: 10
        )))
    let query = try HealthArchiveStatisticsQuery(
      kinds: [.heartRate],
      startsAt: oldStart,
      endsAt: oldEnd,
      recentSyncLimit: 5
    )

    let advanced = try #require(
      HealthArchiveModel.rollingQuery(
        advancing: query,
        to: newEnd,
        calendar: calendar
      ))

    #expect(
      advanced.startsAt
        == calendar.date(
          from: DateComponents(
            year: 2026, month: 7, day: 12
          )))
    #expect(advanced.endsAt == newEnd)
    #expect(advanced.kinds == [.heartRate])
    #expect(advanced.recentSyncLimit == 5)
  }

  @Test("Rolling window follows local calendar days across daylight saving changes")
  func rollingWindowUsesCalendarDaysAcrossDST() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
    let oldStart = try #require(
      calendar.date(from: DateComponents(year: 2026, month: 3, day: 1)))
    let oldEnd = try #require(
      calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 12)))
    let newEnd = try #require(
      calendar.date(from: DateComponents(year: 2026, month: 3, day: 9, hour: 12)))
    let query = try HealthArchiveStatisticsQuery(
      startsAt: oldStart,
      endsAt: oldEnd
    )

    let advanced = try #require(
      HealthArchiveModel.rollingQuery(
        advancing: query,
        to: newEnd,
        calendar: calendar
      ))

    #expect(
      advanced.startsAt
        == calendar.date(from: DateComponents(year: 2026, month: 3, day: 2)))
    #expect(advanced.endsAt == newEnd)
    #expect(
      calendar.dateComponents(
        [.day],
        from: calendar.startOfDay(for: advanced.startsAt),
        to: calendar.startOfDay(for: advanced.endsAt)
      ).day == 7
    )
  }

  @Test("Hover inspection resolves and caches the nearest exact quantity sample")
  func exactHoverSampleUsesBoundedCache() async throws {
    let sourceID = UUID()
    let source = try HealthObservationSource(
      name: "Apple Watch",
      bundleIdentifier: "com.apple.health.watch"
    )
    let observations = try [
      HealthObservation(
        key: .init(sourceInstallationID: sourceID, healthKitUUID: UUID()),
        kind: .heartRate,
        startedAt: Date(timeIntervalSinceReferenceDate: 115),
        endedAt: Date(timeIntervalSinceReferenceDate: 120),
        source: source,
        payload: HealthObservationPayload(quantityValue: 68, unit: "count/min"),
        receivedAt: Date(timeIntervalSinceReferenceDate: 121)
      ),
      HealthObservation(
        key: .init(sourceInstallationID: sourceID, healthKitUUID: UUID()),
        kind: .heartRate,
        startedAt: Date(timeIntervalSinceReferenceDate: 235),
        endedAt: Date(timeIntervalSinceReferenceDate: 240),
        source: source,
        payload: HealthObservationPayload(quantityValue: 73, unit: "count/min"),
        receivedAt: Date(timeIntervalSinceReferenceDate: 241)
      ),
    ]
    let repository = HoverSampleHealthArchiveRepository(observations: observations)
    let model = HealthArchiveModel(
      pairingStore: EmptyHealthPairingStore(),
      prewarmingEnabled: false
    )
    model.configure(repository: repository)
    let aggregate = HealthMetricPoint(
      startedAt: Date(timeIntervalSinceReferenceDate: 0),
      endedAt: Date(timeIntervalSinceReferenceDate: 300),
      value: 70.5,
      contributingSampleCount: 2
    )

    let first = await model.exactQuantitySample(kind: .heartRate, near: aggregate)
    let second = await model.exactQuantitySample(kind: .heartRate, near: aggregate)

    #expect(
      first
        == HealthMetricExactSample(
          measuredAt: Date(timeIntervalSinceReferenceDate: 120),
          value: 68
        ))
    #expect(second == first)
    #expect(await repository.observationRequestCount == 1)
  }

  private func statisticsQuery() throws -> HealthArchiveStatisticsQuery {
    try HealthArchiveStatisticsQuery(
      startsAt: Date(timeIntervalSince1970: 0),
      endsAt: Date(timeIntervalSince1970: 60)
    )
  }

  private func dashboard(
    archiveRevision: UInt64 = 0,
    observationCount: Int,
    latestBatchReceivedAt: Date
  ) -> HealthArchiveDashboard {
    HealthArchiveDashboard(
      archiveRevision: archiveRevision,
      summary: HealthArchiveSummary(
        observationCount: observationCount,
        coveredKindCount: 1,
        sourceInstallationCount: 1,
        receivedBatchCount: 1,
        earliestEndedAt: Date(timeIntervalSince1970: 1),
        latestEndedAt: Date(timeIntervalSince1970: 2),
        latestBatchReceivedAt: latestBatchReceivedAt
      ),
      coverage: [],
      recentSyncs: [],
      dailyCounts: []
    )
  }

  private func eventually(_ condition: @MainActor () async -> Bool) async -> Bool {
    for _ in 0..<100 {
      if await condition() { return true }
      await Task.yield()
    }
    return await condition()
  }
}

private struct EmptyHealthPairingStore: AppHealthPairingCredentialStoring {
  func load() throws -> HealthPairingCredential? { nil }
  func save(_: HealthPairingCredential) throws {}
  func remove() throws {}
}

private actor ScriptedHealthArchiveRepository: HealthArchiveRepository {
  enum DashboardResponse: Sendable {
    case value(HealthArchiveDashboard)
    case failure
  }

  enum Failure: Error { case requested }

  private var dashboardResponses: [DashboardResponse]

  init(_ dashboardResponses: [DashboardResponse]) {
    self.dashboardResponses = dashboardResponses
  }

  func dashboard(matching _: HealthArchiveStatisticsQuery) async throws -> HealthArchiveDashboard {
    guard !dashboardResponses.isEmpty else { throw Failure.requested }
    switch dashboardResponses.removeFirst() {
    case .value(let dashboard): return dashboard
    case .failure: throw Failure.requested
    }
  }

  func apply(_: HealthArchiveBatch) async throws -> HealthArchiveApplyResult { fatalError() }
  func observations(matching _: HealthArchiveQuery) async throws -> [HealthObservation] {
    fatalError()
  }
  func coverage() async throws -> [HealthObservationCoverage] { fatalError() }
  func delete(_: HealthArchiveDeletionRequest) async throws -> HealthArchiveDeletionResult {
    fatalError()
  }
  func export(matching _: HealthArchiveQuery, exportedAt _: Date) async throws
    -> HealthArchiveExport
  { fatalError() }
}

private actor ControlledHealthArchiveRepository: HealthArchiveRepository {
  private var requests: [CheckedContinuation<HealthArchiveDashboard, any Error>] = []

  var requestCount: Int { requests.count }

  func resolveRequest(at index: Int, with dashboard: HealthArchiveDashboard) {
    requests[index].resume(returning: dashboard)
  }

  func dashboard(matching _: HealthArchiveStatisticsQuery) async throws -> HealthArchiveDashboard {
    try await withCheckedThrowingContinuation { continuation in
      requests.append(continuation)
    }
  }

  func apply(_: HealthArchiveBatch) async throws -> HealthArchiveApplyResult { fatalError() }
  func observations(matching _: HealthArchiveQuery) async throws -> [HealthObservation] {
    fatalError()
  }
  func coverage() async throws -> [HealthObservationCoverage] { fatalError() }
  func delete(_: HealthArchiveDeletionRequest) async throws -> HealthArchiveDeletionResult {
    fatalError()
  }
  func export(matching _: HealthArchiveQuery, exportedAt _: Date) async throws
    -> HealthArchiveExport
  { fatalError() }
}

private actor HoverSampleHealthArchiveRepository: HealthArchiveRepository {
  let observations: [HealthObservation]
  private(set) var observationRequestCount = 0

  init(observations: [HealthObservation]) {
    self.observations = observations
  }

  func observations(matching _: HealthArchiveQuery) async throws -> [HealthObservation] {
    observationRequestCount += 1
    return observations
  }

  func dashboard(matching _: HealthArchiveStatisticsQuery) async throws -> HealthArchiveDashboard {
    fatalError()
  }
  func apply(_: HealthArchiveBatch) async throws -> HealthArchiveApplyResult { fatalError() }
  func coverage() async throws -> [HealthObservationCoverage] { fatalError() }
  func delete(_: HealthArchiveDeletionRequest) async throws -> HealthArchiveDeletionResult {
    fatalError()
  }
  func export(matching _: HealthArchiveQuery, exportedAt _: Date) async throws
    -> HealthArchiveExport
  { fatalError() }
}
