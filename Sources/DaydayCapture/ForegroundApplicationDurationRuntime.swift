@preconcurrency import AppKit
import DaydayCore
import Foundation

/// A content-free sample of macOS's single global frontmost application.
/// Raw platform identity remains inside Capture until the injected resolver
/// turns it into Dayday's per-installation application identity.
struct ForegroundApplicationCandidate: Sendable, Equatable {
  let observedAt: Date
  let bundleIdentifier: String
  let displayLabel: String
}

@MainActor
protocol ForegroundApplicationObserving: AnyObject {
  func cancel()
}

@MainActor
protocol ForegroundApplicationPlatformSourcing: AnyObject {
  func frontmostApplication() -> ForegroundApplicationCandidate?
  func observeActivation(
    _ handler: @escaping @MainActor @Sendable () -> Void
  ) -> any ForegroundApplicationObserving
}

@MainActor
private final class MacOSForegroundApplicationPlatformSource: ForegroundApplicationPlatformSourcing {
  func frontmostApplication() -> ForegroundApplicationCandidate? {
    guard let application = NSWorkspace.shared.frontmostApplication,
      let bundleIdentifier = Self.admittedBundleIdentifier(application.bundleIdentifier),
      let displayLabel = Self.admittedDisplayLabel(application.localizedName)
    else { return nil }
    return .init(observedAt: .now, bundleIdentifier: bundleIdentifier, displayLabel: displayLabel)
  }

  func observeActivation(
    _ handler: @escaping @MainActor @Sendable () -> Void
  ) -> any ForegroundApplicationObserving {
    ForegroundApplicationNotificationObservation(handler: handler)
  }

  private static func admittedBundleIdentifier(_ value: String?) -> String? {
    guard let value,
      value == value.trimmingCharacters(in: .whitespacesAndNewlines),
      !value.isEmpty,
      value.utf8.count <= 255,
      value.utf8.allSatisfy({ byte in
        (48...57).contains(byte) || (65...90).contains(byte)
          || (97...122).contains(byte) || byte == 46 || byte == 45
      })
    else { return nil }
    return value
  }

  private static func admittedDisplayLabel(_ value: String?) -> String? {
    guard let value else { return nil }
    let normalized = value
      .unicodeScalars
      .map { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) ? " " : Character(String($0)) }
      .map(String.init)
      .joined()
      .split(whereSeparator: { $0.isWhitespace })
      .joined(separator: " ")
    guard !normalized.isEmpty, normalized.utf8.count <= 96 else { return nil }
    return normalized
  }
}

@MainActor
private final class ForegroundApplicationNotificationObservation: ForegroundApplicationObserving {
  private let notificationCenter = NSWorkspace.shared.notificationCenter
  private var token: NSObjectProtocol?

  init(handler: @escaping @MainActor @Sendable () -> Void) {
    token = notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification,
      object: nil,
      queue: .main
    ) { _ in
      Task { @MainActor in handler() }
    }
  }

  func cancel() {
    if let token { notificationCenter.removeObserver(token) }
    token = nil
  }

  deinit {
    if let token { notificationCenter.removeObserver(token) }
  }
}

