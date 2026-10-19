import DaydayCore
import Foundation
import Testing

@testable import DaydayStorage

struct CollectionConsentPersistenceTests {
  @Test
  func missingRowIsSyntheticAndFirstEnableUsesCAS() async throws {
    let repository = try SQLiteCollectionConsentRepository(location: .inMemory)
    let initial = try await repository.consent(for: .keyboardAggregates)
    #expect(initial.consent.status == .unconfirmed)
    #expect(initial.revision == 0)

    let confirmation = try confirmation(.keyboardAggregates)
    let enabled = try await repository.transition(.enable(confirmation), expectedRevision: 0)
    #expect(enabled.consent.status == .enabled)
    #expect(enabled.lastAction == .enable)
    #expect(enabled.revision == 1)
    await #expect(throws: CollectionConsentStoreError.revisionConflict) {
      _ = try await repository.transition(.enable(confirmation), expectedRevision: 0)
    }
  }

  @Test
  func globalPauseHasItsOwnRevision() async throws {
    let repository = try SQLiteCollectionConsentRepository(location: .inMemory)
    let paused = try await repository.setGlobalPaused(true, expectedRevision: 0)
    #expect(paused == GlobalCollectionControl(isPaused: true, revision: 1))
    #expect((try await repository.consent(for: .weather)).revision == 0)
    await #expect(throws: CollectionConsentStoreError.revisionConflict) {
      _ = try await repository.setGlobalPaused(false, expectedRevision: 0)
    }
    await #expect(throws: CollectionConsentStoreError.revisionOutOfRange) {
      _ = try await repository.setGlobalPaused(false, expectedRevision: UInt64.max)
    }
  }

  @Test
  func stopIntentReplayIsIdempotentAndRejectsDuplicateScopes() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try CollectionStopIntentStore(markerURL: directory.appendingPathComponent("marker"))
    let intent = try CollectionStopIntent(
      scope: .global, target: .globalPaused, confirmation: nil, expectedRevision: 0,
      targetRevision: 1)
    try await store.create(intent)
    await #expect(throws: CollectionStopIntentStoreError.conflict) {
      try await store.create(intent)
    }

    let repository = try SQLiteCollectionConsentRepository(location: .inMemory)
    try await store.replay(using: repository)
    #expect(
      (try await repository.globalControl()) == GlobalCollectionControl(isPaused: true, revision: 1)
    )
    try await store.replay(using: repository)
    #expect(try await store.unresolved() == [])
  }

  @Test
  func markerUnknownVersionAndUnsafePermissionsFailClosed() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let marker = directory.appendingPathComponent("marker")
    try Data(#"{"version":2,"intents":[]}"#.utf8).write(to: marker)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
    #expect(throws: CollectionStopIntentStoreError.invalidMarker) {
      _ = try CollectionStopIntentStore(markerURL: marker)
    }

    try Data(#"{"version":1,"intents":[]}"#.utf8).write(to: marker)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: marker.path)
    #expect(throws: CollectionStopIntentStoreError.invalidMarker) {
      _ = try CollectionStopIntentStore(markerURL: marker)
    }
  }

  @Test
  func emptyMarkerAndExactTargetConfirmationMismatchRemainFailClosed() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let marker = directory.appendingPathComponent("marker")
    try Data(#"{"version":1,"intents":[]}"#.utf8).write(to: marker)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
    #expect(throws: CollectionStopIntentStoreError.invalidMarker) {
      _ = try CollectionStopIntentStore(markerURL: marker)
    }

    try FileManager.default.removeItem(at: marker)
    let expected = try confirmation(.keyboardAggregates)
    let different = try UserConsentConfirmation(
      collector: .keyboardAggregates, confirmedAt: Date(timeIntervalSince1970: 101),
      disclosureVersion: "dayday-consent-v1")
    let repository = try SQLiteCollectionConsentRepository(location: .inMemory)
    _ = try await repository.transition(.disable(expected), expectedRevision: 0)
    let store = try CollectionStopIntentStore(markerURL: marker)
    try await store.create(
      try CollectionStopIntent(
        scope: .collector(.keyboardAggregates), target: .collectorDisabled, confirmation: different,
        expectedRevision: 0, targetRevision: 1))
    await #expect(throws: CollectionStopIntentStoreError.conflict) {
      try await store.replay(using: repository)
    }
    #expect(try await store.unresolved().count == 1)
  }

  @Test
  func directoryReplacementFailsClosedInsteadOfRedirectingMarkerWrites() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let original = root.appendingPathComponent("Dayday", isDirectory: true)
    try FileManager.default.createDirectory(
      at: original, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let store = try CollectionStopIntentStore(markerURL: original.appendingPathComponent("marker"))
    let retired = root.appendingPathComponent("retired", isDirectory: true)
    try FileManager.default.moveItem(at: original, to: retired)
    try FileManager.default.createDirectory(
      at: original, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    await #expect(throws: CollectionStopIntentStoreError.invalidMarker) {
      try await store.create(
        try CollectionStopIntent(
          scope: .global, target: .globalPaused, confirmation: nil, expectedRevision: 0,
          targetRevision: 1))
    }
    #expect(!FileManager.default.fileExists(atPath: retired.appendingPathComponent("marker").path))
    #expect(!FileManager.default.fileExists(atPath: original.appendingPathComponent("marker").path))
  }

  @Test
  func replayPreservesIntentCreatedWhileRepositoryResolutionIsSuspended() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try CollectionStopIntentStore(markerURL: directory.appendingPathComponent("marker"))
    let first = try CollectionStopIntent(
      scope: .global, target: .globalPaused, confirmation: nil, expectedRevision: 0,
      targetRevision: 1)
    try await store.create(first)
    let repository = try SuspendedGlobalRepository(
      base: SQLiteCollectionConsentRepository(location: .inMemory))
    let replay = Task { try await store.replay(using: repository) }
    await repository.waitUntilGlobalPauseSuspends()

    let confirmation = try confirmation(.weather)
    let second = try CollectionStopIntent(
      scope: .collector(.weather), target: .collectorDisabled, confirmation: confirmation,
      expectedRevision: 0, targetRevision: 1)
    try await store.create(second)
    await repository.resumeGlobalPause()
    await repository.waitUntilCollectorTransitionSuspends()
    #expect(try await store.unresolved() == [second])
    await repository.resumeCollectorTransition()
    try await replay.value
    #expect(try await store.unresolved() == [])
  }

  @Test
  func replayRemovesEachOfMultipleScopesWithoutDroppingLaterIntent() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try CollectionStopIntentStore(markerURL: directory.appendingPathComponent("marker"))
    try await store.create(
      try CollectionStopIntent(
        scope: .global, target: .globalPaused, confirmation: nil, expectedRevision: 0,
        targetRevision: 1))
    let confirmation = try confirmation(.weather)
    try await store.create(
      try CollectionStopIntent(
        scope: .collector(.weather), target: .collectorDisabled, confirmation: confirmation,
        expectedRevision: 0, targetRevision: 1))
    let repository = try SQLiteCollectionConsentRepository(location: .inMemory)
    try await store.replay(using: repository)
    #expect(try await store.unresolved() == [])
    #expect((try await repository.globalControl()).isPaused)
    #expect((try await repository.consent(for: .weather)).consent.status == .disabled)
  }

  private func confirmation(_ collector: CollectorKind) throws -> UserConsentConfirmation {
    try UserConsentConfirmation(
      collector: collector, confirmedAt: Date(timeIntervalSince1970: 100),
      disclosureVersion: "dayday-consent-v1")
  }

  private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    return directory
  }
}

