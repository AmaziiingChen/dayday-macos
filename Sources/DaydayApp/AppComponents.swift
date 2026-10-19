import AppKit
import DaydayAI
import DaydayCapture
import DaydayCore
import DaydayStorage
import OSLog
import SwiftUI

private let screenVisionLogger = Logger(
  subsystem: "app.dayday.local",
  category: "screen-vision"
)

private let productionBootstrapLogger = Logger(
  subsystem: "app.dayday.local",
  category: "production-bootstrap"
)

@MainActor
final class DaydayAppComposition: ObservableObject {
  let runtime: AppRuntimeModel
  let drafts: AppDraftStore
  let permissionOnboarding: PermissionOnboardingModel
  let appearance: AppearanceSettingsModel
  let weather: WeatherRuntime
  let dailyWorkScheduleSettings: DailyWorkScheduleSettingsModel
  let inputInsights: InputInsightsModel
  let applicationUsageInsights: ApplicationUsageInsightsModel
  let menuBarTimeline: MenuBarTimelineModel
  let menuBarInsights: MenuBarInsightsModel
  let providerSettings: ProviderSettingsModel
  let visionProviderSettings: VisionProviderSettingsModel
  let diagnostics: PipelineDiagnosticsModel
  let workReport: WorkReportGenerationModel
  let historicalTimeline: HistoricalTimelineModel
  let healthArchive: HealthArchiveModel
  let journal: JournalEntryModel
  let journalAI: JournalAIAssistantModel
  let journalHistory: JournalHistoryModel
  let journalFragments: JournalFragmentModel
  let journalAttachments: JournalAttachmentModel
  let journalLocations: JournalLocationModel
  private let screenCaptureRuntime: any ScreenCaptureConsentRuntimeControlling
  private let screenCaptureRelay: ScreenCaptureRuntimeRelay
  private let screenUnderstandingArchiveRelay: ScreenUnderstandingArchiveRelay
  private let screenVisionRuntime: ScreenVisionRuntime
  private let screenCaptureTargetResolver: ScreenCaptureTargetResolver
  private let inputRuntimeRelay: InputCollectionRuntimeRelay
  private let systemLifecycleBridge: SystemLifecycleBridge
  private var shutdownTask: Task<Void, Never>?
  private var productionBootstrapTask: Task<Void, Never>?
  private var productionRuntime: H1CollectionRuntime?
  private var foregroundDurationRuntime: ForegroundApplicationDurationRuntime?
  private var inputRuntime: InputCollectionRuntime?
  private var productionRuntimeUpdatesTask: Task<Void, Never>?
  private var foregroundDurationUpdatesTask: Task<Void, Never>?
  private var displayTargetRefreshTask: Task<Void, Never>?
  private var inputRollupTask: Task<Void, Never>?
  private var workReportScheduleTask: Task<Void, Never>?
  private var screenVisionRecoveryTask: Task<Void, Never>?
  private var productionStore: ProductionDataStore?
  private var applicationActivationObservers: [NSObjectProtocol] = []

  init(
    runtime: AppRuntimeModel = AppRuntimeModel(),
    drafts: AppDraftStore = AppDraftStore(),
    permissionOnboarding: PermissionOnboardingModel = PermissionOnboardingModel(),
    appearance: AppearanceSettingsModel = AppearanceSettingsModel(),
    screenCaptureRuntime: (any ScreenCaptureConsentRuntimeControlling)? = nil,
    lifecycleNotificationSource: (any SystemLifecycleNotificationSource)? = nil,
    shouldBootstrapProduction: Bool = true
  ) {
    self.runtime = runtime
    self.drafts = drafts
    self.permissionOnboarding = permissionOnboarding
    self.appearance = appearance
    self.weather = WeatherRuntime()
    let dailyWorkScheduleSettings = DailyWorkScheduleSettingsModel()
    self.dailyWorkScheduleSettings = dailyWorkScheduleSettings
    self.inputInsights = InputInsightsModel()
    self.applicationUsageInsights = ApplicationUsageInsightsModel()
    self.menuBarTimeline = MenuBarTimelineModel()
    self.menuBarInsights = MenuBarInsightsModel()
    let historicalTimeline = HistoricalTimelineModel()
    let providerSettings = ProviderSettingsModel(
      developmentCredentialSource: ProcessEnvironmentCredentialSource()
    )
    self.providerSettings = providerSettings
    let journal = JournalEntryModel()
    self.journal = journal
    self.journalAI = JournalAIAssistantModel(
      journal: journal,
      providerSettings: providerSettings
    )
    let workReport = WorkReportGenerationModel(
      providerSettings: providerSettings,
      workingDraftPersistence: WorkReportWorkingDraftFileStore.applicationSupportStore()
    )
    self.workReport = workReport
    providerSettings.setReportGenerationSettingsChangeHandler { [weak workReport] budget, preferences in
      workReport?.updateGenerationSettings(
        budget: budget,
        writingPreferences: preferences
      )
    }
    self.historicalTimeline = historicalTimeline
    self.healthArchive = HealthArchiveModel()
    self.journalHistory = JournalHistoryModel()
    self.journalFragments = JournalFragmentModel()
    self.journalAttachments = JournalAttachmentModel()
    self.journalLocations = JournalLocationModel()
    let screenUnderstandingArchiveRelay = ScreenUnderstandingArchiveRelay()
    self.screenUnderstandingArchiveRelay = screenUnderstandingArchiveRelay
    let visionProviderSettings = VisionProviderSettingsModel(
      developmentCredentialSource: ProcessEnvironmentCredentialSource()
    )
    self.visionProviderSettings = visionProviderSettings
    self.diagnostics = PipelineDiagnosticsModel()
    let screenVisionRuntime = ScreenVisionRuntime(
      provider: (try? visionProviderSettings.runtimeRequest()).map {
        ScreenVisionRuntime.Provider(
          configuration: $0.configuration,
          credential: $0.credential
        )
      }
    )
    self.screenVisionRuntime = screenVisionRuntime
    dailyWorkScheduleSettings.setChangeHandler { [weak workReport, weak runtime, weak inputInsights, weak menuBarTimeline, weak menuBarInsights, weak historicalTimeline] schedule in
      workReport?.updateDailySchedule(schedule)
      runtime?.updateLogicalDayBoundary(schedule.workdayBoundary)
      inputInsights?.updateWorkdayBoundary(schedule.workdayBoundary)
      menuBarTimeline?.updateWorkdayBoundary(schedule.workdayBoundary)
      menuBarInsights?.updateWorkdayBoundary(schedule.workdayBoundary)
      historicalTimeline?.updateWorkdayBoundary(schedule.workdayBoundary)
      Task { await screenVisionRuntime.updateWorkdayBoundary(schedule.workdayBoundary) }
    }
    Task {
      await screenVisionRuntime.updateWorkdayBoundary(
        dailyWorkScheduleSettings.currentSchedule.workdayBoundary)
    }
    visionProviderSettings.setConfigurationChangeHandler { request in
      Task {
        await screenVisionRuntime.configure(
          request.map {
            ScreenVisionRuntime.Provider(
              configuration: $0.configuration,
              credential: $0.credential
            )
          })
      }
    }
    let screenOutputHandler: ScreenCaptureStream.OutputHandler = { output in
      switch output {
      case .recognizedText:
        Task { await screenUnderstandingArchiveRelay.receive(output) }
      case .visionDerivative(let derivative):
        Task { await screenVisionRuntime.receive(derivative) }
      case .availability, .frame:
        break
      }
    }
    let resolvedScreenCaptureRuntime =
      screenCaptureRuntime
      ?? MultiDisplayScreenCaptureRuntime(outputHandler: screenOutputHandler)
    self.screenCaptureRuntime = resolvedScreenCaptureRuntime
    self.screenCaptureTargetResolver = ScreenCaptureTargetResolver()

    let notificationSource =
      lifecycleNotificationSource
      ?? NSWorkspaceSystemLifecycleNotificationSource()
    let initialAvailability = notificationSource.currentAvailability()
    let screenCaptureRelay = ScreenCaptureRuntimeRelay(
      runtime: resolvedScreenCaptureRuntime,
      availability: initialAvailability,
      isHostApplicationActive: ScreenCaptureForegroundPolicy.isHostInteractionActive(
        applicationIsActive: NSRunningApplication.current.isActive,
        hasKeyWindow: NSApplication.shared.keyWindow != nil
      )
    )
    self.screenCaptureRelay = screenCaptureRelay
    Task { [weak screenCaptureRelay] in
      await screenVisionRuntime.setCaptureAnchorHandler {
        screenCaptureRelay?.requestVisualAnchor()
      }
    }
    let inputRuntimeRelay = InputCollectionRuntimeRelay(availability: initialAvailability)
    self.inputRuntimeRelay = inputRuntimeRelay

    let coordinator = CollectorCoordinator()
    let transitionHandler: SystemLifecycleBridge.TransitionHandler = {
      event, _ in
      screenCaptureRelay.receive(event)
      inputRuntimeRelay.receive(event)
    }
    systemLifecycleBridge = SystemLifecycleBridge(
      coordinator: coordinator,
      notificationSource: notificationSource,
      onTransition: transitionHandler
    )

    applicationActivationObservers = [
      NotificationCenter.default.addObserver(
        forName: NSApplication.didBecomeActiveNotification,
        object: nil,
        queue: .main
      ) { [weak screenCaptureRelay] _ in
        Task { @MainActor in
          await Task.yield()
          screenCaptureRelay?.refreshHostInteractionState()
        }
      },
      NotificationCenter.default.addObserver(
        forName: NSApplication.didResignActiveNotification,
        object: nil,
        queue: .main
      ) { [weak screenCaptureRelay] _ in
        Task { @MainActor in
          await Task.yield()
          screenCaptureRelay?.refreshHostInteractionState()
        }
      },
      NotificationCenter.default.addObserver(
        forName: NSWindow.didBecomeKeyNotification,
        object: nil,
        queue: .main
      ) { [weak screenCaptureRelay] _ in
        Task { @MainActor in
          await Task.yield()
          screenCaptureRelay?.refreshHostInteractionState()
        }
      },
      NotificationCenter.default.addObserver(
        forName: NSWindow.didResignKeyNotification,
        object: nil,
        queue: .main
      ) { [weak screenCaptureRelay] _ in
        Task { @MainActor in
          await Task.yield()
          screenCaptureRelay?.refreshHostInteractionState()
        }
      },
    ]

    // SwiftUI may construct the composition after AppKit has already posted the launch-time
    // activation/key-window notifications. Reconcile once on the next main-actor turn so that a
    // missed startup edge cannot leave OCR running while the user is typing in Dayday.
    Task { @MainActor [weak screenCaptureRelay] in
      await Task.yield()
      screenCaptureRelay?.refreshHostInteractionState()
    }

    permissionOnboarding.setScreenCaptureConsentChangeHandler { consent in
      screenCaptureRelay.publish(consent)
    }
    permissionOnboarding.setWeatherConsentChangeHandler { [weather] consent in
      weather.applyProductConsent(consent)
    }
    screenCaptureRelay.publishAvailability()
    systemLifecycleBridge.start()
    weather.start()
    if shouldBootstrapProduction {
      startProductionBootstrap()
    }
  }

