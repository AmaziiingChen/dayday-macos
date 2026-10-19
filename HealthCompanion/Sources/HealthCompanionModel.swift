import Foundation
import HealthKit

struct HealthDeferredManualSyncRequest: Equatable {
    private(set) var isPending = false

    mutating func request() {
        isPending = true
    }

    mutating func drain() -> Bool {
        let result = isPending
        isPending = false
        return result
    }
}

struct HealthManualSyncReadGate: Equatable {
    enum Action: Equatable {
        case none
        case transfer
    }

    private(set) var isPending = false

    mutating func request() {
        isPending = true
    }

    mutating func finishRead(succeeded: Bool) -> Action {
        guard isPending else { return .none }
        isPending = false
        return succeeded ? .transfer : .none
    }
}

@MainActor
final class HealthCompanionModel: ObservableObject {
    enum AuthorizationPresentation: Equatable {
        case checking
        case unavailable
        case readyToRequest
        case requested
        case failed(String)

        var title: String {
            switch self {
            case .checking:
                return "正在检查 HealthKit"
            case .unavailable:
                return "此设备不可用"
            case .readyToRequest:
                return "尚未请求"
            case .requested:
                return "已请求读取授权"
            case .failed:
                return "请求失败"
            }
        }
    }

    @Published private(set) var authorizationPresentation: AuthorizationPresentation = .checking
    @Published private(set) var syncPlan: HealthImportPlan
    @Published private(set) var importPresentation: ImportPresentation = .idle
    @Published private(set) var backgroundObservationState: HealthKitBackgroundObserver.State = .inactive
    @Published private(set) var localFactCount = 0
    @Published private(set) var localTombstoneCount = 0
    @Published private(set) var recentFacts: [HealthFactRecord] = []
    @Published private(set) var coverageByKind: [HealthReadKind: HealthFactCoverage] = [:]
    @Published var pairingCodeInput = ""
    @Published private(set) var localSyncPresentation: LocalSyncPresentation = .notPaired

    private let healthStore: HKHealthStore
    private let planStore: HealthImportPlanStoring
    private let incrementalReader: any HealthKitIncrementalReading
    private let backgroundObserver: HealthKitBackgroundObserver
    private let queueWorker: HealthFactQueueWorker
    private let pairingStore: any HealthCompanionPairingStoring
    private let localSyncClient: any HealthLocalSyncing
    private let sourceInstallationID: UUID
    private var pendingAnchorCommit: HealthKitChangeSet?
    private var pendingMutationCount = 0
    private var acknowledgedChangesInCurrentSync = 0
    private var syncIsActive = false
    private var deferredManualSync = HealthDeferredManualSyncRequest()
    private var manualSyncReadGate: HealthManualSyncReadGate

    enum ImportPresentation: Equatable {
        case idle
        case importing
        case imported(recordCount: Int, deletedCount: Int)
        case failed(String)

        var title: String {
            switch self {
            case .idle: return "尚未读取"
            case .importing: return "正在读取"
            case let .imported(recordCount, deletedCount):
                return "已读取 \(recordCount) 条，删除 \(deletedCount) 条"
            case .failed: return "读取失败"
            }
        }
    }

    enum LocalSyncPresentation: Equatable {
        case notPaired
        case ready(pendingChanges: Int)
        case waitingForRead
        case syncing(completedChanges: Int, pendingChanges: Int)
        case synchronized(Date, transferredChanges: Int)
        case failed(String)

        var title: String {
            switch self {
            case .notPaired: return "尚未与 Mac 配对"
            case let .ready(pendingChanges):
                return pendingChanges == 0
                    ? "已配对，等待健康变化"
                    : "已配对，待同步 \(pendingChanges.formatted(.number)) 条变更"
            case .waitingForRead: return "正在完成本机读取，完成后会自动同步"
            case let .syncing(completedChanges, pendingChanges):
                if completedChanges > 0 {
                    return "已同步 \(completedChanges.formatted(.number)) 条，剩余 \(pendingChanges.formatted(.number)) 条"
                }
                return pendingChanges > 0
                    ? "正在通过本地网络同步 \(pendingChanges.formatted(.number)) 条"
                    : "正在准备本地网络同步"
            case let .synchronized(date, transferredChanges):
                let timestamp = date.formatted(date: .abbreviated, time: .shortened)
                return transferredChanges > 0
                    ? "已同步 \(transferredChanges.formatted(.number)) 条 · \(timestamp)"
                    : "已是最新 · \(timestamp)"
            case let .failed(message): return "本次同步未完成：\(message)"
            }
        }
    }

