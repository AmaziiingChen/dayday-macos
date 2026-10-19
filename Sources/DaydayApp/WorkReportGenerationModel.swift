import DaydayAI
import DaydayCore
import DaydayUnderstanding
import Foundation

@MainActor
final class WorkReportGenerationModel: ObservableObject {
  @Published private(set) var draft: String?
  @Published private(set) var currentRecord: PersistedWorkReportRecord?
  @Published private(set) var generatedAt: Date?
  @Published private(set) var usage: ProviderReportedTokenUsage?
  @Published private(set) var isGenerating = false
  @Published private(set) var isSavingEdit = false
  @Published private(set) var isReady = false
  @Published private(set) var status = "正在等待本地工作数据"
  @Published private(set) var recentReports: [PersistedWorkReportRecord] = []
  @Published private(set) var historyStatus = "正在等待本地报告仓库"
  @Published private(set) var isFinalized = false
  @Published private(set) var isFinalizing = false
  @Published private(set) var revisions: [WorkReportRevision] = []
  @Published private(set) var usageSummary: WorkReportTokenSummary = .empty
  @Published private(set) var monthlyUsageSummary: WorkReportTokenSummary = .empty
  @Published private(set) var workingDraft: String?
  @Published private(set) var workingDraftStatus: String?
  @Published private(set) var workingDraftSaveFailed = false
  @Published private(set) var requestPreview: WorkReportRequestPreview?
  @Published private(set) var requestPreviewStatus = "尚未生成请求预览"
  @Published private(set) var evidenceCoverage = WorkReportEvidenceCoverage.empty
  @Published private(set) var workNoteAdvisory: String?
  @Published private(set) var hasPendingSourceUpdates = false
  @Published private(set) var submittedContextUTF8Bytes = 0

  private let providerSettings: ProviderSettingsModel
  private let generator: any WorkReportGenerating
  private let workingDraftPersistence: any WorkReportWorkingDraftPersisting
  private let workingDraftSaveDelay: Duration
  private var pipeline: ObjectiveUnderstandingPipeline?
  private var objectiveRepository: (any ObjectiveLinkedRecordRepository)?
  private var reportRepository: (any WorkReportRepository)?
  private var visualInferenceRepository: (any VisibleContentArchiveRepository)?
  private var understandingDerivationRepository: (any UnderstandingDerivationRepository)?
  private var budget = WorkReportTokenBudget.unlimited
  private var writingPreferences = WorkReportWritingPreferences.standard
  private var dailySchedule = DailyWorkSchedule.standard
  private var pendingWorkingDraftSave: Task<Void, Never>?
  private var pendingWorkingDraftSnapshot: WorkReportWorkingDraftSnapshot?
  private var workingDraftMutationGeneration = 0

  init(
    providerSettings: ProviderSettingsModel,
    generator: any WorkReportGenerating = OpenAICompatibleWorkReportClient(),
    writingPreferences: WorkReportWritingPreferences = .standard,
    workingDraftPersistence: any WorkReportWorkingDraftPersisting =
      VolatileWorkReportWorkingDraftStore(),
    workingDraftSaveDelay: Duration = .milliseconds(350)
  ) {
    self.providerSettings = providerSettings
    self.generator = generator
    self.writingPreferences = writingPreferences
    self.workingDraftPersistence = workingDraftPersistence
    self.workingDraftSaveDelay = workingDraftSaveDelay
  }

  deinit {
    pendingWorkingDraftSave?.cancel()
  }

  func configure(
    repository: any ObjectiveLinkedRecordRepository,
    reportRepository: any WorkReportRepository,
    visualInferenceRepository: (any VisibleContentArchiveRepository)? = nil,
    understandingDerivationRepository: (any UnderstandingDerivationRepository)? = nil,
    budget: WorkReportTokenBudget = .unlimited,
    writingPreferences: WorkReportWritingPreferences? = nil,
    dailySchedule: DailyWorkSchedule? = nil
  ) {
    pipeline = ObjectiveUnderstandingPipeline(repository: repository)
    objectiveRepository = repository
    self.reportRepository = reportRepository
    self.visualInferenceRepository = visualInferenceRepository
    self.understandingDerivationRepository = understandingDerivationRepository
    self.budget = budget
    if let writingPreferences {
      self.writingPreferences = writingPreferences
    }
    if let dailySchedule {
      self.dailySchedule = dailySchedule
    }
    isReady = true
    status = "可以根据今天的本地工作事实生成草稿"
    Task {
      await restoreCurrentReport()
      await refreshHistory()
      await refreshEvidenceCoverage()
    }
  }

  func updateGenerationSettings(
    budget: WorkReportTokenBudget,
    writingPreferences: WorkReportWritingPreferences
  ) {
    self.budget = budget
    self.writingPreferences = writingPreferences
  }

