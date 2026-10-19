import DaydayCore
import Foundation
import Testing

@testable import DaydayCapture

@MainActor
struct ForegroundApplicationDurationRuntimeTests {
  @Test("system activation writes one content-free foreground fact and lifecycle closes it")
  func activationAndLifecycleProduceBoundedForegroundFacts() async throws {
    let repository = ForegroundDurationRecordingRepository()
    let consent = try ForegroundDurationConsentRepository()
    let source = ForegroundDurationPlatformSource(
      candidate: .init(
        observedAt: Date(timeIntervalSince1970: 1),
        bundleIdentifier: "com.example.editor",
        displayLabel: "编辑器"
      )
    )
    let lifecycle = ForegroundDurationLifecycleSource()
    let clock = ForegroundDurationClock(date: Date(timeIntervalSince1970: 1_800_000_000))
    let runtime = ForegroundApplicationDurationRuntime(
      repository: repository,
      consentRepository: consent,
      lifecycleSource: lifecycle,
      clock: { clock.date },
      timeZoneIdentifier: { "UTC" },
      platformSource: source,
      resolveApplication: { bundleIdentifier, _ in
        let value = bundleIdentifier == "com.example.editor"
          ? "00000000-0000-0000-0000-000000000001"
          : "00000000-0000-0000-0000-000000000002"
        return ApplicationIdentifier(rawValue: UUID(uuidString: value)!)
      }
    )

    await runtime.start()
    try await eventually { try await foregroundEvents(from: repository).count == 1 }

    source.sendActivation()
    try await Task.sleep(for: .milliseconds(20))
    #expect(try await foregroundEvents(from: repository).count == 1)

    clock.date = clock.date.addingTimeInterval(30)
    source.candidate = .init(
      observedAt: clock.date,
      bundleIdentifier: "com.example.browser",
      displayLabel: "浏览器"
    )
    source.sendActivation()
    try await eventually { try await foregroundEvents(from: repository).count == 2 }

    clock.date = clock.date.addingTimeInterval(30)
    lifecycle.send(.systemWillSleep)
    try await eventually {
      let events = try await foregroundEvents(from: repository)
      return events.last?.kind == .systemBoundary
    }

    let events = try await foregroundEvents(from: repository)
    #expect(events.map { $0.kind } == [
      ObjectiveEventKind.applicationContextChanged,
      ObjectiveEventKind.applicationContextChanged,
      ObjectiveEventKind.systemBoundary,
    ])
    let records = await repository.applicationRecords()
    let hasContent = records.contains {
      $0.windowTitleSnapshot != nil || $0.documentFilenameHint != nil
    }
    #expect(!hasContent)
    await runtime.shutdown()
  }

  private func foregroundEvents(from repository: ForegroundDurationRecordingRepository) async throws
    -> [ObjectiveEvent]
  {
    try await repository.fetch(
      occurredIn: Date(timeIntervalSince1970: 1_700_000_000)..<Date(timeIntervalSince1970: 1_900_000_000)
    ).filter {
      $0.source.collectorVersion == ApplicationContextObservationVersion.foregroundApplication
    }.sorted { $0.occurredAt < $1.occurredAt }
  }

  private func eventually(
    timeout: Duration = .seconds(1),
    _ condition: @escaping @Sendable () async throws -> Bool
  ) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
      if try await condition() { return }
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(try await condition())
  }
}

