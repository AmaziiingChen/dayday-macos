import Foundation

/// A crash-recovery snapshot of one still-open input aggregate period.
///
/// The embedded aggregate is the same privacy-closed value used for a
/// finalized hour: it cannot contain typed text, input order, timestamps,
/// coordinates, paths, or a key/application join. Revisions make replacing an
/// older snapshot deterministic without introducing an event log.
public struct InputAggregateCheckpoint: Codable, Equatable, Sendable {
    public enum ValidationError: Error, Equatable, Sendable {
        case aggregateMustBeHourly
        case zeroRevision
        case invalidCheckpointTime
    }

    public let aggregate: InputAggregate
    public let revision: UInt64
    public let checkpointedAt: Date

    public init(
        aggregate: InputAggregate,
        revision: UInt64,
        checkpointedAt: Date
    ) throws {
        guard aggregate.period.granularity == .hour else {
            throw ValidationError.aggregateMustBeHourly
        }
        guard revision > 0 else { throw ValidationError.zeroRevision }
        guard checkpointedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw ValidationError.invalidCheckpointTime
        }
        self.aggregate = aggregate
        self.revision = revision
        self.checkpointedAt = checkpointedAt
    }
}

/// The narrow port used by Capture to recover and replace open-hour snapshots.
/// No raw input or event-shaped type can cross this boundary.
public protocol InputAggregateCheckpointRepository: Sendable {
    func openCheckpoints() async throws -> [InputAggregateCheckpoint]
    func upsert(_ checkpoint: InputAggregateCheckpoint) async throws
    func finalize(_ aggregate: InputAggregate) async throws
}
