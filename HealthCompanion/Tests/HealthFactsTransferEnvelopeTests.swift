import Foundation
import Testing
@testable import DaydayHealthCompanion

@Suite("Health facts transfer envelope")
struct HealthFactsTransferEnvelopeTests {
    @Test("A factual batch round-trips through the stable JSON encoding")
    func roundTrips() throws {
        let record = HealthFactRecord(
            id: UUID(uuidString: "0B32BCDF-7B11-4C40-B2EC-0B532A1D1BF6")!,
            kind: .sleepAnalysis,
            startDate: Date(timeIntervalSince1970: 1_000),
            endDate: Date(timeIntervalSince1970: 2_000),
            sourceName: "iPhone",
            sourceBundleIdentifier: "com.apple.health",
            payload: .category(rawValue: 1)
        )
        let envelope = try HealthFactsTransferEnvelope(
            batchID: UUID(uuidString: "D0C1B2A3-4E5F-6789-ABCD-0123456789AB")!,
            sourceInstallationID: UUID(uuidString: "8A9B0C1D-2E3F-4567-89AB-CDEF01234567")!,
            createdAt: Date(timeIntervalSince1970: 3_000),
            observations: [.init(record: record)],
            tombstones: []
        )

        let decoded = try HealthFactsTransferEnvelope.decode(
            HealthFactsTransferEnvelope.encode(envelope)
        )

        #expect(decoded == envelope)
    }

    @Test("A batch rejects a fact and tombstone with the same UUID")
    func rejectsConflict() throws {
        let id = UUID()
        let observation = HealthFactsTransferEnvelope.Observation(
            record: HealthFactRecord(
                id: id,
                kind: .stepCount,
                startDate: .now,
                endDate: .now,
                sourceName: "iPhone",
                sourceBundleIdentifier: "com.apple.health",
                payload: .quantity(value: 12, unit: "count")
            )
        )
        let tombstone = HealthFactsTransferEnvelope.Tombstone(
            tombstone: HealthFactTombstone(id: id, kind: .stepCount, deletedAt: .now)
        )

        #expect(throws: HealthFactsTransferEnvelopeError.conflictingObservationAndTombstone) {
            try HealthFactsTransferEnvelope(
                sourceInstallationID: UUID(),
                observations: [observation],
                tombstones: [tombstone]
            )
        }
    }
}
