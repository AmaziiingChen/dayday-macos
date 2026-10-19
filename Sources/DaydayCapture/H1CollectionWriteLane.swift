import DaydayCore
import Foundation

struct H1AdmittedCandidate: Sendable {
  let candidate: FilteredApplicationWindowCandidate
  let timeZoneIdentifier: String
}

enum H1CollectionWriteFailure: Error, Equatable, Sendable {
  case storageUnavailable(committedCount: UInt64)
  case serviceUnavailable
  case invariantViolated
}

struct H1CollectionWriteOutcome: Sendable {
  let insertedCount: UInt64
}

/// The only executor that resolves ephemeral platform identity and performs
/// objective writes. The main actor owns admission and presentation state but
/// never waits on repository or resolver I/O while processing callbacks.
actor H1CollectionWriteLane {
  typealias IdentityResolver = @Sendable (String, String) async throws -> ApplicationIdentifier?

  private enum DurableCandidateKey: Equatable, Sendable {
    case application(
      ApplicationIdentifier,
      String,
      String?,
      String?
    )
    case suppression(CollectionSuppressionReason)
  }

  private let repository: any ObjectiveLinkedRecordRepository
  private let identityResolver: IdentityResolver
  private var lastDurableCandidateKey: DurableCandidateKey?

  init(
    repository: any ObjectiveLinkedRecordRepository,
    identityResolver: @escaping IdentityResolver
  ) {
    self.repository = repository
    self.identityResolver = identityResolver
  }

  func persistCandidate(_ admitted: H1AdmittedCandidate) async throws
    -> H1CollectionWriteOutcome
  {
    let candidate = admitted.candidate
    switch candidate.disposition {
    case .available, .focusedWindowMissing:
      guard let bundleIdentifier = candidate.bundleIdentifier,
        let displayLabel = candidate.applicationDisplayLabel?.value
      else {
        return try await persistSuppression(
          observedAt: candidate.observedAt,
          timeZoneIdentifier: admitted.timeZoneIdentifier,
          reason: .uncertainSafetyState
        )
      }

      let applicationIdentifier: ApplicationIdentifier?
      do {
        applicationIdentifier = try await identityResolver(bundleIdentifier, displayLabel)
      } catch {
        throw H1CollectionWriteFailure.serviceUnavailable
      }
      guard let applicationIdentifier else {
        return try await persistSuppression(
          observedAt: candidate.observedAt,
          timeZoneIdentifier: admitted.timeZoneIdentifier,
          reason: .uncertainSafetyState
        )
      }

      let key = DurableCandidateKey.application(
        applicationIdentifier,
        displayLabel,
        candidate.redactedWindowTitle?.value,
        candidate.redactedDocumentHint?.value
      )
      guard key != lastDurableCandidateKey else {
        return H1CollectionWriteOutcome(insertedCount: 0)
      }

      let write: ApplicationContextWrite
      do {
        let eventID = EventID()
        let event = try Self.makeEvent(
          id: eventID,
          kind: .applicationContextChanged,
          occurredAt: candidate.observedAt,
          timeZoneIdentifier: admitted.timeZoneIdentifier,
          securityDisposition: .allowed
        )
        let record = try ApplicationContextRecord(
          eventID: eventID,
          applicationIdentifier: applicationIdentifier,
          displayLabelSnapshot: displayLabel,
          windowTitleSnapshot: candidate.redactedWindowTitle?.value,
          documentFilenameHint: candidate.redactedDocumentHint?.value
        )
        write = try ApplicationContextWrite(event: event, record: record)
      } catch {
        throw H1CollectionWriteFailure.invariantViolated
      }

      let result: ObjectiveEventInsertResult
      do {
        result = try await repository.insertApplicationContext(write)
      } catch {
        throw H1CollectionWriteFailure.storageUnavailable(committedCount: 0)
      }
      lastDurableCandidateKey = key
      return H1CollectionWriteOutcome(insertedCount: result == .inserted ? 1 : 0)

    case .accessibilityDenied:
      return try await persistSuppression(
        observedAt: candidate.observedAt,
        timeZoneIdentifier: admitted.timeZoneIdentifier,
        reason: .authorizationUnavailable
      )
    case .excluded(let reason):
      return try await persistSuppression(
        observedAt: candidate.observedAt,
        timeZoneIdentifier: admitted.timeZoneIdentifier,
        reason: Self.suppressionReason(for: reason)
      )
    case .foregroundApplicationMissing, .applicationIdentityMissing, .unknownSafetyState:
      return try await persistSuppression(
        observedAt: candidate.observedAt,
        timeZoneIdentifier: admitted.timeZoneIdentifier,
        reason: .uncertainSafetyState
      )
    }
  }

  func persistState(
    _ state: CollectorState,
    occurredAt: Date,
    timeZoneIdentifier: String
  ) async throws -> H1CollectionWriteOutcome {
    let write: CollectorStateWrite
    do {
      let eventID = EventID()
      let event = try Self.makeEvent(
        id: eventID,
        kind: .collectorStateTransition,
        occurredAt: occurredAt,
        timeZoneIdentifier: timeZoneIdentifier,
        securityDisposition: .allowed
      )
      let record = try CollectorStateRecord(eventID: eventID, state: state)
      write = try CollectorStateWrite(event: event, record: record)
    } catch {
      throw H1CollectionWriteFailure.invariantViolated
    }

    do {
      let result = try await repository.insertCollectorState(write)
      lastDurableCandidateKey = nil
      return H1CollectionWriteOutcome(insertedCount: result == .inserted ? 1 : 0)
    } catch {
      throw H1CollectionWriteFailure.storageUnavailable(committedCount: 0)
    }
  }

  func persistAuthorizationLoss(
    observedAt: Date,
    timeZoneIdentifier: String,
    state: CollectorState
  ) async throws -> H1CollectionWriteOutcome {
    let boundary = try await persistState(
      state,
      occurredAt: observedAt,
      timeZoneIdentifier: timeZoneIdentifier
    )
    let suppression: H1CollectionWriteOutcome
    do {
      suppression = try await persistSuppression(
        observedAt: observedAt,
        timeZoneIdentifier: timeZoneIdentifier,
        reason: .authorizationUnavailable
      )
    } catch H1CollectionWriteFailure.storageUnavailable {
      throw H1CollectionWriteFailure.storageUnavailable(
        committedCount: boundary.insertedCount
      )
    }
    let addition = suppression.insertedCount.addingReportingOverflow(boundary.insertedCount)
    guard !addition.overflow else {
      throw H1CollectionWriteFailure.invariantViolated
    }
    return H1CollectionWriteOutcome(insertedCount: addition.partialValue)
  }

  private func persistSuppression(
    observedAt: Date,
    timeZoneIdentifier: String,
    reason: CollectionSuppressionReason
  ) async throws -> H1CollectionWriteOutcome {
    let key = DurableCandidateKey.suppression(reason)
    guard key != lastDurableCandidateKey else {
      return H1CollectionWriteOutcome(insertedCount: 0)
    }

    let write: CollectionSuppressionWrite
    do {
      let eventID = EventID()
      let event = try Self.makeEvent(
        id: eventID,
        kind: .applicationContextChanged,
        occurredAt: observedAt,
        timeZoneIdentifier: timeZoneIdentifier,
        securityDisposition: .excluded(reason)
      )
      let record = try CollectionSuppressionRecord(eventID: eventID, reason: reason)
      write = try CollectionSuppressionWrite(event: event, record: record)
    } catch {
      throw H1CollectionWriteFailure.invariantViolated
    }

    do {
      let result = try await repository.insertCollectionSuppression(write)
      lastDurableCandidateKey = key
      return H1CollectionWriteOutcome(insertedCount: result == .inserted ? 1 : 0)
    } catch {
      throw H1CollectionWriteFailure.storageUnavailable(committedCount: 0)
    }
  }

  private static func makeEvent(
    id: EventID,
    kind: ObjectiveEventKind,
    occurredAt: Date,
    timeZoneIdentifier: String,
    securityDisposition: EventSecurityDisposition
  ) throws -> ObjectiveEvent {
    try ObjectiveEvent(
      id: id,
      kind: kind,
      occurredAt: occurredAt,
      timeZoneIdentifier: timeZoneIdentifier,
      source: CollectorSource(
        collector: .applicationWindowContext,
        collectorVersion: ApplicationContextObservationVersion.windowContext,
        payloadSchemaVersion: 1
      ),
      securityDisposition: securityDisposition
    )
  }

  private static func suppressionReason(
    for reason: ApplicationWindowContextExclusionReason
  ) -> CollectionSuppressionReason {
    switch reason {
    case .userExclusion: return .userExclusion
    case .passwordManager: return .passwordManager
    case .authenticationContext: return .authenticationContext
    case .securitySensitiveRole: return .mandatoryExclusion
    }
  }
}