  /// Explicit aliases make the shared identity contract testable. Both
  /// surfaces observe one model rather than constructing permission state.
  var mainWindowPermissionModel: PermissionOnboardingModel { permissionOnboarding }
  var menuBarPermissionModel: PermissionOnboardingModel { permissionOnboarding }

  /// Application-lifetime teardown. This is invoked from the application
  /// delegate's termination handshake, never from a disappearing view.
  func shutdown() async {
    drafts.flushPendingWorkNoteSave()
    await journal.flushPendingAutosave()
    if let shutdownTask {
      await shutdownTask.value
      return
    }

    permissionOnboarding.setScreenCaptureConsentChangeHandler(nil)
    runtime.setCollectionGateRefresher(nil)
    for observer in applicationActivationObservers {
      NotificationCenter.default.removeObserver(observer)
    }
    applicationActivationObservers.removeAll()
    productionBootstrapTask?.cancel()
    productionRuntimeUpdatesTask?.cancel()
    foregroundDurationUpdatesTask?.cancel()
    displayTargetRefreshTask?.cancel()
    inputRollupTask?.cancel()
    workReportScheduleTask?.cancel()
    screenVisionRecoveryTask?.cancel()
    await screenVisionRuntime.stopObjectiveContextAnchoring()
    await inputRuntime?.shutdown()
    await foregroundDurationRuntime?.shutdown()
    await productionRuntime?.shutdown()
    weather.stop()
    systemLifecycleBridge.teardown()
    let relay = screenCaptureRelay
    let task = Task { await relay.shutdown() }
    shutdownTask = task
    await task.value
  }

  /// Pending vision work may require a remote model round trip. It must never
  /// delay startup of local keyboard, pointer, or application collection.
  private func resumePendingScreenVisionEvidence(
    from repository: any ScreenVisionPendingEvidenceRepository
  ) {
    screenVisionRecoveryTask?.cancel()
    let visionRuntime = screenVisionRuntime
    screenVisionRecoveryTask = Task {
      guard !Task.isCancelled else { return }
      await visionRuntime.attachPendingEvidenceRepository(repository)
    }
  }

  /// Opens and validates durable storage before H1 exists. All fallible disk
  /// work is detached from MainActor; an early failure publishes only a
  /// presentation-safe failure and never constructs a producer runtime.
  private func startProductionBootstrap() {
    productionBootstrapTask = Task { [weak self] in
      let store = await Task.detached(priority: .utility) {
        () -> ProductionDataStore? in
        do {
          let store = try ProductionDataStore.open()
          try await store.verifyWritable()
          try await store.collectionStopIntents.replay(using: store.collectionConsents)
          return store
        } catch {
          productionBootstrapLogger.error(
            "Unable to open the local production store: \(String(describing: error), privacy: .public)"
          )
          return nil
        }
      }.value

      guard !Task.isCancelled, let self else { return }
      guard let store else {
        runtime.reportProductionBootstrapFailure()
        return
      }

      // Restore the durable product choices before any optional vision startup
      // work. A slow or unavailable vision path must never make the app look
      // like it forgot the user's enabled keyboard, pointer, or app-context
      // collectors, nor block their historical data from being presented.
      do {
        for collector in CollectorKind.allCases {
          let persisted = try await store.collectionConsents.consent(for: collector)
          permissionOnboarding.applyPersistedConsent(persisted)
          applyPersistedCollectorRuntime(
            persisted.consent,
            restoration: true
          )
        }
      } catch {
        productionBootstrapLogger.error(
          "Unable to restore local collector controls: \(String(describing: error), privacy: .public)"
        )
        runtime.reportProductionBootstrapFailure()
        return
      }

      let hostBundleIdentifierExclusions = Set(
        [Bundle.main.bundleIdentifier].compactMap { $0 }
      )
      let h1Runtime = H1CollectionRuntime(
        repository: store.objectiveEvents,
        consentRepository: store.collectionConsents,
        excludedBundleIdentifiers: hostBundleIdentifierExclusions,
        resolveApplication: { bundleIdentifier, displayLabel in
          try await store.objectiveEvents.resolveApplication(
            bundleIdentifier: bundleIdentifier,
            displayLabel: displayLabel
          ).identifier
        }
      )
      let foregroundDurationRuntime = ForegroundApplicationDurationRuntime(
        repository: store.objectiveEvents,
        consentRepository: store.collectionConsents,
        resolveApplication: { bundleIdentifier, displayLabel in
          try await store.objectiveEvents.resolveApplication(
            bundleIdentifier: bundleIdentifier,
            displayLabel: displayLabel
          ).identifier
        }
      )
      productionStore = store
      productionRuntime = h1Runtime
      self.foregroundDurationRuntime = foregroundDurationRuntime
      runtime.setCollectionGateRefresher {
        await h1Runtime.refreshGates()
        await foregroundDurationRuntime.refreshGates()
      }
      await screenUnderstandingArchiveRelay.attach(store.deepCaptureArchive)
      await screenVisionRuntime.attach(store.deepCaptureArchive)
      await screenVisionRuntime.attachUsageRepository(store.deepCaptureArchive)
      await screenVisionRuntime.attachObjectiveRepository(store.objectiveEvents)
      await screenVisionRuntime.startObjectiveContextAnchoring()
      diagnostics.configure(
        visibleContent: store.deepCaptureArchive,
        textProduction: store.deepCaptureArchive,
        visionUsage: store.deepCaptureArchive
      )
      await screenVisionRuntime.setTraceHandler { [weak diagnostics] trace in
        diagnostics?.applyScreenVisionTrace(trace)
      }
      await screenVisionRuntime.setArchiveChangeHandler { [weak runtime] in
        runtime?.visualInferenceArchiveChanged()
      }
      do {
        permissionOnboarding.setApplicationWindowControlHandler { [weak self] action in
          guard let self else { throw AppProductionControlError.runtimeUnavailable }
          return try await self.applyApplicationWindowControl(action)
        }
        let screenVisionRuntime = self.screenVisionRuntime
        let inputRuntime = try InputCollectionRuntime(
          checkpoints: store.inputAggregates,
          consents: store.collectionConsents,
          excludedBundleIdentifiers: hostBundleIdentifierExclusions,
          submissionAnchorDidOccur: {
            await screenVisionRuntime.recordSubmissionAnchor()
          }
        )
        self.inputRuntime = inputRuntime
        inputRuntimeRelay.attach(inputRuntime)
        inputInsights.configure(
          repository: store.inputAggregates,
          runtime: inputRuntime,
          workdayBoundary: dailyWorkScheduleSettings.currentSchedule.workdayBoundary
        )
        applicationUsageInsights.configure(repository: store.objectiveEvents)
        menuBarTimeline.configure(
          repository: store.objectiveEvents,
          workdayBoundary: dailyWorkScheduleSettings.currentSchedule.workdayBoundary
        )
        menuBarInsights.configure(
          inputRepository: store.inputAggregates,
          objectiveRepository: store.objectiveEvents,
          inputRuntime: inputRuntime,
          workdayBoundary: dailyWorkScheduleSettings.currentSchedule.workdayBoundary
        )
        permissionOnboarding.setInputControlHandler { [weak self] collector, action in
          guard let self else { throw AppProductionControlError.runtimeUnavailable }
          return try await self.applyInputControl(collector: collector, action: action)
        }
        permissionOnboarding.setInputGateRefreshHandler { [weak self] in
          Task { await self?.inputRuntime?.refreshGates() }
        }
        permissionOnboarding.setPersistedCollectorControlHandler {
          [weak self]
          collector, action in
          guard let self else { throw AppProductionControlError.runtimeUnavailable }
          return try await self.applyPersistedCollectorControl(
            collector: collector, action: action
          )
        }

      } catch {
        productionBootstrapLogger.error(
          "Unable to start the local collection runtime: \(String(describing: error), privacy: .public)"
        )
        runtime.reportProductionBootstrapFailure()
        return
      }
      let screenVisionRuntime = self.screenVisionRuntime
      productionRuntimeUpdatesTask = Task { [weak runtime] in
        for await snapshot in h1Runtime.statusUpdates() {
          guard !Task.isCancelled else { return }
          runtime?.applyH1Snapshot(snapshot)
          await screenVisionRuntime.inspectObjectiveContextChanges()
        }
      }
      foregroundDurationUpdatesTask = Task { [weak applicationUsageInsights, weak menuBarInsights] in
        for await _ in foregroundDurationRuntime.historyRevisionUpdates() {
          guard !Task.isCancelled else { return }
          applicationUsageInsights?.refreshForForegroundFactChange()
          menuBarInsights?.foregroundFactsDidChange()
        }
      }
      await h1Runtime.start()
      await foregroundDurationRuntime.start()
      await inputRuntime?.start(sessionAvailable: inputRuntimeRelay.isAvailable)
      resumePendingScreenVisionEvidence(from: store.deepCaptureArchive)
      screenCaptureRelay.refreshHostInteractionState()
      if screenCaptureRelay.shouldRefreshDisplayTargets {
        let targets = await screenCaptureTargetResolver.onlineDisplayTargets()
        screenCaptureRelay.publishTargets(targets)
      }
      displayTargetRefreshTask = Task { [weak self] in
        while !Task.isCancelled {
          do { try await Task.sleep(for: .seconds(5)) } catch { return }
          guard let self, !Task.isCancelled else { return }
          // The notification path is immediate; this cheap synchronous reconciliation closes the
          // launch/Space-transition race before performing the expensive display-topology query.
          screenCaptureRelay.refreshHostInteractionState()
          guard screenCaptureRelay.shouldRefreshDisplayTargets else { continue }
          let targets = await screenCaptureTargetResolver.onlineDisplayTargets()
          screenCaptureRelay.publishTargets(targets)
        }
      }
      runtime.configureToday(
        repository: store.objectiveEvents,
        visualInferenceRepository: store.deepCaptureArchive
      )
      workReport.configure(
        repository: store.objectiveEvents,
        reportRepository: store.workReports,
        visualInferenceRepository: store.deepCaptureArchive,
        understandingDerivationRepository: store.understandingDerivations,
        budget: providerSettings.currentBudget ?? .unlimited,
        writingPreferences: providerSettings.currentWritingPreferences,
        dailySchedule: dailyWorkScheduleSettings.currentSchedule
      )
      historicalTimeline.configure(
        repository: store.objectiveEvents,
        linkedRepository: store.objectiveEvents,
        visualInferenceRepository: store.deepCaptureArchive,
        boundary: dailyWorkScheduleSettings.currentSchedule.workdayBoundary
      )
      healthArchive.configure(repository: store.healthArchive)
      journal.setPersistedRecordHandler { [weak journalHistory] record in
        journalHistory?.integrate(record)
      }
      journal.configure(repository: store.journalEntries)
      journalAI.configure(repository: store.journalEntries)
      journalHistory.configure(repository: store.journalEntries)
      journalFragments.configure(repository: store.journalFragments)
      journalAttachments.configure(
        repository: store.journalAttachments,
        fileStore: store.journalAttachmentFiles,
        journal: journal
      )
      journalLocations.configure(repository: store.journalLocationSnapshots, journal: journal)
      startInputRollupMaintenance(repository: store.inputAggregates)
      startWorkReportSchedule()
    }
  }

