import Foundation
import Testing
@testable import DaydayHealthCompanion

@Suite("Health import plan")
struct HealthImportPlanTests {
    @Test("Initial import records each requested kind only once")
    func initialImportIsIdempotent() {
        let defaults = makeDefaults()
        let store = UserDefaultsHealthImportPlanStore(defaults: defaults)
        let firstDate = Date(timeIntervalSince1970: 1_000)
        let secondDate = Date(timeIntervalSince1970: 2_000)

        _ = store.enqueueInitialImport(types: [.sleepAnalysis, .stepCount], at: firstDate)
        let plan = store.enqueueInitialImport(types: [.stepCount, .bodyMass], at: secondDate)

        #expect(plan.requestedTypes == [.sleepAnalysis, .stepCount, .bodyMass])
        #expect(plan.initialImportQueuedAt == firstDate)
    }

    @Test("Manual sync request preserves the pending import plan")
    func manualRequestPreservesPlan() {
        let defaults = makeDefaults()
        let store = UserDefaultsHealthImportPlanStore(defaults: defaults)
        let importDate = Date(timeIntervalSince1970: 1_000)
        let manualDate = Date(timeIntervalSince1970: 2_000)

        _ = store.enqueueInitialImport(types: [.workout], at: importDate)
        let plan = store.requestManualAttempt(at: manualDate)

        #expect(plan.requestedTypes == [.workout])
        #expect(plan.initialImportQueuedAt == importDate)
        #expect(plan.lastManualSyncRequestAt == manualDate)
    }

    @Test("Completed empty reads remain distinct from facts in the queue")
    func recordsCompletedReadByKind() {
        let defaults = makeDefaults()
        let store = UserDefaultsHealthImportPlanStore(defaults: defaults)
        let completedAt = Date(timeIntervalSince1970: 3_000)

        let plan = store.recordCompletedRead(for: .dietaryWater, at: completedAt)

        #expect(plan.lastCompletedRead(at: .dietaryWater) == completedAt)
        #expect(plan.lastCompletedRead(at: .heartRate) == nil)
    }

    @Test("An interrupted initial import remains resumable until every requested type is checked")
    func initialImportResumesOnlyForUncompletedRequestedTypes() {
        let defaults = makeDefaults()
        let store = UserDefaultsHealthImportPlanStore(defaults: defaults)

        _ = store.enqueueInitialImport(types: [.heartRate, .stepCount], at: Date(timeIntervalSince1970: 1_000))
        #expect(store.load().hasUncompletedRequestedReads)

        _ = store.recordCompletedRead(for: .heartRate, at: Date(timeIntervalSince1970: 2_000))
        #expect(store.load().hasUncompletedRequestedReads)

        _ = store.recordCompletedRead(for: .stepCount, at: Date(timeIntervalSince1970: 3_000))
        #expect(!store.load().hasUncompletedRequestedReads)
    }