    init(
        healthStore: HKHealthStore = HKHealthStore(),
        planStore: HealthImportPlanStoring = UserDefaultsHealthImportPlanStore(),
        factQueue: HealthFactQueueStoring = HealthFactQueueStore(),
        anchorStore: HealthKitAnchorStoring = UserDefaultsHealthKitAnchorStore(),
        pairingStore: any HealthCompanionPairingStoring = HealthCompanionPairingStore(),
        localSyncClient: any HealthLocalSyncing = HealthLocalSyncClient(),
        incrementalReader: (any HealthKitIncrementalReading)? = nil,
        manualSyncReadGate: HealthManualSyncReadGate = HealthManualSyncReadGate()
    ) {
        self.healthStore = healthStore
        self.planStore = planStore
        self.queueWorker = HealthFactQueueWorker(store: factQueue)
        self.incrementalReader = incrementalReader
            ?? HealthKitIncrementalReader(healthStore: healthStore, anchorStore: anchorStore)
        self.backgroundObserver = HealthKitBackgroundObserver(healthStore: healthStore)
        self.pairingStore = pairingStore
        self.localSyncClient = localSyncClient
        self.manualSyncReadGate = manualSyncReadGate
        self.sourceInstallationID = Self.loadOrCreateSourceInstallationID()
        self.syncPlan = planStore.load()
        reloadLocalQueueStatus()
        refreshPairingState()
        refreshAuthorizationRequestStatus()
    }

    func refreshAuthorizationRequestStatus() {
        guard HKHealthStore.isHealthDataAvailable() else {
            authorizationPresentation = .unavailable
            return
        }

        authorizationPresentation = .checking
        healthStore.getRequestStatusForAuthorization(
            toShare: [],
            read: HealthReadCatalog.readTypes
        ) { [weak self] status, error in
            Task { @MainActor [weak self] in
                guard let self else { return }

                if let error {
                    self.authorizationPresentation = .failed(error.localizedDescription)
                    return
                }

                switch status {
                case .shouldRequest:
                    self.authorizationPresentation = .readyToRequest
                case .unnecessary, .unknown:
                    self.authorizationPresentation = .requested
                    self.startBackgroundObservation()
                    self.resumeInitialImportIfNeeded()
                @unknown default:
                    self.authorizationPresentation = .requested
                    self.startBackgroundObservation()
                    self.resumeInitialImportIfNeeded()
                }
            }
        }
    }

    func requestReadAuthorization() {
        guard HKHealthStore.isHealthDataAvailable() else {
            authorizationPresentation = .unavailable
            return
        }

        healthStore.requestAuthorization(toShare: [], read: HealthReadCatalog.readTypes) { [weak self] success, error in
            Task { @MainActor [weak self] in
                guard let self else { return }

                if let error {
                    self.authorizationPresentation = .failed(error.localizedDescription)
                    return
                }

                guard success else {
                    self.authorizationPresentation = .failed("系统未完成授权请求。")
                    return
                }

                self.authorizationPresentation = .requested
                self.syncPlan = self.planStore.enqueueInitialImport(
                    types: HealthReadCatalog.kinds,
                    at: .now
                )
                self.startBackgroundObservation()
                self.importAuthorizedHealthFacts()
            }
        }
    }

    func markManualSyncRequested() {
        syncPlan = planStore.requestManualAttempt(at: .now)
        manualSyncReadGate.request()
        guard authorizationPresentation != .unavailable else {
            importPresentation = .failed("此设备无法读取 HealthKit。")
            finishCurrentReadAndSyncIfNeeded(succeeded: false)
            return
        }
        guard importPresentation != .importing else {
            localSyncPresentation = .waitingForRead
            return
        }
        importAuthorizedHealthFacts()
    }

    func savePairingCodeAndSync() {
        do {
            let credential = try HealthCompanionPairingCredential(setupCode: pairingCodeInput)
            try pairingStore.save(credential)
            localSyncClient.resetEndpointCache()
            pairingCodeInput = ""
            syncNow()
        } catch {
            localSyncPresentation = .failed("配对码无效。请回到 Mac 的健康页面重新复制。")
        }
    }

    func forgetPairedMac() {
        do {
            try pairingStore.remove()
            localSyncClient.resetEndpointCache()
            localSyncPresentation = .notPaired
        } catch {
            localSyncPresentation = .failed(error.localizedDescription)
        }
    }