private actor ForegroundApplicationDurationWriteLane {
  typealias IdentityResolver = @Sendable (String, String) async throws -> ApplicationIdentifier?

  private let repository: any ObjectiveLinkedRecordRepository
  private let identityResolver: IdentityResolver
  private var activeApplication: ApplicationIdentifier?

  init(
    repository: any ObjectiveLinkedRecordRepository,
    identityResolver: @escaping IdentityResolver
  ) {
    self.repository = repository
    self.identityResolver = identityResolver
  }

  func persist(
    _ candidate: ForegroundApplicationCandidate,
    timeZoneIdentifier: String
  ) async throws -> Bool {
    guard let identifier = try await identityResolver(
      candidate.bundleIdentifier,
      candidate.displayLabel
    ) else { return false }
    guard identifier != activeApplication else { return false }

    let eventID = EventID()
    let event = try ObjectiveEvent(
      id: eventID,
      kind: .applicationContextChanged,
      occurredAt: candidate.observedAt,
      timeZoneIdentifier: timeZoneIdentifier,
      source: CollectorSource(
        collector: .applicationWindowContext,
        collectorVersion: ApplicationContextObservationVersion.foregroundApplication,
        payloadSchemaVersion: 1
      ),
      securityDisposition: .allowed
    )
    let record = try ApplicationContextRecord(
      eventID: eventID,
      applicationIdentifier: identifier,
      displayLabelSnapshot: candidate.displayLabel
    )
    let result = try await repository.insertApplicationContext(
      ApplicationContextWrite(event: event, record: record)
    )
    activeApplication = identifier
    return result == .inserted
  }

  func closeOpenInterval(
    occurredAt: Date,
    timeZoneIdentifier: String
  ) async throws -> Bool {
    guard activeApplication != nil else { return false }
    let event = try ObjectiveEvent(
      kind: .systemBoundary,
      occurredAt: occurredAt,
      timeZoneIdentifier: timeZoneIdentifier,
      source: CollectorSource(
        collector: .applicationWindowContext,
        collectorVersion: ApplicationContextObservationVersion.foregroundApplication,
        payloadSchemaVersion: 1
      ),
      securityDisposition: .allowed
    )
    let result = try await repository.insert(event)
    activeApplication = nil
    return result == .inserted
  }
}

/// Independent, low-cost foreground timer. It intentionally does not depend
/// on Accessibility or the application/window collector's health checks.
@MainActor
public final class ForegroundApplicationDurationRuntime {
  public typealias ApplicationIdentityResolver = @Sendable (String, String) async throws -> ApplicationIdentifier?

  private let consentRepository: any CollectionConsentRepository
  private let lifecycleSource: any SystemLifecycleNotificationSource
  private let clock: @Sendable () -> Date
  private let timeZoneIdentifier: @Sendable () -> String
  private let platformSource: any ForegroundApplicationPlatformSourcing
  private let writeLane: ForegroundApplicationDurationWriteLane
  private var lifecycleObservation: (any SystemLifecycleObservation)?
  private var activationObservation: (any ForegroundApplicationObserving)?
  private var isShutdown = false
  private var isObserving = false
  private var availability: SystemLifecycleAvailability
  private var historyRevision: UInt64 = 0
  private var historySubscribers: [UUID: AsyncStream<UInt64>.Continuation] = [:]
  private var writeTask: Task<Void, Never>?

  public convenience init(
    repository: any ObjectiveLinkedRecordRepository,
    consentRepository: any CollectionConsentRepository,
    lifecycleSource: any SystemLifecycleNotificationSource = NSWorkspaceSystemLifecycleNotificationSource(),
    clock: @escaping @Sendable () -> Date = Date.init,
    timeZoneIdentifier: @escaping @Sendable () -> String = { TimeZone.autoupdatingCurrent.identifier },
    resolveApplication: @escaping ApplicationIdentityResolver
  ) {
    self.init(
      repository: repository,
      consentRepository: consentRepository,
      lifecycleSource: lifecycleSource,
      clock: clock,
      timeZoneIdentifier: timeZoneIdentifier,
      platformSource: MacOSForegroundApplicationPlatformSource(),
      resolveApplication: resolveApplication
    )
  }

  init(
    repository: any ObjectiveLinkedRecordRepository,
    consentRepository: any CollectionConsentRepository,
    lifecycleSource: any SystemLifecycleNotificationSource,
    clock: @escaping @Sendable () -> Date,
    timeZoneIdentifier: @escaping @Sendable () -> String,
    platformSource: any ForegroundApplicationPlatformSourcing,
    resolveApplication: @escaping ApplicationIdentityResolver
  ) {
    self.consentRepository = consentRepository
    self.lifecycleSource = lifecycleSource
    self.clock = clock
    self.timeZoneIdentifier = timeZoneIdentifier
    self.platformSource = platformSource
    self.writeLane = ForegroundApplicationDurationWriteLane(
      repository: repository,
      identityResolver: resolveApplication
    )
    self.availability = lifecycleSource.currentAvailability()
  }