    @Test("A manual sync reports deferred, batch, and safe failure states")
    func localSyncPresentationExplainsWhatIsHappening() {
        let completed = 4_000.formatted(.number)
        let pending = 2_000.formatted(.number)
        let transferred = 6_000.formatted(.number)
        #expect(HealthCompanionModel.LocalSyncPresentation.waitingForRead.title.contains("完成本机读取"))
        #expect(HealthCompanionModel.LocalSyncPresentation.syncing(
            completedChanges: 4_000,
            pendingChanges: 2_000
        ).title.contains("已同步 \(completed) 条，剩余 \(pending) 条"))
        #expect(HealthCompanionModel.LocalSyncPresentation.synchronized(
            Date(timeIntervalSince1970: 1_000),
            transferredChanges: 6_000
        ).title.contains("已同步 \(transferred)"))
        #expect(HealthCompanionModel.LocalSyncPresentation.failed("未找到 Mac").title.contains("未找到 Mac"))
    }

    @Test("A deferred manual sync drains exactly once at a terminal edge")
    func deferredManualSyncDrainsOnce() {
        var request = HealthDeferredManualSyncRequest()
        request.request()
        request.request()

        let firstDrain = request.drain()
        let secondDrain = request.drain()
        #expect(firstDrain)
        #expect(!secondDrain)
        #expect(!request.isPending)
    }

    @Test("A failed manual read never opens the transfer gate")
    func failedManualReadNeverTransfers() {
        var gate = HealthManualSyncReadGate()
        gate.request()

        let action = gate.finishRead(succeeded: false)
        #expect(action == .none)
        #expect(!gate.isPending)
    }

    @Test("Only a fully successful manual read opens the transfer gate once")
    func successfulManualReadTransfersOnce() {
        var gate = HealthManualSyncReadGate()
        gate.request()

        let firstAction = gate.finishRead(succeeded: true)
        let secondAction = gate.finishRead(succeeded: true)
        #expect(firstAction == .transfer)
        #expect(secondAction == .none)
    }

    @Test("Older stored plans decode without losing their import request")
    func decodesVersionOnePlanWithoutCoverageState() throws {
        let data = """
        {
          "requestedTypes": ["stepCount"],
          "initialImportQueuedAt": 1000,
          "lastManualSyncRequestAt": null
        }
        """.data(using: .utf8)!

        let plan = try JSONDecoder().decode(HealthImportPlan.self, from: data)

        #expect(plan.requestedTypes == [.stepCount])
        // JSONEncoder/Decoder's default Date contract uses Apple's 2001 reference date, not Unix.
        #expect(plan.initialImportQueuedAt == Date(timeIntervalSinceReferenceDate: 1_000))
        #expect(plan.initialImportQueuedAt != Date(timeIntervalSince1970: 1_000))
        #expect(plan.lastCompletedReadAtByKind.isEmpty)
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "HealthImportPlanTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

@Suite("Health companion manual sync sequencing")
struct HealthCompanionManualSyncSequencingTests {
    @Test("A mid-read failure retains an old outbox without invoking transfer")
    @MainActor
    func midReadFailureNeverTransfers() async {
        let queue = SequencingFactQueueStore()
        let client = SequencingSyncClient()
        let pairing = SequencingPairingStore(credential: testCredential())
        let model = HealthCompanionModel(
            planStore: SequencingPlanStore(),
            factQueue: queue,
            pairingStore: pairing,
            localSyncClient: client,
            incrementalReader: FailingIncrementalReader()
        )
        try? await Task.sleep(for: .milliseconds(100))
        queue.setPendingMutationCount(1)

        model.markManualSyncRequested()
        try? await Task.sleep(for: .milliseconds(100))

        guard case .failed = model.importPresentation else {
            Issue.record("The injected anchored read should fail")
            return
        }
        #expect(queue.pendingTransferCallCount == 0)
        #expect(client.transferCallCount == 0)
        #expect(model.localSyncPresentation.title.contains("已保留待同步数据"))
    }

    @Test("Saving and forgetting credentials invalidate the endpoint cache")
    @MainActor
    func credentialChangesResetEndpointCache() async {
        let queue = SequencingFactQueueStore()
        let client = SequencingSyncClient()
        let pairing = SequencingPairingStore(credential: nil)
        let model = HealthCompanionModel(
            planStore: SequencingPlanStore(),
            factQueue: queue,
            pairingStore: pairing,
            localSyncClient: client,
            incrementalReader: FailingIncrementalReader()
        )
        try? await Task.sleep(for: .milliseconds(50))
        model.pairingCodeInput = testSetupCode()

        model.savePairingCodeAndSync()
        model.forgetPairedMac()

        #expect(client.resetCallCount == 2)
    }

    private func testCredential() -> HealthCompanionPairingCredential {
        try! HealthCompanionPairingCredential(setupCode: testSetupCode())
    }

    private func testSetupCode() -> String {
        let secret = Data(repeating: 0x5A, count: 32).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "dayday-health://pair/00000000-0000-0000-0000-000000000042/\(secret)"
    }
}

private final class FailingIncrementalReader: HealthKitIncrementalReading {
    enum Failure: Error { case injected }

    func fetchChanges(
        for kind: HealthReadKind,
        completion: @escaping (Result<HealthKitChangeSet, Error>) -> Void
    ) {
        completion(.failure(Failure.injected))
    }

    func commit(_: HealthKitChangeSet) {}
}

private final class SequencingPlanStore: HealthImportPlanStoring {
    private var plan = HealthImportPlan.empty

    func load() -> HealthImportPlan { plan }

    func enqueueInitialImport(types: [HealthReadKind], at date: Date) -> HealthImportPlan {
        plan.requestedTypes.formUnion(types)
        plan.initialImportQueuedAt = plan.initialImportQueuedAt ?? date
        return plan
    }

    func requestManualAttempt(at date: Date) -> HealthImportPlan {
        plan.lastManualSyncRequestAt = date
        return plan
    }

    func recordCompletedRead(for kind: HealthReadKind, at date: Date) -> HealthImportPlan {
        plan.lastCompletedReadAtByKind[kind] = date
        return plan
    }
}

private final class SequencingPairingStore: HealthCompanionPairingStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var credential: HealthCompanionPairingCredential?

    init(credential: HealthCompanionPairingCredential?) {
        self.credential = credential
    }

    func load() throws -> HealthCompanionPairingCredential? {
        lock.withLock { credential }
    }

    func save(_ credential: HealthCompanionPairingCredential) throws {
        lock.withLock { self.credential = credential }
    }

    func remove() throws {
        lock.withLock { credential = nil }
    }
}

