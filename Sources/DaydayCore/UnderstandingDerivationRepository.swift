import Foundation

/// A complete immutable deterministic derivation for one logical workday revision.
///
/// This Core type intentionally contains only Session and provisional Activity values; it has no
/// dependency on the Understanding module, model providers, Journal, Mood, OCR, or media.
public struct PersistedUnderstandingDerivation: Equatable, Sendable {
  public enum ValidationError: Error, Equatable, Sendable {
    case mismatchedDay
    case mismatchedRevision
    case activityReferencesSessionOutsideBatch(ActivityID, SessionID)
  }

  public let day: DayDescriptor
  public let revision: UInt64
  public let sessions: [Session]
  public let activities: [Activity]

  public init(
    sessionBatch: SessionDerivationBatch,
    activityBatch: ActivityDerivationBatch
  ) throws {
    guard sessionBatch.day == activityBatch.day else { throw ValidationError.mismatchedDay }
    guard sessionBatch.derivationRevision == activityBatch.derivationRevision else {
      throw ValidationError.mismatchedRevision
    }
    let sessionIDs = Set(sessionBatch.sessions.map(\.id))
    for activity in activityBatch.activities {
      for sessionID in activity.sessionIDs where !sessionIDs.contains(sessionID) {
        throw ValidationError.activityReferencesSessionOutsideBatch(activity.id, sessionID)
      }
    }
    day = sessionBatch.day
    revision = sessionBatch.derivationRevision
    sessions = sessionBatch.sessions
    activities = activityBatch.activities
  }

  public var sessionBatch: SessionDerivationBatch {
    get throws {
      try SessionDerivationBatch(day: day, derivationRevision: revision, sessions: sessions)
    }
  }

  public var activityBatch: ActivityDerivationBatch {
    get throws {
      try ActivityDerivationBatch(day: day, derivationRevision: revision, activities: activities)
    }
  }
}

public enum UnderstandingDerivationSaveResult: Equatable, Sendable {
  case inserted
  case alreadyPresent
  case conflict
}

/// Atomic persistence and complete-revision reads for deterministic understanding output.
public protocol UnderstandingDerivationRepository: Sendable {
  func saveAtomically(_ derivation: PersistedUnderstandingDerivation) async throws
    -> UnderstandingDerivationSaveResult
  func latest(for day: DayDescriptor) async throws -> PersistedUnderstandingDerivation?
}
