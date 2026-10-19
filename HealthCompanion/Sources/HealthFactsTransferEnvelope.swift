import Foundation

/// A self-contained, versioned data package for a later *paired local-network* transport.
/// It is an encoding boundary only: this Companion neither opens a network listener nor sends it.
struct HealthFactsTransferEnvelope: Codable, Equatable, Sendable {
    static let currentFormatVersion = 1

    let formatVersion: Int
    let batchID: UUID
    let sourceInstallationID: UUID
    let createdAt: Date
    let observations: [Observation]
    let tombstones: [Tombstone]

    init(
        batchID: UUID = UUID(),
        sourceInstallationID: UUID,
        createdAt: Date = .now,
        observations: [Observation],
        tombstones: [Tombstone]
    ) throws {
        try Self.validate(observations: observations, tombstones: tombstones)
        formatVersion = Self.currentFormatVersion
        self.batchID = batchID
        self.sourceInstallationID = sourceInstallationID
        self.createdAt = createdAt
        self.observations = observations
        self.tombstones = tombstones
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        guard formatVersion == Self.currentFormatVersion else {
            throw HealthFactsTransferEnvelopeError.unsupportedFormatVersion(formatVersion)
        }
        let batchID = try container.decode(UUID.self, forKey: .batchID)
        let sourceInstallationID = try container.decode(UUID.self, forKey: .sourceInstallationID)
        let createdAt = try container.decode(Date.self, forKey: .createdAt)
        let observations = try container.decode([Observation].self, forKey: .observations)
        let tombstones = try container.decode([Tombstone].self, forKey: .tombstones)
        try Self.validate(observations: observations, tombstones: tombstones)

        self.formatVersion = formatVersion
        self.batchID = batchID
        self.sourceInstallationID = sourceInstallationID
        self.createdAt = createdAt
        self.observations = observations
        self.tombstones = tombstones
    }

    static func encode(_ envelope: HealthFactsTransferEnvelope) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(envelope)
    }

    static func decode(_ data: Data) throws -> HealthFactsTransferEnvelope {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(HealthFactsTransferEnvelope.self, from: data)
    }

    private static func validate(observations: [Observation], tombstones: [Tombstone]) throws {
        let observationIDs = observations.map(\.id)
        let tombstoneIDs = tombstones.map(\.id)
        guard Set(observationIDs).count == observationIDs.count else {
            throw HealthFactsTransferEnvelopeError.duplicateObservationID
        }
        guard Set(tombstoneIDs).count == tombstoneIDs.count else {
            throw HealthFactsTransferEnvelopeError.duplicateTombstoneID
        }
        guard Set(observationIDs).isDisjoint(with: Set(tombstoneIDs)) else {
            throw HealthFactsTransferEnvelopeError.conflictingObservationAndTombstone
        }
    }

    struct Observation: Codable, Equatable, Identifiable, Sendable {
        let id: UUID
        let kind: HealthReadKind
        let startDate: Date
        let endDate: Date
        let sourceName: String
        let sourceBundleIdentifier: String
        let payload: Payload

        init(record: HealthFactRecord) {
            id = record.id
            kind = record.kind
            startDate = record.startDate
            endDate = record.endDate
            sourceName = record.sourceName
            sourceBundleIdentifier = record.sourceBundleIdentifier
            payload = Payload(recordPayload: record.payload)
        }
    }

    struct Tombstone: Codable, Equatable, Identifiable, Sendable {
        let id: UUID
        let kind: HealthReadKind
        let deletedAt: Date

        init(tombstone: HealthFactTombstone) {
            id = tombstone.id
            kind = tombstone.kind
            deletedAt = tombstone.deletedAt
        }
    }

    enum Payload: Codable, Equatable, Sendable {
        case quantity(value: Double, unit: String)
        case category(rawValue: Int)
        case workout(activityType: UInt, duration: TimeInterval, activeEnergyKilocalories: Double?)

        private enum CodingKeys: String, CodingKey {
            case kind, value, unit, rawValue, activityType, duration, activeEnergyKilocalories
        }

        private enum Kind: String, Codable {
            case quantity, category, workout
        }

        init(recordPayload: HealthFactRecord.Payload) {
            switch recordPayload {
            case let .quantity(value, unit): self = .quantity(value: value, unit: unit)
            case let .category(rawValue): self = .category(rawValue: rawValue)
            case let .workout(activityType, duration, activeEnergyKilocalories):
                self = .workout(
                    activityType: activityType,
                    duration: duration,
                    activeEnergyKilocalories: activeEnergyKilocalories
                )
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case let .quantity(value, unit):
                try container.encode(Kind.quantity, forKey: .kind)
                try container.encode(value, forKey: .value)
                try container.encode(unit, forKey: .unit)
            case let .category(rawValue):
                try container.encode(Kind.category, forKey: .kind)
                try container.encode(rawValue, forKey: .rawValue)
            case let .workout(activityType, duration, activeEnergyKilocalories):
                try container.encode(Kind.workout, forKey: .kind)
                try container.encode(activityType, forKey: .activityType)
                try container.encode(duration, forKey: .duration)
                try container.encode(activeEnergyKilocalories, forKey: .activeEnergyKilocalories)
            }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(Kind.self, forKey: .kind) {
            case .quantity:
                self = try .quantity(
                    value: container.decode(Double.self, forKey: .value),
                    unit: container.decode(String.self, forKey: .unit)
                )
            case .category:
                self = try .category(rawValue: container.decode(Int.self, forKey: .rawValue))
            case .workout:
                self = try .workout(
                    activityType: container.decode(UInt.self, forKey: .activityType),
                    duration: container.decode(TimeInterval.self, forKey: .duration),
                    activeEnergyKilocalories: container.decodeIfPresent(Double.self, forKey: .activeEnergyKilocalories)
                )
            }
        }
    }
}

enum HealthFactsTransferEnvelopeError: LocalizedError, Equatable {
    case unsupportedFormatVersion(Int)
    case duplicateObservationID
    case duplicateTombstoneID
    case conflictingObservationAndTombstone

    var errorDescription: String? {
        switch self {
        case let .unsupportedFormatVersion(version): return "不支持健康同步数据包版本 \(version)。"
        case .duplicateObservationID: return "健康同步数据包包含重复事实。"
        case .duplicateTombstoneID: return "健康同步数据包包含重复删除记录。"
        case .conflictingObservationAndTombstone: return "健康同步数据包同时包含同一事实及其删除记录。"
        }
    }
}