  /// Periodically coalesces hourly input aggregates older than the retention
  /// window into idempotent daily rows and prunes the consumed hours. It runs
  /// shortly after production startup and repeats on a fixed cadence; the
  /// storage apply is atomic and plan IDs are deterministic, so re-runs are
  /// safe even after an interruption or time-zone change.
  private func startInputRollupMaintenance(repository: SQLiteInputAggregateRepository) {
    inputRollupTask?.cancel()
    inputRollupTask = Task { [weak self] in
      await self?.runInputRollupPass(repository: repository)
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(Self.inputRollupCadence)) } catch { return }
        guard let self, !Task.isCancelled else { return }
        await self.runInputRollupPass(repository: repository)
      }
    }
  }

  private static let inputRollupCadence: Int64 = 6 * 60 * 60

  private func runInputRollupPass(repository: SQLiteInputAggregateRepository) async {
    let now = Date()
    let timeZoneIdentifier = TimeZone.autoupdatingCurrent.identifier
    let boundaryHour = dailyWorkScheduleSettings.currentSchedule.logicalDayBoundaryHour
    let cutoff: Date
    do {
      cutoff = try InputAggregationPolicy.hourlyRollupCutoff(
        relativeTo: now,
        timeZoneIdentifier: timeZoneIdentifier,
        workdayBoundaryHour: boundaryHour,
        retentionDays: InputAggregationPolicy.defaultHourlyRetentionDays
      )
    } catch {
      return
    }
    let hours: [InputAggregate]
    do {
      hours = try await repository.fetchHoursEndingBefore(cutoff)
    } catch {
      return
    }
    let plans: [DailyInputRollupPlan]
    do {
      plans = try InputAggregationPolicy.dailyRollupPlans(
        for: hours,
        cutoff: cutoff,
        workdayBoundaryHour: boundaryHour
      )
    } catch {
      return
    }
    for plan in plans {
      do {
        _ = try await repository.apply(plan)
      } catch {
        // One failed day must not abort the remaining rollups. The atomic apply
        // already left the affected hours untouched for a later retry.
        continue
      }
    }
  }

  /// Fires an unattended, once-a-day report generation after the configured report time, but only when
  /// no draft exists yet for the current logical day and a provider is configured. Local collection
  /// is never affected by this task.
  private func startWorkReportSchedule() {
    workReportScheduleTask?.cancel()
    workReportScheduleTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let self, !Task.isCancelled else { return }
        await self.runWorkReportSchedulePass()
        do { try await Task.sleep(for: Self.workReportScheduleCadence) } catch { return }
      }
    }
  }

  private static let workReportScheduleCadence: Duration = .seconds(60)

  private func runWorkReportSchedulePass() async {
    let configured = dailyWorkScheduleSettings.currentSchedule
    let schedule = WorkReportAutoSchedule(generatesAt: configured.reportGeneratesAt)
    guard
      schedule.isDue(now: Date())
    else { return }
    let weatherSnapshot = workReport.dayDescriptor().flatMap(weather.workReportSnapshot)
    await workReport.generateIfScheduledAndAbsent(
      workNote: "",
      weatherSnapshot: weatherSnapshot
    )
  }

  private func applyApplicationWindowControl(
    _ action: CollectorConsentAction
  ) async throws -> PersistedCollectorConsent {
    guard let productionStore, let productionRuntime else {
      throw AppProductionControlError.runtimeUnavailable
    }
    let current = try await productionStore.collectionConsents.consent(
      for: .applicationWindowContext
    )

    switch action {
    case .enable, .resume:
      let updated = try await productionStore.collectionConsents.transition(
        action, expectedRevision: current.revision
      )
      await productionRuntime.refreshGates()
      await foregroundDurationRuntime?.refreshGates()
      return updated
    case .pause(let confirmation), .disable(let confirmation):
      let pending: H1PendingNegativeControl =
        switch action {
        case .pause: .pause
        case .disable: .disable
        default: preconditionFailure("Only negative controls reach this branch")
        }
      guard await productionRuntime.beginPendingNegativeControl(pending) else {
        throw AppProductionControlError.runtimeUnavailable
      }
      await foregroundDurationRuntime?.holdForNegativeControl()
      do {
        let target: CollectionStopTarget =
          pending == .pause
          ? .collectorPaused : .collectorDisabled
        let intent = try CollectionStopIntent(
          scope: .collector(.applicationWindowContext), target: target,
          confirmation: confirmation, expectedRevision: current.revision,
          targetRevision: current.revision + 1
        )
        try await productionStore.collectionStopIntents.create(intent)
        let updated = try await productionStore.collectionConsents.transition(
          action, expectedRevision: current.revision
        )
        try await productionStore.collectionStopIntents.replay(
          using: productionStore.collectionConsents
        )
        await productionRuntime.endPendingNegativeControlAndRefresh()
        await foregroundDurationRuntime?.refreshGates()
        return updated
      } catch {
        productionRuntime.markPendingNegativeControlPersistenceFailed()
        throw error
      }
    }
  }

  private func applyInputControl(
    collector: CollectorKind,
    action: CollectorConsentAction
  ) async throws -> PersistedCollectorConsent {
    guard collector == .keyboardAggregates || collector == .pointerAggregates,
      let productionStore, let inputRuntime
    else {
      throw AppProductionControlError.runtimeUnavailable
    }
    let current = try await productionStore.collectionConsents.consent(for: collector)
    switch action {
    case .enable, .resume:
      let updated = try await productionStore.collectionConsents.transition(
        action, expectedRevision: current.revision
      )
      await inputRuntime.refreshGates()
      return updated
    case .pause(let confirmation), .disable(let confirmation):
      await inputRuntime.holdForNegativeControl()
      let target: CollectionStopTarget =
        switch action {
        case .pause: .collectorPaused
        case .disable: .collectorDisabled
        default: preconditionFailure("Only negative input controls reach this branch")
        }
      let intent = try CollectionStopIntent(
        scope: .collector(collector), target: target, confirmation: confirmation,
        expectedRevision: current.revision, targetRevision: current.revision + 1
      )
      do {
        try await productionStore.collectionStopIntents.create(intent)
        let updated = try await productionStore.collectionConsents.transition(
          action, expectedRevision: current.revision
        )
        try await productionStore.collectionStopIntents.replay(
          using: productionStore.collectionConsents
        )
        await inputRuntime.refreshGates()
        return updated
      } catch {
        await inputRuntime.holdForNegativeControl()
        throw error
      }
    }
  }

  /// Persists the Settings-only collectors that have no dedicated producer
  /// control path. Screen and weather receive their runtime update as well;
  /// calendar, reminders, and Chrome currently retain only the explicit
  /// decision until their collectors are connected.
  private func applyPersistedCollectorControl(
    collector: CollectorKind,
    action: CollectorConsentAction
  ) async throws -> PersistedCollectorConsent {
    guard collector != .applicationWindowContext,
      collector != .keyboardAggregates,
      collector != .pointerAggregates,
      let productionStore
    else {
      throw AppProductionControlError.runtimeUnavailable
    }

    let current = try await productionStore.collectionConsents.consent(for: collector)
    switch action {
    case .enable, .resume:
      let updated = try await productionStore.collectionConsents.transition(
        action, expectedRevision: current.revision
      )
      applyPersistedCollectorRuntime(updated.consent, restoration: false)
      return updated
    case .pause(let confirmation), .disable(let confirmation):
      let stopped = try CollectorConsentStateMachine.transition(action, from: current.consent)
      applyPersistedCollectorRuntime(stopped, restoration: false)
      let target: CollectionStopTarget =
        switch action {
        case .pause: .collectorPaused
        case .disable: .collectorDisabled
        default: preconditionFailure("Only negative controls reach this branch")
        }
      let intent = try CollectionStopIntent(
        scope: .collector(collector), target: target, confirmation: confirmation,
        expectedRevision: current.revision, targetRevision: current.revision + 1
      )
      try await productionStore.collectionStopIntents.create(intent)
      let updated = try await productionStore.collectionConsents.transition(
        action, expectedRevision: current.revision
      )
      try await productionStore.collectionStopIntents.replay(
        using: productionStore.collectionConsents
      )
      return updated
    }
  }

  /// Restoring a saved choice is intentionally non-prompting. The explicit
  /// weather enable action remains the sole source of a location request.
  private func applyPersistedCollectorRuntime(
    _ consent: CollectorConsent,
    restoration: Bool
  ) {
    switch consent.collector {
    case .screenUnderstanding:
      screenCaptureRelay.publish(consent)
    case .weather:
      if restoration {
        weather.restoreProductConsent(consent)
      } else {
        weather.applyProductConsent(consent)
      }
    default:
      break
    }
  }
}

private enum AppProductionControlError: Error {
  case runtimeUnavailable
}

/// Forwards lifecycle availability to Input Capture once production storage is
/// ready. It intentionally carries no key, pointer, or foreground data.
@MainActor
private final class InputCollectionRuntimeRelay {
  private var isUserSessionActive: Bool
  private var areScreensAwake: Bool
  private var isSystemAwake = true
  private weak var runtime: InputCollectionRuntime?

  init(availability: SystemLifecycleAvailability) {
    isUserSessionActive = availability.isUserSessionActive
    areScreensAwake = availability.areScreensAwake
  }

  var isAvailable: Bool { isUserSessionActive && areScreensAwake && isSystemAwake }

  func attach(_ runtime: InputCollectionRuntime) {
    self.runtime = runtime
    Task { await runtime.setSessionAvailable(isAvailable) }
  }

