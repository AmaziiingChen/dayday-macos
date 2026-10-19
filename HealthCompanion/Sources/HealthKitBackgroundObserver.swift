import Foundation
@preconcurrency import HealthKit

@MainActor
final class HealthKitBackgroundObserver {
    enum State: Equatable {
        case inactive
        case observing
        case failed(String)

        var title: String {
            switch self {
            case .inactive: return "未启用"
            case .observing: return "等待系统更新"
            case .failed: return "不可用"
            }
        }
    }

    private let healthStore: HKHealthStore
    private var activeQueries: [HKObserverQuery] = []
    private var onUpdate: (@MainActor (HealthReadKind, @escaping () -> Void) -> Void)?
    private var pendingDeliveryRequests = 0
    private var firstDeliveryError: String?

    init(healthStore: HKHealthStore) {
        self.healthStore = healthStore
    }

    func start(
        kinds: [HealthReadKind],
        onUpdate: @escaping @MainActor (HealthReadKind, @escaping () -> Void) -> Void,
        completion: @escaping @MainActor (State) -> Void
    ) {
        stop()
        guard HKHealthStore.isHealthDataAvailable() else {
            completion(.inactive)
            return
        }

        let supportedKinds = kinds.compactMap { kind in
            HealthReadCatalog.sampleType(for: kind).map { (kind, $0) }
        }
        guard !supportedKinds.isEmpty else {
            completion(.inactive)
            return
        }

        self.onUpdate = onUpdate
        pendingDeliveryRequests = supportedKinds.count
        firstDeliveryError = nil

        for (kind, sampleType) in supportedKinds {
            let query = HKObserverQuery(sampleType: sampleType, predicate: nil) { [weak self] _, healthKitCompletion, error in
                guard error == nil else {
                    healthKitCompletion()
                    return
                }

                let completion = HealthKitCompletion(healthKitCompletion)
                Task { @MainActor [weak self] in
                    guard let self, let onUpdate = self.onUpdate else {
                        completion.call()
                        return
                    }
                    onUpdate(kind, completion.call)
                }
            }
            activeQueries.append(query)
            healthStore.execute(query)

            // Dayday is an archive, not a real-time monitor. Let HealthKit coalesce wakeups at an
            // hourly cadence; the explicit “立即同步” path remains available when immediacy matters.
            healthStore.enableBackgroundDelivery(for: sampleType, frequency: .hourly) { success, error in
                let errorDescription = error?.localizedDescription
                Task { @MainActor in
                    self.recordDeliveryRequest(
                        kind: kind,
                        succeeded: success,
                        errorDescription: errorDescription,
                        completion: completion
                    )
                }
            }
        }
    }

    func stop() {
        activeQueries.forEach(healthStore.stop)
        activeQueries = []
        onUpdate = nil
    }

    private func recordDeliveryRequest(
        kind: HealthReadKind,
        succeeded: Bool,
        errorDescription: String?,
        completion: @escaping @MainActor (State) -> Void
    ) {
        if !succeeded, firstDeliveryError == nil {
            firstDeliveryError = errorDescription ?? BackgroundObserverError.deliveryNotEnabled(kind).localizedDescription
        }
        pendingDeliveryRequests -= 1
        guard pendingDeliveryRequests == 0 else { return }
        completion(firstDeliveryError.map(State.failed) ?? .observing)
    }

    enum BackgroundObserverError: LocalizedError {
        case deliveryNotEnabled(HealthReadKind)

        var errorDescription: String? {
            switch self {
            case let .deliveryNotEnabled(kind):
                return "系统未为\(kind.title)启用后台更新。"
            }
        }
    }
}

private final class HealthKitCompletion: @unchecked Sendable {
    private let completion: () -> Void

    init(_ completion: @escaping () -> Void) {
        self.completion = completion
    }

    func call() {
        completion()
    }
}
