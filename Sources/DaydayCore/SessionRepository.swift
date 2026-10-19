import Foundation

/// One immutable deterministic Session rebuild for a logical day and revision.
public struct SessionDerivationBatch: Equatable, Sendable {
  public enum ValidationError: Error, Equatable, Sendable { case empty; case invalidRevision; case mixedRevision; case duplicateID(SessionID); case outsideDay(SessionID) }
  public let day: DayDescriptor
  public let derivationRevision: UInt64
  public let sessions: [Session]
  public init(day: DayDescriptor, derivationRevision: UInt64, sessions: [Session]) throws {
    guard derivationRevision > 0 else { throw ValidationError.invalidRevision }
    guard !sessions.isEmpty else { throw ValidationError.empty }
    guard sessions.allSatisfy({ $0.lineage.derivationRevision == derivationRevision }) else { throw ValidationError.mixedRevision }
    var ids = Set<SessionID>()
    for session in sessions {
      guard day.boundary.startsAt <= session.startedAt, session.startedAt < day.boundary.endsAt,
        session.endedAt <= day.boundary.endsAt
      else { throw ValidationError.outsideDay(session.id) }
      guard ids.insert(session.id).inserted else { throw ValidationError.duplicateID(session.id) }
    }
    self.day = day; self.derivationRevision = derivationRevision; self.sessions = sessions
  }
}

public enum SessionBatchSaveResult: Equatable, Sendable { case inserted, alreadyPresent, conflict }

/// Closed append-only persistence port for deterministic display or workspace Sessions.
public protocol SessionRepository: Sendable {
  func save(_ batch: SessionDerivationBatch) async throws -> SessionBatchSaveResult
  func sessions(startedIn range: Range<Date>) async throws -> [Session]
}