  func receive(_ event: SystemLifecycleEvent) {
    switch event {
    case .systemWillSleep: isSystemAwake = false
    case .systemDidWake: isSystemAwake = true
    case .userSessionDidResignActive: isUserSessionActive = false
    case .userSessionDidBecomeActive: isUserSessionActive = true
    case .screensDidSleep: areScreensAwake = false
    case .screensDidWake: areScreensAwake = true
    }
    guard let runtime else { return }
    Task { await runtime.setSessionAvailable(isAvailable) }
  }
}

protocol ScreenCaptureConsentRuntimeControlling: Sendable {
  func updateConsent(_ updated: CollectorConsent) async throws
  func setDisplayTargets(_ updated: [ScreenCaptureDisplayTarget]) async
  func setSessionAvailable(_ available: Bool) async
  func requestVisualAnchor() async
  func shutdown() async
}

extension ScreenCaptureConsentRuntime: ScreenCaptureConsentRuntimeControlling {
  func setDisplayTargets(_ updated: [ScreenCaptureDisplayTarget]) async {
    await setDisplayTarget(updated.first)
  }
}

private actor MultiDisplayScreenCaptureRuntime: ScreenCaptureConsentRuntimeControlling {
  private let outputHandler: ScreenCaptureStream.OutputHandler
  private var runtimes: [DisplayID: ScreenCaptureConsentRuntime] = [:]
  private var consent = CollectorConsent(collector: .screenUnderstanding)
  private var sessionAvailable = false
  private var isShutdown = false

  init(outputHandler: @escaping ScreenCaptureStream.OutputHandler) {
    self.outputHandler = outputHandler
  }

  func updateConsent(_ updated: CollectorConsent) async throws {
    guard !isShutdown else { return }
    consent = updated
    for runtime in runtimes.values { try await runtime.updateConsent(updated) }
  }

  func setDisplayTargets(_ updated: [ScreenCaptureDisplayTarget]) async {
    guard !isShutdown else { return }
    let next = Dictionary(uniqueKeysWithValues: updated.map { ($0.display.id, $0) })
    let removed = runtimes.keys.filter { next[$0] == nil }
    var removedRuntimes: [ScreenCaptureConsentRuntime] = []
    for id in removed {
      if let runtime = runtimes.removeValue(forKey: id) { removedRuntimes.append(runtime) }
    }
    // Every display may own an expensive Vision request. Stop them concurrently so an external
    // monitor cannot keep consuming a core while another display waits for SCStream teardown.
    await withTaskGroup(of: Void.self) { group in
      for runtime in removedRuntimes {
        group.addTask { await runtime.shutdown() }
      }
    }
    for (id, target) in next {
      let runtime: ScreenCaptureConsentRuntime
      if let existing = runtimes[id] {
        runtime = existing
      } else {
        runtime = ScreenCaptureConsentRuntime(outputHandler: outputHandler)
        runtimes[id] = runtime
        try? await runtime.updateConsent(consent)
        await runtime.setSessionAvailable(sessionAvailable)
      }
      await runtime.setDisplayTarget(target)
    }
  }

  func setSessionAvailable(_ available: Bool) async {
    guard !isShutdown else { return }
    sessionAvailable = available
    for runtime in runtimes.values { await runtime.setSessionAvailable(available) }
  }

  func requestVisualAnchor() async {
    guard !isShutdown else { return }
    for runtime in runtimes.values { await runtime.requestVisualAnchor() }
  }

  func shutdown() async {
    guard !isShutdown else { return }
    isShutdown = true
    let current = Array(runtimes.values)
    runtimes.removeAll()
    await withTaskGroup(of: Void.self) { group in
      for runtime in current {
        group.addTask { await runtime.shutdown() }
      }
    }
  }
}

enum ScreenCaptureForegroundPolicy {
  static func isHostInteractionActive(
    applicationIsActive: Bool,
    hasKeyWindow: Bool
  ) -> Bool {
    applicationIsActive || hasKeyWindow
  }

  static func effectiveTargets<T>(
    _ targets: [T],
    isHostApplicationActive: Bool
  ) -> [T] {
    isHostApplicationActive ? [] : targets
  }

  static func shouldRefreshDisplayTargets(isHostApplicationActive: Bool) -> Bool {
    !isHostApplicationActive
  }
}

/// Serializes synchronous MainActor composition facts before they cross into
/// the Capture actor, so a stale enable/wake cannot overtake a later pause/sleep.
@MainActor
private final class ScreenCaptureRuntimeRelay {
  private let runtime: any ScreenCaptureConsentRuntimeControlling
  private var isUserSessionActive: Bool
  private var areScreensAwake: Bool
  private var isSystemAwake = true
  private var isHostApplicationActive: Bool
  private var latestTargets: [ScreenCaptureDisplayTarget] = []
  private var lastDeliveredTargets: [ScreenCaptureDisplayTarget]?
  private var deliveryTask: Task<Void, Never>?
  private var shutdownTask: Task<Void, Never>?
  private var isShutdown = false

  var shouldRefreshDisplayTargets: Bool {
    !isShutdown
      && isSystemAwake
      && isUserSessionActive
      && areScreensAwake
      && ScreenCaptureForegroundPolicy.shouldRefreshDisplayTargets(
        isHostApplicationActive: isHostApplicationActive
      )
  }

  init(
    runtime: any ScreenCaptureConsentRuntimeControlling,
    availability: SystemLifecycleAvailability,
    isHostApplicationActive: Bool
  ) {
    self.runtime = runtime
    self.isUserSessionActive = availability.isUserSessionActive
    self.areScreensAwake = availability.areScreensAwake
    self.isHostApplicationActive = isHostApplicationActive
  }

  func publish(_ consent: CollectorConsent) {
    guard !isShutdown else { return }
    let previous = deliveryTask
    let runtime = self.runtime
    deliveryTask = Task { @MainActor [weak self] in
      await previous?.value
      guard let self, !self.isShutdown, !Task.isCancelled else { return }
      do {
        try await runtime.updateConsent(consent)
      } catch {
        assertionFailure("Composition forwarded non-screen consent to Capture")
      }
    }
  }

  func receive(_ event: SystemLifecycleEvent) {
    guard !isShutdown else { return }
    switch event {
    case .systemWillSleep:
      isSystemAwake = false
    case .systemDidWake:
      isSystemAwake = true
    case .userSessionDidResignActive:
      isUserSessionActive = false
    case .userSessionDidBecomeActive:
      isUserSessionActive = true
    case .screensDidSleep:
      areScreensAwake = false
    case .screensDidWake:
      areScreensAwake = true
    }
    publishAvailability()
  }

  func publishAvailability() {
    guard !isShutdown else { return }
    let available = isSystemAwake && isUserSessionActive && areScreensAwake
    let previous = deliveryTask
    let runtime = self.runtime
    deliveryTask = Task { @MainActor [weak self] in
      await previous?.value
      guard let self, !self.isShutdown, !Task.isCancelled else { return }
      await runtime.setSessionAvailable(available)
    }
  }

  func publishTargets(_ targets: [ScreenCaptureDisplayTarget]) {
    latestTargets = targets
    publishEffectiveTargets()
  }

  func setHostApplicationActive(_ active: Bool) {
    guard isHostApplicationActive != active else { return }
    isHostApplicationActive = active
    publishEffectiveTargets()
  }

  func refreshHostInteractionState() {
    setHostApplicationActive(
      ScreenCaptureForegroundPolicy.isHostInteractionActive(
        applicationIsActive: NSRunningApplication.current.isActive,
        hasKeyWindow: NSApplication.shared.keyWindow != nil
      ))
  }

  private func publishEffectiveTargets() {
    guard !isShutdown else { return }
    let targets = ScreenCaptureForegroundPolicy.effectiveTargets(
      latestTargets,
      isHostApplicationActive: isHostApplicationActive
    )
    guard lastDeliveredTargets != targets else { return }
    lastDeliveredTargets = targets
    let previous = deliveryTask
    let runtime = self.runtime
    deliveryTask = Task { @MainActor [weak self] in
      await previous?.value
      guard let self, !self.isShutdown, !Task.isCancelled else { return }
      await runtime.setDisplayTargets(targets)
    }
  }

  /// A request carries no input or screen payload and coalesces in each capture stream.
  func requestVisualAnchor() {
    guard !isShutdown, !isHostApplicationActive else { return }
    let runtime = self.runtime
    Task { await runtime.requestVisualAnchor() }
  }

  func shutdown() async {
    if let shutdownTask {
      await shutdownTask.value
      return
    }

    isShutdown = true
    deliveryTask?.cancel()
    deliveryTask = nil
    let runtime = self.runtime
    let task = Task { await runtime.shutdown() }
    shutdownTask = task
    await task.value
  }
}

actor ScreenUnderstandingArchiveRelay {
  private var repository: (any VisibleContentArchiveRepository)?

  func attach(_ repository: any VisibleContentArchiveRepository) {
    self.repository = repository
  }

  func receive(_ output: ScreenCaptureStreamOutput) async {
    guard case .recognizedText(let observation) = output,
      let repository
    else { return }
    do {
      let provenance = try VisibleContentProvenance(
        source: CollectorSource(
          collector: .screenUnderstanding,
          collectorVersion: "apple-vision-ocr-v1",
          payloadSchemaVersion: 1
        ),
        observedAt: observation.frame.observedAt,
        timeZoneIdentifier: TimeZone.current.identifier,
        display: observation.frame.display
      )
      let archived: VisibleContentObservation
      if observation.lines.isEmpty {
        archived = try VisibleContentObservation(
          provenance: provenance,
          kind: .objectiveText,
          redactionState: .excluded,
          suppressionReason: .mandatoryExclusion
        )
      } else {
        archived = try VisibleContentObservation(
          provenance: provenance,
          kind: .objectiveText,
          classification: .ordinaryVisibleContent,
          redactionState: observation.redactionApplied ? .redacted : .noRedactionNeeded,
          text: observation.lines.map(\.value).joined(separator: "\n")
        )
      }
      _ = try await repository.insert(archived)
    } catch {
      // Capture must stay alive if one OCR result cannot be archived. No raw or derived
      // content is logged here; a later diagnostics slice can expose a bounded error code.
    }
  }
}