  func updateDailySchedule(_ schedule: DailyWorkSchedule, now: Date = .now) {
    let boundaryChanged = dailySchedule.logicalDayBoundaryHour != schedule.logicalDayBoundaryHour
    let preservedWorkingDraft = boundaryChanged ? workingDraft : nil
    dailySchedule = schedule
    guard boundaryChanged else { return }

    if preservedWorkingDraft != nil {
      clearWorkingDraftStorage(force: true)
    }
    draft = nil
    currentRecord = nil
    generatedAt = nil
    usage = nil
    isFinalized = false
    revisions = []
    requestPreview = nil
    requestPreviewStatus = "工作日起点已改变；请刷新请求预览"
    status = "正在按新的工作日起点读取本机日报"
    if let preservedWorkingDraft {
      stageWorkingDraft(preservedWorkingDraft, now: now, flush: true)
    }
    Task {
      await restoreCurrentReport(now: now)
      await refreshUsageStatistics(now: now)
    }
  }

  func dayDescriptor(at date: Date = .now) -> DayDescriptor? {
    try? currentDay(at: date)
  }

  /// Stages the exact editor body outside immutable report history. This is the ordinary
  /// autosave path; an explicit save or finalization remains the boundary that creates a revision.
  func stageWorkingDraft(_ body: String, now: Date = .now, flush: Bool = false) {
    guard isReady, !isFinalized else { return }
    if body == (draft ?? "") {
      clearWorkingDraftStorage()
      return
    }

    let day: DayDescriptor
    let snapshot: WorkReportWorkingDraftSnapshot
    do {
      day = try currentDay(at: now)
      snapshot = try WorkReportWorkingDraftSnapshot(
        dayID: day.id,
        baseRevisionID: currentRecord?.currentRevision.id,
        body: body,
        updatedAt: now
      )
    } catch {
      workingDraftSaveFailed = true
      workingDraftStatus = "自动保存失败；正文过长或日期无效"
      return
    }

    let changed = workingDraft != body || pendingWorkingDraftSnapshot == nil
    workingDraftMutationGeneration &+= 1
    workingDraft = body
    pendingWorkingDraftSnapshot = snapshot
    workingDraftSaveFailed = false
    if flush {
      workingDraftStatus = "正在自动保存…"
      flushPendingWorkingDraftSave()
    } else if changed {
      workingDraftStatus = "正在自动保存…"
      scheduleWorkingDraftSave()
    }
  }

  func flushPendingWorkingDraftSave() {
    pendingWorkingDraftSave?.cancel()
    pendingWorkingDraftSave = nil
    persistPendingWorkingDraft()
  }

  func discardWorkingDraft() {
    clearWorkingDraftStorage()
  }