    func syncNow(isManualRequest: Bool = false) {
        guard importPresentation != .importing else {
            if isManualRequest {
                manualSyncReadGate.request()
            }
            localSyncPresentation = .waitingForRead
            return
        }
        guard !syncIsActive else {
            if isManualRequest {
                deferredManualSync.request()
            }
            return
        }
        let credential: HealthCompanionPairingCredential
        do {
            guard let loaded = try pairingStore.load() else {
                localSyncPresentation = .notPaired
                return
            }
            credential = loaded
        } catch {
            localSyncPresentation = .failed(error.localizedDescription)
            return
        }
        syncIsActive = true
        acknowledgedChangesInCurrentSync = 0
        localSyncPresentation = .syncing(
            completedChanges: 0,
            pendingChanges: pendingMutationCount
        )
        sendNextPendingBatch(using: credential)
    }

    /// A foreground transition is a bounded retry opportunity for a durable, unacknowledged
    /// outbox. It performs one queue status read and does not install a timer or Bonjour browser
    /// when there is nothing to send.
    func resumePendingSyncWhenActive() {
        queueWorker.loadStatus { [weak self] result in
            guard let self, case let .succeeded(status) = result else { return }
            self.apply(queueStatus: status)
            guard status.pendingMutationCount > 0 else { return }
            self.syncNow()
        }
    }

    func importAuthorizedHealthFacts(onFinish: @escaping () -> Void = {}) {
        guard authorizationPresentation != .unavailable else { return }
        guard importPresentation != .importing else {
            onFinish()
            return
        }
        importPresentation = .importing
        importNext(kindIndex: 0, imported: 0, deleted: 0, onFinish: onFinish)
    }

    private func importNext(kindIndex: Int, imported: Int, deleted: Int, onFinish: @escaping () -> Void) {
        guard kindIndex < HealthReadCatalog.kinds.count else {
            importPresentation = .imported(recordCount: imported, deletedCount: deleted)
            // HealthKit can wake the observer even when an anchored query finds no changes.
            // Attempt the network only once after the whole read pass, and only when the durable
            // outbox proves there is work. This avoids up to one Bonjour discovery per kind.
            finishCurrentReadAndSyncIfNeeded(succeeded: true)
            onFinish()
            return
        }

        let kind = HealthReadCatalog.kinds[kindIndex]
        incrementalReader.fetchChanges(for: kind) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }

                switch result {
                case let .success(changeSet):
                    let pageContainsChanges = !changeSet.records.isEmpty || !changeSet.deletedIDs.isEmpty
                    guard pageContainsChanges else {
                        // An empty anchored page advances no durable facts. Commit its anchor and
                        // move on without opening SQLite or rebuilding queue coverage, keeping the
                        // common no-change observer wake effectively idle.
                        self.incrementalReader.commit(changeSet)
                        self.syncPlan = self.planStore.recordCompletedRead(for: changeSet.kind, at: .now)
                        self.importNext(
                            kindIndex: kindIndex + 1,
                            imported: imported,
                            deleted: deleted,
                            onFinish: onFinish
                        )
                        return
                    }
                    self.pendingAnchorCommit = changeSet
                    self.queueWorker.apply(
                        records: changeSet.records,
                        deletedIDs: changeSet.deletedIDs,
                        kind: changeSet.kind,
                        at: .now
                    ) { [weak self] queueResult in
                        guard let self, let changeSet = self.pendingAnchorCommit else {
                            onFinish()
                            return
                        }
                        self.pendingAnchorCommit = nil

                        switch queueResult {
                        case let .succeeded(status):
                            self.apply(queueStatus: status)
                            self.incrementalReader.commit(changeSet)

                            self.importNext(
                                kindIndex: kindIndex,
                                imported: imported + changeSet.records.count,
                                deleted: deleted + changeSet.deletedIDs.count,
                                onFinish: onFinish
                            )
                        case let .failed(message):
                            self.importPresentation = .failed(message)
                            self.finishCurrentReadAndSyncIfNeeded(succeeded: false)
                            onFinish()
                        }
                    }
                case let .failure(error):
                    self.importPresentation = .failed(error.localizedDescription)
                    self.finishCurrentReadAndSyncIfNeeded(succeeded: false)
                    onFinish()
                }
            }
        }
    }

    private func startBackgroundObservation() {
        backgroundObserver.start(
            kinds: HealthReadCatalog.kinds,
            onUpdate: { [weak self] _, completion in
                guard let self else {
                    completion()
                    return
                }
                self.importAuthorizedHealthFacts(onFinish: completion)
            },
            completion: { [weak self] state in
                self?.backgroundObservationState = state
            }
        )
    }

    private func reloadLocalQueueStatus() {
        queueWorker.loadStatus { [weak self] result in
            guard let self else { return }
            switch result {
            case let .succeeded(status):
                self.apply(queueStatus: status)
            case .failed:
                self.localFactCount = 0
                self.localTombstoneCount = 0
                self.recentFacts = []
                self.coverageByKind = [:]
            }
        }
    }

    private func apply(queueStatus: HealthFactQueueStatus) {
        localFactCount = queueStatus.factCount
        localTombstoneCount = queueStatus.tombstoneCount
        recentFacts = queueStatus.recentFacts
        coverageByKind = Dictionary(uniqueKeysWithValues: queueStatus.coverage.map { ($0.kind, $0) })
        pendingMutationCount = queueStatus.pendingMutationCount
        if case .notPaired = localSyncPresentation { return }
        if case .syncing = localSyncPresentation { return }
        if case .waitingForRead = localSyncPresentation { return }
        localSyncPresentation = .ready(pendingChanges: queueStatus.pendingMutationCount)
    }

    func coverage(for kind: HealthReadKind) -> HealthFactCoverage? {
        coverageByKind[kind]
    }

    private func refreshPairingState() {
        do {
            guard try pairingStore.load() != nil else {
                localSyncPresentation = .notPaired
                return
            }
            queueWorker.loadStatus { [weak self] result in
                guard let self else { return }
                if case let .succeeded(status) = result {
                    self.localSyncPresentation = .ready(pendingChanges: status.pendingMutationCount)
                    if status.pendingMutationCount > 0 {
                        // A foreground launch is an intentional, bounded opportunity to retry a
                        // previously unacknowledged local transfer. The queue remains unchanged
                        // until the Mac confirms the exact batch.
                        self.syncNow()
                    }
                }
            }
        } catch {
            localSyncPresentation = .failed(error.localizedDescription)
        }
    }

    private func syncIfPaired() {
        switch localSyncPresentation {
        case .notPaired, .syncing:
            return
        case .ready, .waitingForRead, .synchronized, .failed:
            syncNow()
        }
    }

    private func finishCurrentReadAndSyncIfNeeded(succeeded: Bool = true) {
        switch manualSyncReadGate.finishRead(succeeded: succeeded) {
        case .transfer:
            syncNow(isManualRequest: true)
        case .none where !succeeded:
            // A partial manual read is not a valid upload boundary. Anchors already committed for
            // earlier durable pages remain resumable, and the outbox stays untouched for retry.
            localSyncPresentation = .failed("本机健康读取未完成，已保留待同步数据。")
        case .none where pendingMutationCount > 0:
            syncIfPaired()
        case .none:
            break
        }
    }

    private func resumeInitialImportIfNeeded() {
        guard syncPlan.hasUncompletedRequestedReads else { return }
        importAuthorizedHealthFacts()
    }

    private func sendNextPendingBatch(using credential: HealthCompanionPairingCredential) {
        queueWorker.pendingTransfer(sourceInstallationID: sourceInstallationID) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.finishSyncAttempt(with: .failed(error.localizedDescription))
            case .success(nil):
                let transferredChanges = self.acknowledgedChangesInCurrentSync
                self.finishSyncAttempt(with: .synchronized(
                    .now,
                    transferredChanges: transferredChanges
                ))
            case .success(let pending?):
                self.localSyncPresentation = .syncing(
                    completedChanges: self.acknowledgedChangesInCurrentSync,
                    pendingChanges: max(self.pendingMutationCount, pending.mutationCount)
                )
                self.localSyncClient.transfer(pending.batch, credential: credential) { [weak self] result in
                    guard let self else { return }
                    switch result {
                    case .failure(let error):
                        self.finishSyncAttempt(with: .failed(error.localizedDescription))
                    case .success(let acknowledgement):
                        self.queueWorker.acknowledgeTransfer(acknowledgement) { [weak self] result in
                            guard let self else { return }
                            switch result {
                            case .failure(let error):
                                self.finishSyncAttempt(with: .failed(error.localizedDescription))
                            case .success(let status):
                                self.acknowledgedChangesInCurrentSync += pending.mutationCount
                                self.apply(queueStatus: status)
                                self.sendNextPendingBatch(using: credential)
                            }
                        }
                    }
                }
            }
        }
    }

    private func finishSyncAttempt(with presentation: LocalSyncPresentation) {
        syncIsActive = false
        localSyncPresentation = presentation
        // Drain at most one manual request at every terminal edge. The drained retry is not
        // re-enqueued on failure, so a missing Mac cannot create an automatic retry loop.
        guard deferredManualSync.drain() else { return }
        syncNow()
    }

    private static func loadOrCreateSourceInstallationID() -> UUID {
        let key = "dayday-health-companion-source-installation-id"
        if let raw = UserDefaults.standard.string(forKey: key), let existing = UUID(uuidString: raw) { return existing }
        let created = UUID()
        UserDefaults.standard.set(created.uuidString, forKey: key)
        return created
    }
}