actor ScreenVisionRuntime {
  struct Timing: Sendable {
    let partialWindowFlushDelay: TimeInterval
    let initialRetryDelay: TimeInterval
    let maximumRetryDelay: TimeInterval
    let minimumSemanticWindowDuration: TimeInterval
    let maximumImmediateRetryAttempts: Int
    let maximumSuccessfulCallsPerWorkday: Int
    let maximumAttemptsPerWorkday: Int

    init(
      partialWindowFlushDelay: TimeInterval,
      initialRetryDelay: TimeInterval,
      maximumRetryDelay: TimeInterval,
      minimumSemanticWindowDuration: TimeInterval = 5 * 60,
      maximumImmediateRetryAttempts: Int = 1,
      maximumSuccessfulCallsPerWorkday: Int = 80,
      maximumAttemptsPerWorkday: Int = 96
    ) {
      self.partialWindowFlushDelay = partialWindowFlushDelay
      self.initialRetryDelay = initialRetryDelay
      self.maximumRetryDelay = maximumRetryDelay
      self.minimumSemanticWindowDuration = minimumSemanticWindowDuration
      self.maximumImmediateRetryAttempts = maximumImmediateRetryAttempts
      self.maximumSuccessfulCallsPerWorkday = maximumSuccessfulCallsPerWorkday
      self.maximumAttemptsPerWorkday = maximumAttemptsPerWorkday
    }

    static let live = Timing(
      partialWindowFlushDelay: 8 * 60,
      initialRetryDelay: 5,
      maximumRetryDelay: 300,
      minimumSemanticWindowDuration: 5 * 60,
      maximumImmediateRetryAttempts: 1,
      maximumSuccessfulCallsPerWorkday: 80,
      maximumAttemptsPerWorkday: 96
    )
  }

  enum AnchorKind: String, Equatable, Sendable {
    case applicationContextChanged
    case submission
  }

  struct Trace: Equatable, Sendable {
    let pendingTimeSliceCount: Int
    let lastAnchor: AnchorKind?
    let lastTransition: VisualWorkSegmentTransition?
    let lastCompletedAt: Date?
    let lastFailureCategory: ScreenVisionErrorCategory?
    let lastFailureStage: ScreenVisionFailureStage?
  }

  struct Provider: Sendable {
    let configuration: OpenAICompatibleVisionConfiguration
    let credential: String
  }

  private var provider: Provider?
  private let client: any ScreenVisionInferring
  private var repository: (any VisibleContentArchiveRepository)?
  private var pendingEvidenceRepository: (any ScreenVisionPendingEvidenceRepository)?
  private var usageRepository: (any ScreenVisionUsageRepository)?
  private var objectiveRepository: (any ObjectiveLinkedRecordRepository)?
  private var archiveChangeHandler: (@MainActor @Sendable () -> Void)?
  private var traceHandler: (@MainActor @Sendable (Trace) -> Void)?
  private var captureAnchorHandler: (@MainActor @Sendable () -> Void)?
  private struct PendingTimeSlice: Sendable {
    struct Derivative: Sendable {
      let value: ObjectiveScreenVisionDerivative
      let evidenceID: ScreenVisionPendingEvidenceID?
    }

    var derivatives: [Derivative]
    var observedAt: Date { derivatives[0].value.frame.observedAt }
  }

  private var pending: [PendingTimeSlice] = []
  private var isProcessing = false
  private var authorizationFailureLatched = false
  private var partialFlushTask: Task<Void, Never>?
  private var retryTask: Task<Void, Never>?
  private var partialFlushGeneration: UInt64 = 0
  private var retryGeneration: UInt64 = 0
  private var retryAttempt = 0
  private var seenApplicationContextEventIDs = Set<EventID>()
  private var isContextAnchorPrimed = false
  private var lastAnchor: AnchorKind?
  private var lastTransition: VisualWorkSegmentTransition?
  private var lastCompletedAt: Date?
  private var lastFailureCategory: ScreenVisionErrorCategory?
  private var lastFailureStage: ScreenVisionFailureStage?
  private var segmentStateMachine = VisualWorkSegmentStateMachine()
  private var workdayBoundary: WorkdayBoundary

  private static let maximumPendingDerivativeCount = 64
  private static let timeSliceAlignmentTolerance: TimeInterval = 2
  private static let maximumTimeSliceGap: TimeInterval = 2 * 60
  private static let currentSystemContextMaximumAge: TimeInterval = 20
  private static let recentSystemContextMaximumAge: TimeInterval = 120
  private let timing: Timing

  init(
    provider: Provider?,
    client: any ScreenVisionInferring = OpenAICompatibleScreenVisionClient(),
    timing: Timing = .live,
    workdayBoundary: WorkdayBoundary = .standard
  ) {
    self.provider = provider
    self.client = client
    self.timing = timing
    self.workdayBoundary = workdayBoundary
  }

  func updateWorkdayBoundary(_ boundary: WorkdayBoundary) {
    workdayBoundary = boundary
  }

  static func developmentEnvironment(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> ScreenVisionRuntime {
    let endpoint = environment["DAYDAY_VISION_ENDPOINT"]
      .flatMap(URL.init(string:))
    let model = environment["DAYDAY_VISION_MODEL"]?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let credential = environment["DAYDAY_VISION_API_KEY"]
    let provider: Provider?
    if let endpoint, let model, !model.isEmpty,
      let credential, !credential.isEmpty
    {
      provider = Provider(
        configuration: OpenAICompatibleVisionConfiguration(
          endpoint: endpoint,
          model: model,
          detail: .high
        ),
        credential: credential
      )
    } else {
      provider = nil
    }
    return ScreenVisionRuntime(provider: provider)
  }

  func configure(_ provider: Provider?) async {
    cancelScheduledProcessing()
    self.provider = provider
    authorizationFailureLatched = false
    retryAttempt = 0
    await processPendingIfReady(allowPartial: true)
  }

  func attach(_ repository: any VisibleContentArchiveRepository) {
    self.repository = repository
  }

  func attachPendingEvidenceRepository(_ repository: any ScreenVisionPendingEvidenceRepository) async {
    pendingEvidenceRepository = repository
    guard let evidence = try? await repository.pendingScreenVisionEvidence(limit: 64) else { return }
    for record in evidence {
      guard let derivative = try? Self.derivative(from: record) else { continue }
      appendToTimeSlice(.init(value: derivative, evidenceID: record.id))
    }
    await processPendingIfReady(allowPartial: true)
  }

  func attachUsageRepository(_ repository: any ScreenVisionUsageRepository) {
    usageRepository = repository
  }

  /// The repository supplies the most recent privacy-filtered foreground application fact. It is
  /// contextual evidence only: a visual batch may span multiple displays, so no display mapping
  /// is invented here.
  func attachObjectiveRepository(_ repository: any ObjectiveLinkedRecordRepository) {
    objectiveRepository = repository
  }

  func setCaptureAnchorHandler(
    _ handler: @escaping @MainActor @Sendable () -> Void
  ) {
    captureAnchorHandler = handler
  }

  func setTraceHandler(
    _ handler: @escaping @MainActor @Sendable (Trace) -> Void
  ) async {
    traceHandler = handler
    await publishTrace()
  }

  /// Called by the aggregate-only input collector after a Return/Enter event has already passed
  /// its safe gates. No raw key payload reaches this actor.
  func recordSubmissionAnchor() async {
    await requestCaptureAnchor(.submission)
  }

  /// Establishes a cursor over already-durable, privacy-filtered app-context facts. Historic
  /// changes are intentionally not replayed as capture anchors on launch.
  func startObjectiveContextAnchoring() async {
    guard objectiveRepository != nil else { return }
    await inspectObjectiveContextChanges()
  }

  /// App composition calls this only when H1 reports a new durable history revision. This avoids
  /// a recurring database poll while still anchoring the next safe frame after a foreground-app
  /// transition is committed.
  func inspectObjectiveContextChanges() async {
    await pollObjectiveContextAnchors()
  }

  func stopObjectiveContextAnchoring() {
    seenApplicationContextEventIDs.removeAll(keepingCapacity: false)
    isContextAnchorPrimed = false
  }

  func setArchiveChangeHandler(
    _ handler: @escaping @MainActor @Sendable () -> Void
  ) {
    archiveChangeHandler = handler
  }

  func receive(_ derivative: ObjectiveScreenVisionDerivative) async {
    guard provider != nil else {
      screenVisionLogger.notice("Visual derivative skipped because no provider is configured")
      return
    }
    guard !authorizationFailureLatched else {
      screenVisionLogger.notice(
        "Visual derivative skipped because provider authorization requires an explicit reconnect"
      )
      return
    }
    screenVisionLogger.notice("Visual derivative accepted for timeline batch")
    let queued: PendingTimeSlice.Derivative
    if let pendingEvidenceRepository, let evidence = try? Self.pendingEvidence(from: derivative) {
      guard (try? await pendingEvidenceRepository.insert(evidence)) != nil else { return }
      queued = .init(value: derivative, evidenceID: evidence.id)
    } else {
      queued = .init(value: derivative, evidenceID: nil)
    }
    if retryTask == nil, let newest = pending.last?.observedAt,
      queued.value.frame.observedAt.timeIntervalSince(newest) > Self.maximumTimeSliceGap
    {
      cancelPartialFlush()
      await processPendingIfReady(allowPartial: true)
    }
    appendToTimeSlice(queued)
    await publishTrace()
    schedulePendingProcessing()
  }

  /// Used by deterministic runtime tests and by shutdown paths that need to drain an already
  /// sealed capture window without waiting for the display-alignment grace period.
  func flushPending() async {
    cancelScheduledProcessing()
    await processPendingIfReady(allowPartial: true)
  }

  private func schedulePendingProcessing() {
    guard partialFlushTask == nil, retryTask == nil else { return }
    partialFlushGeneration &+= 1
    let generation = partialFlushGeneration
    let delay = timing.partialWindowFlushDelay
    partialFlushTask = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(delay)) } catch { return }
      await self?.partialFlushFired(generation: generation)
    }
  }

  private func partialFlushFired(generation: UInt64) async {
    guard generation == partialFlushGeneration else { return }
    partialFlushTask = nil
    await processPendingIfReady(allowPartial: true)
  }

  private func processPendingIfReady(allowPartial: Bool = false) async {
    guard !isProcessing, allowPartial, !pending.isEmpty else { return }
    isProcessing = true
    defer { isProcessing = false }

    let count = coherentWindowPrefixCount()
    let next = Array(pending.prefix(count))
    pending.removeFirst(count)
    let outcome = await inferAndArchive(next)
    if outcome == .retry {
      pending.insert(contentsOf: next, at: 0)
      trimPendingToCapacity()
      scheduleRetry()
      return
    }
    if outcome == .deferred {
      pending.insert(contentsOf: next, at: 0)
      trimPendingToCapacity()
      return
    }
    retryAttempt = 0
    if !pending.isEmpty { schedulePendingProcessing() }
  }

  /// Real inactivity is a hard boundary. It is preserved locally even when an older provider
  /// request is being retried, so evidence from two separated work periods is never co-mingled.
  private func coherentWindowPrefixCount() -> Int {
    guard pending.count > 1 else { return pending.count }
    for index in 1..<pending.count {
      if pending[index].observedAt.timeIntervalSince(pending[index - 1].observedAt)
        > Self.maximumTimeSliceGap
      {
        return index
      }
    }
    return pending.count
  }

  private func scheduleRetry() {
    guard !authorizationFailureLatched, provider != nil else { return }
    guard retryAttempt < timing.maximumImmediateRetryAttempts else { return }
    cancelPartialFlush()
    cancelRetry()
    let exponent = min(retryAttempt, 6)
    let delay = min(
      timing.initialRetryDelay * pow(2, Double(exponent)), timing.maximumRetryDelay
    )
    retryAttempt += 1
    retryGeneration &+= 1
    let generation = retryGeneration
    retryTask = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(delay)) } catch { return }
      await self?.retryFired(generation: generation)
    }
  }

  private func retryFired(generation: UInt64) async {
    guard generation == retryGeneration else { return }
    retryTask = nil
    await processPendingIfReady(allowPartial: true)
  }

  private func cancelScheduledProcessing() {
    cancelPartialFlush()
    cancelRetry()
  }

  private func cancelPartialFlush() {
    partialFlushGeneration &+= 1
    partialFlushTask?.cancel()
    partialFlushTask = nil
  }

  private func cancelRetry() {
    retryGeneration &+= 1
    retryTask?.cancel()
    retryTask = nil
  }

  private enum InferenceOutcome { case completed; case retry; case deferred }

  private func appendToTimeSlice(_ derivative: PendingTimeSlice.Derivative) {
    let displayID = derivative.value.frame.display.id
    if let index = pending.indices.last(where: { index in
      abs(pending[index].observedAt.timeIntervalSince(derivative.value.frame.observedAt))
        <= Self.timeSliceAlignmentTolerance
        && !pending[index].derivatives.contains(where: { $0.value.frame.display.id == displayID })
    }) {
      pending[index].derivatives.append(derivative)
      pending[index].derivatives.sort {
        $0.value.frame.display.id.rawValue.uuidString < $1.value.frame.display.id.rawValue.uuidString
      }
    } else {
      pending.append(PendingTimeSlice(derivatives: [derivative]))
    }
    pending.sort { $0.observedAt < $1.observedAt }
    trimPendingToCapacity()
  }

  private func trimPendingToCapacity() {
    var derivativeCount = pending.reduce(0) { $0 + $1.derivatives.count }
    while derivativeCount > Self.maximumPendingDerivativeCount, !pending.isEmpty {
      derivativeCount -= pending.removeFirst().derivatives.count
    }
  }

  /// Keep the objective window locally, but send at most eight representative frames to the
  /// provider. First and last state are retained, then the largest uncovered time gaps are filled
  /// deterministically while respecting multi-display frame cost.
  private func representativeSlices(from slices: [PendingTimeSlice]) -> [PendingTimeSlice] {
    guard !slices.isEmpty else { return [] }
    let frameBudget = ScreenVisualTimelineBatch.maximumFrameCount
    if slices.count <= ScreenVisualTimelineBatch.maximumTimeSliceCount,
      slices.reduce(0, { $0 + $1.derivatives.count }) <= frameBudget
    {
      return slices
    }

    var selected = Set([0, slices.count - 1])
    var frameCount = selected.reduce(0) { $0 + slices[$1].derivatives.count }
    while selected.count < ScreenVisualTimelineBatch.maximumTimeSliceCount {
      let candidate = slices.indices
        .filter { !selected.contains($0) && frameCount + slices[$0].derivatives.count <= frameBudget }
        .max { left, right in
          let leftDistance = selected.map {
            abs(slices[left].observedAt.timeIntervalSince(slices[$0].observedAt))
          }.min() ?? 0
          let rightDistance = selected.map {
            abs(slices[right].observedAt.timeIntervalSince(slices[$0].observedAt))
          }.min() ?? 0
          if leftDistance == rightDistance { return left > right }
          return leftDistance < rightDistance
        }
      guard let candidate else { break }
      selected.insert(candidate)
      frameCount += slices[candidate].derivatives.count
    }
    return selected.sorted().map { slices[$0] }
  }

  private func inferAndArchive(_ pendingSlices: [PendingTimeSlice]) async -> InferenceOutcome {
    guard let provider else {
      screenVisionLogger.notice("Visual inference skipped because provider became unavailable")
      return .retry
    }
    guard let repository else {
      screenVisionLogger.notice("Visual inference skipped because archive is unavailable")
      return .retry
    }
    guard await hasAvailableWorkdayBudget(at: Date()) else {
      screenVisionLogger.notice("Visual inference deferred because the workday call budget is full")
      return .deferred
    }
    let queuedDerivatives = pendingSlices.flatMap(\.derivatives)
    let selectedPendingSlices = representativeSlices(from: pendingSlices)
    let selectedQueuedDerivatives = selectedPendingSlices.flatMap(\.derivatives)
    let derivatives = selectedQueuedDerivatives.map(\.value)
    guard let first = derivatives.first else { return .completed }
    let startedAt = Date()
    let response: ProviderScreenVisionResponse
    let batch: ScreenVisualTimelineBatch
    do {
      var slices: [ScreenVisualTimeSlice] = []
      for slice in selectedPendingSlices {
        let frames = try slice.derivatives.map { queuedDerivative in
          let derivative = queuedDerivative.value
          return try ScreenVisualTimelineFrame(
            image: EphemeralVisionImage(
              data: derivative.encodedJPEG,
              mediaType: .jpeg,
              pixelWidth: derivative.pixelWidth,
              pixelHeight: derivative.pixelHeight
            ),
            observedAt: derivative.frame.observedAt,
            displayLabel: Self.displayLabel(for: derivative.frame.display),
            redactedOCRLines: derivative.redactedOCRLines
          )
        }
        let timeSlice = try ScreenVisualTimeSlice(
          frames: frames,
          systemContext: await systemContext(
            for: slice.observedAt...slice.observedAt.addingTimeInterval(
              Self.timeSliceAlignmentTolerance)
          )
        )
        slices.append(timeSlice)
      }
      batch = try ScreenVisualTimelineBatch(
        timeSlices: slices,
        continuityContext: await recentContinuity(before: first.frame.observedAt)
      )
      response = try await client.infer(
        batch: batch,
        configuration: provider.configuration,
        credential: provider.credential
      )
    } catch {
      let category = Self.errorCategory(for: error)
      let stage = Self.failureStage(for: error)
      screenVisionLogger.error(
        "Visual provider request failed: \(String(describing: category), privacy: .public) at \(stage.rawValue, privacy: .public)"
      )
      try? await persistUsage(
        provider: provider,
        startedAt: startedAt,
        requestID: nil,
        usage: nil,
        errorCategory: category,
        failureStage: stage
      )
      if category == .unauthorized {
        // A credential/billing rejection will not heal by retrying every captured frame. Latch
        // after the first durable failure; saving the provider or passing Settings' connection
        // test calls configure(_:) and explicitly re-arms inference.
        authorizationFailureLatched = true
      }
      lastFailureCategory = category
      lastFailureStage = stage
      await publishTrace()
      return .retry
    }

    screenVisionLogger.notice("Visual provider request completed")

    do {
      var acceptedSegments: [(VisualWorkSegment, Date, Date)] = []
      var archivedObservations: [VisibleContentObservation] = []
      let resolvedRanges = response.segments.map {
        $0.timeSliceRange ?? (0...(batch.timeSlices.count - 1))
      }
      guard resolvedRanges.first?.lowerBound == 0,
        resolvedRanges.last?.upperBound == batch.timeSlices.count - 1,
        response.segments.count == 1 || response.segments.allSatisfy({ $0.timeSliceRange != nil })
      else { throw ScreenVisionProviderError.invalidResponse }
      for pair in zip(resolvedRanges, resolvedRanges.dropFirst()) where
        pair.0.upperBound + 1 != pair.1.lowerBound
      {
        throw ScreenVisionProviderError.invalidResponse
      }
      for (providerSegment, range) in zip(response.segments, resolvedRanges) {
        let segmentSlices = range.map { selectedPendingSlices[$0] }
        let segmentBatchSlices = range.map { batch.timeSlices[$0] }
        let segmentDerivatives = segmentSlices.flatMap(\.derivatives).map(\.value)
        guard let segmentFirst = segmentDerivatives.first,
          let segmentLast = segmentDerivatives.last
        else { throw ScreenVisionProviderError.invalidResponse }
        let inference = providerSegment.inference
        let hasCurrentSystemContext = segmentBatchSlices.contains {
          $0.systemContext.freshness == .current
        }
        guard (hasCurrentSystemContext && inference.systemContextAgreement != .unavailable)
          || (!hasCurrentSystemContext && inference.systemContextAgreement == .unavailable)
        else { throw ScreenVisionProviderError.invalidResponse }
        let currentContext = segmentBatchSlices.last(where: {
          $0.systemContext.freshness == .current
        })?.systemContext
        let displays = try Self.visualDisplayStates(
          from: inference, derivatives: segmentDerivatives
        )
        let segment = try VisualWorkSegment(
          primarySituation: inference.summary,
          interaction: inference.interaction,
          activityKind: inference.activityKind,
          foregroundApplicationLabel: currentContext?.foregroundApplicationLabel,
          displays: displays,
          relationship: inference.relationship,
          systemContextAgreement: inference.systemContextAgreement,
          evidence: inference.evidence,
          uncertainties: inference.uncertainties
        )
        let displayLines = segment.displays.map {
          "- \(Self.displayLabel(for: $0.displayID, in: segmentDerivatives))：\($0.role.rawValue)；\($0.visibleState)"
        }.joined(separator: "\n")
        let evidence = inference.evidence.map { "- \($0)" }.joined(separator: "\n")
        let uncertaintyLines = segment.uncertainties.map { "- \($0)" }.joined(separator: "\n")
        let text = """
          系统前台应用：\(currentContext?.foregroundApplicationLabel ?? "未取得")
          情境：\(inference.summary)
          可见交互：\(inference.interaction)
          类型：\(inference.activityKind.rawValue)
          跨屏关系：\(inference.relationship.rawValue)
          系统上下文一致性：\(inference.systemContextAgreement.rawValue)
          屏幕状态：
          \(displayLines)
          可见依据：
          \(evidence)
          不确定项：
          \(uncertaintyLines)
          """
        let startedAt = segmentFirst.frame.observedAt
        let endedAt = max(segmentLast.frame.observedAt, startedAt)
        let provenance = try VisibleContentProvenance(
          source: CollectorSource(
            collector: .screenUnderstanding,
            collectorVersion: "byok-screen-vision-timeline-v1",
            payloadSchemaVersion: 4
          ),
          observedAt: startedAt,
          endedAt: endedAt > startedAt ? endedAt : nil,
          timeZoneIdentifier: TimeZone.current.identifier,
          display: Self.sharedDisplay(in: segmentDerivatives)
        )
        archivedObservations.append(
          try VisibleContentObservation(
            provenance: provenance,
            kind: .inference,
            redactionState: .noRedactionNeeded,
            text: text,
            inferenceOrigin: "byok-screen-vision-timeline-v4",
            visualWorkSegment: segment
          )
        )
        acceptedSegments.append((segment, startedAt, endedAt))
      }
      guard !archivedObservations.isEmpty else {
        throw ScreenVisionProviderError.invalidResponse
      }
      for observation in archivedObservations { _ = try await repository.insert(observation) }
      for accepted in acceptedSegments {
        lastTransition = segmentStateMachine.record(
          accepted.0,
          startedAt: accepted.1,
          endedAt: accepted.2
        )
      }
      let evidenceIDs = queuedDerivatives.compactMap(\.evidenceID)
      if !evidenceIDs.isEmpty {
        // Older archive implementations accepted only small delete batches. Keep the runtime
        // compatible with those stores as well as the current 64-frame crash-safe queue: a
        // successful archive must never be reclassified as retryable merely because cleanup has
        // more identifiers than a repository's one-statement limit.
        for start in stride(from: 0, to: evidenceIDs.count, by: 16) {
          let end = min(start + 16, evidenceIDs.count)
          try await pendingEvidenceRepository?.removePendingScreenVisionEvidence(
            ids: Array(evidenceIDs[start..<end])
          )
        }
      }
      await archiveChangeHandler?()
      try? await persistUsage(
        provider: provider,
        startedAt: startedAt,
        requestID: response.requestID,
        usage: response.usage,
        errorCategory: nil,
        failureStage: nil
      )
      lastCompletedAt = Date()
      lastFailureCategory = nil
      lastFailureStage = nil
      await publishTrace()
    } catch {
      // The provider did return a response, but this attempt was not accepted into the local
      // timeline. Record that distinction while preserving any provider-reported token usage.
      screenVisionLogger.error("Visual inference failed local acceptance")
      try? await persistUsage(
        provider: provider,
        startedAt: startedAt,
        requestID: response.requestID,
        usage: response.usage,
        errorCategory: .archiveFailure,
        failureStage: .localAcceptance
      )
      lastFailureCategory = .archiveFailure
      lastFailureStage = .localAcceptance
      await publishTrace()
      return .retry
    }
    return .completed
  }

  private func hasAvailableWorkdayBudget(at date: Date) async -> Bool {
    guard let usageRepository else { return true }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .autoupdatingCurrent
    guard let startsAt = try? workdayBoundary.start(containing: date, calendar: calendar),
      let nextCivilDay = calendar.date(byAdding: .day, value: 1, to: startsAt),
      let endsAt = try? workdayBoundary.start(containing: nextCivilDay, calendar: calendar),
      startsAt < endsAt,
      let summary = try? await usageRepository.screenVisionUsage(in: startsAt..<endsAt)
    else { return true }
    return summary.successCount < timing.maximumSuccessfulCallsPerWorkday
      && summary.callCount < timing.maximumAttemptsPerWorkday
  }

  private func systemContext(for interval: ClosedRange<Date>) async -> ScreenVisualSystemContext {
    guard let objectiveRepository else { return .init() }
    let lowerBound = interval.lowerBound.addingTimeInterval(-120)
    guard lowerBound < interval.upperBound.addingTimeInterval(1) else { return .init() }
    do {
      let events = try await objectiveRepository.fetch(
        occurredIn: lowerBound..<interval.upperBound.addingTimeInterval(1)
      )
      guard let event = events.last(where: {
        $0.kind == .applicationContextChanged
          && $0.source.collector == .applicationWindowContext
          && $0.securityDisposition == .allowed
      }), let context = try await objectiveRepository.fetchApplicationContext(for: event.id)
      else { return .init() }
      let age = max(0, interval.upperBound.timeIntervalSince(event.occurredAt))
      let freshness: ScreenVisualSystemContext.Freshness
      switch age {
      case ...Self.currentSystemContextMaximumAge: freshness = .current
      case ...Self.recentSystemContextMaximumAge: freshness = .recentlyObserved
      default: freshness = .unavailable
      }
      return .init(
        foregroundApplicationLabel: freshness == .unavailable ? nil : context.displayLabelSnapshot,
        focusedWindowTitle: freshness == .unavailable ? nil : context.windowTitleSnapshot,
        freshness: freshness
      )
    } catch {
      return .init()
    }
  }

  private func recentContinuity(before date: Date) async -> ScreenVisualContinuityContext {
    guard let repository else { return .init() }
    let lowerBound = date.addingTimeInterval(-30 * 60)
    guard lowerBound < date,
      let observations = try? await repository.fetchVisibleContent(observedIn: lowerBound..<date)
    else { return .init() }
    let recent = observations
      .filter { $0.kind == .inference && $0.visualWorkSegment != nil }
      .sorted {
        let left = $0.provenance.endedAt ?? $0.provenance.observedAt
        let right = $1.provenance.endedAt ?? $1.provenance.observedAt
        return left > right
      }
      .prefix(ScreenVisualContinuityContext.maximumSegmentCount)
      .reversed()
      .compactMap { observation -> ScreenVisualPriorSegment? in
        guard let segment = observation.visualWorkSegment else { return nil }
        return try? ScreenVisualPriorSegment(
          summary: segment.primarySituation,
          activityKind: segment.activityKind,
          foregroundApplicationLabel: segment.foregroundApplicationLabel
        )
      }
    return (try? ScreenVisualContinuityContext(recentSegments: recent)) ?? .init()
  }

  private func pollObjectiveContextAnchors() async {
    guard let objectiveRepository else { return }
    let now = Date()
    let lowerBound = now.addingTimeInterval(-90)
    guard let events = try? await objectiveRepository.fetch(occurredIn: lowerBound..<now) else {
      return
    }
    let candidates = events.filter {
      $0.kind == .applicationContextChanged
        && $0.source.collector == .applicationWindowContext
        && $0.securityDisposition == .allowed
    }
    if !isContextAnchorPrimed {
      seenApplicationContextEventIDs = Set(candidates.map(\.id))
      isContextAnchorPrimed = true
      return
    }
    let newCandidates = candidates
      .filter { seenApplicationContextEventIDs.insert($0.id).inserted }
      .sorted { $0.occurredAt < $1.occurredAt }
    if seenApplicationContextEventIDs.count > 256 {
      seenApplicationContextEventIDs = Set(candidates.map(\.id))
    }
    guard !newCandidates.isEmpty else { return }
    await requestCaptureAnchor(.applicationContextChanged)
  }

  private func requestCaptureAnchor(_ anchor: AnchorKind) async {
    lastAnchor = anchor
    await publishTrace()
    if anchor == .applicationContextChanged,
      retryTask == nil,
      let first = pending.first?.observedAt,
      let last = pending.last?.observedAt,
      last.timeIntervalSince(first) >= timing.minimumSemanticWindowDuration
    {
      cancelPartialFlush()
      await processPendingIfReady(allowPartial: true)
    }
    await captureAnchorHandler?()
  }

  private func publishTrace() async {
    await traceHandler?(
      Trace(
        pendingTimeSliceCount: pending.count,
        lastAnchor: lastAnchor,
        lastTransition: lastTransition,
        lastCompletedAt: lastCompletedAt,
        lastFailureCategory: lastFailureCategory,
        lastFailureStage: lastFailureStage
      )
    )
  }

  private static func displayLabel(for display: DisplayContext) -> String {
    "display-\(display.id.rawValue.uuidString.prefix(8).lowercased())"
  }

  private static func displayLabel(
    for displayID: DisplayID, in derivatives: [ObjectiveScreenVisionDerivative]
  ) -> String {
    derivatives.first(where: { $0.frame.display.id == displayID })
      .map { displayLabel(for: $0.frame.display) } ?? "display-unknown"
  }

  private static func visualDisplayStates(
    from inference: ScreenVisualInference,
    derivatives: [ObjectiveScreenVisionDerivative]
  ) throws -> [VisualDisplayState] {
    let displaysByLabel = derivatives.reduce(into: [String: DisplayID]()) { result, derivative in
      result[displayLabel(for: derivative.frame.display)] = derivative.frame.display.id
    }
    return try inference.displayStates.map { state in
      guard let displayID = displaysByLabel[state.displayLabel] else {
        throw ScreenVisionProviderError.invalidResponse
      }
      return try VisualDisplayState(
        displayID: displayID, role: state.role, visibleState: state.visibleState
      )
    }
  }

  private static func sharedDisplay(
    in derivatives: [ObjectiveScreenVisionDerivative]
  ) -> DisplayContext? {
    guard let first = derivatives.first?.frame.display,
      derivatives.allSatisfy({ $0.frame.display == first })
    else { return nil }
    return first
  }

  private static func pendingEvidence(
    from derivative: ObjectiveScreenVisionDerivative
  ) throws -> ScreenVisionPendingEvidence {
    try ScreenVisionPendingEvidence(
      observedAt: derivative.frame.observedAt,
      display: derivative.frame.display,
      encodedJPEG: derivative.encodedJPEG,
      pixelWidth: derivative.pixelWidth,
      pixelHeight: derivative.pixelHeight,
      redactedOCRLines: derivative.redactedOCRLines
    )
  }

  private static func derivative(
    from evidence: ScreenVisionPendingEvidence
  ) throws -> ObjectiveScreenVisionDerivative {
    try ObjectiveScreenVisionDerivative(
      frame: ObjectiveScreenFrameMetadata(
        display: evidence.display,
        observedAt: evidence.observedAt,
        pixelWidth: evidence.pixelWidth,
        pixelHeight: evidence.pixelHeight
      ),
      encodedJPEG: evidence.encodedJPEG,
      pixelWidth: evidence.pixelWidth,
      pixelHeight: evidence.pixelHeight,
      redactedOCRLines: evidence.redactedOCRLines
    )
  }

  private func persistUsage(
    provider: Provider,
    startedAt: Date,
    requestID: String?,
    usage: ProviderReportedTokenUsage?,
    errorCategory: ScreenVisionErrorCategory?,
    failureStage: ScreenVisionFailureStage?
  ) async throws {
    guard let usageRepository else { return }
    let host = provider.configuration.endpoint.host ?? "openai-compatible"
    let record = try ScreenVisionUsageRecord(
      provider: host,
      model: provider.configuration.model,
      requestID: requestID,
      startedAt: startedAt,
      completedAt: Date(),
      outcome: errorCategory == nil ? .success : .failure,
      errorCategory: errorCategory,
      failureStage: failureStage,
      inputTokens: usage?.promptTokens,
      outputTokens: usage?.completionTokens,
      cachedInputTokens: usage?.cachedTokens,
      totalTokens: usage?.totalTokens
    )
    _ = try await usageRepository.insert(record)
  }

  private static func errorCategory(for error: Error) -> ScreenVisionErrorCategory {
    switch error {
    case ScreenVisionProviderError.invalidEndpoint: .invalidEndpoint
    case ScreenVisionProviderError.missingCredential: .missingCredential
    case ScreenVisionProviderError.invalidOCRContext: .invalidInput
    case ScreenVisionProviderError.cancelled: .cancelled
    case ScreenVisionProviderError.transportUnavailable: .network
    case ScreenVisionProviderError.unauthorized: .unauthorized
    case ScreenVisionProviderError.rateLimited: .rateLimited
    case ScreenVisionProviderError.serverFailure: .providerServer
    case ScreenVisionProviderError.rejected: .providerRejected
    case ScreenVisionProviderError.invalidResponse: .invalidResponse
    default: .unknown
    }
  }

  private static func failureStage(for error: Error) -> ScreenVisionFailureStage {
    switch error {
    case ScreenVisionProviderError.invalidEndpoint,
      ScreenVisionProviderError.missingCredential,
      ScreenVisionProviderError.invalidOCRContext:
      .configuration
    case ScreenVisionProviderError.invalidResponse:
      .responseValidation
    default:
      .providerRequest
    }
  }
}

