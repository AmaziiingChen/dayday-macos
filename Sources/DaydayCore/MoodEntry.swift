import Foundation

// MARK: - User-authored mood

public struct MoodLevel: Codable, Hashable, Sendable {
    public enum ValidationError: Error, Equatable, Sendable {
        case outsideClosedScale(Int)
    }

    public let rawValue: Int

    public init(rawValue: Int) throws {
        guard (1...5).contains(rawValue) else {
            throw ValidationError.outsideClosedScale(rawValue)
        }
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(rawValue: container.decode(Int.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum MoodScope: String, Codable, Hashable, Sendable {
    case work
    case life
    case unclassified
}

public enum MoodEntrySource: String, Codable, Hashable, Sendable {
    /// V0.1 deliberately has no inferred/model source.
    case user
}

public struct MoodEntry: Codable, Hashable, Sendable {
    public enum ValidationError: Error, Equatable, Sendable {
        case nonFiniteObservationDate
        case unsupportedSource
    }

    public let id: MoodEntryID
    public let dayID: DayID
    public let observedAt: Date
    public let pleasantness: MoodLevel
    public let energy: MoodLevel
    public let labels: [String]
    public let reason: String?
    public let scope: MoodScope
    public let isOverallFeeling: Bool
    public let source: MoodEntrySource

    public init(
        id: MoodEntryID = MoodEntryID(),
        dayID: DayID,
        observedAt: Date,
        pleasantness: MoodLevel,
        energy: MoodLevel,
        labels: [String] = [],
        reason: String? = nil,
        scope: MoodScope = .unclassified,
        isOverallFeeling: Bool = false
    ) throws {
        guard observedAt.isFinite else {
            throw ValidationError.nonFiniteObservationDate
        }
        self.id = id
        self.dayID = dayID
        self.observedAt = observedAt
        self.pleasantness = pleasantness
        self.energy = energy
        self.labels = labels
        self.reason = reason
        self.scope = scope
        self.isOverallFeeling = isOverallFeeling
        source = .user
    }

    private enum CodingKeys: String, CodingKey {
        case id, dayID, observedAt, pleasantness, energy, labels, reason, scope
        case isOverallFeeling, source
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(MoodEntrySource.self, forKey: .source) == .user else {
            throw ValidationError.unsupportedSource
        }
        try self.init(
            id: values.decode(MoodEntryID.self, forKey: .id),
            dayID: values.decode(DayID.self, forKey: .dayID),
            observedAt: values.decode(Date.self, forKey: .observedAt),
            pleasantness: values.decode(MoodLevel.self, forKey: .pleasantness),
            energy: values.decode(MoodLevel.self, forKey: .energy),
            labels: values.decode([String].self, forKey: .labels),
            reason: values.decodeIfPresent(String.self, forKey: .reason),
            scope: values.decode(MoodScope.self, forKey: .scope),
            isOverallFeeling: values.decode(Bool.self, forKey: .isOverallFeeling)
        )
    }
}

private extension Date {
    var isFinite: Bool {
        timeIntervalSinceReferenceDate.isFinite
    }
}
