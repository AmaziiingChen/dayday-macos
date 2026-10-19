import DaydayAI
import DaydayCore
import DaydayUnderstanding
import Foundation
import Testing

@testable import DaydayApp

@MainActor
struct WorkReportGenerationModelTests {
  @Test
  func reportReviewPresentationUsesVisibleWritingAcrossConsecutiveDays() async throws {
    let reports = InMemoryWorkReportRepository()
    let model = WorkReportGenerationModel(
      providerSettings: ProviderSettingsModel(
        credentialStore: WorkReportCredentialStore(value: "test-key"),
        defaults: makeDefaults()
      )
    )
    model.configure(repository: EmptyLinkedRepository(), reportRepository: reports)
    let firstDay = Date(timeIntervalSince1970: 1_785_736_800)
    let secondDay = firstDay.addingTimeInterval(86_400)

    await model.saveUserEdit("## 第一天\n\n完成任务 123", now: firstDay)
    await model.saveUserEdit("第二天继续完成任务", now: secondDay)
    let records = try await reports.recentReports(limit: 100)
    let presentation = WorkReportReviewPresentation(records: records, endingAt: secondDay)

    #expect(presentation.writingDayCount == 2)
    #expect(presentation.currentStreak == 2)
    #expect(presentation.totalCharacterCount > 0)
    #expect(presentation.characterCounts.count == 2)
    #expect(presentation.previewTextByReportID.count == 2)
    #expect(presentation.heatmap.cells.filter(\.hasEntry).count == 2)
  }