  private func scheduleWorkingDraftSave() {
    pendingWorkingDraftSave?.cancel()
    let delay = workingDraftSaveDelay
    pendingWorkingDraftSave = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(for: delay)
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      self?.persistPendingWorkingDraft()
    }
  }

  private func persistPendingWorkingDraft() {
    pendingWorkingDraftSave = nil
    guard let snapshot = pendingWorkingDraftSnapshot else { return }
    do {
      try workingDraftPersistence.save(snapshot)
      workingDraftSaveFailed = false
      workingDraftStatus = "已自动保存到本机"
    } catch {
      workingDraftSaveFailed = true
      workingDraftStatus = "自动保存失败；当前文字仍保留在编辑器中"
    }
  }

  private func restoreWorkingDraft(
    for day: DayDescriptor,
    currentRecord: PersistedWorkReportRecord?
  ) {
    do {
      guard let snapshot = try workingDraftPersistence.load() else {
        workingDraft = nil
        workingDraftStatus = nil
        workingDraftSaveFailed = false
        return
      }
      let isCurrentWorkingCopy = snapshot.dayID == day.id
        && snapshot.baseRevisionID == currentRecord?.currentRevision.id
        && currentRecord?.report.status != .final
      guard isCurrentWorkingCopy else {
        clearWorkingDraftStorage(force: true)
        return
      }
      workingDraft = snapshot.body
      pendingWorkingDraftSnapshot = nil
      workingDraftSaveFailed = false
      workingDraftStatus = "已恢复自动保存的修改"
    } catch {
      workingDraft = nil
      pendingWorkingDraftSnapshot = nil
      workingDraftSaveFailed = true
      workingDraftStatus = "无法读取自动保存的日报修改"
    }
  }

  private func clearWorkingDraftStorage(force: Bool = false) {
    guard force || workingDraft != nil || pendingWorkingDraftSnapshot != nil
      || workingDraftStatus != nil
    else { return }
    workingDraftMutationGeneration &+= 1
    pendingWorkingDraftSave?.cancel()
    pendingWorkingDraftSave = nil
    pendingWorkingDraftSnapshot = nil
    workingDraft = nil
    do {
      try workingDraftPersistence.save(nil)
      workingDraftSaveFailed = false
      workingDraftStatus = nil
    } catch {
      workingDraftSaveFailed = true
      workingDraftStatus = "无法清理旧的自动保存副本"
    }
  }

  func restoreCurrentReport(now: Date = .now) async {
    guard let reportRepository else { return }
    let observedWorkingDraftGeneration = workingDraftMutationGeneration
    do {
      let day = try currentDay(at: now)
      let record = try await reportRepository.report(for: day.id)
      if let record {
        draft = record.currentRevision.body
        currentRecord = record
        generatedAt = record.report.updatedAt
        isFinalized = record.report.status == .final
        usage = record.modelUsage.map {
          ProviderReportedTokenUsage(
            promptTokens: $0.inputTokens,
            completionTokens: $0.outputTokens,
            totalTokens: $0.totalTokens,
            cachedTokens: $0.cachedInputTokens
          )
        }
        await refreshRevisions(now: now)
        status = record.report.status == .final
          ? "已恢复今天保存在本机的定稿"
          : "已恢复今天保存在本机的第 \(record.report.currentRevisionNumber) 版草稿"
      }
      if observedWorkingDraftGeneration == workingDraftMutationGeneration {
        restoreWorkingDraft(for: day, currentRecord: record)
      }
    } catch {
      status = "读取今天保存在本机的日报失败"
    }
  }

  func refreshHistory() async {
    guard let reportRepository else {
      historyStatus = "本地报告仓库尚未就绪"
      return
    }
    do {
      // A 26-week daily heatmap needs up to 182 occupied days. Keep a small margin without
      // turning the sidebar into an unbounded archive read.
      recentReports = try await reportRepository.recentReports(limit: 200)
      historyStatus = recentReports.isEmpty ? "还没有已保存的工作日报" : "已读取本机历史日报"
    } catch {
      historyStatus = "读取本机历史日报失败"
    }
  }

  func refreshEvidenceCoverage(now: Date = .now) async {
    guard let day = try? currentDay(at: now) else { return }
    let range = day.boundary.startsAt..<min(now, day.boundary.endsAt)
    guard range.lowerBound < range.upperBound else {
      evidenceCoverage = .empty
      return
    }
    let observations = await Self.fetchVisibleContent(
      from: visualInferenceRepository,
      in: range
    )
    if let snapshot = try? WorkReportPipelinePolicy.visualSnapshot(
      from: observations,
      in: range
    ) {
      evidenceCoverage = snapshot.coverage
    }
  }

  func generate(
    workNote: String,
    weatherSnapshot: WeatherSnapshot? = nil,
    now: Date = .now
  ) async {
    guard !isGenerating else { return }
    guard let pipeline, let reportRepository else {
      status = "本地工作数据尚未就绪"
      return
    }
    guard !isFinalized else {
      status = "今日工作日报已定稿，不自动重新生成"
      return
    }

    let providerRequest:
      (
        configuration: OpenAICompatibleProviderConfiguration, credential: String
      )
    do {
      let configured = try providerSettings.generationRequest()
      providerRequest = (
        configured.configuration.optimizedForWorkReport,
        configured.credential
      )
    } catch ProviderSettingsModel.AccessError.missingCredential {
      status = "请先在设置中保存 DeepSeek API Key"
      return
    } catch {
      status = "模型设置无效，请先检查设置"
      return
    }

    let violation = await budgetViolation(now: now)
    if violation != .none {
      status = Self.budgetMessage(for: violation)
      return
    }

    isGenerating = true
    status = "正在理解今天的本地工作事实…"
    defer { isGenerating = false }

    do {
      let day = try currentDay(at: now)
      let prepared = try await prepareGenerationInput(
        pipeline: pipeline,
        day: day,
        workNote: workNote,
        weatherSnapshot: weatherSnapshot,
        now: now
      )
      let context = prepared.context
      evidenceCoverage = prepared.coverage
      workNoteAdvisory = WorkReportPipelinePolicy.workNoteAdvisory(for: workNote)
      guard !prepared.coverage.blocksGeneration else {
        status = prepared.coverage.blockingStatusText
        return
      }
      guard !context.activities.isEmpty || !context.objectiveApplicationSegments.isEmpty
        || !context.visualSegments.isEmpty || !context.workNotes.isEmpty
      else {
        status = "今天还没有可用于日报的工作事实或笔记"
        return
      }

      requestPreview = try OpenAICompatibleWorkReportClient.preview(
        context: context,
        configuration: providerRequest.configuration,
        writingPreferences: writingPreferences
      )
      requestPreviewStatus = "这是本次实际提交的请求；仅保留在当前应用内存中"
      submittedContextUTF8Bytes = requestPreview?.contextJSON.utf8.count ?? 0
      status = "正在生成自由形式工作日报…"
      let providerStartedAt = Date.now
      let response = try await generator.generate(
        context: context,
        configuration: providerRequest.configuration,
        credential: providerRequest.credential,
        writingPreferences: writingPreferences
      )
      let providerCompletedAt = Date.now
      status = "正在保存日报与模型用量…"
      let existing = try await reportRepository.report(for: day.id)
      let record = try Self.makePersistedRecord(
        day: day,
        existing: existing,
        content: response.content,
        sourceReferences: context.sourceReferences,
        response: response,
        configuration: providerRequest.configuration,
        generatedAt: now,
        providerStartedAt: providerStartedAt,
        providerCompletedAt: providerCompletedAt
      )
      if let generationRepository = reportRepository as? any WorkReportGenerationRepository {
        _ = try await generationRepository.saveGenerated(record, sources: prepared.sources)
      } else {
        _ = try await reportRepository.save(record)
      }
      draft = record.currentRevision.body
      currentRecord = record
      generatedAt = record.report.updatedAt
      usage = response.usage
      hasPendingSourceUpdates = false
      clearWorkingDraftStorage()
      await refreshHistory()
      status = "已保存到本机历史；这是可继续修改的 AI 草稿 · \(prepared.coverage.statusText)"
    } catch is CancellationError {
      status = "日报生成已取消"
    } catch WorkReportProviderError.cancelled {
      status = "日报生成已取消"
    } catch WorkReportProviderError.unauthorized {
      status = "DeepSeek 认证失败，请检查 API Key"
    } catch WorkReportProviderError.rateLimited {
      status = "DeepSeek 请求受限，请稍后重试"
    } catch WorkReportProviderError.configuredModelUnavailable {
      status = "当前模型不可用，请检查设置"
    } catch WorkReportGenerationError.derivationStorage {
      status = "本地理解数据存储失败；未调用模型"
    } catch {
      status = "日报生成失败；本地工作数据没有丢失"
    }
  }

  func refreshRequestPreview(
    workNote: String,
    weatherSnapshot: WeatherSnapshot? = nil,
    now: Date = .now
  ) async {
    guard let pipeline else {
      requestPreview = nil
      requestPreviewStatus = "本地工作数据尚未就绪"
      return
    }
    do {
      let configuration = try providerSettings.configurationForPreview().optimizedForWorkReport
      let day = try currentDay(at: now)
      let prepared = try await prepareGenerationInput(
        pipeline: pipeline,
        day: day,
        workNote: workNote,
        weatherSnapshot: weatherSnapshot,
        now: now
      )
      requestPreview = try OpenAICompatibleWorkReportClient.preview(
        context: prepared.context,
        configuration: configuration,
        writingPreferences: writingPreferences
      )
      evidenceCoverage = prepared.coverage
      workNoteAdvisory = WorkReportPipelinePolicy.workNoteAdvisory(for: workNote)
      submittedContextUTF8Bytes = requestPreview?.contextJSON.utf8.count ?? 0
      requestPreviewStatus = "已生成当前工作日的本机请求预览；未调用模型，也未保存预览"
    } catch {
      requestPreview = nil
      requestPreviewStatus = "无法生成请求预览；请检查模型配置和本地工作数据"
    }
  }

  private func prepareGenerationInput(
    pipeline: ObjectiveUnderstandingPipeline,
    day: DayDescriptor,
    workNote: String,
    weatherSnapshot: WeatherSnapshot?,
    now: Date
  ) async throws -> (
    context: WorkReportContext,
    sources: WorkReportGenerationSources,
    coverage: WorkReportEvidenceCoverage
  ) {
    let derived = try await durableWorkReportContext(
      pipeline: pipeline,
      day: day,
      now: now
    )
    let visibleRange = day.boundary.startsAt..<min(now, day.boundary.endsAt)
    let observations = await Self.fetchVisibleContent(
      from: visualInferenceRepository,
      in: visibleRange
    )
    let visual = try WorkReportPipelinePolicy.visualSnapshot(
      from: observations,
      in: visibleRange
    )
    let objectiveApplicationSegments = WorkReportPipelinePolicy.objectiveApplicationSegments(
      try await pipeline.objectiveApplicationSegments(day: day, asOf: now)
    )
    let trimmedNote = workNote.trimmingCharacters(in: .whitespacesAndNewlines)
    let persistedNotes: [PersistedWorkReportNote] = trimmedNote.isEmpty
      ? []
      : [
        try PersistedWorkReportNote(
          dayID: derived.day.id,
          createdAt: now,
          body: trimmedNote
        )
      ]
    let weather = weatherSnapshot.map { [$0] } ?? []
    let context = try WorkReportContext(
      day: derived.day,
      activities: derived.activities,
      objectiveApplicationSegments: objectiveApplicationSegments,
      visualSegments: visual.segments,
      workNotes: persistedNotes.map(\.context),
      weatherSnapshots: weather
    )
    return (
      context,
      WorkReportGenerationSources(
        workNotes: persistedNotes,
        weatherSnapshots: weather
      ),
      visual.coverage
    )
  }

  private func durableWorkReportContext(
    pipeline: ObjectiveUnderstandingPipeline,
    day: DayDescriptor,
    now: Date
  ) async throws -> WorkReportContext {
    guard let understandingDerivationRepository else {
      let snapshot = try await pipeline.derive(day: day, asOf: now)
      guard snapshot.sessions.isEmpty && snapshot.activities.isEmpty else {
        throw WorkReportGenerationError.derivationStorage
      }
      return try pipeline.workReportContext(day: day, snapshot: snapshot)
    }

    for _ in 0..<3 {
      try Task.checkCancellation()
      let previous: PersistedUnderstandingDerivation?
      do {
        previous = try await understandingDerivationRepository.latest(for: day)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        throw WorkReportGenerationError.derivationStorage
      }
      let revision: UInt64
      if let previous {
        guard previous.revision < UInt64.max else {
          throw WorkReportGenerationError.derivationStorage
        }
        revision = previous.revision + 1
      } else {
        revision = 1
      }
      let snapshot = try await pipeline.derive(
        day: day,
        asOf: now,
        derivationRevision: revision,
        previousSnapshot: previous.map {
          ObjectiveUnderstandingSnapshot(sessions: $0.sessions, activities: $0.activities)
        }
      )
      guard !snapshot.sessions.isEmpty || !snapshot.activities.isEmpty else {
        return try pipeline.workReportContext(day: day, snapshot: snapshot)
      }
      let candidate: PersistedUnderstandingDerivation
      do {
        candidate = try PersistedUnderstandingDerivation(
          sessionBatch: SessionDerivationBatch(
            day: day, derivationRevision: revision, sessions: snapshot.sessions),
          activityBatch: ActivityDerivationBatch(
            day: day, derivationRevision: revision, activities: snapshot.activities)
        )
      } catch {
        throw WorkReportGenerationError.derivationStorage
      }
      do {
        switch try await understandingDerivationRepository.saveAtomically(candidate) {
        case .inserted, .alreadyPresent:
          let accepted: PersistedUnderstandingDerivation?
          do {
            accepted = try await understandingDerivationRepository.latest(for: day)
          } catch is CancellationError {
            throw CancellationError()
          } catch {
            throw WorkReportGenerationError.derivationStorage
          }
          guard let accepted else {
            throw WorkReportGenerationError.derivationStorage
          }
          return try pipeline.workReportContext(
            day: day,
            snapshot: ObjectiveUnderstandingSnapshot(
              sessions: accepted.sessions,
              activities: accepted.activities
            )
          )
        case .conflict:
          continue
        }
      } catch is CancellationError {
        throw CancellationError()
      } catch WorkReportGenerationError.derivationStorage {
        throw WorkReportGenerationError.derivationStorage
      } catch {
        throw WorkReportGenerationError.derivationStorage
      }
    }
    throw WorkReportGenerationError.derivationStorage
  }

  private static func fetchVisibleContent(
    from repository: (any VisibleContentArchiveRepository)?,
    in range: Range<Date>
  ) async -> [VisibleContentObservation] {
    guard let repository, range.lowerBound < range.upperBound else { return [] }
    return (try? await repository.fetchVisibleContent(observedIn: range)) ?? []
  }

  static func enrichActivities(
    _ activities: [WorkReportActivityContext],
    with digests: [VisualInferenceDigest]
  ) throws -> [WorkReportActivityContext] {
    try activities.map { activity in
      let relevant = digests.filter {
        $0.startedAt < activity.endedAt
          && ($0.endedAt ?? $0.startedAt) >= activity.startedAt
      }
      let inferenceSummary = relevant.prefix(6).map(\.reportSummary).joined(separator: "\n")
      let visualObservationIDs = relevant.prefix(6).flatMap(\.observationIDs)
      let parts = [activity.summary, inferenceSummary.isEmpty ? nil : inferenceSummary]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
      return try WorkReportActivityContext(
        id: activity.id,
        startedAt: activity.startedAt,
        endedAt: activity.endedAt,
        title: activity.title,
        summary: parts.isEmpty ? nil : parts.joined(separator: "\n"),
        detectedInteractionSeconds: activity.detectedInteractionSeconds,
        evidenceFrameIDs: activity.evidenceFrameIDs,
        visibleContentObservationIDs: activity.visibleContentObservationIDs
          + visualObservationIDs.filter {
            !activity.visibleContentObservationIDs.contains($0)
          }
      )
    }
  }

  /// Makes a bounded, report-only fallback from already persisted visual inferences.
  ///
  /// These values are intentionally not written as H2 Activities: visual interpretation is not
  /// an objective Session and must not acquire a fabricated display identity merely to satisfy
  /// the deterministic Session contract.
  static func visualFallbackActivities(
    from digests: [VisualInferenceDigest], maximumCount: Int = 32
  ) throws -> [WorkReportActivityContext] {
    precondition(maximumCount > 0)
    let ordered = digests.sorted {
      if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
      return $0.id < $1.id
    }
    let selected: [VisualInferenceDigest]
    if ordered.count <= maximumCount {
      selected = ordered
    } else if maximumCount == 1 {
      selected = [ordered[0]]
    } else {
      selected = (0..<maximumCount).map { index in
        let offset = index * (ordered.count - 1) / (maximumCount - 1)
        return ordered[offset]
      }
    }
    return
      try selected
      .map { digest in
        let endedAt = max(
          digest.endedAt ?? digest.startedAt,
          digest.startedAt.addingTimeInterval(1)
        )
        return try WorkReportActivityContext(
          id: ActivityID(),
          startedAt: digest.startedAt,
          endedAt: endedAt,
          title: "AI 视觉观察（待核对）",
          summary: digest.reportSummary,
          detectedInteractionSeconds: 0,
          visibleContentObservationIDs: digest.observationIDs
        )
      }
  }

  func refreshRevisions(now: Date = .now) async {
    guard let reportRepository else { return }
    do {
      let day = try currentDay(at: now)
      revisions = try await reportRepository.revisions(for: day.id)
    } catch {
      revisions = []
    }
  }

  /// Normalized unattended entry point for the auto-generation scheduler. It only fires when a
  /// current-day draft is absent and the budget is available; it never overrides a final report.
  func generateIfScheduledAndAbsent(
    now: Date = .now,
    workNote: String,
    weatherSnapshot: WeatherSnapshot? = nil
  ) async {
    guard !isGenerating else { return }
    guard !isFinalized else { return }
    guard workingDraft == nil else { return }
    guard let reportRepository else {
      status = "本地报告仓库尚未就绪"
      return
    }
    guard pipeline != nil, let objectiveRepository else { return }
    guard let day = try? currentDay(at: now) else { return }
    do {
      let existing = try await reportRepository.report(for: day.id)
      guard let existing else {
        await generate(workNote: workNote, weatherSnapshot: weatherSnapshot, now: now)
        return
      }
      guard existing.report.status == .draft else { return }
      let range = day.boundary.startsAt..<min(now, day.boundary.endsAt)
      let observations = await Self.fetchVisibleContent(
        from: visualInferenceRepository,
        in: range
      )
      let visual = try WorkReportPipelinePolicy.visualSnapshot(from: observations, in: range)
      evidenceCoverage = visual.coverage
      workNoteAdvisory = WorkReportPipelinePolicy.workNoteAdvisory(for: workNote)
      guard !visual.coverage.blocksGeneration else {
        status = visual.coverage.blockingStatusText
        return
      }
      let objectiveEvents = try await objectiveRepository.fetch(occurredIn: range).filter {
        event in
        guard event.kind == .applicationContextChanged,
          event.securityDisposition == .allowed
        else { return false }
        return true
      }
      let objectiveEventIDs = objectiveEvents.map(\.id)
      let prior = existing.currentRevision.sourceReferences
      let hasNewObjectiveEvents = !Set(objectiveEventIDs).isSubset(
        of: Set(prior.objectiveEventIDs)
      )
      let hasNewVisualObservations = !Set(visual.segments.flatMap(\.observationIDs)).isSubset(
        of: Set(prior.visibleContentObservationIDs)
      )
      let hasNewSources = hasNewObjectiveEvents || hasNewVisualObservations
      guard hasNewSources else {
        hasPendingSourceUpdates = false
        return
      }
      guard existing.currentRevision.origin == .model else {
        hasPendingSourceUpdates = true
        status = "检测到日报生成后的新事实；当前版本由你修改过，请手动决定是否重新生成"
        return
      }
      hasPendingSourceUpdates = true
      guard visual.coverage.isQuiescent(
        at: now,
        additionalEvidenceAt: objectiveEvents.map(\.occurredAt).max()
      ) else {
        status = "已检测到日报生成后的新事实；等待证据连续 10 分钟稳定后自动补写"
        return
      }
    } catch {
      return
    }
    await generate(workNote: workNote, weatherSnapshot: weatherSnapshot, now: now)
  }

  private func budgetViolation(now: Date) async -> WorkReportTokenBudget.Violation {
    guard let reportRepository else { return .none }
    do {
      let day = try currentDay(at: now)
      let dayInterval = day.boundary.startsAt..<day.boundary.endsAt
      let calendarMonth = Self.calendarMonthInterval(at: now)
      let daily = try await reportRepository.tokenUsage(in: dayInterval)
      let monthly = try await reportRepository.tokenUsage(in: calendarMonth)
      return budget.violation(
        forDay: daily.totalTokens, responding: monthly.totalTokens
      )
    } catch {
      return .none
    }
  }

  private static func budgetMessage(for violation: WorkReportTokenBudget.Violation)
    -> String
  {
    switch violation {
    case .none:
      return "可以生成工作日报"
    case .daily(let used, let limit):
      return "今日模型用量已到预算上限（≥\(used) token / \(limit)）；本地采集照常，AI 日报已暂停"
    case .monthly(let used, let limit):
      return "本月模型用量已到预算上限（≥\(used) token / \(limit)）；本地采集照常，AI 日报已暂停"
    }
  }

  func refreshUsageStatistics(now: Date = .now) async {
    guard let reportRepository else { return }
    do {
      let day = try currentDay(at: now)
      let daily = try await reportRepository.tokenUsage(in: day.boundary.startsAt..<day.boundary.endsAt)
      let monthly = try await reportRepository.tokenUsage(in: Self.calendarMonthInterval(at: now))
      usageSummary = WorkReportTokenSummary(
        inputTokens: daily.inputTokens,
        outputTokens: daily.outputTokens,
        cachedInputTokens: daily.cachedInputTokens,
        totalTokens: daily.totalTokens,
        attemptCount: daily.attemptCount
      )
      monthlyUsageSummary = WorkReportTokenSummary(
        inputTokens: monthly.inputTokens,
        outputTokens: monthly.outputTokens,
        cachedInputTokens: monthly.cachedInputTokens,
        totalTokens: monthly.totalTokens,
        attemptCount: monthly.attemptCount
      )
    } catch {
      usageSummary = .empty
      monthlyUsageSummary = .empty
    }
  }

  private static func calendarMonthInterval(at date: Date) -> Range<Date> {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone.autoupdatingCurrent
    let comps = calendar.dateComponents([.year, .month], from: date)
    let start = calendar.date(from: comps) ?? date
    let next = calendar.date(byAdding: .month, value: 1, to: start) ?? start.addingTimeInterval(31 * 86400)
    return start..<next
  }

  /// Finalizes the current day's draft. Confirmed reports reject any further
  /// automatic model regeneration in the domain; this surfaces that state.
  func finalizeReport(now: Date = .now) async {
    guard !isFinalizing else { return }
    guard let reportRepository else {
      status = "本地报告仓库尚未就绪"
      return
    }
    guard !isFinalized else {
      status = "今日工作日报已定稿"
      return
    }
    do {
      let day = try currentDay(at: now)
      guard let existing = try await reportRepository.report(for: day.id) else {
        status = "今天还没有可定稿的工作日报"
        return
      }
      guard existing.report.status == .draft else {
        isFinalized = true
        currentRecord = existing
        await refreshRevisions(now: now)
        status = "今日工作日报已定稿"
        return
      }
      let finalReport = try existing.report.finalizedByUser(at: now)
      let record = try PersistedWorkReportRecord(
        day: existing.day,
        report: finalReport,
        currentRevision: existing.currentRevision,
        modelUsage: existing.modelUsage
      )
      isFinalizing = true
      defer { isFinalizing = false }
      _ = try await reportRepository.finalize(record)
      isFinalized = true
      currentRecord = record
      clearWorkingDraftStorage()
      await refreshRevisions(now: now)
      await refreshHistory()
      status = "今日工作日报已定稿"
    } catch {
      status = "定稿失败；草稿仍安全保留"
    }
  }

  func saveUserEdit(_ body: String, now: Date = .now) async {
    guard !isSavingEdit else { return }
    guard !isFinalized else {
      status = "今日工作日报已定稿，不再接受正文修改"
      return
    }
    guard let reportRepository else {
      status = "本地报告仓库尚未就绪"
      return
    }
    guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      status = "工作日报正文不能为空"
      return
    }

    isSavingEdit = true
    status = "正在保存你的修改…"
    defer { isSavingEdit = false }
    do {
      let day = try currentDay(at: now)
      let existing = try await reportRepository.report(for: day.id)
      if let existing, existing.currentRevision.body == body {
        draft = existing.currentRevision.body
        currentRecord = existing
        clearWorkingDraftStorage()
        status = "当前工作日报内容已保存"
        return
      }
      let reportID = existing?.report.id ?? WorkReportID()
      let revision = try WorkReportRevision(
        reportID: reportID,
        revisionNumber: (existing?.report.currentRevisionNumber ?? 0) + 1,
        previousRevisionID: existing?.currentRevision.id,
        body: body,
        origin: .user,
        modelProvenance: nil,
        sourceReferences: existing?.currentRevision.sourceReferences ?? .empty,
        createdAt: now
      )
      let report: WorkReport
      if let existing {
        report = try existing.report.accepting(revision, initiatedBy: .user, at: now)
      } else {
        report = try WorkReport(
          id: reportID,
          dayID: day.id,
          initialRevision: revision,
          createdAt: now
        )
      }
      let record = try PersistedWorkReportRecord(
        day: existing?.day ?? day,
        report: report,
        currentRevision: revision,
        modelUsage: nil
      )
      _ = try await reportRepository.save(record)
      draft = revision.body
      currentRecord = record
      generatedAt = report.updatedAt
      usage = nil
      isFinalized = report.status == .final
      clearWorkingDraftStorage()
      await refreshRevisions(now: now)
      await refreshHistory()
      status = existing == nil
        ? "手写日报已作为第 1 版保存在本机"
        : "你的修改已作为第 \(revision.revisionNumber) 版保存在本机"
    } catch {
      status = "保存修改失败；上一版仍安全保留"
    }
  }

  private func currentDay(at date: Date) throws -> DayDescriptor {
    let timeZone = TimeZone.autoupdatingCurrent
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let boundary = dailySchedule.workdayBoundary
    let start = try boundary.start(containing: date, calendar: calendar)
    guard let followingCivilDay = calendar.date(byAdding: .day, value: 1, to: start) else {
      throw WorkReportDayError.nextDayUnavailable
    }
    let end = try boundary.start(
      containing: followingCivilDay,
      calendar: calendar
    )
    let components = calendar.dateComponents([.year, .month, .day], from: start)
    guard let year = components.year, let month = components.month, let day = components.day else {
      throw WorkReportDayError.invalidDate
    }
    let logicalDate = try LogicalDayDate(year: year, month: month, day: day)
    return try DayDescriptor(
      id: Self.stableDayID(
        logicalDate: logicalDate,
        timeZoneIdentifier: timeZone.identifier,
        boundaryHour: boundary.hour
      ),
      logicalDate: logicalDate,
      timeZoneIdentifier: timeZone.identifier,
      boundary: .init(hour: boundary.hour, startsAt: start, endsAt: end)
    )
  }

  private static func makePersistedRecord(
    day: DayDescriptor,
    existing: PersistedWorkReportRecord?,
    content: String,
    sourceReferences: WorkReportSourceReferences,
    response: ProviderWorkReportResponse,
    configuration: OpenAICompatibleProviderConfiguration,
    generatedAt: Date,
    providerStartedAt: Date,
    providerCompletedAt: Date
  ) throws -> PersistedWorkReportRecord {
    let reportID = existing?.report.id ?? WorkReportID()
    let revision = try WorkReportRevision(
      reportID: reportID,
      revisionNumber: (existing?.report.currentRevisionNumber ?? 0) + 1,
      previousRevisionID: existing?.currentRevision.id,
      body: content,
      origin: .model,
      modelProvenance: try ModelProvenance(
        provider: configuration.endpoint.host ?? "openai-compatible",
        model: configuration.model,
        promptVersion: ChineseWorkReportPrompt.version
      ),
      sourceReferences: sourceReferences,
      createdAt: generatedAt
    )
    let report: WorkReport
    if let existing {
      report = try existing.report.accepting(
        revision,
        initiatedBy: .automatic,
        at: generatedAt
      )
    } else {
      report = try WorkReport(
        id: reportID,
        dayID: day.id,
        initialRevision: revision,
        createdAt: generatedAt
      )
    }
    let providerUsage = response.usage
    let usage = try ModelUsage(
      revisionID: revision.id,
      requestID: response.requestID,
      provider: configuration.endpoint.host ?? "openai-compatible",
      model: configuration.model,
      task: .workReport,
      startedAt: providerStartedAt,
      completedAt: providerCompletedAt,
      outcome: .success,
      inputTokens: providerUsage?.promptTokens,
      outputTokens: providerUsage?.completionTokens,
      cachedInputTokens: providerUsage?.cachedTokens,
      totalTokens: providerUsage?.totalTokens
    )
    return try PersistedWorkReportRecord(
      day: day,
      report: report,
      currentRevision: revision,
      modelUsage: usage
    )
  }

  private static func stableDayID(
    logicalDate: LogicalDayDate,
    timeZoneIdentifier: String,
    boundaryHour: Int
  ) -> DayID {
    let bytes = Array(
      "dayday|\(logicalDate.year)-\(logicalDate.month)-\(logicalDate.day)|\(timeZoneIdentifier)|\(boundaryHour)"
        .utf8
    )
    func hash(seed: UInt64) -> UInt64 {
      bytes.reduce(seed) { partial, byte in
        (partial ^ UInt64(byte)) &* 1_099_511_628_211
      }
    }
    let first = hash(seed: 14_695_981_039_346_656_037)
    let second = hash(seed: 7_809_847_782_465_536_322)
    var raw =
      withUnsafeBytes(of: first.bigEndian, Array.init)
      + withUnsafeBytes(of: second.bigEndian, Array.init)
    // UUID version 8 explicitly marks this as an application-defined stable identifier.
    raw[6] = (raw[6] & 0x0F) | 0x80
    raw[8] = (raw[8] & 0x3F) | 0x80
    return DayID(
      rawValue: UUID(
        uuid: (
          raw[0], raw[1], raw[2], raw[3], raw[4], raw[5], raw[6], raw[7],
          raw[8], raw[9], raw[10], raw[11], raw[12], raw[13], raw[14], raw[15]
        )))
  }
}

private enum WorkReportDayError: Error {
  case nextDayUnavailable
  case invalidDate
}

private enum WorkReportGenerationError: Error {
  case derivationStorage
}
