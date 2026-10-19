import DaydayCore
import Foundation

public enum H1CollectionRuntimeFailure: String, Equatable, Sendable {
  case queueOverflow
  case storageUnavailable
  case serviceUnavailable
  case controlPersistenceUnavailable
  case invariantViolated
}

public enum H1PendingNegativeControl: String, Equatable, Sendable {
  case pause
  case disable
}

public enum H1CollectionConsentGate: String, Equatable, Sendable {
  case unconfirmed
  case disabled
  case paused
  case renewalRequired
  case enabled
}

public enum H1CollectionRuntimeStatus: Equatable, Sendable {
  case idle
  case starting
  case holdingNegativeControl(H1PendingNegativeControl)
  case running
  case waitingForAuthorization
  case disabled
  case pausedByUser
  case paused(Set<CollectionPauseReason>)
  case degraded(H1CollectionRuntimeFailure)
  case failed(H1CollectionRuntimeFailure)
  case stopped
}

/// Presentation-safe state for the application-window collector.
///
/// It deliberately excludes bundle identifiers, captured text, platform error
/// messages and repository details.
public struct H1CollectionRuntimeSnapshot: Equatable, Sendable {
  public let status: H1CollectionRuntimeStatus
  public let historyRevision: UInt64
  public let consentGate: H1CollectionConsentGate
  public let authorization: AuthorizationState
  public let pendingNegativeControl: H1PendingNegativeControl?

  public init(
    status: H1CollectionRuntimeStatus,
    historyRevision: UInt64,
    consentGate: H1CollectionConsentGate = .unconfirmed,
    authorization: AuthorizationState = .unknown,
    pendingNegativeControl: H1PendingNegativeControl? = nil
  ) {
    self.status = status
    self.historyRevision = historyRevision
    self.consentGate = consentGate
    self.authorization = authorization
    self.pendingNegativeControl = pendingNegativeControl
  }
}

/// Application-context-only H1 production collector.
///
/// The main actor owns control state while a synchronous mailbox owns bounded
/// admission. A single long-lived worker drains all durable writes in order;
/// application callbacks never create one task per observation.
@MainActor
public final class H1CollectionRuntime {
  public typealias ApplicationIdentityResolver =
    @Sendable (
      _ bundleIdentifier: String,
      _ displayLabel: String
    ) async throws -> ApplicationIdentifier?

  private enum Work {
    case candidate(H1AdmittedCandidate)
    case collectorState(
      CollectorState,
      occurredAt: Date,
      timeZoneIdentifier: String,
      boundary: BoundaryKind,
      completion: (@MainActor @Sendable (Bool) -> Void)?
    )
    case authorizationLoss(
      observedAt: Date,
      timeZoneIdentifier: String,
      state: CollectorState
    )

    enum BoundaryKind {
      case gate
      case lifecycle
      case overflow
      case shutdown
    }

    var isOrdinary: Bool {
      if case .candidate = self { return true }
      return false
    }

  }

  private struct NegativeControlBoundaryContext: Equatable {
    let occurredAt: Date
    let timeZoneIdentifier: String
  }

  nonisolated private let writeLane: H1CollectionWriteLane
  nonisolated private let mailbox: H1CollectionMailbox<Work>
  private let consentRepository: any CollectionConsentRepository
  private let authorizationPreflight: any CaptureAuthorizationPreflighting
  private let lifecycleSource: any SystemLifecycleNotificationSource
  private let excludedBundleIdentifiers: Set<String>
  private let clock: @Sendable () -> Date
  private let timeZoneIdentifier: @Sendable () -> String
  private let platformSource: (any ApplicationWindowPlatformSourcing)?
  private let privacyFilter: (any ApplicationWindowPrivacyFiltering)?

  private var monitor: ApplicationWindowContextMonitor?
  private var lifecycleObservation: (any SystemLifecycleObservation)?
  private var workerTask: Task<Void, Never>?
  private var reconcileRequested = false
  private var authorizationRecoveryRequested = false
  private var reconcileTask: Task<Void, Never>?
  private var reconcileWaiters: [CheckedContinuation<Void, Never>] = []
  private var historySubscribers: [UUID: AsyncStream<UInt64>.Continuation] = [:]
  private var snapshotSubscribers: [UUID: AsyncStream<H1CollectionRuntimeSnapshot>.Continuation] =
    [:]
  private var acceptsObservations = false
  private var pendingNegativeControl: H1PendingNegativeControl?
  private var pendingNegativeControlBoundary: NegativeControlBoundaryContext?
  private var pendingNegativeControlPersistenceFailed = false
  private var reconcileBoundaryContext: NegativeControlBoundaryContext?
  private var isShutdown = false
  private var isFailed = false
  private var generation: UInt64 = 0
  private var admittedCandidateKeys: Set<FilteredApplicationWindowCandidate.EquivalenceKey> = []
  private var isSystemAwake = true
  private var activePauseReasons: Set<CollectionPauseReason> = []
  private var hasObservedAuthorizedAccessibility = false
  private var accessibilityDeniedLatch = false
  private var shutdownTask: Task<Void, Never>?
  private var lifecycleAvailability = SystemLifecycleAvailability(
    isUserSessionActive: false,
    areScreensAwake: false
  )

