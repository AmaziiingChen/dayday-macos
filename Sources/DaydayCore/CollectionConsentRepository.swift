import Foundation

/// The closed, durable audit action that produced a collector consent state.
/// It intentionally mirrors, rather than replaces, ``CollectorConsentStateMachine``.
public enum CollectorConsentActionKind: String, Codable, CaseIterable, Sendable {
  case enable
  case disable
  case pause
  case resume

  public init(_ action: CollectorConsentAction) {
    switch action {
    case .enable: self = .enable
    case .disable: self = .disable
    case .pause: self = .pause
    case .resume: self = .resume
    }
  }
}

public struct PersistedCollectorConsent: Equatable, Sendable {
  public let consent: CollectorConsent
  public let lastAction: CollectorConsentActionKind?
  public let revision: UInt64
  public let renewalRequired: Bool

  public init(
    consent: CollectorConsent, lastAction: CollectorConsentAction?, revision: UInt64,
    renewalRequired: Bool = false
  ) {
    self.consent = consent
    self.lastAction = lastAction.map(CollectorConsentActionKind.init)
    self.revision = revision
    self.renewalRequired = renewalRequired
  }

  public var permitsCollection: Bool { consent.permitsCollection && !renewalRequired }
}

public struct GlobalCollectionControl: Equatable, Sendable {
  public let isPaused: Bool
  public let revision: UInt64

  public init(isPaused: Bool, revision: UInt64) {
    self.isPaused = isPaused
    self.revision = revision
  }
}

public enum CollectionConsentRepositoryError: Error, Equatable, Sendable {
  case revisionConflict
  case invalidTransition
  case corruptedValue
  case revisionOutOfRange
}

/// Durable product-consent and global-pause boundary. Implementations must use
/// ``CollectorConsentStateMachine`` for legal collector transitions.
public protocol CollectionConsentRepository: Sendable {
  func consent(for collector: CollectorKind) async throws -> PersistedCollectorConsent
  func transition(
    _ action: CollectorConsentAction,
    expectedRevision: UInt64
  ) async throws -> PersistedCollectorConsent
  func globalControl() async throws -> GlobalCollectionControl
  func setGlobalPaused(_ isPaused: Bool, expectedRevision: UInt64) async throws
    -> GlobalCollectionControl
}

public enum CollectionStopScope: Codable, Equatable, Hashable, Sendable {
  case global
  case collector(CollectorKind)
}

public enum CollectionStopTarget: Codable, Equatable, Hashable, Sendable {
  case globalPaused
  case collectorPaused
  case collectorDisabled
}

public struct CollectionStopIntent: Codable, Equatable, Sendable {
  public let scope: CollectionStopScope
  public let target: CollectionStopTarget
  public let confirmation: UserConsentConfirmation?
  public let expectedRevision: UInt64
  public let targetRevision: UInt64

  public init(
    scope: CollectionStopScope, target: CollectionStopTarget,
    confirmation: UserConsentConfirmation?, expectedRevision: UInt64, targetRevision: UInt64
  ) throws {
    guard expectedRevision < UInt64(Int64.max), targetRevision <= UInt64(Int64.max) else {
      throw CollectionConsentRepositoryError.revisionOutOfRange
    }
    guard targetRevision == expectedRevision + 1 else {
      throw CollectionConsentRepositoryError.corruptedValue
    }
    switch (scope, target, confirmation) {
    case (.global, .globalPaused, nil): break
    case (.collector(let collector), .collectorPaused, .some(let confirmation)),
      (.collector(let collector), .collectorDisabled, .some(let confirmation)):
      guard confirmation.collector == collector else {
        throw CollectionConsentRepositoryError.corruptedValue
      }
    default: throw CollectionConsentRepositoryError.corruptedValue
    }
    self.scope = scope
    self.target = target
    self.confirmation = confirmation
    self.expectedRevision = expectedRevision
    self.targetRevision = targetRevision
  }
}

public protocol CollectionStopIntentStoring: Sendable {
  func create(_ intent: CollectionStopIntent) async throws
  func unresolved() async throws -> [CollectionStopIntent]
  func replay(using repository: any CollectionConsentRepository) async throws
}
