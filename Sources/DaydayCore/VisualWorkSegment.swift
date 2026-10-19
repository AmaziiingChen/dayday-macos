import Foundation

/// Coarse, visible work modes inferred from a short screen timeline. These are never objective
/// facts and must remain explicitly labelled as visual-model output in presentation and reports.
public enum VisualWorkActivityKind: String, Codable, CaseIterable, Hashable, Sendable {
  case reading
  case writing
  case navigation
  case development
  case communication
  case media
  case meeting
  case other
  case uncertain
}

/// The inferred contribution of one display to a visual work segment.
public enum VisualDisplayRole: String, Codable, CaseIterable, Hashable, Sendable {
  case primary
  case reference
  case communication
  case monitoring
  case independent
  case unknown
}

/// Whether visible displays appear to support one work situation. This value deliberately permits
/// uncertainty instead of forcing a single-task interpretation for a multi-display desktop.
public enum VisualDisplayRelationship: String, Codable, CaseIterable, Hashable, Sendable {
  case coordinated
  case independent
  case uncertain
}

/// Whether the visual model could reconcile the pixels with a time-scoped deterministic system
/// context. This is an AI inference marker, not a replacement for the system fact.
public enum VisualSystemContextAgreement: String, Codable, CaseIterable, Hashable, Sendable {
  case matches
  case conflicts
  case unavailable
}

/// A bounded model description of the visible state of one display. It says what was visible, not
/// that the user read, clicked, or completed that content.
public struct VisualDisplayState: Codable, Equatable, Hashable, Sendable {
  public enum ValidationError: Error, Equatable, Sendable { case emptyState; case stateTooLong }

  public let displayID: DisplayID
  public let role: VisualDisplayRole
  public let visibleState: String

  public init(displayID: DisplayID, role: VisualDisplayRole, visibleState: String) throws {
    let normalized = visibleState.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { throw ValidationError.emptyState }
    guard normalized.utf8.count <= 600 else { throw ValidationError.stateTooLong }
    self.displayID = displayID
    self.role = role
    self.visibleState = normalized
  }
}

/// The typed, bounded result of visual understanding for one chronological multi-display window.
/// The model may infer a task and display relationship, but the foreground application is copied
/// from a separately collected system fact and must never be replaced by a visual guess.
public struct VisualWorkSegment: Codable, Equatable, Hashable, Sendable {
  public static let currentRecordVersion = 1

  public enum ValidationError: Error, Equatable, Sendable {
    case unsupportedRecordVersion(Int)
    case emptyPrimarySituation
    case primarySituationTooLong
    case emptyInteraction
    case interactionTooLong
    case noDisplayStates
    case duplicateDisplay(DisplayID)
    case tooManyDisplayStates(Int)
    case tooManyEvidence(Int)
    case invalidEvidence
    case tooManyUncertainties(Int)
    case invalidUncertainty
    case invalidForegroundApplication
  }

  public let primarySituation: String
  public let interaction: String
  public let activityKind: VisualWorkActivityKind
  /// A privacy-filtered system fact, not an application name inferred from pixels.
  public let foregroundApplicationLabel: String?
  public let displays: [VisualDisplayState]
  public let relationship: VisualDisplayRelationship
  public let systemContextAgreement: VisualSystemContextAgreement
  public let evidence: [String]
  public let uncertainties: [String]
  public let recordVersion: Int

  public init(
    primarySituation: String,
    interaction: String,
    activityKind: VisualWorkActivityKind,
    foregroundApplicationLabel: String? = nil,
    displays: [VisualDisplayState],
    relationship: VisualDisplayRelationship,
    systemContextAgreement: VisualSystemContextAgreement = .unavailable,
    evidence: [String],
    uncertainties: [String] = [],
    recordVersion: Int = currentRecordVersion
  ) throws {
    guard recordVersion == Self.currentRecordVersion else {
      throw ValidationError.unsupportedRecordVersion(recordVersion)
    }
    self.primarySituation = try Self.bounded(
      primarySituation, maximumBytes: 1_024, empty: .emptyPrimarySituation, tooLong: .primarySituationTooLong
    )
    self.interaction = try Self.bounded(
      interaction, maximumBytes: 1_024, empty: .emptyInteraction, tooLong: .interactionTooLong
    )
    guard !displays.isEmpty else { throw ValidationError.noDisplayStates }
    guard displays.count <= 4 else { throw ValidationError.tooManyDisplayStates(displays.count) }
    var displayIDs = Set<DisplayID>()
    for display in displays where !displayIDs.insert(display.displayID).inserted {
      throw ValidationError.duplicateDisplay(display.displayID)
    }
    guard evidence.count <= 8 else { throw ValidationError.tooManyEvidence(evidence.count) }
    guard uncertainties.count <= 4 else { throw ValidationError.tooManyUncertainties(uncertainties.count) }
    self.evidence = try evidence.map {
      try Self.bounded($0, maximumBytes: 256, empty: .invalidEvidence, tooLong: .invalidEvidence)
    }
    self.uncertainties = try uncertainties.map {
      try Self.bounded($0, maximumBytes: 256, empty: .invalidUncertainty, tooLong: .invalidUncertainty)
    }
    if let foregroundApplicationLabel {
      self.foregroundApplicationLabel = try Self.bounded(
        foregroundApplicationLabel, maximumBytes: 128, empty: .invalidForegroundApplication,
        tooLong: .invalidForegroundApplication
      )
    } else {
      self.foregroundApplicationLabel = nil
    }
    self.activityKind = activityKind
    self.displays = displays
    self.relationship = relationship
    self.systemContextAgreement = systemContextAgreement
    self.recordVersion = recordVersion
  }

  private enum CodingKeys: String, CodingKey {
    case primarySituation, interaction, activityKind, foregroundApplicationLabel, displays
    case relationship, systemContextAgreement, evidence, uncertainties, recordVersion
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      primarySituation: values.decode(String.self, forKey: .primarySituation),
      interaction: values.decode(String.self, forKey: .interaction),
      activityKind: values.decode(VisualWorkActivityKind.self, forKey: .activityKind),
      foregroundApplicationLabel: try values.decodeIfPresent(String.self, forKey: .foregroundApplicationLabel),
      displays: try values.decode([VisualDisplayState].self, forKey: .displays),
      relationship: try values.decode(VisualDisplayRelationship.self, forKey: .relationship),
      systemContextAgreement: try values.decodeIfPresent(
        VisualSystemContextAgreement.self, forKey: .systemContextAgreement
      ) ?? .unavailable,
      evidence: try values.decode([String].self, forKey: .evidence),
      uncertainties: try values.decodeIfPresent([String].self, forKey: .uncertainties) ?? [],
      recordVersion: try values.decodeIfPresent(Int.self, forKey: .recordVersion) ?? Self.currentRecordVersion
    )
  }

  private static func bounded(
    _ value: String, maximumBytes: Int, empty: ValidationError, tooLong: ValidationError
  ) throws -> String {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { throw empty }
    guard normalized.utf8.count <= maximumBytes else { throw tooLong }
    guard !normalized.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
      throw empty
    }
    return normalized
  }
}