private actor ScreenCaptureTargetResolver {
  private let inventory: any DisplayInventoryProviding
  private var reconciler = DisplayIdentityReconciler()

  init(inventory: any DisplayInventoryProviding = CoreGraphicsDisplayInventory()) {
    self.inventory = inventory
  }

  func onlineDisplayTargets() -> [ScreenCaptureDisplayTarget] {
    guard let descriptors = try? inventory.onlineDisplays(), !descriptors.isEmpty else {
      return []
    }
    let topology = DisplayTopology(displays: descriptors)
    let reconciliation = reconciler.reconcile(topology)
    return reconciliation.displays
      .filter { $0.descriptor.mirrorSourceRuntimeID == nil }
      .map { ScreenCaptureDisplayTarget(display: $0, topologyRevision: topology.revision) }
  }
}

struct PageHeader: View {
  let title: String
  let subtitle: String?
  var systemImage: String?

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      if let systemImage {
        Image(systemName: systemImage)
          .font(.title3.weight(.semibold))
          .foregroundStyle(.tint)
          .accessibilityHidden(true)
      }

      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.title2.weight(.semibold))
        if let subtitle, !subtitle.isEmpty {
          Text(subtitle)
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
      }
    }
    .accessibilityElement(children: .combine)
  }
}

enum AdaptivePairLayoutMode: Equatable {
  case horizontal
  case stacked