  public private(set) var snapshot = H1CollectionRuntimeSnapshot(
    status: .idle,
    historyRevision: 0,
    consentGate: .unconfirmed,
    authorization: .unknown
  )

  public func statusUpdates() -> AsyncStream<H1CollectionRuntimeSnapshot> {
    let id = UUID()
    return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
      snapshotSubscribers[id] = continuation
      continuation.yield(snapshot)
      continuation.onTermination = { [weak self] _ in
        Task { @MainActor in self?.snapshotSubscribers[id] = nil }
      }
    }
  }

  public func historyRevisionUpdates() -> AsyncStream<UInt64> {
    let id = UUID()
    return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
      historySubscribers[id] = continuation
      continuation.onTermination = { [weak self] _ in
        Task { @MainActor in self?.historySubscribers[id] = nil }
      }
    }
  }

  public convenience init(
    repository: any ObjectiveLinkedRecordRepository,
    consentRepository: any CollectionConsentRepository,
    authorizationPreflight: any CaptureAuthorizationPreflighting =
      MacOSCaptureAuthorizationPreflight(),
    lifecycleSource: any SystemLifecycleNotificationSource =
      NSWorkspaceSystemLifecycleNotificationSource(),
    excludedBundleIdentifiers: Set<String> = [],
    ordinaryCapacity: Int = 32,
    clock: @escaping @Sendable () -> Date = Date.init,
    timeZoneIdentifier: @escaping @Sendable () -> String = {
      TimeZone.autoupdatingCurrent.identifier
    },
    resolveApplication: @escaping ApplicationIdentityResolver
  ) {
    self.init(
      repository: repository,
      consentRepository: consentRepository,
      authorizationPreflight: authorizationPreflight,
      lifecycleSource: lifecycleSource,
      excludedBundleIdentifiers: excludedBundleIdentifiers,
      ordinaryCapacity: ordinaryCapacity,
      maximumBoundaryFacts: 8,
      clock: clock,
      timeZoneIdentifier: timeZoneIdentifier,
      platformSource: nil,
      privacyFilter: nil,
      resolveApplication: resolveApplication
    )
  }

  init(
    repository: any ObjectiveLinkedRecordRepository,
    consentRepository: any CollectionConsentRepository,
    authorizationPreflight: any CaptureAuthorizationPreflighting,
    lifecycleSource: any SystemLifecycleNotificationSource,
    excludedBundleIdentifiers: Set<String> = [],
    ordinaryCapacity: Int = 32,
    maximumBoundaryFacts: Int = 8,
    clock: @escaping @Sendable () -> Date = Date.init,
    timeZoneIdentifier: @escaping @Sendable () -> String,
    platformSource: (any ApplicationWindowPlatformSourcing)?,
    privacyFilter: (any ApplicationWindowPrivacyFiltering)?,
    resolveApplication: @escaping ApplicationIdentityResolver
  ) {
    precondition(ordinaryCapacity > 0 && maximumBoundaryFacts > 0)
    writeLane = H1CollectionWriteLane(
      repository: repository,
      identityResolver: resolveApplication
    )
    mailbox = H1CollectionMailbox(
      ordinaryCapacity: ordinaryCapacity,
      maximumBoundaryFacts: maximumBoundaryFacts
    )
    self.consentRepository = consentRepository
    self.authorizationPreflight = authorizationPreflight
    self.lifecycleSource = lifecycleSource
    self.excludedBundleIdentifiers = excludedBundleIdentifiers
    self.clock = clock
    self.timeZoneIdentifier = timeZoneIdentifier
    self.platformSource = platformSource
    self.privacyFilter = privacyFilter

  }

  deinit {
    workerTask?.cancel()
  }

  /// Loads persisted consent and non-prompting platform facts. The monitor is
  /// admitted only after a durable running boundary commits.
  public func start() async {
    guard !isShutdown, !isFailed else { return }
    guard workerTask == nil else { return }
    publish(.starting)
    startWorker()
    isSystemAwake = true
    lifecycleAvailability = lifecycleSource.currentAvailability()
    lifecycleObservation = lifecycleSource.observe { [weak self] event in
      self?.receiveLifecycle(event)
    }
    await requestReconcileAndWait()
  }

  /// Re-reads product consent, global pause and authorization without ever
  /// requesting a macOS permission.
  public func refreshGates() async {
    guard workerTask != nil, !isShutdown, !isFailed else { return }
    await requestReconcileAndWait(allowsAuthorizationRecovery: true)
  }

  /// Immediately closes admission while the App durably commits a pause or
  /// disable command. Capture deliberately does not know the marker or SQLite
  /// transaction used by the App/Storage composition.
  @discardableResult
  public func beginPendingNegativeControl(
    _ reason: H1PendingNegativeControl,
    occurredAt: Date? = nil,
    timeZoneIdentifier: String? = nil
  ) async -> Bool {
    guard !isShutdown, !isFailed else { return false }
    if let pendingNegativeControl {
      return pendingNegativeControl == reason
    }
    let boundary = NegativeControlBoundaryContext(
      occurredAt: occurredAt ?? clock(),
      timeZoneIdentifier: timeZoneIdentifier ?? self.timeZoneIdentifier()
    )
    guard boundary.occurredAt.timeIntervalSinceReferenceDate.isFinite,
      TimeZone(identifier: boundary.timeZoneIdentifier) != nil
    else {
      failInvariant()
      return false
    }
    pendingNegativeControl = reason
    pendingNegativeControlBoundary = boundary
    pendingNegativeControlPersistenceFailed = false
    closeAdmission()
    preemptQueuedReconcile()
    publish(.holdingNegativeControl(reason))
    return true
  }

  public func markPendingNegativeControlPersistenceFailed() {
    guard pendingNegativeControl != nil, !isShutdown, !isFailed else { return }
    pendingNegativeControlPersistenceFailed = true
    publish(.failed(.controlPersistenceUnavailable))
  }

  /// The App calls this only after marker creation, durable command commit or
  /// replay, and marker removal all succeed. Normal gates still decide whether
  /// collection may resume. Same-process control keeps the admission boundary
  /// captured by `beginPendingNegativeControl`. After a crash, Capture starts
  /// inert and records only when this process observes the already-stopped
  /// persisted gate; it never invents the original marker time.
  public func endPendingNegativeControlAndRefresh() async {
    guard pendingNegativeControl != nil, !isShutdown, !isFailed else { return }
    let boundary = pendingNegativeControlBoundary
    pendingNegativeControl = nil
    pendingNegativeControlBoundary = nil
    pendingNegativeControlPersistenceFailed = false
    guard workerTask != nil else {
      publish(.idle)
      return
    }
    await requestReconcileAndWait(boundaryContext: boundary)
  }

  /// A hard idempotent boundary. Previously admitted FIFO work is completed
  /// before the durable stopped state; late monitor callbacks are inert.
  public func shutdown() async {
    if let shutdownTask {
      await shutdownTask.value
      return
    }
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      await self.performShutdown()
    }
    shutdownTask = task
    await task.value
  }

  private func performShutdown() async {
    guard !isShutdown else { return }
    let boundaryOccurredAt = clock()
    let boundaryTimeZone = timeZoneIdentifier()
    if workerTask == nil, !isFailed { startWorker() }
    closeAdmission()
    isShutdown = true
    reconcileRequested = false
    reconcileTask?.cancel()
    reconcileTask = nil
    resumeReconcileWaiters()
    if isFailed {
      await workerTask?.value
    } else {
      do {
        let state = try CollectorState(
          kind: .applicationWindowContext,
          authorization: currentAuthorization(),
          runtime: .unconfigured
        )
        await withCheckedContinuation { continuation in
          let accepted = mailbox.beginDraining(
            with: .collectorState(
              state,
              occurredAt: boundaryOccurredAt,
              timeZoneIdentifier: boundaryTimeZone,
              boundary: .shutdown,
              completion: { _ in continuation.resume() }
            ))
          if !accepted { continuation.resume() }
        }
        await workerTask?.value
      } catch {
        failInvariant()
      }
    }
    lifecycleObservation?.cancel()
    lifecycleObservation = nil
    workerTask = nil
    if !isFailed { publish(.stopped) }
    finishSubscribers()
  }

  private func startWorker() {
    guard workerTask == nil else { return }
    let mailbox = mailbox
    let writeLane = writeLane
    workerTask = Task.detached { [weak self] in
      await Self.runWorkerOffMainActor(
        mailbox: mailbox,
        writeLane: writeLane,
        completion: { [weak self] work, result in
          await self?.applyDurableResult(work, result: result)
        },
        onDrain: { [weak self] in
          await self?.resumeDeferredReconcileAfterDrain()
        }
      )
    }
  }

  nonisolated private static func runWorkerOffMainActor(
    mailbox: H1CollectionMailbox<Work>,
    writeLane: H1CollectionWriteLane,
    completion:
      @escaping @Sendable (
        Work,
        Result<H1CollectionWriteOutcome, H1CollectionWriteFailure>
      ) async -> (@MainActor @Sendable () -> Void)?,
    onDrain: @escaping @Sendable () async -> Void
  ) async {
    var iterator = mailbox.signals.makeAsyncIterator()
    while !Task.isCancelled {
      drain: while true {
        switch mailbox.poll() {
        case .work(let work):
          let result = await executeDurable(work, writeLane: writeLane)
          let workCompletion = await completion(work, result)
          mailbox.completeWork()
          await workCompletion?()
        case .wait:
          await onDrain()
          break drain
        case .finished:
          return
        }
      }
      guard await iterator.next() != nil else { return }
    }
  }

  nonisolated private static func executeDurable(
    _ work: Work,
    writeLane: H1CollectionWriteLane
  ) async
    -> Result<H1CollectionWriteOutcome, H1CollectionWriteFailure>
  {
    do {
      switch work {
      case .candidate(let admitted):
        return .success(try await writeLane.persistCandidate(admitted))
      case .collectorState(let state, let occurredAt, let capturedTimeZone, _, _):
        return .success(
          try await writeLane.persistState(
            state,
            occurredAt: occurredAt,
            timeZoneIdentifier: capturedTimeZone
          ))
      case .authorizationLoss(let observedAt, let capturedTimeZone, let state):
        return .success(
          try await writeLane.persistAuthorizationLoss(
            observedAt: observedAt,
            timeZoneIdentifier: capturedTimeZone,
            state: state
          ))
      }
    } catch let failure as H1CollectionWriteFailure {
      return .failure(failure)
    } catch {
      return .failure(.serviceUnavailable)
    }
  }

  private func applyDurableResult(
    _ work: Work,
    result: Result<H1CollectionWriteOutcome, H1CollectionWriteFailure>
  ) -> (@MainActor @Sendable () -> Void)? {
    if case .candidate(let admitted) = work {
      admittedCandidateKeys.remove(admitted.candidate.equivalenceKey)
    }
    let completion: (@MainActor @Sendable (Bool) -> Void)?
    if case .collectorState(_, _, _, _, let stateCompletion) = work {
      completion = stateCompletion
    } else {
      completion = nil
    }
    switch result {
    case .success(let outcome):
      advanceHistory(by: outcome.insertedCount)
      guard let completion else { return nil }
      return { completion(true) }
    case .failure(let failure):
      handleWriteFailure(failure)
      guard let completion else { return nil }
      return { completion(false) }
    }
  }

  private func receive(_ candidate: FilteredApplicationWindowCandidate) {
    guard acceptsObservations, !isShutdown, !isFailed else { return }
    if candidate.disposition == .accessibilityDenied {
      admitAuthorizationLoss(observedAt: candidate.observedAt)
      return
    }
    guard !admittedCandidateKeys.contains(candidate.equivalenceKey) else { return }
    let admitted = H1AdmittedCandidate(
      candidate: candidate,
      timeZoneIdentifier: timeZoneIdentifier()
    )
    switch mailbox.offerOrdinary(.candidate(admitted)) {
    case .accepted:
      admittedCandidateKeys.insert(candidate.equivalenceKey)
    case .overflow:
      failForOverflow()
    case .rejected:
      break
    }
  }

  private func requestReconcileAndWait(
    allowsAuthorizationRecovery: Bool = false,
    boundaryContext: NegativeControlBoundaryContext? = nil
  ) async {
    guard !isShutdown, !isFailed else { return }
    await withCheckedContinuation { continuation in
      reconcileWaiters.append(continuation)
      requestReconcile(
        allowsAuthorizationRecovery: allowsAuthorizationRecovery,
        boundaryContext: boundaryContext
      )
    }
  }

  private func requestReconcile(
    allowsAuthorizationRecovery: Bool = false,
    boundaryContext: NegativeControlBoundaryContext? = nil
  ) {
    guard !isShutdown, !isFailed else {
      resumeReconcileWaiters()
      return
    }
    authorizationRecoveryRequested =
      authorizationRecoveryRequested || allowsAuthorizationRecovery
    if let boundaryContext { reconcileBoundaryContext = boundaryContext }
    reconcileRequested = true
    guard mailbox.canReconcile else { return }
    guard reconcileTask == nil else { return }
    reconcileTask = Task { @MainActor [weak self] in
      guard let self else { return }
      while self.reconcileRequested, !self.isShutdown, !self.isFailed {
        self.reconcileRequested = false
        let allowsRecovery = self.authorizationRecoveryRequested
        self.authorizationRecoveryRequested = false
        await self.performReconcile(
          allowsAuthorizationRecovery: allowsRecovery,
          boundaryContext: self.reconcileBoundaryContext
        )
      }
      self.reconcileTask = nil
      self.resumeReconcileWaiters()
    }
  }

  private func resumeDeferredReconcileAfterDrain() {
    guard reconcileRequested else { return }
    requestReconcile()
  }

  private func resumeReconcileWaiters() {
    let waiters = reconcileWaiters
    reconcileWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
  }

  private func performReconcile(
    allowsAuthorizationRecovery: Bool,
    boundaryContext: NegativeControlBoundaryContext?
  ) async {
    guard !isShutdown, !isFailed else { return }
    let reconcileGeneration = generation
    let consent: PersistedCollectorConsent
    let global: GlobalCollectionControl
    do {
      async let loadedConsent = consentRepository.consent(for: .applicationWindowContext)
      async let loadedGlobal = consentRepository.globalControl()
      (consent, global) = try await (loadedConsent, loadedGlobal)
    } catch {
      failForStorage()
      return
    }
    guard generation == reconcileGeneration, !isShutdown, !isFailed else { return }

    let authorization = currentAuthorization(allowsRecovery: allowsAuthorizationRecovery)
    updateSafetyPresentation(
      consentGate: Self.consentGate(for: consent),
      authorization: authorization
    )
    guard let pendingNegativeControl else {
      // No pending negative command.
      return await performReconcileAfterHoldCheck(
        consent: consent,
        global: global,
        authorization: authorization,
        reconcileGeneration: reconcileGeneration,
        boundaryContext: boundaryContext
      )
    }
    closeAdmission()
    if pendingNegativeControlPersistenceFailed {
      publish(.failed(.controlPersistenceUnavailable))
    } else {
      publish(.holdingNegativeControl(pendingNegativeControl))
    }
  }

  private func performReconcileAfterHoldCheck(
    consent: PersistedCollectorConsent,
    global: GlobalCollectionControl,
    authorization: AuthorizationState,
    reconcileGeneration: UInt64,
    boundaryContext: NegativeControlBoundaryContext?
  ) async {
    guard generation == reconcileGeneration, !isShutdown, !isFailed else { return }
    guard consent.permitsCollection else {
      let boundaryGeneration = closeAdmissionForReconcileIfNeeded()
      await persistStoppedGate(
        authorization: authorization,
        runtime: .unconfigured,
        status: consent.consent.status == .paused ? .pausedByUser : .disabled,
        reconcileGeneration: boundaryGeneration,
        occurredAt: boundaryContext?.occurredAt ?? clock(),
        timeZoneIdentifier: boundaryContext?.timeZoneIdentifier,
        boundaryContext: boundaryContext
      )
      return
    }
    guard !global.isPaused else {
      activePauseReasons.insert(.globalUserPause)
      let boundaryGeneration = closeAdmissionForReconcileIfNeeded()
      await suspendDirect(
        reasons: activePauseReasons,
        authorization: authorization,
        reconcileGeneration: boundaryGeneration,
        occurredAt: boundaryContext?.occurredAt ?? clock(),
        timeZoneIdentifier: boundaryContext?.timeZoneIdentifier,
        boundaryContext: boundaryContext
      )
      return
    }
    activePauseReasons.remove(.globalUserPause)
    guard authorization.permitsCollection else {
      let boundaryGeneration = closeAdmissionForReconcileIfNeeded()
      await persistStoppedGate(
        authorization: authorization,
        runtime: .waitingForAuthorization,
        status: .waitingForAuthorization,
        reconcileGeneration: boundaryGeneration,
        occurredAt: clock(),
        timeZoneIdentifier: nil,
        boundaryContext: boundaryContext
      )
      return
    }
    synchronizeLifecyclePauseReasons()
    guard activePauseReasons.isEmpty else {
      let boundaryGeneration = closeAdmissionForReconcileIfNeeded()
      await suspendDirect(
        reasons: activePauseReasons,
        authorization: authorization,
        reconcileGeneration: boundaryGeneration,
        occurredAt: clock(),
        timeZoneIdentifier: nil,
        boundaryContext: boundaryContext
      )
      return
    }

    // A health refresh is a read-only gate check. When the accepted gates are
    // unchanged, keep the existing monitor and durable running state intact.
    // Closing/reopening here used to manufacture a collector transition every
    // refresh interval, which both churned SQLite and split unrelated
    // foreground-duration projections into thirty-second fragments.
    if acceptsObservations, monitor?.isRunning == true {
      return
    }

    let admittedGeneration = closeAdmissionForReconcileIfNeeded()
    let committed: Bool
    do {
      committed = await persist(
        try CollectorState(
          kind: .applicationWindowContext,
          authorization: authorization,
          runtime: .running
        ),
        occurredAt: clock()
      )
    } catch {
      failInvariant()
      return
    }
    guard committed, admittedGeneration == generation, pendingNegativeControl == nil, !isShutdown,
      !isFailed
    else { return }
    guard mailbox.reopenAfterSuccessfulReconcile() else { return }
    consumeBoundaryContext(boundaryContext)
    acceptsObservations = true
    installAndStartMonitor()
    guard generation == admittedGeneration, !accessibilityDeniedLatch, !isShutdown, !isFailed
    else { return }
    publish(.running)
  }

  private func suspendDirect(
    reasons: Set<CollectionPauseReason>,
    authorization: AuthorizationState,
    reconcileGeneration: UInt64,
    occurredAt: Date,
    timeZoneIdentifier: String?,
    boundaryContext: NegativeControlBoundaryContext?
  ) async {
    do {
      let committed = await persist(
        try CollectorState(
          kind: .applicationWindowContext,
          authorization: authorization,
          runtime: .paused(
            reasons: reasons,
            resumeState: authorization.permitsCollection
              ? .running : .waitingForAuthorization
          )
        ),
        occurredAt: occurredAt,
        timeZoneIdentifier: timeZoneIdentifier
      )
      guard committed, generation == reconcileGeneration else { return }
    } catch {
      failInvariant()
      return
    }
    guard pendingNegativeControl == nil, !isShutdown, !isFailed else { return }
    consumeBoundaryContext(boundaryContext)
    publish(.paused(reasons))
  }

  private func persistStoppedGate(
    authorization: AuthorizationState,
    runtime: CollectorRuntimeState,
    status: H1CollectionRuntimeStatus,
    reconcileGeneration: UInt64,
    occurredAt: Date,
    timeZoneIdentifier: String?,
    boundaryContext: NegativeControlBoundaryContext?
  ) async {
    do {
      let committed = await persist(
        try CollectorState(
          kind: .applicationWindowContext,
          authorization: authorization,
          runtime: runtime
        ),
        occurredAt: occurredAt,
        timeZoneIdentifier: timeZoneIdentifier
      )
      guard committed, generation == reconcileGeneration, pendingNegativeControl == nil,
        !isShutdown, !isFailed
      else { return }
      consumeBoundaryContext(boundaryContext)
      publish(status)
    } catch {
      failInvariant()
    }
  }

  private func admitAuthorizationLoss(observedAt: Date) {
    let capturedTimeZone = timeZoneIdentifier()
    accessibilityDeniedLatch = true
    closeAdmission()
    preemptQueuedReconcile()
    do {
      let state = try CollectorState(
        kind: .applicationWindowContext,
        authorization: .revoked,
        runtime: .waitingForAuthorization
      )
      switch enqueueHardBoundary(
        .authorizationLoss(
          observedAt: observedAt,
          timeZoneIdentifier: capturedTimeZone,
          state: state
        )
      ) {
      case .accepted:
        updateSafetyPresentation(
          consentGate: snapshot.consentGate,
          authorization: .revoked
        )
        publish(.waitingForAuthorization)
      case .duplicate:
        updateSafetyPresentation(
          consentGate: snapshot.consentGate,
          authorization: .revoked
        )
        publish(.waitingForAuthorization)
      case .overflow, .rejected:
        failForCriticalBoundaryOverflow(
          occurredAt: observedAt,
          timeZoneIdentifier: capturedTimeZone
        )
      }
    } catch {
      failInvariant()
    }
  }

  private func receiveLifecycle(_ event: SystemLifecycleEvent) {
    guard !isShutdown, !isFailed else { return }
    switch event {
    case .systemWillSleep:
      let wasAwake = isSystemAwake
      isSystemAwake = false
      let inserted = activePauseReasons.insert(.systemSleep).inserted
      lifecycleAvailability = SystemLifecycleAvailability(
        isUserSessionActive: lifecycleAvailability.isUserSessionActive,
        areScreensAwake: false
      )
      guard wasAwake || inserted else { return }
      enqueueBoundary(reason: .systemSleep)
    case .userSessionDidResignActive:
      let inserted = activePauseReasons.insert(.userSessionInactive).inserted
      lifecycleAvailability = SystemLifecycleAvailability(
        isUserSessionActive: false,
        areScreensAwake: lifecycleAvailability.areScreensAwake
      )
      guard inserted else { return }
      enqueueBoundary(reason: .userSessionInactive)
    case .screensDidSleep:
      let inserted = activePauseReasons.insert(.screensAsleep).inserted
      lifecycleAvailability = SystemLifecycleAvailability(
        isUserSessionActive: lifecycleAvailability.isUserSessionActive,
        areScreensAwake: false
      )
      guard inserted else { return }
      enqueueBoundary(reason: .screensAsleep)
    case .systemDidWake:
      isSystemAwake = true
      activePauseReasons.remove(.systemSleep)
      lifecycleAvailability = lifecycleSource.currentAvailability()
      enqueuePositiveReconcile()
    case .screensDidWake:
      activePauseReasons.remove(.screensAsleep)
      let current = lifecycleSource.currentAvailability()
      lifecycleAvailability = SystemLifecycleAvailability(
        isUserSessionActive: lifecycleAvailability.isUserSessionActive,
        areScreensAwake: current.areScreensAwake
      )
      enqueuePositiveReconcile()
    case .userSessionDidBecomeActive:
      activePauseReasons.remove(.userSessionInactive)
      let current = lifecycleSource.currentAvailability()
      lifecycleAvailability = SystemLifecycleAvailability(
        isUserSessionActive: current.isUserSessionActive,
        areScreensAwake: lifecycleAvailability.areScreensAwake
      )
      enqueuePositiveReconcile()
    }
  }

  private func enqueueBoundary(reason: CollectionPauseReason) {
    let occurredAt = clock()
    let capturedTimeZone = timeZoneIdentifier()
    closeAdmission()
    preemptQueuedReconcile()
    let authorization = currentAuthorization()
    do {
      let state = try CollectorState(
        kind: .applicationWindowContext,
        authorization: authorization,
        runtime: .paused(
          reasons: activePauseReasons,
          resumeState: authorization.permitsCollection
            ? .running : .waitingForAuthorization
        )
      )
      switch enqueueHardBoundary(
        .collectorState(
          state,
          occurredAt: occurredAt,
          timeZoneIdentifier: capturedTimeZone,
          boundary: .lifecycle,
          completion: nil
        ),
        deduplicatingEquivalentLifecycle: true
      ) {
      case .accepted:
        publish(.paused(activePauseReasons))
      case .duplicate:
        publish(.paused(activePauseReasons))
      case .overflow, .rejected:
        failForCriticalBoundaryOverflow(
          occurredAt: occurredAt,
          timeZoneIdentifier: capturedTimeZone
        )
      }
    } catch {
      failInvariant()
    }
  }

  private func enqueuePositiveReconcile() {
    requestReconcile()
  }

  @discardableResult
  private func enqueueHardBoundary(
    _ work: Work,
    deduplicatingEquivalentLifecycle: Bool = false
  ) -> H1CollectionMailbox<Work>.BoundaryOffer {
    mailbox.reserveBoundary(work) { queued, incoming in
      guard deduplicatingEquivalentLifecycle else { return false }
      return Self.areEquivalentLifecycleBoundaries(queued, incoming)
    }
  }

  private static func areEquivalentLifecycleBoundaries(_ lhs: Work, _ rhs: Work) -> Bool {
    guard
      case .collectorState(let leftState, _, _, .lifecycle, _) = lhs,
      case .collectorState(let rightState, _, _, .lifecycle, _) = rhs
    else { return false }
    return leftState == rightState
  }

  private func preemptQueuedReconcile() {
    reconcileRequested = false
    authorizationRecoveryRequested = false
    if reconcileTask == nil { resumeReconcileWaiters() }
  }

  private func consumeBoundaryContext(_ context: NegativeControlBoundaryContext?) {
    guard reconcileBoundaryContext == context else { return }
    reconcileBoundaryContext = nil
  }

  private func persist(
    _ state: CollectorState,
    occurredAt: Date,
    timeZoneIdentifier: String? = nil
  ) async -> Bool {
    await withCheckedContinuation { continuation in
      let offer = enqueueHardBoundary(
        .collectorState(
          state,
          occurredAt: occurredAt,
          timeZoneIdentifier: timeZoneIdentifier ?? self.timeZoneIdentifier(),
          boundary: .gate,
          completion: { succeeded in continuation.resume(returning: succeeded) }
        ))
      if offer != .accepted {
        continuation.resume(returning: false)
        switch offer {
        case .overflow:
          failForCriticalBoundaryOverflow(
            occurredAt: occurredAt,
            timeZoneIdentifier: timeZoneIdentifier ?? self.timeZoneIdentifier()
          )
        case .duplicate, .rejected:
          failInvariant()
        case .accepted:
          break
        }
      }
    }
  }

  private func advanceHistory(by insertedCount: UInt64) {
    guard insertedCount > 0 else { return }
    let addition = snapshot.historyRevision.addingReportingOverflow(insertedCount)
    guard !addition.overflow else {
      failInvariant()
      return
    }
    snapshot = H1CollectionRuntimeSnapshot(
      status: snapshot.status,
      historyRevision: addition.partialValue,
      consentGate: snapshot.consentGate,
      authorization: snapshot.authorization,
      pendingNegativeControl: pendingNegativeControl
    )
    broadcastHistory(addition.partialValue)
    for continuation in snapshotSubscribers.values { continuation.yield(snapshot) }
  }

  private func installAndStartMonitor() {
    guard monitor == nil else {
      monitor?.start()
      return
    }
    if let platformSource, let privacyFilter {
      monitor = ApplicationWindowContextMonitor(
        testingPlatformSource: platformSource,
        testingPrivacyFilter: privacyFilter,
        clock: clock,
        outputHandler: { [weak self] candidate in
          self?.receive(candidate)
        }
      )
    } else {
      monitor = ApplicationWindowContextMonitor(
        excludedBundleIdentifiers: excludedBundleIdentifiers,
        clock: clock,
        outputHandler: { [weak self] candidate in
          self?.receive(candidate)
        }
      )
    }
    monitor?.start()
  }

  private func closeAdmission() {
    let next = generation.addingReportingOverflow(1)
    if next.overflow {
      acceptsObservations = false
      monitor?.stop()
      publish(.failed(.invariantViolated))
      discardPendingWork()
      sealAfterFailure()
      return
    }
    generation = next.partialValue
    acceptsObservations = false
    monitor?.stop()
  }

  private func closeAdmissionForReconcileIfNeeded() -> UInt64 {
    if acceptsObservations || monitor?.isRunning == true { closeAdmission() }
    return generation
  }

  private func failForOverflow() {
    let occurredAt = clock()
    let capturedTimeZone = timeZoneIdentifier()
    closeAdmission()
    preemptQueuedReconcile()
    publish(.degraded(.queueOverflow))
    do {
      let state = try CollectorState(
        kind: .applicationWindowContext,
        authorization: currentAuthorization(),
        runtime: .degraded(.resourcePressure)
      )
      let offer = enqueueHardBoundary(
        .collectorState(
          state,
          occurredAt: occurredAt,
          timeZoneIdentifier: capturedTimeZone,
          boundary: .overflow,
          completion: nil
        ))
      if offer != .accepted {
        failForCriticalBoundaryOverflow(
          occurredAt: occurredAt,
          timeZoneIdentifier: capturedTimeZone
        )
      }
    } catch {
      failInvariant()
    }
  }

  private func failForCriticalBoundaryOverflow(
    occurredAt: Date,
    timeZoneIdentifier: String
  ) {
    guard !isFailed, !isShutdown else { return }
    closeAdmission()
    preemptQueuedReconcile()
    do {
      let terminalState = try CollectorState(
        kind: .applicationWindowContext,
        authorization: currentAuthorization(),
        runtime: .degraded(.resourcePressure)
      )
      let accepted = mailbox.beginDraining(
        with: .collectorState(
          terminalState,
          occurredAt: occurredAt,
          timeZoneIdentifier: timeZoneIdentifier,
          boundary: .overflow,
          completion: nil
        ))
      publish(.failed(.queueOverflow))
      sealAfterFailure()
      if !accepted { discardPendingWork() }
    } catch {
      failInvariant()
    }
  }

  private func failForStorage() {
    closeAdmission()
    publish(.failed(.storageUnavailable))
    discardPendingWork()
    sealAfterFailure()
  }

  private func failForService() {
    closeAdmission()
    publish(.failed(.serviceUnavailable))
    discardPendingWork()
    sealAfterFailure()
  }

  private func failInvariant() {
    closeAdmission()
    publish(.failed(.invariantViolated))
    discardPendingWork()
    sealAfterFailure()
  }

  private func handleWriteFailure(_ error: Error) {
    switch error {
    case H1CollectionWriteFailure.storageUnavailable(let committedCount):
      advanceHistory(by: committedCount)
      failForStorage()
    case H1CollectionWriteFailure.serviceUnavailable:
      failForService()
    case H1CollectionWriteFailure.invariantViolated:
      failInvariant()
    default:
      failForService()
    }
  }

  private func currentAuthorization(allowsRecovery: Bool = false) -> AuthorizationState {
    let preflightAuthorization = authorizationPreflight.snapshot(at: clock()).accessibility
    if accessibilityDeniedLatch {
      guard allowsRecovery, preflightAuthorization == .authorized else { return .revoked }
      accessibilityDeniedLatch = false
    }
    if preflightAuthorization == .authorized {
      hasObservedAuthorizedAccessibility = true
      return .authorized
    }
    return hasObservedAuthorizedAccessibility ? .revoked : .unknown
  }

  private func synchronizeLifecyclePauseReasons() {
    if isSystemAwake {
      activePauseReasons.remove(.systemSleep)
    } else {
      activePauseReasons.insert(.systemSleep)
    }
    if lifecycleAvailability.isUserSessionActive {
      activePauseReasons.remove(.userSessionInactive)
    } else {
      activePauseReasons.insert(.userSessionInactive)
    }
    if lifecycleAvailability.areScreensAwake {
      activePauseReasons.remove(.screensAsleep)
    } else {
      activePauseReasons.insert(.screensAsleep)
    }
  }

  private func sealAfterFailure() {
    isFailed = true
    lifecycleObservation?.cancel()
    lifecycleObservation = nil
    reconcileRequested = false
    reconcileTask?.cancel()
    reconcileTask = nil
    resumeReconcileWaiters()
  }

  private func discardPendingWork() {
    let discarded = mailbox.fail()
    for work in discarded {
      switch work {
      case .candidate(let admitted):
        admittedCandidateKeys.remove(admitted.candidate.equivalenceKey)
      case .authorizationLoss:
        break
      case .collectorState(_, _, _, _, let completion):
        completion?(false)
      }
    }
  }

  private func publish(_ status: H1CollectionRuntimeStatus) {
    snapshot = H1CollectionRuntimeSnapshot(
      status: status,
      historyRevision: snapshot.historyRevision,
      consentGate: snapshot.consentGate,
      authorization: snapshot.authorization,
      pendingNegativeControl: pendingNegativeControl
    )
    for continuation in snapshotSubscribers.values { continuation.yield(snapshot) }
  }

  private func updateSafetyPresentation(
    consentGate: H1CollectionConsentGate,
    authorization: AuthorizationState
  ) {
    snapshot = H1CollectionRuntimeSnapshot(
      status: snapshot.status,
      historyRevision: snapshot.historyRevision,
      consentGate: consentGate,
      authorization: authorization,
      pendingNegativeControl: pendingNegativeControl
    )
    for continuation in snapshotSubscribers.values { continuation.yield(snapshot) }
  }

  private static func consentGate(for consent: PersistedCollectorConsent)
    -> H1CollectionConsentGate
  {
    if consent.renewalRequired { return .renewalRequired }
    switch consent.consent.status {
    case .unconfirmed: return .unconfirmed
    case .disabled: return .disabled
    case .paused: return .paused
    case .enabled: return .enabled
    }
  }

  private func finishSubscribers() {
    for continuation in historySubscribers.values { continuation.finish() }
    historySubscribers.removeAll()
    for continuation in snapshotSubscribers.values { continuation.finish() }
    snapshotSubscribers.removeAll()
  }

  private func broadcastHistory(_ revision: UInt64) {
    for continuation in historySubscribers.values {
      continuation.yield(revision)
    }
  }
}
