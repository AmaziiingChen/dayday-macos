import Foundation
@preconcurrency import HealthKit

struct HealthKitChangeSet {
    let kind: HealthReadKind
    let records: [HealthFactRecord]
    let deletedIDs: [UUID]
    let nextAnchor: HKQueryAnchor?
}

protocol HealthKitAnchorStoring {
    func loadAnchor(for kind: HealthReadKind) -> HKQueryAnchor?
    func save(_ anchor: HKQueryAnchor?, for kind: HealthReadKind)
}

protocol HealthKitIncrementalReading: AnyObject {
    func fetchChanges(
        for kind: HealthReadKind,
        completion: @escaping (Result<HealthKitChangeSet, Error>) -> Void
    )
    func commit(_ changeSet: HealthKitChangeSet)
}

final class UserDefaultsHealthKitAnchorStore: HealthKitAnchorStoring {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadAnchor(for kind: HealthReadKind) -> HKQueryAnchor? {
        guard let data = defaults.data(forKey: key(for: kind)) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }

    func save(_ anchor: HKQueryAnchor?, for kind: HealthReadKind) {
        guard let anchor else {
            defaults.removeObject(forKey: key(for: kind))
            return
        }
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true) else {
            return
        }
        defaults.set(data, forKey: key(for: kind))
    }

    private func key(for kind: HealthReadKind) -> String {
        "healthkit-anchor-v1-\(kind.rawValue)"
    }
}

final class HealthKitIncrementalReader: HealthKitIncrementalReading {
    /// A full history can include years of high-frequency heart-rate samples. Small anchored pages
    /// bound memory and give the main app a chance to remain interactive between durable commits.
    static let pageSize = 500

    private let healthStore: HKHealthStore
    private let anchorStore: HealthKitAnchorStoring

    init(
        healthStore: HKHealthStore,
        anchorStore: HealthKitAnchorStoring = UserDefaultsHealthKitAnchorStore()
    ) {
        self.healthStore = healthStore
        self.anchorStore = anchorStore
    }

    func fetchChanges(
        for kind: HealthReadKind,
        completion: @escaping (Result<HealthKitChangeSet, Error>) -> Void
    ) {
        guard let sampleType = HealthReadCatalog.sampleType(for: kind) else {
            completion(.failure(HealthKitReaderError.unsupportedType(kind)))
            return
        }

        let completion = HealthKitReaderCompletion(completion)
        let query = HKAnchoredObjectQuery(
            type: sampleType,
            predicate: nil,
            anchor: anchorStore.loadAnchor(for: kind),
            limit: Self.pageSize
        ) { _, samples, deletedObjects, nextAnchor, error in
            if let error {
                completion.call(.failure(error))
                return
            }

            let records = (samples ?? []).compactMap { Self.record(from: $0, expectedKind: kind) }
            completion.call(.success(HealthKitChangeSet(
                kind: kind,
                records: records,
                deletedIDs: (deletedObjects ?? []).map(\.uuid),
                nextAnchor: nextAnchor
            )))
        }
        healthStore.execute(query)
    }

    func commit(_ changeSet: HealthKitChangeSet) {
        anchorStore.save(changeSet.nextAnchor, for: changeSet.kind)
    }

    private static func record(from sample: HKSample, expectedKind kind: HealthReadKind) -> HealthFactRecord? {
        let source = sample.sourceRevision.source
        let sourceName = source.name
        let sourceBundleIdentifier = source.bundleIdentifier
        let payload: HealthFactRecord.Payload

        switch HealthReadCatalog.payloadKind(for: kind) {
        case .category:
            guard let sample = sample as? HKCategorySample else { return nil }
            payload = .category(rawValue: sample.value)
        case let .quantity(unit):
            guard let sample = sample as? HKQuantitySample else { return nil }
            payload = .quantity(value: sample.quantity.doubleValue(for: unit), unit: unit.unitString)
        case .workout:
            guard let sample = sample as? HKWorkout else { return nil }
            payload = .workout(
                activityType: sample.workoutActivityType.rawValue,
                duration: sample.duration,
                activeEnergyKilocalories: sample.totalEnergyBurned?.doubleValue(for: .kilocalorie())
            )
        }

        return HealthFactRecord(
            id: sample.uuid,
            kind: kind,
            startDate: sample.startDate,
            endDate: sample.endDate,
            sourceName: sourceName,
            sourceBundleIdentifier: sourceBundleIdentifier,
            payload: payload
        )
    }

    enum HealthKitReaderError: LocalizedError {
        case unsupportedType(HealthReadKind)

        var errorDescription: String? {
            switch self {
            case let .unsupportedType(kind):
                return "此设备不支持读取 \(kind.title)。"
            }
        }
    }
}

/// HealthKit invokes anchored-query handlers from an SDK-owned concurrent context. The wrapper
/// confines the legacy completion callback to that single hand-off, avoiding an unsound capture of
/// the reader or UI state in the handler itself.
private final class HealthKitReaderCompletion: @unchecked Sendable {
    private let completion: (Result<HealthKitChangeSet, Error>) -> Void

    init(_ completion: @escaping (Result<HealthKitChangeSet, Error>) -> Void) {
        self.completion = completion
    }

    func call(_ result: Result<HealthKitChangeSet, Error>) {
        completion(result)
    }
}