  init(
    availableWidth: CGFloat,
    leadingWidth: CGFloat,
    trailingWidth: CGFloat,
    spacing: CGFloat
  ) {
    let requiredSpacing = trailingWidth > 0 ? spacing : 0
    self = leadingWidth + requiredSpacing + trailingWidth <= availableWidth
      ? .horizontal
      : .stacked
  }
}

/// Repositions one leading view and one trailing view without constructing
/// alternative view trees. This matters for native AppKit-backed controls:
/// measuring duplicate Picker trees can trigger re-entrant hosting-view layout.
struct AdaptiveLeadingTrailingLayout: Layout {
  let horizontalSpacing: CGFloat
  let verticalSpacing: CGFloat

  func sizeThatFits(
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout ()
  ) -> CGSize {
    guard subviews.count == 2 else { return .zero }

    let leadingSize = subviews[0].sizeThatFits(.unspecified)
    let intrinsicTrailingSize = subviews[1].sizeThatFits(.unspecified)
    let naturalWidth = leadingSize.width
      + (intrinsicTrailingSize.width > 0 ? horizontalSpacing : 0)
      + intrinsicTrailingSize.width
    let availableWidth = proposal.width ?? naturalWidth
    let mode = AdaptivePairLayoutMode(
      availableWidth: availableWidth,
      leadingWidth: leadingSize.width,
      trailingWidth: intrinsicTrailingSize.width,
      spacing: horizontalSpacing
    )

    switch mode {
    case .horizontal:
      return CGSize(
        width: availableWidth,
        height: max(leadingSize.height, intrinsicTrailingSize.height)
      )
    case .stacked:
      let trailingSize = subviews[1].sizeThatFits(
        ProposedViewSize(width: availableWidth, height: nil)
      )
      let requiredVerticalSpacing = trailingSize.height > 0 ? verticalSpacing : 0
      return CGSize(
        width: availableWidth,
        height: leadingSize.height + requiredVerticalSpacing + trailingSize.height
      )
    }
  }