  @Test
  func workingDraftAutosavesWithoutCreatingVersionsAndRestoresAfterNavigation() async throws {
    let settings = ProviderSettingsModel(
      credentialStore: WorkReportCredentialStore(value: "test-key"),
      defaults: makeDefaults()
    )
    let generator = RecordingWorkReportGenerator()
    let reports = InMemoryWorkReportRepository()
    let workingDrafts = VolatileWorkReportWorkingDraftStore()
    let now = Date(timeIntervalSince1970: 1_785_736_800)
    let model = WorkReportGenerationModel(
      providerSettings: settings,
      generator: generator,
      workingDraftPersistence: workingDrafts,
      workingDraftSaveDelay: .seconds(60)
    )
    model.configure(repository: EmptyLinkedRepository(), reportRepository: reports)
    await model.restoreCurrentReport(now: now)

    model.stageWorkingDraft("第一段。", now: now)
    model.stageWorkingDraft("第一段。\n\n第二段。", now: now, flush: true)

    #expect(await reports.onlyRecord == nil)
    #expect(model.workingDraft == "第一段。\n\n第二段。")
    #expect(model.workingDraftStatus == "已自动保存到本机")
    #expect(try workingDrafts.load()?.body == model.workingDraft)

    // Snapshot requests can publish the same body again. That must not regress the visible
    // status to a saving state when no new write was scheduled.
    model.stageWorkingDraft("第一段。\n\n第二段。", now: now)
    #expect(model.workingDraftStatus == "已自动保存到本机")

    await model.generateIfScheduledAndAbsent(now: now, workNote: "不应覆盖手写副本")
    #expect(await generator.callCount == 0)
    #expect(await reports.onlyRecord == nil)

    let restored = WorkReportGenerationModel(
      providerSettings: settings,
      generator: generator,
      workingDraftPersistence: workingDrafts
    )
    restored.configure(repository: EmptyLinkedRepository(), reportRepository: reports)
    await restored.restoreCurrentReport(now: now)
    #expect(restored.workingDraft == model.workingDraft)
    #expect(restored.workingDraftStatus?.contains("已恢复") == true)

    await restored.saveUserEdit(try #require(restored.workingDraft), now: now)
    let saved = try #require(await reports.onlyRecord)
    #expect(saved.currentRevision.revisionNumber == 1)
    #expect(restored.workingDraft == nil)
    #expect(try workingDrafts.load() == nil)
  }

  @Test
  func manualReportCanBeTheFirstSavedRevisionWithoutCallingAI() async throws {
    let settings = ProviderSettingsModel(
      credentialStore: WorkReportCredentialStore(value: "test-key"),
      defaults: makeDefaults()
    )
    let generator = RecordingWorkReportGenerator()
    let reports = InMemoryWorkReportRepository()
    let model = WorkReportGenerationModel(providerSettings: settings, generator: generator)
    model.configure(repository: EmptyLinkedRepository(), reportRepository: reports)
    let now = Date(timeIntervalSince1970: 1_785_736_800)

    let markdown = "    let result = finishReport()\n\n今天手写完成了日报。\n"
    await model.saveUserEdit(markdown, now: now)

    let saved = try #require(await reports.onlyRecord)
    #expect(saved.currentRevision.revisionNumber == 1)
    #expect(saved.currentRevision.origin == .user)
    #expect(saved.currentRevision.body == markdown)
    #expect(saved.currentRevision.previousRevisionID == nil)
    #expect(saved.currentRevision.modelProvenance == nil)
    #expect(saved.currentRevision.sourceReferences == .empty)
    #expect(saved.modelUsage == nil)
    #expect(model.currentRecord == saved)
    #expect(model.revisions.map(\.revisionNumber) == [1])
    #expect(model.status.contains("手写日报"))
    #expect(await generator.callCount == 0)

    await model.saveUserEdit(markdown, now: now.addingTimeInterval(60))
    #expect(try #require(await reports.onlyRecord).currentRevision.revisionNumber == 1)
    #expect(model.revisions.map(\.revisionNumber) == [1])
    #expect(model.status.contains("已保存"))
  }

  @Test
  func realGenerationUsesOnlyWorkContextAndPersistsTheDraft() async throws {
    let defaults = makeDefaults()
    let credentials = WorkReportCredentialStore(value: "test-key")
    let settings = ProviderSettingsModel(credentialStore: credentials, defaults: defaults)
    let generator = RecordingWorkReportGenerator()
    let reports = InMemoryWorkReportRepository()
    let model = WorkReportGenerationModel(providerSettings: settings, generator: generator)
    model.configure(repository: EmptyLinkedRepository(), reportRepository: reports)
    let now = Date(timeIntervalSince1970: 1_785_736_800)

    await model.generate(workNote: "  完成真实日报链路。  ", now: now)

    #expect(model.draft == "今天完成了真实日报链路。")
    #expect(model.generatedAt == now)
    #expect(model.status.contains("已保存到本机历史"))
    let saved = try #require(await reports.onlyRecord)
    #expect(saved.currentRevision.body == model.draft)
    #expect(saved.modelUsage?.totalTokens == 16)
    #expect(saved.currentRevision.modelProvenance?.promptVersion == ChineseWorkReportPrompt.version)
    let context = try #require(await generator.lastContext)
    #expect(context.activities.isEmpty)
    #expect(context.workNotes.map(\.body) == ["完成真实日报链路。"])
    #expect(await generator.lastCredential == "test-key")
    #expect(await generator.lastConfiguration?.thinkingEnabled == false)

    await model.generate(workNote: "第二次生成。", now: now)
    let regenerated = try #require(await reports.onlyRecord)
    #expect(regenerated.report.id == saved.report.id)
    #expect(regenerated.report.currentRevisionNumber == 2)
    #expect(regenerated.currentRevision.previousRevisionID == saved.currentRevision.id)
    #expect(model.recentReports.count == 1)

    await model.saveUserEdit("我补充了人工确认的结果。", now: now)
    let edited = try #require(await reports.onlyRecord)
    #expect(edited.report.currentRevisionNumber == 3)
    #expect(edited.currentRevision.origin == .user)
    #expect(edited.currentRevision.modelProvenance == nil)
    #expect(edited.currentRevision.sourceReferences == regenerated.currentRevision.sourceReferences)
    #expect(edited.modelUsage == nil)
    #expect(model.draft == "我补充了人工确认的结果。")

    let restored = WorkReportGenerationModel(providerSettings: settings, generator: generator)
    restored.configure(repository: EmptyLinkedRepository(), reportRepository: reports)
    await restored.restoreCurrentReport(now: now)
    #expect(restored.draft == edited.currentRevision.body)
    #expect(restored.status.contains("第 3 版"))
  }

  @Test
  func generationPassesWeatherAndCommitsResolvableSources() async throws {
    let settings = ProviderSettingsModel(
      credentialStore: WorkReportCredentialStore(value: "test-key"),
      defaults: makeDefaults()
    )
    let generator = RecordingWorkReportGenerator()
    let reports = InMemoryWorkReportRepository()
    let model = WorkReportGenerationModel(providerSettings: settings, generator: generator)
    model.configure(repository: EmptyLinkedRepository(), reportRepository: reports)
    let now = Date(timeIntervalSince1970: 1_785_736_800)
    let day = try #require(model.dayDescriptor(at: now))
    let location = try CityWeatherLocation(
      id: CityWeatherLocationID(),
      displayName: "深圳南山区",
      timeZoneIdentifier: day.timeZoneIdentifier,
      providerLocationKey: WeatherProviderLocationKey(rawValue: "district-nanshan")
    )
    let weather = try WeatherSnapshot(
      dayID: day.id,
      location: location,
      provider: "Open-Meteo",
      providerSchemaVersion: "current-v1",
      observedAt: now,
      retrievedAt: now,
      condition: "多云",
      temperatureCelsius: 30
    )

    await model.generate(
      workNote: "今天完成了日报来源闭环。",
      weatherSnapshot: weather,
      now: now
    )

    let context = try #require(await generator.lastContext)
    #expect(context.weatherSnapshots == [weather])
    let references = try #require(await reports.onlyRecord).currentRevision.sourceReferences
    let noteID = try #require(references.workNoteIDs.first)
    #expect(references.weatherSnapshotIDs == [weather.id])
    #expect(try await reports.workNote(id: noteID)?.body == "今天完成了日报来源闭环。")
    #expect(try await reports.weatherSnapshot(id: weather.id) == weather)
    #expect(model.requestPreviewStatus.contains("本次实际提交"))
    #expect(model.requestPreview?.contextJSON.contains("今天完成了日报来源闭环。") == true)
  }

  @Test
  func changingLogicalDayBoundaryPreservesWorkingCopyAndRecomputesDay() async throws {
    let settings = ProviderSettingsModel(
      credentialStore: WorkReportCredentialStore(value: "test-key"),
      defaults: makeDefaults()
    )
    let reports = InMemoryWorkReportRepository()
    let model = WorkReportGenerationModel(
      providerSettings: settings,
      generator: RecordingWorkReportGenerator(),
      workingDraftPersistence: VolatileWorkReportWorkingDraftStore()
    )
    model.configure(repository: EmptyLinkedRepository(), reportRepository: reports)
    let now = Date.now
    model.stageWorkingDraft("保留这份未提交工作副本。", now: now, flush: true)
    let midnight = try DailyWorkSchedule(
      workStartsAt: LocalTimeOfDay(hour: 9),
      workEndsAt: LocalTimeOfDay(hour: 18),
      reportGeneratesAt: LocalTimeOfDay(hour: 18),
      logicalDayBoundaryHour: 0
    )

    model.updateDailySchedule(midnight, now: now)
    await Task.yield()

    #expect(model.dayDescriptor(at: now)?.boundary.hour == 0)
    #expect(model.workingDraft == "保留这份未提交工作副本。")
  }

  @Test
  func finalizeMarksDraftFinalAndBlocksAutomaticRegeneration() async throws {
    let settings = ProviderSettingsModel(
      credentialStore: WorkReportCredentialStore(value: "test-key"),
      defaults: makeDefaults()
    )
    let generator = RecordingWorkReportGenerator()
    let reports = InMemoryWorkReportRepository()
    let model = WorkReportGenerationModel(providerSettings: settings, generator: generator)
    model.configure(repository: EmptyLinkedRepository(), reportRepository: reports)
    let now = Date(timeIntervalSince1970: 1_785_736_800)

    await model.generate(workNote: "生成一份日报。", now: now)
    #expect(model.isFinalized == false)

    await model.finalizeReport(now: now)
    #expect(model.isFinalized == true)
    #expect(model.status.contains("已定稿"))
    let stored = try #require(await reports.onlyRecord)
    #expect(stored.report.status == .final)

    // A finalized report must not be silently regenerated.
    let before = try #require(await reports.onlyRecord).currentRevision.revisionNumber
    await model.generate(workNote: "不应覆盖定稿。", now: now)
    #expect(model.status.contains("已定稿"))
    let after = try #require(await reports.onlyRecord).currentRevision.revisionNumber
    #expect(after == before)
    #expect(await generator.callCount == 1)

    await model.saveUserEdit("不应覆盖定稿。", now: now)
    #expect(model.status.contains("不再接受"))
    #expect(try #require(await reports.onlyRecord).currentRevision.revisionNumber == before)

    let restored = WorkReportGenerationModel(providerSettings: settings, generator: generator)
    restored.configure(repository: EmptyLinkedRepository(), reportRepository: reports)
    await restored.restoreCurrentReport(now: now)
    #expect(restored.isFinalized == true)
  }

  @Test
  func writingPreferencesArePassedToGenerator() async throws {
    let defaults = makeDefaults()
    let credentials = WorkReportCredentialStore(value: "test-key")
    let settings = ProviderSettingsModel(credentialStore: credentials, defaults: defaults)
    let generator = RecordingWorkReportGenerator()
    let reports = InMemoryWorkReportRepository()
    let prefs = WorkReportWritingPreferences(
      tone: "简洁专业", alwaysInclude: "成果与下一步", alwaysAvoid: "猜测"
    )
    let model = WorkReportGenerationModel(
      providerSettings: settings, generator: generator, writingPreferences: prefs
    )
    model.configure(repository: EmptyLinkedRepository(), reportRepository: reports)
    let now = Date(timeIntervalSince1970: 1_785_736_800)

    await model.generate(workNote: "完成偏好注入。", now: now)
    #expect(await generator.lastWritingPreferences == prefs)
  }

  @Test
  func refreshUsageStatisticsLoadsTodayTokens() async throws {
    let settings = ProviderSettingsModel(
      credentialStore: WorkReportCredentialStore(value: "test-key"),
      defaults: makeDefaults()
    )
    let generator = RecordingWorkReportGenerator()
    let reports = InMemoryWorkReportRepository()
    let model = WorkReportGenerationModel(providerSettings: settings, generator: generator)
    model.configure(repository: EmptyLinkedRepository(), reportRepository: reports)
    let now = Date(timeIntervalSince1970: 1_785_736_800)

    await model.generate(workNote: "统计用量。", now: now)
    await model.refreshUsageStatistics(now: now)
    #expect(model.usageSummary.totalTokens == 16)
    #expect(model.usageSummary.attemptCount == 1)
  }

  @Test
  func budgetExhaustionBlocksGenerationWithoutStoppingCollection() async throws {
    let settings = ProviderSettingsModel(
      credentialStore: WorkReportCredentialStore(value: "test-key"),
      defaults: makeDefaults()
    )
    let generator = RecordingWorkReportGenerator()
    let reports = InMemoryWorkReportRepository()
    let budget = try WorkReportTokenBudget(dailyLimit: 10, monthlyLimit: nil)
    let model = WorkReportGenerationModel(providerSettings: settings, generator: generator)
    model.configure(
      repository: EmptyLinkedRepository(), reportRepository: reports, budget: budget
    )
    let now = Date(timeIntervalSince1970: 1_785_736_800)

    await model.generate(workNote: "第一版。", now: now)
    #expect(model.status.contains("已保存到本机历史"))

    // The second attempt would exceed the daily 10-token budget (first used 16) and must not
    // call the provider again.
    await model.generate(workNote: "不应超过预算。", now: now)
    #expect(model.status.contains("预算"))
    #expect(await generator.callCount == 1)
    let record = try #require(await reports.onlyRecord)
    #expect(record.currentRevision.revisionNumber == 1)
  }

  @Test
  func savedProviderSettingsUpdateTheRunningReportGenerationPolicy() async throws {
    let settings = ProviderSettingsModel(
      credentialStore: WorkReportCredentialStore(value: "test-key"),
      defaults: makeDefaults()
    )
    let generator = RecordingWorkReportGenerator()
    let reports = InMemoryWorkReportRepository()
    let model = WorkReportGenerationModel(providerSettings: settings, generator: generator)
    settings.setReportGenerationSettingsChangeHandler { budget, preferences in
      model.updateGenerationSettings(budget: budget, writingPreferences: preferences)
    }
    model.configure(repository: EmptyLinkedRepository(), reportRepository: reports)
    let now = Date(timeIntervalSince1970: 1_785_736_800)

    await model.generate(workNote: "首次生成。", now: now)
    settings.dailyTokenLimit = 10
    settings.writingTone = "简洁专业"
    settings.saveBudgetCaps()
    settings.saveWritingPreferences()

    await model.generate(workNote: "不应超过新预算。", now: now)
    #expect(model.status.contains("预算"))
    #expect(await generator.callCount == 1)
  }

  @Test
  func autoScheduleSkipsWhenDraftAlreadyExists() async throws {
    let settings = ProviderSettingsModel(
      credentialStore: WorkReportCredentialStore(value: "test-key"),
      defaults: makeDefaults()
    )
    let generator = RecordingWorkReportGenerator()
    let reports = InMemoryWorkReportRepository()
    let model = WorkReportGenerationModel(providerSettings: settings, generator: generator)
    model.configure(repository: EmptyLinkedRepository(), reportRepository: reports)
    let now = Date(timeIntervalSince1970: 1_785_736_800)

    await model.generate(workNote: "已有草稿。", now: now)
    let before = await generator.callCount
    await model.generateIfScheduledAndAbsent(now: now, workNote: "自动触发。")
    #expect(await generator.callCount == before)
  }

  @Test("stale visual coverage blocks the provider and explains the missing interval")
  func staleVisualCoverageBlocksGeneration() async throws {
    let now = Date(timeIntervalSince1970: 1_785_736_800)
    let visible = MutableVisibleContentRepository()
    await visible.replace([
      try reportObjectiveObservation(at: now.addingTimeInterval(-60)),
      try reportInferenceObservation(at: now.addingTimeInterval(-12 * 60), summary: "较早的视觉总结"),
    ])
    let generator = RecordingWorkReportGenerator()
    let model = configuredModel(
      generator: generator,
      visualRepository: visible
    )

    await model.generate(workNote: "今天继续推进工作。", now: now)

    #expect(await generator.callCount == 0)
    #expect(model.evidenceCoverage.blocksGeneration)
    #expect(model.status.contains("正在等待更新"))
    #expect(model.draft == nil)
  }

  @Test("scheduled generation appends late facts to an untouched AI draft")
  func automaticGenerationRevisesModelDraftWhenNewFactsArrive() async throws {
    let now = Date(timeIntervalSince1970: 1_785_736_800)
    let visible = MutableVisibleContentRepository()
    await visible.replace([
      try reportObjectiveObservation(at: now.addingTimeInterval(-90)),
      try reportInferenceObservation(at: now.addingTimeInterval(-80), summary: "第一段工作"),
    ])
    let generator = RecordingWorkReportGenerator()
    let reports = InMemoryWorkReportRepository()
    let model = configuredModel(
      generator: generator,
      reports: reports,
      visualRepository: visible
    )
    await model.generate(workNote: "工作笔记", now: now)
    #expect(try #require(await reports.onlyRecord).currentRevision.revisionNumber == 1)

    let later = now.addingTimeInterval(15 * 60)
    await visible.append(contentsOf: [
      try reportObjectiveObservation(at: later.addingTimeInterval(-11 * 60)),
      try reportInferenceObservation(at: later.addingTimeInterval(-11 * 60 + 10), summary: "晚到的新事实"),
    ])
    await model.generateIfScheduledAndAbsent(now: later, workNote: "工作笔记")

    #expect(await generator.callCount == 2)
    #expect(try #require(await reports.onlyRecord).currentRevision.revisionNumber == 2)
    #expect(model.hasPendingSourceUpdates == false)
  }

  @Test("late facts are debounced until the evidence stream is quiet")
  func automaticGenerationWaitsForEvidenceQuiescence() async throws {
    let now = Date(timeIntervalSince1970: 1_785_736_800)
    let visible = MutableVisibleContentRepository()
    await visible.replace([
      try reportObjectiveObservation(at: now.addingTimeInterval(-90)),
      try reportInferenceObservation(at: now.addingTimeInterval(-80), summary: "第一段工作"),
    ])
    let generator = RecordingWorkReportGenerator()
    let model = configuredModel(generator: generator, visualRepository: visible)
    await model.generate(workNote: "工作笔记", now: now)

    let later = now.addingTimeInterval(180)
    await visible.append(contentsOf: [
      try reportObjectiveObservation(at: later.addingTimeInterval(-20)),
      try reportInferenceObservation(at: later.addingTimeInterval(-10), summary: "仍在持续的新事实"),
    ])
    await model.generateIfScheduledAndAbsent(now: later, workNote: "工作笔记")

    #expect(await generator.callCount == 1)
    #expect(model.hasPendingSourceUpdates)
    #expect(model.status.contains("连续 10 分钟稳定"))
  }

  @Test("late facts never overwrite a user-edited report")
  func automaticGenerationPreservesUserRevisionWhenLateFactsArrive() async throws {
    let now = Date(timeIntervalSince1970: 1_785_736_800)
    let visible = MutableVisibleContentRepository()
    await visible.replace([
      try reportObjectiveObservation(at: now.addingTimeInterval(-90)),
      try reportInferenceObservation(at: now.addingTimeInterval(-80), summary: "第一段工作"),
    ])
    let generator = RecordingWorkReportGenerator()
    let reports = InMemoryWorkReportRepository()
    let model = configuredModel(
      generator: generator,
      reports: reports,
      visualRepository: visible
    )
    await model.generate(workNote: "工作笔记", now: now)
    await model.saveUserEdit("我已经人工核对并修改。", now: now.addingTimeInterval(30))

    let later = now.addingTimeInterval(180)
    await visible.append(contentsOf: [
      try reportObjectiveObservation(at: later.addingTimeInterval(-20)),
      try reportInferenceObservation(at: later.addingTimeInterval(-10), summary: "晚到的新事实"),
    ])
    await model.generateIfScheduledAndAbsent(now: later, workNote: "工作笔记")

    #expect(await generator.callCount == 1)
    let saved = try #require(await reports.onlyRecord)
    #expect(saved.currentRevision.origin == .user)
    #expect(saved.currentRevision.body == "我已经人工核对并修改。")
    #expect(model.hasPendingSourceUpdates)
    #expect(model.status.contains("请手动决定"))
  }

  @Test
  func refreshRevisionsLoadsOrderedLineage() async throws {
    let settings = ProviderSettingsModel(
      credentialStore: WorkReportCredentialStore(value: "test-key"),
      defaults: makeDefaults()
    )
    let generator = RecordingWorkReportGenerator()
    let reports = InMemoryWorkReportRepository()
    let model = WorkReportGenerationModel(providerSettings: settings, generator: generator)
    model.configure(repository: EmptyLinkedRepository(), reportRepository: reports)
    let now = Date(timeIntervalSince1970: 1_785_736_800)

    await model.generate(workNote: "第一版。", now: now)
    await model.generate(workNote: "第二版重新生成。", now: now)
    await model.saveUserEdit("第三版人工修订。", now: now)

    await model.refreshRevisions(now: now)
    #expect(model.revisions.map(\.revisionNumber) == [1, 2, 3])
    #expect(model.revisions.last?.origin == .user)
  }

  @Test
  func emptyDayDoesNotCallProvider() async {
    let settings = ProviderSettingsModel(
      credentialStore: WorkReportCredentialStore(value: "test-key"),
      defaults: makeDefaults()
    )
    let generator = RecordingWorkReportGenerator()
    let model = WorkReportGenerationModel(providerSettings: settings, generator: generator)
    model.configure(
      repository: EmptyLinkedRepository(),
      reportRepository: InMemoryWorkReportRepository()
    )

    await model.generate(workNote: "", now: Date(timeIntervalSince1970: 1_785_736_800))

    #expect(model.draft == nil)
    #expect(model.status.contains("还没有"))
    #expect(await generator.callCount == 0)
  }

  @Test("durable Activities are reloaded before report generation")
  func durableActivitiesArePersistedReloadedThenSentToProvider() async throws {
    let now = Date(timeIntervalSince1970: 1_785_736_800)
    let fixture = try activityFixture(at: now)
    let derivations = InMemoryDerivationRepository(behavior: .reloadReplacement)
    let generator = RecordingWorkReportGenerator()
    let model = configuredModel(
      generator: generator,
      repository: fixture,
      derivations: derivations
    )

    await model.generate(workNote: "本地笔记", now: now)

    let durable = try #require(await derivations.current)
    let context = try #require(await generator.lastContext)
    #expect(context.activities.map(\.id) == durable.activities.map(\.id))
    #expect(context.activities.map(\.title) == ["Durably reloaded activity"])
    #expect(context.workNotes.map(\.body) == ["本地笔记"])
    #expect(await derivations.saveCallCount == 1)
    #expect(await generator.callCount == 1)
  }

  @Test("derivation storage failures and exhausted conflicts never invoke the provider")
  func derivationStorageFailureStopsBeforeProvider() async throws {
    let now = Date(timeIntervalSince1970: 1_785_736_800)
    let fixture = try activityFixture(at: now)
    for behavior in [
      InMemoryDerivationRepository.Behavior.readFailure,
      .saveFailure,
      .alwaysConflict,
    ] {
      let derivations = InMemoryDerivationRepository(behavior: behavior)
      let generator = RecordingWorkReportGenerator()
      let model = configuredModel(
        generator: generator,
        repository: fixture,
        derivations: derivations
      )
      await model.generate(workNote: "", now: now)
      #expect(await generator.callCount == 0)
      #expect(model.status.contains("本地理解数据存储失败"))
    }
  }

  @Test("a storage conflict refreshes the durable predecessor and retries")
  func conflictRefreshesAndRetries() async throws {
    let now = Date(timeIntervalSince1970: 1_785_736_800)
    let fixture = try activityFixture(at: now)
    let derivations = InMemoryDerivationRepository(behavior: .conflictThenAccept)
    let generator = RecordingWorkReportGenerator()
    let model = configuredModel(
      generator: generator,
      repository: fixture,
      derivations: derivations
    )

    await model.generate(workNote: "", now: now)

    #expect(await derivations.saveCallCount == 2)
    #expect(await derivations.current?.revision == 2)
    #expect(await generator.callCount == 1)
  }

  @Test("cancellation during the initial durable read never calls the provider")
  func cancellationDuringInitialDurableReadIsPreserved() async throws {
    let now = Date(timeIntervalSince1970: 1_785_736_800)
    let fixture = try activityFixture(at: now)
    let derivations = CancellingInitialReadDerivationRepository()
    let generator = RecordingWorkReportGenerator()
    let model = configuredModel(
      generator: generator,
      repository: fixture,
      derivations: derivations
    )

    let generation = Task { await model.generate(workNote: "", now: now) }
    await derivations.waitUntilInitialRead()
    generation.cancel()
    await derivations.releaseInitialRead()
    await generation.value

    #expect(await generator.callCount == 0)
    #expect(model.status == "日报生成已取消")
  }

  private func configuredModel(
    generator: RecordingWorkReportGenerator,
    repository: any ObjectiveLinkedRecordRepository,
    derivations: any UnderstandingDerivationRepository
  ) -> WorkReportGenerationModel {
    let settings = ProviderSettingsModel(
      credentialStore: WorkReportCredentialStore(value: "test-key"),
      defaults: makeDefaults()
    )
    let model = WorkReportGenerationModel(providerSettings: settings, generator: generator)
    model.configure(
      repository: repository,
      reportRepository: InMemoryWorkReportRepository(),
      understandingDerivationRepository: derivations
    )
    return model
  }

  private func configuredModel(
    generator: RecordingWorkReportGenerator,
    reports: InMemoryWorkReportRepository = InMemoryWorkReportRepository(),
    visualRepository: any VisibleContentArchiveRepository
  ) -> WorkReportGenerationModel {
    let settings = ProviderSettingsModel(
      credentialStore: WorkReportCredentialStore(value: "test-key"),
      defaults: makeDefaults()
    )
    let model = WorkReportGenerationModel(providerSettings: settings, generator: generator)
    model.configure(
      repository: EmptyLinkedRepository(),
      reportRepository: reports,
      visualInferenceRepository: visualRepository
    )
    return model
  }

  private func reportObjectiveObservation(at date: Date) throws -> VisibleContentObservation {
    try VisibleContentObservation(
      provenance: reportProvenance(at: date),
      kind: .objectiveText,
      classification: .conversation,
      redactionState: .noRedactionNeeded,
      text: "研发群 · 陈工：继续联调"
    )
  }

  private func reportInferenceObservation(
    at date: Date,
    summary: String
  ) throws -> VisibleContentObservation {
    let displayID = DisplayID(
      rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    let display = try VisualDisplayState(
      displayID: displayID,
      role: .primary,
      visibleState: summary
    )
    let segment = try VisualWorkSegment(
      primarySituation: summary,
      interaction: "可见输入",
      activityKind: .communication,
      foregroundApplicationLabel: "WeChat",
      displays: [display],
      relationship: .coordinated,
      systemContextAgreement: .matches,
      evidence: ["群聊窗口可见"],
      uncertainties: []
    )
    return try VisibleContentObservation(
      provenance: reportProvenance(
        at: date, endedAt: date.addingTimeInterval(30), displayID: displayID),
      kind: .inference,
      classification: .conversation,
      redactionState: .noRedactionNeeded,
      text: summary,
      inferenceOrigin: "test-vision-v1",
      visualWorkSegment: segment
    )
  }

  private func reportProvenance(
    at date: Date,
    endedAt: Date? = nil,
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
      endedAt: endedAt,
      timeZoneIdentifier: TimeZone.autoupdatingCurrent.identifier,
      display: DisplayContext(id: displayID, topologyRevision: 1)
    )
  }

  private func activityFixture(at now: Date) throws -> ActivityLinkedRepository {
    let day = try reportDay(at: now)
    let display = DisplayID()
    let event = try ObjectiveEvent(
      kind: .applicationContextChanged,
      occurredAt: day.boundary.startsAt.addingTimeInterval(60),
      timeZoneIdentifier: day.timeZoneIdentifier,
      source: try CollectorSource(
        collector: .applicationWindowContext, collectorVersion: "test", payloadSchemaVersion: 1),
      display: DisplayContext(id: display, topologyRevision: 1),
      securityDisposition: .allowed
    )
    let context = try ApplicationContextRecord(
      eventID: event.id,
      applicationIdentifier: ApplicationIdentifier(rawValue: UUID()),
      displayLabelSnapshot: "Editor"
    )
    return ActivityLinkedRepository(events: [event], contexts: [event.id: context])
  }

  private func reportDay(at date: Date) throws -> DayDescriptor {
    let timeZone = TimeZone.autoupdatingCurrent
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let start = try WorkdayBoundary.standard.start(containing: date, calendar: calendar)
    let following = try #require(calendar.date(byAdding: .day, value: 1, to: start))
    let end = try WorkdayBoundary.standard.start(containing: following, calendar: calendar)
    let parts = calendar.dateComponents([.year, .month, .day], from: start)
    return try DayDescriptor(
      logicalDate: .init(
        year: try #require(parts.year), month: try #require(parts.month),
        day: try #require(parts.day)),
      timeZoneIdentifier: timeZone.identifier,
      boundary: .init(hour: WorkdayBoundary.standard.hour, startsAt: start, endsAt: end)
    )
  }

  private func makeDefaults() -> UserDefaults {
    let suite = "WorkReportGenerationModelTests.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
  }
}

private actor InMemoryWorkReportRepository: WorkReportGenerationRepository {
  private var records: [DayID: PersistedWorkReportRecord] = [:]
  private var revisionHistory: [WorkReportRevisionID: WorkReportRevision] = [:]
  private var revisionOrder: [DayID: [WorkReportRevisionID]] = [:]
  private var workNotes: [WorkNoteID: PersistedWorkReportNote] = [:]
  private var weatherSnapshots: [WeatherSnapshotID: WeatherSnapshot] = [:]

  var onlyRecord: PersistedWorkReportRecord? {
    records.values.first
  }

  func save(_ record: PersistedWorkReportRecord) async throws -> WorkReportSaveResult {
    let result: WorkReportSaveResult
    if let current = records[record.report.dayID] {
      result = current == record ? .alreadyPresent : .updated
    } else {
      result = .inserted
    }
    records[record.report.dayID] = record
    revisionLineage(for: record)
    return result
  }

  func saveGenerated(
    _ record: PersistedWorkReportRecord,
    sources: WorkReportGenerationSources
  ) async throws -> WorkReportSaveResult {
    for note in sources.workNotes { workNotes[note.id] = note }
    for weather in sources.weatherSnapshots { weatherSnapshots[weather.id] = weather }
    return try await save(record)
  }

  func workNote(id: WorkNoteID) async throws -> PersistedWorkReportNote? { workNotes[id] }

  func weatherSnapshot(id: WeatherSnapshotID) async throws -> WeatherSnapshot? {
    weatherSnapshots[id]
  }

  private func revisionLineage(for record: PersistedWorkReportRecord) {
    var chain: [WorkReportRevision] = [record.currentRevision]
    var cursor = record.currentRevision.previousRevisionID
    while let id = cursor, let previous = revisionHistory[id] {
      chain.append(previous)
      cursor = previous.previousRevisionID
    }
    for revision in chain { revisionHistory[revision.id] = revision }
    revisionOrder[record.report.dayID] = chain.reversed().map(\.id)
  }

  func report(for dayID: DayID) async throws -> PersistedWorkReportRecord? {
    records[dayID]
  }

  func finalize(_ record: PersistedWorkReportRecord) async throws -> WorkReportSaveResult {
    guard record.report.status == .final else { throw WorkReportFinalizeError.invalidFinalization }
    guard let current = records[record.report.dayID] else {
      throw WorkReportFinalizeError.notFound
    }
    guard record.report.currentRevisionID == current.report.currentRevisionID,
      record.report.currentRevisionNumber == current.report.currentRevisionNumber,
      current.report.status == .draft
    else {
      throw current.report.status == .final
        ? WorkReportFinalizeError.alreadyFinalized
        : WorkReportFinalizeError.recordMismatch
    }
    records[record.report.dayID] = record
    return .updated
  }

  func revisions(for dayID: DayID) async throws -> [WorkReportRevision] {
    guard let order = revisionOrder[dayID] else { return [] }
    return order.compactMap { revisionHistory[$0] }
  }

  func tokenUsage(in interval: Range<Date>) async throws -> WorkReportTokenSummary {
    records.values.compactMap(\.modelUsage).reduce(.empty) { partial, usage in
      WorkReportTokenSummary(
        inputTokens: partial.inputTokens + (usage.inputTokens ?? 0),
        outputTokens: partial.outputTokens + (usage.outputTokens ?? 0),
        cachedInputTokens: partial.cachedInputTokens + (usage.cachedInputTokens ?? 0),
        totalTokens: partial.totalTokens + (usage.totalTokens ?? 0),
        attemptCount: partial.attemptCount + 1
      )
    }
  }

  func recentReports(limit: Int) async throws -> [PersistedWorkReportRecord] {
    Array(records.values.sorted { $0.report.updatedAt > $1.report.updatedAt }.prefix(limit))
  }
}

private actor RecordingWorkReportGenerator: WorkReportGenerating {
  private(set) var callCount = 0
  private(set) var lastContext: WorkReportContext?
  private(set) var lastCredential: String?
  private(set) var lastWritingPreferences: WorkReportWritingPreferences?
  private(set) var lastConfiguration: OpenAICompatibleProviderConfiguration?

  func generate(
    context: WorkReportContext,
    configuration: OpenAICompatibleProviderConfiguration,
    credential: String,
    writingPreferences: WorkReportWritingPreferences
  ) async throws -> ProviderWorkReportResponse {
    callCount += 1
    lastContext = context
    lastCredential = credential
    lastWritingPreferences = writingPreferences
    lastConfiguration = configuration
    return ProviderWorkReportResponse(
      requestID: "test-request",
      content: "今天完成了真实日报链路。",
      usage: ProviderReportedTokenUsage(promptTokens: 10, completionTokens: 6, totalTokens: 16),
      reasoningContentWasPresent: true
    )
  }
}

private final class WorkReportCredentialStore: ProviderCredentialStoring, @unchecked Sendable {
  private var value: String?

  init(value: String?) { self.value = value }

  func credential(for account: String) throws -> String? { value }
  func save(_ credential: String, for account: String) throws { value = credential }
  func removeCredential(for account: String) throws { value = nil }
}

private actor EmptyLinkedRepository: ObjectiveLinkedRecordRepository {
  func insert(_ event: ObjectiveEvent) async throws -> ObjectiveEventInsertResult {
    .alreadyPresent
  }
  func fetch(occurredIn range: Range<Date>) async throws -> [ObjectiveEvent] { [] }
  func insertApplicationContext(_ write: ApplicationContextWrite) async throws
    -> ObjectiveEventInsertResult
  { .alreadyPresent }
  func insertCollectorState(_ write: CollectorStateWrite) async throws
    -> ObjectiveEventInsertResult
  { .alreadyPresent }
  func insertCollectionSuppression(_ write: CollectionSuppressionWrite) async throws
    -> ObjectiveEventInsertResult
  { .alreadyPresent }
  func fetchApplicationContext(for eventID: EventID) async throws -> ApplicationContextRecord? {
    nil
  }
  func fetchCollectorState(for eventID: EventID) async throws -> CollectorStateRecord? { nil }
  func fetchCollectionSuppression(for eventID: EventID) async throws
    -> CollectionSuppressionRecord?
  { nil }
}

private actor MutableVisibleContentRepository: VisibleContentArchiveRepository {
  private var observations: [VisibleContentObservation] = []

  func replace(_ values: [VisibleContentObservation]) {
    observations = values
  }

  func append(contentsOf values: [VisibleContentObservation]) {
    observations.append(contentsOf: values)
  }

  func insert(_ observation: VisibleContentObservation) async throws -> DeepCaptureInsertResult {
    if observations.contains(where: { $0.id == observation.id }) { return .alreadyPresent }
    observations.append(observation)
    return .inserted
  }

  func fetchVisibleContent(observedIn range: Range<Date>) async throws
    -> [VisibleContentObservation]
  {
    observations.filter { range.contains($0.provenance.observedAt) }
  }
}

private actor ActivityLinkedRepository: ObjectiveLinkedRecordRepository {
  let events: [ObjectiveEvent]
  let contexts: [EventID: ApplicationContextRecord]

  init(events: [ObjectiveEvent], contexts: [EventID: ApplicationContextRecord]) {
    self.events = events
    self.contexts = contexts
  }

  func insert(_ event: ObjectiveEvent) async throws -> ObjectiveEventInsertResult {
    .alreadyPresent
  }
  func fetch(occurredIn range: Range<Date>) async throws -> [ObjectiveEvent] {
    events.filter { range.contains($0.occurredAt) }
  }
  func insertApplicationContext(_ write: ApplicationContextWrite) async throws
    -> ObjectiveEventInsertResult
  { .alreadyPresent }
  func insertCollectorState(_ write: CollectorStateWrite) async throws -> ObjectiveEventInsertResult
  { .alreadyPresent }
  func insertCollectionSuppression(_ write: CollectionSuppressionWrite) async throws
    -> ObjectiveEventInsertResult
  { .alreadyPresent }
  func fetchApplicationContext(for eventID: EventID) async throws -> ApplicationContextRecord? {
    contexts[eventID]
  }
  func fetchCollectorState(for eventID: EventID) async throws -> CollectorStateRecord? { nil }
  func fetchCollectionSuppression(for eventID: EventID) async throws -> CollectionSuppressionRecord?
  { nil }
}

private actor InMemoryDerivationRepository: UnderstandingDerivationRepository {
  enum Behavior: Equatable {
    case accept, readFailure, saveFailure, alwaysConflict, conflictThenAccept, reloadReplacement
  }
  private let behavior: Behavior
  private(set) var current: PersistedUnderstandingDerivation?
  private(set) var saveCallCount = 0

  init(behavior: Behavior = .accept) { self.behavior = behavior }

  func latest(for day: DayDescriptor) async throws -> PersistedUnderstandingDerivation? {
    if behavior == .readFailure { throw DerivationTestError.failed }
    return current
  }

  func saveAtomically(_ derivation: PersistedUnderstandingDerivation) async throws
    -> UnderstandingDerivationSaveResult
  {
    saveCallCount += 1
    switch behavior {
    case .accept:
      current = derivation
      return .inserted
    case .reloadReplacement:
      current = try Self.reloaded(derivation)
      return .inserted
    case .readFailure, .alwaysConflict:
      return .conflict
    case .saveFailure:
      throw DerivationTestError.failed
    case .conflictThenAccept:
      if saveCallCount == 1 {
        current = derivation
        return .conflict
      }
      current = derivation
      return .inserted
    }
  }

  private static func reloaded(
    _ derivation: PersistedUnderstandingDerivation
  ) throws -> PersistedUnderstandingDerivation {
    let activity = try #require(derivation.activities.first)
    let replacement = try Activity(
      id: activity.id,
      version: activity.version,
      startedAt: activity.startedAt,
      endedAt: activity.endedAt,
      sessionIDs: activity.sessionIDs,
      evidenceReferences: activity.evidenceReferences,
      title: "Durably reloaded activity",
      summary: "Durably reloaded summary",
      confidence: activity.confidence,
      reviewState: activity.reviewState,
      interpretation: activity.interpretation,
      lineage: activity.lineage
    )
    return try PersistedUnderstandingDerivation(
      sessionBatch: derivation.sessionBatch,
      activityBatch: ActivityDerivationBatch(
        day: derivation.day,
        derivationRevision: derivation.revision,
        activities: [replacement]
      )
    )
  }
}

private actor CancellingInitialReadDerivationRepository: UnderstandingDerivationRepository {
  private var didArrive = false
  private var arrivalWaiter: CheckedContinuation<Void, Never>?
  private var release: CheckedContinuation<Void, Never>?

  func latest(for day: DayDescriptor) async throws -> PersistedUnderstandingDerivation? {
    didArrive = true
    arrivalWaiter?.resume()
    arrivalWaiter = nil
    await withCheckedContinuation { release = $0 }
    throw CancellationError()
  }

  func saveAtomically(_ derivation: PersistedUnderstandingDerivation) async throws
    -> UnderstandingDerivationSaveResult
  {
    .inserted
  }

  func waitUntilInitialRead() async {
    guard !didArrive else { return }
    await withCheckedContinuation { arrivalWaiter = $0 }
  }

  func releaseInitialRead() {
    release?.resume()
    release = nil
  }
}

private enum DerivationTestError: Error { case failed }
