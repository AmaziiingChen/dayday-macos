import Foundation

// MARK: - Journal original and derived copies

public struct JournalOriginalVersion: Codable, Hashable, Sendable {
    public enum ValidationError: Error, Equatable, Sendable {
        case invalidVersionNumber(Int)
        case missingPreviousVersion
        case unexpectedPreviousVersion
        case nonFiniteSaveDate
        case selfReferentialPreviousVersion
    }

    public let id: JournalOriginalVersionID
    public let journalEntryID: JournalEntryID
    public let versionNumber: Int
    public let previousVersionID: JournalOriginalVersionID?
    /// Exact user-authored text. No trimming, correction, or normalization is performed.
    public let body: String
    public let savedAt: Date

    public init(
        id: JournalOriginalVersionID = JournalOriginalVersionID(),
        journalEntryID: JournalEntryID,
        versionNumber: Int,
        previousVersionID: JournalOriginalVersionID?,
        body: String,
        savedAt: Date
    ) throws {
        guard versionNumber > 0 else {
            throw ValidationError.invalidVersionNumber(versionNumber)
        }
        if versionNumber == 1, previousVersionID != nil {
            throw ValidationError.unexpectedPreviousVersion
        }
        if versionNumber > 1, previousVersionID == nil {
            throw ValidationError.missingPreviousVersion
        }
        if previousVersionID == id {
            throw ValidationError.selfReferentialPreviousVersion
        }
        guard savedAt.isFinite else {
            throw ValidationError.nonFiniteSaveDate
        }

        self.id = id
        self.journalEntryID = journalEntryID
        self.versionNumber = versionNumber
        self.previousVersionID = previousVersionID
        self.body = body
        self.savedAt = savedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, journalEntryID, versionNumber, previousVersionID, body, savedAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: values.decode(JournalOriginalVersionID.self, forKey: .id),
            journalEntryID: values.decode(JournalEntryID.self, forKey: .journalEntryID),
            versionNumber: values.decode(Int.self, forKey: .versionNumber),
            previousVersionID: values.decodeIfPresent(
                JournalOriginalVersionID.self,
                forKey: .previousVersionID
            ),
            body: values.decode(String.self, forKey: .body),
            savedAt: values.decode(Date.self, forKey: .savedAt)
        )
    }
}

public struct JournalEntry: Codable, Hashable, Sendable {
    public enum ValidationError: Error, Equatable, Sendable {
        case versionBelongsToDifferentEntry
        case replacementDoesNotFollowCurrentOriginal
        case nonFiniteDate
        case invalidUpdatedAt
        case initialVersionMustBeFirst
        case invalidCurrentOriginalVersionNumber(Int)
        case replacementVersionNumberDoesNotFollowCurrent
    }

    public let id: JournalEntryID
    public let dayID: DayID
    public let currentOriginalVersionID: JournalOriginalVersionID
    public let currentOriginalVersionNumber: Int
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: JournalEntryID,
        dayID: DayID,
        initialOriginal: JournalOriginalVersion,
        createdAt: Date
    ) throws {
        guard initialOriginal.journalEntryID == id else {
            throw ValidationError.versionBelongsToDifferentEntry
        }
        guard initialOriginal.versionNumber == 1,
              initialOriginal.previousVersionID == nil else {
            throw ValidationError.initialVersionMustBeFirst
        }
        guard createdAt.isFinite else {
            throw ValidationError.nonFiniteDate
        }
        guard initialOriginal.savedAt >= createdAt else {
            throw ValidationError.invalidUpdatedAt
        }

        self.id = id
        self.dayID = dayID
        currentOriginalVersionID = initialOriginal.id
        currentOriginalVersionNumber = initialOriginal.versionNumber
        self.createdAt = createdAt
        updatedAt = initialOriginal.savedAt
    }

    private init(
        id: JournalEntryID,
        dayID: DayID,
        currentOriginalVersionID: JournalOriginalVersionID,
        currentOriginalVersionNumber: Int,
        createdAt: Date,
        updatedAt: Date
    ) throws {
        guard createdAt.isFinite, updatedAt.isFinite else {
            throw ValidationError.nonFiniteDate
        }
        guard updatedAt >= createdAt else {
            throw ValidationError.invalidUpdatedAt
        }
        guard currentOriginalVersionNumber > 0 else {
            throw ValidationError.invalidCurrentOriginalVersionNumber(
                currentOriginalVersionNumber
            )
        }

        self.id = id
        self.dayID = dayID
        self.currentOriginalVersionID = currentOriginalVersionID
        self.currentOriginalVersionNumber = currentOriginalVersionNumber
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Advances only to another exact user-authored original version.
    /// `JournalDerivedVersionID` is a distinct type and cannot be supplied here.
    public func acceptingUserEdit(_ version: JournalOriginalVersion) throws -> JournalEntry {
        guard version.journalEntryID == id else {
            throw ValidationError.versionBelongsToDifferentEntry
        }
        guard version.previousVersionID == currentOriginalVersionID else {
            throw ValidationError.replacementDoesNotFollowCurrentOriginal
        }
        let nextNumber = currentOriginalVersionNumber.addingReportingOverflow(1)
        guard !nextNumber.overflow, version.versionNumber == nextNumber.partialValue else {
            throw ValidationError.replacementVersionNumberDoesNotFollowCurrent
        }
        guard version.savedAt >= updatedAt else {
            throw ValidationError.invalidUpdatedAt
        }

        return try JournalEntry(
            id: id,
            dayID: dayID,
            currentOriginalVersionID: version.id,
            currentOriginalVersionNumber: version.versionNumber,
            createdAt: createdAt,
            updatedAt: version.savedAt
        )
    }

    /// Updates the single user-authored original that is continuously saved by the journal editor.
    ///
    /// This deliberately keeps the original identifier and version number stable: typing is not a
    /// user-visible revision operation. Explicit AI operations still create a separate derived copy.
    public func replacingCurrentOriginal(_ original: JournalOriginalVersion) throws -> JournalEntry {
        guard original.journalEntryID == id else {
            throw ValidationError.versionBelongsToDifferentEntry
        }
        guard original.id == currentOriginalVersionID,
              original.versionNumber == currentOriginalVersionNumber else {
            throw ValidationError.replacementDoesNotFollowCurrentOriginal
        }
        guard original.savedAt >= updatedAt else {
            throw ValidationError.invalidUpdatedAt
        }
        return try JournalEntry(
            id: id,
            dayID: dayID,
            currentOriginalVersionID: currentOriginalVersionID,
            currentOriginalVersionNumber: currentOriginalVersionNumber,
            createdAt: createdAt,
            updatedAt: original.savedAt
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, dayID, currentOriginalVersionID, currentOriginalVersionNumber
        case createdAt, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: values.decode(JournalEntryID.self, forKey: .id),
            dayID: values.decode(DayID.self, forKey: .dayID),
            currentOriginalVersionID: values.decode(
                JournalOriginalVersionID.self,
                forKey: .currentOriginalVersionID
            ),
            currentOriginalVersionNumber: values.decode(
                Int.self,
                forKey: .currentOriginalVersionNumber
            ),
            createdAt: values.decode(Date.self, forKey: .createdAt),
            updatedAt: values.decode(Date.self, forKey: .updatedAt)
        )
    }
}

