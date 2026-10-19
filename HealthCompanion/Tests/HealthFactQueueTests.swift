import Foundation
import Testing
@testable import DaydayHealthCompanion

@Suite("Companion-local health fact queue")
struct HealthFactQueueTests {
    @Test("Replacement and deletion leave one durable tombstone")
    func replacementAndDeletion() throws {
        let store = HealthFactQueueStore(databaseURL: temporaryDatabaseURL())
        let id = UUID(uuidString: "0B32BCDF-7B11-4C40-B2EC-0B532A1D1BF6")!
        let record = HealthFactRecord(
            id: id,
            kind: .stepCount,
            startDate: Date(timeIntervalSince1970: 1_000),
            endDate: Date(timeIntervalSince1970: 1_100),
            sourceName: "Apple Watch",
            sourceBundleIdentifier: "com.apple.health",
            payload: .quantity(value: 42, unit: "count")
        )
        try store.apply(records: [record], deletedIDs: [], kind: .stepCount, at: .now)
        try store.apply(records: [], deletedIDs: [id], kind: .stepCount, at: .now)

        let status = try store.status()
        #expect(status.factCount == 0)
        #expect(status.tombstoneCount == 1)
    }

    @Test("A later record restores a previously tombstoned UUID")
    func laterRecordWinsOverTombstone() {
        let id = UUID()
        let record = HealthFactRecord(
            id: id,
            kind: .bodyMass,
            startDate: .now,
            endDate: .now,
            sourceName: "Scale",
            sourceBundleIdentifier: "example.scale",
            payload: .quantity(value: 72.4, unit: "kg")
        )
        var snapshot = HealthFactQueueSnapshot.empty

        snapshot.apply(records: [], deletedIDs: [id], kind: .bodyMass, at: .now)
        snapshot.apply(records: [record], deletedIDs: [], kind: .bodyMass, at: .now)

        #expect(snapshot.observations[id] == record)
        #expect(snapshot.tombstones[id] == nil)
    }

    @Test("A legacy JSON queue migrates into SQLite before anchors resume")
    func migratesLegacyQueue() throws {
        let id = UUID()
        let record = HealthFactRecord(
            id: id,
            kind: .heartRate,
            startDate: .now,
            endDate: .now,
            sourceName: "Apple Watch",
            sourceBundleIdentifier: "com.apple.health",
            payload: .quantity(value: 68, unit: "count/min")
        )
        var snapshot = HealthFactQueueSnapshot.empty
        snapshot.apply(records: [record], deletedIDs: [], kind: .heartRate, at: .now)
        let legacyURL = temporaryDirectoryURL().appendingPathComponent("legacy.json")
        try FileManager.default.createDirectory(at: legacyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: legacyURL)

        let store = HealthFactQueueStore(
            databaseURL: temporaryDirectoryURL().appendingPathComponent("queue.sqlite"),
            legacyFileURL: legacyURL
        )
        let status = try store.status()

        #expect(status.factCount == 1)
        #expect(status.recentFacts.first?.id == id)
    }

    @Test("Queue reports per-kind factual coverage")
    func reportsCoverageByKind() throws {
        let store = HealthFactQueueStore(databaseURL: temporaryDatabaseURL())
        let older = HealthFactRecord(
            id: UUID(),
            kind: .heartRate,
            startDate: Date(timeIntervalSince1970: 1_000),
            endDate: Date(timeIntervalSince1970: 1_100),
            sourceName: "Apple Watch",
            sourceBundleIdentifier: "com.apple.health",
            payload: .quantity(value: 65, unit: "count/min")
        )
        let newer = HealthFactRecord(
            id: UUID(),
            kind: .heartRate,
            startDate: Date(timeIntervalSince1970: 2_000),
            endDate: Date(timeIntervalSince1970: 2_100),
            sourceName: "Apple Watch",
            sourceBundleIdentifier: "com.apple.health",
            payload: .quantity(value: 70, unit: "count/min")
        )
        try store.apply(records: [older, newer], deletedIDs: [], kind: .heartRate, at: .now)

        let coverage = try #require(store.status().coverage.first { $0.kind == .heartRate })
        #expect(coverage.factCount == 2)
        #expect(coverage.latestFactEndDate == newer.endDate)
    }