private final class SequencingSyncClient: HealthLocalSyncing, @unchecked Sendable {
    private let lock = NSLock()
    private var transfers = 0
    private var resets = 0

    var transferCallCount: Int { lock.withLock { transfers } }
    var resetCallCount: Int { lock.withLock { resets } }

    func transfer(
        _: HealthArchiveBatch,
        credential _: HealthCompanionPairingCredential,
        completion _: @escaping @MainActor (Result<HealthSyncAcknowledgement, Error>) -> Void
    ) {
        lock.withLock { transfers += 1 }
    }

    func resetEndpointCache() {
        lock.withLock { resets += 1 }
    }
}

private final class SequencingFactQueueStore: HealthFactQueueStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var pendingMutations = 0
    private var pendingCalls = 0

    var pendingTransferCallCount: Int { lock.withLock { pendingCalls } }

    func setPendingMutationCount(_ count: Int) {
        lock.withLock { pendingMutations = count }
    }

    func status() throws -> HealthFactQueueStatus {
        lock.withLock {
            HealthFactQueueStatus(
                factCount: 0,
                tombstoneCount: 0,
                pendingMutationCount: pendingMutations,
                recentFacts: []
            )
        }
    }

    func apply(
        records _: [HealthFactRecord],
        deletedIDs _: [UUID],
        kind _: HealthReadKind,
        at _: Date
    ) throws {}

    func pendingTransfer(
        sourceInstallationID: UUID,
        maximumMutations _: Int,
        at date: Date
    ) throws -> HealthFactPendingTransfer? {
        try lock.withLock {
            pendingCalls += 1
            guard pendingMutations > 0 else { return nil }
            let batch = try HealthArchiveBatch(
                sourceInstallationID: sourceInstallationID,
                createdAt: date,
                observations: [],
                tombstones: []
            )
            return HealthFactPendingTransfer(batch: batch, mutationCount: pendingMutations)
        }
    }

    func acknowledgeTransfer(_: HealthSyncAcknowledgement) throws {
        lock.withLock { pendingMutations = 0 }
    }
}
