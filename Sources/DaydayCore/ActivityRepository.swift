import Foundation

/// One immutable deterministic-rule Activity rebuild for a logical day and revision.
public struct ActivityDerivationBatch: Equatable, Sendable {
  public enum ValidationError: Error, Equatable, Sendable {
    case empty
    case invalidRevision
    case mixedRevision
    case duplicateID(ActivityID)
    case outsideDay(ActivityID)
    case notDeterministicProvisional(ActivityID)
  }

  public let day: DayDescriptor
  public let derivationRevision: UInt64
  public let activities: [Activity]

  public init(day: DayDescriptor, derivationRevision: UInt64, activities: [Activity]) throws {
    guard derivationRevision > 0 else { throw ValidationError.invalidRevision }
    guard !activities.isEmpty else { throw ValidationError.empty }
    var identifiers = Set<ActivityID>()
    for activity in activities {
      guard activity.lineage.revision == derivationRevision else {
        throw ValidationError.mixedRevision
      }
      guard day.boundary.startsAt <= activity.startedAt, activity.startedAt < day.boundary.endsAt,
        activity.endedAt <= day.boundary.endsAt
      else { throw ValidationError.outsideDay(activity.id) }
      guard identifiers.insert(activity.id).inserted else {
        throw ValidationError.duplicateID(activity.id)
      }
      guard activity.interpretation.origin == .deterministicRule, activity.confidence == .low,
        activity.reviewState == .needsReview, activity.evidenceReferences.isEmpty
      else { throw ValidationError.notDeterministicProvisional(activity.id) }
    }
    self.day = day
    self.derivationRevision = derivationRevision
    self.activities = activities
  }
}

public enum ActivityBatchSaveResult: Equatable, Sendable { case inserted, alreadyPresent, conflict }

/// Closed append-only port for deterministic provisional Activity derivations.
public protocol ActivityRepository: Sendable {
  func save(_ batch: ActivityDerivationBatch) async throws -> ActivityBatchSaveResult
  func activities(startedIn range: Range<Date>) async throws -> [Activity]
}
