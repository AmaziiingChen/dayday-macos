/// One selected stable-state observation and every durable child it requires.
///
/// This is a closed metadata transaction value. It contains no redacted derivative bytes or
/// capability, so it is not the final event-and-derivative transaction boundary. A later
/// Capture-owned safe-derivative adapter must compose that boundary without exposing raw media
/// through DaydayCore.
public struct AtomicSelectedEvidence: Codable, Equatable, Hashable, Sendable {
  public enum ValidationError: Error, Equatable, Sendable {
    case eventIsNotStableStateObservation
    case eventSourceIsNotScreenUnderstanding
    case eventIsNotAllowed
    case eventEvidenceLinkMismatch
    case eventDisplayMismatch
    case eventTimestampMismatch
    case ocrEvidenceLinkMismatch
  }

  public let event: ObjectiveEvent
  public let evidenceFrame: EvidenceFrame
  public let ocrArtifact: OCRArtifact?

  public init(
    event: ObjectiveEvent,
    evidenceFrame: EvidenceFrame,
    ocrArtifact: OCRArtifact? = nil
  ) throws {
    guard event.kind == .stableStateObservation else {
      throw ValidationError.eventIsNotStableStateObservation
    }
    guard event.source.collector == .screenUnderstanding else {
      throw ValidationError.eventSourceIsNotScreenUnderstanding
    }
    guard event.securityDisposition == .allowed else {
      throw ValidationError.eventIsNotAllowed
    }
    guard event.id == evidenceFrame.source.stableStateObservationEventID else {
      throw ValidationError.eventEvidenceLinkMismatch
    }
    guard event.display?.id == evidenceFrame.source.displayID else {
      throw ValidationError.eventDisplayMismatch
    }
    guard event.occurredAt == evidenceFrame.observedAt else {
      throw ValidationError.eventTimestampMismatch
    }
    guard ocrArtifact?.evidenceFrameID == nil || ocrArtifact?.evidenceFrameID == evidenceFrame.id
    else {
      throw ValidationError.ocrEvidenceLinkMismatch
    }

    self.event = event
    self.evidenceFrame = evidenceFrame
    self.ocrArtifact = ocrArtifact
  }

  public init(from decoder: Decoder) throws {
    let container = try ClosedWorldDecoding.container(
      keyedBy: CodingKeys.self,
      typeName: "AtomicSelectedEvidence",
      from: decoder
    )
    try self.init(
      event: container.decode(ObjectiveEvent.self, forKey: .event),
      evidenceFrame: container.decode(EvidenceFrame.self, forKey: .evidenceFrame),
      ocrArtifact: container.decodeIfPresent(OCRArtifact.self, forKey: .ocrArtifact)
    )
  }

  private enum CodingKeys: String, CodingKey {
    case event
    case evidenceFrame
    case ocrArtifact
  }
}