private actor ForegroundDurationRecordingRepository: ObjectiveLinkedRecordRepository {
  private var events: [ObjectiveEvent] = []
  private var applicationWrites: [ApplicationContextWrite] = []

  func insert(_ event: ObjectiveEvent) async throws -> ObjectiveEventInsertResult {
    events.append(event)
    return .inserted
  }

  func fetch(occurredIn range: Range<Date>) async throws -> [ObjectiveEvent] {
    events.filter { range.contains($0.occurredAt) }
  }

  func insertApplicationContext(_ write: ApplicationContextWrite) async throws
    -> ObjectiveEventInsertResult
  {
    events.append(write.event)
    applicationWrites.append(write)
    return .inserted
  }

  func insertCollectorState(_ write: CollectorStateWrite) async throws -> ObjectiveEventInsertResult {
    events.append(write.event)
    return .inserted
  }

  func insertCollectionSuppression(_ write: CollectionSuppressionWrite) async throws
    -> ObjectiveEventInsertResult
  {
    events.append(write.event)
    return .inserted
  }

  func fetchApplicationContext(for eventID: EventID) async throws -> ApplicationContextRecord? {
    applicationWrites.first { $0.event.id == eventID }?.record
  }

  func fetchCollectorState(for eventID: EventID) async throws -> CollectorStateRecord? { nil }
  func fetchCollectionSuppression(for eventID: EventID) async throws
    -> CollectionSuppressionRecord? { nil }
  func applicationRecords() -> [ApplicationContextRecord] { applicationWrites.map(\.record) }
}

private actor ForegroundDurationConsentRepository: CollectionConsentRepository {
  private let persisted: PersistedCollectorConsent

  init() throws {
    let confirmation = try UserConsentConfirmation(
      collector: .applicationWindowContext,
      confirmedAt: Date(timeIntervalSince1970: 1),
      disclosureVersion: "test-v1"
    )
    let enabled = try CollectorConsentStateMachine.transition(
      .enable(confirmation),
      from: CollectorConsent(collector: .applicationWindowContext)
    )
    persisted = .init(consent: enabled, lastAction: .enable(confirmation), revision: 1)
  }

  func consent(for collector: CollectorKind) async throws -> PersistedCollectorConsent { persisted }
  func transition(
    _ action: CollectorConsentAction,
    expectedRevision: UInt64
  ) async throws -> PersistedCollectorConsent { persisted }
  func globalControl() async throws -> GlobalCollectionControl { .init(isPaused: false, revision: 0) }
  func setGlobalPaused(
    _ isPaused: Bool,
    expectedRevision: UInt64
  ) async throws -> GlobalCollectionControl { .init(isPaused: isPaused, revision: 1) }
}

@MainActor
private final class ForegroundDurationPlatformSource: ForegroundApplicationPlatformSourcing {
  var candidate: ForegroundApplicationCandidate?
  private var handler: (@MainActor @Sendable () -> Void)?

  init(candidate: ForegroundApplicationCandidate?) { self.candidate = candidate }
  func frontmostApplication() -> ForegroundApplicationCandidate? { candidate }
  func observeActivation(
    _ handler: @escaping @MainActor @Sendable () -> Void
  ) -> any ForegroundApplicationObserving {
    self.handler = handler
    return ForegroundDurationObservation { [weak self] in self?.handler = nil }
  }
  func sendActivation() { handler?() }
}

@MainActor
private final class ForegroundDurationObservation: ForegroundApplicationObserving {
  private let onCancel: () -> Void
  init(onCancel: @escaping () -> Void) { self.onCancel = onCancel }
  func cancel() { onCancel() }
}

@MainActor
private final class ForegroundDurationLifecycleSource: SystemLifecycleNotificationSource {
  private var handler: (@MainActor @Sendable (SystemLifecycleEvent) -> Void)?
  func currentAvailability() -> SystemLifecycleAvailability {
    .init(isUserSessionActive: true, areScreensAwake: true)
  }
  func observe(
    _ handler: @escaping @MainActor @Sendable (SystemLifecycleEvent) -> Void
  ) -> any SystemLifecycleObservation {
    self.handler = handler
    return ForegroundDurationLifecycleObservation { [weak self] in self?.handler = nil }
  }
  func send(_ event: SystemLifecycleEvent) { handler?(event) }
}

@MainActor
private final class ForegroundDurationLifecycleObservation: SystemLifecycleObservation {
  private let onCancel: () -> Void
  init(onCancel: @escaping () -> Void) { self.onCancel = onCancel }
  func cancel() { onCancel() }
}

private final class ForegroundDurationClock: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Date
  var date: Date {
    get { lock.withLock { value } }
    set { lock.withLock { value = newValue } }
  }
  init(date: Date) { self.value = date }
}