  func placeSubviews(
    in bounds: CGRect,
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout ()
  ) {
    guard subviews.count == 2 else { return }

    let leadingSize = subviews[0].sizeThatFits(.unspecified)
    let intrinsicTrailingSize = subviews[1].sizeThatFits(.unspecified)
    let mode = AdaptivePairLayoutMode(
      availableWidth: bounds.width,
      leadingWidth: leadingSize.width,
      trailingWidth: intrinsicTrailingSize.width,
      spacing: horizontalSpacing
    )

    subviews[0].place(
      at: bounds.origin,
      anchor: .topLeading,
      proposal: ProposedViewSize(leadingSize)
    )

    switch mode {
    case .horizontal:
      subviews[1].place(
        at: CGPoint(x: bounds.maxX, y: bounds.minY),
        anchor: .topTrailing,
        proposal: ProposedViewSize(intrinsicTrailingSize)
      )
    case .stacked:
      let trailingSize = subviews[1].sizeThatFits(
        ProposedViewSize(width: bounds.width, height: nil)
      )
      guard trailingSize.height > 0 else { return }
      subviews[1].place(
        at: CGPoint(
          x: bounds.minX,
          y: bounds.minY + leadingSize.height + verticalSpacing
        ),
        anchor: .topLeading,
        proposal: ProposedViewSize(width: bounds.width, height: trailingSize.height)
      )
    }
  }
}

/// A stable detail-column landmark shared by every primary destination.
///
/// The page body may choose its own readable width, but the page identity must
/// not move when the user switches destinations. Actions can collapse beneath
/// the identity on compact windows without changing the title's leading edge.
struct PageHeaderBar<Actions: View>: View {
  let title: String
  let subtitle: String?
  let systemImage: String
  @ViewBuilder let actions: Actions

  init(
    title: String,
    subtitle: String?,
    systemImage: String,
    @ViewBuilder actions: () -> Actions
  ) {
    self.title = title
    self.subtitle = subtitle
    self.systemImage = systemImage
    self.actions = actions()
  }

  var body: some View {
    AdaptiveLeadingTrailingLayout(
      horizontalSpacing: DaydaySpace.xl,
      verticalSpacing: DaydaySpace.m
    ) {
      pageIdentity
      actions
    }
    .padding(.horizontal, DaydaySpace.pageHorizontal)
    .padding(.top, DaydaySpace.pageTop)
    .padding(.bottom, DaydaySpace.pageHeaderBottom)
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .background(Color(nsColor: .windowBackgroundColor))
  }

  private var pageIdentity: some View {
    PageHeader(title: title, subtitle: subtitle, systemImage: systemImage)
      .frame(
        minHeight: DaydaySpace.pageHeaderMinimumHeight,
        alignment: .topLeading
      )
      .fixedSize(horizontal: false, vertical: true)
  }
}

extension PageHeaderBar where Actions == EmptyView {
  init(title: String, subtitle: String?, systemImage: String) {
    self.init(title: title, subtitle: subtitle, systemImage: systemImage) {
      EmptyView()
    }
  }
}

struct DaydayCard<Content: View>: View {
  let title: String
  let systemImage: String
  @ViewBuilder let content: Content

  init(
    _ title: String,
    systemImage: String,
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.systemImage = systemImage
    self.content = content()
  }

  var body: some View {
    DaydayThemeReader { theme, _ in
      VStack(alignment: .leading, spacing: 14) {
        HStack(spacing: 8) {
          Image(systemName: systemImage)
            .foregroundStyle(theme[.textSecondary])
            .accessibilityHidden(true)
          Text(title)
            .foregroundStyle(theme[.textPrimary])
        }
        .font(.headline)
        content
      }
      .padding(18)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        theme[.surfaceRaised],
        in: RoundedRectangle(cornerRadius: DaydayRadius.partition, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: DaydayRadius.partition, style: .continuous)
          .stroke(theme[.separator], lineWidth: DaydayDepth.hairline)
      }
      .accessibilityElement(children: .contain)
    }
  }
}

struct PrototypeNotice: View {
  let text: String
  var systemImage = "hammer"

  var body: some View {
    Label(text, systemImage: systemImage)
      .font(.callout)
      .foregroundStyle(.secondary)
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
      .accessibilityElement(children: .combine)
  }
}

struct MetricView: View {
  let value: String
  let label: String

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(value)
        .font(.title2.weight(.semibold))
        .monospacedDigit()
      Text(label)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(label)，\(value)")
  }
}

struct StatusBadge: View {
  let title: String
  let systemImage: String
  let color: Color

  var body: some View {
    Label(title, systemImage: systemImage)
      .font(.caption.weight(.medium))
      .foregroundStyle(color)
      .padding(.horizontal, 9)
      .padding(.vertical, 5)
      .background(color.opacity(0.1), in: Capsule())
  }
}

struct PermissionStatusBadge: View {
  let category: String
  let state: AppRuntimePermissionState

  var body: some View {
    StatusBadge(
      title: title,
      systemImage: systemImage,
      color: color
    )
    .accessibilityLabel("\(category)权限：\(title)")
  }

  private var title: String {
    switch state {
    case .unknown: "\(category)未知"
    case .authorized: "\(category)已授权"
    case .notAuthorized: "\(category)未授权"
    }
  }

  private var systemImage: String {
    switch state {
    case .unknown: "questionmark.circle"
    case .authorized: "checkmark.circle.fill"
    case .notAuthorized: "exclamationmark.circle.fill"
    }
  }

  private var color: Color {
    switch state {
    case .unknown: .secondary
    case .authorized: .green
    case .notAuthorized: .orange
    }
  }
}

struct EmptyState: View {
  let title: String
  let detail: String
  let systemImage: String

  var body: some View {
    ContentUnavailableView {
      Label(title, systemImage: systemImage)
    } description: {
      Text(detail)
    }
    .frame(maxWidth: .infinity, minHeight: 150)
  }
}