public struct JournalFragment: Codable, Hashable, Sendable {
    public enum ValidationError: Error, Equatable, Sendable {
        case nonFiniteCreationDate
    }

    public let id: JournalFragmentID
    public let dayID: DayID
    public let body: String
    public let createdAt: Date

    public init(
        id: JournalFragmentID = JournalFragmentID(),
        dayID: DayID,
        body: String,
        createdAt: Date
    ) throws {
        guard createdAt.isFinite else {
            throw ValidationError.nonFiniteCreationDate
        }
        self.id = id
        self.dayID = dayID
        self.body = body
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey { case id, dayID, body, createdAt }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: values.decode(JournalFragmentID.self, forKey: .id),
            dayID: values.decode(DayID.self, forKey: .dayID),
            body: values.decode(String.self, forKey: .body),
            createdAt: values.decode(Date.self, forKey: .createdAt)
        )
    }
}

public enum JournalDerivedOperation: String, Codable, Hashable, Sendable {
    case organize
    case rewrite
    case continueWriting
    case proofread
}

public struct JournalDerivedVersion: Codable, Hashable, Sendable {
    public enum ValidationError: Error, Equatable, Sendable {
        case nonFiniteCreationDate
    }

    public let id: JournalDerivedVersionID
    public let journalEntryID: JournalEntryID
    public let sourceOriginalVersionID: JournalOriginalVersionID
    public let operation: JournalDerivedOperation
    public let body: String
    public let modelProvenance: ModelProvenance
    public let createdAt: Date

    /// A derived version represents an explicit user-requested AI operation and is never an original.
    public init(
        id: JournalDerivedVersionID = JournalDerivedVersionID(),
        journalEntryID: JournalEntryID,
        sourceOriginalVersionID: JournalOriginalVersionID,
        operation: JournalDerivedOperation,
        body: String,
        modelProvenance: ModelProvenance,
        createdAt: Date
    ) throws {
        guard createdAt.isFinite else {
            throw ValidationError.nonFiniteCreationDate
        }
        self.id = id
        self.journalEntryID = journalEntryID
        self.sourceOriginalVersionID = sourceOriginalVersionID
        self.operation = operation
        self.body = body
        self.modelProvenance = modelProvenance
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, journalEntryID, sourceOriginalVersionID, operation, body, modelProvenance, createdAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: values.decode(JournalDerivedVersionID.self, forKey: .id),
            journalEntryID: values.decode(JournalEntryID.self, forKey: .journalEntryID),
            sourceOriginalVersionID: values.decode(
                JournalOriginalVersionID.self,
                forKey: .sourceOriginalVersionID
            ),
            operation: values.decode(JournalDerivedOperation.self, forKey: .operation),
            body: values.decode(String.self, forKey: .body),
            modelProvenance: values.decode(ModelProvenance.self, forKey: .modelProvenance),
            createdAt: values.decode(Date.self, forKey: .createdAt)
        )
    }
}

private extension Date {
    var isFinite: Bool {
        timeIntervalSinceReferenceDate.isFinite
    }
}
