import Foundation

// MARK: - Artifact identifiers

public struct DayID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
    public init() { self.init(rawValue: UUID()) }
}

public struct WorkReportID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
    public init() { self.init(rawValue: UUID()) }
}

public struct WorkReportRevisionID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
    public init() { self.init(rawValue: UUID()) }
}

public struct ModelUsageID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
    public init() { self.init(rawValue: UUID()) }
}

public struct JournalEntryID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
    public init() { self.init(rawValue: UUID()) }
}

public struct JournalOriginalVersionID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
    public init() { self.init(rawValue: UUID()) }
}

public struct JournalFragmentID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
    public init() { self.init(rawValue: UUID()) }
}

public struct JournalDerivedVersionID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
    public init() { self.init(rawValue: UUID()) }
}

public struct JournalAttachmentID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
    public init() { self.init(rawValue: UUID()) }
}

public struct JournalLocationSnapshotID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) { self.rawValue = rawValue }
    public init() { rawValue = UUID() }
}

public struct MoodEntryID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
    public init() { self.init(rawValue: UUID()) }
}

public struct WeatherSnapshotID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
    public init() { self.init(rawValue: UUID()) }
}
