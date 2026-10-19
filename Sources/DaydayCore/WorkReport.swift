import Foundation

// MARK: - Work report

public enum WorkReportStatus: String, Codable, Hashable, Sendable {
    case draft
    case `final`
}

public enum WorkReportRevisionOrigin: String, Codable, Hashable, Sendable {
    case user
    case model
    case imported
}

public struct ModelProvenance: Codable, Hashable, Sendable {
    public enum ValidationError: Error, Equatable, Sendable {
        case emptyProvider
        case emptyModel
        case emptyPromptVersion
    }

    public let provider: String
    public let model: String
    public let promptVersion: String

    public init(provider: String, model: String, promptVersion: String) throws {
        guard !provider.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError.emptyProvider
        }
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError.emptyModel
        }
        guard !promptVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError.emptyPromptVersion
        }

        self.provider = provider
        self.model = model
        self.promptVersion = promptVersion
    }

    private enum CodingKeys: String, CodingKey {
        case provider, model, promptVersion
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            provider: values.decode(String.self, forKey: .provider),
            model: values.decode(String.self, forKey: .model),
            promptVersion: values.decode(String.self, forKey: .promptVersion)
        )
    }
}

public struct WorkReportRevision: Codable, Hashable, Sendable {
    public enum ValidationError: Error, Equatable, Sendable {
        case invalidRevisionNumber(Int)
        case missingPreviousRevision
        case unexpectedPreviousRevision
        case missingModelProvenance
        case unexpectedModelProvenance
        case nonFiniteCreationDate
        case selfReferentialPreviousRevision
    }

    public let id: WorkReportRevisionID
    public let reportID: WorkReportID
    public let revisionNumber: Int
    public let previousRevisionID: WorkReportRevisionID?
    public let body: String
    public let origin: WorkReportRevisionOrigin
    public let modelProvenance: ModelProvenance?
    public let sourceReferences: WorkReportSourceReferences
    public let createdAt: Date

    public init(
        id: WorkReportRevisionID = WorkReportRevisionID(),
        reportID: WorkReportID,
        revisionNumber: Int,
        previousRevisionID: WorkReportRevisionID?,
        body: String,
        origin: WorkReportRevisionOrigin,
        modelProvenance: ModelProvenance?,
        sourceReferences: WorkReportSourceReferences = .empty,
        createdAt: Date
    ) throws {
        guard revisionNumber > 0 else {
            throw ValidationError.invalidRevisionNumber(revisionNumber)
        }
        if revisionNumber == 1, previousRevisionID != nil {
            throw ValidationError.unexpectedPreviousRevision
        }
        if revisionNumber > 1, previousRevisionID == nil {
            throw ValidationError.missingPreviousRevision
        }
        if previousRevisionID == id {
            throw ValidationError.selfReferentialPreviousRevision
        }
        switch (origin, modelProvenance) {
        case (.model, nil):
            throw ValidationError.missingModelProvenance
        case (.user, .some), (.imported, .some):
            throw ValidationError.unexpectedModelProvenance
        default:
            break
        }
        guard createdAt.isFinite else {
            throw ValidationError.nonFiniteCreationDate
        }

        self.id = id
        self.reportID = reportID
        self.revisionNumber = revisionNumber
        self.previousRevisionID = previousRevisionID
        self.body = body
        self.origin = origin
        self.modelProvenance = modelProvenance
        self.sourceReferences = sourceReferences
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, reportID, revisionNumber, previousRevisionID, body, origin
        case modelProvenance, sourceReferences, createdAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: values.decode(WorkReportRevisionID.self, forKey: .id),
            reportID: values.decode(WorkReportID.self, forKey: .reportID),
            revisionNumber: values.decode(Int.self, forKey: .revisionNumber),
            previousRevisionID: values.decodeIfPresent(
                WorkReportRevisionID.self,
                forKey: .previousRevisionID
            ),
            body: values.decode(String.self, forKey: .body),
            origin: values.decode(WorkReportRevisionOrigin.self, forKey: .origin),
            modelProvenance: values.decodeIfPresent(ModelProvenance.self, forKey: .modelProvenance),
            sourceReferences: values.decode(WorkReportSourceReferences.self, forKey: .sourceReferences),
            createdAt: values.decode(Date.self, forKey: .createdAt)
        )
    }
}

public enum WorkReportRevisionAcceptance: String, Codable, Hashable, Sendable {
    case user
    case automatic
}

public struct WorkReport: Codable, Hashable, Sendable {
    public enum ValidationError: Error, Equatable, Sendable {
        case revisionBelongsToDifferentReport
        case nonFiniteDate
        case invalidUpdatedAt
        case invalidFinalizedAt
        case finalizationStateMismatch
        case confirmedReportRequiresUserAcceptance
        case replacementDoesNotFollowCurrentRevision
        case initialRevisionMustBeFirst
        case invalidCurrentRevisionNumber(Int)
        case replacementRevisionNumberDoesNotFollowCurrent
    }

