import Foundation

struct HealthImportPlan: Codable, Equatable {
    var requestedTypes: Set<HealthReadKind>
    var initialImportQueuedAt: Date?
    var lastManualSyncRequestAt: Date?
    /// A successful anchored reconciliation can legitimately find no samples. Keep that fact
    /// separately from the queue so the UI does not confuse "not checked" with "checked, empty".
    var lastCompletedReadAtByKind: [HealthReadKind: Date]

    static let empty = HealthImportPlan(
        requestedTypes: [],
        initialImportQueuedAt: nil,
        lastManualSyncRequestAt: nil,
        lastCompletedReadAtByKind: [:]
    )

    var hasPendingWork: Bool {
        !requestedTypes.isEmpty
    }

    /// The initial import may be interrupted by an app termination, an authorization change, or
    /// iOS background limits. Keep the durable plan until every requested type has completed at
    /// least one anchored reconciliation (an empty result still counts as completed).
    var hasUncompletedRequestedReads: Bool {
        requestedTypes.contains { lastCompletedRead(at: $0) == nil }
    }

    func lastCompletedRead(at kind: HealthReadKind) -> Date? {
        lastCompletedReadAtByKind[kind]
    }

    private enum CodingKeys: String, CodingKey {
        case requestedTypes
        case initialImportQueuedAt
        case lastManualSyncRequestAt
        case lastCompletedReadAtByKind
    }

    init(
        requestedTypes: Set<HealthReadKind>,
        initialImportQueuedAt: Date?,
        lastManualSyncRequestAt: Date?,
        lastCompletedReadAtByKind: [HealthReadKind: Date] = [:]
    ) {
        self.requestedTypes = requestedTypes
        self.initialImportQueuedAt = initialImportQueuedAt
        self.lastManualSyncRequestAt = lastManualSyncRequestAt
        self.lastCompletedReadAtByKind = lastCompletedReadAtByKind
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        requestedTypes = try container.decodeIfPresent(Set<HealthReadKind>.self, forKey: .requestedTypes) ?? []
        initialImportQueuedAt = try container.decodeIfPresent(Date.self, forKey: .initialImportQueuedAt)
        lastManualSyncRequestAt = try container.decodeIfPresent(Date.self, forKey: .lastManualSyncRequestAt)
        lastCompletedReadAtByKind = try container.decodeIfPresent(
            [HealthReadKind: Date].self,
            forKey: .lastCompletedReadAtByKind
        ) ?? [:]
    }
}

protocol HealthImportPlanStoring {
    func load() -> HealthImportPlan
    func enqueueInitialImport(types: [HealthReadKind], at date: Date) -> HealthImportPlan
    func requestManualAttempt(at date: Date) -> HealthImportPlan
    func recordCompletedRead(for kind: HealthReadKind, at date: Date) -> HealthImportPlan
}

final class UserDefaultsHealthImportPlanStore: HealthImportPlanStoring {
    private let defaults: UserDefaults
    private let key = "health-import-plan-v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> HealthImportPlan {
        guard let data = defaults.data(forKey: key) else {
            return .empty
        }

        return (try? JSONDecoder().decode(HealthImportPlan.self, from: data)) ?? .empty
    }

    func enqueueInitialImport(types: [HealthReadKind], at date: Date) -> HealthImportPlan {
        var plan = load()
        plan.requestedTypes.formUnion(types)
        plan.initialImportQueuedAt = plan.initialImportQueuedAt ?? date
        save(plan)
        return plan
    }

    func requestManualAttempt(at date: Date) -> HealthImportPlan {
        var plan = load()
        plan.lastManualSyncRequestAt = date
        save(plan)
        return plan
    }

    func recordCompletedRead(for kind: HealthReadKind, at date: Date) -> HealthImportPlan {
        var plan = load()
        plan.lastCompletedReadAtByKind[kind] = date
        save(plan)
        return plan
    }

    private func save(_ plan: HealthImportPlan) {
        guard let data = try? JSONEncoder().encode(plan) else { return }
        defaults.set(data, forKey: key)
    }
}