  public func start() async {
    guard !isShutdown, lifecycleObservation == nil else { return }
    availability = lifecycleSource.currentAvailability()
    lifecycleObservation = lifecycleSource.observe { [weak self] event in
      self?.receiveLifecycle(event)
    }
    await refreshGates()
  }

  public func refreshGates() async {
    guard !isShutdown else { return }
    guard let consent = try? await consentRepository.consent(for: .applicationWindowContext),
      let global = try? await consentRepository.globalControl()
    else { return }
    let shouldObserve = consent.permitsCollection && !global.isPaused && availability.isUserSessionActive
      && availability.areScreensAwake
    guard shouldObserve != isObserving else { return }
    isObserving = shouldObserve
    if shouldObserve {
      activationObservation = platformSource.observeActivation { [weak self] in
        self?.recordCurrentApplication()
      }
      recordCurrentApplication()
    } else {
      activationObservation?.cancel()
      activationObservation = nil
      await closeCurrentInterval()
    }
  }

  /// Mirrors the application collector's negative-control hold: no further
  /// foreground fact may be admitted while the caller durably commits pause
  /// or disable. The caller either refreshes gates after success or keeps this
  /// fail-closed hold after a persistence failure.
  public func holdForNegativeControl() async {
    guard !isShutdown, isObserving else { return }
    isObserving = false
    activationObservation?.cancel()
    activationObservation = nil
    await closeCurrentInterval()
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

  public func shutdown() async {
    guard !isShutdown else { return }
    isShutdown = true
    activationObservation?.cancel()
    activationObservation = nil
    lifecycleObservation?.cancel()
    lifecycleObservation = nil
    await closeCurrentInterval()
    for subscriber in historySubscribers.values { subscriber.finish() }
    historySubscribers.removeAll()
  }

  private func receiveLifecycle(_ event: SystemLifecycleEvent) {
    switch event {
    case .systemWillSleep, .screensDidSleep:
      availability = .init(isUserSessionActive: availability.isUserSessionActive, areScreensAwake: false)
    case .userSessionDidResignActive:
      availability = .init(isUserSessionActive: false, areScreensAwake: availability.areScreensAwake)
    case .systemDidWake, .screensDidWake, .userSessionDidBecomeActive:
      availability = lifecycleSource.currentAvailability()
    }
    Task { await self.refreshGates() }
  }

  private func recordCurrentApplication() {
    guard isObserving, let candidate = platformSource.frontmostApplication() else { return }
    let observedAt = clock()
    guard observedAt.timeIntervalSinceReferenceDate.isFinite else { return }
    let fact = ForegroundApplicationCandidate(
      observedAt: observedAt,
      bundleIdentifier: candidate.bundleIdentifier,
      displayLabel: candidate.displayLabel
    )
    let lane = writeLane
    let timeZoneIdentifier = timeZoneIdentifier()
    let prior = writeTask
    writeTask = Task { [weak self] in
      await prior?.value
      guard !Task.isCancelled else { return }
      guard (try? await lane.persist(fact, timeZoneIdentifier: timeZoneIdentifier)) == true else { return }
      guard let self, !self.isShutdown else { return }
      self.historyRevision &+= 1
      for subscriber in self.historySubscribers.values { subscriber.yield(self.historyRevision) }
    }
  }

  private func closeCurrentInterval() async {
    await writeTask?.value
    let didClose = (try? await writeLane.closeOpenInterval(
      occurredAt: clock(),
      timeZoneIdentifier: timeZoneIdentifier()
    )) == true
    guard didClose, !isShutdown else { return }
    historyRevision &+= 1
    for subscriber in historySubscribers.values { subscriber.yield(historyRevision) }
  }
}