    public let id: WorkReportID
    public let dayID: DayID
    public let status: WorkReportStatus
    public let currentRevisionID: WorkReportRevisionID
    public let currentRevisionNumber: Int
    public let createdAt: Date
    public let updatedAt: Date
    public let finalizedAt: Date?

    public init(
        id: WorkReportID,
        dayID: DayID,
        initialRevision: WorkReportRevision,
        createdAt: Date
    ) throws {
        guard initialRevision.reportID == id else {
            throw ValidationError.revisionBelongsToDifferentReport
        }
        guard initialRevision.revisionNumber == 1,
              initialRevision.previousRevisionID == nil else {
            throw ValidationError.initialRevisionMustBeFirst
        }
        guard createdAt.isFinite else {
            throw ValidationError.nonFiniteDate
        }
        guard initialRevision.createdAt >= createdAt else {
            throw ValidationError.invalidUpdatedAt
        }

        self.id = id
        self.dayID = dayID
        status = .draft
        currentRevisionID = initialRevision.id
        currentRevisionNumber = initialRevision.revisionNumber
        self.createdAt = createdAt
        updatedAt = initialRevision.createdAt
        finalizedAt = nil
    }

    private init(
        id: WorkReportID,
        dayID: DayID,
        status: WorkReportStatus,
        currentRevisionID: WorkReportRevisionID,
        currentRevisionNumber: Int,
        createdAt: Date,
        updatedAt: Date,
        finalizedAt: Date?
    ) throws {
        guard createdAt.isFinite, updatedAt.isFinite, finalizedAt?.isFinite ?? true else {
            throw ValidationError.nonFiniteDate
        }
        guard updatedAt >= createdAt else {
            throw ValidationError.invalidUpdatedAt
        }
        guard currentRevisionNumber > 0 else {
            throw ValidationError.invalidCurrentRevisionNumber(currentRevisionNumber)
        }
        guard (status == .final) == (finalizedAt != nil) else {
            throw ValidationError.finalizationStateMismatch
        }
        if let finalizedAt, finalizedAt != updatedAt {
            throw ValidationError.invalidFinalizedAt
        }

        self.id = id
        self.dayID = dayID
        self.status = status
        self.currentRevisionID = currentRevisionID
        self.currentRevisionNumber = currentRevisionNumber
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.finalizedAt = finalizedAt
    }

    public func accepting(
        _ revision: WorkReportRevision,
        initiatedBy acceptance: WorkReportRevisionAcceptance,
        at acceptedAt: Date
    ) throws -> WorkReport {
        guard revision.reportID == id else {
            throw ValidationError.revisionBelongsToDifferentReport
        }
        guard revision.previousRevisionID == currentRevisionID else {
            throw ValidationError.replacementDoesNotFollowCurrentRevision
        }
        let nextNumber = currentRevisionNumber.addingReportingOverflow(1)
        guard !nextNumber.overflow, revision.revisionNumber == nextNumber.partialValue else {
            throw ValidationError.replacementRevisionNumberDoesNotFollowCurrent
        }
        guard acceptedAt.isFinite else {
            throw ValidationError.nonFiniteDate
        }
        guard revision.createdAt >= updatedAt,
              acceptedAt >= revision.createdAt else {
            throw ValidationError.invalidUpdatedAt
        }
        if status == .final, acceptance == .automatic {
            throw ValidationError.confirmedReportRequiresUserAcceptance
        }

        return try WorkReport(
            id: id,
            dayID: dayID,
            status: status,
            currentRevisionID: revision.id,
            currentRevisionNumber: revision.revisionNumber,
            createdAt: createdAt,
            updatedAt: acceptedAt,
            finalizedAt: status == .final ? acceptedAt : nil
        )
    }

    public func finalizedByUser(at date: Date) throws -> WorkReport {
        guard date >= updatedAt else {
            throw ValidationError.invalidUpdatedAt
        }
        return try WorkReport(
            id: id,
            dayID: dayID,
            status: .final,
            currentRevisionID: currentRevisionID,
            currentRevisionNumber: currentRevisionNumber,
            createdAt: createdAt,
            updatedAt: date,
            finalizedAt: date
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, dayID, status, currentRevisionID, currentRevisionNumber
        case createdAt, updatedAt, finalizedAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: values.decode(WorkReportID.self, forKey: .id),
            dayID: values.decode(DayID.self, forKey: .dayID),
            status: values.decode(WorkReportStatus.self, forKey: .status),
            currentRevisionID: values.decode(WorkReportRevisionID.self, forKey: .currentRevisionID),
            currentRevisionNumber: values.decode(Int.self, forKey: .currentRevisionNumber),
            createdAt: values.decode(Date.self, forKey: .createdAt),
            updatedAt: values.decode(Date.self, forKey: .updatedAt),
            finalizedAt: values.decodeIfPresent(Date.self, forKey: .finalizedAt)
        )
    }
}

private extension Date {
    var isFinite: Bool {
        timeIntervalSinceReferenceDate.isFinite
    }
}