    @Test("A transfer is stable across retries and only its acknowledged mutations leave the outbox")
    func persistedOutboxRetriesThenAcknowledges() throws {
        let store = HealthFactQueueStore(databaseURL: temporaryDatabaseURL())
        let sourceID = UUID()
        let first = HealthFactRecord(
            id: UUID(), kind: .stepCount,
            startDate: Date(timeIntervalSince1970: 1_000), endDate: Date(timeIntervalSince1970: 1_100),
            sourceName: "iPhone", sourceBundleIdentifier: "com.apple.health",
            payload: .quantity(value: 123, unit: "count")
        )
        let second = HealthFactRecord(
            id: UUID(), kind: .bodyMass,
            startDate: Date(timeIntervalSince1970: 1_200), endDate: Date(timeIntervalSince1970: 1_300),
            sourceName: "Scale", sourceBundleIdentifier: "example.scale",
            payload: .quantity(value: 72.4, unit: "kg")
        )
        try store.apply(records: [first, second], deletedIDs: [], kind: .stepCount, at: .now)

        let firstAttempt = try #require(try store.pendingTransfer(
            sourceInstallationID: sourceID, maximumMutations: 10, at: Date(timeIntervalSince1970: 2_000)
        ))
        let retry = try #require(try store.pendingTransfer(
            sourceInstallationID: sourceID, maximumMutations: 10, at: Date(timeIntervalSince1970: 3_000)
        ))
        #expect(retry == firstAttempt)
        #expect(firstAttempt.batch.observations.map(\.key.healthKitUUID) == [first.id, second.id])
        #expect(try store.status().pendingMutationCount == 2)

        try store.acknowledgeTransfer(HealthSyncAcknowledgement(
            sourceInstallationID: sourceID, batchID: firstAttempt.batch.batchID, receivedAt: .now
        ))
        #expect(try store.pendingTransfer(sourceInstallationID: sourceID, maximumMutations: 10, at: .now) == nil)
        #expect(try store.status().pendingMutationCount == 0)
    }

    @Test("Default local sync batches carry two thousand mutations before continuing")
    func defaultTransferBatchIsLargeEnoughForHistoricalImports() throws {
        let store = HealthFactQueueStore(databaseURL: temporaryDatabaseURL())
        let sourceID = UUID()
        let records = (0...2_000).map { offset in
            HealthFactRecord(
                id: UUID(), kind: .heartRate,
                startDate: Date(timeIntervalSince1970: TimeInterval(offset)),
                endDate: Date(timeIntervalSince1970: TimeInterval(offset)),
                sourceName: "Apple Watch", sourceBundleIdentifier: "com.apple.health",
                payload: .quantity(value: Double(offset), unit: "count/min")
            )
        }
        try store.apply(records: records, deletedIDs: [], kind: .heartRate, at: .now)

        let first = try #require(try store.pendingTransfer(sourceInstallationID: sourceID))
        #expect(first.mutationCount == 2_000)
        try store.acknowledgeTransfer(HealthSyncAcknowledgement(
            sourceInstallationID: sourceID, batchID: first.batch.batchID, receivedAt: .now
        ))
        let second = try #require(try store.pendingTransfer(sourceInstallationID: sourceID))
        #expect(second.mutationCount == 1)
    }

    @Test("A later deletion supersedes an unsent fact without letting it reappear")
    func outboxCoalescesFactAndLaterDeletion() throws {
        let store = HealthFactQueueStore(databaseURL: temporaryDatabaseURL())
        let sourceID = UUID()
        let id = UUID()
        let record = HealthFactRecord(
            id: id, kind: .bodyMass, startDate: .now, endDate: .now,
            sourceName: "Scale", sourceBundleIdentifier: "example.scale", payload: .quantity(value: 72, unit: "kg")
        )
        try store.apply(records: [record], deletedIDs: [], kind: .bodyMass, at: .now)
        try store.apply(records: [], deletedIDs: [id], kind: .bodyMass, at: Date(timeIntervalSince1970: 8_000))

        let pending = try #require(try store.pendingTransfer(
            sourceInstallationID: sourceID, maximumMutations: 10, at: .now
        ))
        #expect(pending.batch.observations.isEmpty)
        #expect(pending.batch.tombstones.map(\.key.healthKitUUID) == [id])
    }

    private func temporaryDatabaseURL() -> URL {
        temporaryDirectoryURL().appendingPathComponent("health-fact-queue.sqlite", isDirectory: false)
    }

    private func temporaryDirectoryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
