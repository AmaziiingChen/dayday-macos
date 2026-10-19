import DaydayCore
import Foundation
import Testing

@Suite("Health archive core contract")
struct HealthObservationTests {
  @Test("A batch is source-scoped and rejects conflicting changes")
  func batchRejectsConflicts() throws {
    let sourceID = UUID()
    let observation = try makeObservation(sourceID: sourceID, recordID: UUID())
    let tombstone = try HealthObservationTombstone(
      key: observation.key, kind: .stepCount, deletedAt: date(20)
    )

    #expect(throws: HealthArchiveBatch.ValidationError.observationAndTombstoneConflict) {
      try HealthArchiveBatch(
        sourceInstallationID: sourceID,
        createdAt: date(21),
        observations: [observation],
        tombstones: [tombstone]
      )
    }
  }

  @Test("Payload and observation validation reject invalid factual values")
  func rejectsInvalidValues() throws {
    #expect(throws: HealthObservationPayload.ValidationError.missingUnit) {
      try HealthObservationPayload(quantityValue: 72.4, unit: " ")
    }
    #expect(throws: HealthObservation.ValidationError.invalidTimeRange) {
      try HealthObservation(
        key: HealthObservationKey(sourceInstallationID: UUID(), healthKitUUID: UUID()),
        kind: .heartRate,
        startedAt: date(10),
        endedAt: date(9),
        source: try HealthObservationSource(name: "Apple Watch", bundleIdentifier: "com.apple.health"),
        payload: try HealthObservationPayload(quantityValue: 70, unit: "count/min"),
        receivedAt: date(11)
      )
    }
  }

  @Test("Dashboard statistics requests remain date- and receipt-bounded")
  func statisticsQueryValidation() throws {
    #expect(throws: HealthArchiveStatisticsQuery.ValidationError.invalidDateRange) {
      try HealthArchiveStatisticsQuery(startsAt: date(20), endsAt: date(10))
    }
    #expect(throws: HealthArchiveStatisticsQuery.ValidationError.invalidRecentSyncLimit) {
      try HealthArchiveStatisticsQuery(startsAt: date(10), endsAt: date(20), recentSyncLimit: 21)
    }
    #expect(throws: HealthArchiveStatisticsQuery.ValidationError.dateRangeTooLarge) {
      try HealthArchiveStatisticsQuery(
        startsAt: date(0),
        endsAt: date(368 * 24 * 60 * 60)
      )
    }
    let query = try HealthArchiveStatisticsQuery(
      kinds: [.heartRate], startsAt: date(10), endsAt: date(20), recentSyncLimit: 10
    )
    #expect(query.kinds == [.heartRate])
    #expect(query.recentSyncLimit == 10)
  }

  private func makeObservation(sourceID: UUID, recordID: UUID) throws -> HealthObservation {
    try HealthObservation(
      key: HealthObservationKey(sourceInstallationID: sourceID, healthKitUUID: recordID),
      kind: .stepCount,
      startedAt: date(10),
      endedAt: date(11),
      source: try HealthObservationSource(name: "Apple Watch", bundleIdentifier: "com.apple.health"),
      payload: try HealthObservationPayload(quantityValue: 420, unit: "count"),
      receivedAt: date(12)
    )
  }

  private func date(_ seconds: TimeInterval) -> Date { Date(timeIntervalSinceReferenceDate: seconds) }
}