private actor SuspendedGlobalRepository: CollectionConsentRepository {
  private let base: SQLiteCollectionConsentRepository
  private var suspension: CheckedContinuation<Void, Never>?
  private var observer: CheckedContinuation<Void, Never>?
  private var collectorSuspension: CheckedContinuation<Void, Never>?
  private var collectorObserver: CheckedContinuation<Void, Never>?
  private var didSuspend = false
  private var didSuspendCollector = false

  init(base: SQLiteCollectionConsentRepository) { self.base = base }

  func consent(for collector: CollectorKind) async throws -> PersistedCollectorConsent {
    try await base.consent(for: collector)
  }
  func transition(_ action: CollectorConsentAction, expectedRevision: UInt64) async throws
    -> PersistedCollectorConsent
  {
    await withCheckedContinuation { continuation in
      didSuspendCollector = true
      collectorSuspension = continuation
      collectorObserver?.resume()
      collectorObserver = nil
    }
    return try await base.transition(action, expectedRevision: expectedRevision)
  }
  func globalControl() async throws -> GlobalCollectionControl { try await base.globalControl() }

  func setGlobalPaused(_ isPaused: Bool, expectedRevision: UInt64) async throws
    -> GlobalCollectionControl
  {
    await withCheckedContinuation { continuation in
      didSuspend = true
      suspension = continuation
      observer?.resume()
      observer = nil
    }
    return try await base.setGlobalPaused(isPaused, expectedRevision: expectedRevision)
  }

  func waitUntilGlobalPauseSuspends() async {
    if didSuspend { return }
    await withCheckedContinuation { observer = $0 }
  }

  func resumeGlobalPause() {
    suspension?.resume()
    suspension = nil
  }

  func waitUntilCollectorTransitionSuspends() async {
    if didSuspendCollector { return }
    await withCheckedContinuation { collectorObserver = $0 }
  }

  func resumeCollectorTransition() {
    collectorSuspension?.resume()
    collectorSuspension = nil
  }
}
